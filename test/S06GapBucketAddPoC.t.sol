// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// GAP CHECK on the S-06 Z3 proof.
///
/// The proof only covered _bucketRemove's PARTIAL-exit branch. It did NOT cover
/// _bucketAdd, which computes:
///     shares = (amount * RAY) / _bucketIndex(q);
///     if (prev == 0) _heapInsert(...)
///
/// If ix > amount*RAY then shares == 0, and a member with ZERO shares gets
/// _heapInsert'ed. That is the same bad state S-06 predicted, reached by a
/// different route the proof never modelled.
///
/// ix grows above RAY on the WINNING side: newIx = ix*(RAY+gRay)/RAY.
/// With amount = 1 wei, amount*RAY = 1e18 = RAY, so any ix > RAY zeroes shares.
contract S06GapBucketAddPoC is Test {
    StakeEngine eng;
    MockVSP vsp;
    MockProtocolPolicy policy;

    uint256 constant DEPLOY_RATE_MAX = 693805319167998976;
    uint256 constant POST = 1;
    uint256 constant C = 100;

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

    function test_S06Gap_ZeroShareBucketAdd() public {
        // Fill ranked so later stakes route to the bucket.
        for (uint256 i = 0; i < C; i++) {
            _stake(address(uint160(0x100000 + i)), 0, 10e18);
        }
        // seed the bucket, then let the SUPPORT side WIN so bucketIndexRay grows > RAY
        _stake(address(0xB001), 0, 5e18);
        _stake(address(0xBEEF), 1, 1); // tiny challenge -> support wins

        vm.warp(block.timestamp + 300 days);
        eng.updatePost(POST);

        // Now a fresh 1-wei bucket entrant: shares = 1*RAY/ix, which is 0 if ix > RAY
        address dust = address(0xD057);
        _stake(dust, 0, 1);

        uint256 recorded = eng.getUserStake(dust, POST, 0);
        emit log_named_uint("dust staker recorded stake (0 = zero-share member)", recorded);

        // Solvency: they paid 1 wei in. If recorded is 0, the wei is stranded.
        (uint256 s, uint256 c) = eng.getPostTotals(POST);
        emit log_named_uint("engine balance", vsp.balanceOf(address(eng)));
        emit log_named_uint("claims", s + c);
        assertGe(vsp.balanceOf(address(eng)), s + c, "solvency");

        // Can they still exit? A zero-share heap member is the S-06 concern.
        if (recorded == 0) {
            emit log("ZERO-SHARE bucket member created via _bucketAdd (proof gap confirmed)");
            // second add: prev is still 0, so _heapInsert runs AGAIN -> duplicate?
            _stake(dust, 0, 1);
            emit log_named_uint("after 2nd 1-wei stake", eng.getUserStake(dust, POST, 0));
            // and a larger add, which should promote them
            _stake(dust, 0, 30e18);
            (uint256 amt2,,,) = eng.getUserLotInfo(dust, POST, 0);
            emit log_named_uint("after 30e18 stake, ranked amount (0 = still bucket)", amt2);
            emit log_named_uint("after 30e18 stake, getUserStake", eng.getUserStake(dust, POST, 0));
        } else {
            emit log("shares were NOT zero; this gap route did not trigger here");
        }

        (uint256 s2, uint256 c2) = eng.getPostTotals(POST);
        assertGe(vsp.balanceOf(address(eng)), s2 + c2, "solvency after churn");
    }
}
