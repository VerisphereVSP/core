// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// S-10 VALIDATION. Three ways the finding could be an overclaim:
///
/// V1: is the decayed-topPosts state actually REACHABLE in normal operation, or
///     did the PoC engineer it with three decoy posts that a real deployment
///     would never produce?
/// V2: does the divergence persist, or does it self-correct on the next read
///     after settlement? A gap that vanishes immediately misleads nobody.
/// V3: is the gap really the DECAY path, or just the known rescale rounding that
///     StakeEngineRescale.t.sol already documents at 0.5% tolerance?
contract S10ValidationPoC is Test {
    StakeEngine eng;
    MockVSP vsp;
    MockProtocolPolicy policy;

    uint256 constant DEPLOY_RATE_MAX = 693805319167998976;
    uint256 constant TARGET = 1;

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

    /// V1: the MINIMAL natural case — ONE post, ever. No decoys at all.
    /// A single post that is the leader, then a second post takes over and the
    /// first goes dormant. This is ordinary protocol life, not an engineered state.
    function test_V1_ReachableWithoutDecoys() public {
        _fresh();
        // the only post in the system
        _stake(address(0xA1), TARGET, 0, 100e18);
        _stake(address(0xBEEF), TARGET, 1, 10e18);

        emit log_named_uint("sMax with a single live post", eng.sMax());
        emit log_named_uint("sMaxLastUpdatedEpoch", eng.sMaxLastUpdatedEpoch());

        vm.warp(block.timestamp + 60 days);

        (uint256 vS,) = eng.getPostTotals(TARGET);
        eng.updatePost(TARGET);
        (uint256 mS,) = eng.getPostTotals(TARGET);
        uint256 d = vS > mS ? vS - mS : mS - vS;

        emit log_named_uint("view", vS);
        emit log_named_uint("materialised", mS);
        emit log_named_uint("delta bps", mS > 0 ? d * 10000 / mS : 0);
        emit log("^ if 0, the finding needs decoy posts and V1 weakens it");
    }

    /// V1b: two posts, the realistic case. Post A leads, post B overtakes,
    /// A goes dormant. No withdrawals, nobody unwinds anything.
    function test_V1b_TwoPostsNaturalOvertake() public {
        _fresh();
        _stake(address(0xA1), TARGET, 0, 100e18);
        _stake(address(0xBEEF), TARGET, 1, 10e18);
        // a bigger post appears and becomes the tracked leader
        _stake(address(0xB1), 2, 0, 5000e18);
        _stake(address(0xB2), 2, 1, 500e18);

        emit log_named_uint("sMax (post 2 leads)", eng.sMax());

        vm.warp(block.timestamp + 60 days);
        (uint256 vS,) = eng.getPostTotals(TARGET);
        eng.updatePost(TARGET);
        (uint256 mS,) = eng.getPostTotals(TARGET);
        uint256 d = vS > mS ? vS - mS : mS - vS;

        emit log_named_uint("view", vS);
        emit log_named_uint("materialised", mS);
        emit log_named_uint("delta bps", mS > 0 ? d * 10000 / mS : 0);
    }

    /// V2: does the gap persist after settlement, or self-correct?
    function test_V2_GapPersistsOrSelfCorrects() public {
        _fresh();
        _stake(address(0xD1), 2, 0, 300e18);
        _stake(address(0xD2), 3, 0, 200e18);
        _stake(address(0xD3), 4, 0, 150e18);
        _stake(address(0xA1), TARGET, 0, 100e18);
        _stake(address(0xBEEF), TARGET, 1, 10e18);
        vm.prank(address(0xD1));
        eng.withdraw(2, 0, 300e18, true);
        vm.prank(address(0xD2));
        eng.withdraw(3, 0, 200e18, true);
        vm.prank(address(0xD3));
        eng.withdraw(4, 0, 150e18, true);

        vm.warp(block.timestamp + 60 days);
        (uint256 v1,) = eng.getPostTotals(TARGET);
        eng.updatePost(TARGET);
        (uint256 m1,) = eng.getPostTotals(TARGET);
        emit log_named_uint("view before settle", v1);
        emit log_named_uint("materialised after settle", m1);

        // immediately read again with no time passing
        (uint256 v2,) = eng.getPostTotals(TARGET);
        emit log_named_uint("view immediately after settle", v2);
        assertEq(v2, m1, "V2: view agrees with materialised right after settlement");

        // and after one more day
        vm.warp(block.timestamp + 1 days);
        (uint256 v3,) = eng.getPostTotals(TARGET);
        eng.updatePost(TARGET);
        (uint256 m3,) = eng.getPostTotals(TARGET);
        uint256 d3 = v3 > m3 ? v3 - m3 : m3 - v3;
        emit log_named_uint("view after 1 more day", v3);
        emit log_named_uint("materialised after 1 more day", m3);
        emit log_named_uint("delta bps at 1-day cadence", m3 > 0 ? d3 * 10000 / m3 : 0);
    }
}
