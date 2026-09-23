// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";

import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// @title ScoreEngineMixedEvidence — patch_vs_pool_split regression
/// @notice Whitepaper §4.2.3:
///           totalSupport   = directSupport   + sum(positive contributions)
///           totalChallenge = directChallenge + |sum(negative contributions)|
///           pool           = totalSupport + totalChallenge
///         The pre-patch engine netted all contributions into ONE signed term
///         before folding it onto a side, so equal-and-opposite evidence left
///         the pool entirely and a contested claim scored like an unchallenged
///         one (mainnet claim #1, 2026-09-22: 2.0 direct support + one 1.0
///         support link + one 1.0 challenge link read +100% instead of +50%).
///         The numerator is identical under both readings; only the pool
///         differs, so WIN/LOSE sign never changes — magnitudes do.
contract ScoreEngineMixedEvidenceTest is Test {
    int256 internal constant RAY = 1e18;

    PostRegistry registry;
    StakeEngine stakeEng;
    LinkGraph graph;
    ScoreEngine score;
    MockVSP vsp;
    MockProtocolPolicy policy;

    function setUp() public {
        vsp = new MockVSP();
        policy = new MockProtocolPolicy(50);

        registry = PostRegistry(
            address(
                new ERC1967Proxy(
                    address(new PostRegistry(address(0))),
                    abi.encodeCall(PostRegistry.initialize, (address(this), address(vsp), address(policy)))
                )
            )
        );
        graph = LinkGraph(
            address(
                new ERC1967Proxy(
                    address(new LinkGraph(address(0))), abi.encodeCall(LinkGraph.initialize, (address(this)))
                )
            )
        );
        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        stakeEng = StakeEngine(
            address(
                new ERC1967Proxy(
                    address(new StakeEngine(address(0))),
                    abi.encodeCall(StakeEngine.initialize, (address(this), address(vsp), address(policy)))
                )
            )
        );
        score = ScoreEngine(
            address(
                new ERC1967Proxy(
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
            )
        );

        vsp.mint(address(this), 1e30);
        vsp.mint(address(registry), 1e30);
        vsp.approve(address(registry), type(uint256).max);
        vsp.approve(address(stakeEng), type(uint256).max);
    }

    function _claim(string memory text, uint256 support, uint256 challenge) internal returns (uint256 postId) {
        postId = registry.createClaim(text);
        if (support > 0) {
            stakeEng.stake(postId, 0, support);
        }
        if (challenge > 0) {
            stakeEng.stake(postId, 1, challenge);
        }
    }

    function _link(uint256 from, uint256 to, bool isChallenge, uint256 linkStake) internal returns (uint256 linkId) {
        linkId = registry.createLink(from, to, isChallenge);
        if (linkStake > 0) {
            stakeEng.stake(linkId, 0, linkStake);
        }
    }

    /// Mainnet claim #1 fixture (scaled x100): 200 direct support; two credible
    /// 100-stake parents, one supporting and one challenging via 100-stake links.
    /// Each contribution = 1.0 * 100 * (100/100) * 1.0 = 100.
    /// Whitepaper: (200+100 - (0+100)) / 400 = +50%.  Pre-patch engine: +100%.
    function test_MixedEvidence_BothSidesEnterPool() public {
        uint256 t = _claim("target", 200, 0);
        uint256 p1 = _claim("supporter", 100, 0);
        uint256 p2 = _claim("challenger", 100, 0);
        _link(p1, t, false, 100);
        _link(p2, t, true, 100);

        assertEq(score.effectiveVSRay(p1), RAY, "parent 1 must be +RAY");
        assertEq(score.effectiveVSRay(p2), RAY, "parent 2 must be +RAY");
        assertEq(score.effectiveVSRay(t), RAY / 2, "mixed evidence must dilute: expected +50%");
    }

    /// Asymmetric mix: 100 direct support, +100 support contribution, -300 challenge
    /// contribution. Whitepaper: (200 - 300) / 500 = -20%. Pre-patch (net -200 folded
    /// onto challenge): (100 - 200) / 300 = -33.3%. Sign agrees, magnitude does not.
    function test_MixedEvidence_AsymmetricUsesFullPool() public {
        uint256 t = _claim("target", 100, 0);
        uint256 p1 = _claim("supporter", 100, 0);
        uint256 p2 = _claim("challenger", 300, 0);
        _link(p1, t, false, 100);
        _link(p2, t, true, 300);

        assertEq(score.effectiveVSRay(t), -RAY / 5, "expected -20%");
    }

    /// Whitepaper §4.2.4 worked example (x100): single-sided contribution is
    /// unchanged by the patch — A(200) challenges B(100) via a 200-stake link.
    function test_Whitepaper424_Example_Unchanged() public {
        uint256 b = _claim("B", 100, 0);
        uint256 a = _claim("A", 200, 0);
        _link(a, b, true, 200);

        // (100 - 200) / 300 = -1/3
        assertEq(score.effectiveVSRay(b), -RAY / 3, "whitepaper 4.2.4 example");
    }

    /// Zero direct stake but active via contributions: +100 and -100 must yield a
    /// 200 pool and 0%, not an empty pool.
    function test_MixedEvidence_NoDirectStake_PoolIsContributions() public {
        uint256 t = _claim("target", 0, 0);
        uint256 p1 = _claim("supporter", 100, 0);
        uint256 p2 = _claim("challenger", 100, 0);
        _link(p1, t, false, 100);
        _link(p2, t, true, 100);

        assertEq(score.effectiveVSRay(t), 0, "balanced contributions -> 0%");
    }
}
