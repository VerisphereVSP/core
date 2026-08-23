// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StakeEngine} from "../src/StakeEngine.sol";
import {MockVSP} from "./mocks/MockVSP.sol";
import {MockProtocolPolicy} from "./mocks/MockProtocolPolicy.sol";

/// Regression suite for VSP-SEC-001 (external report, 2026-08-19):
/// "StakeLot.entryEpoch is stored but never read in accrual."
///
/// Mechanism: _forceSnapshot scales the interest rate by
/// `epochsElapsed = currentEpoch - lastSnapshotEpoch` and _applyEpoch hands that
/// rate to every lot present AT SETTLEMENT TIME, with no reference to when the
/// lot entered. _maybeSnapshot only fires once `snapshotPeriod` has elapsed, so
/// whenever snapshotPeriod > EPOCH_LENGTH there is a window during which the
/// snapshot is suppressed and the lot set can be mutated:
///
///   J1  a lot joining late in the window collects the WHOLE window's accrual
///   J2  a lot leaving before the window closes escapes the WHOLE window's decay
///
/// Fix under test (patch_sec_jit_window): MAX_SNAPSHOT_PERIOD == EPOCH_LENGTH,
/// so periodInEpochs is always 1 and every interaction settles all elapsed
/// epochs BEFORE mutating the lot set (stake() and withdraw() both call
/// _maybeSnapshot first). Both directions close.
///
/// NOTE on the alternative fix: prorating each lot by entryEpoch addresses J1
/// only, and cannot address it for the pooled tail bucket at all — _settleBucket
/// is an O(1) index rebase with no per-entry epochs. That is why the cap was
/// chosen over proration.
contract JitWindowRegressionTest is Test {
    StakeEngine engine;
    MockVSP vsp;
    MockProtocolPolicy policy;

    uint256 constant POST = 1;
    uint8 constant SUPPORT = 0;
    uint8 constant CHALLENGE = 1;
    uint256 constant STAKE = 1_000e18;

    address honest = makeAddr("honest");
    address jit = makeAddr("jit");
    address loser = makeAddr("loser");

    function setUp() public {
        vsp = new MockVSP();
        policy = new MockProtocolPolicy(0);
        engine = StakeEngine(
            address(
                new ERC1967Proxy(
                    address(new StakeEngine(address(0))),
                    abi.encodeCall(StakeEngine.initialize, (address(this), address(vsp), address(policy)))
                )
            )
        );

        address[3] memory actors = [honest, jit, loser];
        for (uint256 i = 0; i < actors.length; i++) {
            vsp.mint(actors[i], 1e36);
            vm.prank(actors[i]);
            vsp.approve(address(engine), type(uint256).max);
        }
        vm.warp(30 days); // land well past epoch 0
    }

    // ── The guard itself ───────────────────────────────────────────────

    /// The cap is what makes the window unreachable: with the period pinned to
    /// one epoch, _maybeSnapshot can never be suppressed across epochs.
    function test_maxSnapshotPeriod_is_one_epoch() public view {
        assertEq(engine.MAX_SNAPSHOT_PERIOD(), engine.EPOCH_LENGTH(), "cap must equal one epoch");
        assertLe(engine.snapshotPeriod(), engine.MAX_SNAPSHOT_PERIOD(), "live period within cap");
    }

    /// Governance cannot re-open the window. THIS is the regression that would
    /// have failed before the fix (setSnapshotPeriod(7 days) used to succeed).
    function test_governance_cannot_open_a_multi_epoch_window() public {
        vm.expectRevert(StakeEngine.PeriodOutOfBounds.selector);
        engine.setSnapshotPeriod(2 days);
        vm.expectRevert(StakeEngine.PeriodOutOfBounds.selector);
        engine.setSnapshotPeriod(7 days);
        vm.expectRevert(StakeEngine.PeriodOutOfBounds.selector);
        engine.setSnapshotPeriod(365 days);
        // sub-epoch periods remain settable (they already behave as one epoch)
        engine.setSnapshotPeriod(6 hours);
        assertEq(engine.snapshotPeriod(), 6 hours);
    }

    // ── J1: late joiner must not capture the window ────────────────────

    /// An honest staker holds a winning position for 7 epochs. A JIT staker
    /// joins in the 7th. Under the vulnerability the JIT lot collected ~the full
    /// 7-epoch rate (reported: 99.78%, ~6x its fair share). With the cap, the
    /// JIT staker's own stake() settles the elapsed epochs BEFORE its lot is
    /// added, so it earns nothing for time it was not present.
    function test_J1_lateJoiner_earns_nothing_for_the_elapsed_window() public {
        vm.prank(honest);
        engine.stake(POST, SUPPORT, STAKE);
        vm.prank(loser);
        engine.stake(POST, CHALLENGE, STAKE / 4); // make SUPPORT the winning side

        skip(7 days); // no interaction: accrual accumulates unsettled

        vm.prank(jit);
        engine.stake(POST, SUPPORT, STAKE); // settles first, then joins

        // settle once more so any pending epoch is materialised for both
        skip(1 days);
        vm.prank(loser);
        engine.stake(POST, CHALLENGE, 1e18);

        uint256 honestAmt = _amountOf(honest, SUPPORT);
        uint256 jitAmt = _amountOf(jit, SUPPORT);

        assertGt(honestAmt, STAKE, "honest staker should have accrued");
        // JIT was present for ~1 epoch vs honest's 8; its gain must be a small
        // fraction of honest's, not parity.
        uint256 honestGain = honestAmt - STAKE;
        uint256 jitGain = jitAmt > STAKE ? jitAmt - STAKE : 0;
        assertLt(jitGain * 2, honestGain, "JIT gain must be far below the long-held lot's");
    }

    // ── J2: early leaver must not dodge the decay ──────────────────────

    /// The mirror image. A losing lot tries to exit mid-window to escape the
    /// burn. With the cap, withdraw() settles the elapsed epochs first, so the
    /// loss is materialised before the exit.
    function test_J2_earlyLeaver_cannot_dodge_the_decay() public {
        vm.prank(honest);
        engine.stake(POST, SUPPORT, STAKE); // winning side
        vm.prank(loser);
        engine.stake(POST, CHALLENGE, STAKE); // losing side

        // tilt support decisively so the challenge side decays
        vm.prank(honest);
        engine.stake(POST, SUPPORT, STAKE * 3);

        uint256 bookedBefore = _amountOf(loser, CHALLENGE);
        skip(7 days); // unsettled decay accumulates against the loser

        // The dodge attempt: withdraw the pre-decay balance. It MUST fail,
        // because withdraw() settles the elapsed epochs before touching the
        // lot -- the decay is materialised first, so that balance is gone.
        vm.prank(loser);
        vm.expectRevert(StakeEngine.NotEnoughStake.selector);
        engine.withdraw(POST, CHALLENGE, bookedBefore, false);

        // What actually remains is strictly less than the principal.
        uint256 remaining = _amountOf(loser, CHALLENGE);
        assertLt(remaining, STAKE, "decay must have been applied before any exit");

        uint256 balBefore = vsp.balanceOf(loser);
        vm.prank(loser);
        engine.withdraw(POST, CHALLENGE, remaining, false);
        uint256 received = vsp.balanceOf(loser) - balBefore;
        assertLe(received, remaining, "cannot receive more than the settled balance");
        assertLt(received, STAKE, "loser must not exit whole");
    }

    function _amountOf(address who, uint8 side) internal view returns (uint256) {
        return engine.getUserStake(who, POST, side);
    }
}
