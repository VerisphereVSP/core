// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/StakeEngine.sol";

/// @title DeployStakeEngineImpl — VSP-SEC-003/004 (patch_sec_upgrade_script)
/// @notice Deploys a new StakeEngine IMPLEMENTATION and nothing else. It does not touch the proxy:
///         governance is the TimelockController, so the upgrade itself is `schedule` + 48 h +
///         `execute` from the Cold Safe. This script prints everything that step needs — the
///         implementation address, the `upgradeToAndCall(impl, "")` calldata for the proxy, and the
///         Timelock operation id for the (target, value, data, predecessor, salt) tuple.
///
///         Any funded key may run it: the implementation has no owner and its constructor only bakes
///         the trusted forwarder (read from the live proxy so it cannot drift). The TimeWeighted
///         library is unchanged, so link the deployed one: pass `--libraries
///         src/lib/TimeWeighted.sol:TimeWeighted:<address>` AND TIMEWEIGHTED_ADDRESS=<same>; the script
///         checks the new implementation's code calls that address (an unlinked build would have made
///         forge deploy a second library silently).
///
///         Env: DEPLOYER_PRIVATE_KEY (any funded EOA), TIMEWEIGHTED_ADDRESS, MAINNET_UPGRADE_CONFIRM=1 on
///         43114, [UPGRADE_SALT] (bytes32; default keccak256("vsp-sec-003-004")).
contract DeployStakeEngineImpl is Script {
    function run() external {
        if (block.chainid == 43114) {
            require(vm.envOr("MAINNET_UPGRADE_CONFIRM", uint256(0)) == 1, "MAINNET_UPGRADE_CONFIRM=1 required");
        }
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory json =
            vm.readFile(string.concat("broadcast/Deploy.s.sol/", vm.toString(block.chainid), "/addresses.json"));
        address proxy = vm.parseJsonAddress(json, ".StakeEngine");
        address timelock = vm.parseJsonAddress(json, ".TimelockController");
        address forwarder = StakeEngine(proxy).trustedForwarder();
        address gov = StakeEngine(proxy).governance();
        bytes32 salt = vm.envOr("UPGRADE_SALT", keccak256("vsp-sec-003-004"));

        console.log("chain:            ", block.chainid);
        console.log("StakeEngine proxy:", proxy);
        console.log("governance():     ", gov);
        console.log("TimelockController", timelock);
        console.log("forwarder (live): ", forwarder);
        require(gov == timelock, "governance() is not the Timelock: this script is for the Timelock path");

        address lib = vm.envAddress("TIMEWEIGHTED_ADDRESS");
        require(lib.code.length > 0, "TIMEWEIGHTED_ADDRESS has no code");

        vm.startBroadcast(pk);
        StakeEngine impl = new StakeEngine(forwarder);
        vm.stopBroadcast();

        require(_codeContains(address(impl).code, lib), "new impl is not linked to TIMEWEIGHTED_ADDRESS");
        console.log("TimeWeighted link:", lib, "(found in impl code)");

        bytes memory data = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(impl), bytes(""));
        bytes32 opId = keccak256(abi.encode(proxy, uint256(0), data, bytes32(0), salt));
        console.log("");
        console.log("NEW StakeEngine impl:", address(impl));
        console.log("--- Timelock operation (Cold Safe -> TimelockController) ---");
        console.log("target:      ", proxy);
        console.log("value:       ", uint256(0));
        console.log("data:        ", vm.toString(data));
        console.log("predecessor: ", vm.toString(bytes32(0)));
        console.log("salt:        ", vm.toString(salt));
        console.log("delay:       ", uint256(172800));
        console.log("operation id:", vm.toString(opId));
        console.log("schedule calldata:");
        console.log(
            vm.toString(
                abi.encodeWithSignature(
                    "schedule(address,uint256,bytes,bytes32,bytes32,uint256)",
                    proxy,
                    uint256(0),
                    data,
                    bytes32(0),
                    salt,
                    uint256(172800)
                )
            )
        );
        console.log("execute calldata:");
        console.log(
            vm.toString(
                abi.encodeWithSignature(
                    "execute(address,uint256,bytes,bytes32,bytes32)", proxy, uint256(0), data, bytes32(0), salt
                )
            )
        );
    }

    /// @dev true if the 20 bytes of `a` occur in `code` (the library CALL target of a linked build).
    function _codeContains(bytes memory code, address a) internal pure returns (bool) {
        bytes20 needle = bytes20(a);
        if (code.length < 20) {
            return false;
        }
        for (uint256 i = 0; i + 20 <= code.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < 20; j++) {
                if (code[i + j] != needle[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) {
                return true;
            }
        }
        return false;
    }
}
