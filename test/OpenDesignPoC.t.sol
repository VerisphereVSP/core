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

/// Independent review PoCs (2026-09-07). Each test is written so that a
/// PASS means the suspected issue is REAL.
contract OpenDesignPoC is Test {
    PostRegistry registry;
    StakeEngine eng;
    LinkGraph graph;
    ScoreEngine score;
    MockVSP vsp;
    MockProtocolPolicy policy;

    uint256 constant DEPLOY_RATE_MAX = 693805319167998976; // as deployed (~100% APY)
    uint256 constant FEE = 1e18;

    address attacker = address(0xA77AC7E2);
    address honest = address(0x40E57);
    address control = address(0xC0147201);

    function setUp() public {
        vm.warp(86400 * 1000);
        vsp = new MockVSP();
        policy = new MockProtocolPolicy(FEE);
        policy.setRates(0, DEPLOY_RATE_MAX);

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
        eng = StakeEngine(
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
                        (address(this), address(registry), address(eng), address(graph), address(policy), address(0))
                    )
                )
            )
        );
        vsp.mint(address(this), 1e30);
        vsp.approve(address(registry), type(uint256).max);
        vsp.approve(address(eng), type(uint256).max);
    }

    function _fund(address who, uint256 amt) internal {
        vsp.mint(who, amt);
        vm.startPrank(who);
        vsp.approve(address(eng), type(uint256).max);
        vsp.approve(address(registry), type(uint256).max);
        vm.stopPrank();
    }

    // ───────────────────────────────────────────────────────────────────
    // H1: StakeEngine accepts stake on postIds that do not exist.
    //     A solo staker on a phantom post earns freshly-minted VSP with no
    //     claim, no posting fee, and nothing for anyone to see in the UI.
    // ───────────────────────────────────────────────────────────────────

    // ── OPEN DESIGN DECISIONS (security review 2026-09) — these PoCs still PASS ──
    // H2 live-dust queue squatting, M1 intra-epoch JIT yield, M2 flash-stake sMax
    // pin are ECONOMIC design questions (whitepaper §3.1/§3.2), not bugs with a
    // single correct patch. They are kept here so the behavior is documented
    // and measurable until the founders rule; invert them when a design lands.
    // Note: this harness deliberately leaves the engine's postRegistry UNSET so
    // the PoCs can stake on synthetic ids; H1's existence check is covered in
    // SecurityRegression.t.sol.
    function test_H2_liveDustSquat_bypassesS02Fix() public {
        uint256 POST = 7; // does not exist in registry yet either
        uint256 big = 1000e18;

        // attacker parks 1 wei FIRST and never leaves (so S-02 ghost logic never triggers)
        _fund(attacker, 1);
        vm.prank(attacker);
        eng.stake(POST, 0, 1);

        // honest stakers arrive with real capital
        for (uint256 i = 0; i < 10; i++) {
            address h = address(uint160(0x5000 + i));
            _fund(h, big);
            vm.prank(h);
            eng.stake(POST, 0, big);
        }

        // attacker tops up; control stakes same amount at same time with no prior dust
        _fund(attacker, big);
        vm.prank(attacker);
        eng.stake(POST, 0, big);
        _fund(control, big);
        vm.prank(control);
        eng.stake(POST, 0, big);

        (uint256 aAmt, uint256 aPos,, uint256 aW) = eng.getUserLotInfo(attacker, POST, 0);
        (uint256 cAmt, uint256 cPos,, uint256 cW) = eng.getUserLotInfo(control, POST, 0);
        (, uint256 h0Pos,, uint256 h0W) = eng.getUserLotInfo(address(0x5000), POST, 0);
        emit log_named_uint("attacker wPos", aPos);
        emit log_named_uint("first honest wPos", h0Pos);
        emit log_named_uint("control wPos", cPos);
        emit log_named_uint("attacker positionWeight", aW);
        emit log_named_uint("first honest positionWeight", h0W);
        emit log_named_uint("control positionWeight", cW);
        assertEq(aAmt, cAmt + 1);
        assertLt(aPos, h0Pos, "H2: attacker is ahead of the FIRST honest capital");
        assertLt(aPos, cPos);

        address chal = address(0xBEEF);
        _fund(chal, 1);
        vm.prank(chal);
        eng.stake(POST, 1, 1);
        vm.warp(block.timestamp + 30 days);
        eng.updatePost(POST);
        uint256 aGain = eng.getUserStake(attacker, POST, 0) - big - 1;
        uint256 cGain = eng.getUserStake(control, POST, 0) - big;
        emit log_named_uint("attacker gain 30d", aGain);
        emit log_named_uint("control gain 30d", cGain);
        emit log_named_uint("ratio bps", aGain * 10000 / cGain);
        assertGt(aGain, cGain, "H2: dust squatter out-earns identical later staker");
    }

    // ───────────────────────────────────────────────────────────────────
    // H3: PostRegistry._exists(0) is true (0 < nextPostId), posts[0] is a
    //     default struct whose contentType == Claim. So a link FROM or TO
    //     post 0 can be created, and the phantom claim 0 can be staked and
    //     will feed ScoreEngine as a parent.
    // ───────────────────────────────────────────────────────────────────
    function test_H4_epochBoundaryJIT_fullDayYieldFor2Seconds() public {
        uint256 POST = 11;
        uint256 big = 1_000_000e18;
        // honest supporter has been in for a long time; minimal challenger so support wins
        _fund(honest, big);
        vm.prank(honest);
        eng.stake(POST, 0, big);
        _fund(control, 1);
        vm.prank(control);
        eng.stake(POST, 1, 1);

        // settle up to now so the honest lot's past is materialised
        vm.warp(block.timestamp + 10 days);
        eng.updatePost(POST);

        // JIT: enter 2 seconds before the next epoch boundary
        uint256 nextBoundary = (block.timestamp / 1 days + 1) * 1 days;
        vm.warp(nextBoundary - 2);
        _fund(attacker, big);
        vm.prank(attacker);
        eng.stake(POST, 0, big);

        // cross boundary, settle, exit
        vm.warp(nextBoundary + 1);
        eng.updatePost(POST);
        uint256 jitValue = eng.getUserStake(attacker, POST, 0);
        vm.prank(attacker);
        eng.withdraw(POST, 0, jitValue, true);
        uint256 jitProfit = vsp.balanceOf(attacker) - big;

        // what the honest lot (same size, present the whole epoch) earned in the same epoch
        uint256 honestAfter = eng.getUserStake(honest, POST, 0);
        emit log_named_uint("JIT profit for 3s exposure (wei)", jitProfit);
        emit log_named_uint("JIT profit in VSP", jitProfit / 1e18);
        assertGt(jitProfit, 0, "H4: 3-second exposure earned a full epoch of minted yield");
        emit log_named_uint("honest lot value after", honestAfter);
    }

    // ───────────────────────────────────────────────────────────────────
    // H5: Flash sMax inflation. stake() then withdraw() in the same block
    //     leaves sMax pinned at the whale amount (never snaps down), which
    //     scales down EVERY other post's participationRay for weeks.
    // ───────────────────────────────────────────────────────────────────
    function test_H5_flashStake_pinsGlobalSMax() public {
        uint256 realPost = 5;
        uint256 phantom = 999_999;
        uint256 honestAmt = 10_000e18;

        _fund(honest, honestAmt);
        vm.prank(honest);
        eng.stake(realPost, 0, honestAmt);
        _fund(control, 1);
        vm.prank(control);
        eng.stake(realPost, 1, 1);
        uint256 sMaxBefore = eng.sMax();

        // Baseline: honest yield over 1 epoch without attack
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + 1 days);
        eng.updatePost(realPost);
        uint256 baseGain = eng.getUserStake(honest, realPost, 0) - honestAmt;
        vm.revertToState(snap);

        // Attack: 10 x MAX_STAKE_AMOUNT into a phantom post and out again, same block.
        // (M3's per-lot cap now blocks one address stacking; a sybil of ten
        // addresses is free, so the design concern survives unchanged.)
        uint256 got;
        // all in first: post total reaches 100M simultaneously
        for (uint256 i = 0; i < 10; i++) {
            address sybil = address(uint160(0x5AB1 + i));
            _fund(sybil, 10_000_000e18);
            vm.prank(sybil);
            eng.stake(phantom, 0, 10_000_000e18);
        }
        // then all out, same block
        for (uint256 i = 0; i < 10; i++) {
            address sybil = address(uint160(0x5AB1 + i));
            vm.prank(sybil);
            eng.withdraw(phantom, 0, 10_000_000e18, true);
            got += vsp.balanceOf(sybil);
        }
        assertEq(got, 100_000_000e18, "attackers got everything back");

        uint256 sMaxAfter = eng.sMax();
        emit log_named_uint("sMax before attack", sMaxBefore);
        emit log_named_uint("sMax after attacker exited", sMaxAfter);
        assertGt(sMaxAfter, sMaxBefore * 1000, "H5: sMax pinned by capital that is no longer staked");

        vm.warp(block.timestamp + 1 days);
        eng.updatePost(realPost);
        uint256 attackedGain = eng.getUserStake(honest, realPost, 0) - honestAmt;
        emit log_named_uint("honest 1-epoch gain, no attack", baseGain);
        emit log_named_uint("honest 1-epoch gain, after flash", attackedGain);
        assertLt(attackedGain * 100, baseGain, "H5: honest yield crushed by >100x");

        // and it stays suppressed for weeks (10%/day decay)
        vm.warp(block.timestamp + 20 days);
        eng.refreshSMax(realPost);
        emit log_named_uint("sMax 21 days later", eng.sMax());
        assertGt(eng.sMax(), sMaxBefore * 10, "still >10x inflated three weeks later");
    }

    // ───────────────────────────────────────────────────────────────────
    // H6: setStake(postId, 0) (full exit) is blocked while paused, contrary
    //     to the documented intent that users can always exit.
    // ───────────────────────────────────────────────────────────────────
}
