// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./base/SnapshotBase.sol";

/// @title Review R3 (2026-10-01) findings as regression tests — each PoC's assertion inverted.
/// @notice F-D: test/SnapshotFlood.t.sol. F-A: V3 P44. F-A2: V3 P46. F-C: V3 P45 + CoreInvariants
///         edge-sum. C-3s: V3 P50. F-B: V3 P53. N-1: V3 P55. H-1: V3 P54. Here: C-1, C-3, C-4.
contract R3RegressionsTest is SnapshotBase {
    /// C-1 (Medium): a sibling link withdrawn to below the fee just before settlement used to vanish
    /// from the outgoing denominator while the survivors kept their full time-weighted mass, so the
    /// survivor's share inflated (walk said 12 where the honest answer was ~7). v18: one clock — the
    /// denominator is the sum of the links' own settled totals. VSP-SEC-004 (patch_sec004_present_pool)
    /// moved that clock from the window AVERAGE to the capital PRESENT at settlement: the withdrawn link
    /// bore no settlement, so it has no mass for that window, and the survivor's share is exactly the
    /// settled arithmetic (now the whole parent mass) — consistent, not inflated by a stale average.
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
        se.updatePost(l2);
        uint256 t1 = _snapT(l1);
        uint256 t2 = _snapT(l2);
        assertEq(t2, 0, "SEC-004: a link that left before settlement has no mass for that window");
        assertGt(t1, 9.9e18, "the link that stayed has its full mass");
        (uint256 S1,,) = score.effectivePool(x1);
        (uint256 Ax1,) = se.getPostTotals(x1);
        uint256 share1 = S1 - Ax1;
        assertEq(share1, Math.mulDiv(_snapT(p), t1, t1 + t2), "x1 gets exactly its settled share (one clock)");
        (uint256 S2,,) = score.effectivePool(x2);
        (uint256 Ax2,) = se.getPostTotals(x2);
        assertEq(S2 - Ax2, 0, "x2's evidence left with its stake");
    }

    /// C-3 (Low): an incoming challenge link withdrawn to live zero just before settlement used to lose
    /// its ranking slot and the target read unchallenged for a window it was challenged in. v18 made
    /// the window average count. VSP-SEC-004: the average let capital that bears no settlement decide
    /// one, so the rule is now presence at settlement — the emptied link counts for nothing in the
    /// window it left, and the target's supporter is not decayed by a challenge that took no risk.
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
        assertEq(Cw, 0, "SEC-004: the challenge left before settlement, so it bears nothing and decides nothing");
        se.updatePost(x);
        assertGe(se.getUserStake(A, x, 0), atE1, "x's supporter is not decayed by a challenge that took no risk");
        // and from the next window the empty link still counts for nothing
        _nextEpoch();
        _keeperPass();
        (, uint256 Cn,) = score.effectivePool(x);
        assertEq(Cn, 0, "an emptied link contributes nothing");
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

    // ── re-check 2026-10-02 (patch_settlement_caps) ──────────────────────────────────────────────

    /// A seed is governance-only, so nobody can plant a post's first snapshot at a transient level.
    function test_seedSnapshotIsGovernanceOnly() public {
        uint256 p = _claimStaked("seed-g", A, 0, 5e18);
        vm.prank(B);
        vm.expectRevert();
        score.seedSnapshot(p);
        (bool seeded,,,) = score.getSnapshot(p);
        assertFalse(seeded, "a non-governance caller cannot seed");
        score.seedSnapshot(p); // governance (this test contract)
        (seeded,,,) = score.getSnapshot(p);
        assertTrue(seeded);
    }

    /// Even a governance seed written at a transient stake level stands only until the post's next
    /// settlement, which overwrites it with the window average.
    function test_seedAtTransientLevelIsOverwrittenAtNextSettle() public {
        uint256 p = _claimStaked("seed-t", A, 0, 1e18);
        _stake(B, p, 0, 1_000e18); // transient: present only for the seed
        score.seedSnapshot(p);
        assertEq(_snapT(p), 1_001e18, "seed reads live totals");
        _withdraw(B, p, 0, 1_000e18);
        assertEq(_snapT(p), 1_001e18, "the seed stands until a settlement");
        _nextEpoch();
        se.updatePost(p);
        uint256 T = _snapT(p);
        assertLt(T, 2e18, "next settlement overwrote the seed with the window average (the flash is gone)");
        assertGt(T, 0);
    }

    /// The absolute ceiling is the measured point: governance cannot raise the caps above it.
    function test_linkCapCeilingIs1000() public {
        assertEq(graph.ABSOLUTE_MAX_LINKS_PER_CLAIM(), 1000);
        vm.expectRevert(LinkGraph.InvalidLinkCap.selector);
        graph.setLinkCaps(1001, 1000);
        vm.expectRevert(LinkGraph.InvalidLinkCap.selector);
        graph.setLinkCaps(1000, 1001);
        graph.setLinkCaps(1000, 1000);
        graph.setLinkCaps(64, 64);
        assertEq(graph.maxIncomingLinksPerClaim(), 64);
    }
}
