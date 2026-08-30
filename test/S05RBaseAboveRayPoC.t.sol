// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// S-05: the code comment at StakeEngine.sol lines 1238 and 1266 asserts
///
///     "behind<=T and rBase<=rMax<RAY, so gRay<=rBase<RAY
///      (the former >RAY clamp was dead)."
///
/// The claim `rMax < RAY` is a standing assumption used to justify deleting a
/// clamp. This test measures when it actually fails.
///
///   rMax = stakeIntRateMaxRay * EPOCH_LENGTH * epochsElapsed / YEAR_LENGTH
///        = rateMax * epochsElapsed / 365
///
/// so rMax >= RAY once epochsElapsed >= 365*RAY/rateMax:
///   deploy rate 693805319167998976 -> 527 epochs
///   governance cap 5e18           ->  73 epochs
contract S05RBaseAboveRayPoC is Test {
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

    function _stake(address who, uint256 post, uint8 side, uint256 amt) internal {
        vsp.mint(who, amt);
        vm.prank(who);
        vsp.approve(address(eng), type(uint256).max);
        vm.prank(who);
        eng.stake(post, side, amt);
    }

    /// Arithmetic restatement of the comment's assumption.
    function test_S05_WhenDoesRMaxExceedRay() public {
        uint256 eDeploy = 365 * RAY / DEPLOY_RATE_MAX + 1;
        uint256 eCap = 365 * RAY / CAP_RATE_MAX + 1;
        emit log_named_uint("epochs until rMax >= RAY, deploy rate", eDeploy);
        emit log_named_uint("epochs until rMax >= RAY, 5e18 cap", eCap);

        uint256 rMaxAtDeploy = DEPLOY_RATE_MAX * eDeploy / 365;
        uint256 rMaxAtCap = CAP_RATE_MAX * eCap / 365;
        emit log_named_uint("rMax at that point (deploy)", rMaxAtDeploy);
        emit log_named_uint("rMax at that point (cap)", rMaxAtCap);

        assertGe(rMaxAtDeploy, RAY, "comment's rMax<RAY assumption fails at deploy rate");
        assertGe(rMaxAtCap, RAY, "comment's rMax<RAY assumption fails at the cap");
    }

    /// Does a losing ranked lot actually get fully wiped in ONE settlement once
    /// rBase >= RAY? That is the observable consequence of the deleted clamp.
    /// Measured at the REAL deploy rate.
    function test_S05_LosingLotWipeoutAtDeployRate() public {
        _build(DEPLOY_RATE_MAX);

        address loser = address(0x1051);
        _stake(loser, POST, 0, 100e18);
        _stake(address(0xBEEF), POST, 1, 100_000e18); // vRay -> ~RAY, support loses

        uint256 before = eng.getUserStake(loser, POST, 0);
        // 600 epochs > the 527 needed for rMax >= RAY
        vm.warp(block.timestamp + 600 days);
        eng.updatePost(POST);
        uint256 after_ = eng.getUserStake(loser, POST, 0);

        emit log_named_uint("loser stake before", before);
        emit log_named_uint("loser stake after 600 epochs", after_);
        emit log_named_uint("fraction lost (bps)", before > 0 ? (before - after_) * 10000 / before : 0);

        // Limited liability (I.2) must still hold no matter what rBase did.
        assertLe(after_, before, "I.2: losing lot grew");
        (uint256 s, uint256 c) = eng.getPostTotals(POST);
        assertGe(vsp.balanceOf(address(eng)), s + c, "solvency broken at rBase >= RAY");
    }

    /// Same at the governance cap, where the threshold is only 73 epochs.
    function test_S05_LosingLotWipeoutAtCap() public {
        _build(CAP_RATE_MAX);

        address loser = address(0x1052);
        _stake(loser, POST, 0, 100e18);
        _stake(address(0xBEEF), POST, 1, 100_000e18);

        uint256 before = eng.getUserStake(loser, POST, 0);
        vm.warp(block.timestamp + 100 days); // > 73
        eng.updatePost(POST);
        uint256 after_ = eng.getUserStake(loser, POST, 0);

        emit log_named_uint("loser stake before", before);
        emit log_named_uint("loser stake after 100 epochs at cap", after_);
        emit log_named_uint("fraction lost (bps)", before > 0 ? (before - after_) * 10000 / before : 0);

        assertLe(after_, before, "I.2: losing lot grew");
        (uint256 s, uint256 c) = eng.getPostTotals(POST);
        assertGe(vsp.balanceOf(address(eng)), s + c, "solvency broken at cap rate");
    }
}
