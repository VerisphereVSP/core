// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// S-04: yield suppression via sMax inflation.
/// sMax is GLOBAL. participationRay = T_post * RAY / sMax, so a whale staking
/// large on ONE post raises sMax and shrinks participationRay for EVERY OTHER
/// post, suppressing their rBase and therefore everyone's yield.
///
/// Differential: identical victim post, measured with and without a whale
/// present on an unrelated post. Then measure the whale's own cost.
contract S04YieldSuppressionPoC is Test {
    StakeEngine eng;
    MockVSP vsp;
    MockProtocolPolicy policy;

    uint256 constant DEPLOY_RATE_MAX = 693805319167998976;
    uint256 constant RAY = 1e18;
    uint256 constant VICTIM_POST = 1;
    uint256 constant WHALE_POST = 2;

    address victimA = address(0xA11CE);
    address victimB = address(0xBEEF);
    address whale = address(0xC0FFEE);

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

    function _total(uint256 post) internal view returns (uint256) {
        (uint256 s, uint256 c) = eng.getPostTotals(post);
        return s + c;
    }

    /// whaleAmt == 0 means "no whale" (control run).
    function _run(uint256 whaleAmt) internal returns (uint256 victimGrowth, uint256 sMaxUsed, uint256 whaleGrowth) {
        _fresh();

        // victim post: 100e18 support vs 1 wei challenge, support wins
        _stake(victimA, VICTIM_POST, 0, 100e18);
        _stake(victimB, VICTIM_POST, 1, 1);

        if (whaleAmt > 0) {
            // whale on a COMPLETELY UNRELATED post
            _stake(whale, WHALE_POST, 0, whaleAmt);
            _stake(address(0xDEAD), WHALE_POST, 1, 1);
            // ruling 3b: a post registers in sMax at ITS first settlement
            vm.warp((block.timestamp / 1 days + 1) * 1 days);
            eng.updatePost(WHALE_POST);
            eng.updatePost(VICTIM_POST);
        }

        sMaxUsed = eng.sMax();

        uint256 vBefore = _total(VICTIM_POST);
        uint256 wBefore = whaleAmt > 0 ? _total(WHALE_POST) : 0;

        vm.warp(block.timestamp + 30 days);
        eng.updatePost(VICTIM_POST);
        if (whaleAmt > 0) {
            eng.updatePost(WHALE_POST);
        }

        victimGrowth = _total(VICTIM_POST) - vBefore;
        whaleGrowth = whaleAmt > 0 ? _total(WHALE_POST) - wBefore : 0;
    }

    function test_S04_YieldSuppression() public {
        (uint256 gClean, uint256 sClean,) = _run(0);
        (uint256 gWhale, uint256 sWhale, uint256 whaleGain) = _run(100_000e18);

        emit log("=== victim post: 100e18, identical in both runs ===");
        emit log_named_uint("sMax without whale", sClean);
        emit log_named_uint("victim growth without whale", gClean);
        emit log_named_uint("sMax with 100k whale", sWhale);
        emit log_named_uint("victim growth with whale", gWhale);

        if (gClean > gWhale) {
            emit log_named_uint("victim yield SUPPRESSED by", gClean - gWhale);
            emit log_named_uint("remaining yield (bps of clean)", gWhale * 10000 / gClean);
        }

        emit log("=== whale's own position ===");
        emit log_named_uint("whale post growth", whaleGain);

        assertLt(gWhale, gClean, "S-04: unrelated whale suppresses victim yield");
    }

    /// How cheap is the grief? Sweep whale size against victim suppression.
    function test_S04_CostCurve() public {
        (uint256 gClean,,) = _run(0);
        emit log_named_uint("baseline victim growth", gClean);

        uint256[5] memory sizes = [uint256(1_000e18), 10_000e18, 100_000e18, 1_000_000e18, 10_000_000e18];
        for (uint256 i = 0; i < sizes.length; i++) {
            (uint256 g,, uint256 wg) = _run(sizes[i]);
            emit log_named_uint("--- whale size", sizes[i]);
            emit log_named_uint("victim growth", g);
            emit log_named_uint("victim retains (bps)", gClean > 0 ? g * 10000 / gClean : 0);
            emit log_named_uint("whale own growth", wg);
        }
    }
}
