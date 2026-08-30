// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// S-01 CONFIRMED PoC: realistic values + withdrawal proof
contract S01ConfirmedPoC is Test {
    StakeEngine eng;
    MockVSP vsp;
    MockProtocolPolicy policy;
    uint256 constant POST = 42;

    function setUp() public {
        vm.warp(86400 * 1000);
        vsp = new MockVSP();
        policy = new MockProtocolPolicy(0);
        policy.setRates(0, 5e18);
        eng = StakeEngine(
            address(
                new ERC1967Proxy(
                    address(new StakeEngine(address(0))),
                    abi.encodeCall(StakeEngine.initialize, (address(this), address(vsp), address(policy)))
                )
            )
        );
        vsp.mint(address(this), 1e36);
        vsp.approve(address(eng), type(uint256).max);
    }

    function _fund(address who, uint256 amt) internal {
        vsp.mint(who, amt);
        vm.prank(who);
        vsp.approve(address(eng), type(uint256).max);
    }

    function test_S01_Confirmed_RealisticValues() public {
        uint256 rankedAmt = 1e18; // 1 VSP per ranked lot
        uint256 bucketAmt = 1e18; // 1 VSP per bucket member (== ranked, so goes to bucket)

        // 100 ranked lots
        for (uint256 i = 0; i < 100; i++) {
            address r = address(uint160(0x100000 + i));
            _fund(r, rankedAmt);
            vm.prank(r);
            eng.stake(POST, 0, rankedAmt);
        }
        // 900 bucket members (amount <= smallest ranked → bucket)
        for (uint256 i = 0; i < 900; i++) {
            address b = address(uint160(0x200000 + i));
            _fund(b, bucketAmt);
            vm.prank(b);
            eng.stake(POST, 0, bucketAmt);
        }

        // Challenge: 10x support to maximize vRay
        address ch = address(0xBEEF);
        uint256 chAmt = 10000e18;
        _fund(ch, chAmt);
        vm.prank(ch);
        eng.stake(POST, 1, chAmt);

        uint256 balBefore = vsp.balanceOf(address(eng));
        emit log_named_uint("total staked (bal)", balBefore);

        // Warp 250 days — single settlement
        vm.warp(block.timestamp + 250 days);
        eng.updatePost(POST);

        (uint256 s1, uint256 c1) = eng.getPostTotals(POST);
        uint256 balAfter = vsp.balanceOf(address(eng));
        emit log_named_uint("support after", s1);
        emit log_named_uint("challenge after", c1);
        emit log_named_uint("claims", s1 + c1);
        emit log_named_uint("balance", balAfter);

        if (s1 + c1 > balAfter) {
            emit log_named_uint("DEFICIT", s1 + c1 - balAfter);
        }

        // Now try withdrawal by a bucket victim — can they drain more than exists?
        address victim = address(uint160(0x200000 + 500));
        uint256 victimStake = eng.getUserStake(victim, POST, 0);
        emit log_named_uint("victim claimable", victimStake);

        if (victimStake > 0) {
            vm.prank(victim);
            eng.withdraw(POST, 0, victimStake, true);
            uint256 victimBal = vsp.balanceOf(victim);
            emit log_named_uint("victim withdrew", victimBal);
        }

        // Final solvency check
        (uint256 s2, uint256 c2) = eng.getPostTotals(POST);
        uint256 balFinal = vsp.balanceOf(address(eng));
        emit log_named_uint("final claims", s2 + c2);
        emit log_named_uint("final balance", balFinal);

        if (s2 + c2 > balFinal) {
            emit log_named_uint("FINAL DEFICIT", s2 + c2 - balFinal);
        }

        // patch_prC_rulings_p2: REGRESSION FORM. The honest bucket-index init
        // + 1-wei settlement floor make the 0->RAY resurrection impossible, so
        // the engine must remain solvent at every checkpoint of this scenario.
        assertGe(balAfter, s1 + c1, "S-01 regression: insolvent after first settlement");
        assertGe(balFinal, s2 + c2, "S-01 regression: insolvent after victim exit");
    }
}
