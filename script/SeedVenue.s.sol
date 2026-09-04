// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SeedVenue — REAL-VENUE pool creation + initial liquidity seed
///
/// patch_venue: replaces the MockCPAMM rehearsal (SeedPool.s.sol) with the
/// production venue class chosen 2026-09-03: canonical UniswapV2-INTERFACE
/// pools. One script serves both rungs of the ladder:
///   Fuji rehearsal  -> LFJ Joe V1   (third-party UniV2 fork, already deployed)
///   Mainnet launch  -> Uniswap v2 on Avalanche C-Chain (board consent #4)
/// because addLiquidity/getPair/getReserves are interface-identical.
///
/// The router creates the pair automatically if it does not exist. Token
/// ordering inside the pair is BY ADDRESS SORT (UniV2 rule) — nothing here or
/// downstream may assume VSP==token0; readers detect orientation via token0().
///
/// Env:
///   DEPLOYER_PRIVATE_KEY   seeder key (holds the VSP + USDC amounts)
///   VSP_TOKEN_ADDRESS      VSPToken proxy (addresses.json)
///   USDC_ADDRESS           chain USDC
///   VENUE_ROUTER           UniV2-interface router (JoeRouter02 / UniswapV2Router02)
///   LP_SEED_VSP_WEI        VSP side  (default 2_000e18 — Schedule 1 open param)
///   LP_SEED_USDC_UNITS     USDC side (default 2_000e6  — Schedule 1 open param)
///   MAINNET_SEED_CONFIRM   must be 1 on chainid 43114 — the mainnet seed is a
///                          board-consent ceremony act, not a casual run.
contract SeedVenue is Script {
    function run() external {
        if (block.chainid == 43114) {
            require(
                vm.envOr("MAINNET_SEED_CONFIRM", uint256(0)) == 1,
                "SeedVenue: mainnet seed requires MAINNET_SEED_CONFIRM=1 (board consent ceremony)"
            );
        }

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address seeder = vm.addr(pk);

        address vspAddr = vm.envAddress("VSP_TOKEN_ADDRESS");
        address usdcAddr = vm.envAddress("USDC_ADDRESS");
        IERC20 vsp = IERC20(vspAddr);
        IERC20 usdc = IERC20(usdcAddr);
        IUniV2Router router = IUniV2Router(vm.envAddress("VENUE_ROUTER"));
        IUniV2Factory factory = IUniV2Factory(router.factory());

        uint256 seedVsp = vm.envOr("LP_SEED_VSP_WEI", uint256(2_000 * 1e18));
        uint256 seedUsdc = vm.envOr("LP_SEED_USDC_UNITS", uint256(2_000 * 1e6));

        require(vsp.balanceOf(seeder) >= seedVsp, "SeedVenue: seeder VSP balance short");
        require(usdc.balanceOf(seeder) >= seedUsdc, "SeedVenue: seeder USDC balance short");

        vm.startBroadcast(pk);

        vsp.approve(address(router), seedVsp);
        usdc.approve(address(router), seedUsdc);
        // amountMin = exact amounts on a fresh pair (ratio is set by us); on a
        // pre-existing pair with drifted ratio this reverts rather than
        // silently seeding at a price nobody consented to.
        (uint256 aVsp, uint256 aUsdc, uint256 liquidity) =
            router.addLiquidity(vspAddr, usdcAddr, seedVsp, seedUsdc, seedVsp, seedUsdc, seeder, block.timestamp + 900);

        vm.stopBroadcast();

        address pair = factory.getPair(vspAddr, usdcAddr);
        require(pair != address(0), "SeedVenue: pair not found after addLiquidity");
        (uint112 r0, uint112 r1,) = IUniV2Pair(pair).getReserves();
        address t0 = IUniV2Pair(pair).token0();

        console.log("PAIR:", pair);
        console.log("token0:", t0);
        console.log("token0 is VSP:", t0 == vspAddr);
        console.log("deposited VSP(wei) / USDC(units):", aVsp, aUsdc);
        console.log("LP tokens minted to seeder:", liquidity);
        console.log("reserves r0 / r1:", uint256(r0), uint256(r1));

        string memory dir = string.concat("broadcast/SeedVenue.s.sol/", vm.toString(block.chainid));
        vm.createDir(dir, true); // the SeedPool lesson: forge won't create parent dirs
        vm.writeFile(
            string.concat(dir, "/pool.json"),
            string.concat(
                '{"pair":"',
                vm.toString(pair),
                '","router":"',
                vm.toString(address(router)),
                '","factory":"',
                vm.toString(address(factory)),
                '","token0":"',
                vm.toString(t0),
                '","venue":"univ2","chainid":',
                vm.toString(block.chainid),
                "}"
            )
        );
    }
}

interface IUniV2Router {
    function factory() external view returns (address);
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

interface IUniV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface IUniV2Pair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}
