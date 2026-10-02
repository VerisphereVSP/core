// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../../src/PostRegistry.sol";
import "../../src/LinkGraph.sol";
import "../../src/StakeEngine.sol";
import "../../src/ScoreEngine.sol";
import "../mocks/MockVSP.sol";
import "../mocks/MockProtocolPolicy.sol";

/// @title Shared fixture for the v18 (settlement-on-snapshots) suites.
/// @notice Full protocol wired (ScoreEngine set on the StakeEngine), mainnet-like policy (1 VSP fee
///         and threshold), four funded actors, clock on an epoch boundary. Helpers build graphs and run
///         the keeper's topological pass (claims, then links, then the claims they point to).
abstract contract SnapshotBase is Test {
    uint256 constant RAY = 1e18;
    uint256 constant FEE = 1e18;
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
    address D = address(0xDA7E);

    uint256[] internal created; // every post created through the helpers, in creation order

    function setUp() public virtual {
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
        se.setScoreEngine(address(score));
        address[5] memory who = [address(this), A, B, C, D];
        for (uint256 i = 0; i < 5; i++) {
            vsp.mint(who[i], 100_000_000e18);
            vm.startPrank(who[i]);
            vsp.approve(address(registry), type(uint256).max);
            vsp.approve(address(se), type(uint256).max);
            vm.stopPrank();
        }
        vm.warp(((block.timestamp / EPOCH) + 2) * EPOCH); // exactly on a boundary
    }

    // ── graph builders ──────────────────────────────────────────────────────
    function _claim(string memory t) internal returns (uint256 id) {
        id = registry.createClaim(t);
        created.push(id);
    }

    function _claimStaked(string memory t, address u, uint8 side, uint256 amt) internal returns (uint256 id) {
        id = _claim(t);
        _stake(u, id, side, amt);
    }

    function _stake(address u, uint256 pid, uint8 side, uint256 amt) internal {
        vm.prank(u);
        se.stake(pid, side, amt);
    }

    function _withdraw(address u, uint256 pid, uint8 side, uint256 amt) internal {
        vm.prank(u);
        se.withdraw(pid, side, amt, false);
    }

    function _link(address u, uint256 from, uint256 to, bool chal, uint256 linkStake) internal returns (uint256 l) {
        l = registry.createLink(from, to, chal);
        created.push(l);
        if (linkStake > 0) {
            _stake(u, l, 0, linkStake);
        }
    }

    // ── keeper ──────────────────────────────────────────────────────────────
    function _nextEpoch() internal {
        vm.warp(block.timestamp + EPOCH);
    }

    /// Keeper pass in the order the app uses: every post in creation order is topological for the
    /// graphs these tests build (parents are created before their links, links before the claims
    /// that depend on them are settled below). Two sweeps make the order irrelevant: claims, then
    /// links, then claims again would be exact; one pass in creation order is what the app does.
    function _keeperPass() internal {
        for (uint256 i = 0; i < created.length; i++) {
            se.updatePost(created[i]);
        }
    }

    /// Seed every created post (what the post-upgrade seed pass does), parents before children.
    function _seedAll() internal {
        for (uint256 i = 0; i < created.length; i++) {
            score.seedSnapshot(created[i]);
        }
    }

    // ── whitepaper arithmetic ───────────────────────────────────────────────
    function _vs(uint256 S, uint256 Cc) internal pure returns (int256) {
        if (S + Cc == 0) {
            return 0;
        }
        return (int256(S) - int256(Cc)) * int256(RAY) / int256(S + Cc);
    }

    function _rMaxE(uint256 epochs) internal pure returns (uint256) {
        return (R_MAX * EPOCH * epochs) / YEAR;
    }

    function _rBaseOf(uint256 S, uint256 Cc, uint256 Tdirect, uint256 sMax_, uint256 epochs)
        internal
        pure
        returns (uint256)
    {
        uint256 diff = S > Cc ? S - Cc : Cc - S;
        uint256 verity = (diff * RAY) / (S + Cc);
        uint256 part = (Tdirect * RAY) / sMax_;
        if (part > RAY) {
            part = RAY;
        }
        return (_rMaxE(epochs) * verity * part) / (RAY * RAY);
    }

    function _delta(uint256 amount, uint256 rBase, uint256 wp, uint256 sideTotal) internal pure returns (uint256) {
        uint256 pw = ((sideTotal - wp) * RAY) / sideTotal;
        return Math.mulDiv(amount * rBase, pw, RAY * RAY);
    }

    function _absI(int256 v) internal pure returns (int256) {
        return v < 0 ? -v : v;
    }

    function _snapT(uint256 pid) internal view returns (uint256) {
        (,, uint96 T,) = score.getSnapshot(pid);
        return T;
    }

    function _snapVs(uint256 pid) internal view returns (int256) {
        (,,, int128 v) = score.getSnapshot(pid);
        return v;
    }
}
