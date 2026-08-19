// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockCPAMM} from "../src/mock/MockCPAMM.sol";

/// @title SeedPool — FUJI MOCK-LAUNCH pool deployment + initial liquidity seed
///
/// Rehearses the "market-formation act" of the launch ceremony: deploys the
/// rehearsal AMM (MockCPAMM — NOT FOR MAINNET; the contract itself reverts on
/// chainid 43114 and this script re-asserts it) and deposits the initial
/// treasury liquidity at the chosen launch ratio.
///
/// Env:
///   DEPLOYER_PRIVATE_KEY   seeder key (must hold the VSP + USDC amounts)
///   VSP_TOKEN_ADDRESS      VSPToken proxy (from addresses.json)
///   USDC_ADDRESS           Fuji USDC (or mock USDC) address
///   POOL_ADDRESS           optional: reuse an existing MockCPAMM instead of deploying
///   LP_SEED_VSP_WEI        VSP side  (default 2_000e18   — Schedule 1 open param)
///   LP_SEED_USDC_UNITS     USDC side (default 2_000e6 = 1 USDC/VSP — Schedule 1 open param)
///
/// The implied launch price is LP_SEED_USDC_UNITS / LP_SEED_VSP_WEI; both are
/// board-consent Schedule 1 numbers — this script just executes them.
contract SeedPool is Script {
    function run() external {
        require(block.chainid != 43114, "SeedPool: rehearsal script, mainnet forbidden");

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address seeder = vm.addr(pk);

        IERC20 vsp = IERC20(vm.envAddress("VSP_TOKEN_ADDRESS"));
        IERC20 usdc = IERC20(vm.envAddress("USDC_ADDRESS"));
        uint256 seedVsp = vm.envOr("LP_SEED_VSP_WEI", uint256(2_000 * 1e18));
        uint256 seedUsdc = vm.envOr("LP_SEED_USDC_UNITS", uint256(2_000 * 1e6));

        require(vsp.balanceOf(seeder) >= seedVsp, "SeedPool: seeder VSP balance short");
        require(usdc.balanceOf(seeder) >= seedUsdc, "SeedPool: seeder USDC balance short");

        vm.startBroadcast(pk);

        MockCPAMM pool;
        address existing = vm.envOr("POOL_ADDRESS", address(0));
        if (existing == address(0)) {
            pool = new MockCPAMM(vsp, usdc);
        } else {
            pool = MockCPAMM(existing);
        }

        vsp.approve(address(pool), seedVsp);
        usdc.approve(address(pool), seedUsdc);
        uint256 minted = pool.addLiquidity(seedVsp, seedUsdc);

        vm.stopBroadcast();

        console.log("POOL:", address(pool));
        console.log("LP shares minted to seeder:", minted);
        console.log("reserves: VSP(wei) / USDC(units):", pool.reserve0(), pool.reserve1());
        console.log("spot price token0-in-token1 (1e18):", pool.spotPrice0In1E18());

        vm.writeFile(
            string.concat("broadcast/SeedPool.s.sol/", vm.toString(block.chainid), "/pool.json"),
            string.concat(
                '{"MockCPAMM":"',
                vm.toString(address(pool)),
                '","seedVspWei":"',
                vm.toString(seedVsp),
                '","seedUsdcUnits":"',
                vm.toString(seedUsdc),
                '","lpShares":"',
                vm.toString(minted),
                '"}'
            )
        );
    }
}
