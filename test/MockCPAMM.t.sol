// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MockCPAMM} from "../src/mock/MockCPAMM.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestToken is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, uint8 dec_) ERC20(n, n) {
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// Rehearsal-infrastructure tests for MockCPAMM (FUJI mock launch).
/// Mirrors the Fuji configuration: token0 = VSP (18 dec), token1 = USDC (6 dec),
/// seed 2_000e18 / 2_000e6 = 1 USDC per VSP (Schedule 1 defaults in SeedPool).
contract MockCPAMMTest is Test {
    TestToken vsp;
    TestToken usdc;
    MockCPAMM pool;
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");

    uint256 constant SEED_VSP = 2_000e18;
    uint256 constant SEED_USDC = 2_000e6;

    function setUp() public {
        vsp = new TestToken("VSP", 18);
        usdc = new TestToken("USDC", 6);
        pool = new MockCPAMM(IERC20(address(vsp)), IERC20(address(usdc)));
        vsp.mint(lp, SEED_VSP);
        usdc.mint(lp, SEED_USDC);
        vm.startPrank(lp);
        vsp.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.addLiquidity(SEED_VSP, SEED_USDC);
        vm.stopPrank();
    }

    function test_MainnetForbidden() public {
        vm.chainId(43114);
        vm.expectRevert(MockCPAMM.MainnetForbidden.selector);
        new MockCPAMM(IERC20(address(vsp)), IERC20(address(usdc)));
        vm.chainId(43113);
    }

    function test_SeedSetsLaunchPrice() public view {
        // 2_000e6 * 1e18 / 2_000e18 = 1e6 -> "1 USDC per VSP" in 1e18-scaled USDC units
        assertEq(pool.reserve0(), SEED_VSP);
        assertEq(pool.reserve1(), SEED_USDC);
        assertEq(pool.spotPrice0In1E18(), 1e6);
        assertGt(pool.shares(lp), 0);
        assertEq(pool.totalShares(), pool.shares(lp));
    }

    function test_SellVspMovesPriceDown_BuyMovesUp() public {
        uint256 p0 = pool.spotPrice0In1E18();
        vsp.mint(trader, 100e18);
        vm.startPrank(trader);
        vsp.approve(address(pool), type(uint256).max);
        uint256 usdcOut = pool.swap(true, 100e18, 0); // sell VSP
        vm.stopPrank();
        assertGt(usdcOut, 0);
        uint256 p1 = pool.spotPrice0In1E18();
        assertLt(p1, p0, "selling VSP must lower the VSP price");

        usdc.mint(trader, 500e6);
        vm.startPrank(trader);
        usdc.approve(address(pool), type(uint256).max);
        pool.swap(false, 500e6, 0); // buy VSP
        vm.stopPrank();
        assertGt(pool.spotPrice0In1E18(), p1, "buying VSP must raise the VSP price");
    }

    function test_FeeAccrues_KGrows() public {
        uint256 kBefore = pool.reserve0() * pool.reserve1();
        vsp.mint(trader, 50e18);
        vm.startPrank(trader);
        vsp.approve(address(pool), type(uint256).max);
        pool.swap(true, 50e18, 0);
        vm.stopPrank();
        uint256 kAfter = pool.reserve0() * pool.reserve1();
        assertGt(kAfter, kBefore, "0.3% fee must grow k for LPs");
    }

    function test_SwapRespectsMinOut() public {
        vsp.mint(trader, 10e18);
        vm.startPrank(trader);
        vsp.approve(address(pool), type(uint256).max);
        uint256 expectOut = (pool.reserve1() * (10e18 * 997)) / (pool.reserve0() * 1000 + 10e18 * 997);
        vm.expectRevert(abi.encodeWithSelector(MockCPAMM.InsufficientOutput.selector, expectOut, type(uint256).max));
        pool.swap(true, 10e18, type(uint256).max);
        vm.stopPrank();
    }

    function test_RemoveLiquidityReturnsProRata() public {
        uint256 half = pool.shares(lp) / 2;
        vm.prank(lp);
        (uint256 a0, uint256 a1) = pool.removeLiquidity(half);
        assertApproxEqAbs(a0, SEED_VSP / 2, 1);
        assertApproxEqAbs(a1, SEED_USDC / 2, 1);
        assertApproxEqAbs(pool.reserve0(), SEED_VSP / 2, 1);
    }
}
