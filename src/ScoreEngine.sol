// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PostRegistry.sol";
import "./LinkGraph.sol";
import "./interfaces/IStakeEngine.sol";
import "./interfaces/IProtocolPolicy.sol";
import "./governance/GovernedUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ScoreEngine (v3 — settlement on stored snapshots, whitepaper v18)
/// @notice Computes Verity Scores for claims using stake-weighted evidence propagation.
///
/// Rules (whitepaper §4.2):
///   1. Only credible parents contribute: parent effective VS must be > 0; link base VS must be > 0.
///   2. Contributions are stake: parentVS × parentT × linkT / outSum(parent) × linkVS, on the child's
///      side given by the link's polarity; S = A + Σpos, C = D + Σ|neg|, VS = (S − C)/(S + C).
///   3. patch_settlement_snapshots: every quantity on the right-hand side is read from the SNAPSHOT
///      the owning post wrote at its own last settlement (§4.2.6). Settlement of a child never
///      recurses into its ancestors; its cost is O(incoming) storage reads. Cycles feed back one
///      epoch per hop, bounded (§4.3). The outgoing denominator is maintained incrementally over ALL
///      active outgoing links (§4.4); there is no outgoing cap.
///   4. Bounded fan-in (§4.2.2): at most maxIncomingEdges incoming links count, ranked by an
///      eligibility key = link snapshot stake if the link would contribute non-zero, else 0; ties by
///      link postId ascending.
///   5. The displayed pool (effectivePool) = live direct totals + the same snapshot contributions
///      the next settlement will read (§4.2.5). getEdgeContribution applies rule 4 from the same
///      stored values, so view == settlement by construction.
contract ScoreEngine is GovernedUpgradeable {
    PostRegistry public registry;
    IStakeEngine public stake;
    LinkGraph public graph;
    IProtocolPolicy public protocolPolicy;
    /// @dev Reserved slot to preserve storage layout (was activityPolicy in pre-Patch-17 versions).
    address private __reservedSlot1_unused;

    int256 internal constant RAY = 1e18;
    uint256 internal constant URAY = 1e18;

    /// @notice Max incoming edges counted per claim (§4.2.2 scoring bound).
    uint256 public maxIncomingEdges;
    /// @notice Retained for storage layout and ABI; no longer used (v18 removed the outgoing cap).
    uint256 public maxOutgoingLinks;

    uint256 private constant DEFAULT_MAX_INCOMING = 64;
    uint256 private constant DEFAULT_MAX_OUTGOING = 64;

    // ── patch_settlement_snapshots: storage (three gap slots consumed) ──────────────────────────

    /// @notice What a post's last settlement recorded. One slot.
    ///         epoch1: settlement epoch (window end / EPOCH_LENGTH) PLUS ONE; 0 = never settled or
    ///                 seeded (the +1 keeps "epoch 0" distinguishable from "no snapshot").
    ///         T:      window-averaged direct total (A_w + D_w), wei.
    ///         vs:     effective VS for a claim, base VS for a link, RAY-scaled, 0 when inactive.
    struct Snapshot {
        uint32 epoch1;
        uint96 T;
        int128 vs;
    }

    mapping(uint256 => Snapshot) internal snaps;
    /// @notice Σ outContrib over a parent's outgoing links = the §4.2.2 denominator.
    mapping(uint256 => uint256) public outSum;
    /// @notice The value each link last wrote into its parent's outSum (the delta source — never
    ///         recomputed from the link's snapshot, so drift cannot creep in).
    mapping(uint256 => uint96) public outContrib;

    /// @notice The pool a claim's last settlement used (needed to read a parent back WITHOUT the
    ///         settling post's own contribution — §4.3 two-post cycles). One slot.
    struct Pool {
        uint96 S;
        uint96 C;
    }

    mapping(uint256 => Pool) internal pools;

    /// @notice What a claim counted from a given incoming link at its last settlement, tagged with
    ///         that settlement's epoch1 so a record from an older settlement reads as 0.
    struct Counted {
        int96 c;
        uint32 epoch1;
    }

    mapping(uint256 => Counted) internal counted;
    /// @notice Reverse index linkPostId by (from, to, polarity), written when a link first snapshots.
    mapping(uint256 => mapping(uint256 => uint256[2])) internal linkBetween;

    event EdgeLimitsSet(uint256 maxIncoming, uint256 maxOutgoing);
    event ProtocolPolicySet(address indexed oldPolicy, address indexed newPolicy);
    event SnapshotWritten(uint256 indexed postId, uint32 epoch, uint96 T, int128 vs, uint256 S, uint256 C);
    event StaleParentUsed(uint256 indexed postId, uint256 indexed parentPostId, uint32 parentEpoch);
    event OutSumRecalculated(uint256 indexed claimPostId, uint256 oldSum, uint256 newSum);

    error InvalidEdgeLimit();
    error ZeroAddressPolicy();
    error NotStakeEngine();
    error StaleParent(uint256 postId, uint256 parentPostId);
    error NotSeeded(uint256 postId);
    error Fits96();

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
        maxIncomingEdges = DEFAULT_MAX_INCOMING;
        maxOutgoingLinks = DEFAULT_MAX_OUTGOING;
    }

    // ── Governance ───────────────────────────────────────────────

    uint256 public constant ABSOLUTE_MAX_INCOMING = 1000;
    uint256 public constant ABSOLUTE_MAX_OUTGOING = 1000;

    /// @notice Set the incoming scoring bound. The second argument is accepted for ABI compatibility
    ///         and stored, but nothing reads it since v18.
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

    function setProtocolPolicy(address newProtocolPolicy) external onlyGovernance {
        if (newProtocolPolicy == address(0)) {
            revert ZeroAddressPolicy();
        }
        address old = address(protocolPolicy);
        protocolPolicy = IProtocolPolicy(newProtocolPolicy);
        emit ProtocolPolicySet(old, newProtocolPolicy);
    }

    // ── Settlement entry points (StakeEngine only) ───────────────────────────────────────────────

    /// @notice patch_settlement_snapshots: compute the pool a settlement pays on, over the window
    ///         [t0, t1), and write this post's snapshot. Called by StakeEngine._forceSnapshot.
    ///         `strict` is the user path (stake/withdraw): it reverts StaleParent when a counted
    ///         parent's or link's snapshot is older than the previous epoch, and NotSeeded when this
    ///         post has incoming links but no snapshot yet; the keeper path (strict = false) always
    ///         completes, emitting StaleParentUsed instead.
    function settlePool(uint256 postId, uint256 t0, uint256 t1, bool strict) external returns (uint256 S, uint256 C) {
        if (msg.sender != address(stake)) {
            revert NotStakeEngine();
        }
        uint32 epoch = uint32(t1 / stake.EPOCH_LENGTH());
        (uint256 A, uint256 D) = stake.getTimeWeightedTotals(postId, t0, t1);
        (S, C) = _writeSnapshot(postId, A, D, epoch, strict);
    }

    /// @notice Seed a post's first snapshot from its standing (live) state. Permissionless, per-post,
    ///         idempotent: a no-op once the post has any snapshot. Run in topological order after the
    ///         upgrade (claims, then links, then the claims they point to) so parents are seeded first.
    function seedSnapshot(uint256 postId) external {
        if (snaps[postId].epoch1 != 0) {
            return;
        }
        (uint256 A, uint256 D) = stake.getTimeWeightedTotals(postId, 0, 0); // live totals
        uint32 epoch = uint32(block.timestamp / stake.EPOCH_LENGTH());
        _writeSnapshot(postId, A, D, epoch, false);
    }

    /// @notice Rebuild a claim's outgoing sum from its links' outContrib. Permissionless, bounded by
    ///         the structural outgoing cap. The rescue path if drift is ever observed.
    function recalcOutSum(uint256 claimPostId) external {
        LinkGraph.Edge[] memory outs = graph.getOutgoing(claimPostId);
        uint256 sum;
        for (uint256 i = 0; i < outs.length; i++) {
            sum += outContrib[outs[i].linkPostId];
        }
        uint256 old = outSum[claimPostId];
        outSum[claimPostId] = sum;
        emit OutSumRecalculated(claimPostId, old, sum);
    }

    function _writeSnapshot(uint256 postId, uint256 A, uint256 D, uint32 epoch, bool strict)
        internal
        returns (uint256 S, uint256 C)
    {
        uint256 T = A + D;
        uint256 threshold = _threshold();
        bool active = _activeAt(T, threshold);
        PostRegistry.Post memory post = registry.getPost(postId);
        int256 vs;
        if (post.contentType == PostRegistry.ContentType.Link) {
            // Links carry no incoming evidence; their score is the base VS, and their stake is the
            // parent's denominator entry.
            S = A;
            C = D;
            vs = (active && T != 0) ? _clampRay(((int256(A) - int256(D)) * RAY) / int256(T)) : int256(0);
            PostRegistry.Link memory l = registry.getLink(post.contentId);
            uint96 t96 = _fits96(T);
            uint256 prev = outContrib[postId];
            if (t96 != prev) {
                outSum[l.fromPostId] = outSum[l.fromPostId] + t96 - prev;
                outContrib[postId] = t96;
            }
            uint256 pol = l.isChallenge ? 1 : 0;
            if (linkBetween[l.fromPostId][l.toPostId][pol] == 0) {
                linkBetween[l.fromPostId][l.toPostId][pol] = postId;
            }
        } else {
            if (strict && snaps[postId].epoch1 == 0 && graph.getIncoming(postId).length != 0) {
                revert NotSeeded(postId);
            }
            (uint256 pos, uint256 neg) = _incoming(postId, epoch, strict, threshold);
            S = A + pos;
            C = D + neg;
            pools[postId] = Pool({S: _fits96(S), C: _fits96(C)});
            // Rule 4: a claim is active if its direct stake clears the threshold OR its evidence
            // alone is at least a posting fee; otherwise it has no score (G2).
            bool scored = active || pos + neg >= protocolPolicy.postingFeeVSP();
            vs = (scored && S + C != 0) ? _clampRay(((int256(S) - int256(C)) * RAY) / int256(S + C)) : int256(0);
        }
        snaps[postId] = Snapshot({epoch1: epoch + 1, T: _fits96(T), vs: int128(vs)});
        emit SnapshotWritten(postId, epoch, _fits96(T), int128(vs), S, C);
    }

    // ── Views ────────────────────────────────────────────────────

    /// @notice A post's snapshot. `seeded` false = none yet (the other fields are then 0).
    function getSnapshot(uint256 postId) external view returns (bool seeded, uint32 epoch, uint96 T, int128 vs) {
        Snapshot memory s = snaps[postId];
        if (s.epoch1 == 0) {
            return (false, 0, 0, 0);
        }
        return (true, s.epoch1 - 1, s.T, s.vs);
    }

    /// @notice The pool a claim's last settlement used (0,0 before its first settlement).
    function getSettledPool(uint256 postId) external view returns (uint96 S, uint96 C) {
        Pool memory q = pools[postId];
        return (q.S, q.C);
    }

    /// @notice patch_game_b (whitepaper v17 §4.1): base VS is INTERNAL — the direct stake ratio on the
    ///         same scale as the effective score, (A - D) / T, and 0 for an inactive post.
    function baseVSRay(uint256 postId) public view returns (int256) {
        (uint256 A, uint256 D) = stake.getPostTotals(postId);
        uint256 T = A + D;
        if (T == 0 || !protocolPolicy.isActive(T)) {
            return 0;
        }
        return _clampRay(((int256(A) - int256(D)) * RAY) / int256(T));
    }

    /// @notice The displayed score: live direct totals plus the snapshot contributions the next
    ///         settlement will read (§4.2.5). 0 for an inactive post.
    function effectiveVSRay(uint256 postId) external view returns (int256) {
        (uint256 S, uint256 C,) = _poolView(postId);
        if (S + C == 0) {
            return 0;
        }
        return _clampRay(((int256(S) - int256(C)) * RAY) / int256(S + C));
    }

    /// @notice The displayed effective pool (§4.2.3). `exact` is always true since v18 (kept for ABI).
    function effectivePool(uint256 postId) external view returns (uint256 S, uint256 C, bool exact) {
        return _poolView(postId);
    }

    /// @notice The pool a settlement over [t0, t1) would pay on right now, read-only (used by the
    ///         StakeEngine projection so view == settlement, spec V.8).
    function previewPoolWindow(uint256 postId, uint256 t0, uint256 t1) external view returns (uint256 S, uint256 C) {
        (uint256 A, uint256 D) = stake.getTimeWeightedTotals(postId, t0, t1);
        if (registry.getPost(postId).contentType == PostRegistry.ContentType.Link) {
            return (A, D);
        }
        (uint256 pos, uint256 neg) = _incomingView(postId, _threshold());
        return (A + pos, D + neg);
    }

    function _poolView(uint256 postId) internal view returns (uint256 S, uint256 C, bool exact) {
        (uint256 A, uint256 D) = stake.getPostTotals(postId);
        uint256 T = A + D;
        exact = true;
        if (registry.getPost(postId).contentType == PostRegistry.ContentType.Link) {
            return (A, D, true);
        }
        uint256 threshold = _threshold();
        (uint256 pos, uint256 neg) = _incomingView(postId, threshold);
        // Rule 4 (G2): no score unless direct stake clears the threshold or evidence >= one fee.
        if (!_activeAt(T, threshold) && pos + neg < protocolPolicy.postingFeeVSP()) {
            return (0, 0, true);
        }
        return (A + pos, D + neg, true);
    }

    /// @notice Per-edge contribution exactly as settlement would count it from current snapshots:
    ///         0 if the link is ineligible or outside the top-N (§4.2.2). Indexers read this.
    function getEdgeContribution(uint256 targetClaimPostId, uint256 linkPostId) external view returns (int256 contrib) {
        LinkGraph.IncomingEdge[] memory inc = graph.getIncoming(targetClaimPostId);
        uint256 threshold = _threshold();
        uint256 n = inc.length;
        uint256 maxIn = maxIncomingEdges;
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
        (int256 c, uint256 key) = _edge(targetClaimPostId, inc[idx], threshold);
        if (c == 0) {
            return 0;
        }
        if (n > maxIn) {
            // count the edges ranked ahead of this one (higher key, or equal key and lower id)
            uint256 ahead;
            for (uint256 i = 0; i < n; i++) {
                if (i == idx) {
                    continue;
                }
                (int256 ci, uint256 ki) = _edge(targetClaimPostId, inc[i], threshold);
                if (ci == 0) {
                    continue;
                }
                if (ki > key || (ki == key && inc[i].linkPostId < linkPostId)) {
                    ahead++;
                    if (ahead >= maxIn) {
                        return 0;
                    }
                }
            }
        }
        return c;
    }

    // ── Internals ────────────────────────────────────────────────

    /// @dev One edge into `self` from snapshots: (signed contribution, ranking key). Both 0 when
    ///      ineligible. §4.3: if `self` itself links back into the parent, the parent is read WITHOUT
    ///      what it counted from `self`, so a two-post cycle is symmetric and order-independent (no
    ///      post influences its own score through its direct back-edge).
    function _edge(uint256 self, LinkGraph.IncomingEdge memory e, uint256 threshold)
        internal
        view
        returns (int256 contrib, uint256 key)
    {
        Snapshot memory p = snaps[e.fromClaimPostId];
        Snapshot memory l = snaps[e.linkPostId];
        if (p.epoch1 == 0 || l.epoch1 == 0) {
            return (0, 0); // unseeded / never settled: contributes nothing until it has
        }
        if (!_activeAt(p.T, threshold) || !_activeAt(l.T, threshold)) {
            return (0, 0); // inactive parent or link
        }
        if (l.vs <= 0) {
            return (0, 0); // discredited link (§4.2.1)
        }
        // the parent's stored vs may be 0 or negative ONLY because of what it counted from `self`;
        // the exclusion decides, not the stored sign
        int256 pvs = _parentVsExcludingSelf(self, e.fromClaimPostId, p);
        if (pvs <= 0) {
            return (0, 0); // credibility gate (§4.2.1)
        }
        uint256 os = outSum[e.fromClaimPostId];
        if (os == 0) {
            return (0, 0);
        }
        // parentMass × linkShare × linkVS, full-width: x = vs_p·T_p·T_l / RAY, then x·vs_l / (os·RAY).
        uint256 x = Math.mulDiv(uint256(pvs) * uint256(p.T), uint256(l.T), URAY);
        uint256 c = Math.mulDiv(x, uint256(int256(l.vs)), os * URAY);
        if (c == 0) {
            return (0, 0); // rounds to zero: ranks as zero too (§4.2.2)
        }
        return (e.isChallenge ? -int256(c) : int256(c), uint256(l.T));
    }

    /// @dev The parent's effective VS with whatever it counted from `self`'s links removed from its
    ///      pool. Reads the reverse index for both polarities; a Counted record only applies if it was
    ///      written at the parent's latest settlement (epoch1 match).
    function _parentVsExcludingSelf(uint256 self, uint256 parent, Snapshot memory p) internal view returns (int256) {
        uint256[2] storage back = linkBetween[self][parent];
        uint256 b0 = back[0];
        uint256 b1 = back[1];
        if (b0 == 0 && b1 == 0) {
            return int256(p.vs);
        }
        int256 adj; // signed amount `self` contributed to the parent (+ support side, − challenge side)
        if (b0 != 0) {
            Counted memory k = counted[b0];
            if (k.epoch1 == p.epoch1) {
                adj += k.c;
            }
        }
        if (b1 != 0) {
            Counted memory k = counted[b1];
            if (k.epoch1 == p.epoch1) {
                adj += k.c;
            }
        }
        if (adj == 0) {
            return int256(p.vs);
        }
        Pool memory pool = pools[parent];
        int256 S = int256(uint256(pool.S));
        int256 C = int256(uint256(pool.C));
        if (adj > 0) {
            S -= adj;
        } else {
            C += adj; // adj < 0: remove |adj| from the challenge side
        }
        if (S < 0) {
            S = 0;
        }
        if (C < 0) {
            C = 0;
        }
        if (S + C == 0) {
            return 0;
        }
        return _clampRay(((S - C) * RAY) / (S + C));
    }

    /// @dev Settlement-side incoming sum with freshness handling; writes nothing but may emit/revert.
    function _incoming(uint256 postId, uint32 epoch, bool strict, uint256 threshold)
        internal
        returns (uint256 pos, uint256 neg)
    {
        LinkGraph.IncomingEdge[] memory inc = graph.getIncoming(postId);
        uint256 n = inc.length;
        if (n == 0) {
            return (0, 0);
        }
        uint256 k = maxIncomingEdges;
        uint32 epoch1 = epoch + 1;
        if (n <= k) {
            for (uint256 i = 0; i < n; i++) {
                (int256 c,) = _edge(postId, inc[i], threshold);
                if (c == 0) {
                    continue;
                }
                _freshness(postId, inc[i], epoch, strict);
                counted[inc[i].linkPostId] = Counted({c: _fitsI96(c), epoch1: epoch1});
                if (c > 0) {
                    pos += uint256(c);
                } else {
                    neg += uint256(-c);
                }
            }
            return (pos, neg);
        }
        (int256[] memory cs, uint256[] memory ids) = _topK(postId, inc, k, threshold);
        for (uint256 i = 0; i < cs.length; i++) {
            if (cs[i] == 0) {
                break;
            }
            _freshness(postId, inc[ids[i]], epoch, strict);
            counted[inc[ids[i]].linkPostId] = Counted({c: _fitsI96(cs[i]), epoch1: epoch1});
            if (cs[i] > 0) {
                pos += uint256(cs[i]);
            } else {
                neg += uint256(-cs[i]);
            }
        }
    }

    function _incomingView(uint256 postId, uint256 threshold) internal view returns (uint256 pos, uint256 neg) {
        LinkGraph.IncomingEdge[] memory inc = graph.getIncoming(postId);
        uint256 n = inc.length;
        if (n == 0) {
            return (0, 0);
        }
        uint256 k = maxIncomingEdges;
        if (n <= k) {
            for (uint256 i = 0; i < n; i++) {
                (int256 c,) = _edge(postId, inc[i], threshold);
                if (c > 0) {
                    pos += uint256(c);
                } else if (c < 0) {
                    neg += uint256(-c);
                }
            }
            return (pos, neg);
        }
        (int256[] memory cs,) = _topK(postId, inc, k, threshold);
        for (uint256 i = 0; i < cs.length; i++) {
            if (cs[i] == 0) {
                break;
            }
            if (cs[i] > 0) {
                pos += uint256(cs[i]);
            } else {
                neg += uint256(-cs[i]);
            }
        }
    }

    /// @dev Top-k eligible edges by (key desc, linkPostId asc). Returns contributions and the index
    ///      of each chosen edge in `inc`; unused tail entries are 0.
    function _topK(uint256 self, LinkGraph.IncomingEdge[] memory inc, uint256 k, uint256 threshold)
        internal
        view
        returns (int256[] memory cs, uint256[] memory ids)
    {
        uint256[] memory keys = new uint256[](k);
        cs = new int256[](k);
        ids = new uint256[](k);
        uint256 count;
        for (uint256 i = 0; i < inc.length; i++) {
            (int256 c, uint256 key) = _edge(self, inc[i], threshold);
            if (c == 0) {
                continue;
            }
            uint256 id = inc[i].linkPostId;
            // does it beat the current minimum (last filled slot)?
            if (count == k) {
                uint256 lk = keys[k - 1];
                uint256 lid = inc[ids[k - 1]].linkPostId;
                if (key < lk || (key == lk && id > lid)) {
                    continue; // does not beat the current k-th
                }
            }
            uint256 pos = count < k ? count : k - 1;
            // shift down while the new edge ranks ahead
            while (pos > 0) {
                uint256 pk = keys[pos - 1];
                uint256 pid = inc[ids[pos - 1]].linkPostId;
                if (pk > key || (pk == key && pid < id)) {
                    break;
                }
                keys[pos] = pk;
                cs[pos] = cs[pos - 1];
                ids[pos] = ids[pos - 1];
                pos--;
            }
            keys[pos] = key;
            cs[pos] = c;
            ids[pos] = i;
            if (count < k) {
                count++;
            }
        }
    }

    function _freshness(uint256 postId, LinkGraph.IncomingEdge memory e, uint32 epoch, bool strict) internal {
        uint32 pe = snaps[e.fromClaimPostId].epoch1; // both non-zero here: the edge was eligible
        uint32 le = snaps[e.linkPostId].epoch1;
        uint32 older1 = pe < le ? pe : le;
        if (older1 + 1 < epoch + 1) {
            // older snapshot epoch < epoch - 1: not settled last epoch nor this one
            uint256 culprit = pe <= le ? e.fromClaimPostId : e.linkPostId;
            if (strict) {
                revert StaleParent(postId, culprit);
            }
            emit StaleParentUsed(postId, culprit, older1 - 1);
        }
    }

    function _threshold() internal view returns (uint256) {
        return protocolPolicy.minTotalStakeVSP();
    }

    /// @dev Mirrors IProtocolPolicy.isActive without an external call per edge.
    function _activeAt(uint256 total, uint256 threshold) internal pure returns (bool) {
        if (threshold == 0) {
            return total > 0;
        }
        return total >= threshold;
    }

    function _fitsI96(int256 x) internal pure returns (int96) {
        if (x > type(int96).max || x < type(int96).min) {
            revert Fits96();
        }
        return int96(x);
    }

    function _fits96(uint256 x) internal pure returns (uint96) {
        if (x > type(uint96).max) {
            revert Fits96();
        }
        return uint96(x);
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

    // Gap: 500 originally; −2 for maxIncomingEdges/maxOutgoingLinks (v2); −6 for snaps, outSum,
    // outContrib, pools, counted, linkBetween (v18).
    uint256[494] private __gap;
}
