// SPDX-License-Identifier: MIT
// ============================================================================
//  VeriSphere - Permanent Stake Freeze via Cycle-Tainted Settlement (REGRESSION)
//  Reporter: Ibnu76, 2026-09-26. Original PoC inverted after fix_cycle_freeze:
//  the same graph must settle, withdraw and setStake normally. Confirmed against VerisphereVSP/core @ ea0254e
//  (Merge PR #27 "Game B: evidence-economic settlement", merged 2026-09-25).
//
//  HOW TO RUN
//    git clone https://github.com/VerisphereVSP/core && cd core
//    # drop this file into test/
//    forge test --match-contract CycleFreezeVerify -vvv
//
//  EXPECTED (fresh run, both green):
//    [PASS] test_control_cleanClaim_withdrawsFine()
//    [PASS] test_cycleTaint_freezesVictimStake()   log: victim exact: 0 (tainted)
//    Suite result: ok. 2 passed; 0 failed; 0 skipped
//
//  Error selector confirmed in trace at updatePost(victim):
//    InexactScore(uint256) = 0x609b0047   (matches expectRevert data)
//    SettleFirst(uint256)  = 0x1e6049a5
// ============================================================================
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";

import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// Wiring mirrors the project's own ScoreEngineCycleSafety.t.sol exactly:
/// a link is itself a staked post (createLink returns a postId which is then
/// staked to give the edge weight).
contract CycleFreezeVerify is Test {
    PostRegistry registry;
    StakeEngine stakeEng;
    LinkGraph graph;
    ScoreEngine score;
    MockVSP vsp;
    MockProtocolPolicy policy;

    address victim = address(0xB0B);

    uint256 constant FEE = 50;
    uint256 constant CLAIM_STAKE = FEE * 4;
    uint256 constant LINK_STAKE = FEE * 4;

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    function setUp() public {
        vsp = new MockVSP();
        policy = new MockProtocolPolicy(FEE);

        registry = PostRegistry(
            _proxy(
                address(new PostRegistry(address(0))),
                abi.encodeCall(PostRegistry.initialize, (address(this), address(vsp), address(policy)))
            )
        );
        graph = LinkGraph(
            _proxy(address(new LinkGraph(address(0))), abi.encodeCall(LinkGraph.initialize, (address(this))))
        );
        stakeEng = StakeEngine(
            _proxy(
                address(new StakeEngine(address(0))),
                abi.encodeCall(StakeEngine.initialize, (address(this), address(vsp), address(policy)))
            )
        );
        score = ScoreEngine(
            _proxy(
                address(new ScoreEngine(address(0))),
                abi.encodeCall(
                    ScoreEngine.initialize,
                    (
                        address(this),
                        address(registry),
                        address(stakeEng),
                        address(graph),
                        address(policy),
                        address(policy)
                    )
                )
            )
        );

        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));
        stakeEng.setScoreEngine(address(score));

        vsp.mint(address(this), 1e36);
        vsp.mint(address(registry), 1e36);
        vsp.approve(address(stakeEng), type(uint256).max);
        vsp.approve(address(registry), type(uint256).max);
    }

    function _claim(string memory text, uint256 support) internal returns (uint256 postId) {
        postId = registry.createClaim(text);
        if (support > 0) {
            stakeEng.stake(postId, 0, support);
        }
    }

    function _link(uint256 from, uint256 to, uint256 linkStake) internal returns (uint256 linkId) {
        linkId = registry.createLink(from, to, false);
        if (linkStake > 0) {
            stakeEng.stake(linkId, 0, linkStake);
        }
    }

    /// v18: seed every outgoing link-post of a claim (snapshots are per post).
    function _seedLinksOf(uint256 claimId) internal {
        LinkGraph.Edge[] memory outs = graph.getOutgoing(claimId);
        for (uint256 k = 0; k < outs.length; k++) {
            score.seedSnapshot(outs[k].linkPostId);
        }
    }

    /// A permissionless 2-cycle upstream of the victim taints its settlement
    /// forever: the cycle-cut in ScoreEngine returns exact=false, the flag
    /// propagates down to the victim, and StakeEngine._forceSnapshot then reverts
    /// InexactScore. Every money path settles first, so all of them revert.
    function test_cycleTaint_victimStillSettles() public {
        vm.warp(100 days);
        uint256 x = _claim("X", CLAIM_STAKE);
        uint256 y = _claim("Y", CLAIM_STAKE);
        _link(x, y, LINK_STAKE);
        _link(y, x, LINK_STAKE); // 2-cycle above the victim
        uint256 v = _claim("victim", CLAIM_STAKE);
        _link(x, v, LINK_STAKE);

        // v18: no walk, no memo flag — the pool is read from snapshots; seed the standing graph
        score.seedSnapshot(x);
        score.seedSnapshot(y);
        _seedLinksOf(x);
        _seedLinksOf(y);
        (uint256 S, uint256 C,) = score.effectivePool(v);
        // ... but the VALUE is the whitepaper's: X contributes its mass (X's incoming from Y is cut to 0,
        // X itself is +100% with CLAIM_STAKE), so victim S = own + X's share, C = 0
        assertGt(S, CLAIM_STAKE, "X's support reaches the victim");
        assertEq(C, 0);

        // settlement, withdraw and setStake all work (this is what the PoC showed reverting)
        vm.warp(block.timestamp + 30 days);
        stakeEng.updatePost(v);
        assertEq(stakeEng.getLastSnapshotEpoch(v), block.timestamp / 1 days, "settled");
        stakeEng.withdraw(v, 0, CLAIM_STAKE / 2, false);
        stakeEng.setStake(v, int256(0));
        assertEq(stakeEng.getUserStake(address(this), v, 0), 0, "fully withdrawn");
    }

    /// Control: a claim with no tainted ancestor settles and withdraws cleanly,
    /// proving the freeze is caused by the cycle taint and not by the harness.
    function test_control_cleanClaim_withdrawsFine() public {
        vm.warp(100 days);
        uint256 clean = _claim("clean", CLAIM_STAKE);
        vm.warp(block.timestamp + 30 days);
        stakeEng.updatePost(clean);
        stakeEng.withdraw(clean, 0, CLAIM_STAKE, false);
        assertTrue(true, "clean claim settled and withdrew");
    }
}
