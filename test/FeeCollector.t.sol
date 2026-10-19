// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/FeeCollector.sol";
import "./mocks/MockVSP.sol";

/// patch_fee_collector — the relay's fee spender: bounded, pausable, governed.
contract FeeCollectorTest is Test {
    MockVSP vsp;
    FeeCollector fc;

    address governance = address(0xA110);
    address guardian = address(0xB220);
    address treasury = address(0xC330);
    address relay = address(0xD440);
    address relay2 = address(0xD441);
    address user = address(0xCAFE);
    address attacker = address(0xDEAD);

    uint256 constant ONE = 1e18;
    uint256 constant CAP = 5 * ONE; // per collect
    uint256 constant DAILY = 25 * ONE; // per user per day

    event FeeCollected(address indexed user, uint256 amount, bytes32 indexed ref, address indexed collector);

    function setUp() public {
        vsp = new MockVSP();
        fc = new FeeCollector(address(vsp), governance, guardian, treasury, relay, CAP, DAILY);
        vsp.mint(user, 1_000 * ONE);
        vm.prank(user);
        vsp.approve(address(fc), 100 * ONE); // the standing fee allowance, now to the contract
        vm.warp(1_800_000_000);
    }

    function test_collect_moves_fee_user_to_treasury_and_emits_ref() public {
        bytes32 ref = keccak256("relayed tx");
        vm.expectEmit(true, true, true, true);
        emit FeeCollected(user, ONE / 10, ref, relay);
        vm.prank(relay);
        fc.collect(user, ONE / 10, ref);
        assertEq(vsp.balanceOf(treasury), ONE / 10);
        assertEq(vsp.balanceOf(user), 1_000 * ONE - ONE / 10);
        assertEq(vsp.balanceOf(address(fc)), 0, "contract never holds funds");
        assertEq(fc.allowanceOf(user), 100 * ONE - ONE / 10);
    }

    function test_only_a_registered_collector_can_collect() public {
        vm.prank(attacker);
        vm.expectRevert(FeeCollector.NotCollector.selector);
        fc.collect(user, ONE, bytes32(0));
        // governance itself is not a collector either
        vm.prank(governance);
        vm.expectRevert(FeeCollector.NotCollector.selector);
        fc.collect(user, ONE, bytes32(0));
    }

    function test_per_collect_cap() public {
        vm.prank(relay);
        vm.expectRevert(abi.encodeWithSelector(FeeCollector.FeeAboveCap.selector, CAP + 1, CAP));
        fc.collect(user, CAP + 1, bytes32(0));
        vm.prank(relay);
        fc.collect(user, CAP, bytes32(0)); // exactly the cap is fine
    }

    function test_daily_cap_bounds_a_stolen_key_and_resets_next_day() public {
        // 5 collections of 5 VSP reach the 25 VSP daily cap; the 6th is refused even though the
        // allowance (100 VSP) would cover it.
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(relay);
            fc.collect(user, CAP, bytes32(i));
        }
        assertEq(fc.remainingToday(user), 0);
        vm.prank(relay);
        vm.expectRevert(abi.encodeWithSelector(FeeCollector.DailyCapExceeded.selector, user, DAILY + 1, DAILY));
        fc.collect(user, 1, bytes32(0));
        assertEq(vsp.balanceOf(treasury), DAILY);
        // next UTC day the window resets
        vm.warp(block.timestamp + 1 days);
        assertEq(fc.remainingToday(user), DAILY);
        vm.prank(relay);
        fc.collect(user, ONE, bytes32(0));
        assertEq(fc.remainingToday(user), DAILY - ONE);
    }

    function test_allowance_or_balance_short_reverts_in_the_token() public {
        vm.prank(user);
        vsp.approve(address(fc), ONE / 2);
        vm.prank(relay);
        vm.expectRevert(); // MockVSP: insufficient allowance
        fc.collect(user, ONE, bytes32(0));
        assertEq(vsp.balanceOf(treasury), 0);
    }

    function test_guardian_pauses_only_governance_unpauses() public {
        vm.prank(attacker);
        vm.expectRevert(FeeCollector.NotGuardian.selector);
        fc.pause();
        vm.prank(guardian);
        fc.pause();
        vm.prank(relay);
        vm.expectRevert(FeeCollector.WhenPaused.selector);
        fc.collect(user, ONE, bytes32(0));
        vm.prank(guardian);
        vm.expectRevert(FeeCollector.NotGovernance.selector);
        fc.unpause();
        vm.prank(governance);
        fc.unpause();
        vm.prank(relay);
        fc.collect(user, ONE, bytes32(0));
        // governance may pause too
        vm.prank(governance);
        fc.pause();
        assertTrue(fc.paused());
    }

    function test_governance_manages_collectors_treasury_limits_guardian() public {
        vm.prank(attacker);
        vm.expectRevert(FeeCollector.NotGovernance.selector);
        fc.setCollector(relay2, true);

        vm.startPrank(governance);
        fc.setCollector(relay2, true);
        fc.setCollector(relay, false);
        fc.setTreasury(address(0xE550));
        fc.setLimits(2 * ONE, 10 * ONE);
        fc.setGuardian(address(0xB221));
        vm.expectRevert(FeeCollector.BadLimits.selector);
        fc.setLimits(3 * ONE, 2 * ONE); // daily < per-collect
        vm.expectRevert(FeeCollector.BadLimits.selector);
        fc.setLimits(0, 2 * ONE);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        fc.setTreasury(address(0));
        vm.stopPrank();

        vm.prank(relay);
        vm.expectRevert(FeeCollector.NotCollector.selector);
        fc.collect(user, ONE, bytes32(0));
        vm.prank(relay2);
        vm.expectRevert(abi.encodeWithSelector(FeeCollector.FeeAboveCap.selector, 3 * ONE, 2 * ONE));
        fc.collect(user, 3 * ONE, bytes32(0));
        vm.prank(relay2);
        fc.collect(user, 2 * ONE, bytes32(0));
        assertEq(vsp.balanceOf(address(0xE550)), 2 * ONE);
        assertEq(fc.guardian(), address(0xB221));
    }

    function test_governance_handover_is_two_step() public {
        address newGov = address(0xA111);
        vm.prank(governance);
        fc.transferGovernance(newGov);
        assertEq(fc.governance(), governance, "unchanged until accepted");
        vm.prank(attacker);
        vm.expectRevert(FeeCollector.NotPendingGovernance.selector);
        fc.acceptGovernance();
        vm.prank(newGov);
        fc.acceptGovernance();
        assertEq(fc.governance(), newGov);
        assertEq(fc.pendingGovernance(), address(0));
        vm.prank(governance);
        vm.expectRevert(FeeCollector.NotGovernance.selector);
        fc.setLimits(ONE, ONE);
    }

    function test_constructor_rejects_zero_addresses_and_bad_limits() public {
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        new FeeCollector(address(0), governance, guardian, treasury, relay, CAP, DAILY);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        new FeeCollector(address(vsp), governance, guardian, treasury, address(0), CAP, DAILY);
        vm.expectRevert(FeeCollector.BadLimits.selector);
        new FeeCollector(address(vsp), governance, guardian, treasury, relay, CAP, CAP - 1);
        vm.expectRevert(FeeCollector.BadLimits.selector);
        new FeeCollector(address(vsp), governance, guardian, treasury, relay, 0, DAILY);
    }

    function test_zero_amount_and_zero_user_refused() public {
        vm.prank(relay);
        vm.expectRevert(FeeCollector.ZeroAmount.selector);
        fc.collect(user, 0, bytes32(0));
        vm.prank(relay);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        fc.collect(address(0), ONE, bytes32(0));
    }

    function test_sweep_returns_stray_tokens() public {
        vsp.mint(address(fc), 7 * ONE);
        vm.prank(attacker);
        vm.expectRevert(FeeCollector.NotGovernance.selector);
        fc.sweep(address(vsp), attacker, 7 * ONE);
        vm.prank(governance);
        fc.sweep(address(vsp), treasury, 7 * ONE);
        assertEq(vsp.balanceOf(treasury), 7 * ONE);
    }

    function testFuzz_daily_cap_is_never_exceeded(uint8 n, uint96 amt) public {
        uint256 a = bound(uint256(amt), 1, CAP);
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            vm.prank(relay);
            if (total + a > DAILY) {
                vm.expectRevert();
                fc.collect(user, a, bytes32(i));
            } else {
                fc.collect(user, a, bytes32(i));
                total += a;
            }
        }
        assertLe(vsp.balanceOf(treasury), DAILY);
        assertEq(vsp.balanceOf(treasury), total);
    }
}
