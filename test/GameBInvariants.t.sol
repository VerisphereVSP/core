// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ProtocolInvariants.t.sol";

/// @title Game B invariant campaign (whitepaper v17)
/// @notice Stateful fuzz over random graphs — cycles included — with the ScoreEngine WIRED into
///         settlement. The handler's epoch step asserts that every post settles: a settlement
///         revert is a finding, never swallowed (the cycle-freeze report of 2026-09-26 escaped the
///         base invariants because hWarp caught updatePost failures silently).
///         forge-config below runs longer than the default suite; run standalone for hours with
///         `forge test --match-contract GameBInvariants --fuzz-runs N`.
contract GameBHandler is ProtocolHandler {
    uint256 public settleReverts; // ghost: must stay 0
    uint256 public settled;
    bytes public lastRevert;

    constructor(PostRegistry r, StakeEngine s, LinkGraph g, ScoreEngine sc, MockVSP v)
        ProtocolHandler(r, s, g, sc, v)
    {}

    /// Epoch step: advance 1..7 days and settle EVERY post, recording any revert.
    function hEpoch(uint256 daysSeed) public virtual {
        uint256 nDays = bound(daysSeed, 1, 7);
        vm.warp(block.timestamp + nDays * 1 days);
        uint256 n = allPosts.length;
        for (uint256 i = 0; i < n; i++) {
            try stakeEng.updatePost(allPosts[i]) {
                settled++;
            } catch (bytes memory reason) {
                settleReverts++;
                lastRevert = reason;
            }
        }
    }

    /// Deliberate 2-cycles between random claims (the reported shape), staked so they are active.
    function hCycle(uint256 aSeed, uint256 bSeed, uint256 actorSeed) public virtual {
        if (claims.length < 2 || allPosts.length + 2 > MAX_POSTS) {
            return;
        }
        uint256 a = claims[aSeed % claims.length];
        uint256 b = claims[bSeed % claims.length];
        if (a == b) {
            return;
        }
        address actor = actors[actorSeed % actors.length];
        vm.startPrank(actor);
        try registry.createLink(a, b, aSeed % 2 == 0) returns (uint256 l1) {
            allPosts.push(l1);
            try stakeEng.stake(l1, 0, 2e18) {} catch {}
        } catch {}
        try registry.createLink(b, a, bSeed % 2 == 0) returns (uint256 l2) {
            allPosts.push(l2);
            try stakeEng.stake(l2, 0, 2e18) {} catch {}
        } catch {}
        vm.stopPrank();
    }
}

/// forge-config: default.invariant.runs = 12
/// forge-config: default.invariant.depth = 120
/// forge-config: default.invariant.fail-on-revert = false
contract GameBInvariantsTest is Test {
    PostRegistry registry;
    StakeEngine stakeEng;
    LinkGraph graph;
    ScoreEngine score;
    MockVSP vsp;
    GameBHandler handler;

    uint256 constant FEE = 1e18;
    int256 constant RAY = 1e18;

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
        stakeEng.setScoreEngine(address(score)); // GAME B: settlement pays on the effective pool
        vm.warp(1_800_000_000);
        handler = new GameBHandler(registry, stakeEng, graph, score, vsp);
        targetContract(address(handler));
    }

    /// FREEZE-FREEDOM: no post has ever failed to settle, whatever graph the fuzzer built.
    function invariant_everyPostSettles() public view {
        assertEq(
            handler.settleReverts(),
            0,
            string(abi.encodePacked("a settlement reverted: ", vm.toString(handler.lastRevert())))
        );
    }

    /// SOLVENCY: the engine holds at least the sum of all live lots.
    function invariant_engineSolvent() public view {
        uint256[] memory posts = handler.getAllPosts();
        address[] memory actors = handler.getActors();
        uint256 sum;
        for (uint256 i = 0; i < posts.length; i++) {
            for (uint256 j = 0; j < actors.length; j++) {
                sum += stakeEng.getUserStake(actors[j], posts[i], 0) + stakeEng.getUserStake(actors[j], posts[i], 1);
            }
        }
        assertGe(vsp.balanceOf(address(stakeEng)), sum, "engine balance below sum of lots");
    }

    /// POOL BOUNDS: S >= A, C >= D (evidence only adds), and contributions never exceed the parents'
    /// available mass (Σ parentVS·parentT over active parents). Also: the pool of a post with no
    /// incoming links equals its direct totals (display path == direct when there is no evidence).
    function invariant_poolBounded() public view {
        uint256[] memory claims = handler.getClaims();
        for (uint256 i = 0; i < claims.length; i++) {
            uint256 c = claims[i];
            (uint256 A, uint256 D) = stakeEng.getPostTotals(c);
            (uint256 S, uint256 C,) = score.effectivePool(c);
            if (S + C == 0) {
                continue; // inactive: pool reads 0 by rule
            }
            assertGe(S, A, "S < direct support");
            assertGe(C, D, "C < direct challenge");
            uint256 mass;
            LinkGraph.IncomingEdge[] memory inc = graph.getIncoming(c);
            for (uint256 k = 0; k < inc.length; k++) {
                (uint256 pa, uint256 pd) = stakeEng.getPostTotals(inc[k].fromClaimPostId);
                mass += pa + pd; // parentVS <= 1, so mass <= parentT
            }
            assertLe((S - A) + (C - D), mass + 1, "contributions exceed parents' total stake");
        }
    }

    /// SCORE BOUNDS: effective VS in [-RAY, RAY]; sign agrees with the pool.
    function invariant_scoreBounded() public view {
        uint256[] memory posts = handler.getAllPosts();
        for (uint256 i = 0; i < posts.length; i++) {
            int256 v = score.effectiveVSRay(posts[i]);
            assertLe(v, RAY);
            assertGe(v, -RAY);
            (uint256 S, uint256 C,) = score.effectivePool(posts[i]);
            if (S > C) {
                assertGt(v, 0, "S > C but VS <= 0");
            }
            if (C > S) {
                assertLt(v, 0, "C > S but VS >= 0");
            }
        }
    }

    /// sMax covers every settled total (participation <= 1 for everyone).
    function invariant_sMaxCovers() public view {
        uint256[] memory posts = handler.getAllPosts();
        uint256 sMax = stakeEng.sMax();
        for (uint256 i = 0; i < posts.length; i++) {
            assertLe(stakeEng.settledTotal(posts[i]), sMax + 1, "settled total above sMax");
        }
    }

    // (A "time-weighted totals <= live totals" invariant was tried and removed: decay at a settlement
    // inside the open window legitimately puts the window average above the live total. The exact
    // arithmetic is pinned in WhitepaperConformanceV2 instead.)
}
