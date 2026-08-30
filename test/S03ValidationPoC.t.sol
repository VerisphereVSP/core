// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// S-03 VALIDATION. Three questions that decide whether this is a real
/// finding or an overclaim:
///
/// V1: is the inflated growth actually ABOVE the rMax ceiling, or is the
///     post merely receiving the maximum rate the protocol already permits?
///     If growth <= rMax the "inflation" framing is wrong.
/// V2: can ONE attacker execute the whole thing self-contained, or does it
///     depend on three unrelated whales voluntarily unwinding?
/// V3: is the attacker's net PnL positive after their own capital costs?
contract S03ValidationPoC is Test {
    StakeEngine eng;
    MockVSP vsp;
    MockProtocolPolicy policy;

    uint256 constant DEPLOY_RATE_MAX = 693805319167998976;
    uint256 constant RAY = 1e18;
    uint256 constant TARGET = 4;

    address attacker = address(0xA77AC7E2);
    address victimSide = address(0xBEEF);

    function _fresh() internal {
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
        vsp.mint(address(this), 1e30);
        vsp.approve(address(eng), type(uint256).max);
    }

    function _fund(address who, uint256 amt) internal {
        vsp.mint(who, amt);
        vm.prank(who);
        vsp.approve(address(eng), type(uint256).max);
    }

    function _stake(address who, uint256 post, uint8 side, uint256 amt) internal {
        _fund(who, amt);
        vm.prank(who);
        eng.stake(post, side, amt);
    }

    function _total(uint256 post) internal view returns (uint256) {
        (uint256 s, uint256 c) = eng.getPostTotals(post);
        return s + c;
    }

    // ─────────────────────────────────────────────────────────────
    // V1: is growth above the rMax ceiling?
    // ─────────────────────────────────────────────────────────────
    function test_V1_GrowthVsRMaxCeiling() public {
        _fresh();
        // occupy all 3 slots, target post untracked
        _stake(address(0xA1), 1, 0, 300e18);
        _stake(address(0xA2), 2, 0, 200e18);
        _stake(address(0xA3), 3, 0, 150e18);
        _stake(attacker, TARGET, 0, 80e18);
        _stake(victimSide, TARGET, 1, 1);

        // drag sMax to 1 wei
        vm.prank(address(0xA1));
        eng.withdraw(1, 0, 300e18, true);
        vm.prank(address(0xA2));
        eng.withdraw(2, 0, 200e18, true);
        vm.prank(address(0xA3));
        eng.withdraw(3, 0, 150e18, true);
        _stake(address(0xD057), 9, 0, 1);

        // patch_prC_rulings_p2: REGRESSION FORM — the drag is dead. Within the
        // same epoch no decay elapses, so sMax holds the 300e18 high-water mark.
        assertEq(eng.sMax(), 300e18, "never-snap-down: sMax must hold the high-water mark");

        uint256 before = _total(TARGET);
        uint256 epochs = 30;
        vm.warp(block.timestamp + epochs * 1 days);
        eng.updatePost(TARGET);
        uint256 growth = _total(TARGET) - before;

        // rMax for this elapsed window, straight from the formula in _forceSnapshot
        uint256 rMax = (DEPLOY_RATE_MAX * 1 days * epochs) / 365 days;
        uint256 ceiling = (before * rMax) / RAY;

        emit log_named_uint("supportTotal before", before);
        emit log_named_uint("actual growth", growth);
        emit log_named_uint("rMax for 30 epochs (RAY)", rMax);
        emit log_named_uint("theoretical max growth (T*rMax/RAY)", ceiling);
        if (growth > ceiling) {
            emit log_named_uint("ABOVE ceiling by", growth - ceiling);
        } else {
            emit log_named_uint("BELOW ceiling by", ceiling - growth);
        }

        // Honest question: does it breach the ceiling?
        assertLe(growth, ceiling, "growth stays within the rMax ceiling");
    }

    // ─────────────────────────────────────────────────────────────
    // V2 + V3: one attacker, self-contained, net PnL
    // ─────────────────────────────────────────────────────────────
    function test_V2_SelfContainedAttack_AndPnL() public {
        _fresh();

        uint256 attackerStart = 1000e18;
        _fund(attacker, attackerStart);

        // Step 1: attacker seeds all 3 tracked slots himself (temporary capital)
        vm.startPrank(attacker);
        eng.stake(1, 0, 300e18);
        eng.stake(2, 0, 200e18);
        eng.stake(3, 0, 150e18);
        // Step 2: real position on the untracked target post
        eng.stake(TARGET, 0, 80e18);
        // Step 3: pull the seed capital straight back out
        eng.withdraw(1, 0, 300e18, true);
        eng.withdraw(2, 0, 200e18, true);
        eng.withdraw(3, 0, 150e18, true);
        // Step 4: 1 wei dust post becomes the tracked leader -> sMax = 1
        eng.stake(9, 0, 1);
        vm.stopPrank();

        // opposing side so the target actually settles
        _stake(victimSide, TARGET, 1, 1);

        emit log_named_uint("sMax after self-contained setup", eng.sMax());
        emit log_named_uint("attacker VSP left in wallet", vsp.balanceOf(attacker));

        uint256 before = _total(TARGET);
        vm.warp(block.timestamp + 30 days);
        eng.updatePost(TARGET);

        uint256 attackerPos = eng.getUserStake(attacker, TARGET, 0);
        emit log_named_uint("target total before settle", before);
        emit log_named_uint("target total after settle", _total(TARGET));
        emit log_named_uint("attacker position after settle", attackerPos);
        emit log_named_uint("attacker gain on 80e18", attackerPos - 80e18);

        // net: everything the attacker still holds vs what they started with
        uint256 held = vsp.balanceOf(attacker) + attackerPos + 1; // +1 wei in post 9
        emit log_named_uint("attacker total value held", held);
        emit log_named_uint("attacker started with", attackerStart);
        if (held > attackerStart) {
            emit log_named_uint("NET PROFIT", held - attackerStart);
        } else {
            emit log_named_uint("NET LOSS", attackerStart - held);
        }

        // patch_prC_rulings_p2: post-fix the setup cannot drag sMax (it holds at
        // 300e18 through the unwind and descends only by decay, floored at the
        // tracked leader — which by settlement time is the attacker's own post,
        // the INTENDED leader semantics). The attacker earns only the honest
        // participation-scaled yield on their real position.
        assertEq(eng.sMax(), _total(TARGET), "decay floored at the tracked leader (attacker's own post)");
        assertGe(held + 1e18, attackerStart, "attacker keeps roughly their capital (honest yield only)");
    }

    // ─────────────────────────────────────────────────────────────
    // Control: same attacker, same capital, NO sMax manipulation
    // ─────────────────────────────────────────────────────────────
    function test_V3_ControlWithoutManipulation() public {
        _fresh();
        uint256 attackerStart = 1000e18;
        _fund(attacker, attackerStart);

        // honest whales hold the 3 slots and do NOT unwind
        _stake(address(0xA1), 1, 0, 300e18);
        _stake(address(0xA2), 2, 0, 200e18);
        _stake(address(0xA3), 3, 0, 150e18);

        vm.prank(attacker);
        eng.stake(TARGET, 0, 80e18);
        _stake(victimSide, TARGET, 1, 1);

        emit log_named_uint("sMax (honest)", eng.sMax());
        vm.warp(block.timestamp + 30 days);
        eng.updatePost(TARGET);

        uint256 pos = eng.getUserStake(attacker, TARGET, 0);
        emit log_named_uint("attacker position, honest sMax", pos);
        emit log_named_uint("attacker gain, honest sMax", pos - 80e18);
    }
}
