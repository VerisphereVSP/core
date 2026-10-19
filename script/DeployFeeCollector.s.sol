// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/FeeCollector.sol";

/// @title DeployFeeCollector (patch_fee_collector)
/// @notice Deploys the relay's fee spender. Nothing else changes on chain: no Timelock action is
///         needed, because the contract is new and governed by the Timelock from its constructor.
///         Clients learn the new spender from the app (/api/relay/config feeCollector) and permit it
///         at their next action; the app's worker calls `collect` instead of transferFrom.
///
///         Reads TimelockController and VSPToken from broadcast/Deploy.s.sol/<chain>/addresses.json.
///         Env: DEPLOYER_PRIVATE_KEY (any funded EOA), FEE_COLLECTOR_GUARDIAN (the Guardian Safe),
///         FEE_COLLECTOR_TREASURY (the Cold Safe), FEE_COLLECTOR_RELAY (the relay wallet),
///         [FEE_COLLECTOR_MAX_PER_COLLECT_WEI] default 5e18, [FEE_COLLECTOR_MAX_PER_USER_DAY_WEI] default 25e18,
///         MAINNET_UPGRADE_CONFIRM=1 on 43114.
///         Writes broadcast/DeployFeeCollector.s.sol/<chain>/fee-collector.json (address + constructor args,
///         what `forge verify-contract` needs).
contract DeployFeeCollector is Script {
    function run() external {
        if (block.chainid == 43114) {
            require(vm.envOr("MAINNET_UPGRADE_CONFIRM", uint256(0)) == 1, "MAINNET_UPGRADE_CONFIRM=1 required");
        }
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory json =
            vm.readFile(string.concat("broadcast/Deploy.s.sol/", vm.toString(block.chainid), "/addresses.json"));
        address timelock = vm.parseJsonAddress(json, ".TimelockController");
        address token = vm.parseJsonAddress(json, ".VSPToken");
        address guardian = vm.envAddress("FEE_COLLECTOR_GUARDIAN");
        address treasury = vm.envAddress("FEE_COLLECTOR_TREASURY");
        address relay = vm.envAddress("FEE_COLLECTOR_RELAY");
        uint256 maxPer = vm.envOr("FEE_COLLECTOR_MAX_PER_COLLECT_WEI", uint256(5e18));
        uint256 maxDay = vm.envOr("FEE_COLLECTOR_MAX_PER_USER_DAY_WEI", uint256(25e18));

        require(timelock.code.length > 0, "TimelockController has no code");
        require(token.code.length > 0, "VSPToken has no code");
        if (block.chainid == 43114) {
            // mainnet: the roles are the Safes; on Fuji the deployer EOA stands in for them
            require(guardian.code.length > 0, "guardian must be a contract (the Guardian Safe)");
            require(treasury.code.length > 0, "treasury must be a contract (the Cold Safe)");
        }
        require(relay != address(0) && relay.code.length == 0, "relay must be an EOA (the relay wallet)");

        console.log("chain:              ", block.chainid);
        console.log("VSPToken:           ", token);
        console.log("governance (Timelock)", timelock);
        console.log("guardian:           ", guardian);
        console.log("treasury:           ", treasury);
        console.log("collector (relay):  ", relay);
        console.log("maxFeePerCollect:   ", maxPer);
        console.log("maxPerUserPerDay:   ", maxDay);

        vm.startBroadcast(pk);
        FeeCollector fc = new FeeCollector(token, timelock, guardian, treasury, relay, maxPer, maxDay);
        vm.stopBroadcast();

        require(fc.governance() == timelock && fc.isCollector(relay) && fc.treasury() == treasury, "post-deploy check");
        bytes memory args = abi.encode(token, timelock, guardian, treasury, relay, maxPer, maxDay);
        console.log("");
        console.log("FeeCollector:       ", address(fc));
        console.log("constructor args (for verify-contract):", vm.toString(args));

        string memory out = "fc";
        vm.serializeAddress(out, "FeeCollector", address(fc));
        vm.serializeAddress(out, "token", token);
        vm.serializeAddress(out, "governance", timelock);
        vm.serializeAddress(out, "guardian", guardian);
        vm.serializeAddress(out, "treasury", treasury);
        vm.serializeAddress(out, "collector", relay);
        vm.serializeUint(out, "maxFeePerCollectWei", maxPer);
        vm.serializeUint(out, "maxPerUserPerDayWei", maxDay);
        string memory doc = vm.serializeString(out, "constructorArgs", vm.toString(args));
        string memory dir = string.concat("broadcast/DeployFeeCollector.s.sol/", vm.toString(block.chainid));
        vm.createDir(dir, true);
        vm.writeJson(doc, string.concat(dir, "/fee-collector.json"));
        console.log("wrote", string.concat(dir, "/fee-collector.json"));
    }
}
