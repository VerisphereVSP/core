// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";
import "../src/ProtocolViews.sol";

import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

contract ProtocolViewsTest is Test {
    PostRegistry registry;
    LinkGraph graph;
    StakeEngine stake;
    ScoreEngine score;
    ProtocolViews views;

    MockVSP vsp;
    MockProtocolPolicy policy;

    function setUp() public {
        vsp = new MockVSP();
        policy = new MockProtocolPolicy(50);

        // ------------------------------------------------------------
        // PostRegistry (proxy)
        // ------------------------------------------------------------
        registry = PostRegistry(
            address(
                new ERC1967Proxy(
                    address(new PostRegistry(address(0))),
                    abi.encodeCall(
                        PostRegistry.initialize,
                        (
                            address(this), // governance
                            address(vsp),
                            address(policy)
                        )
                    )
                )
            )
        );

        // ------------------------------------------------------------
        // LinkGraph (proxy)
        // ------------------------------------------------------------
        graph = LinkGraph(
            address(
                new ERC1967Proxy(
                    address(new LinkGraph(address(0))),
                    abi.encodeCall(
                        LinkGraph.initialize,
                        (address(this)) // governance
                    )
                )
            )
        );

        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        // ------------------------------------------------------------
        // StakeEngine (proxy)
        // ------------------------------------------------------------
        stake = StakeEngine(
            address(
                new ERC1967Proxy(
                    address(new StakeEngine(address(0))),
                    abi.encodeCall(
                        StakeEngine.initialize,
                        (
                            address(this), // governance
                            address(vsp),
                            address(policy)
                        )
                    )
                )
            )
        );

        // ------------------------------------------------------------
        // ScoreEngine (proxy)
        // ------------------------------------------------------------
        score = ScoreEngine(
            address(
                new ERC1967Proxy(
                    address(new ScoreEngine(address(0))),
                    abi.encodeCall(
                        ScoreEngine.initialize,
                        (
                            address(this), // governance
                            address(registry),
                            address(stake),
                            address(graph),
                            address(policy),
                            address(policy)
                        )
                    )
                )
            )
        );

        // ------------------------------------------------------------
        // ProtocolViews (proxy)
        // ------------------------------------------------------------
        views = ProtocolViews(
            address(
                new ERC1967Proxy(
                    address(new ProtocolViews(address(0))),
                    abi.encodeCall(
                        ProtocolViews.initialize,
                        (
                            address(this), // governance
                            address(registry),
                            address(stake),
                            address(graph),
                            address(score),
                            address(policy)
                        )
                    )
                )
            )
        );

        // ------------------------------------------------------------
        // Fund + approve
        // ------------------------------------------------------------
        vsp.mint(address(this), 1e30);
        vsp.approve(address(stake), type(uint256).max);
        vsp.approve(address(registry), type(uint256).max);
    }

    function test_ActivationGate() public {
        uint256 c = registry.createClaim("C");

        stake.stake(c, 0, 10);
        assertFalse(views.isActive(c));

        stake.stake(c, 0, 40);
        assertTrue(views.isActive(c));
    }

    function test_ClaimSummaryAndRawRays() public {
        uint256 a = registry.createClaim("Drug X is safe");

        ProtocolViews.ClaimSummary memory s0 = views.getClaimSummary(a);
        assertEq(s0.text, "Drug X is safe");
        assertEq(s0.supportStake, 0);
        assertEq(s0.challengeStake, 0);
        assertEq(s0.totalStake, 0);
        assertEq(s0.postingFee, 50);
        assertFalse(s0.isActive);
        assertEq(s0.effectiveVSRay, 0);
        assertEq(s0.incomingCount, 0);
        assertEq(s0.outgoingCount, 0);

        stake.stake(a, 0, 49);
        ProtocolViews.ClaimSummary memory s1 = views.getClaimSummary(a);
        assertFalse(s1.isActive);
        // patch_game_b: base VS is no longer a view surface; a post has one score (effectiveVSRay)

        stake.stake(a, 0, 1);
        ProtocolViews.ClaimSummary memory s2 = views.getClaimSummary(a);
        assertTrue(s2.isActive);
        assertEq(s2.effectiveVSRay, 1e18);
    }

    function test_OutgoingIncomingEdgesContainMetadata() public {
        uint256 ic = registry.createClaim("IC");
        uint256 dc = registry.createClaim("DC");

        uint256 linkPostId = registry.createLink(ic, dc, false);

        LinkGraph.Edge[] memory out = views.getOutgoingEdges(ic);
        assertEq(out.length, 1);

        LinkGraph.IncomingEdge[] memory inc = views.getIncomingEdges(dc);
        assertEq(inc.length, 1);

        (uint256 indep, uint256 dep, bool isChal) = views.getLinkMeta(linkPostId);
        assertEq(indep, ic);
        assertEq(dep, dc);
        assertFalse(isChal);
    }

    function test_RawRayPassthroughsMatchScoreEngine() public {
        uint256 ic = registry.createClaim("IC");
        uint256 dc = registry.createClaim("DC");

        stake.stake(dc, 0, 50);
        stake.stake(ic, 0, 100);

        uint256 linkPostId = registry.createLink(ic, dc, false);
        stake.stake(linkPostId, 0, 50);

        // patch_game_b: getBaseVSRay removed (base VS internal)
        assertEq(views.getEffectiveVSRay(dc), score.effectiveVSRay(dc));
    }
}

