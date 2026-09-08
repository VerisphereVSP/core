// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IVSPToken.sol";
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

    struct TopPost {
        uint256 postId;
        uint256 total;
    }
    TopPost[TRACKED_POSTS] private topPosts;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus;

    modifier nonReentrant() {
        require(_reentrancyStatus != _ENTERED, "ReentrancyGuard: reentrant call");
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
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
        if (paused) {
            revert WhenPaused();
        }
        _;
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
        // S-08 FIX: single forward read/write compaction pass instead of reverse
        // swap-and-pop, so survivors keep arrival order. Swap-and-pop moved the
        // LAST staker into the ghost's slot, promoting them at another honest
        // staker's expense.
        uint256 write = 0;
        uint256 len = q.lots.length;
        for (uint256 read = 0; read < len; read++) {
            StakeLot storage src = q.lots[read];
            if (src.amount == 0) {
                _setLotIndex(ps, src.staker, side, 0);
                removed++;
                continue;
            }
            if (write != read) {
                q.lots[write] = src;
            }
            _setLotIndex(ps, q.lots[write].staker, side, write + 1);
            write++;
        }
        for (uint256 k = 0; k < removed; k++) {
            q.lots.pop();
        }
        if (removed == 0) {
            revert NoGhostLots();
        }

        // Recompute positions after swap-and-pop changes array layout
        _recomputeWeightedPositions(postId, side, q);

        emit LotsCompacted(postId, side, removed);
    }

    // ------------------------------------------------------------
    // Read (view — always current via projection)
    // ------------------------------------------------------------

    function getPostTotals(uint256 postId) external view returns (uint256 support, uint256 challenge) {
        PostState storage ps = posts[postId];
        uint256 currentEpoch = _currentEpoch();
        uint256 snapshotEpoch = ps.lastSnapshotEpoch;
        uint256 storedS = ps.sides[0].total;
        uint256 storedC = ps.sides[1].total;
        if (snapshotEpoch == 0 || currentEpoch <= snapshotEpoch) {
            return (storedS, storedC);
        }
        return _projectTotals(ps, currentEpoch);
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
        require(ERC20_TOKEN.transferFrom(_msgSender(), address(this), amount), "VSP transfer failed");
        PostState storage ps = posts[postId];
        uint256 epoch = _currentEpoch();
        if (ps.lastSnapshotEpoch == 0) {
            ps.lastSnapshotEpoch = epoch;
        }
        _maybeSnapshot(postId, epoch);
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
        _maybeSnapshot(postId, epoch);
        // patch_h1a_bucket: unified ranked/bucket decrease (both bounded)
        if (_userAmount(ps, side, _msgSender()) < amount) {
            revert NotEnoughStake();
        }
        uint256 removed = _decreaseUser(postId, side, amount, _msgSender());
        _updateSMax(postId, settledTotal[postId]); // ruling 3b: settled, not live
        require(ERC20_TOKEN.transfer(_msgSender(), removed), "VSP transfer failed");
        emit StakeWithdrawn(postId, _msgSender(), side, removed, true);
    }

    // ------------------------------------------------------------
    // Permissionless update
    // ------------------------------------------------------------

    function updatePost(uint256 postId) external nonReentrant {
        uint256 epoch = _currentEpoch();
        _forceSnapshot(postId, epoch);
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
        _maybeSnapshot(postId, epoch);
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
                require(ERC20_TOKEN.transferFrom(user, address(this), toStake), "VSP transfer failed");
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
                require(ERC20_TOKEN.transferFrom(user, address(this), toStake), "VSP transfer failed");
                _increaseUser(postId, 1, toStake, user); // patch_h1a_bucket
                emit StakeAdded(postId, user, 1, toStake);
            } else if (absTarget < currentChal) {
                _doWithdraw(postId, ps, user, 1, currentChal - absTarget);
            }
        }

        _updateSMax(postId, settledTotal[postId]); // ruling 3b: settled, not live
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
        require(ERC20_TOKEN.transfer(user, removed), "VSP transfer failed");
        emit StakeWithdrawn(postId, user, side, removed, true);
    }

    function _maybeSnapshot(uint256 postId, uint256 currentEpoch) internal {
        PostState storage ps = posts[postId];
        uint256 lastEpoch = ps.lastSnapshotEpoch;
        if (lastEpoch == 0) {
            ps.lastSnapshotEpoch = currentEpoch;
            return;
        }
        uint256 periodInEpochs = snapshotPeriod / EPOCH_LENGTH;
        if (periodInEpochs == 0) {
            periodInEpochs = 1;
        }
        if (currentEpoch >= lastEpoch + periodInEpochs) {
            _forceSnapshot(postId, currentEpoch);
        }
    }

    function _forceSnapshot(uint256 postId, uint256 currentEpoch) internal {
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

        if (T == 0 || sMax == 0) {
            ps.lastSnapshotEpoch = currentEpoch;
            return;
        }

        int256 vsNum = int256(2 * A) - int256(T);
        if (vsNum == 0) {
            // VS neutral — no growth/decay. patch_prC_rulings S-12: the old
            // _rescalePositions call here was dead in effect — positions are
            // recomputed as midpoints (< total) after every queue mutation and
            // every settlement, so its rescale body never executed; the
            // clamp inside _applyEpoch remains the safety net regardless.
            ps.lastSnapshotEpoch = currentEpoch;
            return;
        }

        bool supportWins = vsNum > 0;
        uint256 absVS = uint256(vsNum > 0 ? vsNum : -vsNum);

        uint256 epochsElapsed = currentEpoch - lastEpoch;
        uint256 vRay = (absVS * RAY) / T;
        // patch_prC_rulings S-04 (ratified): participation deliberately couples
        // every post's rate to the GLOBAL leader via sMax — smaller posts earn a
        // scaled-down rate by design; this is the intended cross-post coupling.
        uint256 participationRay = (T * RAY) / sMax;
        if (participationRay > RAY) {
            participationRay = RAY;
        }

        uint256 rMin = (protocolPolicy.stakeIntRateMinRay() * EPOCH_LENGTH * epochsElapsed) / YEAR_LENGTH;
        uint256 rMax = (protocolPolicy.stakeIntRateMaxRay() * EPOCH_LENGTH * epochsElapsed) / YEAR_LENGTH;
        uint256 rBase = rMin + ((rMax - rMin) * vRay * participationRay) / (RAY * RAY);

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

        _updateSMax(postId, settledTotal[postId]); // just settled above

        emit PostUpdated(postId, currentEpoch, qs.total, qc.total);
    }

    // patch_prC_rulings S-12: _rescalePositions removed (dead code). Positions
    // are recomputed as midpoints (< q.total) after every queue mutation and
    // settlement, so the rescale condition never fired outside the neutral
    // branch, where it was a no-op. The _applyEpoch clamp is the safety net.
    /// @dev Applies epoch gains/losses with midpoint positional weighting.
    ///      Each lot's delta = amount * rBase * (T - wPos) / T.
    ///      No redistribution: unminted rate is simply not created.
    ///      Individual earn is capped: (T - wPos) / T <= 1, so delta <= amount * rBase.
    function _applyEpoch(SideQueue storage q, bool supportWins, bool isSupportSide, uint256 rBase)
        internal
        returns (uint256 minted, uint256 burned)
    {
        return _applyEpochFor(0, 0, 0, 0, q, supportWins, isSupportSide, rBase);
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
            // midpointRate = (T - wPos) / T, clamped to [0, RAY]
            uint256 behindMe = lot.weightedPosition < T ? T - lot.weightedPosition : 0;
            uint256 midpointRate = (behindMe * RAY) / T;
            if (midpointRate > RAY) {
                midpointRate = RAY;
            }
            // delta = amount * rBase * midpointRate / RAY, then prorated by presence
            uint256 delta = (lot.amount * rBase * midpointRate) / (RAY * RAY);
            if (windowEnd > windowStart) {
                uint256 et = entryTime[postId][side][lot.staker];
                if (et > windowStart) {
                    uint256 present = et < windowEnd ? windowEnd - et : 0;
                    delta = (delta * present) / (windowEnd - windowStart);
                }
            }
            if (delta == 0) {
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
        (uint256 bMint, uint256 bBurn) = _settleBucket(q, aligned, rBase);
        minted += bMint;
        burned += bBurn;
    }

    // ------------------------------------------------------------
    // Internal: Lot management
    // ------------------------------------------------------------

    /// @dev Retired by patch_h1a_bucket — superseded by _increaseUser (cap+bucket
    ///      aware). Retained as a guarded stub so any stale caller fails loudly.
    function _addOrMergeLot(uint256 postId, uint8 side, uint256 amount, address staker) internal {
        _increaseUser(postId, side, amount, staker);
    }

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

    function _projectTotals(PostState storage ps, uint256 currentEpoch)
        internal
        view
        returns (uint256 projS, uint256 projC)
    {
        SideQueue storage qs = ps.sides[0];
        SideQueue storage qc = ps.sides[1];
        uint256 A = qs.total;
        uint256 D = qc.total;
        uint256 T = A + D;
        if (T == 0) {
            return (A, D);
        }
        int256 vsNum = int256(2 * A) - int256(T);
        if (vsNum == 0) {
            return (A, D);
        }
        bool supportWins = vsNum > 0;
        uint256 absVS = uint256(vsNum > 0 ? vsNum : -vsNum);
        uint256 epochsElapsed = currentEpoch - ps.lastSnapshotEpoch;
        // S-10 FIX: settlement (_forceSnapshot) divides by the RAW sMax, so the
        // view must too, otherwise V.8 (view == materialised) breaks whenever
        // topPosts is empty and the decay fallback is live.
        uint256 projSMax = sMax;
        // ruling 3b: settlement registers T into sMax BEFORE applying the epoch,
        // so the projection floors sMax at T (and never bails on sMax == 0).
        if (projSMax < T) {
            projSMax = T;
        }
        uint256 vRay = (absVS * RAY) / T;
        uint256 participationRay = (T * RAY) / projSMax;
        if (participationRay > RAY) {
            participationRay = RAY;
        }
        uint256 rMin = (protocolPolicy.stakeIntRateMinRay() * EPOCH_LENGTH * epochsElapsed) / YEAR_LENGTH;
        uint256 rMax = (protocolPolicy.stakeIntRateMaxRay() * EPOCH_LENGTH * epochsElapsed) / YEAR_LENGTH;
        uint256 rBase = rMin + ((rMax - rMin) * vRay * participationRay) / (RAY * RAY);
        projS = _projectSideTotal(qs, supportWins, true, rBase);
        projC = _projectSideTotal(qc, supportWins, false, rBase);
    }

    function _projectSideTotal(SideQueue storage q, bool supportWins, bool isSupportSide, uint256 rBase)
        internal
        view
        returns (uint256 total)
    {
        if (q.total == 0 || rBase == 0) {
            return q.total;
        }
        bool aligned = (supportWins && isSupportSide) || (!supportWins && !isSupportSide);
        uint256 T = q.total;

        total = 0;
        for (uint256 i = 0; i < q.lots.length; i++) {
            StakeLot storage lot = q.lots[i];
            if (lot.amount == 0) {
                continue;
            }
            uint256 behindMe = lot.weightedPosition < T ? T - lot.weightedPosition : 0;
            uint256 midpointRate = (behindMe * RAY) / T;
            if (midpointRate > RAY) {
                midpointRate = RAY;
            }
            uint256 delta = (lot.amount * rBase * midpointRate) / (RAY * RAY);
            if (aligned) {
                total += lot.amount + delta;
            } else {
                uint256 loss = delta > lot.amount ? lot.amount : delta;
                total += lot.amount - loss;
            }
        }
        total += _projectBucket(q, aligned, rBase); // patch_h1a_bucket
    }

    function _projectLotValue(uint256 postId, PostState storage ps, StakeLot storage lot, uint256 currentEpoch)
        internal
        view
        returns (uint256)
    {
        SideQueue storage qs = ps.sides[0];
        SideQueue storage qc = ps.sides[1];
        uint256 A = qs.total;
        uint256 D = qc.total;
        uint256 T = A + D;
        if (T == 0) {
            return lot.amount;
        }
        int256 vsNum = int256(2 * A) - int256(T);
        if (vsNum == 0) {
            return lot.amount;
        }
        bool supportWins = vsNum > 0;
        bool isSupportSide = lot.side == 0;
        bool aligned = (supportWins && isSupportSide) || (!supportWins && !isSupportSide);
        uint256 absVS = uint256(vsNum > 0 ? vsNum : -vsNum);
        uint256 epochsElapsed = currentEpoch - ps.lastSnapshotEpoch;
        // S-10 FIX (second site): same reasoning as _projectTotals.
        uint256 projSMax = sMax;
        // ruling 3b: settlement registers T into sMax BEFORE applying the epoch,
        // so the projection floors sMax at T (and never bails on sMax == 0).
        if (projSMax < T) {
            projSMax = T;
        }
        uint256 vRay = (absVS * RAY) / T;
        uint256 participationRay = (T * RAY) / projSMax;
        if (participationRay > RAY) {
            participationRay = RAY;
        }
        uint256 rMin = (protocolPolicy.stakeIntRateMinRay() * EPOCH_LENGTH * epochsElapsed) / YEAR_LENGTH;
        uint256 rMax = (protocolPolicy.stakeIntRateMaxRay() * EPOCH_LENGTH * epochsElapsed) / YEAR_LENGTH;
        uint256 rBase = rMin + ((rMax - rMin) * vRay * participationRay) / (RAY * RAY);

        SideQueue storage mySide = isSupportSide ? qs : qc;
        uint256 sideTotal = mySide.total;
        if (sideTotal == 0 || rBase == 0) {
            return lot.amount;
        }

        uint256 behindMe = lot.weightedPosition < sideTotal ? sideTotal - lot.weightedPosition : 0;
        uint256 midpointRate = (behindMe * RAY) / sideTotal;
        if (midpointRate > RAY) {
            midpointRate = RAY;
        }
        uint256 delta = (lot.amount * rBase * midpointRate) / (RAY * RAY);
        // ruling 2b: mirror the settlement's presence proration so the view
        // matches what will materialise (S-10 view/materialised invariant).
        {
            uint256 wStart = ps.lastSnapshotEpoch * EPOCH_LENGTH;
            uint256 wEnd = currentEpoch * EPOCH_LENGTH;
            uint256 et = entryTime[postId][lot.side][lot.staker];
            if (wEnd > wStart && et > wStart) {
                uint256 present = et < wEnd ? wEnd - et : 0;
                delta = (delta * present) / (wEnd - wStart);
            }
        }
        if (aligned) {
            return lot.amount + delta;
        } else {
            uint256 loss = delta > lot.amount ? lot.amount : delta;
            return lot.amount - loss;
        }
    }

    // ------------------------------------------------------------
    // Internal: sMax management
    // ------------------------------------------------------------

    function _currentEpoch() internal view returns (uint256) {
        return block.timestamp / EPOCH_LENGTH;
    }

    function _updateSMax(uint256 postId, uint256 postTotal) internal {
        uint256 slot = type(uint256).max;
        for (uint256 i = 0; i < TRACKED_POSTS; i++) {
            if (topPosts[i].postId == postId && topPosts[i].total > 0) {
                slot = i;
                break;
            }
        }
        if (slot != type(uint256).max) {
            topPosts[slot].total = postTotal;
            while (slot > 0 && topPosts[slot].total > topPosts[slot - 1].total) {
                TopPost memory tmp = topPosts[slot];
                topPosts[slot] = topPosts[slot - 1];
                topPosts[slot - 1] = tmp;
                slot--;
            }
            while (slot < TRACKED_POSTS - 1 && topPosts[slot].total < topPosts[slot + 1].total) {
                TopPost memory tmp = topPosts[slot];
                topPosts[slot] = topPosts[slot + 1];
                topPosts[slot + 1] = tmp;
                slot++;
            }
        } else {
            for (uint256 i = 0; i < TRACKED_POSTS; i++) {
                if (postTotal > topPosts[i].total) {
                    for (uint256 j = TRACKED_POSTS - 1; j > i; j--) {
                        topPosts[j] = topPosts[j - 1];
                    }
                    topPosts[i] = TopPost(postId, postTotal);
                    break;
                }
            }
        }
        for (uint256 i = 0; i < TRACKED_POSTS; i++) {
            if (topPosts[i].total == 0) {
                topPosts[i] = TopPost(0, 0);
            }
        }
        uint256 leaderTotal = topPosts[0].total;
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
            sMaxPostId = topPosts[0].postId;
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
        _maybeSnapshot(postId, _currentEpoch());
        PostState storage ps = posts[postId];
        uint256 total = settledTotal[postId]; // ruling 3b: settled, not live
        _updateSMax(postId, total);
        emit SMaxRefreshed(postId, total, sMax);
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
        uint256 decayed = sMax;
        for (uint256 i = 0; i < elapsed; i++) {
            decayed = (decayed * sMaxDecayRateRay) / RAY;
            if (decayed == 0) {
                break;
            }
        }
        sMax = decayed;
        sMaxLastUpdatedEpoch = currentEpoch;
        return decayed;
    }

    function rescanSMax(uint256[] calldata postIds) external onlyGovernance {
        for (uint256 i = 0; i < TRACKED_POSTS; i++) {
            topPosts[i] = TopPost(0, 0);
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

    /// @dev Returns the top 3 of the TRACKED_POSTS-slot tracker (view kept at
    ///      three pairs for ABI stability across the widening — patch_prC_rulings).
    function getTopPosts()
        external
        view
        returns (uint256 p0, uint256 t0, uint256 p1, uint256 t1, uint256 p2, uint256 t2)
    {
        return (
            topPosts[0].postId,
            topPosts[0].total,
            topPosts[1].postId,
            topPosts[1].total,
            topPosts[2].postId,
            topPosts[2].total
        );
    }

    function _projectSMaxDecay(uint256 currentEpoch) internal view returns (uint256) {
        if (sMax == 0 || currentEpoch <= sMaxLastUpdatedEpoch) {
            return sMax;
        }
        uint256 elapsed = currentEpoch - sMaxLastUpdatedEpoch;
        if (elapsed > sMaxDecayMaxEpochs) {
            elapsed = sMaxDecayMaxEpochs;
        }
        uint256 decayed = sMax;
        for (uint256 i = 0; i < elapsed; i++) {
            decayed = (decayed * sMaxDecayRateRay) / RAY;
            if (decayed == 0) {
                break;
            }
        }
        uint256 leader = topPosts[0].total;
        return decayed > leader ? decayed : leader;
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
    function _bucketAdd(PostState storage ps, SideQueue storage q, uint8 side, address user, uint256 amount) internal {
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
            _bucketAdd(ps, q, side, vStaker, vAmount);
            emit LotDemoted(postId, side, vStaker, vAmount);
        }
        // shift survivors [sIdx+1..end) left by one, fixing their lot indices
        uint256 last = q.lots.length - 1;
        for (uint256 i = sIdx; i < last; i++) {
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
        if (idx != 0) {
            if (q.lots[idx - 1].amount == 0) {
                // S-02 FIX v2: remove the ghost from the array (shift-compact,
                // preserving arrival order) before re-entering, so one address can
                // never hold both a ghost entry and a live entry.
                uint256 gIdx = idx - 1;
                uint256 lastG = q.lots.length - 1;
                for (uint256 i = gIdx; i < lastG; i++) {
                    q.lots[i] = q.lots[i + 1];
                    _setLotIndex(ps, q.lots[i].staker, side, i + 1);
                }
                q.lots.pop();
                _setLotIndex(ps, user, side, 0);

                if (q.lots.length < MAX_RANKED_LOTS) {
                    _pushRankedLot(ps, q, side, user, amount);
                } else {
                    uint256 sIdxG = _smallestRankedIndex(q);
                    if (amount > q.lots[sIdxG].amount) {
                        _demoteRankedToBucket(postId, ps, q, side, sIdxG);
                        _pushRankedLot(ps, q, side, user, amount);
                    } else {
                        _bucketAdd(ps, q, side, user, amount);
                    }
                }
            } else {
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
            }
        } else if (_getBucketShares(ps, user, side) != 0) {
            _bucketAdd(ps, q, side, user, amount); // existing bucket member (may promote via _rebalance)
        } else if (q.lots.length < MAX_RANKED_LOTS) {
            _pushRankedLot(ps, q, side, user, amount); // new ranked lot
        } else {
            uint256 sIdx = _smallestRankedIndex(q);
            if (amount > q.lots[sIdx].amount) {
                _demoteRankedToBucket(postId, ps, q, side, sIdx); // evict smallest, append new at tail
                _pushRankedLot(ps, q, side, user, amount);
            } else {
                _bucketAdd(ps, q, side, user, amount); // too small for a slot -> bucket
            }
        }
        _rebalance(postId, ps, q, side); // patch_h1b_promotion: keep ranked = the C largest
        _recomputeWeightedPositions(postId, side, q);
        _recomputeSideTotal(q); // exact side total (ranked + bucketLive)
        _updateSMax(postId, settledTotal[postId]); // ruling 3b: settled, not live
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
    }

    /// @dev Project the bucket's live value forward one settlement at `rBase`
    ///      using the blended tail-midpoint rate. Mirrors _projectSideTotal.
    function _projectBucket(SideQueue storage q, bool aligned, uint256 rBase) internal view returns (uint256) {
        uint256 live = _bucketLive(q);
        if (live == 0 || rBase == 0) {
            return live;
        }
        uint256 T = q.total;
        if (T == 0) {
            return live;
        }
        uint256 rankedTotal = T - live;
        uint256 wPosB = rankedTotal + live / 2;
        uint256 behind = wPosB < T ? T - wPosB : 0;
        // Ray-math ordering: single multiply-first truncation, mirroring the
        // ranked-lot delta = amount*rBase*midpointRate/(RAY*RAY). behind <= T so
        // gRay <= rBase. patch_prC_rulings S-05: rBase is NOT bounded by RAY —
        // rMax scales with epochsElapsed (annualized rate x elapsed window), so
        // under dormancy rBase can exceed RAY (proven at deploy rates from ~530
        // elapsed epochs, and far sooner at the 5e18 policy cap). The gRay>=RAY
        // wipe branch below is therefore LIVE, not dead: it floors a losing
        // bucket at total loss, which is the correct bound.
        uint256 gRay = (rBase * behind) / T;
        // patch_prC_rulings S-01/V.8: project through the INDEX with the same
        // operations and floor as _settleBucket, so view == materialized to the
        // wei even in the wipe/floor regime (the old live-based formula had a
        // different truncation order).
        uint256 ix = _bucketIndex(q);
        uint256 newIx;
        if (aligned) {
            newIx = (ix * (RAY + gRay)) / RAY;
        } else {
            uint256 factor = gRay >= RAY ? 0 : RAY - gRay;
            newIx = (ix * factor) / RAY;
        }
        if (newIx == 0) {
            newIx = 1;
        }
        return (q.bucketScaledTotal * newIx) / RAY;
    }

    /// @dev Settle the bucket in place (one epoch) via a single index rebase.
    ///      Returns minted/burned for the bucket slab. O(1).
    function _settleBucket(SideQueue storage q, bool aligned, uint256 rBase)
        internal
        returns (uint256 minted, uint256 burned)
    {
        uint256 live = _bucketLive(q);
        if (q.bucketScaledTotal == 0 || live == 0 || rBase == 0) {
            return (0, 0);
        }
        uint256 T = q.total;
        if (T == 0) {
            return (0, 0);
        }
        uint256 rankedTotal = T - live;
        uint256 wPosB = rankedTotal + live / 2;
        uint256 behind = wPosB < T ? T - wPosB : 0;
        // Ray-math ordering: single multiply-first truncation, mirroring the
        // ranked-lot delta = amount*rBase*midpointRate/(RAY*RAY). behind <= T so
        // gRay <= rBase. patch_prC_rulings S-05: rBase is NOT bounded by RAY —
        // rMax scales with epochsElapsed (annualized rate x elapsed window), so
        // under dormancy rBase can exceed RAY (proven at deploy rates from ~530
        // elapsed epochs, and far sooner at the 5e18 policy cap). The gRay>=RAY
        // wipe branch below is therefore LIVE, not dead: it floors a losing
        // bucket at total loss, which is the correct bound.
        uint256 gRay = (rBase * behind) / T;
        uint256 ix = _bucketIndex(q);
        uint256 newIx;
        if (aligned) {
            newIx = (ix * (RAY + gRay)) / RAY;
        } else {
            uint256 factor = gRay >= RAY ? 0 : RAY - gRay;
            newIx = (ix * factor) / RAY;
        }
        // patch_prC_rulings S-01: floor at 1 wei. A fully-wiped bucket is
        // dust-dead (live ~ scaled/RAY), exits still work (full-exit branch,
        // no division hazard), and the stored value can never collide with
        // the 0 == uninitialized state — the root cause of the resurrection.
        if (newIx == 0) {
            newIx = 1;
        }
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

    uint256[495] private __gap; // 499 -> 498 (postRegistry) -> 495 (posOffset, entryTime, settledTotal)
}

/// @dev Minimal read surface the engine needs from PostRegistry (H1).
interface IPostRegistryIds {
    function nextPostId() external view returns (uint256);
}
