// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// EXTERNAL REVIEW CHALLENGE to the S-02 fix.
///
/// Claim from the reviewer: the fix leaves the OLD ghost lot in the array while
/// creating a NEW lot for the same address. When compactLots() or _rebalance
/// later drops the ghost, `_setLotIndex(ps, ghostStaker, side, 0)` would wipe the
/// index of the address's still-live NEW lot, orphaning real funds.
///
/// This test is designed to FAIL if that is true.
contract S02FixOrphanCheckPoC is Test {
    StakeEngine eng;
    MockVSP vsp;
    MockProtocolPolicy policy;

    uint256 constant DEPLOY_RATE_MAX = 693805319167998976;
    uint256 constant POST = 1;

    address attacker = address(0xA77AC7E2);

    function setUp() public {
        vm.warp(86400 * 1000);
        vsp = new MockVSP();
        policy = new MockProtocolPolicy(0);
        policy.setRates(0, DEPLOY_RATE_MAX);
        eng = StakeEngine(
            address(
                new ERC1967Proxy(
                    address(new StakeEngine(address(0))),
                    abi.encodeCall(StakeEngine.initialize, (address(this), address(vsp), address(policy)))
                )
            )
        );
        vsp.mint(address(this), 1e33);
        vsp.approve(address(eng), type(uint256).max);
    }

    function _stake(address who, uint8 side, uint256 amt) internal {
        vsp.mint(who, amt);
        vm.prank(who);
        vsp.approve(address(eng), type(uint256).max);
        vm.prank(who);
        eng.stake(POST, side, amt);
    }

    /// Does the fix actually leave TWO array entries for the same address?
    function test_DoesFixLeaveADuplicateLot() public {
        _stake(attacker, 0, 1);
        vm.prank(attacker);
        eng.withdraw(POST, 0, 1, true); // ghost created

        _stake(address(0xB1), 0, 100e18);
        _stake(address(0xB2), 0, 100e18);

        // restake: with the fix this must NOT revive at the old index
        _stake(attacker, 0, 500e18);

        (uint256 amt, uint256 wPos,,) = eng.getUserLotInfo(attacker, POST, 0);
        emit log_named_uint("attacker lot amount", amt);
        emit log_named_uint("attacker wPos", wPos);
        emit log_named_uint("attacker getUserStake", eng.getUserStake(attacker, POST, 0));
        assertEq(amt, 500e18, "attacker must hold exactly the restaked amount");
    }

    /// THE CHALLENGE: compactLots after the fix. Does the attacker's live lot survive?
    function test_CompactLotsAfterFix_LiveLotSurvives() public {
        _stake(attacker, 0, 1);
        vm.prank(attacker);
        eng.withdraw(POST, 0, 1, true); // ghost at index 1

        _stake(address(0xB1), 0, 100e18);
        _stake(address(0xB2), 0, 100e18);
        _stake(attacker, 0, 500e18); // new lot via the fix path

        uint256 beforeCompact = eng.getUserStake(attacker, POST, 0);
        emit log_named_uint("attacker stake BEFORE compactLots", beforeCompact);

        // governance compacts, which drops zero-amount ghosts.
        // With the v2 fix the ghost was already removed at restake time, so there
        // is nothing to compact and the call correctly reverts NoGhostLots.
        try eng.compactLots(POST, 0) {
            emit log("compactLots ran (a ghost still existed)");
        } catch {
            emit log("compactLots reverted NoGhostLots -> no ghost remained (v2 behaviour)");
        }

        uint256 afterCompact = eng.getUserStake(attacker, POST, 0);
        emit log_named_uint("attacker stake AFTER compactLots", afterCompact);

        // If the reviewer is right, the ghost removal zeroes the live lot's index
        // and this reads 0 -> funds orphaned.
        assertEq(afterCompact, beforeCompact, "ORPHANED: compactLots wiped the live lot index");

        // and the attacker must still be able to exit
        vm.prank(attacker);
        eng.withdraw(POST, 0, afterCompact, true);
        emit log_named_uint("attacker withdrew", vsp.balanceOf(attacker));
        assertEq(eng.getUserStake(attacker, POST, 0), 0, "exit failed after compact");

        (uint256 s, uint256 c) = eng.getPostTotals(POST);
        assertGe(vsp.balanceOf(address(eng)), s + c, "solvency after compact+exit");
    }

    /// Same challenge but via _rebalance's ghost-demotion path (needs a full ranked set).
    function test_RebalanceGhostDrop_LiveLotSurvives() public {
        _stake(attacker, 0, 1);
        vm.prank(attacker);
        eng.withdraw(POST, 0, 1, true); // ghost

        // fill ranked to MAX so _rebalance's second loop can demote ghosts
        for (uint256 i = 0; i < 99; i++) {
            _stake(address(uint160(0x100000 + i)), 0, 10e18);
        }
        // attacker restakes -> new lot via fix path; array now at/over the cap
        _stake(attacker, 0, 500e18);

        uint256 before = eng.getUserStake(attacker, POST, 0);
        emit log_named_uint("attacker stake before churn", before);

        // more stakers arrive, forcing repeated _rebalance passes
        for (uint256 i = 0; i < 10; i++) {
            _stake(address(uint160(0x200000 + i)), 0, 20e18);
        }

        uint256 after_ = eng.getUserStake(attacker, POST, 0);
        emit log_named_uint("attacker stake after churn", after_);
        assertEq(after_, before, "ORPHANED via _rebalance ghost drop");

        vm.prank(attacker);
        eng.withdraw(POST, 0, after_, true);
        assertEq(eng.getUserStake(attacker, POST, 0), 0, "exit failed after rebalance churn");

        (uint256 s, uint256 c) = eng.getPostTotals(POST);
        assertGe(vsp.balanceOf(address(eng)), s + c, "solvency after rebalance churn");
    }
}
