// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// S-02 VALIDATION — differential test.
/// Question: is the attacker's advantage caused by the GHOST, or is it just
/// "whoever is early in the array wins", which would be intended design?
///
/// Scenario A (ghost):    attacker dust-stakes FIRST, exits, restakes big later.
/// Scenario B (no ghost): same attacker address does NOTHING first, just stakes
///                        big at the same later moment.
/// Everything else identical. If A >> B, the ghost is the cause.
///
/// Also compares against the EARLIEST honest staker, not just the last one,
/// which is the strictest fair benchmark.
contract S02ValidationPoC is Test {
    MockVSP vsp;
    MockProtocolPolicy policy;
    uint256 constant POST = 7;
    uint256 constant DEPLOY_RATE_MAX = 693805319167998976;
    uint256 constant BIG = 1000e18;

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

    /// Runs the scenario. useGhost = whether the attacker pre-stakes dust and exits.
    /// Returns attacker position/gain and the EARLIEST honest staker's position/gain.
    function _scenario(bool useGhost) internal returns (uint256 aPos, uint256 aGain, uint256 hPos, uint256 hGain) {
        vm.warp(86400 * 1000);
        StakeEngine eng = _build();

        if (useGhost) {
            _fund(eng, attacker, 1);
            vm.prank(attacker);
            eng.stake(POST, 0, 1);
            vm.prank(attacker);
            eng.withdraw(POST, 0, 1, true);
        }

        // first honest staker — the strictest benchmark: genuinely earliest real capital
        address h0 = address(uint160(0x5000));
        _fund(eng, h0, BIG);
        vm.prank(h0);
        eng.stake(POST, 0, BIG);

        for (uint256 i = 1; i < 10; i++) {
            address h = address(uint160(0x5000 + i));
            _fund(eng, h, BIG);
            vm.prank(h);
            eng.stake(POST, 0, BIG);
        }

        // attacker stakes big now (revives ghost in scenario A, fresh lot in scenario B)
        _fund(eng, attacker, BIG);
        vm.prank(attacker);
        eng.stake(POST, 0, BIG);

        (, aPos,,) = eng.getUserLotInfo(attacker, POST, 0);
        (, hPos,,) = eng.getUserLotInfo(h0, POST, 0);

        // make support win so the aligned branch mints
        address chal = address(0xBEEF);
        _fund(eng, chal, 1);
        vm.prank(chal);
        eng.stake(POST, 1, 1);

        vm.warp(block.timestamp + 30 days);
        eng.updatePost(POST);

        aGain = eng.getUserStake(attacker, POST, 0) - BIG;
        hGain = eng.getUserStake(h0, POST, 0) - BIG;
    }

    function test_S02_Differential() public {
        (uint256 aPosG, uint256 aGainG, uint256 hPosG, uint256 hGainG) = _scenario(true);
        emit log("--- Scenario A: WITH ghost ---");
        emit log_named_uint("attacker wPos", aPosG);
        emit log_named_uint("earliest honest wPos", hPosG);
        emit log_named_uint("attacker gain", aGainG);
        emit log_named_uint("earliest honest gain", hGainG);

        (uint256 aPosN, uint256 aGainN, uint256 hPosN, uint256 hGainN) = _scenario(false);
        emit log("--- Scenario B: NO ghost (same address, no pre-stake) ---");
        emit log_named_uint("attacker wPos", aPosN);
        emit log_named_uint("earliest honest wPos", hPosN);
        emit log_named_uint("attacker gain", aGainN);
        emit log_named_uint("earliest honest gain", hGainN);

        emit log("--- Delta attributable to the ghost ---");
        emit log_named_uint("gain WITH ghost", aGainG);
        emit log_named_uint("gain WITHOUT ghost", aGainN);
        if (aGainN > 0) {
            emit log_named_uint("ghost advantage (bps)", aGainG * 10000 / aGainN);
        }

        // patch_prA_s02_regression: with the S-02 v2 fix, ghost re-entry must be
        // indistinguishable from fresh entry (demonstration form preserved in the
        // reviewer artifacts archive verisphere-artifacts-58971c05.zip).
        assertEq(aGainG, aGainN, "S-02 regression: ghost re-entry gains exactly a fresh entry's yield");
        assertEq(aPosG, aPosN, "S-02 regression: ghost re-entry lands at the fresh-entry queue position");
        assertEq(hGainG, hGainN, "S-02 regression: honest stakers unaffected by the ghost path");
    }
}
