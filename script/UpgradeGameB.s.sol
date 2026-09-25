// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/ScoreEngine.sol";
import "../src/StakeEngine.sol";
import "../src/ProtocolViews.sol";

/// @title UpgradeGameB — whitepaper v17 evidence-economic settlement
/// @notice Deployer (= governance, pre-Phase-A) upgrades three UUPS proxies and wires the
///         StakeEngine to the ScoreEngine. Reads the proxies from broadcast/Deploy.s.sol/<chain>/addresses.json.
///         Env: DEPLOYER_PRIVATE_KEY, FORWARDER_ADDRESS; MAINNET_UPGRADE_CONFIRM=1 on 43114.
///         Idempotent: proxies already on these impls are skipped; setScoreEngine only if unset/different.
contract UpgradeGameB is Script {
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _impl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    function run() external {
        if (block.chainid == 43114) {
            require(
                vm.envOr("MAINNET_UPGRADE_CONFIRM", uint256(0)) == 1, "UpgradeGameB: MAINNET_UPGRADE_CONFIRM=1 required"
            );
        }
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address fw = vm.envAddress("FORWARDER_ADDRESS");
        address me = vm.addr(pk);
        string memory json =
            vm.readFile(string.concat("broadcast/Deploy.s.sol/", vm.toString(block.chainid), "/addresses.json"));
        ScoreEngine score = ScoreEngine(vm.parseJsonAddress(json, ".ScoreEngine"));
        StakeEngine stakeEng = StakeEngine(vm.parseJsonAddress(json, ".StakeEngine"));
        ProtocolViews views = ProtocolViews(vm.parseJsonAddress(json, ".ProtocolViews"));

        require(score.governance() == me, "UpgradeGameB: not ScoreEngine governance");
        require(stakeEng.governance() == me, "UpgradeGameB: not StakeEngine governance");
        require(views.governance() == me, "UpgradeGameB: not ProtocolViews governance");
        require(score.isTrustedForwarder(fw), "UpgradeGameB: FORWARDER_ADDRESS not trusted by ScoreEngine");
        require(stakeEng.isTrustedForwarder(fw), "UpgradeGameB: FORWARDER_ADDRESS not trusted by StakeEngine");

        vm.startBroadcast(pk);
        address scoreImpl = address(new ScoreEngine(fw));
        score.upgradeToAndCall(scoreImpl, "");
        address stakeImpl = address(new StakeEngine(fw));
        stakeEng.upgradeToAndCall(stakeImpl, "");
        address viewsImpl = address(new ProtocolViews(fw));
        views.upgradeToAndCall(viewsImpl, "");
        if (address(stakeEng.scoreEngine()) != address(score)) {
            stakeEng.setScoreEngine(address(score));
        }
        vm.stopBroadcast();

        // proof
        require(_impl(address(score)) == scoreImpl, "UpgradeGameB: ScoreEngine impl mismatch");
        require(_impl(address(stakeEng)) == stakeImpl, "UpgradeGameB: StakeEngine impl mismatch");
        require(_impl(address(views)) == viewsImpl, "UpgradeGameB: ProtocolViews impl mismatch");
        require(address(stakeEng.scoreEngine()) == address(score), "UpgradeGameB: StakeEngine not wired");
        require(score.isTrustedForwarder(fw) && stakeEng.isTrustedForwarder(fw), "UpgradeGameB: forwarder trust lost");
        (,, bool exact) = score.effectivePool(1);
        require(exact, "UpgradeGameB: effectivePool(1) inexact");

        console.log("ScoreEngine impl:", scoreImpl);
        console.log("StakeEngine impl:", stakeImpl);
        console.log("ProtocolViews impl:", viewsImpl);
        console.log("GAME B UPGRADE COMPLETE");
    }
}
