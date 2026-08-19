// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Minimal interface the emitter needs: totalSupply (for the cap terminating
///      check) + mint. VSPToken's own IVSPToken interface declares mint/burn/
///      burnFrom but NOT totalSupply, so we declare a local interface that
///      includes both. totalSupply is the standard ERC20 selector; VSPToken is an
///      ERC20 and exposes it.
interface IEmitterToken {
    function totalSupply() external view returns (uint256);
    function mint(address to, uint256 amount) external;
}

/// ############################  SUPERSEDED — NOT DEPLOYED  #################
/// # 2026-07-29: the one-shot genesis supply model (patch_oneshot_genesis)  #
/// # supersedes scheduled emission before this contract ever deployed.      #
/// # Retained in-tree as the reference implementation of the               #
/// # price-independent schedule design (see patches/log/oneshot-genesis.md #
/// # and corporate/legal-memo-2026-07.md C1). Do not wire into Deploy.     #
/// ###########################################################################
/// @title ScheduledEmitter
/// @notice Immutable, nudge-driven, PRICE-INDEPENDENT VSP issuance. Replaces the
///         treasury worker's discretionary MM-funding mint with a fixed on-chain
///         schedule. A worker (or anyone, if permissionless) "nudges" emit(); the
///         contract mints AMOUNT to RECIPIENT at most once per INTERVAL, until
///         total supply reaches CAP, then latches finished forever.
///
/// @dev DESIGN INVARIANT (legal + safety): every input the contract reads to
///      decide whether/how much to emit is PRICE-INDEPENDENT — meaningful even if
///      VSP had no market price. The only inputs are:
///        - block.timestamp vs INTERVAL  (time)
///        - IVSPToken.totalSupply() vs CAP  (a terminating/cap condition ONLY)
///      Supply is read ONLY as a terminating condition ("are we done?"), NEVER as
///      a demand/price signal ("does the market need more?"). In an AMM,
///      supply-responsive emission IS price-responsive emission (reserve ratio
///      links them) — which is issuer price-management. This contract must never
///      gain any input that would read differently if VSP had no price.
///
///      Non-discretion (supply governance option "A"): this emitter and the
///      protocol-bound StakeEngine are the only minters. No standing EOA can mint.
///      The immutables below cannot be changed; the schedule is fixed at deploy.
///
///      Worker unreliability is SAFE: a missed nudge only makes an emission LATE,
///      never early, never wrong-sized. Correctness is fully on-chain; only
///      liveness depends on the nudge.
contract ScheduledEmitter {
    /// @notice The VSP token this emitter mints. Immutable.
    IEmitterToken public immutable TOKEN;
    /// @notice Where emitted VSP is minted to (treasury, or a pool/seed address).
    address public immutable RECIPIENT;
    /// @notice Minimum seconds between emissions.
    uint256 public immutable INTERVAL;
    /// @notice VSP minted per emission (in wei).
    uint256 public immutable AMOUNT;
    /// @notice Total-supply ceiling. Emission stops permanently once totalSupply
    ///         reaches CAP. Set very high / unreachable for effectively-uncapped
    ///         ongoing emission; set CAP == AMOUNT for a single premint tranche.
    ///         A terminating condition, NOT a discretionary control — immutable.
    uint256 public immutable CAP;
    /// @notice If true, emit() is caller-gated to WORKER; if false, permissionless
    ///         (anyone may nudge — the contract gates on time+cap regardless).
    bool public immutable WORKER_ONLY;
    /// @notice Authorized nudger when WORKER_ONLY is true. address(0) otherwise.
    address public immutable WORKER;

    /// @notice Timestamp of the last successful emission (0 until first emit).
    uint256 public lastEmission;
    /// @notice Latches true once CAP is reached; emit() then always reverts.
    bool public finished;

    /// @notice Emitted on every successful emission.
    event Emitted(uint256 amount, uint256 at, uint256 totalSupplyAfter);
    /// @notice Emitted once when CAP is reached and the emitter latches finished.
    event Finished(uint256 at, uint256 totalSupplyFinal);

    error EmitterFinished();
    error TooSoon(uint256 nowTs, uint256 earliest);
    error CapReached(uint256 supply, uint256 cap);
    error NotWorker();
    error ZeroToken();
    error ZeroRecipient();
    error ZeroAmount();
    error ZeroInterval();
    error CapBelowAmount();

    /// @param token_      VSP token (must be nonzero).
    /// @param recipient_  mint destination (must be nonzero).
    /// @param interval_   min seconds between emissions (must be > 0).
    /// @param amount_     VSP per emission (must be > 0).
    /// @param cap_        total-supply ceiling (must be >= amount_).
    /// @param workerOnly_ if true, only worker_ may nudge emit().
    /// @param worker_     authorized nudger (required nonzero iff workerOnly_).
    /// @param startAt_    lastEmission seed. Pass 0 to allow the first emission
    ///                    immediately; pass a future ts to delay the first window.
    constructor(
        address token_,
        address recipient_,
        uint256 interval_,
        uint256 amount_,
        uint256 cap_,
        bool workerOnly_,
        address worker_,
        uint256 startAt_
    ) {
        if (token_ == address(0)) {
            revert ZeroToken();
        }
        if (recipient_ == address(0)) {
            revert ZeroRecipient();
        }
        if (interval_ == 0) {
            revert ZeroInterval();
        }
        if (amount_ == 0) {
            revert ZeroAmount();
        }
        if (cap_ < amount_) {
            revert CapBelowAmount();
        }
        if (workerOnly_ && worker_ == address(0)) {
            revert NotWorker();
        }

        TOKEN = IEmitterToken(token_);
        RECIPIENT = recipient_;
        INTERVAL = interval_;
        AMOUNT = amount_;
        CAP = cap_;
        WORKER_ONLY = workerOnly_;
        WORKER = workerOnly_ ? worker_ : address(0);
        // startAt_ seeds lastEmission. With startAt_==0 the first emit() is allowed
        // as soon as block.timestamp >= INTERVAL (i.e. essentially immediately in
        // practice, since 0 + INTERVAL is far in the past). To delay the first
        // emission to time T, pass startAt_ = T - INTERVAL.
        lastEmission = startAt_;
    }

    /// @notice Nudge the schedule. Mints AMOUNT (or the final partial tranche) to
    ///         RECIPIENT iff INTERVAL has elapsed and CAP is not yet reached.
    ///         Reverts otherwise. Idempotent-safe to call as often as desired.
    /// @return minted the amount actually minted this call.
    function emit_() external returns (uint256 minted) {
        if (finished) {
            revert EmitterFinished();
        }
        if (WORKER_ONLY && msg.sender != WORKER) {
            revert NotWorker();
        }

        uint256 earliest = lastEmission + INTERVAL;
        if (block.timestamp < earliest) {
            revert TooSoon(block.timestamp, earliest);
        }

        uint256 supply = TOKEN.totalSupply();
        if (supply >= CAP) {
            // defensive: should have latched already, but never emit over cap
            finished = true;
            emit Finished(block.timestamp, supply);
            revert CapReached(supply, CAP);
        }

        // clamp the final tranche so total supply never exceeds CAP
        uint256 toMint = AMOUNT;
        unchecked {
            uint256 room = CAP - supply; // supply < CAP guaranteed above
            if (toMint > room) {
                toMint = room;
            }
        }

        TOKEN.mint(RECIPIENT, toMint);
        lastEmission = block.timestamp;
        minted = toMint;

        uint256 supplyAfter = TOKEN.totalSupply();
        emit Emitted(toMint, block.timestamp, supplyAfter);

        if (supplyAfter >= CAP) {
            finished = true;
            emit Finished(block.timestamp, supplyAfter);
        }
    }

    /// @notice View: is an emission currently due (time elapsed, not finished,
    ///         under cap)? Lets a worker/keeper cheaply decide whether to nudge.
    function emissionDue() external view returns (bool) {
        if (finished) {
            return false;
        }
        if (block.timestamp < lastEmission + INTERVAL) {
            return false;
        }
        return TOKEN.totalSupply() < CAP;
    }

    /// @notice View: earliest timestamp the next emission can occur.
    function nextEmissionTime() external view returns (uint256) {
        return lastEmission + INTERVAL;
    }
}
