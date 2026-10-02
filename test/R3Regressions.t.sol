// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./base/SnapshotBase.sol";

/// @title Review R3 (2026-10-01) findings as regression tests — each PoC's assertion inverted.
/// @notice F-D: test/SnapshotFlood.t.sol. F-A: V3 P44. F-A2: V3 P46. F-C: V3 P45 + CoreInvariants
///         edge-sum. C-3s: V3 P50. F-B: V3 P53. N-1: V3 P55. H-1: V3 P54. Here: C-1, C-3, C-4.
contract R3RegressionsTest is SnapshotBase {
    /// C-1 (Medium): a sibling link withdrawn to below the fee just before settlement used to vanish
    /// from the outgoing denominator while the survivors kept their full time-weighted mass, so the
    /// survivor's share inflated (walk said 12 where the honest answer was ~7). v18: the denominator
    /// is the sum of the links' own settled window averages — one clock.
    function test_C1_outgoingDenominatorUsesSettledClock() public {
        uint256 p = _claimStaked("p", A, 0, 12e18);
        uint256 x1 = _claimStaked("x1", B, 0, 1e18);
        uint256 x2 = _claimStaked("x2", B, 0, 1e18);
        uint256 l1 = _link(C, p, x1, false, 10e18);
        uint256 l2 = _link(C, p, x2, false, 10e18);
        _nextEpoch();
        _keeperPass(); // window 1: both links full presence; outSum = 20
        vm.warp(block.timestamp + EPOCH - 60);
        _withdraw(C, l2, 0, se.getUserStake(C, l2, 0)); // l2 leaves 60 s before the boundary
        vm.warp(block.timestamp + 60);
        se.updatePost(p);
        se.updatePost(l1);
        se.updatePost(l2); // l2's T_w over this window ~ 10 x (86340/86400)
        uint256 t1 = _snapT(l1);
        uint256 t2 = _snapT(l2);
        assertGt(t2, 9.9e18, "the withdrawn link stood almost the whole window");
        (uint256 S1,,) = score.effectivePool(x1);
        (uint256 Ax1,) = se.getPostTotals(x1);
        uint256 share1 = S1 - Ax1;
        assertEq(share1, Math.mulDiv(_snapT(p), t1, t1 + t2), "x1 gets exactly its settled share");
        assertLt(share1, 6.5e18, "not the whole parent mass (the old walk gave 12)");
    }

    /// C-3 (Low): an incoming challenge link withdrawn to live zero just before settlement used to lose
    /// its ranking slot and the target read unchallenged for a window it was challenged in. v18: the
    /// link's settled window average is what counts, for that window.
    function test_C3_incomingRankUsesSettledClock() public {
        score.setEdgeLimits(1, 64);
        uint256 x = _claimStaked("x", A, 0, 2e18);
        uint256 p = _claimStaked("p", B, 0, 50e18);
        uint256 l = _link(C, p, x, true, 50e18);
        _nextEpoch();
        _keeperPass();
        uint256 atE1 = se.getUserStake(A, x, 0); // stored value (x settled this epoch)
        vm.warp(block.timestamp + EPOCH - 30);
        _withdraw(C, l, 0, se.getUserStake(C, l, 0)); // challenge link emptied 30 s before the boundary
        vm.warp(block.timestamp + 30);
        se.updatePost(p);
        se.updatePost(l);
        (, uint256 Cw) = score.previewPoolWindow(x, se.getLastSnapshotEpoch(x) * EPOCH, block.timestamp);
        assertGt(Cw, 49e18, "the window x is settling was challenged ~all along: it settles challenged");
        se.updatePost(x);
        assertLt(se.getUserStake(A, x, 0), atE1, "x's supporter decayed for that window");
        // and from the NEXT window the empty link counts for nothing
        _nextEpoch();
        _keeperPass();
        (, uint256 Cn,) = score.effectivePool(x);
        assertEq(Cn, 0, "an emptied link contributes nothing once its empty window has settled");
    }

    /// C-4 (Medium): a 1,000,000-VSP transient leader that settled once and withdrew used to pin sMax
    /// for the whole decay window (10,000x suppression of every other post's accrual). v18: the drain
    /// snaps sMax to the remaining leader in the same transaction; the victim's accrual is unchanged.
    function test_C4_noGhostLeaderSuppression() public {
        uint256 victim = _claimStaked("victim", A, 0, 100e18);
        _nextEpoch();
        se.updatePost(victim);
        uint256 v0 = se.getUserStake(A, victim, 0);
        _nextEpoch();
        se.updatePost(victim);
        uint256 cleanGain = se.getUserStake(A, victim, 0) - v0;
        // attacker: transient leader for one epoch, then gone
        uint256 whale = _claimStaked("whale", B, 0, 1_000_000e18);
        _nextEpoch();
        se.updatePost(whale);
        se.updatePost(victim);
        _withdraw(B, whale, 0, se.getUserStake(B, whale, 0));
        assertEq(se.sMaxPostId(), victim, "victim is the tracked leader again, immediately");
        assertEq(se.sMax(), se.settledTotal(victim), "sMax followed within the drain transaction");
        uint256 v1 = se.getUserStake(A, victim, 0);
        _nextEpoch();
        se.updatePost(victim);
        uint256 afterGain = se.getUserStake(A, victim, 0) - v1;
        assertApproxEqRel(afterGain, cleanGain, 2e16, "no suppression after the ghost leaves (was 10,000x)");
    }
}
