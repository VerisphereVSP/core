// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";
import "../src/ProtocolViews.sol";

/// @title UpgradeForwarder — re-point the five UUPS consumers at the relay Forwarder
///
/// patch_fw_upgrade (2026-09-06). The Fuji genesis (Phase 1) ran Deploy.s.sol
/// WITHOUT FORWARDER_ADDRESS in its env; the script's silent
/// `vm.envOr("FORWARDER_ADDRESS", address(0))` default constructed every
/// consumer implementation trusting address(0). OZ ERC2771Forwarder.verify()
/// therefore returned false for every relayed request (_isTrustedByTarget),
/// which the relay reported as "Invalid signature". Token, pool, and all
/// proxy addresses are untouched by this fix.
///
/// The trusted forwarder is an IMMUTABLE on the implementation (OZ 5.x
/// ERC2771Context), so the fix is the designed one: deploy fresh
/// implementations with the forwarder in the constructor and upgrade each
/// proxy. Sources are byte-identical to genesis (only the immutable changes),
/// so storage layout is unchanged. Idempotent: proxies that already trust the
/// forwarder are skipped.
///
/// Env:
///   DEPLOYER_PRIVATE_KEY     must be each proxy's `governance` (dev: deployer)
///   FORWARDER_ADDRESS        the deployed ERC2771 forwarder (code required)
///   MAINNET_UPGRADE_CONFIRM  must be 1 on chainid 43114
contract UpgradeForwarder is Script {
    function run() external {
        if (block.chainid == 43114) {
            require(
                vm.envOr("MAINNET_UPGRADE_CONFIRM", uint256(0)) == 1,
                "UpgradeForwarder: mainnet requires MAINNET_UPGRADE_CONFIRM=1"
            );
        }
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address gov = vm.addr(pk);
        address fw = vm.envAddress("FORWARDER_ADDRESS");
        require(
            fw != address(0) && fw.code.length > 0, "UpgradeForwarder: FORWARDER_ADDRESS must be a deployed contract"
        );

        string memory json =
            vm.readFile(string.concat("broadcast/Deploy.s.sol/", vm.toString(block.chainid), "/addresses.json"));
        address[5] memory proxies = [
            vm.parseJsonAddress(json, ".StakeEngine"),
            vm.parseJsonAddress(json, ".PostRegistry"),
            vm.parseJsonAddress(json, ".LinkGraph"),
            vm.parseJsonAddress(json, ".ScoreEngine"),
            vm.parseJsonAddress(json, ".ProtocolViews")
        ];
        string[5] memory names;
        names[0] = "StakeEngine";
        names[1] = "PostRegistry";
        names[2] = "LinkGraph";
        names[3] = "ScoreEngine";
        names[4] = "ProtocolViews";
        address[5] memory impls;

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < 5; i++) {
            IConsumer c = IConsumer(proxies[i]);
            if (c.isTrustedForwarder(fw)) {
                console.log(string.concat(names[i], ": already trusts forwarder - SKIP"), proxies[i]);
                continue;
            }
            require(
                c.governance() == gov, string.concat("UpgradeForwarder: broadcaster is not governance of ", names[i])
            );
            address impl;
            if (i == 0) {
                impl = address(new StakeEngine(fw));
            } else if (i == 1) {
                impl = address(new PostRegistry(fw));
            } else if (i == 2) {
                impl = address(new LinkGraph(fw));
            } else if (i == 3) {
                impl = address(new ScoreEngine(fw));
            } else {
                impl = address(new ProtocolViews(fw));
            }
            c.upgradeToAndCall(impl, "");
            require(
                c.isTrustedForwarder(fw), string.concat("UpgradeForwarder: post-upgrade check failed for ", names[i])
            );
            impls[i] = impl;
            console.log(string.concat(names[i], ": upgraded, new impl"), impl);
        }
        vm.stopBroadcast();

        string memory dir = string.concat("broadcast/UpgradeForwarder.s.sol/", vm.toString(block.chainid));
        vm.createDir(dir, true);
        vm.writeFile(
            string.concat(dir, "/upgrade.json"),
            string.concat(
                '{"forwarder":"',
                vm.toString(fw),
                '","StakeEngine_impl":"',
                vm.toString(impls[0]),
                '","PostRegistry_impl":"',
                vm.toString(impls[1]),
                '","LinkGraph_impl":"',
                vm.toString(impls[2]),
                '","ScoreEngine_impl":"',
                vm.toString(impls[3]),
                '","ProtocolViews_impl":"',
                vm.toString(impls[4]),
                '","chainid":',
                vm.toString(block.chainid),
                "}"
            )
        );
        console.log("UPGRADE COMPLETE: all consumers trust forwarder", fw);
    }
}

interface IConsumer {
    function governance() external view returns (address);
    function isTrustedForwarder(address) external view returns (bool);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}
