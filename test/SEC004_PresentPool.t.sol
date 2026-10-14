// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./base/SnapshotBase.sol";

/// VSP-SEC-004 (reported 2026-10-14): the settlement pool was the window AVERAGE of the side totals, while
/// gains and losses were applied only to lots open at the window end. A 100,000-VSP stake placed at the
/// start of a one-day window and withdrawn after 12 h recovered in full and still moved a near-balanced
/// post's settlement 36x (0.3183 vs 0.00878 VSP on a 1,000-VSP stayer); in a second setup it flipped the
/// winner. Ruling (2026-10-14, Lavey; option A): the pool is the capital PRESENT at settlement, each lot
/// prorated by presence — the same rule as the payouts — and withdrawals stay immediate. The reporter's
/// three scenarios are reproduced with the assertions inverted: attack post == control post.
contract SEC004_PresentPool is SnapshotBase {
    function _twin(string memory tag, uint256 sa, uint256 sb, uint256 c) internal returns (uint256 atk, uint256 ctl) {
        atk = _claim(string.concat(tag, " atk"));
        ctl = _claim(string.concat(tag, " ctl"));
        for (uint256 i = 0; i < 2; i++) {
            uint256 p = i == 0 ? atk : ctl;
            _stake(A, p, 0, sa);
            _stake(B, p, 0, sb);
            _stake(C, p, 1, c);
        }
    }

    function _assertClose(uint256 a, uint256 b, string memory what) internal pure {
        // within 1e-6 relative (rounding of the presence fraction), both directions
        uint256 hi = a > b ? a : b;
        uint256 lo = a > b ? b : a;
        assertLe(hi - lo, hi / 1_000_000 + 1, what);
    }

    /// Scenario 1: transient 100k support for half the window, withdrawn whole; stayers settle like the control.
    function test_SEC004_transientHalfWindowHasNoSay() public {
        (uint256 atk, uint256 ctl) = _twin("s1", 1000e18, 1000e18, 1900e18);
        uint256 dBal0 = vsp.balanceOf(D);
        _stake(D, atk, 0, 100_000e18);
        vm.warp(block.timestamp + 12 hours);
        _withdraw(D, atk, 0, 100_000e18);
        assertEq(vsp.balanceOf(D), dBal0, "withdrawals stay immediate and whole (ruling: no unbonding)");
        _nextEpoch();
        _keeperPass();
        _assertClose(se.getUserStake(B, atk, 0), se.getUserStake(B, ctl, 0), "stayer B settles like the control");
        _assertClose(se.getUserStake(C, atk, 1), se.getUserStake(C, ctl, 1), "victim C settles like the control");
    }

    /// Scenario 2: the transient leaves one second before the window closes — still no say.
    function test_SEC004_transientExitAtWindowEndHasNoSay() public {
        (uint256 atk, uint256 ctl) = _twin("s2", 1000e18, 1000e18, 1900e18);
        _stake(D, atk, 0, 100_000e18);
        vm.warp(block.timestamp + 1 days - 1 seconds);
        _withdraw(D, atk, 0, 100_000e18);
        _nextEpoch();
        _keeperPass();
        _assertClose(se.getUserStake(B, atk, 0), se.getUserStake(B, ctl, 0), "stayer B settles like the control");
        _assertClose(se.getUserStake(C, atk, 1), se.getUserStake(C, ctl, 1), "victim C settles like the control");
    }

    /// Scenario 3: honest challenge majority (1,100 vs 1,000); the transient can no longer flip the winner.
    function test_SEC004_transientCannotFlipWinner() public {
        (uint256 atk, uint256 ctl) = _twin("s3", 900e18, 100e18, 1100e18);
        _stake(D, atk, 0, 100_000e18);
        vm.warp(block.timestamp + 12 hours);
        _withdraw(D, atk, 0, 100_000e18);
        _nextEpoch();
        _keeperPass();
        assertLt(se.getUserStake(B, atk, 0), 100e18, "attack post: support loses, as the honest majority says");
        assertGt(se.getUserStake(C, atk, 1), 1100e18, "attack post: the challenge majority gains");
        _assertClose(se.getUserStake(B, atk, 0), se.getUserStake(B, ctl, 0), "same outcome as the control");
        _assertClose(se.getUserStake(C, atk, 1), se.getUserStake(C, ctl, 1), "same outcome as the control");
    }

    /// Presence proration: capital that STAYS counts for the share of the window it was present —
    /// a late joiner that stays counts in proportion (it also bears a prorated settlement).
    function test_SEC004_lateCapitalCountsByPresence() public {
        uint256 p = _claim("s4");
        _stake(A, p, 0, 1000e18);
        _stake(C, p, 1, 1000e18);
        _nextEpoch();
        _keeperPass(); // window 1 settled with 1000/1000
        uint256 t0 = se.getLastSnapshotEpoch(p) * EPOCH;
        vm.warp(t0 + 18 hours);
        _stake(D, p, 0, 4000e18); // present for the last quarter of the window
        vm.warp(t0 + EPOCH);
        (uint256 S, uint256 Cc) = se.getTimeWeightedTotals(p, t0, t0 + EPOCH);
        assertEq(Cc, 1000e18, "challenge present all window");
        assertEq(S, 1000e18 + 1000e18, "late support counts 4000 x 1/4 = 1000");
        // and a view with t1 <= t0 is the live total (governance seed path)
        (uint256 live,) = se.getTimeWeightedTotals(p, 0, 0);
        assertEq(live, 5000e18);
    }

    /// Flash evidence stays worthless: a stake placed seconds before settlement has ~zero presence.
    function test_SEC004_flashStakeHasNoWeight() public {
        uint256 p = _claim("s5");
        _stake(A, p, 0, 1000e18);
        _stake(C, p, 1, 1100e18);
        _nextEpoch();
        _keeperPass();
        uint256 t0 = se.getLastSnapshotEpoch(p) * EPOCH;
        uint256 cAfterW1 = se.getUserStake(C, p, 1); // C won window 1 and grew a little
        vm.warp(t0 + EPOCH - 5);
        _stake(D, p, 0, 100_000e18); // five seconds of presence
        vm.warp(t0 + EPOCH);
        (uint256 S, uint256 Cc) = se.getTimeWeightedTotals(p, t0, t0 + EPOCH);
        assertLt(S, 1000e18 + 10e18, "100k x 5/86400 < 6 VSP of weight");
        assertGt(S, se.getUserStake(A, p, 0), "but not zero: five seconds count for five seconds");
        assertEq(Cc, cAfterW1, "challenge present all window counts in full");
    }
}
