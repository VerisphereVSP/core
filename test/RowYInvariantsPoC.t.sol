// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// ROW Y — direct tests of the invariants stated in ECONOMIC_INVARIANTS.md.
/// Every test here is derived from a quoted line of that document, and runs
/// WITH epoch settlement (the gap their ProtocolInvariants suite leaves open,
/// since its handler has no warp action).
///
/// All tests use the REAL deploy rate from script/Deploy.s.sol:86.
contract RowYInvariantsPoC is Test {
    StakeEngine eng;
    MockVSP vsp;
    MockProtocolPolicy policy;

    uint256 constant DEPLOY_RATE_MAX = 693805319167998976;
    uint256 constant RAY = 1e18;
    uint256 constant C = 100; // MAX_RANKED_LOTS

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

    // ─────────────────────────────────────────────────────────────
    // I.1 "VSP.balanceOf(StakeEngine) == TotalStakedAllPosts"
    // Tested ACROSS SETTLEMENT, which their suite never does.
    // ─────────────────────────────────────────────────────────────
    function test_I1_SolvencyAcrossSettlement() public {
        _fresh();
        uint256[3] memory postIds = [uint256(1), 2, 3];

        // three posts, mixed sides, uneven sizes
        _stake(address(0xA1), 1, 0, 500e18);
        _stake(address(0xA2), 1, 1, 300e18);
        _stake(address(0xB1), 2, 0, 120e18);
        _stake(address(0xB2), 2, 1, 700e18);
        _stake(address(0xC1), 3, 0, 90e18);
        _stake(address(0xC2), 3, 1, 90e18);

        for (uint256 round = 0; round < 6; round++) {
            vm.warp(block.timestamp + 17 days);
            for (uint256 i = 0; i < postIds.length; i++) {
                eng.updatePost(postIds[i]);
            }

            uint256 sum;
            for (uint256 i = 0; i < postIds.length; i++) {
                sum += _total(postIds[i]);
            }
            uint256 bal = vsp.balanceOf(address(eng));
            emit log_named_uint("round", round);
            emit log_named_uint("  sum of post totals", sum);
            emit log_named_uint("  engine balance", bal);
            assertGe(bal, sum, "I.1 VIOLATED: engine balance below sum of post totals");
        }
    }

    // ─────────────────────────────────────────────────────────────
    // I.2 "loss = min(delta, L.amount)" -> no lot underflows
    // ─────────────────────────────────────────────────────────────
    function test_I2_LimitedLiabilityUnderExtremeLoss() public {
        _fresh();
        address small = address(0x5A11);
        _stake(small, 1, 0, 1e18);
        _stake(address(0xB16), 1, 1, 10_000_000e18); // MAX_STAKE_AMOUNT

        for (uint256 i = 0; i < 40; i++) {
            vm.warp(block.timestamp + 30 days);
            eng.updatePost(1);
            uint256 pos = eng.getUserStake(small, 1, 0);
            assertLe(pos, 1e18, "I.2: losing lot grew");
        }
        emit log_named_uint("small lot after 40 x 30d of losing", eng.getUserStake(small, 1, 0));
        // withdrawal must still not revert or over-pay
        uint256 remaining = eng.getUserStake(small, 1, 0);
        if (remaining > 0) {
            vm.prank(small);
            eng.withdraw(1, 0, remaining, true);
            assertEq(vsp.balanceOf(small), remaining, "I.2: payout != recorded position");
        }
    }

    // ─────────────────────────────────────────────────────────────
    // I.3 "If T == 0 then no minting or burning occurs"
    //     and VS == 0 must be economically neutral.
    // ─────────────────────────────────────────────────────────────
    function test_I3_NoMintOnNeutralOrEmpty() public {
        _fresh();
        // empty post
        uint256 supplyBefore = vsp.totalSupply();
        vm.warp(block.timestamp + 100 days);
        eng.updatePost(99);
        assertEq(vsp.totalSupply(), supplyBefore, "I.3: minted on an empty post");

        // perfectly balanced post -> VS == 0
        _stake(address(0xE1), 5, 0, 250e18);
        _stake(address(0xE2), 5, 1, 250e18);
        uint256 s2 = vsp.totalSupply();
        uint256 t2 = _total(5);
        vm.warp(block.timestamp + 60 days);
        eng.updatePost(5);
        emit log_named_uint("supply delta on balanced post", vsp.totalSupply() - s2);
        emit log_named_uint("total delta on balanced post", _total(5) - t2);
        assertEq(vsp.totalSupply(), s2, "I.3: minted on a VS-neutral post");
    }

    // ─────────────────────────────────────────────────────────────
    // I.6 "After every snapshot, max(weightedPosition) < sideTotal"
    // ─────────────────────────────────────────────────────────────
    function test_I6_PositionsBoundedAfterSnapshot() public {
        _fresh();
        for (uint256 i = 0; i < 12; i++) {
            _stake(address(uint160(0x7000 + i)), 1, 0, (i + 1) * 10e18);
        }
        _stake(address(0xBEEF), 1, 1, 5e18);

        for (uint256 round = 0; round < 5; round++) {
            vm.warp(block.timestamp + 25 days);
            eng.updatePost(1);
            (uint256 sideTotal,) = eng.getPostTotals(1);
            for (uint256 i = 0; i < 12; i++) {
                (uint256 amt, uint256 wPos,,,) = eng.getUserLotInfo(address(uint160(0x7000 + i)), 1, 0);
                if (amt == 0) {
                    continue;
                }
                assertLt(wPos, sideTotal, "I.6 VIOLATED: weightedPosition >= sideTotal");
            }
        }
        emit log("I.6 held across 5 settlements");
    }

    // ─────────────────────────────────────────────────────────────
    // I.7 "Ranked members still earn strictly more than bucket members"
    //     and "bucket members earn the same uniform rate regardless of
    //     arrival order within the bucket"
    // ─────────────────────────────────────────────────────────────
    function test_I7_RankedBeatsBucket_AndBucketIsUniform() public {
        _fresh();
        // fill ranked with equal lots so the comparison is clean
        for (uint256 i = 0; i < C; i++) {
            _stake(address(uint160(0x100000 + i)), 1, 0, 10e18);
        }
        // three bucket members, equal size, different arrival order
        address b1 = address(0x2001);
        address b2 = address(0x2002);
        address b3 = address(0x2003);
        _stake(b1, 1, 0, 5e18);
        _stake(b2, 1, 0, 5e18);
        _stake(b3, 1, 0, 5e18);

        _stake(address(0xBEEF), 1, 1, 1);

        uint256 rankedBefore = eng.getUserStake(address(uint160(0x100000 + 50)), 1, 0);
        vm.warp(block.timestamp + 30 days);
        eng.updatePost(1);

        uint256 rankedGain = eng.getUserStake(address(uint160(0x100000 + 50)), 1, 0) - rankedBefore;
        uint256 g1 = eng.getUserStake(b1, 1, 0) - 5e18;
        uint256 g2 = eng.getUserStake(b2, 1, 0) - 5e18;
        uint256 g3 = eng.getUserStake(b3, 1, 0) - 5e18;

        emit log_named_uint("ranked lot gain (on 10e18)", rankedGain);
        emit log_named_uint("bucket b1 gain (on 5e18)", g1);
        emit log_named_uint("bucket b2 gain (on 5e18)", g2);
        emit log_named_uint("bucket b3 gain (on 5e18)", g3);

        // uniformity within the bucket
        assertEq(g1, g2, "I.7: bucket members with equal size earn unequally (b1 vs b2)");
        assertEq(g2, g3, "I.7: bucket members with equal size earn unequally (b2 vs b3)");

        // per-unit comparison: ranked must beat bucket
        uint256 rankedPerUnit = rankedGain * RAY / 10e18;
        uint256 bucketPerUnit = g1 * RAY / 5e18;
        emit log_named_uint("ranked gain per unit (RAY)", rankedPerUnit);
        emit log_named_uint("bucket gain per unit (RAY)", bucketPerUnit);
        assertGt(rankedPerUnit, bucketPerUnit, "I.7 VIOLATED: bucket earns >= ranked per unit");
    }

    // ─────────────────────────────────────────────────────────────
    // I.8 "sideTotal == rankedTotal + bucketLive" and a bucket
    //     withdrawal never over-draws the pool.
    // ─────────────────────────────────────────────────────────────
    function test_I8_BucketConservationAndNoOverdraw() public {
        _fresh();
        for (uint256 i = 0; i < C; i++) {
            _stake(address(uint160(0x100000 + i)), 1, 0, 10e18);
        }
        address[5] memory bm = [address(0x3001), address(0x3002), address(0x3003), address(0x3004), address(0x3005)];
        for (uint256 i = 0; i < bm.length; i++) {
            _stake(bm[i], 1, 0, 5e18);
        }
        _stake(address(0xBEEF), 1, 1, 200e18); // support loses, exercises the burn path

        for (uint256 round = 0; round < 4; round++) {
            vm.warp(block.timestamp + 40 days);
            eng.updatePost(1);

            // every bucket member exits fully; must never be paid more than recorded
            for (uint256 i = 0; i < bm.length; i++) {
                uint256 rec = eng.getUserStake(bm[i], 1, 0);
                if (rec == 0) {
                    continue;
                }
                uint256 balBefore = vsp.balanceOf(bm[i]);
                vm.prank(bm[i]);
                eng.withdraw(1, 0, rec, true);
                uint256 paid = vsp.balanceOf(bm[i]) - balBefore;
                assertLe(paid, rec, "I.8 VIOLATED: bucket withdrawal over-paid");
                // re-enter for the next round
                if (paid > 0) {
                    vm.prank(bm[i]);
                    eng.stake(1, 0, paid);
                }
            }
            // solvency must still hold after all that churn
            assertGe(vsp.balanceOf(address(eng)), _total(1), "I.8/I.1 VIOLATED after bucket churn");
            emit log_named_uint("round ok, side total", _total(1));
        }
    }
}
