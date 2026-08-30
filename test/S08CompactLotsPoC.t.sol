// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// S-08: compactLots uses swap-and-pop (lines 320-328), whereas
/// _demoteRankedToBucket deliberately SHIFTS survivors to preserve arrival
/// order. Claim: governance calling compactLots reshuffles reward positions,
/// and it never calls _rebalance.
///
/// This test measures the actual effect on honest stakers rather than asserting
/// the reshuffle exists from reading the code.
contract S08CompactLotsPoC is Test {
    StakeEngine eng;
    MockVSP vsp;
    MockProtocolPolicy policy;

    uint256 constant DEPLOY_RATE_MAX = 693805319167998976;
    uint256 constant POST = 1;

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

    function _stake(address who, uint8 side, uint256 amt) internal {
        vsp.mint(who, amt);
        vm.prank(who);
        vsp.approve(address(eng), type(uint256).max);
        vm.prank(who);
        eng.stake(POST, side, amt);
    }

    /// Build: A(first) B C GHOST D E(last). Compact removes the ghost by swapping
    /// E into its slot. Question: does E jump ahead of D in queue position?
    function test_S08_SwapAndPopReordersQueue() public {
        _fresh();
        address a = address(0xA1);
        address b = address(0xB2);
        address c = address(0xC3);
        address ghost = address(0x6057);
        address d = address(0xD4);
        address e = address(0xE5);

        _stake(a, 0, 100e18);
        _stake(b, 0, 100e18);
        _stake(c, 0, 100e18);
        _stake(ghost, 0, 100e18);
        _stake(d, 0, 100e18);
        _stake(e, 0, 100e18);

        // make the ghost: full withdrawal leaves amount == 0 in the array
        vm.prank(ghost);
        eng.withdraw(POST, 0, 100e18, true);

        (, uint256 pA,,,) = eng.getUserLotInfo(a, POST, 0);
        (, uint256 pB,,,) = eng.getUserLotInfo(b, POST, 0);
        (, uint256 pC,,,) = eng.getUserLotInfo(c, POST, 0);
        (, uint256 pD,,,) = eng.getUserLotInfo(d, POST, 0);
        (, uint256 pE,,,) = eng.getUserLotInfo(e, POST, 0);

        emit log("--- positions BEFORE compactLots (arrival order) ---");
        emit log_named_uint("A", pA);
        emit log_named_uint("B", pB);
        emit log_named_uint("C", pC);
        emit log_named_uint("D", pD);
        emit log_named_uint("E", pE);
        assertLt(pD, pE, "sanity: D arrived before E");

        // governance compacts
        eng.compactLots(POST, 0);

        (, uint256 qA,,,) = eng.getUserLotInfo(a, POST, 0);
        (, uint256 qB,,,) = eng.getUserLotInfo(b, POST, 0);
        (, uint256 qC,,,) = eng.getUserLotInfo(c, POST, 0);
        (, uint256 qD,,,) = eng.getUserLotInfo(d, POST, 0);
        (, uint256 qE,,,) = eng.getUserLotInfo(e, POST, 0);

        emit log("--- positions AFTER compactLots ---");
        emit log_named_uint("A", qA);
        emit log_named_uint("B", qB);
        emit log_named_uint("C", qC);
        emit log_named_uint("D", qD);
        emit log_named_uint("E", qE);

        if (qE < qD) {
            emit log("E OVERTOOK D: swap-and-pop reordered the queue");
            emit log_named_uint("E gained (position units)", pE - qE);
            emit log_named_uint("D lost (position units)", qD > pD ? qD - pD : 0);
        } else {
            emit log("order preserved between D and E");
        }

        // Report, do not assume: assert only what the run actually shows.
        assertTrue(qE < qD || qE > qD, "positions comparable");
    }

    /// Quantify: does the reorder change YIELD, or only the reported position?
    function test_S08_YieldImpactOfReorder() public {
        // run 1: compact, then settle
        _fresh();
        address[6] memory who =
            [address(0xA1), address(0xB2), address(0xC3), address(0x6057), address(0xD4), address(0xE5)];
        for (uint256 i = 0; i < who.length; i++) {
            _stake(who[i], 0, 100e18);
        }
        _stake(address(0xBEEF), 1, 1); // support wins so aligned branch mints
        vm.prank(who[3]);
        eng.withdraw(POST, 0, 100e18, true);
        eng.compactLots(POST, 0);
        vm.warp(block.timestamp + 30 days);
        eng.updatePost(POST);
        uint256 dCompact = eng.getUserStake(who[4], POST, 0);
        uint256 eCompact = eng.getUserStake(who[5], POST, 0);

        // run 2: identical, but NO compact
        _fresh();
        for (uint256 i = 0; i < who.length; i++) {
            _stake(who[i], 0, 100e18);
        }
        _stake(address(0xBEEF), 1, 1);
        vm.prank(who[3]);
        eng.withdraw(POST, 0, 100e18, true);
        vm.warp(block.timestamp + 30 days);
        eng.updatePost(POST);
        uint256 dPlain = eng.getUserStake(who[4], POST, 0);
        uint256 ePlain = eng.getUserStake(who[5], POST, 0);

        emit log("--- D and E final stake, WITH compact vs WITHOUT ---");
        emit log_named_uint("D with compact", dCompact);
        emit log_named_uint("D without", dPlain);
        emit log_named_uint("E with compact", eCompact);
        emit log_named_uint("E without", ePlain);

        if (eCompact > ePlain) {
            emit log_named_uint("E gained from compact", eCompact - ePlain);
        }
        if (dPlain > dCompact) {
            emit log_named_uint("D lost from compact", dPlain - dCompact);
        }
    }
}
