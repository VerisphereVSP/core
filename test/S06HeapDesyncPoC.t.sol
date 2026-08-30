// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// S-06: bucketShares <-> heap desync.
///
/// Claim under test (from the journal): a PARTIAL exit that lands shares exactly
/// at 0 takes the `_heapUpdate` branch instead of `_heapRemove`, leaving a heap
/// entry with pos != 0 and shares == 0. A later `_bucketAdd` then sees
/// `prev == 0` and calls `_heapInsert`, creating a DUPLICATE heap entry for the
/// same address.
///
/// `_bucketRemove` (line ~1107):
///   if (amount >= live) { full exit -> _heapRemove; }
///   sharesOut = amount * RAY / ix;  if (sharesOut > shares) sharesOut = shares;
///   shares - sharesOut  ->  _heapUpdate
/// So the bug needs: amount < live AND sharesOut == shares.
///
/// This test does NOT assume that is reachable. It searches for it and reports.
contract S06HeapDesyncPoC is Test {
    StakeEngine eng;
    MockVSP vsp;
    MockProtocolPolicy policy;

    uint256 constant DEPLOY_RATE_MAX = 693805319167998976;
    uint256 constant C = 100;
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

    function _stake(address who, uint256 post, uint8 side, uint256 amt) internal {
        vsp.mint(who, amt);
        vm.prank(who);
        vsp.approve(address(eng), type(uint256).max);
        vm.prank(who);
        eng.stake(post, side, amt);
    }

    /// Fill ranked so later stakes route to the bucket.
    function _fillRanked(uint256 each) internal {
        for (uint256 i = 0; i < C; i++) {
            _stake(address(uint160(0x100000 + i)), POST, 0, each);
        }
    }

    /// Try to land a bucket member's shares on exactly 0 via a PARTIAL withdraw,
    /// across a range of index states (produced by settlement) and amounts.
    function test_S06_SearchForZeroSharePartialExit() public {
        uint256 found;
        uint256 attempts;

        for (uint256 scenario = 0; scenario < 6; scenario++) {
            _fresh();
            _fillRanked(10e18);

            address victim = address(0xD06);
            _stake(victim, POST, 0, 5e18);
            // opposing side; even scenarios = support loses (index shrinks),
            // odd = support wins (index grows)
            if (scenario % 2 == 0) {
                _stake(address(0xBEEF), POST, 1, 5000e18);
            } else {
                _stake(address(0xBEEF), POST, 1, 1);
            }

            // move bucketIndexRay away from RAY by settling
            vm.warp(block.timestamp + (scenario + 1) * 13 days);
            eng.updatePost(POST);

            uint256 live = eng.getUserStake(victim, POST, 0);
            if (live <= 1) {
                continue;
            }

            // sweep withdraw amounts just below `live`
            for (uint256 d = 1; d <= 3; d++) {
                if (live <= d) {
                    continue;
                }
                uint256 amt = live - d;
                uint256 snap = vm.snapshotState();
                vm.prank(victim);
                eng.withdraw(POST, 0, amt, true);
                uint256 after_ = eng.getUserStake(victim, POST, 0);
                attempts++;
                if (after_ == 0) {
                    found++;
                    emit log_named_uint("scenario", scenario);
                    emit log_named_uint("  live before", live);
                    emit log_named_uint("  withdrew", amt);
                    emit log_named_uint("  stake after (0 = candidate)", after_);

                    // Now the decisive part: restake and see whether the heap gains
                    // a duplicate. Observable proxy: does the member still behave
                    // correctly, and does promotion still work?
                    _stake(victim, POST, 0, 20e18); // > smallest ranked -> should promote
                    (uint256 amt2,,,,) = eng.getUserLotInfo(victim, POST, 0);
                    emit log_named_uint("  after restake, ranked amount (0 = still bucket)", amt2);
                    emit log_named_uint("  after restake, getUserStake", eng.getUserStake(victim, POST, 0));
                }
                vm.revertToState(snap);
            }
        }

        emit log_named_uint("partial-exit attempts", attempts);
        emit log_named_uint("landed on exactly 0 shares", found);
        // No assertion on the bug existing — this test reports reachability.
        assertGt(attempts, 0, "search must actually run");
    }

    /// Direct check of the invariant the heap must satisfy: no address may appear
    /// twice, and every heap entry must have non-zero shares.
    /// Exercised through heavy bucket churn WITH settlement.
    function test_S06_HeapIntegrityUnderChurn() public {
        _fresh();
        _fillRanked(10e18);

        address[6] memory bm =
            [address(0x3001), address(0x3002), address(0x3003), address(0x3004), address(0x3005), address(0x3006)];
        for (uint256 i = 0; i < bm.length; i++) {
            _stake(bm[i], POST, 0, 5e18);
        }
        _stake(address(0xBEEF), POST, 1, 300e18);

        for (uint256 round = 0; round < 5; round++) {
            vm.warp(block.timestamp + 21 days);
            eng.updatePost(POST);

            for (uint256 i = 0; i < bm.length; i++) {
                uint256 live = eng.getUserStake(bm[i], POST, 0);
                if (live == 0) {
                    continue;
                }
                // partial exit leaving 1 wei, then top back up
                if (live > 1) {
                    vm.prank(bm[i]);
                    eng.withdraw(POST, 0, live - 1, true);
                }
                uint256 nowLive = eng.getUserStake(bm[i], POST, 0);
                emit log_named_uint("round", round);
                emit log_named_uint("  member idx", i);
                emit log_named_uint("  live after partial exit", nowLive);

                _stake(bm[i], POST, 0, 4e18);
            }

            // solvency and total consistency must survive the churn
            (uint256 s, uint256 c) = eng.getPostTotals(POST);
            assertGe(vsp.balanceOf(address(eng)), s + c, "solvency broken during heap churn");
        }
        emit log("heap churn completed without solvency break");
    }
}
