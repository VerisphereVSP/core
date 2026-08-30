// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// S-01 reachability against REAL deploy parameters.
/// Deploy.s.sol line 86: rateMax = 693805319167998976 (~0.6938e18, 100% APY)
/// vs the 5e18 hard cap used in the first CONFIRMED PoC.
contract S01DeployParams is Test {
    MockVSP vsp;
    MockProtocolPolicy policy;
    uint256 constant POST = 42;
    uint256 constant DEPLOY_RATE_MAX = 693805319167998976;
    uint256 constant CAP_RATE_MAX = 5e18;

    function _build(uint256 rateMax) internal returns (StakeEngine eng) {
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
        vsp.mint(address(this), 1e36);
        vsp.approve(address(eng), type(uint256).max);
    }

    function _fund(StakeEngine eng, address who, uint256 amt) internal {
        vsp.mint(who, amt);
        vm.prank(who);
        vsp.approve(address(eng), type(uint256).max);
    }

    /// Returns deficit (claims - balance) for a given rate and dormancy.
    function _run(uint256 rateMax, uint256 days_) internal returns (uint256 deficit, uint256 support) {
        vm.warp(86400 * 1000);
        StakeEngine eng = _build(rateMax);

        for (uint256 i = 0; i < 100; i++) {
            address r = address(uint160(0x100000 + i));
            _fund(eng, r, 1e18);
            vm.prank(r);
            eng.stake(POST, 0, 1e18);
        }
        for (uint256 i = 0; i < 900; i++) {
            address b = address(uint160(0x200000 + i));
            _fund(eng, b, 1e18);
            vm.prank(b);
            eng.stake(POST, 0, 1e18);
        }
        address ch = address(0xBEEF);
        _fund(eng, ch, 10000e18);
        vm.prank(ch);
        eng.stake(POST, 1, 10000e18);

        vm.warp(block.timestamp + days_ * 1 days);
        eng.updatePost(POST);

        (uint256 s, uint256 c) = eng.getPostTotals(POST);
        uint256 bal = vsp.balanceOf(address(eng));
        support = s;
        deficit = (s + c) > bal ? (s + c) - bal : 0;
    }

    function test_A_capRate_250d() public {
        (uint256 d, uint256 s) = _run(CAP_RATE_MAX, 250);
        emit log_named_uint("[cap 5e18 / 250d] support", s);
        emit log_named_uint("[cap 5e18 / 250d] deficit", d);
    }

    function test_B_deployRate_250d() public {
        (uint256 d, uint256 s) = _run(DEPLOY_RATE_MAX, 250);
        emit log_named_uint("[deploy 0.69e18 / 250d] support", s);
        emit log_named_uint("[deploy 0.69e18 / 250d] deficit", d);
    }

    function test_C_deployRate_1100d() public {
        (uint256 d, uint256 s) = _run(DEPLOY_RATE_MAX, 1100);
        emit log_named_uint("[deploy 0.69e18 / 1100d] support", s);
        emit log_named_uint("[deploy 0.69e18 / 1100d] deficit", d);
    }

    function test_D_deployRate_1500d() public {
        (uint256 d, uint256 s) = _run(DEPLOY_RATE_MAX, 1500);
        emit log_named_uint("[deploy 0.69e18 / 1500d] support", s);
        emit log_named_uint("[deploy 0.69e18 / 1500d] deficit", d);
    }

    function test_E_1250d() public {
        (uint256 def,) = _run(DEPLOY_RATE_MAX, 1250);
        emit log_named_uint("deficit@1250d", def);
    }

    function test_E_1300d() public {
        (uint256 def,) = _run(DEPLOY_RATE_MAX, 1300);
        emit log_named_uint("deficit@1300d", def);
    }

    function test_E_1350d() public {
        (uint256 def,) = _run(DEPLOY_RATE_MAX, 1350);
        emit log_named_uint("deficit@1350d", def);
    }

    function test_E_1400d() public {
        (uint256 def,) = _run(DEPLOY_RATE_MAX, 1400);
        emit log_named_uint("deficit@1400d", def);
    }

    function test_E_1450d() public {
        (uint256 def,) = _run(DEPLOY_RATE_MAX, 1450);
        emit log_named_uint("deficit@1450d", def);
    }
}

