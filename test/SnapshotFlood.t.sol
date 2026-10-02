// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./base/SnapshotBase.sol";

/// @title The binding F-D acceptance test (review R3, 2026-10-01) — settlement cost does not depend
///        on the graph above a post.
/// @notice Flood one hub to the structural cap (1,000 incoming links, each from a distinct ACTIVE
///         parent), then settle and withdraw on the hub and on every descendant; all must fit a Fuji
///         block (32M, the smaller of the two deployed limits), and a child's settlement cost must not
///         depend on its hub's link count. Also ChatGPT's dense-cycle case (six mutually linked claims)
///         and the per-descendant amplification that made F-D Critical.
/// @dev patch_settlement_caps: the gates below are calibrated COLD — `forge test --isolate` runs every
///      call as its own transaction, so storage reads are not warmed by the fixture (CI runs this contract
///      both ways). Measured 2026-10-02: hub at 1,000 incoming 22.7M cold / 10.46M warm; child 443k / 214k; dense clique
///      592k / 333k; a flood parent or link 468k / <400k; 300 inactive-parent links 4.1M / 1.49M.
contract SnapshotFloodTest is SnapshotBase {
    uint256 constant BLOCK_GAS = 32_000_000; // Fuji; mainnet is 80M (measured 2026-10-01)

    function _flood(uint256 hub, uint256 n, string memory tag) internal {
        for (uint256 i = 0; i < n; i++) {
            uint256 p = registry.createClaim(string(abi.encodePacked(tag, vm.toString(i))));
            se.stake(p, 0, 2e18); // active parent
            uint256 l = registry.createLink(p, hub, i % 2 == 0);
            se.stake(l, 0, 1e18); // active link
        }
    }

    /// Flood 1,000 (the cap); the hub, a child with one link from the hub, and a grandchild all settle
    /// and withdraw within a block. The keeper settles the flood parents/links first (each is a tiny,
    /// bounded tx) — that cost is theirs, not the hub's.
    function test_FD_floodedHubAndDescendantsSettleWithinABlock() public {
        uint256 hub = _claimStaked("hub", A, 0, 10e18);
        uint256 child = _claimStaked("child", B, 0, 5e18);
        uint256 lc = _link(C, hub, child, false, 1e18);
        uint256 grand = _claimStaked("grand", D, 0, 5e18);
        uint256 lg = _link(C, child, grand, true, 1e18);
        uint256 cap = graph.maxIncomingLinksPerClaim();
        assertEq(cap, 1000);
        _flood(hub, cap - 0, "fp"); // hub already has 0 incoming; fill to the cap
        assertEq(graph.getIncoming(hub).length, cap, "hub at the structural cap");
        vm.expectRevert();
        registry.createLink(child, hub, true); // the cap holds
        _nextEpoch();
        // keeper: flood parents and links (1 .. 2*cap posts), each bounded
        uint256 next = registry.nextPostId();
        uint256 worstSmall;
        for (uint256 p = 1; p < next; p++) {
            if (p == hub || p == child || p == grand || p == lc || p == lg) {
                continue;
            }
            uint256 g0 = gasleft();
            se.updatePost(p);
            uint256 g = g0 - gasleft();
            if (g > worstSmall) {
                worstSmall = g;
            }
        }
        assertLt(worstSmall, 700_000, "a flood parent or link settles for < 700k (cold)");
        // the hub: O(incoming) reads, no recursion
        uint256 h0 = gasleft();
        se.updatePost(hub);
        uint256 hubGas = h0 - gasleft();
        emit log_named_uint("hub settle gas @1000 incoming", hubGas);
        assertLt(
            hubGas, (BLOCK_GAS * 4) / 5, "flooded hub at the absolute cap settles within 80% of a Fuji block (cold)"
        );
        assertEq(
            graph.ABSOLUTE_MAX_LINKS_PER_CLAIM(), cap, "the structural ceiling is the measured point, not above it"
        );
        se.updatePost(lc);
        uint256 c0 = gasleft();
        se.updatePost(child);
        uint256 childGas = c0 - gasleft();
        emit log_named_uint("child settle gas (1 link from the flooded hub)", childGas);
        assertLt(childGas, 600_000, "child cost is its own incoming count, not the hub's (cold)");
        se.updatePost(lg);
        uint256 gg0 = gasleft();
        se.updatePost(grand);
        emit log_named_uint("grandchild settle gas", gg0 - gasleft());
        // withdrawals on every descendant go through the user path (inline settlement, 3M budget)
        _withdraw(B, child, 0, 1e18);
        _withdraw(D, grand, 0, 1e18);
        _withdraw(A, hub, 0, 1e18);
        assertEq(se.getUserStake(B, child, 0) > 0, true);
    }

    /// A child's settlement cost is independent of its parent's fan-in: hub with 1,000 links vs hub
    /// with 1 link; the children's settle gas agree within noise.
    function test_FD_childCostIndependentOfHubFanIn() public {
        uint256 bigHub = _claimStaked("bighub", A, 0, 10e18);
        uint256 smallHub = _claimStaked("smallhub", A, 0, 10e18);
        uint256 c1 = _claimStaked("c1", B, 0, 5e18);
        uint256 c2 = _claimStaked("c2", B, 0, 5e18);
        uint256 l1 = _link(C, bigHub, c1, false, 1e18);
        uint256 l2 = _link(C, smallHub, c2, false, 1e18);
        _flood(bigHub, 1000, "bf");
        _flood(smallHub, 1, "sf");
        _nextEpoch();
        uint256 next = registry.nextPostId();
        for (uint256 p = 1; p < next; p++) {
            if (p != c1 && p != c2) {
                se.updatePost(p);
            }
        }
        uint256 g0 = gasleft();
        se.updatePost(c1);
        uint256 gBig = g0 - gasleft();
        g0 = gasleft();
        se.updatePost(c2);
        uint256 gSmall = g0 - gasleft();
        emit log_named_uint("child of 1000-link hub", gBig);
        emit log_named_uint("child of 1-link hub", gSmall);
        assertApproxEqRel(gBig, gSmall, 5e16, "within 5%: no ancestry amplification");
        // and the big hub's own contribution reached its child
        (uint256 S,,) = score.effectivePool(c1);
        assertGt(S, 5e18, "flooded hub still contributes to its child");
        assertEq(score.getEdgeContribution(c1, l1) > 0, true);
        assertEq(score.getEdgeContribution(c2, l2) > 0, true);
    }

    /// ChatGPT's case: six mutually linked active claims (a full directed clique) plus a target; the
    /// old walk burned 28.6M on the target. Every one of them settles for a fraction of a block.
    function test_FD_denseCliqueSettlesCheaply() public {
        uint256[6] memory c;
        for (uint256 i = 0; i < 6; i++) {
            c[i] = _claimStaked(string(abi.encodePacked("k", vm.toString(i))), A, 0, 5e18);
        }
        for (uint256 i = 0; i < 6; i++) {
            for (uint256 j = 0; j < 6; j++) {
                if (i != j) {
                    _link(B, c[i], c[j], (i + j) % 2 == 0, 1e18);
                }
            }
        }
        uint256 target = _claimStaked("target", C, 0, 3e18);
        _link(B, c[0], target, false, 1e18);
        _nextEpoch();
        uint256 worst;
        for (uint256 e = 0; e < 3; e++) {
            for (uint256 i = 0; i < created.length; i++) {
                uint256 g0 = gasleft();
                se.updatePost(created[i]);
                uint256 g = g0 - gasleft();
                if (g > worst) {
                    worst = g;
                }
            }
            _nextEpoch();
        }
        emit log_named_uint("worst settle gas in the clique", worst);
        assertLt(worst, 1_200_000, "dense cycles cost O(incoming), not 28.6M (cold)");
        for (uint256 i = 0; i < 6; i++) {
            int256 v = score.effectiveVSRay(c[i]);
            assertLe(v, int256(RAY));
            assertGe(v, -int256(RAY));
        }
    }

    /// Flood parents that are INACTIVE (unstaked) cost nothing to anyone and count for nothing.
    function test_FD_inactiveFloodIsInert() public {
        uint256 hub = _claimStaked("hub2", A, 0, 10e18);
        for (uint256 i = 0; i < 300; i++) {
            uint256 p = registry.createClaim(string(abi.encodePacked("dead", vm.toString(i))));
            uint256 l = registry.createLink(p, hub, true);
            se.stake(l, 0, 1e18); // staked links from unstaked parents
        }
        _nextEpoch();
        uint256 next = registry.nextPostId();
        for (uint256 p = 1; p < next; p++) {
            if (p != hub) {
                se.updatePost(p);
            }
        }
        uint256 g0 = gasleft();
        se.updatePost(hub);
        emit log_named_uint("hub settle gas @300 inactive-parent links", g0 - gasleft());
        (uint256 S, uint256 Cc,) = score.effectivePool(hub);
        assertEq(Cc, 0, "inactive parents contribute nothing");
        assertGt(S, 0);
    }
}
