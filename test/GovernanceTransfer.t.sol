// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/StakeEngine.sol";
import "../src/governance/GovernedUpgradeable.sol";

import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// @title GovernanceTransferTest
/// @notice Tests for the two-step proposeGovernance / acceptGovernance
///         flow added to GovernedUpgradeable. Uses StakeEngine as a
///         representative inheriting contract — coverage applies to
///         every other inheriting proxy too (PostRegistry, LinkGraph,
///         ScoreEngine, ProtocolViews) since the logic lives in the
///         shared base.
contract GovernanceTransferTest is Test {
    MockVSP token;
    StakeEngine engine;
    MockProtocolPolicy policy;

    address gov = address(this); // initial governance (deploy-time)
    address newGov = address(0xC0FFEE); // intended next governance (e.g. timelock)
    address attacker = address(0xBAD);
    address typoAddr = address(0xDEAD); // wrong-but-valid address used for typo test

    // Mirror the GovernedUpgradeable events so we can assert on them.
    event GovernanceSet(address indexed governance);
    event PendingGovernanceSet(address indexed pending);

    function setUp() public {
        token = new MockVSP();
        policy = new MockProtocolPolicy(0);

        engine = StakeEngine(
            address(
                new ERC1967Proxy(
                    address(new StakeEngine(address(0))),
                    abi.encodeCall(
                        StakeEngine.initialize,
                        (
                            gov, // governance — i.e. this test contract
                            address(token),
                            address(policy)
                        )
                    )
                )
            )
        );

        assertEq(engine.governance(), gov, "initial governance should be this");
        assertEq(engine.pendingGovernance(), address(0), "no pending at start");
    }

    // ─────────────────────────────────────────────────────────────
    // 1. Happy path
    // ─────────────────────────────────────────────────────────────
    function test_HappyPath_ProposeThenAccept() public {
        engine.proposeGovernance(newGov);
        assertEq(engine.pendingGovernance(), newGov, "pending should be set");
        assertEq(engine.governance(), gov, "governance must NOT change on propose alone");

        vm.prank(newGov);
        engine.acceptGovernance();
        assertEq(engine.governance(), newGov, "governance should be transferred");
        assertEq(engine.pendingGovernance(), address(0), "pending cleared after accept");
    }

    // ─────────────────────────────────────────────────────────────
    // 2. proposeGovernance reverts when caller is not current governance
    // ─────────────────────────────────────────────────────────────
    function test_RevertWhen_NonGovernanceProposes() public {
        vm.prank(attacker);
        vm.expectRevert(GovernedUpgradeable.NotGovernance.selector);
        engine.proposeGovernance(newGov);
    }

    // ─────────────────────────────────────────────────────────────
    // 3. acceptGovernance reverts when caller is not the proposed address
    // ─────────────────────────────────────────────────────────────
    function test_RevertWhen_WrongAddressAccepts() public {
        engine.proposeGovernance(newGov);

        vm.prank(attacker);
        vm.expectRevert(GovernedUpgradeable.NotPendingGovernance.selector);
        engine.acceptGovernance();

        // State is unchanged
        assertEq(engine.governance(), gov);
        assertEq(engine.pendingGovernance(), newGov);
    }

    // ─────────────────────────────────────────────────────────────
    // 4. acceptGovernance reverts when no proposal pending
    // ─────────────────────────────────────────────────────────────
    function test_RevertWhen_AcceptWithNoPending() public {
        // No proposeGovernance call — pendingGovernance is address(0)
        vm.prank(newGov);
        vm.expectRevert(GovernedUpgradeable.NotPendingGovernance.selector);
        engine.acceptGovernance();
    }

    // ─────────────────────────────────────────────────────────────
    // 5. proposeGovernance(address(0)) cancels an outstanding proposal
    //
    // Documented behavior — pinned by this test so a future "cleanup"
    // refactor can't silently change the semantic. After cancellation,
    // the previously-proposed address can no longer accept.
    // ─────────────────────────────────────────────────────────────
    function test_ProposeZeroAddressCancelsPending() public {
        engine.proposeGovernance(newGov);
        assertEq(engine.pendingGovernance(), newGov);

        // Cancel by proposing the zero address.
        engine.proposeGovernance(address(0));
        assertEq(engine.pendingGovernance(), address(0), "pending should be cleared");

        // newGov can no longer accept.
        vm.prank(newGov);
        vm.expectRevert(GovernedUpgradeable.NotPendingGovernance.selector);
        engine.acceptGovernance();

        assertEq(engine.governance(), gov, "governance unchanged after cancellation");
    }

    // ─────────────────────────────────────────────────────────────
    // 6. After transfer: old governance can no longer call onlyGovernance
    // ─────────────────────────────────────────────────────────────
    function test_OldGovernanceCannotCallAfterTransfer() public {
        engine.proposeGovernance(newGov);
        vm.prank(newGov);
        engine.acceptGovernance();

        // 'this' (gov) is no longer governance. setSnapshotPeriod must revert.
        vm.expectRevert(GovernedUpgradeable.NotGovernance.selector);
        engine.setSnapshotPeriod(1 days);
    }

    // ─────────────────────────────────────────────────────────────
    // 7. After transfer: new governance CAN call onlyGovernance
    // ─────────────────────────────────────────────────────────────
    function test_NewGovernanceCanCallAfterTransfer() public {
        engine.proposeGovernance(newGov);
        vm.prank(newGov);
        engine.acceptGovernance();

        uint256 newPeriod = 6 hours; // patch_sec_jit_window: must be <= MAX_SNAPSHOT_PERIOD
        vm.prank(newGov);
        engine.setSnapshotPeriod(newPeriod);
        assertEq(engine.snapshotPeriod(), newPeriod, "newGov should be able to set period");
    }

    // ─────────────────────────────────────────────────────────────
    // 8. proposeGovernance can be called twice — replaces pending
    // ─────────────────────────────────────────────────────────────
    function test_SecondProposeReplacesFirst() public {
        engine.proposeGovernance(typoAddr);
        assertEq(engine.pendingGovernance(), typoAddr);

        // Replace with the correct address.
        engine.proposeGovernance(newGov);
        assertEq(engine.pendingGovernance(), newGov);

        // typoAddr (the original wrong proposal) must NOT be able to accept.
        vm.prank(typoAddr);
        vm.expectRevert(GovernedUpgradeable.NotPendingGovernance.selector);
        engine.acceptGovernance();

        // newGov still can.
        vm.prank(newGov);
        engine.acceptGovernance();
        assertEq(engine.governance(), newGov);
    }

    // ─────────────────────────────────────────────────────────────
    // 9. Two-step protects against typo (composite scenario)
    //
    // Verifies the canonical "I typo'd the address; how do I recover?"
    // workflow. The original governance proposes a wrong address, then
    // proposes the correct one before the wrong one accepts. The wrong
    // address is locked out; the correct one accepts cleanly.
    // ─────────────────────────────────────────────────────────────
    function test_TypoRecoveryFlow() public {
        // Step 1: governance accidentally proposes the wrong address.
        engine.proposeGovernance(typoAddr);

        // Step 2: governance notices and overwrites with the correct address
        //         BEFORE the wrong address has a chance to call accept.
        engine.proposeGovernance(newGov);

        // Step 3: typo address is locked out.
        vm.prank(typoAddr);
        vm.expectRevert(GovernedUpgradeable.NotPendingGovernance.selector);
        engine.acceptGovernance();

        // Step 4: correct address accepts cleanly.
        vm.prank(newGov);
        engine.acceptGovernance();
        assertEq(engine.governance(), newGov);

        // Step 5: original governance is fully out of the picture.
        vm.expectRevert(GovernedUpgradeable.NotGovernance.selector);
        engine.setSnapshotPeriod(1 days);
    }

    // ─────────────────────────────────────────────────────────────
    // 10. Events emit on propose and accept
    // ─────────────────────────────────────────────────────────────
    function test_EmitsPendingGovernanceSetOnPropose() public {
        vm.expectEmit(true, false, false, false, address(engine));
        emit PendingGovernanceSet(newGov);
        engine.proposeGovernance(newGov);
    }

    function test_EmitsGovernanceSetOnAccept() public {
        engine.proposeGovernance(newGov);

        vm.expectEmit(true, false, false, false, address(engine));
        emit GovernanceSet(newGov);
        vm.prank(newGov);
        engine.acceptGovernance();
    }

    // ─────────────────────────────────────────────────────────────
    // Bonus: full timelock-style choreography
    //
    // Simulates the actual mainnet flow:
    //   - "deployer" is initial governance
    //   - "timelock" is the new owner (a contract address simulated by an EOA)
    //   - The timelock receives the proposal, then "executes" the accept.
    //
    // Just gives confidence that the same primitives compose into the
    // real-world deploy story.
    // ─────────────────────────────────────────────────────────────
    function test_TimelockStyleHandoffSimulation() public {
        address deployer = gov; // current governance
        address timelock = address(0x71E10C); // simulated timelock contract (any address works for this test)

        // Deployer proposes timelock as new governance.
        vm.prank(deployer);
        engine.proposeGovernance(timelock);

        // Timelock "executes" the accept (in production this is the
        // executor role in the timelock contract calling acceptGovernance
        // on this proxy).
        vm.prank(timelock);
        engine.acceptGovernance();

        assertEq(engine.governance(), timelock);
        assertEq(engine.pendingGovernance(), address(0));

        // From here on, every onlyGovernance call must be initiated by
        // the timelock (in production, scheduled by the Safe).
        vm.prank(timelock);
        engine.setSnapshotPeriod(6 hours); // patch_sec_jit_window: <= MAX_SNAPSHOT_PERIOD
        assertEq(engine.snapshotPeriod(), 6 hours);
    }
}
