// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./base/SnapshotBase.sol";

/// @title Whitepaper v18 conformance — settlement on stored snapshots (patch_settlement_snapshots)
/// @notice Every expected value is computed from the paper's text (§3.2, §4.2.2, §4.2.5, §4.2.6, §4.3,
///         §4.4, §7.4), never from the code. Pronouncements P40–P55 continue the numbering of the v16/v17
///         suites.
contract WhitepaperConformanceV3Test is SnapshotBase {
    // ═══════════════ §4.2.6 snapshots ═══════════════

    /// P40: a post's settlement writes {epoch, T_w, vs}; a link's settlement also writes its parent's
    /// outgoing sum (replacing its previous entry).
    function test_P40_SettlementWritesSnapshot() public {
        uint256 p = _claimStaked("p", A, 0, 3e18);
        uint256 x = _claimStaked("x", B, 0, 2e18);
        uint256 l = _link(C, p, x, true, 1e18);
        (bool seeded,,,) = score.getSnapshot(p);
        assertFalse(seeded, "no snapshot before the first settlement");
        _nextEpoch();
        _keeperPass();
        (bool s1, uint32 e1, uint96 T1, int128 v1) = score.getSnapshot(p);
        assertTrue(s1);
        assertEq(e1, block.timestamp / EPOCH, "snapshot epoch = window end");
        assertEq(T1, 3e18, "T_w = window-averaged direct total (present all window)");
        assertEq(v1, int128(int256(RAY)), "uncontested: vs = +1");
        assertEq(score.outSum(p), 1e18, "the link's settlement wrote its T_w into the parent's outgoing sum");
        assertEq(score.outContrib(l), 1e18);
        (, uint32 ex,,) = score.getSnapshot(x);
        assertEq(ex, e1, "the child settled in the same epoch");
    }

    /// P41 (§4.2.2 step 2): outSum is maintained incrementally — a link that changes stake REPLACES
    /// its entry; recalcOutSum rebuilds the same number from the links' entries.
    function test_P41_OutSumIncrementalAndRecalc() public {
        uint256 p = _claimStaked("p41", A, 0, 10e18);
        uint256 x1 = _claimStaked("x1", B, 0, 1e18);
        uint256 x2 = _claimStaked("x2", B, 0, 1e18);
        uint256 l1 = _link(C, p, x1, false, 2e18);
        uint256 l2 = _link(C, p, x2, false, 6e18);
        _nextEpoch();
        _keeperPass();
        assertEq(score.outSum(p), 8e18);
        _withdraw(C, l2, 0, 3e18); // l2: 6 -> 3 (plus its one-epoch accrual)
        _nextEpoch();
        _keeperPass();
        uint256 t1 = _snapT(l1);
        uint256 t2 = _snapT(l2);
        assertEq(score.outSum(p), t1 + t2, "outSum == sum of the links' current snapshot stakes");
        assertEq(score.outContrib(l2), t2, "entry replaced, not accumulated");
        uint256 before = score.outSum(p);
        score.recalcOutSum(p);
        assertEq(score.outSum(p), before, "recalc is a no-op when there is no drift");
    }

    /// P42 (§4.2.6): a child's contribution uses the parent's SNAPSHOT T and vs, not its live totals —
    /// a parent that withdraws after settling keeps contributing until its next settlement.
    function test_P42_ChildReadsParentSnapshotNotLive() public {
        uint256 p = _claimStaked("p42", A, 0, 4e18);
        uint256 x = _claimStaked("x42", B, 0, 1e18);
        _link(C, p, x, false, 1e18);
        _nextEpoch();
        _keeperPass();
        (uint256 S0,,) = score.effectivePool(x);
        (uint256 Ax0,) = se.getPostTotals(x);
        assertEq(S0, Ax0 + 4e18, "S = live direct + parent's snapshot mass (T_w = 4, window pre-accrual)");
        _withdraw(A, p, 0, se.getUserStake(A, p, 0)); // parent drained live
        (uint256 S1,,) = score.effectivePool(x);
        assertEq(S1, S0, "display still reads the snapshot (one hop per epoch)");
        _nextEpoch();
        _keeperPass(); // parent's snapshot now T_w = 0 (drained for the whole window)
        (uint256 S2,,) = score.effectivePool(x);
        (uint256 Ax,) = se.getPostTotals(x);
        assertEq(S2, Ax, "after the parent's next settlement its contribution is gone");
    }

    /// P43 (§4.2.5): displayed pool = live direct totals + the snapshot contributions the next
    /// settlement will read; previewPoolWindow == what settlePool pays on.
    function test_P43_DisplayEqualsNextSettlementInputs() public {
        uint256 p = _claimStaked("p43", A, 0, 5e18);
        uint256 x = _claimStaked("x43", B, 0, 2e18);
        _link(C, p, x, true, 1e18);
        _nextEpoch();
        _keeperPass();
        vm.warp(block.timestamp + EPOCH / 2);
        _stake(D, x, 0, 1e18); // live change on x only, mid-window
        (uint256 Sd, uint256 Cd,) = score.effectivePool(x);
        (uint256 Ax,) = se.getPostTotals(x);
        assertEq(Sd, Ax, "display: live direct support");
        assertEq(Cd, 5e18, "display: parent's snapshot mass against (T_w of its first window = 5)");
        vm.warp(block.timestamp + EPOCH / 2);
        (uint256 Sw, uint256 Cw) = score.previewPoolWindow(x, se.getLastSnapshotEpoch(x) * EPOCH, block.timestamp);
        assertEq(Cw, Cd, "same evidence term in the settlement preview");
        assertLt(Sw, Sd, "settlement averages x's own direct stake over the window (D entered mid-window)");
    }

    // ═══════════════ §4.2.2 eligibility ranking ═══════════════

    /// P44: an eligible link whose parent is active but discredited (vs <= 0) ranks as 0 and can
    /// never occupy a scoring slot (closes review F-A: fan-in eclipse).
    function test_P44_DiscreditedParentsCannotOccupySlots() public {
        score.setEdgeLimits(2, 64);
        uint256 x = _claimStaked("x44", A, 0, 10e18);
        uint256 honest = _claimStaked("honest", B, 0, 10e18);
        uint256 hl = _link(B, honest, x, true, 1e18); // honest challenge, 1 VSP link
        // two ACTIVE but discredited parents (challenged below zero) with bigger links
        for (uint256 i = 0; i < 2; i++) {
            uint256 bad = _claimStaked(string(abi.encodePacked("bad", vm.toString(i))), C, 0, 5e18);
            _stake(D, bad, 1, 9e18); // vs = (5-9)/14 < 0
            _link(C, bad, x, false, 50e18); // out-stakes the honest link 50:1
        }
        _nextEpoch();
        _keeperPass();
        assertGt(_absI(score.getEdgeContribution(x, hl)), 0, "honest link still counts");
        (, uint256 Cx,) = score.effectivePool(x);
        assertEq(Cx, 10e18, "x is challenged by exactly the honest parent's snapshot mass");
    }

    /// P45: equal keys break by linkPostId ascending; a contribution that rounds to zero ranks as 0.
    function test_P45_TiesAndZeroRounding() public {
        score.setEdgeLimits(1, 64);
        uint256 x = _claimStaked("x45", A, 0, 10e18);
        uint256 p1 = _claimStaked("p1", B, 0, 4e18);
        uint256 p2 = _claimStaked("p2", B, 0, 4e18);
        uint256 l1 = _link(C, p1, x, false, 2e18);
        uint256 l2 = _link(C, p2, x, false, 2e18); // same key, later id
        _nextEpoch();
        _keeperPass();
        assertGt(score.getEdgeContribution(x, l1), 0, "older link wins the single slot");
        assertEq(score.getEdgeContribution(x, l2), 0, "later tied link is cut");
        // a dust parent whose contribution rounds to zero never takes the slot from a real one
        score.setEdgeLimits(1, 64);
        uint256 y = _claimStaked("y45", A, 0, 10e18);
        uint256 dust = _claimStaked("dust", B, 0, 1e18 + 1);
        _stake(C, dust, 1, 1e18); // vs = 1/(2e18+1) ~ 5e-19 -> contribution rounds to 0
        uint256 ld = _link(C, dust, y, false, 100e18); // huge link stake, zero mass
        uint256 real = _claimStaked("real", B, 0, 3e18);
        uint256 lr = _link(C, real, y, true, 1e18);
        _nextEpoch();
        _keeperPass();
        assertEq(score.getEdgeContribution(y, ld), 0, "rounds to zero -> ranks as zero");
        assertLt(score.getEdgeContribution(y, lr), 0, "the real link holds the slot");
    }

    /// P46 (§4.4): no outgoing cap — a third party's links from a parent DILUTE its existing link
    /// but cannot evict it; Σ linkShare = 1 exactly (closes review F-A2: fan-out eclipse).
    function test_P46_NoOutgoingCapNoEviction() public {
        uint256 p = _claimStaked("p46", A, 0, 100e18);
        uint256 x = _claimStaked("x46", B, 0, 10e18);
        uint256 hl = _link(B, p, x, true, 5e18); // honest evidence: 5 VSP link
        // attacker: 70 links from p (which they do not own) to their own claims, 1 VSP each
        uint256 n = 70;
        for (uint256 i = 0; i < n; i++) {
            uint256 t = _claimStaked(string(abi.encodePacked("t", vm.toString(i))), C, 0, 1e18);
            _link(C, p, t, false, 1e18);
        }
        _nextEpoch();
        _keeperPass();
        int256 c = score.getEdgeContribution(x, hl);
        // share = 5 / (5 + 70) of parent mass (100 + accrual): diluted, never zero
        uint256 pm = _snapT(p); // 100e18: first-window average == principal
        assertEq(pm, 100e18);
        assertEq(score.outSum(p), 75e18, "denominator over ALL outgoing links (5 + 70 x 1)");
        assertEq(uint256(-c), Math.mulDiv(pm, 5e18, 75e18), "honest link keeps its exact share, never evicted");
    }

    // ═══════════════ §4.3 cycles ═══════════════

    /// P47: two-post cycle — a parent is read back WITHOUT what it counted from the settling post, so
    /// a symmetric mutual challenge reads contested for both, whatever the settlement order.
    function test_P47_TwoCycleIsSymmetric() public {
        uint256 x = _claimStaked("cx", A, 0, 2e18);
        uint256 y = _claimStaked("cy", B, 0, 2e18);
        _link(C, x, y, true, 1e18);
        _link(C, y, x, true, 1e18);
        _nextEpoch();
        // settle in BOTH orders across epochs; the result must not depend on it
        se.updatePost(x);
        se.updatePost(y);
        se.updatePost(created[2]);
        se.updatePost(created[3]);
        // (the very first pass has a one-epoch warm-up: y had no snapshot when x settled)
        _nextEpoch();
        se.updatePost(y);
        se.updatePost(x);
        se.updatePost(created[3]);
        se.updatePost(created[2]);
        int256 vx = score.effectiveVSRay(x);
        int256 vy = score.effectiveVSRay(y);
        assertApproxEqAbs(vx, vy, 1e12, "symmetric cycle, symmetric scores (settlement order reversed)");
        assertLe(_absI(vx), int256(RAY) / 1000, "contested (~0)");
        _nextEpoch();
        se.updatePost(x);
        se.updatePost(y);
        se.updatePost(created[2]);
        se.updatePost(created[3]);
        assertApproxEqAbs(score.effectiveVSRay(x), score.effectiveVSRay(y), 1e12, "order-independent");
    }

    /// P48: longer cycles feed back one epoch per hop and stay bounded; nobody earns more than an
    /// uncontested claim would (no discount for routing stake around a loop).
    function test_P48_ThreeCycleBoundedNoDiscount() public {
        uint256 a = _claimStaked("a", A, 0, 10e18);
        uint256 b = _claimStaked("b", B, 0, 10e18);
        uint256 c = _claimStaked("c", C, 0, 10e18);
        _link(D, a, b, false, 1e18);
        _link(D, b, c, false, 1e18);
        _link(D, c, a, false, 1e18);
        uint256 lone = _claimStaked("lone", D, 0, 10e18); // same stake, no links
        for (uint256 e = 0; e < 4; e++) {
            _nextEpoch();
            _keeperPass();
            for (uint256 i = 0; i < 3; i++) {
                int256 v = score.effectiveVSRay(created[i]);
                assertLe(v, int256(RAY));
                assertGe(v, -int256(RAY));
                (uint256 S,,) = score.effectivePool(created[i]);
                assertLe(S, 31e18, "pool bounded by the loop's direct mass (10 + at most 2 x 10 + accrual)");
            }
        }
        // each member earned exactly what the lone claim earned: vs = +1 for all, same T, same sMax
        assertApproxEqRel(se.getUserStake(A, a, 0), se.getUserStake(D, lone, 0), 1e13, "a loop buys no extra rate");
    }

    // ═══════════════ §3.2 / §4.2.6 freshness & keeper path ═══════════════

    /// P49: the user path defers (SettleFirst) on a parent snapshot older than the previous epoch;
    /// the keeper path completes and emits StaleParentUsed; posts without incoming links never defer.
    function test_P49_FreshnessGate() public {
        uint256 p = _claimStaked("p49", A, 0, 3e18);
        uint256 x = _claimStaked("x49", B, 0, 2e18);
        uint256 l = _link(C, p, x, false, 1e18);
        uint256 solo = _claimStaked("solo", D, 0, 1e18);
        _nextEpoch();
        _keeperPass(); // E1
        _nextEpoch(); // E2 skipped
        _nextEpoch(); // E3
        vm.prank(D);
        vm.expectRevert(abi.encodeWithSelector(StakeEngine.SettleFirst.selector, x));
        se.stake(x, 0, 1e18);
        vm.prank(D);
        se.stake(solo, 0, 1e18); // no incoming links: never deferred
        vm.expectEmit(true, true, false, false, address(score));
        emit ScoreEngine.StaleParentUsed(x, p, 0);
        se.updatePost(x); // keeper completes with the newest snapshot available
        se.updatePost(p);
        se.updatePost(l);
        vm.prank(D);
        se.stake(x, 0, 1e18); // and now the user path works again
        assertEq(se.getUserStake(D, x, 0), 1e18);
    }

    /// P50: settlement never falls back silently — setScoreEngine(0) reverts.
    function test_P50_ScoreEngineCannotBeUnset() public {
        vm.expectRevert(GovernedUpgradeable.ZeroAddress.selector);
        se.setScoreEngine(address(0));
    }

    /// P51: seeding is idempotent and per-post; an unseeded child with incoming links defers its first
    /// user-path settlement and never settles on an empty record by a user's hand.
    function test_P51_SeedIdempotentAndUnseededDefers() public {
        uint256 p = _claimStaked("p51", A, 0, 3e18);
        uint256 x = _claimStaked("x51", B, 0, 2e18);
        uint256 l = _link(C, p, x, true, 1e18);
        score.seedSnapshot(p);
        score.seedSnapshot(l);
        uint256 t0 = _snapT(p);
        _stake(A, p, 0, 1e18);
        score.seedSnapshot(p); // no-op
        assertEq(_snapT(p), t0, "seed is a no-op once a snapshot exists");
        _nextEpoch();
        vm.prank(D);
        vm.expectRevert(abi.encodeWithSelector(StakeEngine.SettleFirst.selector, x));
        se.stake(x, 0, 1e18);
        se.updatePost(x);
        vm.prank(D);
        se.stake(x, 0, 1e18);
    }

    // ═══════════════ §3.2 sMax and bucket ═══════════════

    /// P52 (review C-4): when the post defining sMax drains to zero, sMax snaps to the remaining
    /// tracked leader in the same transaction — no ghost leader, no decay window.
    function test_P52_SMaxSnapsOnDrain() public {
        uint256 small = _claimStaked("small", A, 0, 100e18);
        uint256 big = _claimStaked("big", B, 0, 1_000_000e18);
        _nextEpoch();
        _keeperPass();
        assertEq(se.sMaxPostId(), big);
        uint256 bigTotal = se.settledTotal(big);
        assertEq(se.sMax(), bigTotal);
        _withdraw(B, big, 0, se.getUserStake(B, big, 0)); // transient leader leaves
        assertEq(se.settledTotal(big), 0, "settled total reset on drain");
        assertEq(se.sMaxPostId(), small, "tracker leader is the true leader");
        assertEq(se.sMax(), se.settledTotal(small), "sMax followed the leader down within the drain tx");
        // and a partial withdrawal still does NOT snap (dust-drag protection kept)
        _withdraw(A, small, 0, 50e18);
        assertEq(se.sMax(), se.settledTotal(small), "partial withdraw: never-snap-down unchanged");
    }

    /// P53 (review F-B): the pooled tail bucket ages as ONE amount-weighted lot and is prorated by
    /// its presence. Control: a bucket holding only an all-window member. Test: the same bucket plus
    /// an equal entrant one second before the boundary. Without proration the second bucket's per-wei
    /// rate would be ~2x the control's (its position weight doubles with its live amount); with the
    /// blended presence (~1/2) it is ~equal — the late wei did not buy a full window.
    function test_P53_BucketProrated() public {
        uint256 p1 = _bucketFixture("p53a");
        uint256 p2 = _bucketFixture("p53b");
        address early1 = address(0x7E0001);
        address early2 = address(0x7E0002);
        address late2 = address(0x7E0003);
        _fundStake(early1, p1, 1e18);
        _fundStake(early2, p2, 1e18);
        vm.warp(block.timestamp + EPOCH - 1);
        _fundStake(late2, p2, 1e18);
        vm.warp(block.timestamp + 1);
        uint256 b1 = se.getUserStake(early1, p1, 0);
        uint256 b2 = se.getUserStake(early2, p2, 0) + se.getUserStake(late2, p2, 0);
        se.updatePost(p1);
        se.updatePost(p2);
        uint256 g1 = se.getUserStake(early1, p1, 0) - b1; // per 1 VSP
        uint256 g2 = se.getUserStake(early2, p2, 0) + se.getUserStake(late2, p2, 0) - b2; // per 2 VSP
        uint256 perWei1 = g1; // 1 VSP
        uint256 perWei2 = g2 / 2;
        assertGt(perWei1, 0);
        assertLt(perWei2, perWei1 * 12 / 10, "late entrant did not earn a full window (would be ~2x)");
        assertApproxEqRel(perWei2, perWei1, 3e16, "blended presence ~1/2 cancels the doubled position weight");
    }

    function _bucketFixture(string memory t) internal returns (uint256 p) {
        p = _claimStaked(t, A, 0, 1000e18);
        for (uint256 i = 0; i < 100; i++) {
            _fundStake(address(uint160(0x100000 + i + uint256(keccak256(bytes(t))) % 1000 * 0x1000)), p, 10e18); // fill the ranked slots
        }
    }

    function _fundStake(address u, uint256 p, uint256 amt) internal {
        vsp.mint(u, amt);
        vm.startPrank(u);
        vsp.approve(address(se), type(uint256).max);
        se.stake(p, 0, amt);
        vm.stopPrank();
    }

    /// P54 (review H-1): the uint96 narrowing in the time-weighted observations is asserted, not silent.
    function test_P54_Fits96Asserted() public {
        Fits96Harness h = new Fits96Harness();
        h.observe(1e18, 0); // fine
        vm.expectRevert(TimeWeighted.Fits96.selector);
        h.observe(uint256(type(uint96).max) + 1, 0);
    }

    /// P55 (review N-1): a legacy post's standing stake counts for the whole window even when its
    /// first post-upgrade mutation lands in the same epoch as its preserved lastSnapshotEpoch.
    /// Simulated by clearing the observations (storage surgery) exactly as the review did.
    function test_P55_LegacySeedBeforeMutation() public {
        uint256 p = _claimStaked("p55", A, 0, 2e18);
        _nextEpoch();
        se.updatePost(p); // epoch E: observations exist
        (uint256 a0,) = se.getPostTotals(p); // standing stake at the window start (post-accrual)
        // surgery: wipe observations[p] (length slot) to simulate a pre-upgrade post
        bytes32 slot = keccak256(abi.encode(p, uint256(_observationsSlot())));
        vm.store(address(se), slot, bytes32(0));
        // same epoch: a mutation BEFORE any settlement
        vm.warp(block.timestamp + EPOCH / 2);
        _stake(B, p, 1, 2e18); // user path -> _maybeSnapshot seeds the window start first
        vm.warp(block.timestamp + EPOCH / 2);
        (uint256 Aw, uint256 Dw) = se.getTimeWeightedTotals(p, se.getLastSnapshotEpoch(p) * EPOCH, block.timestamp);
        assertEq(Aw, a0, "standing legacy stake counted for the whole window");
        assertEq(Dw, 1e18, "the mid-window challenge counted for half");
    }

    function _observationsSlot() internal pure returns (uint256) {
        return 138; // StakeEngine storage layout (script/storage-layout/baselines): observations @ slot 138
    }

    // ── patch_presence_bar (Fuji soak S2, 2026-10-04) ───────────────────────────────────────────
    // Activity (the minTotalStake gate, §4.2.1) is judged on the SAME window-averaged stake as every
    // other quantity: a post counts in a window only if stake × (fraction of the window it stood) clears
    // the threshold — one VSP-window of presence at the deployed threshold. The soak showed the
    // consequence at the minimum stake (a 1-VSP link placed mid-window counted from its second window);
    // the reason the rule is right is P59: without it a link staked for the last minutes of a window
    // would transmit its parent's full mass for the whole window at no capital risk, every day.

    /// P58: the bar is one VSP-window of presence — 1 VSP placed mid-window misses it, 2 VSP clears it,
    /// and the 1-VSP link counts from its first FULL window. (Two parents, so each link is alone on its
    /// parent's outgoing sum; vm.getBlockTimestamp because via-IR folds repeated block.timestamp reads.)
    function test_P58_PresenceBarAtTheMinimumStake() public {
        policy.setMinTotalStake(1e18); // Fuji/mainnet-like threshold
        uint256 p1 = _claimStaked("p58-parent1", A, 0, 5e18);
        uint256 p2 = _claimStaked("p58-parent2", A, 0, 5e18);
        uint256 x1 = _claimStaked("p58-x1", B, 0, 20e18);
        uint256 x2 = _claimStaked("p58-x2", B, 0, 20e18);
        _nextEpoch();
        _keeperPass();
        vm.warp(vm.getBlockTimestamp() + EPOCH / 2); // mid-window
        uint256 l1 = _link(C, p1, x1, true, 1e18); // the minimum
        uint256 l2 = _link(C, p2, x2, true, 2e18); // twice the minimum
        vm.warp(vm.getBlockTimestamp() + EPOCH / 2); // the boundary
        // keeper order: parents, links, then the children (a post settles once per epoch, so order matters)
        se.updatePost(p1);
        se.updatePost(p2);
        se.updatePost(l1);
        se.updatePost(l2);
        se.updatePost(x1);
        se.updatePost(x2);
        (,, uint96 t1, int128 v1) = score.getSnapshot(l1);
        (,, uint96 t2, int128 v2) = score.getSnapshot(l2);
        assertApproxEqRel(uint256(t1), 0.5e18, 2e16, "1 VSP for half a window = 0.5 VSP-windows");
        assertEq(int256(v1), 0, "below the bar: inactive for this window");
        assertApproxEqRel(uint256(t2), 1e18, 2e16, "2 VSP for half a window = 1 VSP-window");
        assertEq(int256(v2), int256(RAY), "at the bar: active");
        (, uint256 c1) = score.getSettledPool(x1);
        (, uint256 c2) = score.getSettledPool(x2);
        assertEq(c1, 0, "minimum link placed mid-window: nothing on its first (partial) window");
        assertApproxEqRel(c2, 5e18, 1e16, "2-VSP link placed mid-window: the parent's mass on day one");
        // the next window is the 1-VSP link's first full one: it counts from here on
        _nextEpoch();
        se.updatePost(p1);
        se.updatePost(l1);
        se.updatePost(x1);
        (, uint256 c1b) = score.getSettledPool(x1);
        assertApproxEqRel(c1b, 5e18, 1e16, "and from its first full window");
    }

    /// P59: why the bar is time-weighted — a link staked for the last minutes of a window cannot
    /// transmit its parent's mass for that window (no free one-window challenges, repeatable daily).
    function test_P59_LastMinuteLinkTransmitsNothing() public {
        policy.setMinTotalStake(1e18);
        uint256 p = _claimStaked("p59-parent", A, 0, 50e18);
        uint256 x = _claimStaked("p59-x", B, 0, 20e18);
        uint256 l = _link(C, p, x, true, 1e18);
        _withdraw(C, l, 0, 1e18); // start the experiment with the link empty
        _nextEpoch();
        _keeperPass();
        for (uint256 day = 0; day < 3; day++) {
            vm.warp(vm.getBlockTimestamp() + EPOCH - 120);
            _stake(C, l, 0, 1e18); // two minutes before the boundary
            vm.warp(vm.getBlockTimestamp() + 120);
            se.updatePost(p);
            se.updatePost(l);
            (,, uint96 lT, int128 lVs) = score.getSnapshot(l);
            assertLt(uint256(lT), 0.01e18, "two minutes of 1 VSP is ~0.0014 VSP-windows");
            assertEq(int256(lVs), 0, "inactive");
            se.updatePost(x);
            (, uint256 c) = score.getSettledPool(x);
            assertEq(c, 0, "the 50-VSP parent's mass does not reach x through a last-minute link");
            _withdraw(C, l, 0, se.getUserStake(C, l, 0)); // and out again
        }
        // the same link, held for a full window, counts — presence is what the bar measures
        _stake(C, l, 0, 1e18);
        _nextEpoch();
        se.updatePost(p);
        se.updatePost(l);
        se.updatePost(x);
        (, uint256 cFull) = score.getSettledPool(x);
        assertApproxEqRel(cFull, 50e18, 1e16, "held a full window: counted");
    }
}

contract Fits96Harness {
    TimeWeighted.Observation[] internal obs;

    function observe(uint256 A, uint256 D) external {
        TimeWeighted.observe(obs, A, D);
    }
}
