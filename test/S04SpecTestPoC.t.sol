// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// S-04 SPEC TEST.
///
/// ECONOMIC_INVARIANTS.md I.4, safety statement, lines 62-63:
///   "Decay prevents historical peaks from permanently suppressing
///    participation factors on future posts."
///
/// That is an explicit safety PROMISE about suppression. It has two parts:
/// a HISTORICAL peak, and PERMANENTLY. So the decisive question for S-04 is not
/// "can a live whale suppress" (arguably intended relative-attention design) but:
///
///   Q: can a whale EXIT and leave its peak suppressing everyone else?
///
/// If yes, that is a direct violation of the documented safety statement,
/// because decay is supposed to prevent exactly that.
contract S04SpecTestPoC is Test {
    StakeEngine eng;
    MockVSP vsp;
    MockProtocolPolicy policy;

    uint256 constant DEPLOY_RATE_MAX = 693805319167998976;
    uint256 constant VICTIM = 1;
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

    /// Q1: does a LIVE whale keep suppressing forever, i.e. does decay ever help?
    function test_Q1_LiveWhaleSuppressionIsPermanent() public {
        _fresh();
        _stake(victimA, VICTIM, 0, 100e18);
        _stake(victimB, VICTIM, 1, 1);
        _stake(whale, WHALE_POST, 0, 1_000_000e18);
        _stake(address(0xDEAD), WHALE_POST, 1, 1);

        emit log_named_uint("sMax with live whale", eng.sMax());

        // wait far beyond sMaxDecayMaxEpochs (30) and touch the victim post
        vm.warp(block.timestamp + 365 days);
        eng.updatePost(VICTIM);

        emit log_named_uint("sMax after 365d, whale still staked", eng.sMax());
        emit log_named_uint("victim total", _total(VICTIM));
        // decay only runs when leaderTotal == 0, so a live whale is never decayed away
        assertGe(eng.sMax(), 1_000_000e18, "live whale keeps sMax pinned high indefinitely");
    }

    /// Q2 — THE DECISIVE TEST. Whale exits completely. Does its historical peak
    /// keep suppressing the victim post? Spec lines 62-63 say decay must prevent this.
    function test_Q2_ExitedWhalePeakSuppressesFuturePosts() public {
        // ---- baseline: victim alone, no whale ever ----
        _fresh();
        _stake(victimA, VICTIM, 0, 100e18);
        _stake(victimB, VICTIM, 1, 1);
        uint256 b0 = _total(VICTIM);
        vm.warp(block.timestamp + 30 days);
        eng.updatePost(VICTIM);
        uint256 cleanGrowth = _total(VICTIM) - b0;
        emit log_named_uint("baseline growth (no whale ever)", cleanGrowth);

        // ---- whale stakes, then FULLY EXITS, then victim settles ----
        _fresh();
        _stake(victimA, VICTIM, 0, 100e18);
        _stake(victimB, VICTIM, 1, 1);

        _stake(whale, WHALE_POST, 0, 1_000_000e18);
        emit log_named_uint("sMax while whale staked", eng.sMax());

        vm.prank(whale);
        eng.withdraw(WHALE_POST, 0, 1_000_000e18, true);
        emit log_named_uint("whale post total after exit", _total(WHALE_POST));
        emit log_named_uint("sMax AFTER whale fully exited", eng.sMax());
        emit log_named_uint("victim total (true leader now)", _total(VICTIM));

        uint256 b1 = _total(VICTIM);
        vm.warp(block.timestamp + 30 days);
        eng.updatePost(VICTIM);
        uint256 afterExitGrowth = _total(VICTIM) - b1;

        emit log_named_uint("victim growth after whale exited", afterExitGrowth);
        if (cleanGrowth > afterExitGrowth) {
            emit log_named_uint("STILL SUPPRESSED by", cleanGrowth - afterExitGrowth);
            emit log_named_uint("victim retains (bps of clean)", afterExitGrowth * 10000 / cleanGrowth);
        } else {
            emit log_named_uint("no residual suppression; excess", afterExitGrowth - cleanGrowth);
        }

        // patch_prC_rulings_p2: CHANGED INTENDED BEHAVIOR under S-03 never-snap-down.
        // Pre-PR-C, sMax snapped from the whale's 1e24 peak straight back to the
        // victim's total on exit — which is exactly the mechanism a dust post
        // abused in the other direction. Now the peak persists and DECAYS (10%/
        // epoch, floored at the tracked leader), so an exited whale leaves a
        // BOUNDED, TRANSIENT suppression that anyone can burn down by poking
        // refreshSMax each epoch. Assert the full arc: suppression exists,
        // decay+poke clears it, and the recovered rate matches the clean rate.
        assertLt(afterExitGrowth, cleanGrowth, "transient suppression expected under never-snap-down");

        // burn the peak down: three 30-epoch decay windows (capped per call).
        for (uint256 k = 0; k < 3; k++) {
            // vm.getBlockTimestamp: in-frame block.timestamp reads are cached by
            // the solc 0.8.33 optimizer after first use, so relative warp chains
            // collapse; the cheatcode reads the true env value (fresh frame).
            vm.warp(vm.getBlockTimestamp() + 30 days);
            eng.refreshSMax(VICTIM);
        }
        assertEq(eng.sMax(), _total(VICTIM), "decay floors at the victim once the peak burns off");

        uint256 b2 = _total(VICTIM);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        eng.updatePost(VICTIM);
        uint256 recoveredGrowth = _total(VICTIM) - b2;
        emit log_named_uint("victim growth after peak burned off", recoveredGrowth);
        // rate (growth/base) recovers to the clean rate within 2%
        assertApproxEqRel(
            recoveredGrowth * 1e18 / b2, cleanGrowth * 1e18 / b0, 2e16, "post-decay rate matches the never-whaled rate"
        );
    }
}
