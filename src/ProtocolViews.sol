// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PostRegistry.sol";
import "./LinkGraph.sol";
import "./ScoreEngine.sol";
import "./interfaces/IStakeEngine.sol";
import "./interfaces/IProtocolPolicy.sol";
import "./governance/GovernedUpgradeable.sol";

contract ProtocolViews is GovernedUpgradeable {
    error ZeroAddressPolicy();
    PostRegistry public registry;
    IStakeEngine public stake;
    LinkGraph public graph;
    ScoreEngine public score;
    IProtocolPolicy public protocolPolicy;

    struct ClaimSummary {
        string text;
        uint256 supportStake;
        uint256 challengeStake;
        uint256 totalStake;
        uint256 postingFee;
        bool isActive;
        int256 effectiveVSRay; // patch_game_b: base VS is internal (whitepaper v17 §4.1); a post has ONE score
        uint256 incomingCount;
        uint256 outgoingCount;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder_) GovernedUpgradeable(trustedForwarder_) {}

    function initialize(
        address governance_,
        address registry_,
        address stake_,
        address graph_,
        address score_,
        address protocolPolicy_
    ) external initializer {
        __GovernedUpgradeable_init(governance_);
        registry = PostRegistry(registry_);
        stake = IStakeEngine(stake_);
        graph = LinkGraph(graph_);
        score = ScoreEngine(score_);
        protocolPolicy = IProtocolPolicy(protocolPolicy_);
    }

    function getClaimSummary(uint256 claimPostId) external view returns (ClaimSummary memory s) {
        PostRegistry.Post memory p = registry.getPost(claimPostId);
        require(p.contentType == PostRegistry.ContentType.Claim, "not claim");

        s.text = registry.getClaim(p.contentId);
        (s.supportStake, s.challengeStake) = stake.getPostTotals(claimPostId);
        s.totalStake = s.supportStake + s.challengeStake;
        s.postingFee = protocolPolicy.postingFeeVSP();
        s.isActive = s.totalStake >= s.postingFee;
        s.effectiveVSRay = score.effectiveVSRay(claimPostId);
        s.incomingCount = graph.getIncoming(claimPostId).length;
        s.outgoingCount = graph.getOutgoing(claimPostId).length;
    }

    function postingFeeVSP() external view returns (uint256) {
        return protocolPolicy.postingFeeVSP();
    }

    function isActive(uint256 postId) external view returns (bool) {
        (uint256 s, uint256 c) = stake.getPostTotals(postId);
        return (s + c) >= protocolPolicy.postingFeeVSP();
    }

    function getEffectiveVSRay(uint256 postId) external view returns (int256) {
        return score.effectiveVSRay(postId);
    }

    function getIncomingEdges(uint256 claimPostId) external view returns (LinkGraph.IncomingEdge[] memory) {
        return graph.getIncoming(claimPostId);
    }

    function getOutgoingEdges(uint256 claimPostId) external view returns (LinkGraph.Edge[] memory) {
        return graph.getOutgoing(claimPostId);
    }

    function getLinkMeta(uint256 linkPostId) external view returns (uint256 from, uint256 to, bool isChallenge) {
        PostRegistry.Post memory p = registry.getPost(linkPostId);
        require(p.contentType == PostRegistry.ContentType.Link, "not link");

        PostRegistry.Link memory l = registry.getLink(p.contentId);
        return (l.fromPostId, l.toPostId, l.isChallenge);
    }

    /// @notice Signed contribution of `linkPostId` to `targetClaimPostId`'s effective VS.
    /// @dev Returns 0 if the link doesn't target the given claim or if any guard fails
    ///      (parent inactive, parent VS ≤ 0, link VS ≤ 0, etc.). In RAY units.
    function getEdgeContribution(uint256 targetClaimPostId, uint256 linkPostId) external view returns (int256) {
        return score.getEdgeContribution(targetClaimPostId, linkPostId);
    }

    uint256[500] private __gap;

    /// @notice Replace the ProtocolPolicy address. Governance only.
    event ProtocolPolicySet(address indexed oldPolicy, address indexed newPolicy);

    function setProtocolPolicy(address newProtocolPolicy) external onlyGovernance {
        if (newProtocolPolicy == address(0)) {
            revert ZeroAddressPolicy();
        }
        address old = address(protocolPolicy);
        protocolPolicy = IProtocolPolicy(newProtocolPolicy);
        emit ProtocolPolicySet(old, newProtocolPolicy);
    }
}
