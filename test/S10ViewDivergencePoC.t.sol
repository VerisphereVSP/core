// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// S-10: view vs materialised sMax path divergence.
///
/// _forceSnapshot (line 629)  : participationRay = T * RAY / sMax          <- RAW sMax
/// _projectTotals (line 801-806): projSMax = _projectSMaxDecay(currentEpoch)
///                                participationRay = T * RAY / projSMax   <- DECAYED sMax
///
/// Spec V.8 (coverage requirement 8): "View projections match materialized
/// snapshot values (within rounding tolerance)."
///
/// If sMax has decayed since the last update, the view uses a SMALLER denominator
/// than settlement will, so the view over-reports growth. Test measures the gap.
contract S10ViewDivergencePoC is Test {
    StakeEngine eng;
    MockVSP vsp;
    MockProtocolPolicy policy;

    uint256 constant DEPLOY_RATE_MAX = 693805319167998976;
    uint256 constant TARGET = 1;
    uint256 constant DECOY = 2;

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

    /// Baseline: no decay in play, so view and materialised must agree.
    function test_S10_ViewMatchesMaterialised_NoDecay() public {
        _fresh();
        _stake(address(0xA1), TARGET, 0, 100e18);
        _stake(address(0xBEEF), TARGET, 1, 10e18);

        vm.warp(block.timestamp + 40 days);

        (uint256 vS, uint256 vC) = eng.getPostTotals(TARGET); // projected
        eng.updatePost(TARGET);
        (uint256 mS, uint256 mC) = eng.getPostTotals(TARGET); // materialised

        emit log_named_uint("view support", vS);
        emit log_named_uint("materialised support", mS);
        emit log_named_uint("view challenge", vC);
        emit log_named_uint("materialised challenge", mC);

        uint256 dS = vS > mS ? vS - mS : mS - vS;
        uint256 dC = vC > mC ? vC - mC : mC - vC;
        emit log_named_uint("support delta", dS);
        emit log_named_uint("challenge delta", dC);
        // rounding tolerance: 0.5% as their own StakeEngineRescale suite uses
        assertLe(dS * 10000 / (mS == 0 ? 1 : mS), 50, "support diverged > 0.5%");
        assertLe(dC * 10000 / (mC == 0 ? 1 : mC), 50, "challenge diverged > 0.5%");
    }

    /// Decay engaged: drive topPosts empty so _applySMaxDecay is the fallback,
    /// then compare view vs materialised on a still-live post.
    function test_S10_ViewVsMaterialised_WithDecay() public {
        _fresh();
        // decoy posts occupy all 3 tracked slots, then unwind so topPosts empties
        _stake(address(0xD1), DECOY, 0, 300e18);
        _stake(address(0xD2), 3, 0, 200e18);
        _stake(address(0xD3), 4, 0, 150e18);
        // the post we measure
        _stake(address(0xA1), TARGET, 0, 100e18);
        _stake(address(0xBEEF), TARGET, 1, 10e18);

        vm.prank(address(0xD1));
        eng.withdraw(DECOY, 0, 300e18, true);
        vm.prank(address(0xD2));
        eng.withdraw(3, 0, 200e18, true);
        vm.prank(address(0xD3));
        eng.withdraw(4, 0, 150e18, true);

        emit log_named_uint("sMax after decoys unwind", eng.sMax());
        emit log_named_uint("sMaxLastUpdatedEpoch", eng.sMaxLastUpdatedEpoch());

        // warp well past sMaxDecayMaxEpochs so the projection decays hard
        vm.warp(block.timestamp + 60 days);

        (uint256 vS, uint256 vC) = eng.getPostTotals(TARGET);
        eng.updatePost(TARGET);
        (uint256 mS, uint256 mC) = eng.getPostTotals(TARGET);

        emit log_named_uint("VIEW support (projected)", vS);
        emit log_named_uint("MATERIALISED support", mS);
        emit log_named_uint("VIEW challenge", vC);
        emit log_named_uint("MATERIALISED challenge", mC);
        emit log_named_uint("sMax after settle", eng.sMax());

        uint256 dS = vS > mS ? vS - mS : mS - vS;
        emit log_named_uint("support absolute delta", dS);
        if (mS > 0) {
            emit log_named_uint("support delta (bps of materialised)", dS * 10000 / mS);
        }

        // Report only. V.8 asks for equality within rounding tolerance.
        // RECORDED: this assertion FAILS at 120 bps. Kept as the failing PoC for S-10.
        assertLe(dS * 10000 / (mS == 0 ? 1 : mS), 50, "V.8: view diverged from materialised > 0.5%");
    }

    /// Sweep: how large can the view/materialised gap get, and is it bounded?
    function test_S10_DivergenceSweep() public {
        uint256[6] memory ds = [uint256(5), 15, 30, 60, 120, 300];
        for (uint256 i = 0; i < ds.length; i++) {
            _fresh();
            _stake(address(0xD1), DECOY, 0, 300e18);
            _stake(address(0xD2), 3, 0, 200e18);
            _stake(address(0xD3), 4, 0, 150e18);
            _stake(address(0xA1), TARGET, 0, 100e18);
            _stake(address(0xBEEF), TARGET, 1, 10e18);
            vm.prank(address(0xD1));
            eng.withdraw(DECOY, 0, 300e18, true);
            vm.prank(address(0xD2));
            eng.withdraw(3, 0, 200e18, true);
            vm.prank(address(0xD3));
            eng.withdraw(4, 0, 150e18, true);

            vm.warp(block.timestamp + ds[i] * 1 days);
            (uint256 vS,) = eng.getPostTotals(TARGET);
            eng.updatePost(TARGET);
            (uint256 mS,) = eng.getPostTotals(TARGET);
            uint256 d = vS > mS ? vS - mS : mS - vS;
            emit log_named_uint("--- warp days", ds[i]);
            emit log_named_uint("  view", vS);
            emit log_named_uint("  materialised", mS);
            emit log_named_uint("  delta bps", mS > 0 ? d * 10000 / mS : 0);
            emit log_named_uint("  view HIGHER? 1=yes", vS > mS ? 1 : 0);
        }
    }
}

