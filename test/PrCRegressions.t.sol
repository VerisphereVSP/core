// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// patch_prC_rulings: targeted regressions for the PR-C rulings, one per
/// mechanism, deterministic where possible.
///   S-01  honest bucket-index init + 1-wei settlement floor (no resurrection)
///   S-03  never-snap-down, decay floored at tracked leader, 10-slot tracker,
///         permissionless refreshSMax closes untracked-dormant deviations
///   S-13  zero-pending acceptGovernance still reverts (NotPendingGovernance)
contract PrCRegressions is Test {
    StakeEngine eng;
    MockVSP vsp;
    MockProtocolPolicy policy;

    uint256 constant DEPLOY_RATE_MAX = 693805319167998976;
    uint256 constant RAY = 1e18;

    function setUp() public {
        vm.warp(86400 * 1000);
        vsp = new MockVSP();
        policy = new MockProtocolPolicy(0);
        policy.setRates(0, DEPLOY_RATE_MAX);
        eng = StakeEngine(
            address(
                new ERC1967Proxy(
                    address(new StakeEngine(address(0))),
                    abi.encodeCall(StakeEngine.initialize, (address(this), address(vsp), address(policy)))
                )
            )
        );
        vsp.mint(address(this), 1e30);
        vsp.approve(address(eng), type(uint256).max);
    }

    function _stake(address who, uint256 post, uint8 side, uint256 amt) internal {
        vsp.mint(who, amt);
        vm.prank(who);
        vsp.approve(address(eng), type(uint256).max);
        vm.prank(who);
        eng.stake(post, side, amt);
    }

    function _total(uint256 post) internal view returns (uint256) {
        (uint256 s, uint256 c) = eng.getPostTotals(post);
        return s + c;
    }

    // ─────────────────────────────────────────────────────────────
    // S-03 layer (i): never snap down
    // ─────────────────────────────────────────────────────────────
    function test_S03_NeverSnapDown_DustCannotDrag() public {
        _stake(address(0xA1), 1, 0, 300e18);
        vm.prank(address(0xA1));
        eng.withdraw(1, 0, 300e18, true);

        // pre-PR-C, this 1-wei stake snapped sMax to 1
        _stake(address(0xD057), 9, 0, 1);
        assertEq(eng.sMax(), 300e18, "same-epoch: sMax must hold the high-water mark");
    }

    function test_S03_DecayIsSoleDescent_FlooredAtTrackedLeader() public {
        _stake(address(0xA1), 1, 0, 300e18);
        _stake(address(0xA2), 2, 0, 100e18);
        vm.prank(address(0xA1));
        eng.withdraw(1, 0, 300e18, true);

        // 5 epochs of decay from 300e18 at 10%/day = 300e18 * 0.9^5 ≈ 177.1e18,
        // still above the tracked leader (post 2, 100e18): pure decay value.
        vm.warp(vm.getBlockTimestamp() + 5 days);
        eng.refreshSMax(2);
        uint256 expect5 = 300e18;
        for (uint256 i = 0; i < 5; i++) {
            expect5 = (expect5 * 9e17) / RAY;
        }
        assertEq(eng.sMax(), expect5, "descent must be exactly the decay curve");

        // 30 more epochs decays past the leader: floor engages.
        vm.warp(vm.getBlockTimestamp() + 30 days);
        eng.refreshSMax(2);
        assertEq(eng.sMax(), _total(2), "decay must floor at the tracked leader");
    }

    // ─────────────────────────────────────────────────────────────
    // S-03 layer (ii): permissionless poke closes untracked deviations
    // ─────────────────────────────────────────────────────────────
    function test_S03_RefreshSMax_PermissionlessAndHonest() public {
        // fill all 10 tracker slots, plus one untracked dormant post (11)
        for (uint256 p = 1; p <= 10; p++) {
            _stake(address(uint160(0xA000 + p)), p, 0, (20 - p) * 10e18);
        }
        _stake(address(0xDEAD), 11, 0, 5e18); // smallest — never enters tracker

        // unwind everything tracked; sMax decays with nothing visible to floor at
        for (uint256 p = 1; p <= 10; p++) {
            vm.prank(address(uint160(0xA000 + p)));
            eng.withdraw(p, 0, (20 - p) * 10e18, true);
        }
        vm.warp(vm.getBlockTimestamp() + 40 days);

        // any address at all can restore I.4 for post 11
        vm.prank(address(0xBADC0FFEE));
        eng.refreshSMax(11);
        assertGe(eng.sMax(), _total(11), "poke must restore sMax >= post total");
        // honesty bound: the poke can only feed stored reality, so sMax is at
        // most the pre-existing high-water decay path — never inflated above it.
        uint256 hw = 190e18; // initial leader (post 1)
        uint256 cap30 = hw;
        for (uint256 i = 0; i < 30; i++) {
            cap30 = (cap30 * 9e17) / 1e18;
        }
        assertLe(eng.sMax(), cap30 + 1, "poke must not inflate sMax beyond the decay curve");
    }

    // ─────────────────────────────────────────────────────────────
    // S-03 layer (iii): 10-slot tracker
    // ─────────────────────────────────────────────────────────────
    function test_S03_TrackerHoldsTen() public {
        assertEq(eng.TRACKED_POSTS(), 10, "tracker constant");
        for (uint256 p = 1; p <= 10; p++) {
            _stake(address(uint160(0xB000 + p)), p, 0, (11 - p) * 10e18); // 100e18 down to 10e18
        }
        // unwind the leader; the OLD 3-slot board would only remember posts 2-3.
        vm.prank(address(uint160(0xB001)));
        eng.withdraw(1, 0, 100e18, true);
        vm.warp(vm.getBlockTimestamp() + 40 days);
        // decay far past everything, then let any tracked slot floor it:
        // post 10 (10e18) is only visible because the board is 10 wide.
        eng.refreshSMax(10);
        assertGe(eng.sMax(), _total(10), "10th-ranked post must be tracked and floor sMax");
    }

    // ─────────────────────────────────────────────────────────────
    // S-01: honest init + floor — no resurrection, exits live
    // ─────────────────────────────────────────────────────────────
    function test_S01_WipedBucketStaysDead_EngineSolvent() public {
        // deploy-rate wipe scenario, S01ConfirmedPoC shape but two settlements
        for (uint256 i = 0; i < 100; i++) {
            _stake(address(uint160(0x100000 + i)), 1, 0, 1e18);
        }
        for (uint256 i = 0; i < 300; i++) {
            _stake(address(uint160(0x200000 + i)), 1, 0, 1e18); // bucket members
        }
        _stake(address(0xBEEF), 1, 1, 4000e18);

        // cap-rate regime: gRay >= RAY inside one settlement -> factor 0 -> the
        // S-01 floor (index = 1 wei) is the exact code path under test.
        policy.setRates(0, 5e18);
        vm.warp(vm.getBlockTimestamp() + 300 days);
        eng.updatePost(1);
        (uint256 s1, uint256 c1) = eng.getPostTotals(1);
        assertGe(vsp.balanceOf(address(eng)), s1 + c1, "solvent after wipe settlement");

        // the read-back settlement that used to resurrect the bucket
        vm.warp(vm.getBlockTimestamp() + 1 days);
        eng.updatePost(1);
        (uint256 s2, uint256 c2) = eng.getPostTotals(1);
        assertGe(vsp.balanceOf(address(eng)), s2 + c2, "no resurrection on second settlement");

        // a wiped member's exit must not revert and must not overdraw
        address victim = address(uint160(0x200000 + 7));
        uint256 claim = eng.getUserStake(victim, 1, 0);
        assertLe(claim, 1e15, "fully wiped bucket member holds dust at most (index floored at 1)");
        if (claim > 0) {
            vm.prank(victim);
            eng.withdraw(1, 0, claim, true);
        }
        (uint256 s3, uint256 c3) = eng.getPostTotals(1);
        assertGe(vsp.balanceOf(address(eng)), s3 + c3, "solvent after wiped-member exit");
    }

    function test_S01_FreshBucketAfterFullExit_InitializesCleanly() public {
        // one bucket member in, out, in again: index must re-init to RAY, value exact
        for (uint256 i = 0; i < 100; i++) {
            _stake(address(uint160(0x300000 + i)), 1, 0, 2e18); // fill ranked
        }
        address m = address(0x333);
        _stake(m, 1, 0, 1e18);
        vm.prank(m);
        eng.withdraw(1, 0, 1e18, true);
        assertEq(eng.getUserStake(m, 1, 0), 0, "clean exit");
        _stake(m, 1, 0, 1e18);
        assertEq(eng.getUserStake(m, 1, 0), 1e18, "re-entry at face value, no sentinel games");
    }

    // ─────────────────────────────────────────────────────────────
    // S-13: dead branch removed, guard intact
    // ─────────────────────────────────────────────────────────────
    function test_S13_ZeroPendingAcceptStillReverts() public {
        assertEq(eng.pendingGovernance(), address(0), "precondition");
        vm.expectRevert(abi.encodeWithSignature("NotPendingGovernance()"));
        eng.acceptGovernance();
    }
}
