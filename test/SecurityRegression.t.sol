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
contract SecurityRegression is Test {
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
        eng.setPostRegistry(address(registry)); // as Deploy.s.sol wires it (H1)
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

    // ── Security review 2026-09 — regression tests (PASS == FIXED) ──────────

    function test_H1_stakeOnNonexistentPost_reverts() public {
        uint256 phantom = 987_654_321;
        _fund(attacker, 1_000_000e18);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(StakeEngine.InvalidPostId.selector, phantom));
        eng.stake(phantom, 0, 1_000_000e18);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(StakeEngine.InvalidPostId.selector, phantom));
        eng.setStake(phantom, 1e18);
    }

    function test_H1_stakeOnRealPost_stillWorks() public {
        uint256 pid = registry.createClaim("Water is wet");
        _fund(honest, 100e18);
        vm.prank(honest);
        eng.stake(pid, 0, 100e18);
        assertEq(eng.getUserStake(honest, pid, 0), 100e18);
    }

    function test_H3_post0_isNotLinkableOrStakeable() public {
        uint256 target = registry.createClaim("The sky is green");
        vm.expectRevert();
        registry.createLink(0, target, false);
        vm.expectRevert();
        registry.createLink(target, 0, true);
        _fund(attacker, 10_000e18);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(StakeEngine.InvalidPostId.selector, 0));
        eng.stake(0, 0, 5_000e18);
        assertEq(score.effectiveVSRay(target), 0, "no phantom evidence reaches the target");
    }

    function test_M3_perLotCap_bindsAcrossCalls() public {
        uint256 pid = registry.createClaim("Cap me");
        _fund(attacker, 100_000_000e18);
        vm.startPrank(attacker);
        eng.stake(pid, 0, eng.MAX_STAKE_AMOUNT()); // first call fills the lot exactly
        vm.expectRevert(
            abi.encodeWithSelector(
                StakeEngine.LotExceedsCap.selector, eng.MAX_STAKE_AMOUNT() + 1, eng.MAX_STAKE_AMOUNT()
            )
        );
        eng.stake(pid, 0, 1); // any top-up beyond the cap is refused
        vm.stopPrank();
        assertEq(eng.getUserStake(attacker, pid, 0), eng.MAX_STAKE_AMOUNT());
    }

    function test_Low_setStakeZero_allowedWhenPaused() public {
        uint256 pid = registry.createClaim("Exit while paused");
        _fund(honest, 100e18);
        vm.prank(honest);
        eng.stake(pid, 0, 100e18);
        eng.initializeV2(address(this));
        eng.pause();
        vm.prank(honest);
        eng.setStake(pid, 0); // full exit stays open
        assertEq(eng.getUserStake(honest, pid, 0), 0);
        vm.prank(honest);
        vm.expectRevert(StakeEngine.WhenPaused.selector);
        eng.setStake(pid, 1e18); // but no new exposure while paused
    }
}
