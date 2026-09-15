// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/ScoreEngine.sol";

/// @title UpgradeScoreEngine — deploy a fresh ScoreEngine implementation and
///        upgrade the proxy (R2-H and any later view-logic changes). Idempotent
///        in effect (a no-op re-run just redeploys an identical impl), mainnet-gated.
/// Env: DEPLOYER_PRIVATE_KEY (= governance), FORWARDER_ADDRESS, MAINNET_UPGRADE_CONFIRM on 43114.
contract UpgradeScoreEngine is Script {
    function run() external {
        if (block.chainid == 43114) {
            require(
                vm.envOr("MAINNET_UPGRADE_CONFIRM", uint256(0)) == 1,
                "UpgradeScoreEngine: MAINNET_UPGRADE_CONFIRM=1 required"
            );
        }
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address fw = vm.envAddress("FORWARDER_ADDRESS");
        string memory json =
            vm.readFile(string.concat("broadcast/Deploy.s.sol/", vm.toString(block.chainid), "/addresses.json"));
        ScoreEngine score = ScoreEngine(vm.parseJsonAddress(json, ".ScoreEngine"));
        require(score.governance() == vm.addr(pk), "UpgradeScoreEngine: broadcaster is not governance");
        require(score.isTrustedForwarder(fw), "UpgradeScoreEngine: FORWARDER_ADDRESS is not the trusted forwarder");
        vm.startBroadcast(pk);
        address impl = address(new ScoreEngine(fw));
        score.upgradeToAndCall(impl, "");
        vm.stopBroadcast();
        require(score.isTrustedForwarder(fw), "UpgradeScoreEngine: forwarder trust lost");
        console.log("ScoreEngine impl:", impl);
        console.log("SCORE UPGRADE COMPLETE");
    }
}
