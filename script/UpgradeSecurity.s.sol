// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/PostRegistry.sol";
import "../src/StakeEngine.sol";

/// @title UpgradeSecurity — security review 2026-09 (H1, H3, M3, paused-exit)
/// Deploys fresh StakeEngine + PostRegistry implementations (forwarder immutable
/// preserved), upgrades both proxies, then wires the engine's postRegistry
/// (H1). Storage is append-only on both; idempotent; mainnet-gated.
/// Env: DEPLOYER_PRIVATE_KEY (= governance), FORWARDER_ADDRESS, MAINNET_UPGRADE_CONFIRM on 43114.
contract UpgradeSecurity is Script {
    function run() external {
        if (block.chainid == 43114) {
            require(
                vm.envOr("MAINNET_UPGRADE_CONFIRM", uint256(0)) == 1,
                "UpgradeSecurity: MAINNET_UPGRADE_CONFIRM=1 required"
            );
        }
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address gov = vm.addr(pk);
        address fw = vm.envAddress("FORWARDER_ADDRESS");
        require(fw.code.length > 0, "UpgradeSecurity: FORWARDER_ADDRESS has no code");
        string memory json =
            vm.readFile(string.concat("broadcast/Deploy.s.sol/", vm.toString(block.chainid), "/addresses.json"));
        address engineProxy = vm.parseJsonAddress(json, ".StakeEngine");
        address registryProxy = vm.parseJsonAddress(json, ".PostRegistry");
        StakeEngine engine = StakeEngine(engineProxy);
        PostRegistry registry = PostRegistry(registryProxy);
        require(
            engine.governance() == gov && registry.governance() == gov, "UpgradeSecurity: broadcaster is not governance"
        );
        require(
            engine.isTrustedForwarder(fw) && registry.isTrustedForwarder(fw),
            "UpgradeSecurity: FORWARDER_ADDRESS is not the trusted forwarder"
        );

        vm.startBroadcast(pk);
        address eImpl = address(new StakeEngine(fw));
        engine.upgradeToAndCall(eImpl, "");
        address rImpl = address(new PostRegistry(fw));
        registry.upgradeToAndCall(rImpl, "");
        if (engine.postRegistry() != registryProxy) {
            engine.setPostRegistry(registryProxy);
        }
        vm.stopBroadcast();

        require(engine.postRegistry() == registryProxy, "UpgradeSecurity: postRegistry not wired");
        require(
            engine.isTrustedForwarder(fw) && registry.isTrustedForwarder(fw), "UpgradeSecurity: forwarder trust lost"
        );
        console.log("StakeEngine impl:", eImpl);
        console.log("PostRegistry impl:", rImpl);
        console.log("engine.postRegistry:", engine.postRegistry());
        console.log("SECURITY UPGRADE COMPLETE");
    }
}
