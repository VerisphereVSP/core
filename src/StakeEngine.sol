// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IVSPToken.sol";
import "./lib/TimeWeighted.sol";

/// @dev patch_game_b: the only ScoreEngine surface settlement needs.
interface IScoreEngineV2 {
    /// patch_settlement_snapshots: settlement reads stored snapshots and writes this post's.
    function settlePool(uint256 postId, uint256 t0, uint256 t1, bool strict) external returns (uint256 S, uint256 C);
    function previewPoolWindow(uint256 postId, uint256 t0, uint256 t1) external view returns (uint256 S, uint256 C);
}
import "./interfaces/IProtocolPolicy.sol";
import "./governance/GovernedUpgradeable.sol";

/// @title StakeEngine (v3)
/// @notice Manages VSP staking on posts with:
///         - Lot consolidation: one lot per user per side per post
///         - Midpoint positional weighting: wPos = cumBefore + amount/2
///           Per-lot APR = rBase * (T - wPos) / T. No redistribution.
///           Solo staker earns rMax/2. First of many approaches rMax.
///           Individual APR never exceeds rMax.
///         - O(n) recalculation on every queue mutation (stake, withdraw)
///         - Periodic snapshots for epoch gain/loss materialization
///         - Lazy view projection: reads project forward from last snapshot
///         Supports gasless meta-transactions via ERC-2771.
contract StakeEngine is GovernedUpgradeable {
    uint8 public constant SIDE_SUPPORT = 0;
    uint8 public constant SIDE_CHALLENGE = 1;

    // ------------------------------------------------------------
    // Data structures
    // ------------------------------------------------------------

    /// @notice A consolidated stake lot — one per user per side per post.
    struct StakeLot {
        address staker;
        uint256 amount; // Current amount after last snapshot
        uint8 side;
        uint256 weightedPosition; // Stake-weighted queue position
        // patch_prC_rulings S-11: entryEpoch removed — stored but never read by
        // any settlement path (see MAX_SNAPSHOT_PERIOD note below for why
        // prorating by entry epoch was rejected as a mechanism).
    }

    struct SideQueue {
        StakeLot[] lots; // ranked lots (<= MAX_RANKED_LOTS), individually positioned
        uint256 total; // side total = rankedTotal + bucketLive (as of last snapshot)
        // patch_h1a_bucket: pooled tail bucket (all stakers below the ranked set,
        // sharing one position). Rebases in O(1); bucketLive = scaled * index / RAY.
        uint256 bucketScaledTotal;
        // patch_prC_rulings S-01: honest init — 0 means "no member has ever
        // entered this bucket" and nothing else. _bucketAdd sets RAY explicitly
        // on first entry; settlement floors the index at 1 wei so a stored 0
        // can never be produced by decay and never collides with the
        // uninitialized state (the old 0==RAY lazy sentinel resurrected wiped
        // buckets at face value after ~1400 days of losses at deployed rates).
        uint256 bucketIndexRay;
        // patch_h1b_promotion: max-heap of bucket member addresses, keyed on
        // scaledShares (rebase-stable -> no settlement-time maintenance).
        address[] bucketHeap;
    }

    struct PostState {
        SideQueue[2] sides; // [0] = support, [1] = challenge
        uint256 lastSnapshotEpoch; // Last epoch when full O(C) update ran
        mapping(address => uint256) lotIndex0; // user => lots index + 1, support side
        mapping(address => uint256) lotIndex1; // user => lots index + 1, challenge side
        // patch_h1a_bucket: user => scaled bucket shares (0 == not in bucket)
        mapping(address => uint256) bucketShares0;
        mapping(address => uint256) bucketShares1;
        // patch_h1b_promotion: user => heap index + 1 (0 == not in heap)
        mapping(address => uint256) bucketHeapPos0;
        mapping(address => uint256) bucketHeapPos1;
    }

    // ------------------------------------------------------------
    // State variables
    // ------------------------------------------------------------

    IERC20 public ERC20_TOKEN;
    IVSPToken public VSP_TOKEN;
    IProtocolPolicy public protocolPolicy;

    mapping(uint256 => PostState) private posts;

    uint256 public sMax;
    uint256 public sMaxPostId;

    /// @notice Leader-tracker width (patch_prC_rulings S-03 layer iii: 3 -> 10).
    ///         Wider board narrows the untracked-dormant-post window; the
    ///         irreducible residue is closed by permissionless refreshSMax().
    uint256 public constant TRACKED_POSTS = 10;

    /// @dev Tracker slots; the struct and its maintenance live in TimeWeighted (same layout: two words).
    TimeWeighted.TopPost[TRACKED_POSTS] private topPosts;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus;

    modifier nonReentrant() {
        _enter();
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    function _enter() internal {
        if (_reentrancyStatus == _ENTERED) {
            revert Reentrant();
        }
        _reentrancyStatus = _ENTERED;
    }
    uint256 public sMaxLastUpdatedEpoch;

    uint256 public snapshotPeriod;

    /// @notice sMax decay rate per epoch, in RAY.
    ///         Default 9e17 = 0.9 = 10% decay per day (patch_prC_rulings S-09:
    ///         the constant was always 9e17 and is CORRECT as the backstop; the
    ///         old docstring claiming 0.5%/day was the bug. Deploy.s.sol pins
    ///         this value explicitly).
    ///         Governance-configurable. Lower value = faster decay.
    ///         RAY (1e18) = no decay. Must be in (0, RAY].
    uint256 public sMaxDecayRateRay;

    /// @notice Maximum epochs of sMax decay to project in one call.
    ///         Caps gas cost when catching up stale posts.
    uint256 public sMaxDecayMaxEpochs;

    /// @notice Legacy field, retained for ABI compatibility.

    // ------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------

    uint256 public constant EPOCH_LENGTH = 1 days;
    uint256 public constant YEAR_LENGTH = 365 days;
    uint256 private constant RAY = 1e18;

    uint256 private constant DEFAULT_SNAPSHOT_PERIOD = 1 days;

    /// @notice Hard floor on snapshotPeriod. Prevents gas-grief at sub-hour periods.
    uint256 public constant MIN_SNAPSHOT_PERIOD = 1 hours;
    /// @notice Hard cap on snapshotPeriod. Prevents yield freeze at multi-year
    ///         periods AND closes the mid-window accrual asymmetry.
    /// @dev patch_sec_jit_window (2026-08-19, external report VSP-SEC-001):
    ///      settlement scales the rate by `epochsElapsed` and applies the result
    ///      to whatever lots exist at settlement time -- no per-lot entry epoch
    ///      participates (the field was removed as S-11). Whenever snapshotPeriod > EPOCH_LENGTH the
    ///      snapshot is SUPPRESSED mid-window, so (a) a lot joining late in the
    ///      window collects the whole window's accrual, and (b) a lot leaving
    ///      before the window closes escapes the whole window's decay.
    ///      Capping the period at one epoch makes `periodInEpochs == 1`, so any
    ///      interaction settles every elapsed epoch BEFORE mutating the lot set
    ///      (stake() and withdraw() both call _maybeSnapshot first) -- which
    ///      closes both directions.
    ///      Prorating by a per-lot entry epoch was the reporter's suggestion; it
    ///      fixes only direction (a), and cannot fix it for the pooled tail bucket
    ///      at all, since _settleBucket is an O(1) index rebase with no per-entry
    ///      epochs. That is also why StakeLot carries no entry-epoch field (S-11).
    uint256 public constant MAX_SNAPSHOT_PERIOD = EPOCH_LENGTH;
    /// @notice Hard cap on sMaxDecayMaxEpochs. Prevents OOG in _projectSMaxDecay.
    uint256 public constant MAX_SMAX_DECAY_EPOCHS = 10000;
    // bundle05_a: G-9/G-10 bounds (10M VSP cap on stake amount and setStake target).
    uint256 public constant MAX_STAKE_AMOUNT = 10_000_000 * 1e18;
    // patch_h1a_bucket: max individually-positioned lots per side. Beyond this,
    // stakers share the pooled tail bucket, so every per-side loop is O(C).
    uint256 public constant MAX_RANKED_LOTS = 100;
    uint256 private constant DEFAULT_SMAX_DECAY_RATE_RAY = 9e17; // 10% daily decay

    // ── patch_game_b (whitepaper v17): evidence-economic settlement ───────────
    /// @notice Gas a user transaction may spend on the inline settlement before it is deferred
    ///         to the keeper (`SettleFirst`). updatePost() is unbounded.
    uint256 internal constant USER_SETTLE_GAS = 3_000_000;

    error SettleFirst(uint256 postId);
    error TransferFailed(); // EIP-170: replaces 5 revert strings
    error Reentrant();

    uint256 private constant DEFAULT_SMAX_DECAY_MAX_EPOCHS = 30; // Full decay in ~30 days

    // ------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------

    error InvalidSide();
    error AmountZero();
    error StakeAmountTooLarge(uint256 amount, uint256 max); // bundle05_a G-9
    error SetStakeTargetTooLarge(int256 target, uint256 max); // bundle05_a G-10
    error OppositeSideStaked();
    error NotEnoughStake();
    error ZeroAddressToken();
    error InvalidSnapshotPeriod();
    error NoGhostLots();
    error InvalidDecayRate();
    error InvalidDecayMaxEpochs();
    error PeriodOutOfBounds();
    error EpochsOutOfBounds();
    error ZeroAddressPolicy();

    // ------------------------------------------------------------
    // Events
    // ------------------------------------------------------------

    event StakeAdded(uint256 indexed postId, address indexed staker, uint8 side, uint256 amount);
    event StakeWithdrawn(uint256 indexed postId, address indexed staker, uint8 side, uint256 amount, bool lifo);
    event PostUpdated(uint256 indexed postId, uint256 epoch, uint256 supportTotal, uint256 challengeTotal);
    event EpochMinted(uint256 indexed postId, uint256 amount);
    event EpochBurned(uint256 indexed postId, uint256 amount);
    event SnapshotPeriodSet(uint256 oldPeriod, uint256 newPeriod);
    event LotsCompacted(uint256 indexed postId, uint8 side, uint256 removed);
    // patch_h1a_bucket: emitted when a ranked lot is demoted into the tail bucket
    // (indexer surfaces this as a zero-cost timeline entry for the demoted staker).
    event LotDemoted(uint256 indexed postId, uint8 side, address indexed staker, uint256 amount);
    // patch_h1b_promotion: emitted when a bucket member is promoted into the ranked set.
    event LotPromoted(uint256 indexed postId, uint8 side, address indexed staker, uint256 amount);
    event SMaxRescanned(uint256 newSMax, uint256 newSMaxPostId);
    event SMaxDecayRateSet(uint256 oldRate, uint256 newRate);
    event SMaxDecayMaxEpochsSet(uint256 oldMax, uint256 newMax);
    // patch_prC_rulings S-12: PositionsRescaled event removed with _rescalePositions.
    /// @notice patch_prC_rulings S-03: emitted by the permissionless poke.
    event SMaxRefreshed(uint256 indexed postId, uint256 postTotal, uint256 sMaxAfter);

    // ------------------------------------------------------------
    // Constructor / Initializer
    // ------------------------------------------------------------

    // ─────────────────────────────────────────────────────────────────
    // Pause / Guardian (patch12b)
    // ─────────────────────────────────────────────────────────────────
    //
    // guardian can call pause() (fast emergency halt). Only governance
    // can unpause(), so resuming is a deliberate multisig+timelock step.
    //
    // Pause scope: stake() and setStake() reverted when paused.
    // withdraw() and updatePost() remain callable so users can always
    // exit positions even during emergencies.
    address public guardian;
    bool public paused;
    bool internal _initializedV2;

    /// H1 (security review 2026-09): the engine never checked that a postId
    /// exists, so staking on an unborn/phantom id minted uncapped yield with
    /// no claim, no fee, and nothing for indexers to show. Storage is APPENDED
    /// (upgrade-safe, same pattern as V2). Wired by Deploy.s.sol via
    /// setPostRegistry; tools/verify-genesis.sh refuses an unset value.
    /// Semantics: postId == 0 is ALWAYS rejected; when a registry is set,
    /// postId must be < registry.nextPostId(). When unset (legacy test
    /// harnesses only), the range check is skipped — this is deliberate and
    /// gated by deployment verification, not by the contract.
    address public postRegistry;

    /// Economics rulings 2026-09-08 (founder), storage APPENDED (gap 498 -> 495):
    ///  posOffset:      capital-weighted top-ups (ruling 1c). A ranked lot's
    ///                  weightedPosition = natural midpoint + posOffset, where the
    ///                  offset is the amount-weighted average of each tranche's
    ///                  ENTRY midpoint minus the natural midpoint. A late top-up
    ///                  therefore earns as if it had queued at the tail, while the
    ///                  original tranche keeps its earliness. Drift note: when
    ///                  capital ahead withdraws, the blended lot moves up as one
    ///                  (bounded by the earliest tranche's share); on partial
    ///                  withdraw the offset scales with the remaining amount.
    ///  entryTime:      pro-rating (ruling 2b). A lot's gains AND losses for a
    ///                  settlement window are scaled by the fraction of the
    ///                  window it was present: f = clamp((windowEnd - entryTime)
    ///                  / windowLen, 0, 1). On top-up the entry time becomes the
    ///                  amount-weighted average of old entry and now — the same
    ///                  capital-weighting as posOffset, so parking dust early and
    ///                  topping up at the boundary ages the lot to seconds. The
    ///                  pooled tail bucket (stakers below the top 100 by size) has
    ///                  no per-entry data and is not prorated — documented residual.
    ///  settledTotal:   sMax tracks last-SETTLED post totals (ruling 3b), so a
    ///                  stake-and-withdraw inside one epoch never registers.
    mapping(uint256 => mapping(uint8 => mapping(address => uint256))) public posOffset;
    mapping(uint256 => mapping(uint8 => mapping(address => uint256))) public entryTime;
    mapping(uint256 => uint256) public settledTotal;

    event PostRegistrySet(address indexed oldRegistry, address indexed newRegistry);
    error InvalidPostId(uint256 postId);
    error InvalidPostRegistry(address registry);
    error LotExceedsCap(uint256 lotAfter, uint256 cap);

    function setPostRegistry(address registry_) external onlyGovernance {
        // Slither missing-zero-check (CI): a zero registry would silently
        // disable the range check — the fail-open shape H1 exists to close.
        if (registry_ == address(0) || registry_.code.length == 0) {
            revert InvalidPostRegistry(registry_);
        }
        address old = postRegistry;
        postRegistry = registry_;
        emit PostRegistrySet(old, registry_);
    }

    function _requireValidPost(uint256 postId) internal view {
        if (postId == 0) {
            revert InvalidPostId(postId);
        }
        if (postRegistry != address(0) && postId >= IPostRegistryIds(postRegistry).nextPostId()) {
            revert InvalidPostId(postId);
        }
    }

    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event GuardianSet(address indexed oldGuardian, address indexed newGuardian);

    error WhenPaused();
    error NotGuardianOrGovernance();
    error AlreadyInitializedV2();

    modifier whenNotPaused() {
        _requireNotPaused();
        _;
    }

    function _requireNotPaused() internal view {
        if (paused) {
            revert WhenPaused();
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder_) GovernedUpgradeable(trustedForwarder_) {}

    function initialize(address governance_, address vspToken_, address protocolPolicy_) external initializer {
        if (vspToken_ == address(0)) {
            revert ZeroAddressToken();
        }
        __GovernedUpgradeable_init(governance_);
        ERC20_TOKEN = IERC20(vspToken_);
        VSP_TOKEN = IVSPToken(vspToken_);
        protocolPolicy = IProtocolPolicy(protocolPolicy_);
        sMaxLastUpdatedEpoch = _currentEpoch();
        snapshotPeriod = DEFAULT_SNAPSHOT_PERIOD;
        sMaxDecayRateRay = DEFAULT_SMAX_DECAY_RATE_RAY;
        sMaxDecayMaxEpochs = DEFAULT_SMAX_DECAY_MAX_EPOCHS;
    }

    // ------------------------------------------------------------
    // Governance setters
    // ------------------------------------------------------------

    function setSnapshotPeriod(uint256 newPeriod) external onlyGovernance {
        if (newPeriod < MIN_SNAPSHOT_PERIOD || newPeriod > MAX_SNAPSHOT_PERIOD) {
            revert PeriodOutOfBounds();
        }
        emit SnapshotPeriodSet(snapshotPeriod, newPeriod);
        snapshotPeriod = newPeriod;
    }

    /// @notice Set the sMax decay rate. Governance-only.
    ///         Must be in (0, RAY]. 995e15 = 0.5%/day, RAY = no decay.
    function setSMaxDecayRate(uint256 newRate) external onlyGovernance {
        if (newRate == 0 || newRate > RAY) {
            revert InvalidDecayRate();
        }
        emit SMaxDecayRateSet(sMaxDecayRateRay, newRate);
        sMaxDecayRateRay = newRate;
    }

    /// @notice Set the max epochs of sMax decay projection. Governance-only.
    function setSMaxDecayMaxEpochs(uint256 newMax) external onlyGovernance {
        if (newMax == 0 || newMax > MAX_SMAX_DECAY_EPOCHS) {
            revert EpochsOutOfBounds();
        }
        emit SMaxDecayMaxEpochsSet(sMaxDecayMaxEpochs, newMax);
        sMaxDecayMaxEpochs = newMax;
    }

    /// @notice Replace the ProtocolPolicy address. Governance only.
    /// @dev    Enables swapping in a new policy contract after deploy.
    event ProtocolPolicySet(address indexed oldPolicy, address indexed newPolicy);

    /// @notice patch_game_b: wire the ScoreEngine whose effective pool settlement pays on.
    event ScoreEngineSet(address indexed oldEngine, address indexed newEngine);

    /// @notice Wire the ScoreEngine settlement reads. Governance only. patch_settlement_snapshots
    ///         (review R3 C-3s): the zero address is rejected and the change is evented; an unwired
    ///         engine settles on the direct ratio only in test/bootstrap deployments, and
    ///         verify-genesis asserts the wiring on every network.
    function setScoreEngine(address newScoreEngine) external onlyGovernance {
        if (newScoreEngine == address(0)) {
            revert ZeroAddress();
        }
        address old = address(scoreEngine);
        scoreEngine = IScoreEngineV2(newScoreEngine);
        emit ScoreEngineSet(old, newScoreEngine);
    }

    function setProtocolPolicy(address newProtocolPolicy) external onlyGovernance {
        if (newProtocolPolicy == address(0)) {
            revert ZeroAddressPolicy();
        }
        address old = address(protocolPolicy);
        protocolPolicy = IProtocolPolicy(newProtocolPolicy);
        emit ProtocolPolicySet(old, newProtocolPolicy);
    }

    // -------- Pause / Guardian admin (patch12b) --------

    /// @notice One-shot V2 initializer. Sets initial Guardian after
    ///         upgrade-in-place. Only governance, only once.
    function initializeV2(address guardian_) external onlyGovernance {
        if (_initializedV2) {
            revert AlreadyInitializedV2();
        }
        _initializedV2 = true;
        if (guardian_ == address(0)) {
            revert ZeroAddress();
        }
        guardian = guardian_;
        emit GuardianSet(address(0), guardian_);
    }

    /// @notice Pause new staking. Callable by Guardian (fast emergency
    ///         response) or by governance (deliberate). Withdraws and
    ///         updatePost remain callable while paused.
    function pause() external {
        address sender = _msgSender();
        if (sender != guardian && sender != governance) {
            revert NotGuardianOrGovernance();
        }
        paused = true;
        emit Paused(sender);
    }

    /// @notice Unpause. Governance only.
    function unpause() external onlyGovernance {
        paused = false;
        emit Unpaused(_msgSender());
    }

    /// @notice Replace the Guardian. Governance only.
    function setGuardian(address newGuardian) external onlyGovernance {
        if (newGuardian == address(0)) {
            revert ZeroAddress(); // review G CR-4: a zeroed guardian disables the fast pause
        }
        address old = guardian;
        guardian = newGuardian;
        emit GuardianSet(old, newGuardian);
    }

    /// @notice Legacy setter retained for ABI compatibility.

    function compactLots(uint256 postId, uint8 side) external onlyGovernance nonReentrant {
        if (side > 1) {
            revert InvalidSide();
        }
        PostState storage ps = posts[postId];
        SideQueue storage q = ps.sides[side];
        uint256 removed = 0;
        // S-08 FIX: shift-compact (arrival order preserved), never swap-and-pop. Walk from the tail
        // so each removal only moves lots behind the ghost.
        for (uint256 i = q.lots.length; i > 0; i--) {
            if (q.lots[i - 1].amount == 0) {
                _setLotIndex(ps, q.lots[i - 1].staker, side, 0);
                _removeRankedAt(ps, q, side, i - 1);
                removed++;
            }
        }
        if (removed == 0) {
            revert NoGhostLots();
        }
        _recomputeWeightedPositions(postId, side, q);
        emit LotsCompacted(postId, side, removed);
    }

    // ------------------------------------------------------------
    // Read (view — always current via projection)
    // ------------------------------------------------------------

    /// @notice patch_game_b: the post's last settlement epoch (window start = epoch * EPOCH_LENGTH).
    function getLastSnapshotEpoch(uint256 postId) external view returns (uint256) {
        return posts[postId].lastSnapshotEpoch;
    }

    /// @notice patch_game_b (v17 §4.2.5): direct side totals time-weighted over [t0, t1].
    ///         t1 <= t0, or a post with no observations yet, returns the live totals.
    function getTimeWeightedTotals(uint256 postId, uint256 t0, uint256 t1)
        external
        view
        returns (uint256 support, uint256 challenge)
    {
        PostState storage ps = posts[postId];
        return observations[postId].totals(t0, t1, ps.sides[0].total, ps.sides[1].total);
    }

    /// @dev Record the current totals. Called after every change to a side total.
    function _observe(uint256 postId) internal {
        PostState storage ps = posts[postId];
        observations[postId].observe(ps.sides[0].total, ps.sides[1].total);
    }

    /// @dev User path: settle inline within USER_SETTLE_GAS or defer to the keeper.
    function _settleBounded(uint256 postId) internal {
        try this.settleSelf{gas: USER_SETTLE_GAS}(postId) {}
        catch {
            revert SettleFirst(postId);
        }
    }

    /// @notice Self-call target for the bounded inline settlement. Not callable externally.
    function settleSelf(uint256 postId) external {
        if (msg.sender != address(this)) {
            revert NotGuardianOrGovernance(); // self-call only
        }
        _maybeSnapshot(postId, _currentEpoch(), true); // user path: defer on stale parents
    }

    function getPostTotals(uint256 postId) external view returns (uint256 support, uint256 challenge) {
        PostState storage ps = posts[postId];
        uint256 currentEpoch = _currentEpoch();
        uint256 snapshotEpoch = ps.lastSnapshotEpoch;
        uint256 storedS = ps.sides[0].total;
        uint256 storedC = ps.sides[1].total;
        if (snapshotEpoch == 0 || currentEpoch <= snapshotEpoch) {
            return (storedS, storedC);
        }
        return _projectTotals(postId, ps, currentEpoch);
    }

    function getUserStake(address user, uint256 postId, uint8 side) external view returns (uint256) {
        if (side > 1) {
            revert InvalidSide();
        }
        PostState storage ps = posts[postId];
        uint256 idx = _getLotIndex(ps, user, side);
        if (idx == 0) {
            // patch_h1a_bucket: bucket member -> live value (stored index)
            uint256 shares = _getBucketShares(ps, user, side);
            if (shares == 0) {
                return 0;
            }
            return (shares * _bucketIndex(ps.sides[side])) / RAY;
        }
        StakeLot storage lot = ps.sides[side].lots[idx - 1];
        if (lot.amount == 0) {
            return 0;
        }
        uint256 currentEpoch = _currentEpoch();
        uint256 snapshotEpoch = ps.lastSnapshotEpoch;
        if (snapshotEpoch == 0 || currentEpoch <= snapshotEpoch) {
            return lot.amount;
        }
        return _projectLotValue(postId, ps, lot, currentEpoch);
    }

    /// @dev patch_prC_rulings S-11: entryEpoch dropped from the tuple (field removed).
    // patch_prC_rulings_p2 (arity sweep applied)
    function getUserLotInfo(address user, uint256 postId, uint8 side)
        external
        view
        returns (uint256 amount, uint256 weightedPosition, uint256 sideTotal, uint256 positionWeight)
    {
        if (side > 1) {
            revert InvalidSide();
        }
        PostState storage ps = posts[postId];
        uint256 idx = _getLotIndex(ps, user, side);
        if (idx == 0) {
            return (0, 0, 0, 0);
        }
        StakeLot storage lot = ps.sides[side].lots[idx - 1];
        if (lot.amount == 0) {
            return (0, 0, 0, 0);
        }

        uint256 currentEpoch = _currentEpoch();
        uint256 projectedAmount = lot.amount;
        if (ps.lastSnapshotEpoch > 0 && currentEpoch > ps.lastSnapshotEpoch) {
            projectedAmount = _projectLotValue(postId, ps, lot, currentEpoch);
        }

        sideTotal = ps.sides[side].total;
        if (sideTotal > 0) {
            // Midpoint model: positionWeight = (T - wPos) / T
            uint256 behindMe = lot.weightedPosition < sideTotal ? sideTotal - lot.weightedPosition : 0;
            positionWeight = (behindMe * RAY) / sideTotal;
            if (positionWeight > RAY) {
                positionWeight = RAY;
            }
        } else {
            positionWeight = RAY;
        }
        return (projectedAmount, lot.weightedPosition, sideTotal, positionWeight);
    }

    // ------------------------------------------------------------
    // Stake
    // ------------------------------------------------------------

    function stake(uint256 postId, uint8 side, uint256 amount) external nonReentrant whenNotPaused {
        _requireValidPost(postId); // H1 / H3
        if (amount == 0) {
            revert AmountZero();
        }
        if (side > 1) {
            revert InvalidSide();
        }
        // bundle05_a G-9: cap stake amount.
        if (amount > MAX_STAKE_AMOUNT) {
            revert StakeAmountTooLarge(amount, MAX_STAKE_AMOUNT);
        }
        PostState storage psCheck = posts[postId];
        uint8 opposite = 1 - side;
        if (_userAmount(psCheck, opposite, _msgSender()) > 0) {
            revert OppositeSideStaked();
        }
        // M3 (security review 2026-09): G-9 capped each CALL, not the lot, so
        // ten calls pushed 100M through. The cap now binds the lot total.
        {
            uint256 lotAfter = _userAmount(psCheck, side, _msgSender()) + amount;
            if (lotAfter > MAX_STAKE_AMOUNT) {
                revert LotExceedsCap(lotAfter, MAX_STAKE_AMOUNT);
            }
        }
        if (!ERC20_TOKEN.transferFrom(_msgSender(), address(this), amount)) {
            revert TransferFailed();
        }
        PostState storage ps = posts[postId];
        uint256 epoch = _currentEpoch();
        if (ps.lastSnapshotEpoch == 0) {
            ps.lastSnapshotEpoch = epoch;
        }
        _settleBounded(postId); // patch_game_b: inline within USER_SETTLE_GAS, else SettleFirst
        _increaseUser(postId, side, amount, _msgSender()); // patch_h1a_bucket
        emit StakeAdded(postId, _msgSender(), side, amount);
    }

    // ------------------------------------------------------------
    // Withdraw
    // ------------------------------------------------------------

    function withdraw(
        uint256 postId,
        uint8 side,
        uint256 amount,
        bool /* lifo */
    )
        external
        nonReentrant
    {
        if (amount == 0) {
            revert AmountZero();
        }
        if (side > 1) {
            revert InvalidSide();
        }
        PostState storage ps = posts[postId];
        uint256 epoch = _currentEpoch();
        _settleBounded(postId); // patch_game_b: inline within USER_SETTLE_GAS, else SettleFirst
        // patch_h1a_bucket: unified ranked/bucket decrease (both bounded)
        if (_userAmount(ps, side, _msgSender()) < amount) {
            revert NotEnoughStake();
        }
        uint256 removed = _decreaseUser(postId, side, amount, _msgSender());
        _refeedSMax(postId); // ruling 3b (settled, not live) + review R3 C-4 (drain snap-down)
        if (!ERC20_TOKEN.transfer(_msgSender(), removed)) {
            revert TransferFailed();
        }
        emit StakeWithdrawn(postId, _msgSender(), side, removed, true);
    }

    // ------------------------------------------------------------
    // Permissionless update
    // ------------------------------------------------------------

    function updatePost(uint256 postId) external nonReentrant {
        uint256 epoch = _currentEpoch();
        _forceSnapshot(postId, epoch, false); // keeper path: always completes
    }

    // ------------------------------------------------------------
    // Internal: Snapshot logic
    // ------------------------------------------------------------

    /// @notice Set the user's stake on a post to a target value.
    ///         target > 0: desired support stake amount
    ///         target < 0: desired challenge stake amount (absolute value)
    ///         target == 0: withdraw all stakes on this post
    function setStake(uint256 postId, int256 target) external nonReentrant {
        // Security review 2026-09 (Low): a full exit (target == 0) must stay
        // open while paused, as the pause docs promise; only non-zero targets
        // are blocked. withdraw() was already exempt.
        if (paused && target != 0) {
            revert WhenPaused();
        }
        _requireValidPost(postId); // H1 / H3
        // bundle05_a G-10: cap |target| at MAX_STAKE_AMOUNT.
        uint256 absT_b05a = target >= 0 ? uint256(target) : uint256(-target);
        if (absT_b05a > MAX_STAKE_AMOUNT) {
            revert SetStakeTargetTooLarge(target, MAX_STAKE_AMOUNT);
        }
        PostState storage ps = posts[postId];
        uint256 epoch = _currentEpoch();
        _settleBounded(postId); // patch_game_b: inline within USER_SETTLE_GAS, else SettleFirst
        address user = _msgSender();

        uint256 currentSup = _userAmount(ps, 0, user); // patch_h1a_bucket
        uint256 currentChal = _userAmount(ps, 1, user);

        uint256 absTarget = target >= 0 ? uint256(target) : uint256(-target);

        if (target == 0) {
            if (currentSup > 0) {
                _doWithdraw(postId, ps, user, 0, currentSup);
            }
            if (currentChal > 0) {
                _doWithdraw(postId, ps, user, 1, currentChal);
            }
        } else if (target > 0) {
            if (currentChal > 0) {
                _doWithdraw(postId, ps, user, 1, currentChal);
            }
            if (absTarget > currentSup) {
                uint256 toStake = absTarget - currentSup;
                if (!ERC20_TOKEN.transferFrom(user, address(this), toStake)) {
                    revert TransferFailed();
                }
                _increaseUser(postId, 0, toStake, user); // patch_h1a_bucket
                emit StakeAdded(postId, user, 0, toStake);
            } else if (absTarget < currentSup) {
                _doWithdraw(postId, ps, user, 0, currentSup - absTarget);
            }
        } else {
            if (currentSup > 0) {
                _doWithdraw(postId, ps, user, 0, currentSup);
            }
            if (absTarget > currentChal) {
                uint256 toStake = absTarget - currentChal;
                if (!ERC20_TOKEN.transferFrom(user, address(this), toStake)) {
                    revert TransferFailed();
                }
                _increaseUser(postId, 1, toStake, user); // patch_h1a_bucket
                emit StakeAdded(postId, user, 1, toStake);
            } else if (absTarget < currentChal) {
                _doWithdraw(postId, ps, user, 1, currentChal - absTarget);
            }
        }

        _refeedSMax(postId); // ruling 3b (settled, not live) + review R3 C-4 (drain snap-down)
    }

    /// @dev Withdraw helper for setStake (no reentrancy guard - caller is guarded)
    function _doWithdraw(uint256 postId, PostState storage ps, address user, uint8 side, uint256 amount) internal {
        // patch_h1a_bucket: unified ranked/bucket decrease
        if (_userAmount(ps, side, user) == 0) {
            return;
        }
        uint256 removed = _decreaseUser(postId, side, amount, user);
        if (removed == 0) {
            return;
        }
        if (!ERC20_TOKEN.transfer(user, removed)) {
            revert TransferFailed();
        }
        emit StakeWithdrawn(postId, user, side, removed, true);
    }

    function _maybeSnapshot(uint256 postId, uint256 currentEpoch, bool strict) internal {
        PostState storage ps = posts[postId];
        uint256 lastEpoch = ps.lastSnapshotEpoch;
        if (lastEpoch == 0) {
            ps.lastSnapshotEpoch = currentEpoch;
            return;
        }
        // patch_settlement_snapshots (review R3 N-1): a legacy post (no observations yet) gets its
        // window-start observation BEFORE any mutation can write a later one, so standing stake
        // counts for the whole window it stood.
        if (observations[postId].length == 0) {
            uint256 a_ = ps.sides[0].total;
            uint256 d_ = ps.sides[1].total;
            if (a_ + d_ != 0) {
                observations[postId].seed(lastEpoch * EPOCH_LENGTH, a_, d_);
            }
        }
        uint256 periodInEpochs = snapshotPeriod / EPOCH_LENGTH;
        if (periodInEpochs == 0) {
            periodInEpochs = 1;
        }
        if (currentEpoch >= lastEpoch + periodInEpochs) {
            _forceSnapshot(postId, currentEpoch, strict);
        }
    }

    function _forceSnapshot(uint256 postId, uint256 currentEpoch, bool strict) internal {
        PostState storage ps = posts[postId];
        uint256 lastEpoch = ps.lastSnapshotEpoch;
        if (lastEpoch == 0 || currentEpoch <= lastEpoch) {
            if (lastEpoch == 0) {
                ps.lastSnapshotEpoch = currentEpoch;
            }
            return;
        }

        SideQueue storage qs = ps.sides[0];
        SideQueue storage qc = ps.sides[1];

        uint256 A = qs.total;
        uint256 D = qc.total;
        uint256 T = A + D;
        // ruling 3b: capital present AT settlement registers at settlement (and
        // participates in it); capital that came and went inside the window
        // never survives to this line, so it never registers in sMax.
        // (T == 0 registers too: a fully-withdrawn post must drop out of the
        // tracker so the decay floor can fall — S-03 "floored at tracked leader".)
        settledTotal[postId] = T;
        _updateSMax(postId, T);

        // patch_game_b: legacy posts (pre-upgrade) get their first observation at the window
        // start with the pre-settlement totals, so standing stake counts for this window.
        if (T != 0) {
            observations[postId].seed(lastEpoch * EPOCH_LENGTH, A, D);
        }
        // patch_settlement_snapshots (whitepaper v18 §3.2/§4.2.6): truth pressure and the accruing
        // side come from the effective pool over this window, assembled by the ScoreEngine from this
        // post's window-averaged direct totals and its parents'/links' SNAPSHOTS (no recursion);
        // the call also writes THIS post's snapshot — so it runs even for an empty post, or children
        // would read a stale record. Participation stays on direct T.
        uint256 S = A;
        uint256 C = D;
        if (address(scoreEngine) != address(0)) {
            (S, C) = scoreEngine.settlePool(postId, lastEpoch * EPOCH_LENGTH, currentEpoch * EPOCH_LENGTH, strict);
        }

        if (T == 0 || sMax == 0) {
            ps.lastSnapshotEpoch = currentEpoch;
            return;
        }
        if (S == C) {
            ps.lastSnapshotEpoch = currentEpoch;
            _observe(postId);
            return;
        }
        bool supportWins = S > C;
        // patch_prC_rulings S-04 (ratified): participation deliberately couples every post's
        // rate to the GLOBAL leader via sMax (see TimeWeighted.rBase; moved out for EIP-170).
        uint256 rBase = TimeWeighted.rBase(
            S,
            C,
            T,
            sMax,
            protocolPolicy.stakeIntRateMinRay(),
            protocolPolicy.stakeIntRateMaxRay(),
            EPOCH_LENGTH,
            currentEpoch - lastEpoch,
            YEAR_LENGTH
        );

        // Apply epoch gains/losses (positions that exceed sideTotal are
        // safely clamped to zero weight inside _applyEpoch; midpoint
        // recomputation after every mutation keeps positions < total, so the
        // clamp is a safety net rather than a working path — S-12).
        uint256 wStart = lastEpoch * EPOCH_LENGTH;
        uint256 wEnd = currentEpoch * EPOCH_LENGTH;
        (uint256 mintS, uint256 burnS) = _applyEpochFor(postId, 0, wStart, wEnd, qs, supportWins, true, rBase);
        (uint256 mintC, uint256 burnC) = _applyEpochFor(postId, 1, wStart, wEnd, qc, supportWins, false, rBase);

        if (mintS + mintC > 0) {
            VSP_TOKEN.mint(address(this), mintS + mintC);
            emit EpochMinted(postId, mintS + mintC);
        }
        if (burnS + burnC > 0) {
            VSP_TOKEN.burn(burnS + burnC);
            emit EpochBurned(postId, burnS + burnC);
        }

        // Recompute totals and midpoint positions after mints/burns
        _recomputeSideTotal(qs);
        _recomputeSideTotal(qc);
        _recomputeWeightedPositions(postId, 0, qs);
        _recomputeWeightedPositions(postId, 1, qc);

        settledTotal[postId] = qs.total + qc.total; // post-mint/burn totals

        ps.lastSnapshotEpoch = currentEpoch;
        _observe(postId); // patch_game_b: accrual changed the totals

        _updateSMax(postId, settledTotal[postId]); // just settled above

        emit PostUpdated(postId, currentEpoch, qs.total, qc.total);
    }

    /// @dev ruling 2b: each lot's delta (gain or loss) is scaled by the share of
    ///      the settlement window [windowStart, windowEnd) it was present for.
    ///      windowLen == 0 (legacy caller) means "no proration".
    function _applyEpochFor(
        uint256 postId,
        uint8 side,
        uint256 windowStart,
        uint256 windowEnd,
        SideQueue storage q,
        bool supportWins,
        bool isSupportSide,
        uint256 rBase
    ) internal returns (uint256 minted, uint256 burned) {
        if (q.total == 0 || rBase == 0 || sMax == 0) {
            return (0, 0);
        }
        bool aligned = (supportWins && isSupportSide) || (!supportWins && !isSupportSide);
        uint256 T = q.total;

        for (uint256 i = 0; i < q.lots.length; i++) {
            StakeLot storage lot = q.lots[i];
            if (lot.amount == 0) {
                continue;
            }
            // delta = amount × rBase × midpoint weight, prorated by presence (TimeWeighted.lotDelta —
            // the same function the projection uses, so view == materialised).
            uint256 delta = TimeWeighted.lotDelta(
                lot.amount, lot.weightedPosition, T, rBase, entryTime[postId][side][lot.staker], windowStart, windowEnd
            );
            if (delta < 1) {
                continue;
            }
            if (aligned) {
                lot.amount += delta;
                minted += delta;
            } else {
                uint256 loss = delta > lot.amount ? lot.amount : delta;
                lot.amount -= loss;
                burned += loss;
            }
        }
        // patch_h1a_bucket: settle the pooled tail bucket in O(1)
        (uint256 bMint, uint256 bBurn) = _settleBucket(postId, side, windowStart, windowEnd, q, aligned, rBase);
        minted += bMint;
        burned += bBurn;
    }

    // ------------------------------------------------------------
    // Internal: Lot management
    // ------------------------------------------------------------

    function _getLotIndex(PostState storage ps, address user, uint8 side) internal view returns (uint256) {
        if (side == 0) {
            return ps.lotIndex0[user];
        }
        return ps.lotIndex1[user];
    }

    function _setLotIndex(PostState storage ps, address user, uint8 side, uint256 idxPlusOne) internal {
        if (side == 0) {
            ps.lotIndex0[user] = idxPlusOne;
        } else {
            ps.lotIndex1[user] = idxPlusOne;
        }
    }

    // ------------------------------------------------------------
    // Internal: View projection
    // ------------------------------------------------------------

    /// @dev patch_settlement_snapshots (review CI-1, spec V.8): ONE rate path for projection and
    ///      settlement. The projection asks the ScoreEngine for the same window pool settlement will
    ///      (previewPoolWindow: window-averaged direct totals + snapshot contributions), floors sMax at T
    ///      as settlement does (ruling 3b), and derives rBase through the same library function.
    function _projectRate(uint256 postId, PostState storage ps, uint256 currentEpoch)
        internal
        view
        returns (uint256 rBase, bool supportWins, uint256 wStart, uint256 wEnd)
    {
        uint256 T = ps.sides[0].total + ps.sides[1].total;
        if (T == 0) {
            return (0, false, 0, 0);
        }
        wStart = ps.lastSnapshotEpoch * EPOCH_LENGTH;
        wEnd = currentEpoch * EPOCH_LENGTH;
        uint256 S = ps.sides[0].total;
        uint256 C = ps.sides[1].total;
        if (address(scoreEngine) != address(0)) {
            (S, C) = scoreEngine.previewPoolWindow(postId, wStart, wEnd);
        }
        if (S == C) {
            return (0, false, wStart, wEnd);
        }
        uint256 el = currentEpoch > sMaxLastUpdatedEpoch ? currentEpoch - sMaxLastUpdatedEpoch : 0;
        if (el > sMaxDecayMaxEpochs) {
            el = sMaxDecayMaxEpochs;
        }
        // settlement re-registers THIS post's total first, so its own tracker entry reads as T
        uint256 leader = topPosts[0].postId == postId ? topPosts[1].total : topPosts[0].total;
        uint256 projSMax = TimeWeighted.projectSMax(sMax, leader, T, sMaxDecayRateRay, el);
        rBase = TimeWeighted.rBase(
            S,
            C,
            T,
            projSMax,
            protocolPolicy.stakeIntRateMinRay(),
            protocolPolicy.stakeIntRateMaxRay(),
            EPOCH_LENGTH,
            currentEpoch - ps.lastSnapshotEpoch,
            YEAR_LENGTH
        );
        supportWins = S > C;
    }

    function _projectTotals(uint256 postId, PostState storage ps, uint256 currentEpoch)
        internal
        view
        returns (uint256 projS, uint256 projC)
    {
        (uint256 rBase, bool supportWins, uint256 wStart, uint256 wEnd) = _projectRate(postId, ps, currentEpoch);
        if (rBase == 0) {
            return (ps.sides[0].total, ps.sides[1].total);
        }
        projS = _projectSideTotal(postId, 0, wStart, wEnd, ps.sides[0], supportWins, rBase);
        projC = _projectSideTotal(postId, 1, wStart, wEnd, ps.sides[1], supportWins, rBase);
    }

    /// @dev Mirrors _applyEpochFor lot by lot (midpoint weight, presence proration) and the bucket.
    function _projectSideTotal(
        uint256 postId,
        uint8 side,
        uint256 wStart,
        uint256 wEnd,
        SideQueue storage q,
        bool supportWins,
        uint256 rBase
    ) internal view returns (uint256 total) {
        if (q.total == 0 || rBase == 0) {
            return q.total;
        }
        bool aligned = supportWins == (side == 0);
        uint256 T = q.total;
        for (uint256 i = 0; i < q.lots.length; i++) {
            StakeLot storage lot = q.lots[i];
            if (lot.amount == 0) {
                continue;
            }
            total += _projectLot(postId, side, wStart, wEnd, lot, T, aligned, rBase);
        }
        total += _projectBucket(postId, side, wStart, wEnd, q, aligned, rBase);
    }

    function _projectLot(
        uint256 postId,
        uint8 side,
        uint256 wStart,
        uint256 wEnd,
        StakeLot storage lot,
        uint256 sideTotal,
        bool aligned,
        uint256 rBase
    ) internal view returns (uint256) {
        uint256 delta = TimeWeighted.lotDelta(
            lot.amount, lot.weightedPosition, sideTotal, rBase, entryTime[postId][side][lot.staker], wStart, wEnd
        );
        if (aligned) {
            return lot.amount + delta;
        }
        uint256 loss = delta > lot.amount ? lot.amount : delta;
        return lot.amount - loss;
    }

    function _projectLotValue(uint256 postId, PostState storage ps, StakeLot storage lot, uint256 currentEpoch)
        internal
        view
        returns (uint256)
    {
        (uint256 rBase, bool supportWins, uint256 wStart, uint256 wEnd) = _projectRate(postId, ps, currentEpoch);
        uint256 sideTotal = ps.sides[lot.side].total;
        if (rBase == 0 || sideTotal == 0) {
            return lot.amount;
        }
        return _projectLot(postId, lot.side, wStart, wEnd, lot, sideTotal, supportWins == (lot.side == 0), rBase);
    }

    // ------------------------------------------------------------
    // Internal: sMax management
    // ------------------------------------------------------------

    function _currentEpoch() internal view returns (uint256) {
        return block.timestamp / EPOCH_LENGTH;
    }

    function _updateSMax(uint256 postId, uint256 postTotal) internal {
        (uint256 leaderTotal, uint256 leaderId) = TimeWeighted.trackerUpdate(topPosts, postId, postTotal);
        uint256 currentEpoch = _currentEpoch();
        if (leaderTotal > 0) {
            if (leaderTotal >= sMax) {
                sMax = leaderTotal;
                sMaxLastUpdatedEpoch = currentEpoch;
            } else {
                // patch_prC_rulings S-03 layer (i): NEVER snap down. Decay is
                // the sole descent, floored at the tracked leader. The old
                // immediate snap-down let a 1-wei dust post drag sMax to dust
                // the instant the tracked leaders unwound, inflating every
                // other post's participation factor to the clamp.
                uint256 decayed = _applySMaxDecay(currentEpoch);
                if (decayed < leaderTotal) {
                    sMax = leaderTotal;
                }
            }
            sMaxPostId = leaderId;
        } else {
            sMax = _applySMaxDecay(currentEpoch);
        }
    }

    /// @notice patch_prC_rulings S-03 layer (ii): the irreducible "poke" for
    ///         lazy-accrual dormant posts. Permissionless: it can only feed the
    ///         tracker a post's TRUE stored total (settling first if an epoch
    ///         boundary has passed), so the worst any caller can do is make
    ///         sMax more honest. The ops worker calls this each epoch for the
    ///         largest known posts; anyone else can close a deviation the
    ///         moment they see one (I.4 restoration is permissionless).
    function refreshSMax(uint256 postId) external nonReentrant {
        _maybeSnapshot(postId, _currentEpoch(), false);
        PostState storage ps = posts[postId];
        uint256 total = settledTotal[postId]; // ruling 3b: settled, not live
        _updateSMax(postId, total);
        emit SMaxRefreshed(postId, total, sMax);
    }

    /// @dev patch_settlement_snapshots (review R3 C-4): after a user mutation. Ordinarily re-feed the
    ///      tracker with the settled total (ruling 3b). But when the post is drained to zero AND it is
    ///      the post that defines sMax, reset its settled total, drop it from the tracker and snap
    ///      sMax to the remaining tracked leader in the same transaction — otherwise a transient
    ///      leader that settled once and left would pin every post's participation for the whole
    ///      decay window (never-snap-down protects against dust drag, not against ghosts).
    function _refeedSMax(uint256 postId) internal {
        PostState storage ps = posts[postId];
        if (ps.sides[0].total == 0 && ps.sides[1].total == 0) {
            settledTotal[postId] = 0;
            bool wasLeader = sMaxPostId == postId;
            _updateSMax(postId, 0);
            if (wasLeader) {
                sMax = topPosts[0].total;
                sMaxPostId = topPosts[0].postId;
                sMaxLastUpdatedEpoch = _currentEpoch();
            }
            return;
        }
        _updateSMax(postId, settledTotal[postId]);
    }

    function _applySMaxDecay(uint256 currentEpoch) internal returns (uint256) {
        if (sMax == 0 || currentEpoch <= sMaxLastUpdatedEpoch) {
            sMaxLastUpdatedEpoch = currentEpoch;
            return sMax;
        }
        uint256 elapsed = currentEpoch - sMaxLastUpdatedEpoch;
        if (elapsed > sMaxDecayMaxEpochs) {
            elapsed = sMaxDecayMaxEpochs;
        }
        uint256 decayed = TimeWeighted.decay(sMax, sMaxDecayRateRay, elapsed);
        sMax = decayed;
        sMaxLastUpdatedEpoch = currentEpoch;
        return decayed;
    }

    function rescanSMax(uint256[] calldata postIds) external onlyGovernance {
        for (uint256 i = 0; i < TRACKED_POSTS; i++) {
            topPosts[i] = TimeWeighted.TopPost(0, 0);
        }
        for (uint256 i = 0; i < postIds.length; i++) {
            uint256 pid = postIds[i];
            PostState storage ps = posts[pid];
            uint256 total = settledTotal[pid]; // ruling 3b: settled, not live
            if (total == 0) {
                continue;
            }
            _updateSMax(pid, total);
        }
        emit SMaxRescanned(topPosts[0].total, topPosts[0].postId);
    }

    /// @dev Recompute weighted positions as midpoints: cumBefore + amount/2.
    ///      Called after any queue mutation (stake, withdraw, compact, epoch).
    // ===================================================================
    // patch_h1a_bucket: pooled tail-bucket + unified position helpers
    // ===================================================================

    /// @dev patch_prC_rulings S-01: returns the stored index verbatim. 0 now
    ///      means only "never initialized" (empty bucket, zero scaled shares);
    ///      _bucketAdd writes RAY explicitly on first entry and _settleBucket
    ///      floors at 1, so a member-bearing bucket can never store 0.
    function _bucketIndex(SideQueue storage q) internal view returns (uint256) {
        return q.bucketIndexRay;
    }

    function _bucketLive(SideQueue storage q) internal view returns (uint256) {
        return (q.bucketScaledTotal * _bucketIndex(q)) / RAY;
    }

    function _getBucketShares(PostState storage ps, address user, uint8 side) internal view returns (uint256) {
        return side == 0 ? ps.bucketShares0[user] : ps.bucketShares1[user];
    }

    function _setBucketShares(PostState storage ps, address user, uint8 side, uint256 shares) internal {
        if (side == 0) {
            ps.bucketShares0[user] = shares;
        } else {
            ps.bucketShares1[user] = shares;
        }
    }

    /// @dev User's live amount on a side, whether ranked or bucketed (as of last snapshot).
    function _userAmount(PostState storage ps, uint8 side, address user) internal view returns (uint256) {
        uint256 idx = _getLotIndex(ps, user, side);
        if (idx != 0) {
            return ps.sides[side].lots[idx - 1].amount;
        }
        uint256 shares = _getBucketShares(ps, user, side);
        if (shares == 0) {
            return 0;
        }
        return (shares * _bucketIndex(ps.sides[side])) / RAY;
    }

    /// @dev O(C) scan for the smallest ranked lot index.
    function _smallestRankedIndex(SideQueue storage q) internal view returns (uint256 minIdx) {
        minIdx = 0;
        uint256 minAmt = q.lots[0].amount;
        for (uint256 i = 1; i < q.lots.length; i++) {
            if (q.lots[i].amount < minAmt) {
                minAmt = q.lots[i].amount;
                minIdx = i;
            }
        }
    }

    /// @dev Add `amount` to a (new or existing) bucket member. O(1).
    function _bucketAdd(
        uint256 postId,
        PostState storage ps,
        SideQueue storage q,
        uint8 side,
        address user,
        uint256 amount
    ) internal {
        // patch_settlement_snapshots (review R3 F-B): the bucket ages like one lot — its entry time is
        // the live-amount-weighted blend of its members' entry times (the member's own entry time is
        // already amount-weighted across top-ups by _increaseUser).
        {
            uint256 etU = entryTime[postId][side][user];
            if (etU != 0) {
                uint256 liveB = _bucketLive(q);
                uint256 etB = bucketEntryTime[postId][side];
                bucketEntryTime[postId][side] =
                    (liveB == 0 || etB == 0) ? etU : (liveB * etB + amount * etU) / (liveB + amount);
            }
        }
        // patch_prC_rulings S-01: honest init. Index 0 <=> no member has ever
        // entered (settlement floors at 1, so decay cannot write 0), and with
        // no members there are no shares to revalue — initializing to RAY here
        // is therefore always safe and never resurrects wiped value.
        if (q.bucketIndexRay == 0) {
            q.bucketIndexRay = RAY;
        }
        uint256 prev = _getBucketShares(ps, user, side);
        uint256 shares = (amount * RAY) / _bucketIndex(q);
        q.bucketScaledTotal += shares;
        _setBucketShares(ps, user, side, prev + shares);
        if (prev == 0) {
            _heapInsert(ps, q, side, user); // patch_h1b_promotion
        } else {
            _heapUpdate(ps, q, side, user);
        }
    }

    /// @dev Remove up to `amount` of live value from a bucket member. Returns the
    ///      exact value removed (<= amount; never over-pays). O(1).
    function _bucketRemove(PostState storage ps, SideQueue storage q, uint8 side, address user, uint256 amount)
        internal
        returns (uint256 removed)
    {
        uint256 shares = _getBucketShares(ps, user, side);
        if (shares == 0) {
            return 0;
        }
        uint256 ix = _bucketIndex(q);
        uint256 live = (shares * ix) / RAY;
        if (amount >= live) {
            // full exit: remove all shares, pay their exact live value
            q.bucketScaledTotal -= shares;
            _setBucketShares(ps, user, side, 0);
            _heapRemove(ps, q, side, user); // patch_h1b_promotion
            return live;
        }
        // partial: floor shares so removed value <= amount (solvency-safe)
        uint256 sharesOut = (amount * RAY) / ix;
        if (sharesOut > shares) {
            sharesOut = shares;
        }
        q.bucketScaledTotal -= sharesOut;
        _setBucketShares(ps, user, side, shares - sharesOut);
        _heapUpdate(ps, q, side, user); // patch_h1b_promotion
        return (sharesOut * ix) / RAY;
    }

    /// @dev Append a fresh ranked lot at the tail (arrival order). O(1) + caller recomputes positions.
    function _pushRankedLot(PostState storage ps, SideQueue storage q, uint8 side, address user, uint256 amount)
        internal
    {
        q.lots.push(StakeLot({staker: user, amount: amount, side: side, weightedPosition: 0}));
        _setLotIndex(ps, user, side, q.lots.length);
    }

    /// @dev Demote ranked lot at `sIdx` into the bucket, then compact the array so
    ///      survivors keep arrival order ("all those after it move up"). O(C).
    function _demoteRankedToBucket(uint256 postId, PostState storage ps, SideQueue storage q, uint8 side, uint256 sIdx)
        internal
    {
        StakeLot storage victim = q.lots[sIdx];
        address vStaker = victim.staker;
        uint256 vAmount = victim.amount;
        _setLotIndex(ps, vStaker, side, 0);
        // patch_h1b_promotion: never demote a 0-amount ghost into the bucket/heap;
        // just drop it (this also compacts ghosts during rebalance).
        if (vAmount > 0) {
            _bucketAdd(postId, ps, q, side, vStaker, vAmount);
            emit LotDemoted(postId, side, vStaker, vAmount);
        }
        _removeRankedAt(ps, q, side, sIdx);
    }

    /// @dev Remove q.lots[i] by shift-compacting the tail (arrival order preserved), fixing indices.
    function _removeRankedAt(PostState storage ps, SideQueue storage q, uint8 side, uint256 i) internal {
        uint256 last = q.lots.length - 1;
        for (; i < last; i++) {
            q.lots[i] = q.lots[i + 1];
            _setLotIndex(ps, q.lots[i].staker, side, i + 1);
        }
        q.lots.pop();
    }

    /// @dev Increase a user's position by `amount` (already transferred in).
    ///      Routes to ranked-merge, bucket-add, new-ranked, or evict-or-bucket.
    ///      q.total is recomputed exactly (O(C)) so it never drifts from
    ///      rankedSum + bucketLive under bucket index rounding.
    function _increaseUser(uint256 postId, uint8 side, uint256 amount, address user) internal {
        PostState storage ps = posts[postId];
        SideQueue storage q = ps.sides[side];
        // ruling 2b: entry time is amount-weighted across tranches, so capital
        // added at a boundary ages the lot toward "now" in proportion to its size.
        {
            uint256 prev = _userAmount(ps, side, user);
            uint256 et = entryTime[postId][side][user];
            entryTime[postId][side][user] =
                (prev == 0 || et == 0) ? block.timestamp : (prev * et + amount * block.timestamp) / (prev + amount);
        }

        uint256 idx = _getLotIndex(ps, user, side);
        if (idx != 0 && q.lots[idx - 1].amount == 0) {
            // S-02 FIX v2: remove the ghost from the array (shift-compact, preserving arrival
            // order) before re-entering, so one address can never hold both a ghost entry and a
            // live entry. The re-entry then takes the same route as a brand-new staker below.
            _removeRankedAt(ps, q, side, idx - 1);
            _setLotIndex(ps, user, side, 0);
            idx = 0;
        }
        if (idx != 0) {
            // ruling 1c: capital-weighted position. New capital enters at
            // the tail midpoint (T_now + amount/2); the lot's position
            // becomes the amount-weighted average of old and new entries.
            StakeLot storage lot = q.lots[idx - 1];
            uint256 oldAmt = lot.amount;
            uint256 tailEntry = q.total + amount / 2;
            uint256 blended = (oldAmt * lot.weightedPosition + amount * tailEntry) / (oldAmt + amount);
            uint256 natural =
                (lot.weightedPosition > posOffset[postId][side][user]
                            ? lot.weightedPosition - posOffset[postId][side][user]
                            : 0) + amount / 2; // natural midpoint after growth: cumBefore + newAmt/2
            posOffset[postId][side][user] = blended > natural ? blended - natural : 0;
            lot.amount += amount; // existing ranked staker
        } else if (_getBucketShares(ps, user, side) != 0) {
            _bucketAdd(postId, ps, q, side, user, amount); // existing bucket member (may promote via _rebalance)
        } else if (q.lots.length < MAX_RANKED_LOTS) {
            _pushRankedLot(ps, q, side, user, amount); // new ranked lot
        } else {
            uint256 sIdx = _smallestRankedIndex(q);
            if (amount > q.lots[sIdx].amount) {
                _demoteRankedToBucket(postId, ps, q, side, sIdx); // evict smallest, append new at tail
                _pushRankedLot(ps, q, side, user, amount);
            } else {
                _bucketAdd(postId, ps, q, side, user, amount); // too small for a slot -> bucket
            }
        }
        _rebalance(postId, ps, q, side); // patch_h1b_promotion: keep ranked = the C largest
        _recomputeWeightedPositions(postId, side, q);
        _recomputeSideTotal(q); // exact side total (ranked + bucketLive)
        _observe(postId); // patch_game_b
        _refeedSMax(postId); // ruling 3b (settled, not live) + review R3 C-4 (drain snap-down)
    }

    /// @dev Decrease a user's position by up to `amount`. Returns value removed.
    ///      Ranked: reduce lot + O(C) reposition. Bucket: O(1). (H-1b: promotion.)
    function _decreaseUser(uint256 postId, uint8 side, uint256 amount, address user)
        internal
        returns (uint256 removed)
    {
        PostState storage ps = posts[postId];
        SideQueue storage q = ps.sides[side];
        uint256 idx = _getLotIndex(ps, user, side);
        if (idx != 0) {
            StakeLot storage lot = q.lots[idx - 1];
            removed = amount > lot.amount ? lot.amount : amount;
            lot.amount -= removed;
        } else {
            removed = _bucketRemove(ps, q, side, user, amount);
        }
        _rebalance(postId, ps, q, side); // patch_h1b_promotion: fill freed slots / swap boundary
        _recomputeWeightedPositions(postId, side, q);
        _recomputeSideTotal(q); // exact side total (ranked + bucketLive)
        _observe(postId); // patch_game_b
    }

    /// @dev Project the bucket's live value forward one settlement at `rBase`
    ///      using the blended tail-midpoint rate. Mirrors _projectSideTotal.
    function _projectBucket(
        uint256 postId,
        uint8 side,
        uint256 wStart,
        uint256 wEnd,
        SideQueue storage q,
        bool aligned,
        uint256 rBase
    ) internal view returns (uint256) {
        uint256 live = _bucketLive(q);
        if (live == 0 || rBase == 0) {
            return live;
        }
        uint256 T = q.total;
        if (T == 0) {
            return live;
        }
        uint256 newIx = TimeWeighted.bucketIndexAfter(
            _bucketIndex(q), live, T, rBase, aligned, bucketEntryTime[postId][side], wStart, wEnd
        );
        return (q.bucketScaledTotal * newIx) / RAY;
    }

    /// @dev Settle the bucket in place (one epoch) via a single index rebase.
    ///      Returns minted/burned for the bucket slab. O(1).
    function _settleBucket(
        uint256 postId,
        uint8 side,
        uint256 windowStart,
        uint256 windowEnd,
        SideQueue storage q,
        bool aligned,
        uint256 rBase
    ) internal returns (uint256 minted, uint256 burned) {
        uint256 live = _bucketLive(q);
        if (q.bucketScaledTotal == 0 || live == 0 || rBase == 0) {
            return (0, 0);
        }
        uint256 T = q.total;
        if (T == 0) {
            return (0, 0);
        }
        uint256 ix = _bucketIndex(q);
        uint256 newIx = TimeWeighted.bucketIndexAfter(
            ix, live, T, rBase, aligned, bucketEntryTime[postId][side], windowStart, windowEnd
        );
        q.bucketIndexRay = newIx;
        uint256 newLive = (q.bucketScaledTotal * newIx) / RAY;
        if (newLive >= live) {
            minted = newLive - live;
        } else {
            burned = live - newLive;
        }
    }

    // ===================================================================
    // patch_h1b_promotion: bucket max-heap (keyed on scaledShares) + rebalance
    // ===================================================================

    function _getHeapPos(PostState storage ps, address user, uint8 side) internal view returns (uint256) {
        return side == 0 ? ps.bucketHeapPos0[user] : ps.bucketHeapPos1[user];
    }

    function _setHeapPos(PostState storage ps, address user, uint8 side, uint256 v) internal {
        if (side == 0) {
            ps.bucketHeapPos0[user] = v;
        } else {
            ps.bucketHeapPos1[user] = v;
        }
    }

    function _heapKey(PostState storage ps, uint8 side, address a) internal view returns (uint256) {
        return _getBucketShares(ps, a, side); // scaledShares: rebase-invariant
    }

    function _heapPeekMax(SideQueue storage q) internal view returns (address) {
        return q.bucketHeap.length == 0 ? address(0) : q.bucketHeap[0];
    }

    function _heapSwap(PostState storage ps, SideQueue storage q, uint8 side, uint256 i, uint256 j) internal {
        address ai = q.bucketHeap[i];
        address aj = q.bucketHeap[j];
        q.bucketHeap[i] = aj;
        q.bucketHeap[j] = ai;
        _setHeapPos(ps, aj, side, i + 1);
        _setHeapPos(ps, ai, side, j + 1);
    }

    function _siftUp(PostState storage ps, SideQueue storage q, uint8 side, uint256 i) internal {
        while (i > 0) {
            uint256 parent = (i - 1) / 2;
            if (_heapKey(ps, side, q.bucketHeap[i]) <= _heapKey(ps, side, q.bucketHeap[parent])) {
                break;
            }
            _heapSwap(ps, q, side, i, parent);
            i = parent;
        }
    }

    function _siftDown(PostState storage ps, SideQueue storage q, uint8 side, uint256 i) internal {
        uint256 n = q.bucketHeap.length;
        while (true) {
            uint256 l = 2 * i + 1;
            uint256 r = 2 * i + 2;
            uint256 big = i;
            if (l < n && _heapKey(ps, side, q.bucketHeap[l]) > _heapKey(ps, side, q.bucketHeap[big])) {
                big = l;
            }
            if (r < n && _heapKey(ps, side, q.bucketHeap[r]) > _heapKey(ps, side, q.bucketHeap[big])) {
                big = r;
            }
            if (big == i) {
                break;
            }
            _heapSwap(ps, q, side, i, big);
            i = big;
        }
    }

    function _heapInsert(PostState storage ps, SideQueue storage q, uint8 side, address addr) internal {
        q.bucketHeap.push(addr);
        uint256 i = q.bucketHeap.length - 1;
        _setHeapPos(ps, addr, side, i + 1);
        _siftUp(ps, q, side, i);
    }

    function _heapRemove(PostState storage ps, SideQueue storage q, uint8 side, address addr) internal {
        uint256 pos = _getHeapPos(ps, addr, side);
        if (pos == 0) {
            return;
        }
        uint256 i = pos - 1;
        uint256 lastIdx = q.bucketHeap.length - 1;
        address lastAddr = q.bucketHeap[lastIdx];
        q.bucketHeap[i] = lastAddr;
        _setHeapPos(ps, lastAddr, side, i + 1);
        q.bucketHeap.pop();
        _setHeapPos(ps, addr, side, 0);
        if (i < q.bucketHeap.length) {
            _siftUp(ps, q, side, i);
            _siftDown(ps, q, side, i);
        }
    }

    function _heapUpdate(PostState storage ps, SideQueue storage q, uint8 side, address addr) internal {
        uint256 pos = _getHeapPos(ps, addr, side);
        if (pos == 0) {
            return;
        }
        uint256 i = pos - 1;
        _siftUp(ps, q, side, i);
        _siftDown(ps, q, side, i);
    }

    /// @dev Promote a bucket member to the ranked set at its live value (tail slot,
    ///      arrival order). Full bucket exit + heap remove. O(C + log n).
    function _promoteToRanked(uint256 postId, PostState storage ps, SideQueue storage q, uint8 side, address member)
        internal
    {
        uint256 shares = _getBucketShares(ps, member, side);
        if (shares == 0) {
            return;
        }
        uint256 live = (shares * _bucketIndex(q)) / RAY;
        q.bucketScaledTotal -= shares;
        _setBucketShares(ps, member, side, 0);
        _heapRemove(ps, q, side, member);
        _pushRankedLot(ps, q, side, member, live);
        emit LotPromoted(postId, side, member, live);
    }

    /// @dev Restore "ranked = the C largest": fill any free ranked slots from the
    ///      top of the bucket, then swap while max(bucket) > min(ranked). The
    ///      invariant holds before each mutation, so in practice this is <=1 move;
    ///      the iter cap is a hard DoS backstop (O(C) worst case). O(C + log n).
    function _rebalance(uint256 postId, PostState storage ps, SideQueue storage q, uint8 side) internal {
        while (q.lots.length < MAX_RANKED_LOTS && q.bucketScaledTotal > 0) {
            _promoteToRanked(postId, ps, q, side, _heapPeekMax(q));
        }
        uint256 iter = 0;
        while (q.bucketScaledTotal > 0 && q.lots.length == MAX_RANKED_LOTS && iter < MAX_RANKED_LOTS) {
            address mx = _heapPeekMax(q);
            uint256 mxLive = (_getBucketShares(ps, mx, side) * _bucketIndex(q)) / RAY;
            uint256 sIdx = _smallestRankedIndex(q);
            if (mxLive <= q.lots[sIdx].amount) {
                break;
            }
            _demoteRankedToBucket(postId, ps, q, side, sIdx);
            _promoteToRanked(postId, ps, q, side, mx);
            iter++;
        }
    }

    function _recomputeWeightedPositions(uint256 postId, uint8 side, SideQueue storage q) internal {
        uint256 cumulative = 0;
        uint256 T = 0;
        for (uint256 i = 0; i < q.lots.length; i++) {
            T += q.lots[i].amount;
        }
        for (uint256 i = 0; i < q.lots.length; i++) {
            uint256 a = q.lots[i].amount;
            if (a == 0) {
                continue;
            }
            uint256 natural = cumulative + a / 2;
            uint256 off = posOffset[postId][side][q.lots[i].staker];
            uint256 wp = natural + off;
            // a blended position can never be behind the tail of the side
            uint256 tailMid = T > a / 2 ? T - a / 2 : 0;
            if (wp > tailMid) {
                wp = tailMid;
            }
            q.lots[i].weightedPosition = wp;
            cumulative += a;
        }
    }

    function _recomputeSideTotal(SideQueue storage q) internal {
        uint256 total = 0;
        for (uint256 i = 0; i < q.lots.length; i++) {
            total += q.lots[i].amount;
        }
        q.total = total + _bucketLive(q); // patch_h1a_bucket
    }
    // ── patch_game_b: two slots consumed from __gap (495 -> 493); layout re-baselined deliberately ──
    mapping(uint256 => TimeWeighted.Observation[]) internal observations;
    using TimeWeighted for TimeWeighted.Observation[];
    /// @dev ScoreEngine that supplies the effective pool at settlement (v17 §3.2). address(0) =
    ///      unwired (test harnesses): settlement uses direct totals, as v16 did.
    IScoreEngineV2 public scoreEngine;
    /// @dev patch_settlement_snapshots (slot after scoreEngine — appended, never inserted) (review R3 F-B): the pooled tail bucket's amount-weighted entry
    ///      time per (post, side), so bucket accrual is prorated by presence like a ranked lot (§3.2).
    mapping(uint256 => uint256[2]) internal bucketEntryTime;

    uint256[492] private __gap; // 493 -> 492 (bucketEntryTime) patch_settlement_snapshots // 495 -> 493 (observations, scoreEngine) patch_game_b // 499 -> 498 (postRegistry) -> 495 (posOffset, entryTime, settledTotal)
}

/// @dev Minimal read surface the engine needs from PostRegistry (H1).
interface IPostRegistryIds {
    function nextPostId() external view returns (uint256);
}
