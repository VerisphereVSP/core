// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// ADVERSARIAL REGRESSION SUITE for the S-08 and S-10 fixes.
///
/// Motivation: the S-02 v1 fix looked correct and kept the 242-test baseline
/// green, yet orphaned 500e18 through a single admin path (compactLots). These
/// tests apply the same class of attack to the other two "verified" fixes:
///   - exercise EVERY path that touches the same state
///   - always end with a full exit and a solvency assertion
///   - hit index/edge cases the happy-path tests skip
contract FixAdversarialPoC is Test {
    StakeEngine eng;
    MockVSP vsp;
    MockProtocolPolicy policy;

    uint256 constant DEPLOY_RATE_MAX = 693805319167998976;
    uint256 constant POST = 1;
    uint256 constant C = 100;

    function _fresh() internal {
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
        vsp.mint(address(this), 1e33);
        vsp.approve(address(eng), type(uint256).max);
    }

    function _stake(address who, uint8 side, uint256 amt) internal {
        vsp.mint(who, amt);
        vm.prank(who);
        vsp.approve(address(eng), type(uint256).max);
        vm.prank(who);
        eng.stake(POST, side, amt);
    }

    function _solvent() internal view returns (bool) {
        (uint256 s, uint256 c) = eng.getPostTotals(POST);
        return vsp.balanceOf(address(eng)) >= s + c;
    }

    // ─────────────────────────────────────────────────────────────
    // S-08 fix: shift-compaction. Index bookkeeping is the risk.
    // ─────────────────────────────────────────────────────────────

    /// Ghost at index 0 (the first slot) — the shift loop's boundary case.
    function test_S08_GhostAtIndexZero_AllSurvive() public {
        _fresh();
        address a = address(0xA1);
        address b = address(0xB2);
        address c = address(0xC3);
        _stake(a, 0, 100e18);
        _stake(b, 0, 100e18);
        _stake(c, 0, 100e18);
        vm.prank(a);
        eng.withdraw(POST, 0, 100e18, true); // ghost at slot 0

        eng.compactLots(POST, 0);

        assertEq(eng.getUserStake(b, POST, 0), 100e18, "B lost funds");
        assertEq(eng.getUserStake(c, POST, 0), 100e18, "C lost funds");
        // both must still be able to exit
        vm.prank(b);
        eng.withdraw(POST, 0, 100e18, true);
        vm.prank(c);
        eng.withdraw(POST, 0, 100e18, true);
        assertEq(vsp.balanceOf(b), 100e18, "B exit shortfall");
        assertEq(vsp.balanceOf(c), 100e18, "C exit shortfall");
        assertTrue(_solvent(), "insolvent after compact+exit");
    }

    /// Ghost at the LAST index.
    function test_S08_GhostAtLastIndex_AllSurvive() public {
        _fresh();
        address a = address(0xA1);
        address b = address(0xB2);
        address c = address(0xC3);
        _stake(a, 0, 100e18);
        _stake(b, 0, 100e18);
        _stake(c, 0, 100e18);
        vm.prank(c);
        eng.withdraw(POST, 0, 100e18, true); // ghost at the tail

        eng.compactLots(POST, 0);
        assertEq(eng.getUserStake(a, POST, 0), 100e18, "A lost funds");
        assertEq(eng.getUserStake(b, POST, 0), 100e18, "B lost funds");
        vm.prank(a);
        eng.withdraw(POST, 0, 100e18, true);
        vm.prank(b);
        eng.withdraw(POST, 0, 100e18, true);
        assertTrue(_solvent(), "insolvent");
    }

    /// MULTIPLE adjacent ghosts — the pop-count arithmetic is the risk.
    function test_S08_ManyGhostsInterleaved_AllSurvive() public {
        _fresh();
        address[8] memory who = [
            address(0xA1),
            address(0xA2),
            address(0xA3),
            address(0xA4),
            address(0xA5),
            address(0xA6),
            address(0xA7),
            address(0xA8)
        ];
        for (uint256 i = 0; i < who.length; i++) {
            _stake(who[i], 0, 100e18);
        }
        // ghost out indices 0,1,4,7 (adjacent pair + isolated + tail)
        uint256[4] memory kill = [uint256(0), 1, 4, 7];
        for (uint256 k = 0; k < kill.length; k++) {
            vm.prank(who[kill[k]]);
            eng.withdraw(POST, 0, 100e18, true);
        }

        eng.compactLots(POST, 0);

        // survivors: 2,3,5,6
        uint256[4] memory live = [uint256(2), 3, 5, 6];
        for (uint256 j = 0; j < live.length; j++) {
            assertEq(eng.getUserStake(who[live[j]], POST, 0), 100e18, "survivor lost funds");
            vm.prank(who[live[j]]);
            eng.withdraw(POST, 0, 100e18, true);
            assertEq(vsp.balanceOf(who[live[j]]), 100e18, "survivor exit shortfall");
        }
        assertTrue(_solvent(), "insolvent after multi-ghost compact");
    }

    /// ALL lots are ghosts — array must empty cleanly, no underflow.
    function test_S08_AllGhosts_NoUnderflow() public {
        _fresh();
        address a = address(0xA1);
        address b = address(0xB2);
        _stake(a, 0, 100e18);
        _stake(b, 0, 100e18);
        vm.prank(a);
        eng.withdraw(POST, 0, 100e18, true);
        vm.prank(b);
        eng.withdraw(POST, 0, 100e18, true);

        eng.compactLots(POST, 0);
        (uint256 s,) = eng.getPostTotals(POST);
        emit log_named_uint("side total after all-ghost compact", s);
        assertTrue(_solvent(), "insolvent");

        // a fresh staker must still work afterwards
        _stake(address(0xD4), 0, 50e18);
        assertEq(eng.getUserStake(address(0xD4), POST, 0), 50e18, "post-compact staking broken");
    }

    /// Compact then RESTAKE by a compacted address — index must be reusable.
    function test_S08_CompactThenRestake() public {
        _fresh();
        address a = address(0xA1);
        _stake(a, 0, 100e18);
        _stake(address(0xB2), 0, 100e18);
        vm.prank(a);
        eng.withdraw(POST, 0, 100e18, true);
        eng.compactLots(POST, 0);

        _stake(a, 0, 300e18);
        assertEq(eng.getUserStake(a, POST, 0), 300e18, "restake after compact broken");
        vm.prank(a);
        eng.withdraw(POST, 0, 300e18, true);
        assertEq(vsp.balanceOf(a), 400e18, "exit after compact+restake shortfall");
        assertTrue(_solvent(), "insolvent");
    }

    /// Compaction while a BUCKET is active (ranked full) — the S-02 v1 lesson was
    /// that admin paths interact badly with the bucket.
    function test_S08_CompactWithActiveBucket() public {
        _fresh();
        for (uint256 i = 0; i < C; i++) {
            _stake(address(uint160(0x100000 + i)), 0, 10e18);
        }
        address bm = address(0x3001);
        _stake(bm, 0, 5e18); // bucket member
        // ghost one ranked lot
        vm.prank(address(uint160(0x100000)));
        eng.withdraw(POST, 0, 10e18, true);

        // With a bucket active, _rebalance promotes the bucket member into the
        // freed slot, so no ghost remains and compactLots correctly reverts.
        try eng.compactLots(POST, 0) {
            emit log("compactLots ran");
        } catch {
            emit log("compactLots reverted NoGhostLots: _rebalance already promoted, no ghost left");
        }

        emit log_named_uint("bucket member stake after", eng.getUserStake(bm, POST, 0));
        assertEq(eng.getUserStake(bm, POST, 0), 5e18, "bucket member lost funds");
        vm.prank(bm);
        eng.withdraw(POST, 0, 5e18, true);
        assertEq(vsp.balanceOf(bm), 5e18, "bucket exit shortfall");
        assertTrue(_solvent(), "insolvent with active bucket");
    }

    // ─────────────────────────────────────────────────────────────
    // S-10 fix: view now uses raw sMax. Risk is a wrong view, or a
    // divide-by-zero / stale read in a state the happy path skips.
    // ─────────────────────────────────────────────────────────────

    /// sMax == 0 edge: no stake anywhere. The view must not revert.
    function test_S10_ViewOnVirginPost_NoRevert() public {
        _fresh();
        (uint256 s, uint256 c) = eng.getPostTotals(999);
        assertEq(s + c, 0, "virgin post should read zero");
        assertEq(eng.getUserStake(address(0xDEAD), 999, 0), 0, "virgin user should read zero");
    }

    /// View must stay consistent with materialised across MANY settlements,
    /// including after the decoy-unwind state that produced the original gap.
    function test_S10_ViewMatchesAcrossRepeatedSettlements() public {
        _fresh();
        _stake(address(0xD1), 0, 300e18);
        _stake(address(0xA1), 0, 100e18);
        _stake(address(0xBEEF), 1, 10e18);
        vm.prank(address(0xD1));
        eng.withdraw(POST, 0, 300e18, true);

        for (uint256 r = 0; r < 8; r++) {
            vm.warp(block.timestamp + 45 days);
            (uint256 vS, uint256 vC) = eng.getPostTotals(POST);
            eng.updatePost(POST);
            (uint256 mS, uint256 mC) = eng.getPostTotals(POST);
            assertEq(vS, mS, "view != materialised (support)");
            assertEq(vC, mC, "view != materialised (challenge)");
            assertTrue(_solvent(), "insolvent");
        }
        emit log("view == materialised exactly, 8 rounds x 45 days");
    }

    /// getUserStake (the second patched site) must agree with what a withdrawal
    /// actually pays out. A wrong view here would mislead every integrator.
    function test_S10_UserStakeViewMatchesActualPayout() public {
        _fresh();
        address u = address(0xA1);
        _stake(u, 0, 100e18);
        _stake(address(0xBEEF), 1, 10e18);

        vm.warp(block.timestamp + 90 days);
        eng.updatePost(POST);

        uint256 quoted = eng.getUserStake(u, POST, 0);
        vm.prank(u);
        eng.withdraw(POST, 0, quoted, true);
        uint256 paid = vsp.balanceOf(u);

        emit log_named_uint("view quoted", quoted);
        emit log_named_uint("actually paid", paid);
        assertEq(paid, quoted, "S-10: quoted stake != amount paid on withdrawal");
        assertTrue(_solvent(), "insolvent after quoted-exact withdrawal");
    }
}
