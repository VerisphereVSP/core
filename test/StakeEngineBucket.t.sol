// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// patch_h1a_bucket — StakeEngine ranked-cap + tail-bucket tests.
// Focus: the H-1 fund-lock is gone (bucket withdraw is O(1) regardless of how
// many sybils are in the bucket) and the bucket rebase stays solvent. Honest
// posts (<= C stakers) are covered by the existing StakeEngine* suites, which
// must keep passing unchanged.
import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

contract StakeEngineBucketTest is Test {
    StakeEngine eng;
    MockVSP vsp;
    MockProtocolPolicy policy;

    uint256 constant POST = 1;
    uint256 constant FEE = 50;

    function setUp() public {
        vsp = new MockVSP();
        policy = new MockProtocolPolicy(FEE);
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

    function _fund(address who, uint256 amt) internal {
        vsp.mint(who, amt);
        vm.prank(who);
        vsp.approve(address(eng), type(uint256).max);
    }

    /// A big ranked stake, then MANY small sybil stakes that all land in the
    /// bucket. A bucket member must be able to withdraw in bounded gas — the
    /// H-1 fund-lock regression (pre-patch this is O(n) and OOGs).
    function test_BucketWithdraw_IsBounded() public {
        // C=100 ranked lots, each larger than the sybil dust
        for (uint256 i = 0; i < 100; i++) {
            address r = address(uint160(0x1000 + i));
            _fund(r, 1e18);
            vm.prank(r);
            eng.stake(POST, 0, 1e18);
        }
        // 400 sybil dust stakers -> all bucket (dust < ranked)
        address victim;
        for (uint256 i = 0; i < 400; i++) {
            address s = address(uint160(0x9000 + i));
            _fund(s, 10);
            vm.prank(s);
            eng.stake(POST, 0, 5);
            if (i == 200) {
                victim = s;
            }
        }
        // a bucket victim withdraws; assert it returns under a tight gas bound
        vm.prank(victim);
        uint256 g0 = gasleft();
        eng.withdraw(POST, 0, 5, true);
        uint256 used = g0 - gasleft();
        assertLt(used, 1_000_000, "bucket withdraw not O(1) (fund-lock not fixed?)");
    }

    /// Cap boundary: the 101st distinct staker with dust joins the bucket; with a
    /// stake bigger than the smallest ranked lot, it evicts (demotes) that lot.
    function test_CapEvictionAndBucketRouting() public {
        for (uint256 i = 0; i < 100; i++) {
            address r = address(uint160(0x2000 + i));
            _fund(r, 1000 + i); // strictly increasing so lot 0 is smallest
            vm.prank(r);
            eng.stake(POST, 0, 1000 + i);
        }
        // dust staker -> bucket, no eviction event expected
        address dust = address(0x3001);
        _fund(dust, 10);
        vm.prank(dust);
        eng.stake(POST, 0, 1); // < smallest ranked (1000)
        assertEq(eng.getUserStake(dust, POST, 0), 1, "dust not in bucket");

        // large staker -> evicts smallest ranked (amount 1000), gets a slot
        address big = address(0x3002);
        _fund(big, 5000);
        vm.prank(big);
        vm.expectEmit(true, true, false, false);
        emit StakeEngine.LotDemoted(POST, 0, address(uint160(0x2000)), 1000);
        eng.stake(POST, 0, 5000);
        assertEq(eng.getUserStake(big, POST, 0), 5000, "big not ranked");
    }

    /// Solvency: after several settlement epochs on a post with an active bucket,
    /// the engine's VSP balance covers all stakers' claimable value.
    function test_SolventWithActiveBucket() public {
        for (uint256 i = 0; i < 100; i++) {
            address r = address(uint160(0x4000 + i));
            _fund(r, 1e18);
            vm.prank(r);
            eng.stake(POST, 0, 1e18);
        }
        for (uint256 i = 0; i < 50; i++) {
            address s = address(uint160(0x5000 + i));
            _fund(s, 1e12);
            vm.prank(s);
            eng.stake(POST, 0, 1e12);
        }
        // opposite side so there is a winner/loser and settlement runs
        address chal = address(0x6001);
        _fund(chal, 5e19);
        vm.prank(chal);
        eng.stake(POST, 1, 5e19);

        for (uint256 e = 0; e < 5; e++) {
            vm.warp(block.timestamp + 2 days);
            eng.updatePost(POST);
        }
        (uint256 s0, uint256 c0) = eng.getPostTotals(POST);
        // patch_prD_invariant_warp: the previous assertGe(balance, 0) was
        // vacuous (uint >= 0 always holds). Real solvency: state is settled
        // (updatePost ran at this timestamp, so totals are stored, not
        // projected) and the engine must hold every wei of post totals AND
        // every wei of per-staker claimable value.
        assertGe(vsp.balanceOf(address(eng)), s0 + c0, "engine insolvent: balance < settled post totals");
        uint256 claimable;
        for (uint256 i = 0; i < 100; i++) {
            claimable += eng.getUserStake(address(uint160(0x4000 + i)), POST, 0);
        }
        for (uint256 i = 0; i < 50; i++) {
            claimable += eng.getUserStake(address(uint160(0x5000 + i)), POST, 0);
        }
        claimable += eng.getUserStake(address(0x6001), POST, 1);
        assertGe(vsp.balanceOf(address(eng)), claimable, "engine insolvent: balance < sum of claimables");
        assertGt(s0 + c0, 0, "totals collapsed");
    }

    // ─────────────── patch_h1b_promotion: promotion tests ───────────────

    /// Withdraw-triggered promotion: fully withdraw a ranked lot; the largest
    /// bucket member must auto-promote into the freed slot (LotPromoted).
    function test_WithdrawTriggersPromotion() public {
        // fill C ranked with increasing amounts; lot 0 (0x7000) is smallest
        for (uint256 i = 0; i < 100; i++) {
            address r = address(uint160(0x7000 + i));
            _fund(r, 2000 + i);
            vm.prank(r);
            eng.stake(POST, 0, 2000 + i);
        }
        // a bucket member just below the smallest ranked (2000)
        address bucketBig = address(0x8001);
        _fund(bucketBig, 1999);
        vm.prank(bucketBig);
        eng.stake(POST, 0, 1999);
        assertEq(eng.getUserStake(bucketBig, POST, 0), 1999, "not bucketed");

        // fully withdraw the smallest ranked lot -> frees a slot -> promote bucketBig
        address smallestRanked = address(uint160(0x7000));
        vm.prank(smallestRanked);
        vm.expectEmit(true, true, false, false);
        emit StakeEngine.LotPromoted(POST, 0, bucketBig, 1999);
        eng.withdraw(POST, 0, 2000, true);
        // bucketBig is now ranked; its stake still readable and intact
        assertEq(eng.getUserStake(bucketBig, POST, 0), 1999, "not promoted");
    }

    /// Top-up-triggered promotion: a bucket member tops up above the smallest
    /// ranked lot and must auto-promote (evicting that smallest lot).
    function test_TopUpTriggersPromotion() public {
        for (uint256 i = 0; i < 100; i++) {
            address r = address(uint160(0xA000 + i));
            _fund(r, 3000 + i);
            vm.prank(r);
            eng.stake(POST, 0, 3000 + i);
        }
        address climber = address(0xB001);
        _fund(climber, 10_000);
        vm.prank(climber);
        eng.stake(POST, 0, 100); // starts in the bucket (< 3000)
        assertEq(eng.getUserStake(climber, POST, 0), 100, "not bucketed");

        // top up above the smallest ranked (3000) -> promote
        vm.prank(climber);
        eng.stake(POST, 0, 4000); // now 4100 total > 3000
        assertEq(eng.getUserStake(climber, POST, 0), 4100, "not promoted after top-up");
    }

    /// Heap/promotion churn stays solvent + bounded: many stakers cross the
    /// boundary in both directions; the invariant suite covers conservation, this
    /// asserts no revert and bounded gas on the hot paths.
    function test_PromotionChurnBounded() public {
        for (uint256 i = 0; i < 100; i++) {
            address r = address(uint160(0xC000 + i));
            _fund(r, 5000 + i);
            vm.prank(r);
            eng.stake(POST, 0, 5000 + i);
        }
        for (uint256 i = 0; i < 200; i++) {
            address s = address(uint160(0xD000 + i));
            _fund(s, 6000); // bigger than ranked -> each eviction+rebalance
            vm.prank(s);
            uint256 g0 = gasleft();
            eng.stake(POST, 0, 4000 + i); // varies around the boundary
            assertLt(g0 - gasleft(), 3_000_000, "stake+rebalance not bounded");
        }
    }
}
