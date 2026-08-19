// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockCPAMM — minimal constant-product pool for the FUJI MOCK-LAUNCH ONLY
///
/// ############################  NOT FOR MAINNET  ############################
/// # This contract exists so the Fuji mock-launch can rehearse the           #
/// # public-AMM architecture (pool seeding, price discovery, treasury LP    #
/// # position custody) without depending on third-party testnet             #
/// # deployments. It is UNAUDITED REHEARSAL INFRASTRUCTURE. The mainnet     #
/// # venue is a real, established AMM chosen per MAINNET-PLAN §6            #
/// # ("Genesis split + LP seed"). Deployment scripts refuse chainid 43114.  #
/// ###########################################################################
///
/// Mechanics: classic x*y=k with a 0.3% swap fee accruing to LPs, and
/// square-root-share LP accounting. No flash-swap, no oracle, no
/// fee-on-transfer support, no permit — deliberately minimal.
contract MockCPAMM {
    using SafeERC20 for IERC20;

    IERC20 public immutable token0; // VSP
    IERC20 public immutable token1; // USDC (6 decimals on Fuji mock)

    uint256 public reserve0;
    uint256 public reserve1;

    uint256 public totalShares;
    mapping(address => uint256) public shares;

    error MainnetForbidden();
    error ZeroAmount();
    error InsufficientLiquidity();
    error InsufficientOutput(uint256 got, uint256 minOut);
    error InsufficientShares();

    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, uint256 minted);
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1, uint256 burned);
    event Swapped(address indexed trader, bool zeroForOne, uint256 amountIn, uint256 amountOut);

    constructor(IERC20 token0_, IERC20 token1_) {
        // Rehearsal-only tripwire: this mock must never exist on Avalanche mainnet.
        if (block.chainid == 43114) {
            revert MainnetForbidden();
        }
        token0 = token0_;
        token1 = token1_;
    }

    /// @notice Deposit both tokens; first deposit sets the price.
    ///         Subsequent deposits must match the current ratio (caller
    ///         sends exact amounts; any ratio drift favors the pool).
    function addLiquidity(uint256 amount0, uint256 amount1) external returns (uint256 minted) {
        if (amount0 == 0 || amount1 == 0) {
            revert ZeroAmount();
        }
        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);

        if (totalShares == 0) {
            minted = _sqrt(amount0 * amount1);
        } else {
            uint256 s0 = (amount0 * totalShares) / reserve0;
            uint256 s1 = (amount1 * totalShares) / reserve1;
            minted = s0 < s1 ? s0 : s1;
        }
        if (minted == 0) {
            revert InsufficientLiquidity();
        }
        shares[msg.sender] += minted;
        totalShares += minted;
        reserve0 += amount0;
        reserve1 += amount1;
        emit LiquidityAdded(msg.sender, amount0, amount1, minted);
    }

    /// @notice Burn shares, withdraw the proportional slice of both reserves.
    function removeLiquidity(uint256 burnShares) external returns (uint256 amount0, uint256 amount1) {
        if (burnShares == 0) {
            revert ZeroAmount();
        }
        if (shares[msg.sender] < burnShares) {
            revert InsufficientShares();
        }
        amount0 = (reserve0 * burnShares) / totalShares;
        amount1 = (reserve1 * burnShares) / totalShares;
        shares[msg.sender] -= burnShares;
        totalShares -= burnShares;
        reserve0 -= amount0;
        reserve1 -= amount1;
        token0.safeTransfer(msg.sender, amount0);
        token1.safeTransfer(msg.sender, amount1);
        emit LiquidityRemoved(msg.sender, amount0, amount1, burnShares);
    }

    /// @notice Swap exact `amountIn` of one side for the other. 0.3% fee.
    /// @param zeroForOne true: sell token0 (VSP) for token1 (USDC).
    function swap(bool zeroForOne, uint256 amountIn, uint256 minOut) external returns (uint256 amountOut) {
        if (amountIn == 0) {
            revert ZeroAmount();
        }
        if (reserve0 == 0 || reserve1 == 0) {
            revert InsufficientLiquidity();
        }
        (IERC20 tokenIn, IERC20 tokenOut, uint256 resIn, uint256 resOut) =
            zeroForOne ? (token0, token1, reserve0, reserve1) : (token1, token0, reserve1, reserve0);

        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 amountInWithFee = amountIn * 997;
        amountOut = (resOut * amountInWithFee) / (resIn * 1000 + amountInWithFee);
        if (amountOut < minOut) {
            revert InsufficientOutput(amountOut, minOut);
        }
        if (zeroForOne) {
            reserve0 += amountIn;
            reserve1 -= amountOut;
        } else {
            reserve1 += amountIn;
            reserve0 -= amountOut;
        }
        tokenOut.safeTransfer(msg.sender, amountOut);
        emit Swapped(msg.sender, zeroForOne, amountIn, amountOut);
    }

    /// @notice Spot price of token0 in token1 units, scaled by 1e18.
    ///         (For VSP/USDC-6: usdc_per_vsp_1e18 = reserve1 * 1e18 / reserve0.)
    function spotPrice0In1E18() external view returns (uint256) {
        if (reserve0 == 0) {
            return 0;
        }
        return (reserve1 * 1e18) / reserve0;
    }

    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
