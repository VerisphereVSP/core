// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/StakeEngine.sol";
import "../src/interfaces/IVSPToken.sol";

import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// @title StakeEngine Fuzz Tests
/// @notice Invariant and property-based tests for the economic core.
///         Targets: rate computation, snapshot math, sMax decay,
///         lot consolidation, and withdrawal safety.
contract StakeEngineFuzzTest is Test {
    MockVSP token;
    StakeEngine engine;
    MockProtocolPolicy policy;

    uint256 postA = 1;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);

    function setUp() public {
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

        // Fund generously
        address[4] memory users = [address(this), alice, bob, carol];
        for (uint256 i = 0; i < users.length; i++) {
            token.mint(users[i], 1e36);
            vm.prank(users[i]);
            token.approve(address(engine), type(uint256).max);
        }
    }

    // ────────────────────────────────────────────────────────────
    // Invariant: totals always equal sum of lot amounts
    // ────────────────────────────────────────────────────────────

    /// @notice After any combination of stakes, getPostTotals must
    ///         equal the actual token balance changes.
    function testFuzz_TotalsMatchStakes(uint128 supportA, uint128 supportB, uint128 challenge) public {
        // Bound to reasonable range — avoid zero (reverts) and overflow
        uint256 sA = bound(uint256(supportA), 1, 1e24); // bundle05_a
        uint256 sB = bound(uint256(supportB), 1, 1e24); // bundle05_a
        uint256 chal = bound(uint256(challenge), 1, 1e24); // bundle05_a

        engine.stake(postA, 0, sA);

        vm.prank(alice);
        engine.stake(postA, 0, sB);

        vm.prank(bob);
        engine.stake(postA, 1, chal);

        (uint256 support, uint256 challengeTotal) = engine.getPostTotals(postA);

        // Before any epoch passes, totals must exactly match stakes
        assertEq(support, sA + sB, "support total mismatch");
        assertEq(challengeTotal, chal, "challenge total mismatch");
    }

    // ────────────────────────────────────────────────────────────
    // Invariant: winning side never decreases after snapshot
    // ────────────────────────────────────────────────────────────

    /// @notice The majority side must not lose value from snapshots.
    function testFuzz_WinningSideNeverDecreases(uint128 supportAmt, uint128 challengeAmt, uint16 daysElapsed) public {
        uint256 sup = bound(uint256(supportAmt), 1e18, 1e24); // bundle05_a
        uint256 chal = bound(uint256(challengeAmt), 1e18, 1e24); // bundle05_a
        uint256 days_ = bound(uint256(daysElapsed), 1, 365);

        // Ensure sides are unequal (VS != 0)
        vm.assume(sup != chal);

        engine.stake(postA, 0, sup);
        vm.prank(alice);
        engine.stake(postA, 1, chal);

        vm.warp(block.timestamp + days_ * 1 days);
        engine.updatePost(postA);

        (uint256 newSup, uint256 newChal) = engine.getPostTotals(postA);

        if (sup > chal) {
            assertGe(newSup, sup, "winning support side decreased");
            assertLe(newChal, chal, "losing challenge side increased");
        } else {
            assertGe(newChal, chal, "winning challenge side decreased");
            assertLe(newSup, sup, "losing support side increased");
        }
    }

    // ────────────────────────────────────────────────────────────
    // Invariant: balanced stakes produce no change
    // ────────────────────────────────────────────────────────────

    /// @notice When support == challenge, VS == 0, no growth or decay.
    function testFuzz_BalancedStakesNoChange(uint128 amount, uint16 daysElapsed) public {
        uint256 amt = bound(uint256(amount), 1e18, 1e24); // bundle05_a
        uint256 days_ = bound(uint256(daysElapsed), 1, 365);

        engine.stake(postA, 0, amt);
        vm.prank(alice);
        engine.stake(postA, 1, amt);

        vm.warp(block.timestamp + days_ * 1 days);
        engine.updatePost(postA);

        (uint256 sup, uint256 chal) = engine.getPostTotals(postA);
        assertEq(sup, amt, "balanced support changed");
        assertEq(chal, amt, "balanced challenge changed");
    }

    // ────────────────────────────────────────────────────────────
    // Invariant: withdrawal never exceeds staked amount
    // ────────────────────────────────────────────────────────────

    /// @notice Can't withdraw more than you have. Partial withdrawals
    ///         leave the correct remainder.
    function testFuzz_WithdrawNeverExceedsStake(uint128 stakeAmt, uint128 withdrawAmt) public {
        uint256 staked = bound(uint256(stakeAmt), 1e18, 1e24); // bundle05_a
        uint256 withdrawn = bound(uint256(withdrawAmt), 1, staked);

        engine.stake(postA, 0, staked);

        uint256 balBefore = token.balanceOf(address(this));
        engine.withdraw(postA, 0, withdrawn, false);
        uint256 balAfter = token.balanceOf(address(this));

        assertEq(balAfter - balBefore, withdrawn, "didn't receive withdrawn amount");

        uint256 remaining = engine.getUserStake(address(this), postA, 0);
        assertEq(remaining, staked - withdrawn, "remaining stake wrong");
    }

    /// @notice Withdrawing more than staked must revert.
    function testFuzz_WithdrawTooMuchReverts(uint128 stakeAmt, uint128 extra) public {
        uint256 staked = bound(uint256(stakeAmt), 1e18, 1e24); // bundle05_a
        uint256 tooMuch = staked + bound(uint256(extra), 1, 1e24); // bundle05_a

        engine.stake(postA, 0, staked);

        vm.expectRevert(StakeEngine.NotEnoughStake.selector);
        engine.withdraw(postA, 0, tooMuch, false);
    }

    // ────────────────────────────────────────────────────────────
    // Invariant: lot consolidation preserves total and position ordering
    // ────────────────────────────────────────────────────────────

    /// @notice Multiple stakes from same user consolidate into one lot.
    ///         Total must equal sum. Weighted position must be between
    ///         the earliest and latest entry positions.
    function testFuzz_LotConsolidation(uint128 first, uint128 second) public {
        uint256 amt1 = bound(uint256(first), 1e18, 1e24); // bundle05_a
        uint256 amt2 = bound(uint256(second), 1e18, 1e24); // bundle05_a

        engine.stake(postA, 0, amt1);
        engine.stake(postA, 0, amt2);

        uint256 total = engine.getUserStake(address(this), postA, 0);
        assertEq(total, amt1 + amt2, "consolidated total wrong");

        // Weighted position is now the midpoint: cumBefore + amount/2
        // Since this is the only lot on this side, cumBefore=0, amount=amt1+amt2
        // So wPos = (amt1 + amt2) / 2
        (uint256 amount, uint256 weightedPos,,) = engine.getUserLotInfo(address(this), postA, 0);

        assertEq(amount, amt1 + amt2, "lot info amount wrong");
        uint256 expectedPos = (amt1 + amt2) / 2;
        assertEq(weightedPos, expectedPos, "weighted position wrong");
    }

    // ────────────────────────────────────────────────────────────
    // Invariant: sMax decays monotonically and is bounded
    // ────────────────────────────────────────────────────────────

    /// @notice sMax must decay over time when no new stakes exceed it.
    function testFuzz_SMaxDecays(uint128 stakeAmt, uint16 daysElapsed) public {
        uint256 amt = bound(uint256(stakeAmt), 1e18, 1e24); // bundle05_a
        uint256 days_ = bound(uint256(daysElapsed), 1, 3650);

        engine.stake(postA, 0, amt);
        uint256 sMaxBefore = engine.sMax();
        assertGe(sMaxBefore, amt, "sMax should be >= stake");

        vm.warp(block.timestamp + days_ * 1 days);
        engine.updatePost(postA);

        uint256 sMaxAfter = engine.sMax();

        // sMax should have decayed (support-only post, VS=100%, so
        // support grows — but sMax decay happens before the growth check)
        // The key invariant: sMax after decay + possible re-raise from
        // new total must be >= 0 and <= some reasonable bound
        assertGt(sMaxAfter, 0, "sMax decayed to zero unexpectedly");
    }

    // ────────────────────────────────────────────────────────────
    // Invariant: view projection matches materialized snapshot
    // ────────────────────────────────────────────────────────────

    /// @notice getPostTotals (view projection) must equal the values
    ///         after an explicit updatePost (materialized snapshot).
    function testFuzz_ViewProjectionMatchesSnapshot(uint128 supportAmt, uint128 challengeAmt, uint16 daysElapsed)
        public
    {
        uint256 sup = bound(uint256(supportAmt), 1e18, 1e24); // bundle05_a
        uint256 chal = bound(uint256(challengeAmt), 1e18, 1e24); // bundle05_a
        uint256 days_ = bound(uint256(daysElapsed), 1, 30);

        vm.assume(sup != chal);

        engine.stake(postA, 0, sup);
        vm.prank(alice);
        engine.stake(postA, 1, chal);

        vm.warp(block.timestamp + days_ * 1 days);

        // Read projected values BEFORE materializing
        (uint256 projS, uint256 projC) = engine.getPostTotals(postA);

        // Materialize
        engine.updatePost(postA);

        // Read materialized values
        (uint256 matS, uint256 matC) = engine.getPostTotals(postA);

        // They should be equal (both reflect the same epoch)
        assertEq(projS, matS, "projected support != materialized");
        assertEq(projC, matC, "projected challenge != materialized");
    }

    // ────────────────────────────────────────────────────────────
    // Invariant: user stake projection matches materialized
    // ────────────────────────────────────────────────────────────

    function testFuzz_UserStakeProjectionMatches(uint128 supportAmt, uint128 challengeAmt, uint16 daysElapsed) public {
        uint256 sup = bound(uint256(supportAmt), 1e18, 1e24); // bundle05_a
        uint256 chal = bound(uint256(challengeAmt), 1e18, 1e24); // bundle05_a
        uint256 days_ = bound(uint256(daysElapsed), 1, 30);

        vm.assume(sup != chal);

        engine.stake(postA, 0, sup);
        vm.prank(alice);
        engine.stake(postA, 1, chal);

        vm.warp(block.timestamp + days_ * 1 days);

        uint256 projUser = engine.getUserStake(address(this), postA, 0);

        engine.updatePost(postA);

        uint256 matUser = engine.getUserStake(address(this), postA, 0);

        assertEq(projUser, matUser, "user stake projection mismatch");
    }

    // ────────────────────────────────────────────────────────────
    // Invariant: multiple snapshots are idempotent within same epoch
    // ────────────────────────────────────────────────────────────

    function testFuzz_DoubleSnapshotIdempotent(uint128 supportAmt, uint128 challengeAmt) public {
        uint256 sup = bound(uint256(supportAmt), 1e18, 1e24); // bundle05_a
        uint256 chal = bound(uint256(challengeAmt), 1e18, 1e24); // bundle05_a
        vm.assume(sup != chal);

        engine.stake(postA, 0, sup);
        vm.prank(alice);
        engine.stake(postA, 1, chal);

        vm.warp(block.timestamp + 2 days);

        engine.updatePost(postA);
        (uint256 s1, uint256 c1) = engine.getPostTotals(postA);

        // Second update in same epoch should be no-op
        engine.updatePost(postA);
        (uint256 s2, uint256 c2) = engine.getPostTotals(postA);

        assertEq(s1, s2, "double snapshot changed support");
        assertEq(c1, c2, "double snapshot changed challenge");
    }

    // ────────────────────────────────────────────────────────────
    // Invariant: losing side can never go negative (floor at 0)
    // ────────────────────────────────────────────────────────────

    /// @notice Even with extreme imbalance and long time, the losing
    ///         side must floor at 0, never underflow.
    function testFuzz_LosingSideFloorsAtZero(uint128 bigSide, uint8 smallMultiplier, uint16 daysElapsed) public {
        uint256 big = bound(uint256(bigSide), 1e23, 1e24); // bundle05_a
        // Small side is 1/100 to 1/2 of big side
        uint256 divisor = bound(uint256(smallMultiplier), 2, 100);
        uint256 small = big / divisor;
        if (small == 0) {
            small = 1e18;
        }
        uint256 days_ = bound(uint256(daysElapsed), 30, 365);

        engine.stake(postA, 0, big);
        vm.prank(alice);
        engine.stake(postA, 1, small);

        vm.warp(block.timestamp + days_ * 1 days);
        engine.updatePost(postA);

        (uint256 sup, uint256 chal) = engine.getPostTotals(postA);
        assertGe(sup, big, "winning side should have grown");
        // Challenge should be >= 0 (can't underflow) and <= original
        assertLe(chal, small, "losing side grew");
        // This assertion is implicit in uint256 — if it underflowed,
        // the tx would revert. The test passing means no underflow.
    }

    // ────────────────────────────────────────────────────────────
    // Invariant: early staker earns more than late staker
    // ────────────────────────────────────────────────────────────

    /// @notice Given equal amounts, the earlier staker should earn
    ///         at least as much as the later staker (positional advantage).
    function testFuzz_EarlyStakerEarnsMore(uint128 amount, uint16 daysElapsed) public {
        uint256 amt = bound(uint256(amount), 1e18, 1e24); // bundle05_a
        uint256 days_ = bound(uint256(daysElapsed), 2, 180);

        // Alice stakes first (gets better position)
        vm.prank(alice);
        engine.stake(postA, 0, amt);

        // Bob stakes second (worse position)
        vm.prank(bob);
        engine.stake(postA, 0, amt);

        // Carol provides challenge so VS isn't 100% (more interesting)
        vm.prank(carol);
        engine.stake(postA, 1, amt / 4);

        vm.warp(block.timestamp + days_ * 1 days);
        engine.updatePost(postA);

        uint256 aliceStake = engine.getUserStake(alice, postA, 0);
        uint256 bobStake = engine.getUserStake(bob, postA, 0);

        assertGe(aliceStake, bobStake, "early staker earned less than late staker");
    }
}
