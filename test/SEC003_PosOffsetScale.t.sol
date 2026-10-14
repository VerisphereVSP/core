// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./base/SnapshotBase.sol";

/// VSP-SEC-003 (reported 2026-10-14): a ranked lot's posOffset was blended upward on top-up but never
/// scaled back on partial withdraw, so "top up 9,900, withdraw 9,900" left a 100-VSP lot parked at the
/// tail with the blended offset: position weight 0.015 vs 0.995 for an identical control lot and 98.5 %
/// of its losing-settlement burn avoided, every epoch, while its full amount still counted in the side
/// totals and the score. The reporter's PoC (test_T2_PosOffsetStaleness) is reproduced here with the
/// assertions inverted: after patch_sec003_posoffset_scale the manipulated lot settles like the control.
contract SEC003_PosOffsetScale is SnapshotBase {
    address constant ATT = address(0xA77ACC);
    address constant CROWD = address(0x40000);

    function _setupTwin() internal returns (uint256 atk, uint256 ctl) {
        atk = _claim("sec003 atk");
        ctl = _claim("sec003 ctl");
        vsp.mint(CROWD, 1_000_000e18);
        vsp.mint(ATT, 1_000_000e18);
        vm.startPrank(CROWD);
        vsp.approve(address(se), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(ATT);
        vsp.approve(address(se), type(uint256).max);
        vm.stopPrank();
        // attacker / control lot of 100 at the front of the support queue, 9,000 behind, 10,000 challenge
        _stake(ATT, atk, 0, 100e18);
        _stake(A, ctl, 0, 100e18);
        _stake(CROWD, atk, 0, 9000e18);
        _stake(CROWD, ctl, 0, 9000e18);
        _stake(B, atk, 1, 10000e18);
        _stake(B, ctl, 1, 10000e18);
    }

    function test_SEC003_partialWithdrawScalesOffset() public {
        (uint256 atk, uint256 ctl) = _setupTwin();
        _stake(ATT, atk, 0, 9900e18); // top-up blends the offset toward the tail
        assertGt(se.posOffset(atk, 0, ATT), 0, "top-up must create an offset");
        _withdraw(ATT, atk, 0, 9900e18); // partial withdraw in the same epoch
        (uint256 amtA,,, uint256 pwA) = se.getUserLotInfo(ATT, atk, 0);
        (uint256 amtC,,, uint256 pwC) = se.getUserLotInfo(A, ctl, 0);
        assertEq(amtA, 100e18);
        assertEq(amtC, 100e18);
        // the offset scaled with the remaining 1 %: the lot is back near the front
        assertGe(pwA * 100, pwC * 98, "position weight must stay within 2 % of the control lot");
        // two losing settlements: the manipulated lot burns like the control, not 1.5 % of it
        _seedAll();
        _nextEpoch();
        _keeperPass();
        uint256 atkLoss = 100e18 - se.getUserStake(ATT, atk, 0);
        uint256 ctlLoss = 100e18 - se.getUserStake(A, ctl, 0);
        assertGt(atkLoss, 0, "a losing lot burns");
        assertGe(atkLoss * 100, ctlLoss * 98, "epoch 1: burn within 2 % of control");
        uint256 a1 = se.getUserStake(ATT, atk, 0);
        uint256 c1 = se.getUserStake(A, ctl, 0);
        _nextEpoch();
        _keeperPass();
        uint256 atkLoss2 = a1 - se.getUserStake(ATT, atk, 0);
        uint256 ctlLoss2 = c1 - se.getUserStake(A, ctl, 0);
        assertGe(atkLoss2 * 100, ctlLoss2 * 98, "epoch 2: burn within 2 % of control");
    }

    function test_SEC003_fullExitClearsOffset() public {
        (uint256 atk,) = _setupTwin();
        _stake(ATT, atk, 0, 9900e18);
        assertGt(se.posOffset(atk, 0, ATT), 0);
        _withdraw(ATT, atk, 0, 10000e18); // full exit
        assertEq(se.posOffset(atk, 0, ATT), 0, "full exit leaves no offset to inherit");
        _stake(ATT, atk, 0, 100e18); // re-entry: a fresh lot at the tail, offset 0
        assertEq(se.posOffset(atk, 0, ATT), 0, "re-entry starts without an offset");
    }

    function test_SEC003_offsetScalesProportionally() public {
        (uint256 atk,) = _setupTwin();
        _stake(ATT, atk, 0, 900e18); // 100 -> 1,000
        uint256 off = se.posOffset(atk, 0, ATT);
        assertGt(off, 0);
        _withdraw(ATT, atk, 0, 500e18); // 1,000 -> 500: offset halves
        assertEq(se.posOffset(atk, 0, ATT), off / 2, "offset scales with remaining/previous");
    }
}
