// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// SCOPE COVERAGE — governance/GovernedUpgradeable.sol (row W)
///
/// The last scoped file that was marked reviewed on a read-only basis. Tested
/// through StakeEngine, which inherits it, because the base is abstract.
///
/// Targets, quoted from the source:
///   :49      _authorizeUpgrade gated onlyGovernance  <- the whole UUPS story
///   :56-59   proposeGovernance: no zero-check, comment says 0 = cancel
///   :63-73   acceptGovernance: two-step
///   :67-69   a ZeroAddress check that may be UNREACHABLE
///   :30-32   _disableInitializers on the implementation
///   :34-40   __GovernedUpgradeable_init rejects zero governance
contract ScopeGovernedUpgradeablePoC is Test {
    StakeEngine eng;
    StakeEngine impl;
    MockVSP vsp;
    MockProtocolPolicy policy;

    address governance = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.warp(86400 * 1000);
        vsp = new MockVSP();
        policy = new MockProtocolPolicy(0);
        impl = new StakeEngine(address(0));
        eng = StakeEngine(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(StakeEngine.initialize, (governance, address(vsp), address(policy)))
                )
            )
        );
    }

    // ── the UUPS gate: this is the one that matters ──────────────────

    /// A non-governance caller must NOT be able to upgrade the proxy.
    function test_GU_NonGovernanceCannotUpgrade() public {
        StakeEngine newImpl = new StakeEngine(address(0));

        vm.prank(alice);
        vm.expectRevert(); // NotGovernance
        eng.upgradeToAndCall(address(newImpl), "");

        vm.prank(bob);
        vm.expectRevert();
        eng.upgradeToAndCall(address(newImpl), "");
        emit log("upgrade correctly gated: two unprivileged callers rejected");
    }

    /// Governance CAN upgrade, and state survives.
    function test_GU_GovernanceCanUpgrade_StatePreserved() public {
        // put some state in first
        vsp.mint(alice, 100e18);
        vm.prank(alice);
        vsp.approve(address(eng), type(uint256).max);
        vm.prank(alice);
        eng.stake(1, 0, 100e18);
        assertEq(eng.getUserStake(alice, 1, 0), 100e18, "pre-upgrade stake missing");

        StakeEngine newImpl = new StakeEngine(address(0));
        eng.upgradeToAndCall(address(newImpl), "");

        assertEq(eng.getUserStake(alice, 1, 0), 100e18, "state lost across upgrade");
        assertEq(eng.governance(), governance, "governance lost across upgrade");
        emit log("governance upgrade succeeded, state and governance preserved");
    }

    /// After a governance handover, the OLD governance must lose upgrade rights.
    function test_GU_UpgradeRightsFollowGovernance() public {
        eng.proposeGovernance(alice);
        vm.prank(alice);
        eng.acceptGovernance();
        assertEq(eng.governance(), alice, "handover failed");

        StakeEngine newImpl = new StakeEngine(address(0));

        // old governance is now powerless
        vm.expectRevert();
        eng.upgradeToAndCall(address(newImpl), "");

        // new governance can
        vm.prank(alice);
        eng.upgradeToAndCall(address(newImpl), "");
        emit log("upgrade rights transferred with governance");
    }

    // ── two-step governance transfer ─────────────────────────────────

    function test_GU_TwoStepRequiresAccept() public {
        eng.proposeGovernance(alice);
        assertEq(eng.governance(), governance, "governance changed on propose alone");
        assertEq(eng.pendingGovernance(), alice, "pending not set");

        // a third party cannot accept
        vm.prank(bob);
        vm.expectRevert(); // NotPendingGovernance
        eng.acceptGovernance();
        assertEq(eng.governance(), governance, "governance hijacked by non-pending caller");

        vm.prank(alice);
        eng.acceptGovernance();
        assertEq(eng.governance(), alice, "accept did not transfer");
        assertEq(eng.pendingGovernance(), address(0), "pending not cleared");
    }

    /// Only current governance may propose.
    function test_GU_OnlyGovernanceCanPropose() public {
        vm.prank(alice);
        vm.expectRevert(); // NotGovernance
        eng.proposeGovernance(alice);
    }

    /// The source comment at :55 claims setting pending to address(0) CANCELS a
    /// proposal. Verify that is actually true.
    function test_GU_ProposeZeroCancelsProposal() public {
        eng.proposeGovernance(alice);
        assertEq(eng.pendingGovernance(), alice, "pending not set");

        eng.proposeGovernance(address(0)); // documented as "cancel"
        assertEq(eng.pendingGovernance(), address(0), "cancel did not clear pending");

        // the previously-proposed address must no longer be able to accept
        vm.prank(alice);
        vm.expectRevert();
        eng.acceptGovernance();
        emit log("proposeGovernance(0) cancels as documented");
    }

    /// Is the ZeroAddress check at :67-69 reachable? Reaching it needs
    /// _msgSender() == pendingGovernance == address(0), i.e. a call from
    /// address(0), which no normal transaction can do.
    function test_GU_ZeroAddressCheckIsUnreachable() public {
        assertEq(eng.pendingGovernance(), address(0), "precondition: pending is zero");

        // any real caller trips NotPendingGovernance first, never ZeroAddress
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotPendingGovernance()"));
        eng.acceptGovernance();

        // even governance itself
        vm.expectRevert(abi.encodeWithSignature("NotPendingGovernance()"));
        eng.acceptGovernance();

        emit log("ZeroAddress branch at GovernedUpgradeable:67-69 is dead code:");
        emit log("  NotPendingGovernance always fires first for any real sender");
    }

    // ── initializer hygiene ──────────────────────────────────────────

    /// The IMPLEMENTATION must not be initializable directly (constructor calls
    /// _disableInitializers). Otherwise an attacker could seize the impl.
    function test_GU_ImplementationCannotBeInitialized() public {
        vm.expectRevert(); // InvalidInitialization
        impl.initialize(alice, address(vsp), address(policy));
        emit log("implementation is locked: _disableInitializers holds");
    }

    /// The proxy must not be re-initializable.
    function test_GU_ProxyCannotBeReinitialized() public {
        vm.expectRevert(); // InvalidInitialization
        eng.initialize(alice, address(vsp), address(policy));
    }

    /// Zero governance must be rejected at init time.
    function test_GU_ZeroGovernanceRejectedAtInit() public {
        StakeEngine i2 = new StakeEngine(address(0));
        vm.expectRevert(); // ZeroAddress
        new ERC1967Proxy(
            address(i2), abi.encodeCall(StakeEngine.initialize, (address(0), address(vsp), address(policy)))
        );
        emit log("zero governance rejected at initialize");
    }

    /// Governance cannot be locked out by proposing an address that never accepts:
    /// current governance keeps full power throughout.
    function test_GU_DanglingProposalDoesNotLockOut() public {
        eng.proposeGovernance(alice); // alice never accepts

        // governance must still be able to act
        // NOTE: at HEAD 58971c0, MAX_SNAPSHOT_PERIOD == EPOCH_LENGTH == 1 day, so
        // setSnapshotPeriod(2 days) now reverts PeriodOutOfBounds. Use the boundary value
        // that is still valid, so the test proves governance retains power without
        // depending on the old 365-day cap.
        eng.setSnapshotPeriod(1 days);
        assertEq(eng.snapshotPeriod(), 1 days, "governance lost power while a proposal was pending");

        StakeEngine newImpl = new StakeEngine(address(0));
        eng.upgradeToAndCall(address(newImpl), "");
        emit log("dangling proposal does not disable current governance");
    }
}
