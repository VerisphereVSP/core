// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/ScoreEngine.sol";
import "../src/StakeEngine.sol";
import "../src/LinkGraph.sol";
import "../src/ProtocolViews.sol";

/// @title UpgradeSnapshots — whitepaper v18: settlement on stored snapshots (patch_settlement_snapshots)
/// @notice Deployer (= governance, pre-Phase-A) upgrades ScoreEngine, StakeEngine, LinkGraph and
///         ProtocolViews to the v18 implementations (TimeWeighted library re-linked; `forge script
///         --libraries` or the linked artifact), wires the StakeEngine to the ScoreEngine if it is not
///         yet (mainnet), and SEEDS every existing post's first snapshot in topological order:
///         links first (they write their parents' outgoing sums and the reverse index), then claims in
///         the order given by SEED_ORDER (comma-separated post ids, from the app keeper's topo_order) or
///         ascending id when SEED_ORDER is unset. Seeding is per-post idempotent; re-running is safe.
///         Env: DEPLOYER_PRIVATE_KEY, FORWARDER_ADDRESS, [SEED_ORDER], MAINNET_UPGRADE_CONFIRM=1 on 43114.
contract UpgradeSnapshots is Script {
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _impl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    function run() external {
        if (block.chainid == 43114) {
            require(
                vm.envOr("MAINNET_UPGRADE_CONFIRM", uint256(0)) == 1,
                "UpgradeSnapshots: MAINNET_UPGRADE_CONFIRM=1 required"
            );
        }
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address fw = vm.envAddress("FORWARDER_ADDRESS");
        address me = vm.addr(pk);
        string memory json =
            vm.readFile(string.concat("broadcast/Deploy.s.sol/", vm.toString(block.chainid), "/addresses.json"));
        ScoreEngine score = ScoreEngine(vm.parseJsonAddress(json, ".ScoreEngine"));
        StakeEngine stakeEng = StakeEngine(vm.parseJsonAddress(json, ".StakeEngine"));
        LinkGraph graph = LinkGraph(vm.parseJsonAddress(json, ".LinkGraph"));
        ProtocolViews views = ProtocolViews(vm.parseJsonAddress(json, ".ProtocolViews"));
        PostRegistry registry = PostRegistry(vm.parseJsonAddress(json, ".PostRegistry"));

        require(score.governance() == me, "UpgradeSnapshots: not ScoreEngine governance");
        require(stakeEng.governance() == me, "UpgradeSnapshots: not StakeEngine governance");
        require(graph.governance() == me, "UpgradeSnapshots: not LinkGraph governance");
        require(views.governance() == me, "UpgradeSnapshots: not ProtocolViews governance");
        require(score.isTrustedForwarder(fw), "UpgradeSnapshots: FORWARDER_ADDRESS not trusted by ScoreEngine");
        require(stakeEng.isTrustedForwarder(fw), "UpgradeSnapshots: FORWARDER_ADDRESS not trusted by StakeEngine");

        vm.startBroadcast(pk);
        address scoreImpl = address(new ScoreEngine(fw));
        score.upgradeToAndCall(scoreImpl, "");
        address stakeImpl = address(new StakeEngine(fw));
        stakeEng.upgradeToAndCall(stakeImpl, "");
        address graphImpl = address(new LinkGraph(fw));
        graph.upgradeToAndCall(graphImpl, "");
        address viewsImpl = address(new ProtocolViews(fw));
        views.upgradeToAndCall(viewsImpl, "");
        if (address(stakeEng.scoreEngine()) != address(score)) {
            stakeEng.setScoreEngine(address(score));
        }

        // ── seed pass: links first, then claims in SEED_ORDER (or id order) ──
        uint256 next = registry.nextPostId();
        uint256 seededLinks;
        uint256 seededClaims;
        for (uint256 p = 1; p < next; p++) {
            if (registry.getPost(p).contentType == PostRegistry.ContentType.Link) {
                (bool had,,,) = score.getSnapshot(p);
                score.seedSnapshot(p);
                if (!had) {
                    seededLinks++;
                }
            }
        }
        string memory order = vm.envOr("SEED_ORDER", string(""));
        if (bytes(order).length != 0) {
            string[] memory parts = vm.split(order, ",");
            for (uint256 i = 0; i < parts.length; i++) {
                uint256 p = vm.parseUint(parts[i]);
                (bool had,,,) = score.getSnapshot(p);
                score.seedSnapshot(p);
                if (!had) {
                    seededClaims++;
                }
            }
        }
        for (uint256 p = 1; p < next; p++) {
            if (registry.getPost(p).contentType == PostRegistry.ContentType.Claim) {
                (bool had,,,) = score.getSnapshot(p);
                score.seedSnapshot(p); // no-op where SEED_ORDER already covered it
                if (!had) {
                    seededClaims++;
                }
            }
        }
        vm.stopBroadcast();

        // ── proof ──
        require(_impl(address(score)) == scoreImpl, "UpgradeSnapshots: ScoreEngine impl mismatch");
        require(_impl(address(stakeEng)) == stakeImpl, "UpgradeSnapshots: StakeEngine impl mismatch");
        require(_impl(address(graph)) == graphImpl, "UpgradeSnapshots: LinkGraph impl mismatch");
        require(_impl(address(views)) == viewsImpl, "UpgradeSnapshots: ProtocolViews impl mismatch");
        require(address(stakeEng.scoreEngine()) == address(score), "UpgradeSnapshots: StakeEngine not wired");
        require(
            score.isTrustedForwarder(fw) && stakeEng.isTrustedForwarder(fw), "UpgradeSnapshots: forwarder trust lost"
        );
        require(
            graph.maxIncomingLinksPerClaim() == 1000 && graph.maxOutgoingLinksPerClaim() == 1000,
            "LinkGraph caps default"
        );
        for (uint256 p = 1; p < next; p++) {
            (bool seeded,,,) = score.getSnapshot(p);
            require(seeded, "UpgradeSnapshots: a post is unseeded");
        }
        if (next > 1) {
            (,, bool exact) = score.effectivePool(1);
            require(exact, "UpgradeSnapshots: effectivePool(1) failed");
        }

        console.log("ScoreEngine impl:", scoreImpl);
        console.log("StakeEngine impl:", stakeImpl);
        console.log("LinkGraph impl:", graphImpl);
        console.log("ProtocolViews impl:", viewsImpl);
        console.log("seeded links:", seededLinks);
        console.log("seeded claims:", seededClaims);
        console.log("V18 SNAPSHOTS UPGRADE COMPLETE");
    }
}
