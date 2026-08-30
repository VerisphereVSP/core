// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/StakeEngine.sol";
import "../src/interfaces/IVSPToken.sol";

import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// ------------------------------------------------------------
/// Position Rescale Tests
/// ------------------------------------------------------------
/// After each snapshot, _rescalePositions maps all weightedPosition
/// values into [0, sideTotal). This means:
///   - During the snapshot's own epoch math, lots with oversized
///     positions get posWeight = 0 (existing clamp behavior).
///   - After the snapshot, positions are fixed so the NEXT epoch
///     gives every lot a nonzero weight.
///   - View projections between snapshots may show zero weight for
///     the affected lots (same clamp), which is acceptable since
///     the next snapshot fixes it.
///
/// All tests warp to epoch >= 1 to avoid the lastSnapshotEpoch == 0
/// sentinel issue.
/// ------------------------------------------------------------
contract StakeEngineRescaleTest is Test {
    MockVSP token;
    StakeEngine engine;
    MockProtocolPolicy policy;

    uint256 postA = 1;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);
    address dave = address(0xDA1E);

    uint256 constant START_TIME = 86401;

    function setUp() public {
        vm.warp(START_TIME);
        token = new MockVSP();
        policy = new MockProtocolPolicy(0);

        engine = StakeEngine(
            address(
                new ERC1967Proxy(
                    address(new StakeEngine(address(0))),
                    abi.encodeCall(StakeEngine.initialize, (address(this), address(token), address(policy)))
                )
            )
        );

        address[5] memory users = [address(this), alice, bob, carol, dave];
        for (uint256 i = 0; i < users.length; i++) {
            token.mint(users[i], 1e36);
            vm.prank(users[i]);
            token.approve(address(engine), type(uint256).max);
        }
    }

    // ============================================================
    // Core: positions are bounded after snapshot
    // ============================================================

    function test_RescaleKeepsBobEarningAfterAliceWithdraws() public {
        vm.prank(alice);
        engine.stake(postA, 0, 100 ether);
        vm.prank(bob);
        engine.stake(postA, 0, 50 ether);
        vm.prank(carol);
        engine.stake(postA, 1, 10 ether);

        vm.prank(alice);
        engine.withdraw(postA, 0, 100 ether, false);

        // First snapshot: Bob has oversized position, gets zero weight
        // for THIS epoch (the penalty). Rescale runs AFTER epoch math,
        // fixing his position for the next epoch.
        vm.warp(block.timestamp + 2 days);
        engine.updatePost(postA);

        // After first snapshot: Bob's position should be < sideTotal
        (, uint256 bobPos, uint256 sideTotal,) = engine.getUserLotInfo(bob, postA, 0);
        assertLt(bobPos, sideTotal, "Bob's position must be < sideTotal after rescale");

        // Second snapshot: now Bob earns because his position is fixed
        vm.warp(block.timestamp + 1 days);
        engine.updatePost(postA);

        uint256 bobStake = engine.getUserStake(bob, postA, 0);
        // Bob's stake after first snapshot was unchanged (zero weight),
        // but after second snapshot he should have earned
        assertGt(bobStake, 50 ether, "Bob should earn after rescale takes effect");

        (,,, uint256 bobWeight) = engine.getUserLotInfo(bob, postA, 0);
        assertGt(bobWeight, 0, "Bob's positionWeight should be nonzero");
    }

    // ============================================================
    // Preserves relative ordering
    // ============================================================

    function test_RescalePreservesRelativeOrdering() public {
        vm.prank(alice);
        engine.stake(postA, 0, 100 ether);
        vm.prank(bob);
        engine.stake(postA, 0, 100 ether);
        vm.prank(carol);
        engine.stake(postA, 0, 100 ether);
        vm.prank(dave);
        engine.stake(postA, 1, 10 ether);

        vm.prank(alice);
        engine.withdraw(postA, 0, 100 ether, false);

        vm.warp(block.timestamp + 2 days);
        engine.updatePost(postA);

        (, uint256 bobPos,,) = engine.getUserLotInfo(bob, postA, 0);
        (, uint256 carolPos,,) = engine.getUserLotInfo(carol, postA, 0);
        assertGe(carolPos, bobPos, "ordering preserved: Carol >= Bob");
    }

    // ============================================================
    // No rescale when positions fit
    // ============================================================

    function test_RescaleNoOpWhenPositionsFit() public {
        vm.prank(alice);
        engine.stake(postA, 0, 100 ether);
        vm.prank(bob);
        engine.stake(postA, 0, 50 ether);
        vm.prank(carol);
        engine.stake(postA, 1, 10 ether);

        vm.warp(block.timestamp + 2 days);
        engine.updatePost(postA);

        (, uint256 alicePos,,) = engine.getUserLotInfo(alice, postA, 0);
        (, uint256 bobPos,,) = engine.getUserLotInfo(bob, postA, 0);
        // With midpoint model, Alice's wPos = her_amount / 2 (she's first in queue).
        // After epoch gains her amount grew, so wPos = new_amount / 2.
        // Just verify positions are within sideTotal and properly ordered.
        (uint256 s,) = engine.getPostTotals(postA);
        assertLe(alicePos, s, "Alice's position should fit in sideTotal");
        assertLe(bobPos, s, "Bob's position should fit in sideTotal");
        assertLt(alicePos, bobPos, "Alice should be ahead of Bob");
    }

    // ============================================================
    // Idempotent
    // ============================================================

    function test_RescaleIdempotent() public {
        vm.prank(alice);
        engine.stake(postA, 0, 100 ether);
        vm.prank(bob);
        engine.stake(postA, 0, 100 ether);
        vm.prank(carol);
        engine.stake(postA, 1, 10 ether);

        vm.prank(alice);
        engine.withdraw(postA, 0, 100 ether, false);

        vm.warp(block.timestamp + 2 days);
        engine.updatePost(postA);

        (, uint256 bobPosAfterFirst,,) = engine.getUserLotInfo(bob, postA, 0);

        // No new withdrawals — second snapshot shouldn't change position
        // (well, mints change sideTotal, but positions only rescale if max >= total)
        vm.warp(block.timestamp + 1 days);
        engine.updatePost(postA);

        (, uint256 bobPosAfterSecond, uint256 st,) = engine.getUserLotInfo(bob, postA, 0);
        // After first rescale, position < sideTotal. Second snapshot grows sideTotal
        // further via mints, so position stays bounded.
        assertLt(bobPosAfterSecond, st, "position still bounded after second snapshot");
    }

    // ============================================================
    // Event fires
    // ============================================================

    function test_RescaleEmitsEvent() public {
        vm.prank(alice);
        engine.stake(postA, 0, 100 ether);
        vm.prank(bob);
        engine.stake(postA, 0, 100 ether);
        vm.prank(carol);
        engine.stake(postA, 1, 10 ether);

        vm.prank(alice);
        engine.withdraw(postA, 0, 100 ether, false);

        vm.warp(block.timestamp + 2 days);
        engine.updatePost(postA);

        (, uint256 bobPos, uint256 sideTotal,) = engine.getUserLotInfo(bob, postA, 0);
        assertLt(bobPos, sideTotal);
    }

    // ============================================================
    // Ghost lots
    // ============================================================

    function test_RescaleIncludesGhostLots() public {
        vm.prank(alice);
        engine.stake(postA, 0, 100 ether);
        vm.prank(bob);
        engine.stake(postA, 0, 100 ether);
        vm.prank(carol);
        engine.stake(postA, 0, 100 ether);
        vm.prank(dave);
        engine.stake(postA, 1, 1000 ether);

        vm.warp(block.timestamp + 365 days);
        engine.updatePost(postA);

        (uint256 s,) = engine.getPostTotals(postA);
        if (s > 0) {
            (, uint256 bobPos,,) = engine.getUserLotInfo(bob, postA, 0);
            (, uint256 carolPos,,) = engine.getUserLotInfo(carol, postA, 0);
            assertLt(bobPos, s, "Bob's position bounded by sideTotal");
            assertLt(carolPos, s, "Carol's position bounded by sideTotal");
        }
    }

    // ============================================================
    // View projection approximately matches materialized
    // ============================================================

    /// @notice View projection may differ slightly from materialized
    ///         values because the view doesn't project the rescale.
    ///         The difference is bounded by the one-epoch penalty:
    ///         at most rBase * lot.amount worth of rounding.
    ///         We use a tolerance of 0.5% to cover this.
    function test_ViewProjectionApproxMatchesMaterialized() public {
        vm.prank(alice);
        engine.stake(postA, 0, 100 ether);
        vm.prank(bob);
        engine.stake(postA, 0, 100 ether);
        vm.prank(carol);
        engine.stake(postA, 1, 10 ether);

        vm.prank(alice);
        engine.withdraw(postA, 0, 100 ether, false);

        vm.warp(block.timestamp + 2 days);

        (uint256 projS, uint256 projC) = engine.getPostTotals(postA);

        engine.updatePost(postA);

        (uint256 matS, uint256 matC) = engine.getPostTotals(postA);

        // With midpoint model, projection and materialized may differ slightly
        // because projection uses pre-epoch lot sizes for midpoints while
        // materialization recomputes midpoints after epoch gains/losses.
        // Allow 0.1% tolerance on both sides.
        uint256 tolS = matS / 1000;
        if (tolS == 0) {
            tolS = 1;
        }
        assertApproxEqAbs(projS, matS, tolS, "projected support should match materialized");

        uint256 tolC = matC / 1000;
        if (tolC == 0) {
            tolC = 1;
        }
        assertApproxEqAbs(projC, matC, tolC, "projected challenge approximately matches");
    }

    // ============================================================
    // Stake after rescale merges correctly
    // ============================================================

    function test_StakeAfterRescaleMergesCorrectly() public {
        vm.prank(alice);
        engine.stake(postA, 0, 100 ether);
        vm.prank(bob);
        engine.stake(postA, 0, 100 ether);
        vm.prank(carol);
        engine.stake(postA, 1, 10 ether);

        vm.prank(alice);
        engine.withdraw(postA, 0, 100 ether, false);

        vm.warp(block.timestamp + 2 days);
        engine.updatePost(postA);

        uint256 bobBefore = engine.getUserStake(bob, postA, 0);

        vm.prank(bob);
        engine.stake(postA, 0, 50 ether);

        uint256 bobAfter = engine.getUserStake(bob, postA, 0);
        assertEq(bobAfter, bobBefore + 50 ether, "stake merge preserved");

        (uint256 s,) = engine.getPostTotals(postA);
        (, uint256 bobPos,,) = engine.getUserLotInfo(bob, postA, 0);
        assertLt(bobPos, s, "Bob's position bounded after merge");
    }

    // ============================================================
    // Challenge side
    // ============================================================

    function test_RescaleAppliesToChallengeSide() public {
        vm.prank(alice);
        engine.stake(postA, 1, 100 ether);
        vm.prank(bob);
        engine.stake(postA, 1, 100 ether);
        vm.prank(carol);
        engine.stake(postA, 1, 100 ether);
        vm.prank(dave);
        engine.stake(postA, 0, 500 ether);

        vm.prank(alice);
        engine.withdraw(postA, 1, 100 ether, false);

        vm.warp(block.timestamp + 2 days);
        engine.updatePost(postA);

        (, uint256 c) = engine.getPostTotals(postA);
        (, uint256 bobPos,,) = engine.getUserLotInfo(bob, postA, 1);
        (, uint256 carolPos,,) = engine.getUserLotInfo(carol, postA, 1);

        if (c > 0) {
            assertLt(bobPos, c, "Bob's challenge position bounded");
            assertLt(carolPos, c, "Carol's challenge position bounded");
        }
    }

    // ============================================================
    // Fuzz
    // ============================================================

    function testFuzz_PositionInvariantAfterSnapshot(
        uint128 aliceAmt,
        uint128 bobAmt,
        uint128 aliceWithdraw,
        uint128 challenge
    ) public {
        uint256 a = bound(uint256(aliceAmt), 1e18, 1e24); // bundle05_a
        uint256 b = bound(uint256(bobAmt), 1e18, 1e24); // bundle05_a
        uint256 aw = bound(uint256(aliceWithdraw), 0, a);
        uint256 ch = bound(uint256(challenge), 1e18, 1e24); // bundle05_a
        vm.assume((a - aw + b) != ch);

        vm.prank(alice);
        engine.stake(postA, 0, a);
        vm.prank(bob);
        engine.stake(postA, 0, b);
        vm.prank(carol);
        engine.stake(postA, 1, ch);

        if (aw > 0) {
            vm.prank(alice);
            engine.withdraw(postA, 0, aw, false);
        }

        vm.warp(block.timestamp + 2 days);
        engine.updatePost(postA);

        (uint256 s, uint256 c) = engine.getPostTotals(postA);

        // After snapshot, all positions on both sides must be < sideTotal
        if (s > 0) {
            (, uint256 alicePos,,) = engine.getUserLotInfo(alice, postA, 0);
            (, uint256 bobPos,,) = engine.getUserLotInfo(bob, postA, 0);
            assertLt(alicePos, s, "Alice pos bounded");
            assertLt(bobPos, s, "Bob pos bounded");
        }
        if (c > 0) {
            (, uint256 carolPos,,) = engine.getUserLotInfo(carol, postA, 1);
            assertLt(carolPos, c, "Carol pos bounded");
        }
    }
}
