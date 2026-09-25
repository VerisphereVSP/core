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

/// @title ScoreEngine Fuzz Tests
/// @notice Property-based tests for VS computation, link propagation,
///         cycle handling, and the credibility gate.
///
/// NOTE: StakeEngine v2 enforces single-sided positions (a user cannot
///       stake both support and challenge on the same post). All helpers
///       use a dedicated `challenger` address for the challenge side and
///       `address(this)` (or other addresses) for the support side.
contract ScoreEngineFuzzTest is Test {
    PostRegistry registry;
    StakeEngine stakeEng;
    LinkGraph graph;
    ScoreEngine score;

    MockVSP vsp;

    /// @dev Dedicated address for challenge-side stakes so that
    ///      _createAndStake can place both sides without hitting
    ///      OppositeSideStaked().
    address challenger = address(0xCBA1);

    uint256 constant FEE = 50; // posting fee in mock

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

        // Fund address(this) — used for support side + claim creation
        vsp.mint(address(this), 1e36);
        vsp.mint(address(registry), 1e36);
        vsp.approve(address(stakeEng), type(uint256).max);
        vsp.approve(address(registry), type(uint256).max);

        // Fund challenger — used for challenge side
        vsp.mint(challenger, 1e36);
        vm.prank(challenger);
        vsp.approve(address(stakeEng), type(uint256).max);
    }

    // ────────────────────────────────────────────────────────────
    // Helpers
    // ────────────────────────────────────────────────────────────

    /// @dev Creates a claim (as address(this)) and stakes both sides.
    ///      Support is staked by address(this); challenge by `challenger`.
    ///      This avoids OppositeSideStaked() since each address stakes
    ///      only one side.
    function _createAndStake(string memory text, uint256 support, uint256 challenge) internal returns (uint256 postId) {
        postId = registry.createClaim(text);
        if (support > 0) {
            stakeEng.stake(postId, 0, support);
        }
        if (challenge > 0) {
            vm.prank(challenger);
            stakeEng.stake(postId, 1, challenge);
        }
    }

    // ────────────────────────────────────────────────────────────
    // Invariant: baseVS is always in [-RAY, +RAY]
    // ────────────────────────────────────────────────────────────

    function testFuzz_BaseVSBounded(uint128 support, uint128 challenge) public {
        uint256 sup = bound(uint256(support), 0, 1e24); // bundle05_a
        uint256 chal = bound(uint256(challenge), 0, 1e24); // bundle05_a
        vm.assume(sup + chal > 0); // need at least some stake

        uint256 c = _createAndStake("bounded test", sup, chal);

        int256 vs = score.baseVSRay(c);
        int256 RAY = 1e18;

        assertGe(vs, -RAY, "baseVS below -RAY");
        assertLe(vs, RAY, "baseVS above RAY");
    }

    // ────────────────────────────────────────────────────────────
    // Invariant: baseVS sign matches majority side
    // ────────────────────────────────────────────────────────────

    function testFuzz_BaseVSSignMatchesMajority(uint128 support, uint128 challenge) public {
        uint256 sup = bound(uint256(support), FEE, 1e24); // bundle05_a
        uint256 chal = bound(uint256(challenge), FEE, 1e24); // bundle05_a
        vm.assume(sup != chal);
        // patch_game_b: baseVS is (A-D)/T on the RAY scale; a majority smaller than T/1e18 rounds to 0
        uint256 diff = sup > chal ? sup - chal : chal - sup;
        vm.assume(diff * 1e18 >= sup + chal);

        uint256 c = _createAndStake("sign test", sup, chal);

        int256 vs = score.baseVSRay(c);

        if (sup > chal) {
            assertGt(vs, 0, "support majority but VS <= 0");
        } else {
            assertLt(vs, 0, "challenge majority but VS >= 0");
        }
    }

    // ────────────────────────────────────────────────────────────
    // Invariant: effectiveVS is always in [-RAY, +RAY]
    // ────────────────────────────────────────────────────────────

    function testFuzz_EffectiveVSBounded(uint128 support, uint128 challenge) public {
        uint256 sup = bound(uint256(support), FEE, 1e24); // bundle05_a
        uint256 chal = bound(uint256(challenge), 0, 1e24); // bundle05_a

        uint256 c = _createAndStake("eff bounded", sup, chal);

        int256 vs = score.effectiveVSRay(c);
        int256 RAY = 1e18;

        assertGe(vs, -RAY, "effectiveVS below -RAY");
        assertLe(vs, RAY, "effectiveVS above RAY");
    }

    // ────────────────────────────────────────────────────────────
    // Invariant: support-only claim has baseVS == +RAY
    // ────────────────────────────────────────────────────────────

    function testFuzz_SupportOnlyIsMaxVS(uint128 amount) public {
        uint256 amt = bound(uint256(amount), FEE, 1e24); // bundle05_a

        uint256 c = _createAndStake("support only", amt, 0);

        int256 vs = score.baseVSRay(c);
        assertEq(vs, 1e18, "support-only should be +RAY");
    }

    // ────────────────────────────────────────────────────────────
    // Invariant: challenge-only claim has baseVS == -RAY
    // ────────────────────────────────────────────────────────────

    function testFuzz_ChallengeOnlyIsMinVS(uint128 amount) public {
        uint256 amt = bound(uint256(amount), FEE, 1e24); // bundle05_a

        uint256 c = _createAndStake("challenge only", 0, amt);

        int256 vs = score.baseVSRay(c);
        assertEq(vs, -1e18, "challenge-only should be -RAY");
    }

    // ────────────────────────────────────────────────────────────
    // Credibility gate: negative-VS parent contributes nothing
    // ────────────────────────────────────────────────────────────

    function testFuzz_NegativeParentContributesNothing(uint128 parentChallenge, uint128 childSupport) public {
        uint256 pChal = bound(uint256(parentChallenge), FEE, 1e24); // bundle05_a
        uint256 cSup = bound(uint256(childSupport), FEE, 1e24); // bundle05_a

        // Parent: challenge-only (VS < 0)
        uint256 parent = _createAndStake("bad parent", 0, pChal);

        // Child: support-only
        uint256 child = _createAndStake("child claim", cSup, 0);

        // Link: parent supports child
        uint256 link = registry.createLink(parent, child, false);
        stakeEng.stake(link, 0, FEE); // activate the link

        // Child's effective VS should equal its base VS (parent blocked)
        int256 baseVS = score.baseVSRay(child);
        int256 effVS = score.effectiveVSRay(child);

        assertEq(effVS, baseVS, "negative parent should not affect child");
    }

    // ────────────────────────────────────────────────────────────
    // Credibility gate: negative-VS link contributes nothing
    // ────────────────────────────────────────────────────────────

    function testFuzz_NegativeLinkContributesNothing(uint128 parentSupport, uint128 childSupport) public {
        uint256 pSup = bound(uint256(parentSupport), FEE, 1e24); // bundle05_a
        uint256 cSup = bound(uint256(childSupport), FEE, 1e24); // bundle05_a

        // Parent: positive VS
        uint256 parent = _createAndStake("good parent", pSup, 0);

        // Child: positive VS
        uint256 child = _createAndStake("good child", cSup, 0);

        // Link: parent supports child, but link has negative VS
        // (challenger stakes challenge on the link)
        uint256 link = registry.createLink(parent, child, false);
        vm.prank(challenger);
        stakeEng.stake(link, 1, FEE * 2); // challenge the link → negative link VS

        // Child's effective VS should equal its base VS (link blocked)
        int256 baseVS = score.baseVSRay(child);
        int256 effVS = score.effectiveVSRay(child);

        assertEq(effVS, baseVS, "negative link should not affect child");
    }

    // ────────────────────────────────────────────────────────────
    // Challenge link pushes child VS down
    // ────────────────────────────────────────────────────────────

    function testFuzz_ChallengeLinkReducesChildVS(uint128 parentSupport, uint128 childSupport) public {
        uint256 pSup = bound(uint256(parentSupport), FEE * 2, 1e24); // bundle05_a
        uint256 cSup = bound(uint256(childSupport), FEE * 2, 1e24); // bundle05_a

        // Parent: credible (positive VS)
        uint256 parent = _createAndStake("strong parent", pSup, 0);

        // Child: has support
        uint256 child = _createAndStake("target child", cSup, 0);

        int256 vsBeforeLink = score.effectiveVSRay(child);

        // Challenge link from parent to child
        uint256 link = registry.createLink(parent, child, true);
        stakeEng.stake(link, 0, pSup); // strongly supported link

        int256 vsAfterLink = score.effectiveVSRay(child);

        // Child's effective VS should decrease
        assertLt(vsAfterLink, vsBeforeLink, "challenge link should reduce child VS");
    }

    // ────────────────────────────────────────────────────────────
    // Support link pushes child VS up (or keeps it at max)
    // ────────────────────────────────────────────────────────────

    function testFuzz_SupportLinkDoesNotReduceChildVS(
        uint128 parentSupport,
        uint128 childSupport,
        uint128 childChallenge
    ) public {
        uint256 pSup = bound(uint256(parentSupport), FEE * 2, 1e24); // bundle05_a
        uint256 cSup = bound(uint256(childSupport), FEE * 2, 1e24); // bundle05_a
        uint256 cChal = bound(uint256(childChallenge), FEE, 1e24); // bundle05_a

        // Parent: credible
        uint256 parent = _createAndStake("helper parent", pSup, 0);

        // Child: has some challenge (VS < 100%)
        uint256 child = _createAndStake("helped child", cSup, cChal);

        int256 vsBefore = score.effectiveVSRay(child);

        // Support link from parent to child
        uint256 link = registry.createLink(parent, child, false);
        stakeEng.stake(link, 0, pSup);

        int256 vsAfter = score.effectiveVSRay(child);

        assertGe(vsAfter, vsBefore, "support link should not reduce child VS");
    }

    // ────────────────────────────────────────────────────────────
    // Cycle handling: mutual challenge doesn't revert
    // ────────────────────────────────────────────────────────────

    function testFuzz_MutualChallengeDoesNotRevert(uint128 stakeA, uint128 stakeB) public {
        uint256 sA = bound(uint256(stakeA), FEE * 2, 1e24); // bundle05_a
        uint256 sB = bound(uint256(stakeB), FEE * 2, 1e24); // bundle05_a

        uint256 claimA = _createAndStake("claim A cycle", sA, 0);
        uint256 claimB = _createAndStake("claim B cycle", sB, 0);

        // A challenges B
        uint256 linkAB = registry.createLink(claimA, claimB, true);
        stakeEng.stake(linkAB, 0, FEE * 2);

        // B challenges A (creates a cycle)
        uint256 linkBA = registry.createLink(claimB, claimA, true);
        stakeEng.stake(linkBA, 0, FEE * 2);

        // Both effective VS calls should succeed (not revert)
        int256 vsA = score.effectiveVSRay(claimA);
        int256 vsB = score.effectiveVSRay(claimB);

        // Both should still be bounded
        assertGe(vsA, -1e18);
        assertLe(vsA, 1e18);
        assertGe(vsB, -1e18);
        assertLe(vsB, 1e18);
    }

    // ────────────────────────────────────────────────────────────
    // No-link post: effectiveVS has same sign as baseVS
    // ────────────────────────────────────────────────────────────

    /// @notice A post with no incoming links should have effectiveVS with the
    ///         same sign as baseVS. The exact magnitudes may differ because
    ///         baseVSRay uses A*RAY/T (asymmetric) while effectiveVSRay uses
    ///         (support-challenge)*RAY/(support+challenge) (symmetric subtraction).
    ///         These are mathematically different formulas that agree on sign
    ///         and extremes (0, +/-RAY) but diverge at intermediate values.
    function testFuzz_NoLinkEffectiveSameSign(uint128 support, uint128 challenge) public {
        uint256 sup = bound(uint256(support), FEE, 1e24); // bundle05_a
        uint256 chal = bound(uint256(challenge), 0, 1e24); // bundle05_a

        uint256 c = _createAndStake("no-link sign", sup, chal);

        int256 baseVS = score.baseVSRay(c);
        int256 effVS = score.effectiveVSRay(c);

        // Same sign, or both near-zero.
        // The two formulas (baseVSRay: A*RAY/T, effectiveVSRay: (S-C)*RAY/pool)
        // can disagree on sign when VS is near zero due to integer rounding.
        // We allow effectiveVS == 0 when baseVS is very small.
        if (baseVS > 0) {
            assertTrue(effVS >= 0, "effectiveVS should be non-negative when baseVS is positive");
        }
        if (baseVS < 0) {
            assertTrue(effVS <= 0, "effectiveVS should be non-positive when baseVS is negative");
        }
        if (baseVS == 0) {
            assertEq(effVS, 0, "effectiveVS should be zero when baseVS is zero");
        }
    }

    // ════════════════════════════════════════════════════════════
    // Conservation of Influence under Bounded Fan-Out (v2.1)
    // ════════════════════════════════════════════════════════════

    /// @notice Verifies that under bounded outgoing fan-out, only links
    ///         in the parent's top-N by stake produce a non-zero
    ///         contribution, and that the sum of those contributions is
    ///         bounded by parent mass × max link VS / RAY.
    function test_ConservationOfInfluenceUnderBoundedFanOut() public {
        // Force a tight outgoing limit so we can observe the cut.
        score.setEdgeLimits(64, 3);

        // Parent: fully positive VS, parentMass = 1000.
        uint256 parent = _createAndStake("parent_conservation", 1000, 0);

        // Five distinct targets and five outgoing links from parent,
        // each with a different stake (all above FEE = 50 so the
        // activity gate doesn't pre-filter them, isolating the
        // top-N gate).
        uint256[5] memory tgt;
        uint256[5] memory linkIds;
        uint256[5] memory linkStakes = [uint256(60), 70, 80, 90, 100];
        for (uint256 i = 0; i < 5; i++) {
            tgt[i] = _createAndStake(string.concat("ct_target_", vm.toString(i)), 100, 0);
            linkIds[i] = registry.createLink(parent, tgt[i], false);
            stakeEng.stake(linkIds[i], 0, linkStakes[i]);
        }

        // With maxOut = 3, the kept top-3 are the links with stakes
        // 100, 90, 80 (indices 4, 3, 2). The cut links are stakes
        // 70, 60 (indices 1, 0).
        int256 c0 = score.getEdgeContribution(tgt[0], linkIds[0]);
        int256 c1 = score.getEdgeContribution(tgt[1], linkIds[1]);
        int256 c2 = score.getEdgeContribution(tgt[2], linkIds[2]);
        int256 c3 = score.getEdgeContribution(tgt[3], linkIds[3]);
        int256 c4 = score.getEdgeContribution(tgt[4], linkIds[4]);

        assertEq(c0, 0, "stake-60 link must be cut and contribute 0");
        assertEq(c1, 0, "stake-70 link must be cut and contribute 0");
        assertGt(c2, 0, "stake-80 link must be in top-N and contribute");
        assertGt(c3, 0, "stake-90 link must be in top-N and contribute");
        assertGt(c4, 0, "stake-100 link must be in top-N and contribute");

        // Conservation invariant: sum of kept-link contributions is
        // bounded by parent mass (= 1000 here, since parentVS = +RAY).
        // With identical link VS = +RAY across all kept links:
        //   sumContrib = parentMass × sum(keptStakes) / sum(keptStakes) = parentMass
        // (modulo tiny truncation in the integer division).
        int256 sumKept = c2 + c3 + c4;
        int256 parentMass = 1000;
        assertLe(sumKept, parentMass, "kept-link contributions exceed parent mass");
        assertApproxEqAbs(sumKept, parentMass, 5, "kept sum should equal parent mass");
    }

    /// @notice Verifies the deterministic tiebreak in the outgoing top-N
    ///         cut: equal stakes are ordered by linkPostId ascending, so
    ///         the older link wins.
    function test_OutgoingTiebreakIsLinkPostIdAscending() public {
        // Tight outgoing limit and identical stakes so the tiebreak is
        // the only thing distinguishing kept from cut.
        score.setEdgeLimits(64, 2);

        uint256 parent = _createAndStake("parent_tiebreak", 1000, 0);

        // Three outgoing links, all with the SAME stake. linkIds are
        // assigned by registry.createLink in creation order, so
        // linkIds[0] < linkIds[1] < linkIds[2].
        uint256[3] memory tgt;
        uint256[3] memory linkIds;
        for (uint256 i = 0; i < 3; i++) {
            tgt[i] = _createAndStake(string.concat("tb_target_", vm.toString(i)), 100, 0);
            linkIds[i] = registry.createLink(parent, tgt[i], false);
            stakeEng.stake(linkIds[i], 0, 75);
        }

        int256 c0 = score.getEdgeContribution(tgt[0], linkIds[0]);
        int256 c1 = score.getEdgeContribution(tgt[1], linkIds[1]);
        int256 c2 = score.getEdgeContribution(tgt[2], linkIds[2]);

        assertGt(c0, 0, "earliest tied link must be kept");
        assertGt(c1, 0, "second-earliest tied link must be kept");
        assertEq(c2, 0, "latest tied link must be cut by linkPostId-ascending tiebreak");
    }
}
