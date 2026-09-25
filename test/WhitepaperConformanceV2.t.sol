// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./WhitepaperConformance.t.sol";

/// @title Whitepaper v17 conformance — evidence-economic settlement (Game B)
/// @notice Written from whitepaper v17 §3.2 / §4.1 / §4.2 / §4.2.5 BEFORE the contracts were changed.
///         Expected values are computed here from the paper's formulas, never from the code.
///         Inherits the v16 fixtures; every v16 test that does not involve evidence still holds.
contract WhitepaperConformanceV2Test is WhitepaperConformanceTest {
    function setUp() public override {
        super.setUp();
        se.setScoreEngine(address(score)); // Game B: settlement pays on the effective pool
    }

    // ── helpers ──────────────────────────────────────────────────────────────
    function _link(address u, uint256 from, uint256 to, bool chal, uint256 linkStake) internal returns (uint256 l) {
        l = registry.createLink(from, to, chal);
        _stake(u, l, 0, linkStake);
    }

    /// the settlement view: window average over the post's open window
    function _windowPool(uint256 pid) internal view returns (uint256 S, uint256 C, bool exact) {
        return score.effectivePoolWindow(pid, se.getLastSnapshotEpoch(pid) * EPOCH, block.timestamp);
    }

    /// paper §4.2.3: effVS = (S - C) / (S + C)
    function _vs(uint256 S, uint256 C) internal pure returns (int256) {
        if (S + C == 0) {
            return 0;
        }
        return (int256(S) - int256(C)) * int256(RAY) / int256(S + C);
    }

    /// paper §3.2 v17: rBase from the effective pool, participation on direct T
    function _rBaseV2(uint256 S, uint256 C, uint256 Tdirect, uint256 sMax_, uint256 epochs)
        internal
        pure
        returns (uint256)
    {
        uint256 diff = S > C ? S - C : C - S;
        uint256 verity = (diff * RAY) / (S + C);
        uint256 part = (Tdirect * RAY) / sMax_;
        if (part > RAY) {
            part = RAY;
        }
        return (_rMaxE(epochs) * verity * part) / (RAY * RAY);
    }

    // ═══════════════ §4.1 (v17): base VS internal, same scale, gated ═══════════════

    /// G3 ruling: baseVS = (A - D) / T — same scale as effective VS
    function test_V2_P18_BaseVSSameScale() public {
        uint256 p = _claim("scale");
        _stake(A, p, 0, 4e18);
        _stake(B, p, 1, 1e18);
        assertEq(score.baseVSRay(p), int256((3 * RAY) / 5), "(4-1)/5 = +60%, not winner share +80%");
        assertEq(score.effectiveVSRay(p), int256((3 * RAY) / 5), "no links: effective == base");
    }

    /// G2 ruling: below the activity threshold a post has NO score (base and effective read 0)
    function test_V2_P19_InactivePostHasNoScore() public {
        policy.setMinTotalStake(2e18);
        uint256 p = _claim("tiny");
        _stake(A, p, 0, 1e18);
        assertEq(score.baseVSRay(p), 0, "inactive: base VS 0");
        assertEq(score.effectiveVSRay(p), 0, "inactive: effective VS 0");
        _stake(A, p, 0, 1e18);
        assertEq(score.effectiveVSRay(p), int256(RAY), "active now");
    }

    // ═══════════════ §4.2 (v17): a contribution is stake ═══════════════

    /// §4.2 + §4.2.3: the pool is visible; contributions cancel in the numerator and stay in the pool
    function test_V2_P25_EffectivePoolView() public {
        uint256 c = _claim("c");
        _stake(A, c, 0, 2e18);
        uint256 p1 = _claim("p1");
        _stake(B, p1, 0, 1e18);
        _link(C, p1, c, false, 1e18);
        uint256 p2 = _claim("p2");
        _stake(B, p2, 0, 1e18);
        _link(C, p2, c, true, 1e18);
        (uint256 S, uint256 Cc, bool exact) = score.effectivePool(c);
        assertTrue(exact);
        assertEq(S, 3e18, "2 direct + 1 evidence for");
        assertEq(Cc, 1e18, "0 direct + 1 evidence against");
        assertEq(score.effectiveVSRay(c), int256(RAY / 2), "+50% (mainnet claim #1)");
    }

    // ═══════════════ §3.2 (v17): settlement pays on the effective pool ═══════════════

    /// The headline change. X: 2 VSP direct support, no direct challenge. Credible parent P (3 VSP)
    /// challenges X through a 1-VSP link. Contribution = 1.0 * 3 * 1 * 1.0 = 3 ⇒ S = 2, C = 3:
    /// challenge wins, X's supporter DECAYS although nobody staked challenge on X directly.
    function test_V2_P10_EvidenceMovesMoney() public {
        uint256 x = _claim("x");
        _stake(A, x, 0, 2e18);
        uint256 p = _claim("p");
        _stake(B, p, 0, 3e18);
        _link(C, p, x, true, 1e18);
        uint256 s0 = vsp.totalSupply();
        _nextEpoch();
        se.updatePost(p); // parents first (keeper order): sMax = 3 + P's accrual
        se.updatePost(x);
        // X: S = 2, C = 3 (P's time-weighted mass over the window = 3, present all window)
        uint256 rBase = _rBaseV2(2e18, 3e18, 2e18, se.settledTotal(p), 1);
        uint256 dA = _delta(2e18, rBase, 1e18, 2e18); // sole support lot: wp = 1, pw = 1/2
        assertEq(se.getUserStake(A, x, 0), 2e18 - dA, "supporter decays on evidence alone");
        assertEq(vsp.totalSupply(), s0 + (se.settledTotal(p) - 3e18) - dA, "P's accrual minted; A's decay burned");
    }

    /// Direct stake and evidence give the same verity and aligned side (participation differs: direct T)
    function test_V2_P34_ContributionEqualsDirectStake() public {
        uint256 x1 = _claim("x1"); // 2 support, 3 DIRECT challenge
        _stake(A, x1, 0, 2e18);
        _stake(B, x1, 1, 3e18);
        uint256 x2 = _claim("x2"); // 2 support, 3 of EVIDENCE against
        _stake(A, x2, 0, 2e18);
        uint256 p = _claim("p34");
        _stake(B, p, 0, 3e18);
        _link(C, p, x2, true, 1e18);
        (uint256 S1, uint256 C1,) = score.effectivePool(x1);
        (uint256 S2, uint256 C2,) = score.effectivePool(x2);
        assertEq(S1, S2);
        assertEq(C1, C2, "3 VSP of evidence == 3 VSP of direct challenge in the pool");
        assertEq(score.effectiveVSRay(x1), score.effectiveVSRay(x2), "same score");
        _nextEpoch();
        se.updatePost(p);
        se.updatePost(x1);
        se.updatePost(x2);
        // both supporters decay; x1 (T = 5) has larger participation than x2 (T = 2), so a larger delta
        uint256 loss1 = 2e18 - se.getUserStake(A, x1, 0);
        uint256 loss2 = 2e18 - se.getUserStake(A, x2, 0);
        assertGt(loss1, 0);
        assertGt(loss2, 0);
        // participation = T/sMax; sMax carries the leader's accrual (G6), so compare to 1e-4
        assertApproxEqRel(loss1 * 2e18, loss2 * 5e18, 1e14, "same verity; deltas scale with direct T (participation)");
    }

    /// §4.2.5: evidence present for half the window contributes half its mass
    function test_V2_P35_TimeWeightedMass() public {
        uint256 x = _claim("x35");
        _stake(A, x, 0, 2e18);
        vm.warp(block.timestamp + EPOCH / 2);
        uint256 p = _claim("p35");
        _stake(B, p, 0, 3e18); // parent and link enter at mid-window
        _link(C, p, x, true, 1e18);
        vm.warp(block.timestamp + EPOCH / 2); // exactly at the boundary: window fully elapsed
        (uint256 S, uint256 Cc,) = _windowPool(x);
        assertEq(S, 2e18);
        assertEq(Cc, 1.5e18, "3 VSP present for half the window = 1.5 VSP of mass");
        assertEq(score.effectiveVSRay(x), _vs(2e18, 3e18), "instantaneous display: -20% (evidence now standing)");
        se.updatePost(p);
        se.updatePost(x);
        assertGt(se.getUserStake(A, x, 0), 2e18, "support side accrued (S > C)");
    }

    /// §7.4 flash evidence: a parent staked one second before settlement has ~no effect
    function test_V2_P35_FlashEvidenceIsWorthless() public {
        uint256 x = _claim("x-flash");
        _stake(A, x, 0, 2e18);
        vm.warp(block.timestamp + EPOCH - 1);
        uint256 p = _claim("p-flash");
        _stake(B, p, 0, 300e18); // huge, one second before the boundary
        _link(C, p, x, true, 1e18);
        vm.warp(block.timestamp + 1);
        (, uint256 Cc,) = _windowPool(x);
        assertLt(Cc, 0.01e18, "300 VSP for 1 s of 86400 = 0.0035 VSP of mass");
        se.updatePost(p);
        se.updatePost(x);
        assertGt(se.getUserStake(A, x, 0), 2e18, "supporter still accrues");
    }

    /// §4.2.1 + cascade: a parent flipped this epoch withdraws its support from children this epoch
    function test_V2_P36_CascadeSameEpoch() public {
        uint256 r = _claim("root");
        _stake(A, r, 0, 3e18);
        uint256 k = _claim("kid");
        _stake(B, k, 0, 1e18);
        _link(C, r, k, false, 1e18); // r supports k: k's S = 1 + 3 = 4
        (uint256 S0,,) = score.effectivePool(k);
        assertEq(S0, 4e18);
        _stake(B, r, 1, 5e18); // refute r at window start: r's effVS < 0 -> gate -> contributes 0
        vm.warp(block.timestamp + EPOCH);
        (uint256 S1,,) = score.effectivePool(k);
        assertEq(S1, 1e18, "discredited parent withdraws its support (no negation)");
    }

    /// §3.2 (v17): balanced pool -> no economic effect, even with direct majority
    function test_V2_P10_BalancedPoolNoEffect() public {
        uint256 x = _claim("bal");
        _stake(A, x, 0, 2e18); // direct +2
        uint256 p = _claim("pbal");
        _stake(B, p, 0, 2e18);
        _link(C, p, x, true, 1e18); // evidence -2 => S = C = 2
        uint256 s0 = vsp.totalSupply();
        _nextEpoch();
        se.updatePost(p);
        uint256 supplyAfterP = vsp.totalSupply();
        se.updatePost(x);
        assertEq(se.getUserStake(A, x, 0), 2e18, "no accrual, no decay on x");
        assertEq(vsp.totalSupply(), supplyAfterP, "x minted and burned nothing");
        assertGt(supplyAfterP, s0, "(p itself accrued as an uncontested post)");
    }

    /// §4.2: link stake is time-weighted too (share uses averaged link stakes)
    function test_V2_P35_LinkShareTimeWeighted() public {
        uint256 p = _claim("pshare");
        _stake(A, p, 0, 4e18); // mass 4
        uint256 k1 = _claim("k1");
        uint256 k2 = _claim("k2");
        _stake(B, k1, 0, 1e18);
        _stake(B, k2, 0, 1e18);
        _link(C, p, k1, true, 1e18); // present all window
        vm.warp(block.timestamp + EPOCH / 2);
        _link(C, p, k2, true, 1e18); // present half the window: averaged stake 0.5
        vm.warp(block.timestamp + EPOCH / 2);
        (, uint256 C1,) = _windowPool(k1);
        (, uint256 C2,) = _windowPool(k2);
        // shares: 1/(1+0.5) and 0.5/(1+0.5); mass 4 => 2.667 and 1.333
        assertEq(C1, uint256(8e18) / 3, "k1 gets 2/3 of the mass");
        assertEq(C2, uint256(4e18) / 3, "k2 gets 1/3");
        assertApproxEqAbs(C1 + C2, 4e18, 1, "P28 conservation holds with time weighting (1 wei rounding)");
    }

    /// v17 §3.2: with the pool time-weighted, a direct lot present for half the window counts half
    /// toward verity AND earns half its delta (v16 counted it fully toward verity). Overrides v1.
    function test_P15_Proration() public override {
        uint256 p = _claim("prorate2");
        _stake(A, p, 0, 3e18);
        _stake(B, p, 1, 1e18);
        vm.warp(block.timestamp + EPOCH / 2);
        _stake(C, p, 0, 1e18); // enters halfway
        vm.warp(block.timestamp + EPOCH / 2);
        se.updatePost(p);
        // pool over the window: S_tw = 3 + 0.5 = 3.5, C_tw = 1; participation on live T = 5
        uint256 rBase = _rBaseV2(3.5e18, 1e18, 5e18, 5e18, 1); // sMax registers pre-settlement T = 5
        uint256 dC = _delta(1e18, rBase, 3.5e18, 4e18); // positions from live lots: A wp 1.5, C wp 3.5 of 4
        assertEq(se.getUserStake(C, p, 0), 1e18 + dC / 2, "half the window present -> half the delta");
        assertEq(se.getUserStake(A, p, 0), 3e18 + _delta(3e18, rBase, 1.5e18, 4e18), "A present all window");
    }

    // ═══════════════ §3.2 (v17): SettleFirst — oversized settlement defers to the keeper ═══════════════

    uint256 internal _n;

    function _tree(uint256 depth, uint256 fanin) internal returns (uint256 root) {
        _n++;
        root = _claim(string(abi.encodePacked("t", vm.toString(_n))));
        _stake(A, root, 0, 2e18);
        if (depth == 0) {
            return root;
        }
        for (uint256 i = 0; i < fanin; i++) {
            uint256 parent = _tree(depth - 1, fanin);
            _link(B, parent, root, i % 2 == 0, 1e18);
        }
    }

    /// A post whose ancestry is too large to settle within USER_SETTLE_GAS: stake() reverts
    /// SettleFirst; updatePost() (keeper, unbounded) settles it; then stake() works. Settlement is
    /// never skipped and never falls back to direct totals.
    function test_V2_SettleFirst_DefersToKeeper() public {
        uint256 root = _tree(2, 12); // 157 ancestors, > 3M gas cold with time-weighted reads
        _nextEpoch();
        uint256 g0 = gasleft();
        (,, bool exact) = score.effectivePoolWindow(root, se.getLastSnapshotEpoch(root) * EPOCH, block.timestamp);
        uint256 walk = g0 - gasleft();
        assertTrue(exact);
        assertGt(walk, 3_000_000, "fixture must exceed the user budget (USER_SETTLE_GAS)");
        vm.prank(C);
        vm.expectRevert(abi.encodeWithSelector(StakeEngine.SettleFirst.selector, root));
        se.stake(root, 0, 1e18);
        se.updatePost(root); // keeper path: unbounded
        assertEq(se.getLastSnapshotEpoch(root), block.timestamp / EPOCH, "settled by the keeper");
        vm.prank(C);
        se.stake(root, 0, 1e18); // now inline settlement is a no-op and the stake succeeds
        assertEq(se.getUserStake(C, root, 0), 1e18);
    }

    /// Gas record for the design note: cost per ancestor with time-weighted reads.
    function test_V2_GasPerAncestor() public {
        uint256 root = _tree(2, 4); // 21 nodes
        _nextEpoch();
        uint256 g0 = gasleft();
        score.effectivePoolWindow(root, se.getLastSnapshotEpoch(root) * EPOCH, block.timestamp);
        uint256 used = g0 - gasleft();
        emit log_named_uint("walk gas, 21 ancestors, time-weighted", used);
        emit log_named_uint("per ancestor", used / 21);
        assertLt(used / 21, 120_000, "per-ancestor cost sanity bound");
    }

    // ═══════════════ invariants under evidence settlement ═══════════════

    /// Fuzz: random small graph (claims, links, both polarities, random stakes), several epochs of
    /// keeper-ordered settlement. Invariants: supply delta == sum of lot deltas (nothing leaks);
    /// no lot below zero; every settlement exact; sMax >= every settled total.
    function testFuzz_V2_SupplyConservation(uint256 seed) public {
        seed = bound(seed, 1, type(uint64).max);
        uint256 nClaims = 3 + (seed % 4);
        uint256[] memory ids = new uint256[](nClaims);
        for (uint256 i = 0; i < nClaims; i++) {
            ids[i] = _claim(string(abi.encodePacked("f", vm.toString(seed), "-", vm.toString(i))));
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            _stake(A, ids[i], 0, 1e18 + (r % 5e18));
            if (r % 3 == 0) {
                _stake(B, ids[i], 1, 1e18 + ((r >> 8) % 3e18));
            }
        }
        // links: parent j -> child i for j < i (a DAG), random polarity, random stake
        for (uint256 i = 1; i < nClaims; i++) {
            for (uint256 j = 0; j < i; j++) {
                uint256 r = uint256(keccak256(abi.encode(seed, i, j)));
                if (r % 2 == 0) {
                    _link(C, ids[j], ids[i], (r >> 4) % 2 == 0, 1e18 + ((r >> 8) % 2e18));
                }
            }
        }
        uint256 before = vsp.totalSupply();
        uint256 lotsBefore;
        for (uint256 i = 0; i < nClaims; i++) {
            lotsBefore += se.getUserStake(A, ids[i], 0) + se.getUserStake(B, ids[i], 1);
        }
        uint256 linkLotsBefore = _allLinkLots();
        for (uint256 e = 0; e < 3; e++) {
            _nextEpoch();
            for (uint256 i = 0; i < nClaims; i++) {
                se.updatePost(ids[i]); // topological: parents (j < i) first
            }
            _settleAllLinks();
        }
        uint256 lotsAfter;
        for (uint256 i = 0; i < nClaims; i++) {
            lotsAfter += se.getUserStake(A, ids[i], 0) + se.getUserStake(B, ids[i], 1);
            assertLe(se.settledTotal(ids[i]), se.sMax() + 1, "sMax covers every settled total");
        }
        uint256 linkLotsAfter = _allLinkLots();
        int256 supplyDelta = int256(vsp.totalSupply()) - int256(before);
        int256 lotDelta = (int256(lotsAfter) - int256(lotsBefore)) + (int256(linkLotsAfter) - int256(linkLotsBefore));
        assertEq(supplyDelta, lotDelta, "supply delta == sum of lot deltas (mint - burn), nothing leaks");
    }

    function _allLinkLots() internal view returns (uint256 sum) {
        uint256 next = registry.nextPostId();
        for (uint256 p = 1; p < next; p++) {
            sum += se.getUserStake(C, p, 0);
        }
    }

    function _settleAllLinks() internal {
        uint256 next = registry.nextPostId();
        for (uint256 p = 1; p < next; p++) {
            if (se.getUserStake(C, p, 0) > 0) {
                se.updatePost(p);
            }
        }
    }
}
