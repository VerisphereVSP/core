// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GameBInvariants.t.sol";

/// @title Whole-core invariant campaign (patch_core_invariants)
/// @notice Extends the settlement campaign (GameBInvariants) to the rest of core: lot accounting,
///         withdrawal liveness under SettleFirst and under pause, settlement idempotence, the rate
///         ceiling, supply conservation, PostRegistry dedupe/ids, and LinkGraph edge shape. Every
///         property is checked against the paper's rule, never against the code's own view of it.
///         Same handler shape as before: fully guarded actions, ghosts for anything that must
///         never happen, invariants that read only public state.
contract CoreHandler is GameBHandler {
    address public gov; // governance of every proxy (the test contract)

    // ghosts: each must stay 0
    uint256 public exitFailures; // a full withdrawal failed (after one keeper settle if SettleFirst)
    uint256 public stakedWhilePaused; // stake() succeeded while paused
    uint256 public exitBlockedByPause; // withdraw() reverted while paused (the pause docs promise exit)
    uint256 public resettleChanges; // updatePost twice in one epoch changed a total
    uint256 public rateViolations; // a settlement moved a post's total faster than rMax allows
    uint256 public dupClaimsAccepted; // createClaim accepted a normalised duplicate
    uint256 public postsCreated; // fee-paying creates that succeeded (claims + links)
    bytes public lastExitRevert;
    uint256 public worstRateExcess;
    uint256 public projectionMismatches; // getPostTotals projected a different number than settlement paid
    uint256 public worstProjectionGap;
    uint256 public worstProjectionPost;

    // settlement counter for the dust bound (bucket index rebase strands <= 1 wei per settle)
    uint256 public settlements;

    constructor(PostRegistry r, StakeEngine s, LinkGraph g, ScoreEngine sc, MockVSP v, address gov_)
        GameBHandler(r, s, g, sc, v)
    {
        gov = gov_;
    }

    // ───────────────────────── overrides: count fee-paying creates ─────────────────────────

    function hCreateClaim(uint256 aSeed) public override {
        uint256 before = claims.length;
        super.hCreateClaim(aSeed);
        if (claims.length > before) {
            postsCreated++;
        }
    }

    function hCreateLink(uint256 fSeed, uint256 tSeed, uint256 aSeed, bool isChallenge) public override {
        uint256 before = allPosts.length;
        super.hCreateLink(fSeed, tSeed, aSeed, isChallenge);
        if (allPosts.length > before) {
            postsCreated++;
        }
    }

    function hCycle(uint256 aSeed, uint256 bSeed, uint256 actorSeed) public override {
        uint256 before = allPosts.length;
        uint256 balBefore = vsp.balanceOf(address(stakeEng));
        super.hCycle(aSeed, bSeed, actorSeed);
        uint256 added = allPosts.length - before;
        postsCreated += added;
        // the base action stakes 2 VSP on each new link-post: book it like hStake does
        uint256 dep = vsp.balanceOf(address(stakeEng)) - balBefore;
        ghostDeposited += dep;
        ghostOps += dep == 0 ? 0 : (dep + 2e18 - 1) / 2e18;
        for (uint256 i = before; i < allPosts.length; i++) {
            if (stakeEng.getUserStake(actors[actorSeed % actors.length], allPosts[i], 0) > 0) {
                sidePlusOne[actors[actorSeed % actors.length]][allPosts[i]] = 1;
            }
        }
    }

    /// Stake while possibly paused: a success under pause is a finding.
    function hStake(uint256 pSeed, uint256 aSeed, uint8 sideIn, uint256 amtSeed) public override {
        bool wasPaused = stakeEng.paused();
        uint256 balBefore = vsp.balanceOf(address(stakeEng));
        super.hStake(pSeed, aSeed, sideIn, amtSeed);
        if (wasPaused && vsp.balanceOf(address(stakeEng)) > balBefore) {
            stakedWhilePaused++;
        }
    }

    // ───────────────────────── new actions ─────────────────────────

    /// Full exit: a user with a lot must always be able to take all of it out. The only
    /// acceptable revert is SettleFirst(postId), after which one keeper settlement must
    /// unblock it. Pause must not block exit (StakeEngine docs: withdraws stay open).
    function hExit(uint256 pSeed, uint256 aSeed) public {
        if (allPosts.length == 0) {
            return;
        }
        address actor = actors[aSeed % actors.length];
        uint256 post = allPosts[pSeed % allPosts.length];
        uint8 chosen = sidePlusOne[actor][post];
        if (chosen == 0) {
            return;
        }
        uint8 side = chosen - 1;
        uint256 avail = stakeEng.getUserStake(actor, post, side);
        if (avail == 0) {
            return;
        }
        bool wasPaused = stakeEng.paused();
        uint256 balBefore = vsp.balanceOf(address(stakeEng));
        vm.prank(actor);
        try stakeEng.withdraw(post, side, avail, false) {
            ghostWithdrawn += balBefore - vsp.balanceOf(address(stakeEng));
            ghostOps++;
            return;
        } catch (bytes memory reason) {
            if (wasPaused && bytes4(reason) == StakeEngine.WhenPaused.selector) {
                exitBlockedByPause++;
                return;
            }
            if (bytes4(reason) != StakeEngine.SettleFirst.selector) {
                exitFailures++;
                lastExitRevert = reason;
                return;
            }
        }
        // SettleFirst: the keeper path must clear it.
        try stakeEng.updatePost(post) {
            settlements++;
        } catch (bytes memory reason) {
            exitFailures++;
            lastExitRevert = reason;
            return;
        }
        avail = stakeEng.getUserStake(actor, post, side);
        if (avail == 0) {
            return; // settlement burned the lot to zero — nothing left to exit
        }
        balBefore = vsp.balanceOf(address(stakeEng));
        vm.prank(actor);
        try stakeEng.withdraw(post, side, avail, false) {
            ghostWithdrawn += balBefore - vsp.balanceOf(address(stakeEng));
            ghostOps++;
        } catch (bytes memory reason) {
            exitFailures++;
            lastExitRevert = reason;
        }
    }

    /// Guardian pause / governance unpause on the StakeEngine.
    function hPause(bool on) public {
        if (on) {
            vm.prank(gov);
            stakeEng.pause();
        } else {
            vm.prank(gov);
            stakeEng.unpause();
        }
    }

    /// Epoch step with three checks folded in:
    ///  - rate ceiling: |ΔT| over the settlement <= T_before * rMax * epochsElapsed / year (+dust)
    ///  - idempotence: a second updatePost in the same epoch changes nothing
    ///  - settlement always succeeds (inherited ghost)
    function hEpoch(uint256 daysSeed) public override {
        uint256 nDays = bound(daysSeed, 1, 7);
        uint256 n = allPosts.length;
        // stored (settled) totals: state is settled at entry, so getPostTotals does not project here
        uint256[] memory t0 = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            (uint256 a, uint256 d) = stakeEng.getPostTotals(allPosts[i]);
            t0[i] = a + d;
        }
        vm.warp(block.timestamp + nDays * 1 days);
        uint256 nowEpoch = block.timestamp / stakeEng.EPOCH_LENGTH();
        uint256 rMaxRay = MockProtocolPolicy(address(stakeEng.protocolPolicy())).stakeIntRateMaxRay();
        for (uint256 i = 0; i < n; i++) {
            uint256 p = allPosts[i];
            uint256 last = stakeEng.getLastSnapshotEpoch(p);
            uint256 elapsed = last == 0 || nowEpoch <= last ? 0 : nowEpoch - last;
            // what the view PROJECTS for this settlement (getPostTotals projects once the epoch passed)
            (uint256 pa, uint256 pd) = stakeEng.getPostTotals(p);
            try stakeEng.updatePost(p) {
                settled++;
                settlements++;
            } catch (bytes memory reason) {
                settleReverts++;
                lastRevert = reason;
                continue;
            }
            (uint256 a1, uint256 d1) = stakeEng.getPostTotals(p);
            uint256 t1 = a1 + d1;
            uint256 moved = t1 > t0[i] ? t1 - t0[i] : t0[i] - t1;
            // whitepaper §3.2: delta <= amount * rBase, rBase <= rMax * epochs * EPOCH/YEAR
            uint256 cap = (t0[i] * rMaxRay * stakeEng.EPOCH_LENGTH() * elapsed) / stakeEng.YEAR_LENGTH() / 1e18;
            if (moved > cap + 1e6) {
                rateViolations++;
                if (moved - cap > worstRateExcess) {
                    worstRateExcess = moved - cap;
                }
            }
            ghostSettleNet += int256(t1) - int256(t0[i]);
            // projection == settlement (V.8 "view == materialised"): per side, up to dust
            uint256 dA = pa > a1 ? pa - a1 : a1 - pa;
            uint256 dD = pd > d1 ? pd - d1 : d1 - pd;
            if (dA + dD > 1e6) {
                projectionMismatches++;
                if (dA + dD > worstProjectionGap) {
                    worstProjectionGap = dA + dD;
                    worstProjectionPost = p;
                }
            }
            // idempotence
            try stakeEng.updatePost(p) {} catch {}
            (uint256 a2, uint256 d2) = stakeEng.getPostTotals(p);
            if (a2 != a1 || d2 != d1) {
                resettleChanges++;
            }
        }
    }

    /// patch_settlement_snapshots: a keeper pass in the WRONG order after a skipped epoch — advance
    /// 2..7 epochs (so every snapshot is now stale), settle one parity class first (its children read
    /// stale ancestors: StaleParentUsed, never a revert), then the other. State is fully settled at
    /// the end, as every invariant here assumes.
    function hEpochPartial(uint256 daysSeed, uint256 parity) public {
        uint256 nDays = bound(daysSeed, 2, 7);
        uint256 n = allPosts.length;
        uint256[] memory t0 = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            (uint256 a, uint256 d) = stakeEng.getPostTotals(allPosts[i]);
            t0[i] = a + d;
        }
        vm.warp(block.timestamp + nDays * 1 days);
        for (uint256 pass = 0; pass < 2; pass++) {
            for (uint256 i = 0; i < n; i++) {
                if ((i + (parity % 2) + pass) % 2 != 0) {
                    continue;
                }
                try stakeEng.updatePost(allPosts[i]) {
                    settled++;
                    settlements++;
                } catch (bytes memory reason) {
                    settleReverts++;
                    lastRevert = reason;
                    continue;
                }
                (uint256 a1, uint256 d1) = stakeEng.getPostTotals(allPosts[i]);
                ghostSettleNet += int256(a1 + d1) - int256(t0[i]);
            }
        }
    }

    /// The base warp action is folded into hEpoch so every settlement is counted and checked.
    function hWarp(uint256 daysSeed) public override {
        hEpoch(daysSeed);
    }

    /// Re-post an existing claim's text (normalised variants): must revert DuplicateClaim.
    function hDupClaim(uint256 cSeed, uint256 aSeed, uint8 variant) public {
        if (claims.length == 0) {
            return;
        }
        uint256 c = claims[cSeed % claims.length];
        string memory t = registry.getClaim(registry.getPost(c).contentId);
        if (variant % 3 == 1) {
            t = string(abi.encodePacked("  ", t, " "));
        } else if (variant % 3 == 2) {
            t = _upper(t);
        }
        address actor = actors[aSeed % actors.length];
        vm.prank(actor);
        try registry.createClaim(t) returns (uint256 id) {
            dupClaimsAccepted++;
            claims.push(id);
            allPosts.push(id);
            postsCreated++;
        } catch {}
    }

    function _upper(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] >= 0x61 && b[i] <= 0x7a) {
                b[i] = bytes1(uint8(b[i]) - 32);
            }
        }
        return string(b);
    }
}

