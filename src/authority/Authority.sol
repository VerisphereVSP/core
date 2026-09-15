// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Authority
/// @notice Role-based access control for VSPToken mint/burn privileges.
///         Uses two-step ownership transfer to prevent accidental loss of control.
///         In dev: owner is deployer EOA. In prod: owner is a TimelockController
///         controlled by a multisig.
contract Authority {
    address public owner;
    address public pendingOwner;

    mapping(address => bool) public isMinter;
    mapping(address => bool) public isBurner;

    event OwnerChanged(address indexed newOwner);
    event PendingOwnerSet(address indexed proposed);
    event MinterSet(address indexed minter, bool allowed);
    event BurnerSet(address indexed burner, bool allowed);

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();

    constructor(address _owner) {
        if (_owner == address(0)) {
            revert ZeroAddress();
        }
        owner = _owner;

        // Bootstrap privileges
        isMinter[_owner] = true;
        isBurner[_owner] = true;

        emit MinterSet(_owner, true);
        emit BurnerSet(_owner, true);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }

    // ------------------------------------------------------------
    // Two-step ownership transfer
    // ------------------------------------------------------------

    /// @notice Propose a new owner. The new owner must call acceptOwner() to complete.
    function proposeOwner(address proposed) external onlyOwner {
        if (proposed == address(0)) {
            revert ZeroAddress();
        }
        pendingOwner = proposed;
        emit PendingOwnerSet(proposed);
    }

    /// @notice Accept ownership. Only callable by the pending owner.
    function acceptOwner() external {
        if (msg.sender != pendingOwner) {
            revert NotPendingOwner();
        }
        address oldOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        // Housekeeping sweep 2026-09-13 (security review Low): the old owner's
        // operational roles do not survive the handoff. Deploy.s.sol already
        // revoked the deployer explicitly; the contract now guarantees it.
        if (isMinter[oldOwner]) {
            isMinter[oldOwner] = false;
            emit MinterSet(oldOwner, false);
        }
        if (isBurner[oldOwner]) {
            isBurner[oldOwner] = false;
            emit BurnerSet(oldOwner, false);
        }
        emit OwnerChanged(msg.sender);
    }

    // ------------------------------------------------------------
    // Role management
    // ------------------------------------------------------------

    function setMinter(address who, bool allowed) external onlyOwner {
        isMinter[who] = allowed;
        emit MinterSet(who, allowed);
    }

    function setBurner(address who, bool allowed) external onlyOwner {
        isBurner[who] = allowed;
        emit BurnerSet(who, allowed);
    }
}
