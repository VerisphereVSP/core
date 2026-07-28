// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ScheduledEmitter.sol";
import "../src/interfaces/IVSPToken.sol";

/// @dev Minimal mock token: tracks totalSupply, mints unconditionally when called
///      by an allowed minter. Enough to exercise the emitter's logic in isolation
///      (the real VSPToken time-window cap is tested separately in its own suite).
contract MockVSP is IVSPToken {
    uint256 public totalSupply;
    mapping(address => bool) public minter;
    mapping(address => uint256) public balanceOf;

    function setMinter(address who, bool ok) external { minter[who] = ok; }

    function mint(address to, uint256 amount) external override {
        require(minter[msg.sender], "not minter");
        totalSupply += amount;
        balanceOf[to] += amount;
    }
    function burn(uint256) external override {}
    function burnFrom(address, uint256) external override {}
}

contract ScheduledEmitterTest is Test {
    MockVSP token;
    address recipient = makeAddr("recipient");
    address worker = makeAddr("worker");
    address stranger = makeAddr("stranger");

    uint256 constant INTERVAL = 30 days;
    uint256 constant AMOUNT = 1000e18;
    uint256 constant CAP = 10000e18;

    function setUp() public {
        token = new MockVSP();
        vm.warp(1_700_000_000); // a realistic start ts, not 0
    }

    function _deploy(bool workerOnly, uint256 cap, uint256 startAt)
        internal
        returns (ScheduledEmitter e)
    {
        e = new ScheduledEmitter(
            address(token), recipient, INTERVAL, AMOUNT, cap,
            workerOnly, workerOnly ? worker : address(0), startAt
        );
        token.setMinter(address(e), true);
    }

    // ---- constructor guards ----
    function test_ctor_rejects_zero_token() public {
        vm.expectRevert(ScheduledEmitter.ZeroToken.selector);
        new ScheduledEmitter(address(0), recipient, INTERVAL, AMOUNT, CAP, false, address(0), 0);
    }
    function test_ctor_rejects_zero_recipient() public {
        vm.expectRevert(ScheduledEmitter.ZeroRecipient.selector);
        new ScheduledEmitter(address(token), address(0), INTERVAL, AMOUNT, CAP, false, address(0), 0);
    }
    function test_ctor_rejects_zero_interval() public {
        vm.expectRevert(ScheduledEmitter.ZeroInterval.selector);
        new ScheduledEmitter(address(token), recipient, 0, AMOUNT, CAP, false, address(0), 0);
    }
    function test_ctor_rejects_zero_amount() public {
        vm.expectRevert(ScheduledEmitter.ZeroAmount.selector);
        new ScheduledEmitter(address(token), recipient, INTERVAL, 0, CAP, false, address(0), 0);
    }
    function test_ctor_rejects_cap_below_amount() public {
        vm.expectRevert(ScheduledEmitter.CapBelowAmount.selector);
        new ScheduledEmitter(address(token), recipient, INTERVAL, AMOUNT, AMOUNT - 1, false, address(0), 0);
    }
    function test_ctor_rejects_workeronly_zero_worker() public {
        vm.expectRevert(ScheduledEmitter.NotWorker.selector);
        new ScheduledEmitter(address(token), recipient, INTERVAL, AMOUNT, CAP, true, address(0), 0);
    }

    // ---- time gate ----
    function test_first_emit_allowed_when_startAt_zero() public {
        ScheduledEmitter e = _deploy(false, CAP, 0);
        uint256 minted = e.emit_();
        assertEq(minted, AMOUNT);
        assertEq(token.totalSupply(), AMOUNT);
        assertEq(token.balanceOf(recipient), AMOUNT);
    }

    function test_emit_reverts_before_interval() public {
        ScheduledEmitter e = _deploy(false, CAP, block.timestamp);
        // startAt = now, so earliest = now + INTERVAL; immediate emit too soon
        vm.expectRevert(
            abi.encodeWithSelector(ScheduledEmitter.TooSoon.selector, block.timestamp, block.timestamp + INTERVAL)
        );
        e.emit_();
    }

    function test_emit_allowed_after_interval() public {
        ScheduledEmitter e = _deploy(false, CAP, block.timestamp);
        vm.warp(block.timestamp + INTERVAL);
        e.emit_();
        assertEq(token.totalSupply(), AMOUNT);
    }

    function test_second_emit_reverts_until_next_interval() public {
        ScheduledEmitter e = _deploy(false, CAP, 0);
        e.emit_(); // t0
        uint256 t0 = block.timestamp;
        vm.warp(t0 + INTERVAL - 1);
        vm.expectRevert(
            abi.encodeWithSelector(ScheduledEmitter.TooSoon.selector, block.timestamp, t0 + INTERVAL)
        );
        e.emit_();
        vm.warp(t0 + INTERVAL);
        e.emit_(); // now allowed
        assertEq(token.totalSupply(), 2 * AMOUNT);
    }

    // ---- worker unreliability: late nudge emits once, not catch-up ----
    function test_late_nudge_emits_once_not_catchup() public {
        ScheduledEmitter e = _deploy(false, CAP, 0);
        e.emit_(); // t0
        // wait 5 intervals, then nudge once
        vm.warp(block.timestamp + 5 * INTERVAL);
        e.emit_();
        // only ONE emission happened despite 5 intervals elapsing (no catch-up)
        assertEq(token.totalSupply(), 2 * AMOUNT);
    }

    // ---- cap: premint (cap == amount) ----
    function test_premint_single_tranche_then_finished() public {
        ScheduledEmitter e = _deploy(false, AMOUNT, 0); // cap == amount
        e.emit_();
        assertEq(token.totalSupply(), AMOUNT);
        assertTrue(e.finished());
        // any further nudge reverts finished
        vm.warp(block.timestamp + INTERVAL);
        vm.expectRevert(ScheduledEmitter.EmitterFinished.selector);
        e.emit_();
    }

    // ---- cap: final partial tranche is clamped ----
    function test_final_tranche_clamped_to_cap() public {
        // cap = 2500, amount = 1000 -> emissions 1000,1000, then 500 (clamped)
        ScheduledEmitter e = _deploy(false, 2500e18, 0);
        e.emit_(); // 1000 at t=start
        // advance a FULL interval past each emission explicitly (avoid reusing a
        // stale block.timestamp base, which would land two warps on the same ts)
        vm.warp(e.nextEmissionTime());
        e.emit_(); // 2000
        vm.warp(e.nextEmissionTime());
        uint256 minted = e.emit_(); // clamp to 500
        assertEq(minted, 500e18);
        assertEq(token.totalSupply(), 2500e18);
        assertTrue(e.finished());
    }

    // ---- cap: pre-existing supply near cap ----
    function test_respects_existing_supply_toward_cap() public {
        // simulate other minters already produced supply
        token.setMinter(address(this), true);
        token.mint(address(0xdead), 9500e18);
        ScheduledEmitter e = _deploy(false, 10000e18, 0); // cap 10000
        uint256 minted = e.emit_(); // room = 500
        assertEq(minted, 500e18);
        assertTrue(e.finished());
    }

    // ---- access control ----
    function test_workeronly_stranger_reverts() public {
        ScheduledEmitter e = _deploy(true, CAP, 0);
        vm.prank(stranger);
        vm.expectRevert(ScheduledEmitter.NotWorker.selector);
        e.emit_();
    }
    function test_workeronly_worker_ok() public {
        ScheduledEmitter e = _deploy(true, CAP, 0);
        vm.prank(worker);
        e.emit_();
        assertEq(token.totalSupply(), AMOUNT);
    }
    function test_permissionless_stranger_ok() public {
        ScheduledEmitter e = _deploy(false, CAP, 0);
        vm.prank(stranger);
        e.emit_(); // contract gates on time+cap, not caller
        assertEq(token.totalSupply(), AMOUNT);
    }

    // ---- views ----
    function test_emissionDue_and_nextTime() public {
        ScheduledEmitter e = _deploy(false, CAP, block.timestamp);
        assertFalse(e.emissionDue()); // too soon
        assertEq(e.nextEmissionTime(), block.timestamp + INTERVAL);
        vm.warp(block.timestamp + INTERVAL);
        assertTrue(e.emissionDue());
        e.emit_();
        assertFalse(e.emissionDue()); // just emitted
    }

    // ---- INVARIANT: emission depends ONLY on time + cap, never on price ----
    //      Encoded as: given identical (time, supply) state, emit() behaves
    //      identically regardless of any external "market" — there is no price
    //      input to vary. This test documents the property; the structural proof
    //      is that the contract has no oracle/price/reserve reads at all.
    function test_invariant_no_price_dependence_behaves_purely_on_time_and_cap() public {
        ScheduledEmitter a = _deploy(false, CAP, 0);
        // Two identical emitters in identical time/supply state must behave
        // identically — there is no other input that could differ.
        a.emit_();
        uint256 supplyAfterA = token.totalSupply();

        MockVSP token2 = new MockVSP();
        vm.warp(block.timestamp); // same ts
        ScheduledEmitter b = new ScheduledEmitter(
            address(token2), recipient, INTERVAL, AMOUNT, CAP, false, address(0), 0
        );
        token2.setMinter(address(b), true);
        b.emit_();
        assertEq(token2.totalSupply(), supplyAfterA, "emission must depend only on time+cap");
    }

    // ---- fuzz: never exceeds cap, never emits early ----
    function testFuzz_never_exceeds_cap(uint96 warpBy, uint8 nudges) public {
        ScheduledEmitter e = _deploy(false, CAP, 0);
        uint256 n = uint256(nudges) % 30;
        for (uint256 i = 0; i < n; i++) {
            vm.warp(block.timestamp + (uint256(warpBy) % (2 * INTERVAL)) + 1);
            if (e.emissionDue()) {
                try e.emit_() {} catch {}
            }
        }
        assertLe(token.totalSupply(), CAP, "cap must never be exceeded");
    }
}