/// forge-config: default.invariant.runs = 12
/// forge-config: default.invariant.depth = 120
/// forge-config: default.invariant.fail-on-revert = true
contract CoreInvariantsTest is Test {
    PostRegistry registry;
    StakeEngine stakeEng;
    LinkGraph graph;
    ScoreEngine score;
    MockVSP vsp;
    CoreHandler handler;

    uint256 constant FEE = 1e18;
    uint256 constant FUND = 1e30; // ProtocolHandler.FUND, per actor
    int256 constant RAY = 1e18;
    uint256 supply0;

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    function setUp() public {
        vsp = new MockVSP();
        MockProtocolPolicy policy = new MockProtocolPolicy(FEE);
        registry = PostRegistry(
            _proxy(
                address(new PostRegistry(address(0))),
                abi.encodeCall(PostRegistry.initialize, (address(this), address(vsp), address(policy)))
            )
        );
        graph = LinkGraph(
            _proxy(address(new LinkGraph(address(0))), abi.encodeCall(LinkGraph.initialize, (address(this))))
        );
        stakeEng = StakeEngine(
            _proxy(
                address(new StakeEngine(address(0))),
                abi.encodeCall(StakeEngine.initialize, (address(this), address(vsp), address(policy)))
            )
        );
        score = ScoreEngine(
            _proxy(
                address(new ScoreEngine(address(0))),
                abi.encodeCall(
                    ScoreEngine.initialize,
                    (
                        address(this),
                        address(registry),
                        address(stakeEng),
                        address(graph),
                        address(policy),
                        address(policy)
                    )
                )
            )
        );
        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));
        stakeEng.setScoreEngine(address(score));
        vm.warp(1_800_000_000);
        handler = new CoreHandler(registry, stakeEng, graph, score, vsp, address(this));
        supply0 = vsp.totalSupply();
        targetContract(address(handler));
    }

    // ───────────────────────── ghosts (things that must never happen) ─────────────────────────

    function invariant_everyPostSettles() public view {
        assertEq(
            handler.settleReverts(), 0, string(abi.encodePacked("settle revert: ", vm.toString(handler.lastRevert())))
        );
    }

    /// EXIT LIVENESS: a full withdrawal never fails, paused or not, beyond one SettleFirst round-trip.
    function invariant_exitAlwaysPossible() public view {
        assertEq(handler.exitBlockedByPause(), 0, "pause blocked a withdrawal");
        assertEq(
            handler.exitFailures(), 0, string(abi.encodePacked("exit failed: ", vm.toString(handler.lastExitRevert())))
        );
    }

    /// PAUSE: no stake lands while paused.
    function invariant_pauseBlocksStake() public view {
        assertEq(handler.stakedWhilePaused(), 0, "stake succeeded while paused");
    }

    /// IDEMPOTENCE: settling twice in one epoch is a no-op the second time.
    function invariant_settlementIdempotent() public view {
        assertEq(handler.resettleChanges(), 0, "second updatePost in the same epoch changed totals");
    }

    /// RATE CEILING (§3.2): no post's total moves faster than rMax per epoch.
    function invariant_rateCeiling() public view {
        assertEq(
            handler.rateViolations(),
            0,
            string(abi.encodePacked("rate ceiling exceeded by ", vm.toString(handler.worstRateExcess()), " wei"))
        );
    }

    /// PROJECTION == SETTLEMENT (spec V.8): what getPostTotals shows before settlement is what
    /// settlement pays. Finding CI-1 (2026-09-28) — closed by patch_settlement_snapshots: one rate
    /// path (_projectRate / TimeWeighted.lotDelta / bucketIndexAfter / projectSMax) for both.
    function invariant_projectionMatchesSettlement() public view {
        assertEq(
            handler.projectionMismatches(),
            0,
            string(
                abi.encodePacked(
                    "projection differs from settlement by ",
                    vm.toString(handler.worstProjectionGap()),
                    " wei on post ",
                    vm.toString(handler.worstProjectionPost())
                )
            )
        );
    }

    /// DEDUPE (§2): normalised duplicates are rejected.
    function invariant_noDuplicateClaims() public view {
        assertEq(handler.dupClaimsAccepted(), 0, "duplicate claim accepted");
    }

    // ───────────────────────── accounting ─────────────────────────

    /// LOTS SUM TO TOTALS: per post and side, Σ user lots == side total, up to engine-favouring
    /// dust (<= 1 wei per mutating op or settlement, bucket share<->index floor).
    function invariant_lotsSumToTotals() public view {
        uint256[] memory posts = handler.getAllPosts();
        address[] memory acts = handler.getActors();
        uint256 dust = handler.ghostOps() + handler.settlements();
        for (uint256 i = 0; i < posts.length; i++) {
            (uint256 A, uint256 D) = stakeEng.getPostTotals(posts[i]);
            uint256 sa;
            uint256 sd;
            for (uint256 j = 0; j < acts.length; j++) {
                sa += stakeEng.getUserStake(acts[j], posts[i], 0);
                sd += stakeEng.getUserStake(acts[j], posts[i], 1);
            }
            assertLe(sa, A, "user lots exceed support total");
            assertLe(sd, D, "user lots exceed challenge total");
            assertLe(A - sa, dust, "support total above lots by more than dust");
            assertLe(D - sd, dust, "challenge total above lots by more than dust");
        }
    }

    /// SOLVENCY: engine balance >= every post total (not just every lot).
    function invariant_engineSolvent() public view {
        uint256[] memory posts = handler.getAllPosts();
        uint256 sum;
        for (uint256 i = 0; i < posts.length; i++) {
            (uint256 A, uint256 D) = stakeEng.getPostTotals(posts[i]);
            sum += A + D;
        }
        assertGe(vsp.balanceOf(address(stakeEng)), sum, "engine balance below sum of post totals");
    }

    /// SUPPLY (§5): totalSupply == initial − fees burned + settlement net (mint − burn), exactly.
    function invariant_supplyConserved() public view {
        int256 expected = int256(supply0) - int256(handler.postsCreated() * FEE) + handler.ghostSettleNet();
        assertEq(int256(vsp.totalSupply()), expected, "supply drifted from fees + settlement net");
    }

    /// CONSERVATION: post totals == deposited − withdrawn + settlement net, engine-favouring dust only.
    function invariant_totalsConserved() public view {
        uint256[] memory posts = handler.getAllPosts();
        uint256 sum;
        for (uint256 i = 0; i < posts.length; i++) {
            (uint256 A, uint256 D) = stakeEng.getPostTotals(posts[i]);
            sum += A + D;
        }
        int256 lhs = int256(sum + handler.ghostWithdrawn());
        int256 rhs = int256(handler.ghostDeposited()) + handler.ghostSettleNet();
        assertLe(lhs, rhs, "engine leaked value");
        assertLe(rhs - lhs, int256(handler.ghostOps() + handler.settlements()), "conservation gap above dust");
    }

    /// OUTSUM (v18 §4.2.2): a claim's outgoing sum equals the sum of its links' recorded entries —
    /// maintained state that must never drift from the records it is built from.
    function invariant_outSumConsistent() public view {
        uint256[] memory cl = handler.getClaims();
        for (uint256 i = 0; i < cl.length; i++) {
            LinkGraph.Edge[] memory outs = graph.getOutgoing(cl[i]);
            uint256 sum;
            for (uint256 k = 0; k < outs.length; k++) {
                sum += score.outContrib(outs[k].linkPostId);
            }
            assertEq(score.outSum(cl[i]), sum, "outSum drifted from the links' entries");
        }
    }

    /// NO GHOST LEADER (review C-4): whenever sMax > 0, the post that defines it has live stake.
    function invariant_noGhostLeader() public view {
        if (stakeEng.sMax() == 0) {
            return;
        }
        uint256 leader = stakeEng.sMaxPostId();
        (uint256 A, uint256 D) = stakeEng.getPostTotals(leader);
        assertGt(A + D, 0, "sMax is defined by a drained post");
    }

    // ───────────────────────── registry & graph shape ─────────────────────────

    /// IDS (§1): ids are dense from 1; every successful create consumed exactly one id.
    function invariant_idsDense() public view {
        assertEq(registry.nextPostId(), handler.postsCreated() + 1, "nextPostId != creates + 1");
    }

    /// EDGES: no self-edge, no duplicate (from, polarity) into a claim, every from is a claim,
    /// incoming count within the absolute cap, and getIncoming/getOutgoing agree.
    function invariant_edgeShape() public view {
        uint256[] memory cl = handler.getClaims();
        for (uint256 i = 0; i < cl.length; i++) {
            LinkGraph.IncomingEdge[] memory inc = graph.getIncoming(cl[i]);
            assertLe(inc.length, graph.MAX_INCOMING_LINKS_PER_CLAIM(), "incoming above cap");
            for (uint256 k = 0; k < inc.length; k++) {
                assertTrue(inc[k].fromClaimPostId != cl[i], "self edge");
                assertTrue(
                    registry.getPost(inc[k].fromClaimPostId).contentType == PostRegistry.ContentType.Claim,
                    "from not a claim"
                );
                assertTrue(graph.hasEdge(inc[k].fromClaimPostId, cl[i], inc[k].isChallenge), "incoming not in outgoing");
                for (uint256 m = k + 1; m < inc.length; m++) {
                    assertFalse(
                        inc[m].fromClaimPostId == inc[k].fromClaimPostId && inc[m].isChallenge == inc[k].isChallenge,
                        "duplicate (from, polarity) edge"
                    );
                }
            }
        }
    }

    /// EDGE VIEW == POOL: the per-edge view the app reads sums to the pool the chain settles on.
    /// Finding CI-2 (2026-09-28) — closed by patch_settlement_snapshots: one eligibility/ranking
    /// function serves settlement and getEdgeContribution.
    function invariant_edgeContributionsSumToPool() public view {
        uint256[] memory cl = handler.getClaims();
        for (uint256 i = 0; i < cl.length; i++) {
            (uint256 A, uint256 D) = stakeEng.getPostTotals(cl[i]);
            (uint256 S, uint256 C,) = score.effectivePool(cl[i]);
            if (S + C == 0) {
                continue;
            }
            LinkGraph.IncomingEdge[] memory inc = graph.getIncoming(cl[i]);
            uint256 pos;
            uint256 neg;
            for (uint256 k = 0; k < inc.length; k++) {
                int256 e = score.getEdgeContribution(cl[i], inc[k].linkPostId);
                if (e > 0) {
                    pos += uint256(e);
                } else {
                    neg += uint256(-e);
                }
            }
            _assertClose(pos, S - A, 1e6, "sum of positive edges != S - A");
            _assertClose(neg, C - D, 1e6, "sum of negative edges != C - D");
        }
    }

    function _assertClose(uint256 x, uint256 y, uint256 tol, string memory msg_) internal pure {
        uint256 d = x > y ? x - y : y - x;
        assertLe(d, tol, msg_);
    }
}
