// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";

import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Whitepaper conformance (audit 2026-09-24)
/// @notice One test per mathematical pronouncement of whitepaper v16.2 (P-numbers from
///         the audit map). Every expected value below is computed from the WHITEPAPER's
///         formula, in the test, never read back from the contract. A failure here is a
///         spec/code gap, not a test bug.
contract WhitepaperConformanceTest is Test {
    uint256 constant RAY = 1e18;
    uint256 constant FEE = 1e18; // 1 VSP, as on mainnet
    uint256 constant EPOCH = 1 days;
    uint256 constant YEAR = 365 days;
    uint256 constant R_MAX = 50e16; // MockProtocolPolicy default: 50% annual, rMin 0

    PostRegistry registry;
    StakeEngine se;
    LinkGraph graph;
    ScoreEngine score;
    MockVSP vsp;
    MockProtocolPolicy policy;

    address A = address(0xA11CE);
    address B = address(0xB0B);
    address C = address(0xCA51);

    function setUp() public {
        vsp = new MockVSP();
        policy = new MockProtocolPolicy(FEE);
        registry = PostRegistry(
            address(
                new ERC1967Proxy(
                    address(new PostRegistry(address(0))),
                    abi.encodeCall(PostRegistry.initialize, (address(this), address(vsp), address(policy)))
                )
            )
        );
        graph = LinkGraph(
            address(
                new ERC1967Proxy(
                    address(new LinkGraph(address(0))), abi.encodeCall(LinkGraph.initialize, (address(this)))
                )
            )
        );
        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));
        se = StakeEngine(
            address(
                new ERC1967Proxy(
                    address(new StakeEngine(address(0))),
                    abi.encodeCall(StakeEngine.initialize, (address(this), address(vsp), address(policy)))
                )
            )
        );
        score = ScoreEngine(
            address(
                new ERC1967Proxy(
                    address(new ScoreEngine(address(0))),
                    abi.encodeCall(
                        ScoreEngine.initialize,
                        (
                            address(this),
                            address(registry),
                            address(se),
                            address(graph),
                            address(policy),
                            address(policy)
                        )
                    )
                )
            )
        );
        address[4] memory who = [address(this), A, B, C];
        for (uint256 i = 0; i < 4; i++) {
            vsp.mint(who[i], 1_000_000e18);
            vm.startPrank(who[i]);
            vsp.approve(address(registry), type(uint256).max);
            vsp.approve(address(se), type(uint256).max);
            vm.stopPrank();
        }
        // start exactly on an epoch boundary so entry == window start (no proration unless a test wants it)
        vm.warp(((block.timestamp / EPOCH) + 2) * EPOCH);
    }

    // ── helpers (whitepaper arithmetic) ─────────────────────────────────────
    function _claim(string memory t) internal returns (uint256) {
        return registry.createClaim(t);
    }

    function _stake(address u, uint256 pid, uint8 side, uint256 amt) internal {
        vm.prank(u);
        se.stake(pid, side, amt);
    }

    /// rMax scaled from annual to `epochs` (P13)
    function _rMaxE(uint256 epochs) internal pure returns (uint256) {
        return (R_MAX * EPOCH * epochs) / YEAR;
    }

    /// rBase = rMin + (rMax - rMin) * verity * participation   (P10, P11, P13)
    function _rBase(uint256 A_, uint256 D_, uint256 sMax_, uint256 epochs) internal pure returns (uint256) {
        uint256 T = A_ + D_;
        uint256 diff = A_ > D_ ? A_ - D_ : D_ - A_; // |2A - T| == |A - D|
        uint256 verity = (diff * RAY) / T;
        uint256 part = (T * RAY) / sMax_;
        return (_rMaxE(epochs) * verity * part) / (RAY * RAY);
    }

    /// delta = amount * rBase * positionWeight / RAY  (P14), positionWeight = 1 - wp/sideTotal (P12)
    function _delta(uint256 amount, uint256 rBase, uint256 wp, uint256 sideTotal) internal pure returns (uint256) {
        uint256 pw = ((sideTotal - wp) * RAY) / sideTotal;
        return Math.mulDiv(amount * rBase, pw, RAY * RAY);
    }

    function _nextEpoch() internal {
        vm.warp(block.timestamp + EPOCH);
    }

    // ═════════════════════════════ §2 rules ═════════════════════════════

    /// P2: dedupe = lowercase ASCII + collapse whitespace + trim
    function test_P2_ClaimDedupeNormalization() public {
        uint256 id = _claim("The  Earth   is ROUND ");
        vm.expectRevert(abi.encodeWithSelector(PostRegistry.DuplicateClaim.selector, id));
        _claim("the earth is round");
    }

    /// P3: duplicate (from,to,flag) rejected; opposite flag allowed; self-loop rejected
    function test_P3_LinkRules() public {
        uint256 a = _claim("a");
        uint256 b = _claim("b");
        registry.createLink(a, b, true);
        vm.expectRevert(); // DuplicateLink / DuplicateEdge
        registry.createLink(a, b, true);
        registry.createLink(a, b, false); // same pair, other polarity: allowed (P5 discussion)
        vm.expectRevert(); // SelfLoop
        registry.createLink(a, a, false);
    }

    /// P4: posting fee is burned (supply falls by exactly the fee; nobody receives it)
    function test_P4_FeeIsBurned() public {
        uint256 s0 = vsp.totalSupply();
        uint256 r0 = vsp.balanceOf(address(registry));
        uint256 a = _claim("fee a");
        uint256 b = _claim("fee b");
        assertEq(s0 - vsp.totalSupply(), 2 * FEE, "two claims burn two fees");
        registry.createLink(a, b, false);
        assertEq(s0 - vsp.totalSupply(), 3 * FEE, "a link burns a fee too");
        assertEq(vsp.balanceOf(address(registry)), r0, "registry keeps nothing");
    }

    // ═════════════════════════════ §3.1 positions ═════════════════════════════

    /// P5: one side per user per post
    function test_P5_OneSidePerUser() public {
        uint256 p = _claim("p5");
        _stake(A, p, 0, 5e18);
        vm.prank(A);
        vm.expectRevert(StakeEngine.OppositeSideStaked.selector);
        se.stake(p, 1, 1e18);
    }

    /// P7 + P12: wp = cumBefore + amount/2; positionWeight = 1 - wp/sideTotal
    function test_P7_P12_MidpointPositions() public {
        uint256 p = _claim("p7");
        _stake(A, p, 0, 10e18);
        _stake(B, p, 0, 6e18);
        (uint256 amtA, uint256 wpA, uint256 totA, uint256 pwA) = se.getUserLotInfo(A, p, 0);
        (, uint256 wpB,, uint256 pwB) = se.getUserLotInfo(B, p, 0);
        assertEq(amtA, 10e18);
        assertEq(totA, 16e18);
        assertEq(wpA, 5e18, "A: 0 + 10/2");
        assertEq(wpB, 13e18, "B: 10 + 6/2");
        assertEq(pwA, ((16e18 - 5e18) * RAY) / 16e18, "pw A = 11/16");
        assertEq(pwB, ((16e18 - 13e18) * RAY) / 16e18, "pw B = 3/16");
    }

    /// P8: a top-up enters at the tail midpoint; the lot's position becomes the
    /// amount-weighted average of its tranches. A: 1 early, then +99 behind B's 99.
    function test_P8_TopUpDoesNotInheritEarliness() public {
        uint256 p = _claim("p8");
        _stake(A, p, 0, 1e18);
        _stake(B, p, 0, 99e18);
        _stake(A, p, 0, 99e18); // top-up: sideTotal was 100, tail midpoint = 100 + 99/2 = 149.5
        (, uint256 wpA, uint256 tot,) = se.getUserLotInfo(A, p, 0);
        (, uint256 wpB,,) = se.getUserLotInfo(B, p, 0);
        assertEq(tot, 199e18);
        // blended = (1 * 0.5 + 99 * 149.5) / 100 = 148.01
        uint256 blended = (1e18 * 0.5e18 + 99e18 * 149.5e18) / 100e18;
        assertEq(wpA, blended, "A's lot = amount-weighted average of tranche positions (148.01)");
        assertEq(wpB, 100e18 + 99e18 / 2, "B: cumBefore 100 + 99/2 = 149.5");
        assertLt(blended, 149.5e18, "and A's lot sits just ahead of B only by its 1 VSP early tranche");
        assertLe(wpA, tot - 100e18 / 2, "P16 clamp: never behind the tail");
    }

    /// P9: partial withdraw recomputes positions; full withdraw leaves a ghost lot; over-withdraw reverts
    function test_P9_Withdraw() public {
        uint256 p = _claim("p9");
        _stake(A, p, 0, 10e18);
        _stake(B, p, 0, 6e18);
        vm.prank(A);
        se.withdraw(p, 0, 4e18, false);
        (uint256 amtA, uint256 wpA,,) = se.getUserLotInfo(A, p, 0);
        (, uint256 wpB,,) = se.getUserLotInfo(B, p, 0);
        assertEq(amtA, 6e18);
        assertEq(wpA, 3e18, "A: 0 + 6/2");
        assertEq(wpB, 9e18, "B moved forward: 6 + 6/2");
        vm.prank(B);
        vm.expectRevert();
        se.withdraw(p, 0, 7e18, false); // more than balance
        vm.prank(A);
        se.withdraw(p, 0, 6e18, false); // full
        (uint256 amt0,,,) = se.getUserLotInfo(A, p, 0);
        assertEq(amt0, 0, "ghost lot: amount 0");
        (, uint256 wpB2, uint256 tot2,) = se.getUserLotInfo(B, p, 0);
        assertEq(tot2, 6e18);
        assertEq(wpB2, 3e18, "B is now first: 0 + 6/2");
    }

    // ═════════════════════════════ §3.2 rate ═════════════════════════════

    /// P10–P14: one settlement, sole stakers on each side. A=3 support (wins), B=1 challenge.
    /// sMax registers T=4 at settlement so participation = 1; verity = |3-1|/4 = 0.5;
    /// rBase = rMax_e * 0.5; each sole staker has positionWeight 1/2.
    function test_P10_P14_SingleSettlement() public {
        uint256 p = _claim("rate");
        _stake(A, p, 0, 3e18);
        _stake(B, p, 1, 1e18);
        uint256 s0 = vsp.totalSupply();
        _nextEpoch();
        se.updatePost(p);
        uint256 rBase = _rBase(3e18, 1e18, 4e18, 1);
        assertEq(rBase, _rMaxE(1) / 2, "rBase = rMax_e * verity(0.5) * participation(1)");
        uint256 dA = _delta(3e18, rBase, 1.5e18, 3e18); // sole: wp = 3/2, pw = 1/2
        uint256 dB = _delta(1e18, rBase, 0.5e18, 1e18);
        assertEq(se.getUserStake(A, p, 0), 3e18 + dA, "aligned lot accrues delta");
        assertEq(se.getUserStake(B, p, 1), 1e18 - dB, "opposing lot decays delta");
        (uint256 S, uint256 D) = se.getPostTotals(p);
        assertEq(S, 3e18 + dA);
        assertEq(D, 1e18 - dB);
        assertEq(vsp.totalSupply(), s0 + dA - dB, "minted dA, burned dB - nothing else");
        // P17: the code registers T=4 at the START of settlement (participation uses it) and then
        // re-registers the post-settlement total (4 + dA - dB); the paper only describes the first.
        assertEq(se.sMax(), se.settledTotal(p), "P17: sMax = settled total");
        assertEq(se.settledTotal(p), 4e18 + dA - dB);
    }

    /// P10: equal sides → verity 0 → no economic effect at all
    function test_P10_NeutralVSNoEffect() public {
        uint256 p = _claim("neutral");
        _stake(A, p, 0, 2e18);
        _stake(B, p, 1, 2e18);
        uint256 s0 = vsp.totalSupply();
        _nextEpoch();
        se.updatePost(p);
        assertEq(se.getUserStake(A, p, 0), 2e18);
        assertEq(se.getUserStake(B, p, 1), 2e18);
        assertEq(vsp.totalSupply(), s0);
    }

    /// P12: earlier of many earns more; sole staker exactly half of rBase
    function test_P12_PositionWeightOrdering() public {
        uint256 p = _claim("order");
        _stake(A, p, 0, 1e18); // wp 0.5  -> pw 1 - 0.5/4 = 0.875
        _stake(B, p, 0, 3e18); // wp 2.5  -> pw 1 - 2.5/4 = 0.375
        _stake(C, p, 1, 1e18); // challenge, sole: pw 0.5
        _nextEpoch();
        se.updatePost(p);
        uint256 rBase = _rBase(4e18, 1e18, 5e18, 1);
        assertEq(se.getUserStake(A, p, 0), 1e18 + _delta(1e18, rBase, 0.5e18, 4e18));
        assertEq(se.getUserStake(B, p, 0), 3e18 + _delta(3e18, rBase, 2.5e18, 4e18));
        assertEq(se.getUserStake(C, p, 1), 1e18 - _delta(1e18, rBase, 0.5e18, 1e18));
        // per-unit rate: A (earlier) > B (later)
        uint256 rateA = ((se.getUserStake(A, p, 0) - 1e18) * RAY) / 1e18;
        uint256 rateB = ((se.getUserStake(B, p, 0) - 3e18) * RAY) / 3e18;
        assertGt(rateA, rateB, "earlier staker earns a higher rate per unit");
    }

    /// P13: multi-epoch catch-up scales the bounds linearly by epochsElapsed
    function test_P13_MultiEpochScaling() public {
        uint256 p = _claim("multi");
        _stake(A, p, 0, 3e18);
        _stake(B, p, 1, 1e18);
        vm.warp(block.timestamp + 3 * EPOCH);
        se.updatePost(p);
        uint256 rBase = _rBase(3e18, 1e18, 4e18, 3);
        assertEq(se.getUserStake(A, p, 0), 3e18 + _delta(3e18, rBase, 1.5e18, 3e18), "3 epochs = 3x one epoch (linear)");
    }

    /// P15: a lot entering mid-window earns delta * present/window
    function test_P15_Proration() public {
        uint256 p = _claim("prorate");
        _stake(A, p, 0, 3e18);
        _stake(B, p, 1, 1e18);
        vm.warp(block.timestamp + EPOCH / 2);
        _stake(C, p, 0, 1e18); // enters halfway: positions now A wp 1.5, C wp 3.5, side 4
        vm.warp(block.timestamp + EPOCH / 2);
        se.updatePost(p);
        uint256 rBase = _rBase(4e18, 1e18, 5e18, 1);
        uint256 dC = _delta(1e18, rBase, 3.5e18, 4e18);
        assertEq(se.getUserStake(C, p, 0), 1e18 + dC / 2, "half the window present -> half the delta");
        assertEq(se.getUserStake(A, p, 0), 3e18 + _delta(3e18, rBase, 1.5e18, 4e18), "A present all window");
    }

    /// P17a: capital that enters and leaves inside one epoch never registers in sMax
    function test_P17_FlashStakeDoesNotMoveSMax() public {
        uint256 p = _claim("flash");
        _stake(A, p, 0, 100e18);
        vm.prank(A);
        se.withdraw(p, 0, 100e18, false);
        _nextEpoch();
        se.refreshSMax(p);
        assertEq(se.sMax(), 0, "nothing settled, sMax untouched");
    }

    /// P17b: sMax rises immediately to a larger settled total; never snaps down; decays 10%/epoch toward the leader
    function test_P17_SMaxRiseAndDecay() public {
        uint256 small = _claim("small");
        uint256 big = _claim("big");
        _stake(A, small, 0, 4e18);
        _stake(B, big, 0, 10e18);
        _nextEpoch();
        se.updatePost(small);
        assertEq(se.sMax(), se.settledTotal(small), "sMax = small's settled total (4 + accrual)");
        se.updatePost(big); // big's settlement registers 10 (plus its tiny accrual)
        uint256 bigTotal = se.settledTotal(big);
        assertEq(se.sMax(), bigTotal, "rises to the settling post's total");
        // remove the big post's capital; its next settlement registers 0 and small leads with ~4
        (uint256 bAmt,,,) = se.getUserLotInfo(B, big, 0);
        vm.prank(B);
        se.withdraw(big, 0, bAmt, false);
        uint256 peak = se.sMax();
        for (uint256 k = 1; k <= 12; k++) {
            _nextEpoch();
            se.refreshSMax(big);
            se.refreshSMax(small);
            uint256 leader = se.settledTotal(small);
            uint256 decayed = peak;
            for (uint256 i = 0; i < k; i++) {
                decayed = (decayed * 9e17) / RAY;
            }
            uint256 expected = decayed > leader ? decayed : leader;
            assertApproxEqRel(se.sMax(), expected, 1e15, "sMax = max(leader, peak * 0.9^k)");
        }
    }

    // ═════════════════════════════ §4 scoring ═════════════════════════════

    /// P18: baseVS is the WINNING side's share (3 vs 1 -> +75%, not +50%), 0 when equal or empty
    function test_P18_BaseVSWinnerShare() public {
        uint256 p = _claim("base");
        assertEq(score.baseVSRay(p), 0, "T = 0 -> 0");
        _stake(A, p, 0, 3e18);
        _stake(B, p, 1, 1e18);
        assertEq(score.baseVSRay(p), int256((3e18 * RAY) / 4e18), "+A/T = +75%");
        _stake(B, p, 1, 2e18);
        assertEq(score.baseVSRay(p), 0, "A = D -> 0");
        _stake(B, p, 1, 1e18);
        assertEq(score.baseVSRay(p), -int256((4e18 * RAY) / 7e18), "-D/T");
    }

    /// P19: below the activity threshold a parent contributes nothing
    function test_P19_ActivityThreshold() public {
        policy.setMinTotalStake(2e18);
        uint256 parent = _claim("weak parent");
        uint256 child = _claim("child");
        _stake(A, child, 0, 2e18); // child itself active
        uint256 link = registry.createLink(parent, child, true);
        _stake(B, link, 0, 2e18); // links are posts: they must be active too (>= threshold)
        _stake(C, parent, 0, 1e18); // parent T = 1 < threshold 2
        assertEq(score.effectiveVSRay(child), int256(RAY), "inactive parent: child untouched");
        // GAP G2 (spec): the paper says inactive posts don't influence OTHERS; the code also zeroes the
        // inactive post's OWN effective VS (base VS still reads +100%). Documented behaviour, pinned here.
        assertEq(score.baseVSRay(parent), int256(RAY));
        assertEq(score.effectiveVSRay(parent), 0, "G2: inactive claim's own effective VS is 0 in code");
        _stake(C, parent, 0, 2e18); // T = 3 > threshold -> active
        assertLt(score.effectiveVSRay(child), int256(RAY), "active parent now contributes");
    }

    /// P20: credibility gate — a parent at VS <= 0 contributes nothing (double negative must not help)
    function test_P20_CredibilityGate() public {
        uint256 bad = _claim("discredited");
        uint256 target = _claim("target");
        _stake(A, target, 0, 1e18);
        uint256 link = registry.createLink(bad, target, true);
        _stake(B, link, 0, 5e18);
        _stake(C, bad, 1, 5e18); // parent at -100%
        assertEq(score.effectiveVSRay(target), int256(RAY), "discredited challenger contributes 0, not +");
        // and a discredited LINK contributes nothing even from a credible parent
        uint256 good = _claim("credible");
        _stake(A, good, 0, 5e18);
        uint256 link2 = registry.createLink(good, target, true);
        _stake(B, link2, 1, 1e18); // link VS -100%
        assertEq(score.effectiveVSRay(target), int256(RAY), "discredited link is inert");
    }

    /// P21–P23 + P25: contribution = parentVS * parentTotal * linkShare * linkVS; mixed pool
    function test_P21_P25_Contribution() public {
        uint256 parent = _claim("parent");
        uint256 child = _claim("child2");
        _stake(A, child, 0, 2e18);
        _stake(B, parent, 0, 4e18);
        _stake(C, parent, 1, 1e18); // parent: base VS +0.8 (winner share) but EFFECTIVE VS (4-1)/5 = 0.6
        // P21 uses the parent's effective VS: mass = 0.6 * 5 = 3   (not 0.8 * 5)
        uint256 l1 = registry.createLink(parent, child, true);
        uint256 l2 = registry.createLink(parent, child, false);
        _stake(A, l1, 0, 3e18); // share 3/4, link VS +1
        _stake(A, l2, 0, 1e18); // share 1/4
        // contributions: -3*3/4 = -2.25 ; +3*1/4 = +0.75
        // pool: S = 2 + 0.75 = 2.75, C = 0 + 2.25 = 2.25 -> VS = 0.5/5 = +10%
        assertEq(score.effectiveVSRay(child), int256(RAY / 10), "(2.75 - 2.25) / 5 = +10%");
        _stake(A, child, 0, 4e18); // S = 6.75, C = 2.25 -> 4.5/9
        assertEq(score.effectiveVSRay(child), int256(RAY / 2), "+50%");
    }

    /// P28: conservation — three equal links share the parent's mass M/3 each
    function test_P28_Conservation() public {
        uint256 parent = _claim("mass");
        _stake(A, parent, 0, 6e18); // mass 6
        uint256[3] memory kids;
        for (uint256 i = 0; i < 3; i++) {
            kids[i] = _claim(string(abi.encodePacked("kid", i)));
            _stake(B, kids[i], 0, 2e18);
            uint256 l = registry.createLink(parent, kids[i], true);
            _stake(C, l, 0, 1e18);
        }
        // each kid: S = 2, C = 6/3 = 2 -> 0%
        for (uint256 i = 0; i < 3; i++) {
            assertEq(score.effectiveVSRay(kids[i]), 0, "M/3 each");
        }
    }

    /// P27: a cycle contributes 0 along the closing path; the function stays defined
    function test_P27_CycleTerminatesAndZeroes() public {
        uint256 x = _claim("x");
        uint256 y = _claim("y");
        _stake(A, x, 0, 2e18);
        _stake(B, y, 0, 2e18);
        uint256 lx = registry.createLink(x, y, true);
        uint256 ly = registry.createLink(y, x, true);
        _stake(C, lx, 0, 1e18);
        _stake(C, ly, 0, 1e18);
        // VS(y): parent x is computed with y on the stack -> x's incoming from y = 0 -> x = +100%, mass 2
        // y: S = 2, C = 2 -> 0. Symmetric for x.
        assertEq(score.effectiveVSRay(y), 0);
        assertEq(score.effectiveVSRay(x), 0);
    }
}
