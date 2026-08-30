// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// S-05 VALIDATION. Three questions that decide whether S-05 is even
/// Informational, or merely a stale comment with zero consequence.
///
/// V1: does the comment hold in NORMAL operation (settlement every epoch)?
///     If yes, it is only false for dormant posts, which weakens it.
/// V2: is there any UNCLAMPED consumer of rBase > RAY? The winning side does
///     `lot.amount += delta` with no min(). Can a winner exceed the rMax ceiling?
/// V3: can `amount * rBase * midpointRate` overflow uint256 at extreme dormancy?
contract S05ValidationPoC is Test {
    StakeEngine eng;
    MockVSP vsp;
    MockProtocolPolicy policy;

    uint256 constant DEPLOY_RATE_MAX = 693805319167998976;
    uint256 constant CAP_RATE_MAX = 5e18;
    uint256 constant RAY = 1e18;
    uint256 constant POST = 1;

    function _build(uint256 rateMax) internal {
        vm.warp(86400 * 1000);
        vsp = new MockVSP();
        policy = new MockProtocolPolicy(0);
        policy.setRates(0, rateMax);
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

    /// V1: settle every single epoch, so epochsElapsed == 1 always.
    /// rMax = rateMax/365, far below RAY. Does the comment hold here?
    function test_V1_CommentHoldsUnderNormalOperation() public {
        _build(CAP_RATE_MAX); // worst case rate
        _stake(address(0xA1), 0, 100e18);
        _stake(address(0xBEEF), 1, 10_000e18);

        uint256 rMaxPerEpoch = CAP_RATE_MAX * 1 / 365;
        emit log_named_uint("rMax at epochsElapsed=1 (cap rate)", rMaxPerEpoch);
        assertLt(rMaxPerEpoch, RAY, "V1: at 1 epoch/settlement the comment's premise HOLDS");

        // 200 consecutive single-epoch settlements
        for (uint256 i = 0; i < 200; i++) {
            vm.warp(block.timestamp + 1 days);
            eng.updatePost(POST);
        }
        (uint256 s, uint256 c) = eng.getPostTotals(POST);
        emit log_named_uint("support after 200 single-epoch settles", s);
        assertGe(vsp.balanceOf(address(eng)), s + c, "solvency under normal operation");
    }

    /// V2: winning side has NO min() clamp. Can it exceed T*rMax/RAY?
    function test_V2_WinningSideVsRMaxCeiling() public {
        _build(CAP_RATE_MAX);
        _stake(address(0xA1), 0, 10_000e18); // winner
        _stake(address(0xBEEF), 1, 1); // loser, vRay -> RAY

        uint256 epochs = 200; // rMax = 5e18*200/365 = 2.739e18 > 2*RAY
        uint256 before = 10_000e18;
        vm.warp(block.timestamp + epochs * 1 days);
        eng.updatePost(POST);

        (uint256 sAfter,) = eng.getPostTotals(POST);
        uint256 growth = sAfter - (before + 1) + 1; // side total includes nothing else
        uint256 rMax = CAP_RATE_MAX * epochs / 365;
        uint256 ceiling = ((before + 1) * rMax) / RAY;

        emit log_named_uint("rMax at 200 epochs (RAY)", rMax);
        emit log_named_uint("support before", before + 1);
        emit log_named_uint("support after", sAfter);
        emit log_named_uint("actual growth", growth);
        emit log_named_uint("ceiling T*rMax/RAY", ceiling);

        assertLe(growth, ceiling, "V2: winning growth stays within the rMax ceiling");
    }

    /// V3: extreme dormancy at the cap rate. No overflow, no revert, solvency held.
    function test_V3_ExtremeDormancyNoOverflow() public {
        _build(CAP_RATE_MAX);
        _stake(address(0xA1), 0, 10_000_000e18); // MAX_STAKE_AMOUNT
        _stake(address(0xBEEF), 1, 10_000_000e18);
        // tip the balance so a winner exists
        _stake(address(0xA2), 0, 1e18);

        vm.warp(block.timestamp + 8000 days); // ~22 years, rMax ~ 109 * RAY
        eng.updatePost(POST);

        (uint256 s, uint256 c) = eng.getPostTotals(POST);
        emit log_named_uint("support after 8000 epochs", s);
        emit log_named_uint("challenge after 8000 epochs", c);
        emit log_named_uint("engine balance", vsp.balanceOf(address(eng)));
        assertGe(vsp.balanceOf(address(eng)), s + c, "V3: solvency at extreme rBase");
    }
}
