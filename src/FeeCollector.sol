// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FeeCollector — the relay's fee spender (patch_fee_collector)
/// @notice The relay charges its gas-indexed fee in VSP AFTER a user's gasless action has confirmed
///         (app/fee_collector.py). Until now the user's standing fee allowance named the relay's own
///         wallet as spender, so wallets showed a "spending cap" to a plain address and flagged it as
///         risky, and the only bound on a compromised relay key was that allowance (100 VSP per user,
///         all at once). This contract is the spender instead:
///
///           * users permit THIS verified contract, not an EOA;
///           * only registered collectors (the relay wallets) can call `collect`, and only while not paused;
///           * every collection is bounded on chain — at most `maxFeePerCollect` per call and
///             `maxPerUserPerDay` per user per UTC day — so a stolen relay key can take at most the daily
///             cap from each user who has an allowance, not the whole allowance;
///           * fees go straight from the user to `treasury`; the contract never holds funds;
///           * the Guardian can pause it instantly; only governance (the TimelockController, 48 h) can
///             unpause, change limits, the treasury or the collector set.
///
///         Not upgradeable: it has no state worth preserving across versions (the day windows are
///         ephemeral), and a replacement is a new address users permit at their next action. No ERC-2771:
///         collectors are keys, not users.
contract FeeCollector {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;

    address public governance;
    address public pendingGovernance;
    address public guardian;
    address public treasury;
    mapping(address => bool) public isCollector;

    /// @notice Per-call ceiling (wei of VSP). Mirrors the relay's RELAY_FEE_CAP_VSP on chain.
    uint256 public maxFeePerCollect;
    /// @notice Per-user ceiling per UTC day (wei of VSP).
    uint256 public maxPerUserPerDay;

    bool public paused;

    struct Window {
        uint64 day; // block.timestamp / 1 days
        uint192 spent; // collected from this user within `day`
    }

    mapping(address => Window) private _window;

    event FeeCollected(address indexed user, uint256 amount, bytes32 indexed ref, address indexed collector);
    event CollectorSet(address indexed collector, bool allowed);
    event TreasurySet(address indexed treasury);
    event LimitsSet(uint256 maxFeePerCollect, uint256 maxPerUserPerDay);
    event GuardianSet(address indexed guardian);
    event PendingGovernanceSet(address indexed pending);
    event GovernanceSet(address indexed governance);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    error NotGovernance();
    error NotPendingGovernance();
    error NotGuardian();
    error NotCollector();
    error ZeroAddress();
    error ZeroAmount();
    error WhenPaused();
    error FeeAboveCap(uint256 amount, uint256 cap);
    error DailyCapExceeded(address user, uint256 wouldBe, uint256 cap);
    error BadLimits();

    modifier onlyGovernance() {
        if (msg.sender != governance) {
            revert NotGovernance();
        }
        _;
    }

    modifier onlyCollector() {
        if (!isCollector[msg.sender]) {
            revert NotCollector();
        }
        _;
    }

    /// @param token_ the VSP token
    /// @param governance_ the TimelockController
    /// @param guardian_ the Guardian Safe (pause only)
    /// @param treasury_ where fees go (the Cold Safe)
    /// @param collector_ the first collector (the relay wallet); more via setCollector
    /// @param maxFeePerCollect_ per-call ceiling, wei
    /// @param maxPerUserPerDay_ per-user-per-day ceiling, wei (>= maxFeePerCollect_)
    constructor(
        address token_,
        address governance_,
        address guardian_,
        address treasury_,
        address collector_,
        uint256 maxFeePerCollect_,
        uint256 maxPerUserPerDay_
    ) {
        if (
            token_ == address(0) || governance_ == address(0) || guardian_ == address(0) || treasury_ == address(0)
                || collector_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (maxFeePerCollect_ == 0 || maxPerUserPerDay_ < maxFeePerCollect_) {
            revert BadLimits();
        }
        token = IERC20(token_);
        governance = governance_;
        guardian = guardian_;
        treasury = treasury_;
        isCollector[collector_] = true;
        maxFeePerCollect = maxFeePerCollect_;
        maxPerUserPerDay = maxPerUserPerDay_;
        emit GovernanceSet(governance_);
        emit GuardianSet(guardian_);
        emit TreasurySet(treasury_);
        emit CollectorSet(collector_, true);
        emit LimitsSet(maxFeePerCollect_, maxPerUserPerDay_);
    }

    // ── collection ───────────────────────────────────────────────────────────────────────────────

    /// @notice Pull `amount` of VSP from `user` to the treasury. `ref` ties the fee to the action it
    ///         pays for (the relayed transaction hash); it is indexed for the app and the ledger.
    function collect(address user, uint256 amount, bytes32 ref) external onlyCollector {
        if (paused) {
            revert WhenPaused();
        }
        if (user == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        if (amount > maxFeePerCollect) {
            revert FeeAboveCap(amount, maxFeePerCollect);
        }

        uint64 today = uint64(block.timestamp / 1 days);
        Window storage w = _window[user];
        uint256 spent = w.day == today ? uint256(w.spent) : 0;
        uint256 wouldBe = spent + amount;
        if (wouldBe > maxPerUserPerDay) {
            revert DailyCapExceeded(user, wouldBe, maxPerUserPerDay);
        }
        w.day = today;
        w.spent = uint192(wouldBe);

        token.safeTransferFrom(user, treasury, amount);
        emit FeeCollected(user, amount, ref, msg.sender);
    }

    /// @notice What `collect` could still take from `user` today, ignoring the allowance and balance.
    function remainingToday(address user) external view returns (uint256) {
        Window storage w = _window[user];
        uint256 spent = w.day == uint64(block.timestamp / 1 days) ? uint256(w.spent) : 0;
        return spent >= maxPerUserPerDay ? 0 : maxPerUserPerDay - spent;
    }

    /// @notice The user's standing allowance to this collector.
    function allowanceOf(address user) external view returns (uint256) {
        return token.allowance(user, address(this));
    }

    // ── pause (guardian or governance pauses; only governance resumes) ───────────────────────────

    function pause() external {
        if (msg.sender != guardian && msg.sender != governance) {
            revert NotGuardian();
        }
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyGovernance {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ── governance ──────────────────────────────────────────────────────────────────────────────

    function setCollector(address collector, bool allowed) external onlyGovernance {
        if (collector == address(0)) {
            revert ZeroAddress();
        }
        isCollector[collector] = allowed;
        emit CollectorSet(collector, allowed);
    }

    function setTreasury(address treasury_) external onlyGovernance {
        if (treasury_ == address(0)) {
            revert ZeroAddress();
        }
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setLimits(uint256 maxFeePerCollect_, uint256 maxPerUserPerDay_) external onlyGovernance {
        if (maxFeePerCollect_ == 0 || maxPerUserPerDay_ < maxFeePerCollect_) {
            revert BadLimits();
        }
        maxFeePerCollect = maxFeePerCollect_;
        maxPerUserPerDay = maxPerUserPerDay_;
        emit LimitsSet(maxFeePerCollect_, maxPerUserPerDay_);
    }

    function setGuardian(address guardian_) external onlyGovernance {
        if (guardian_ == address(0)) {
            revert ZeroAddress();
        }
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    /// @dev Two-step, as in GovernedUpgradeable: the new governance must accept.
    function transferGovernance(address pending) external onlyGovernance {
        if (pending == address(0)) {
            revert ZeroAddress();
        }
        pendingGovernance = pending;
        emit PendingGovernanceSet(pending);
    }

    function acceptGovernance() external {
        if (msg.sender != pendingGovernance) {
            revert NotPendingGovernance();
        }
        governance = msg.sender;
        pendingGovernance = address(0);
        emit GovernanceSet(msg.sender);
    }

    /// @notice Tokens sent here by mistake (the contract never holds fees) can be moved by governance.
    function sweep(address erc20, address to, uint256 amount) external onlyGovernance {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        IERC20(erc20).safeTransfer(to, amount);
    }
}
