// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";

/// @title GovernedUpgradeable
/// @notice Base contract for all upgradeable protocol contracts.
///         Provides UUPS upgrade authorization gated by governance,
///         and ERC-2771 trusted forwarder support so meta-transactions
///         resolve _msgSender() to the real end-user, not the relayer.
///
///         In OZ v5.5, ERC2771ContextUpgradeable stores the trusted forwarder
///         as an immutable set in the constructor (not via initializer).
///         With UUPS proxies this works because immutables are embedded in
///         the implementation bytecode that the proxy delegatecalls to.
abstract contract GovernedUpgradeable is Initializable, UUPSUpgradeable, ERC2771ContextUpgradeable {
    address public governance;
    address public pendingGovernance;

    error NotGovernance();
    error NotPendingGovernance();
    error ZeroAddress();

    event GovernanceSet(address indexed governance);
    event PendingGovernanceSet(address indexed pending);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder_) ERC2771ContextUpgradeable(trustedForwarder_) {
        _disableInitializers();
    }

    function __GovernedUpgradeable_init(address governance_) internal onlyInitializing {
        if (governance_ == address(0)) {
            revert ZeroAddress();
        }
        governance = governance_;
        emit GovernanceSet(governance_);
    }

    modifier onlyGovernance() {
        if (_msgSender() != governance) {
            revert NotGovernance();
        }
        _;
    }

    function _authorizeUpgrade(address) internal override onlyGovernance {}

    // ----- Two-step governance transfer -----

    /// @notice Propose a new governance address. Only callable by current governance.
    ///         The proposed address must call acceptGovernance() to complete the transfer.
    ///         Setting pending to address(0) cancels any outstanding proposal.
    function proposeGovernance(address newGovernance) external onlyGovernance {
        pendingGovernance = newGovernance;
        emit PendingGovernanceSet(newGovernance);
    }

    /// @notice Accept proposed governance role. Only callable by the address
    ///         that was set as pendingGovernance via proposeGovernance().
    function acceptGovernance() external {
        if (_msgSender() != pendingGovernance) {
            revert NotPendingGovernance();
        }
        // patch_prC_rulings S-13: the old ZeroAddress branch here was
        // unreachable — when pendingGovernance is address(0), no real caller
        // can equal it, so the NotPendingGovernance check above always fires
        // first. Removed as dead code; behavior is identical.
        governance = pendingGovernance;
        pendingGovernance = address(0);
        emit GovernanceSet(governance);
    }

    // ----- Solidity diamond override resolution -----

    function _msgSender() internal view virtual override returns (address) {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData() internal view virtual override returns (bytes calldata) {
        return ERC2771ContextUpgradeable._msgData();
    }

    function _contextSuffixLength() internal view virtual override returns (uint256) {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }

    uint256[100] private __gap;
}
