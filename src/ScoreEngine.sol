// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PostRegistry.sol";
import "./LinkGraph.sol";
import "./interfaces/IStakeEngine.sol";
import "./interfaces/IProtocolPolicy.sol";
import "./governance/GovernedUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title ScoreEngine (v2 — bounded fan-in)
/// @notice Computes Verity Scores for claims using stake-weighted evidence propagation.
///
/// Key rules:
///   1. Only credible parents contribute: parentVS must be > 0.
///   2. Contributions are stake-weighted: parent economic mass flows through links.
///   3. Effective VS = (directSupport + positiveContribs - directChallenge - negativeContribs) / pool.
///   4. A claim is active if direct stakes OR abs(incoming contributions) >= posting fee.
///   5. Cycle elimination: when computing VS(X), if a chain of links leads back to X,
///      X's contribution is zero. X cannot influence its own VS through any path.
///
/// v2 changes:
///   - MAX_INCOMING_EDGES: bounds the number of incoming edges processed per claim.
///   - MAX_OUTGOING_LINKS: bounds the outgoing link stake summation per parent.
///   - Both are governance-configurable via setEdgeLimits().
///   - Prevents gas exhaustion on popular claims with many evidence links.
contract ScoreEngine is GovernedUpgradeable {
    using SafeCast for uint256;

    PostRegistry public registry;
    IStakeEngine public stake;
    LinkGraph public graph;
    IProtocolPolicy public protocolPolicy;
    /// @dev Reserved slot to preserve storage layout (was activityPolicy
    ///      in pre-Patch-17 versions).
    address private __reservedSlot1_unused;

    int256 internal constant RAY = 1e18;
    uint256 internal constant MAX_DEPTH = 32;

    // ── New in v2: bounded fan-in ────────────────────────────────
    // These use gap slots (no storage layout change).

    /// @notice Max incoming edges processed per effectiveVSRay call.
    ///         Edges beyond this limit are silently skipped.
    uint256 public maxIncomingEdges;

    /// @notice Max outgoing links summed when computing a parent's
    ///         link stake distribution. Links beyond this are skipped.
    uint256 public maxOutgoingLinks;

    uint256 private constant DEFAULT_MAX_INCOMING = 64;
    uint256 private constant DEFAULT_MAX_OUTGOING = 64;

    // ── patch_h2_score_memo: bounded, DAG-exact score memoization ─────────
    // effectiveVSRay memoizes postId -> VS *within a single call*, storing a
    // result ONLY when its whole subtree resolved with no cycle-cut and no
    // depth-cap truncation (hence path-independent). Acyclic evidence graphs
    // collapse from exponential to ~linear and return IDENTICAL scores; cyclic
    // graphs are bounded by VS_MEMO_VISIT_CAP (deterministic). Memory-only:
    // no storage slots added, external ABI unchanged.
    uint256 private constant VS_MEMO_SLOTS = 2048; // pow2 open-addressed table
    uint256 private constant VS_MEMO_VISIT_CAP = 50000; // hard backstop on node visits

    struct VSMemo {
        uint256[] keys; // postId occupying each slot
        int256[] vals; // cached effectiveVSRay for that postId
        bool[] used; // slot occupied?
        uint256 visited;
        bool full; // table saturated -> stop inserting (still correct)
    }

    function _newMemo() internal pure returns (VSMemo memory m) {
        m.keys = new uint256[](VS_MEMO_SLOTS);
        m.vals = new int256[](VS_MEMO_SLOTS);
        m.used = new bool[](VS_MEMO_SLOTS);
    }

    function _memoGet(VSMemo memory m, uint256 postId) internal pure returns (bool hit, int256 val) {
        uint256 mask = VS_MEMO_SLOTS - 1;
        uint256 slot = postId & mask;
        for (uint256 probe = 0; probe < VS_MEMO_SLOTS; probe++) {
            if (!m.used[slot]) {
                return (false, 0); // empty slot -> not present
            }
            if (m.keys[slot] == postId) {
                return (true, m.vals[slot]);
            }
            slot = (slot + 1) & mask;
        }
        return (false, 0);
    }

    function _memoPut(VSMemo memory m, uint256 postId, int256 val) internal pure {
        if (m.full) {
            return;
        }
        uint256 mask = VS_MEMO_SLOTS - 1;
        uint256 slot = postId & mask;
        for (uint256 probe = 0; probe < VS_MEMO_SLOTS; probe++) {
            if (!m.used[slot]) {
                m.used[slot] = true;
                m.keys[slot] = postId;
                m.vals[slot] = val;
                return;
            }
            if (m.keys[slot] == postId) {
                m.vals[slot] = val; // overwrite (same value; harmless)
                return;
            }
            slot = (slot + 1) & mask;
        }
        m.full = true; // no free slot -> saturate; correctness preserved, collapse degrades
    }

    event EdgeLimitsSet(uint256 maxIncoming, uint256 maxOutgoing);
    error InvalidEdgeLimit();
    error ZeroAddressPolicy();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder_) GovernedUpgradeable(trustedForwarder_) {}

    function initialize(
        address governance_,
        address registry_,
        address stake_,
        address graph_,
        address protocolPolicy_,
        address /* reserved_unused */
    ) external initializer {
        __GovernedUpgradeable_init(governance_);
        registry = PostRegistry(registry_);
        stake = IStakeEngine(stake_);
        graph = LinkGraph(graph_);
        protocolPolicy = IProtocolPolicy(protocolPolicy_);
        // Second arg reserved/unused (was activityPolicy pre-Patch-17).
        maxIncomingEdges = DEFAULT_MAX_INCOMING;
        maxOutgoingLinks = DEFAULT_MAX_OUTGOING;
    }

    // ── Governance ───────────────────────────────────────────────

    /// @notice Set the maximum number of edges processed in VS computation.
    ///         Governance-only. Values of 0 are rejected.
    /// Review 3 (2026-09-10) #6: governance may tune the traversal bounds but
    /// never disable them. Ceilings equal LinkGraph's structural per-claim
    /// limits (1000), the most any traversal could ever have to visit.
    uint256 public constant ABSOLUTE_MAX_INCOMING = 1000;
    uint256 public constant ABSOLUTE_MAX_OUTGOING = 1000;

    function setEdgeLimits(uint256 maxIncoming_, uint256 maxOutgoing_) external onlyGovernance {
        if (maxIncoming_ == 0 || maxOutgoing_ == 0) {
            revert InvalidEdgeLimit();
        }
        if (maxIncoming_ > ABSOLUTE_MAX_INCOMING || maxOutgoing_ > ABSOLUTE_MAX_OUTGOING) {
            revert InvalidEdgeLimit();
        }
        maxIncomingEdges = maxIncoming_;
        maxOutgoingLinks = maxOutgoing_;
        emit EdgeLimitsSet(maxIncoming_, maxOutgoing_);
    }

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

    // ── VS Computation ──────────────────────────────────────────

    function baseVSRay(uint256 postId) public view returns (int256) {
        (uint256 A, uint256 D) = stake.getPostTotals(postId);
        uint256 T = A + D;
        if (T == 0) {
            return 0;
        }
        if (A > D) {
            return int256((A * uint256(RAY)) / T);
        }
        if (D > A) {
            return -int256((D * uint256(RAY)) / T);
        }
        return 0;
    }

    function effectiveVSRay(uint256 postId) external view returns (int256) {
        uint256[] memory computing = new uint256[](MAX_DEPTH + 1);
        VSMemo memory memo = _newMemo(); // patch_h2_score_memo
        (int256 v,) = _effectiveVSRay(postId, computing, memo, 0);
        return v;
    }

    // patch_h2_score_memo: returns (value, exact). `exact` == the whole subtree
    // resolved with no cycle-cut and no depth-cap truncation, so the value is
    // path-independent and safe to memoize (node-keyed). Only exact results are
    // cached; acyclic graphs are therefore bit-identical to the pre-patch logic.
    function _effectiveVSRay(uint256 postId, uint256[] memory computing, VSMemo memory memo, uint256 depth)
        internal
        view
        returns (int256 value, bool exact)
    {
        if (depth > MAX_DEPTH) {
            return (0, false); // depth-truncated -> arrival-depth dependent, not cacheable
        }

        // Cycle detection MUST precede the memo lookup: a node on the current
        // path is cut to 0 here regardless of any cached full value.
        for (uint256 i = 0; i < depth; i++) {
            if (computing[i] == postId) {
                return (0, false); // cycle cut -> ancestor-set dependent, not cacheable
            }
        }

        // Memo lookup: only path-independent (exact) results were stored.
        {
            (bool hit, int256 cached) = _memoGet(memo, postId);
            if (hit) {
                return (cached, true);
            }
        }

        // Visited-node backstop: bounds total work on adversarial cyclic graphs.
        memo.visited += 1;
        if (memo.visited > VS_MEMO_VISIT_CAP) {
            return (0, false); // deterministic truncation; never cached
        }

        computing[depth] = postId;

        (uint256 directSupport, uint256 directChallenge) = stake.getPostTotals(postId);
        bool directlyActive = protocolPolicy.isActive(directSupport + directChallenge);

        // Compute incoming link contributions (bounded). `exact` folds in every
        // kept edge's exactness (dropped-by-cap edges are path-independent).
        uint256 absContribution;
        int256 netContribution;
        (netContribution, absContribution, exact) = _sumIncomingContributions(postId, computing, memo, depth);

        // Activity gate
        if (!directlyActive && absContribution < protocolPolicy.postingFeeVSP()) {
            if (exact) {
                _memoPut(memo, postId, 0);
            }
            return (0, exact);
        }

        // Combine
        int256 totalSupport = directSupport.toInt256();
        int256 totalChallenge = directChallenge.toInt256();

        if (netContribution > 0) {
            totalSupport += netContribution;
        } else if (netContribution < 0) {
            totalChallenge += (-netContribution);
        }

        int256 pool = totalSupport + totalChallenge;
        if (pool == 0) {
            if (exact) {
                _memoPut(memo, postId, 0);
            }
            return (0, exact);
        }

        value = _clampRay(((totalSupport - totalChallenge) * RAY) / pool);
        if (exact) {
            _memoPut(memo, postId, value);
        }
        return (value, exact);
    }

    /// @dev Computes the sum of incoming link contributions, bounded by maxIncomingEdges.
    ///      When edges exceed the limit, they are sorted by link stake descending
    ///      with ties broken by linkPostId ascending (older link wins) so the most
    ///      economically significant evidence is always processed and the cap
    ///      decision is deterministic across calls and off-chain indexers.
    function _sumIncomingContributions(uint256 postId, uint256[] memory computing, VSMemo memory memo, uint256 depth)
        internal
        view
        returns (int256 net, uint256 abs_, bool exact)
    {
        exact = true; // patch_h2_score_memo: AND of every kept edge's exactness
        LinkGraph.IncomingEdge[] memory inc = graph.getIncoming(postId);
        uint256 fee = protocolPolicy.postingFeeVSP();
        uint256 n = inc.length;
        uint256 maxIn = maxIncomingEdges;

        // Sort by link stake descending (ties: linkPostId ascending) when bounded.
        if (maxIn > 0 && n > maxIn) {
            uint256[] memory stakes = new uint256[](n);
            for (uint256 i = 0; i < n; i++) {
                stakes[i] = _totalStake(inc[i].linkPostId);
            }
            // Insertion sort (view call, no gas limit; n typically < 200)
            for (uint256 i = 1; i < n; i++) {
                uint256 ks = stakes[i];
                LinkGraph.IncomingEdge memory ke = inc[i];
                uint256 j = i;
                while (
                    j > 0 && (stakes[j - 1] < ks || (stakes[j - 1] == ks && inc[j - 1].linkPostId > ke.linkPostId))
                ) {
                    stakes[j] = stakes[j - 1];
                    inc[j] = inc[j - 1];
                    j--;
                }
                stakes[j] = ks;
                inc[j] = ke;
            }
            n = maxIn;
        }

        for (uint256 i = 0; i < n; i++) {
            (int256 contrib, bool eExact) = _computeEdgeContribution(inc[i], computing, memo, depth, fee);
            if (!eExact) {
                exact = false;
            }
            if (contrib != 0) {
                net += contrib;
                abs_ += _abs(contrib);
            }
        }
    }

    /// @dev Computes the contribution of a single incoming edge.
    ///
    ///      Conservation of influence (whitepaper §4.4) requires that the
    ///      sum of `linkShare` across all of a parent's outgoing links be
    ///      ≤ 1.0. Under bounded fan-out (maxOutgoingLinks), only the top-N
    ///      outgoing links by stake (ties: linkPostId ascending) sum into
    ///      the parent's denominator. To preserve conservation, this gate
    ///      makes those same top-N the *only* links that produce a non-zero
    ///      numerator: a link outside its parent's top-N contributes zero.
    ///
    ///      This means: a parent's mass is fully distributed across its
    ///      top-N outgoing links and nowhere else. Adding more outgoing
    ///      links beyond the cap does not increase total influence — it
    ///      only competes for slots in the top-N.
    // patch_h2_score_memo: returns (contrib, exact). Early exits that never
    // consult the recursion are path-independent (exact = true); once the
    // parent recursion runs, this edge inherits the parent's exactness.
    function _computeEdgeContribution(
        LinkGraph.IncomingEdge memory e,
        uint256[] memory computing,
        VSMemo memory memo,
        uint256 depth,
        uint256 fee
    ) internal view returns (int256 contrib, bool exact) {
        exact = true;
        uint256 parentTotal = _totalStake(e.fromClaimPostId);
        if (!protocolPolicy.isActive(parentTotal)) {
            return (0, true);
        }

        uint256 linkStake = _totalStake(e.linkPostId);
        if (!protocolPolicy.isActive(linkStake)) {
            return (0, true);
        }

        // Parent VS (recursive, with cycle detection)
        (int256 parentVS, bool pExact) = _effectiveVSRay(e.fromClaimPostId, computing, memo, depth + 1);
        exact = pExact;
        if (parentVS <= 0) {
            return (0, exact);
        }

        // Link VS
        int256 linkVS = baseVSRay(e.linkPostId);
        if (linkVS <= 0) {
            return (0, exact);
        }

        // Parent mass distributed to this link (bounded outgoing sum +
        // top-N membership gate enforcing conservation of influence).
        (uint256 sumOutgoing, uint256 thresholdStake, uint256 thresholdPostId) =
            _sumOutgoingLinkStake(e.fromClaimPostId, fee);
        if (sumOutgoing == 0) {
            return (0, exact);
        }
        if (!_isInTopN(linkStake, e.linkPostId, thresholdStake, thresholdPostId)) {
            return (0, exact);
        }

        int256 numerator = (parentVS * parentTotal.toInt256() * linkStake.toInt256()) / sumOutgoing.toInt256();
        contrib = (numerator * linkVS) / (RAY * RAY);

        if (e.isChallenge) {
            contrib = -contrib;
        }

        return (contrib, exact);
    }

    /// @dev True iff a link with `(linkStake, linkPostId)` is at or above the
    ///      top-N cutoff established by _sumOutgoingLinkStake.
    ///      The cutoff is `(thresholdStake, thresholdPostId)` describing the
    ///      bottom-of-the-kept-set (smallest stake, with linkPostId-ascending
    ///      tiebreak). A link qualifies if its stake is strictly greater, or
    ///      its stake is exactly equal and its postId is at most the
    ///      threshold's postId. When no cap was applied, thresholdStake is 0
    ///      and thresholdPostId is type(uint256).max so every link passes.
    function _isInTopN(uint256 linkStake, uint256 linkPostId, uint256 thresholdStake, uint256 thresholdPostId)
        internal
        pure
        returns (bool)
    {
        if (linkStake > thresholdStake) {
            return true;
        }
        if (linkStake < thresholdStake) {
            return false;
        }
        return linkPostId <= thresholdPostId;
    }

    /// @notice Public view: computes the signed contribution of one link to its target claim's VS.
    /// @param targetClaimPostId The claim receiving the contribution
    /// @param linkPostId The link whose contribution to compute
    /// @return contrib In RAY units. Positive = link pushes target VS up, negative = pushes down.
    ///                 Returns 0 if the link does not target the given claim or if any guard
    ///                 fails (parent inactive, link inactive, parent VS ≤ 0, link VS ≤ 0,
    ///                 link outside the target's top-`maxIncomingEdges` incoming, or link
    ///                 outside the parent's top-`maxOutgoingLinks` outgoing).
    /// @dev Same math used internally when computing target's effective VS. Safe to call
    ///      off-chain; iterates over incoming edges once.
    function getEdgeContribution(uint256 targetClaimPostId, uint256 linkPostId) external view returns (int256 contrib) {
        LinkGraph.IncomingEdge[] memory inc = graph.getIncoming(targetClaimPostId);
        uint256 fee = protocolPolicy.postingFeeVSP();
        uint256 n = inc.length;
        uint256 maxIn = maxIncomingEdges;

        // Locate the matching incoming edge first.
        uint256 idx = type(uint256).max;
        for (uint256 i = 0; i < n; i++) {
            if (inc[i].linkPostId == linkPostId) {
                idx = i;
                break;
            }
        }
        if (idx == type(uint256).max) {
            return 0;
        }

        // Apply the same incoming-cap gate that _sumIncomingContributions uses,
        // so this view reports the same number that effectiveVSRay would see.
        if (maxIn > 0 && n > maxIn) {
            uint256 thisStake = _totalStake(linkPostId);
            uint256 ahead = 0;
            for (uint256 i = 0; i < n; i++) {
                if (i == idx) {
                    continue;
                }
                uint256 si = _totalStake(inc[i].linkPostId);
                if (si > thisStake) {
                    ahead++;
                } else if (si == thisStake && inc[i].linkPostId < linkPostId) {
                    ahead++;
                }
                // Early exit: we only need to know whether ahead >= maxIn.
                if (ahead >= maxIn) {
                    return 0;
                }
            }
        }

        uint256[] memory computing = new uint256[](MAX_DEPTH + 1);
        VSMemo memory memo = _newMemo(); // patch_h2_score_memo
        (contrib,) = _computeEdgeContribution(inc[idx], computing, memo, 0, fee);
        return contrib;
    }

    function _totalStake(uint256 postId) internal view returns (uint256) {
        (uint256 s, uint256 d) = stake.getPostTotals(postId);
        return s + d;
    }

    /// @dev Sum outgoing link stakes, bounded by maxOutgoingLinks.
    ///      When the parent has more outgoing links than the limit, they
    ///      are sorted by link stake descending (ties: linkPostId ascending,
    ///      i.e. older link wins) and only the top maxOutgoingLinks are
    ///      summed. Returns the sum together with the cutoff
    ///      `(thresholdStake, thresholdPostId)` describing the smallest
    ///      stake / largest-postId link that made the cut, so callers can
    ///      ask "is this specific link in the top-N?" via _isInTopN.
    ///      When no cap was needed, thresholdStake = 0 and
    ///      thresholdPostId = type(uint256).max — every link qualifies.
    ///
    ///      The fee filter (skip links with stake < posting fee) is
    ///      applied to the sum but NOT to top-N membership: a below-fee
    ///      link can win a top-N slot, but its stake doesn't dilute
    ///      siblings' shares (excluded from sum), and
    ///      _computeEdgeContribution will short-circuit it via
    ///      protocolPolicy.isActive.
    function _sumOutgoingLinkStake(uint256 claimPostId, uint256 fee)
        internal
        view
        returns (uint256 sum, uint256 thresholdStake, uint256 thresholdPostId)
    {
        LinkGraph.Edge[] memory outs = graph.getOutgoing(claimPostId);
        uint256 n = outs.length;
        uint256 maxOut = maxOutgoingLinks;

        if (n == 0) {
            return (0, 0, type(uint256).max);
        }

        // Sort by link stake descending (ties: linkPostId ascending) when bounded.
        if (maxOut > 0 && n > maxOut) {
            uint256[] memory stakes = new uint256[](n);
            for (uint256 i = 0; i < n; i++) {
                stakes[i] = _totalStake(outs[i].linkPostId);
            }
            // Insertion sort (view call, no gas limit; n typically < 200)
            for (uint256 i = 1; i < n; i++) {
                uint256 ks = stakes[i];
                LinkGraph.Edge memory ke = outs[i];
                uint256 j = i;
                while (
                    j > 0 && (stakes[j - 1] < ks || (stakes[j - 1] == ks && outs[j - 1].linkPostId > ke.linkPostId))
                ) {
                    stakes[j] = stakes[j - 1];
                    outs[j] = outs[j - 1];
                    j--;
                }
                stakes[j] = ks;
                outs[j] = ke;
            }
            // Cutoff is the maxOut-th element (1-indexed) — outs[maxOut - 1].
            thresholdStake = stakes[maxOut - 1];
            thresholdPostId = outs[maxOut - 1].linkPostId;
            n = maxOut;
        } else {
            // No cap applied — every link qualifies.
            thresholdStake = 0;
            thresholdPostId = type(uint256).max;
        }

        for (uint256 i = 0; i < n; i++) {
            uint256 t = _totalStake(outs[i].linkPostId);
            if (t >= fee) {
                sum += t;
            }
        }
    }

    function _clampRay(int256 x) internal pure returns (int256) {
        if (x > RAY) {
            return RAY;
        }
        if (x < -RAY) {
            return -RAY;
        }
        return x;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    // Reduced gap by 2 for maxIncomingEdges + maxOutgoingLinks
    uint256[500] private __gap;
}
