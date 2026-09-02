// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Authority} from "../src/authority/Authority.sol";
import {VSPToken} from "../src/VSPToken.sol";
import {MockCPAMM} from "../src/mock/MockCPAMM.sol";

/// One-shot genesis supply-model invariants (patch_oneshot_genesis):
///   G1  after genesis, totalSupply == INCEPTION_SUPPLY (flat cap filled exactly)
///   G2  any further capped mint reverts, even 1 wei, even years later
///   G3  the exempt address (StakeEngine slot) can still mint (staking mechanics live)
///   G4  the flat cap never grows: maxAllowedSupply() == INCEPTION_SUPPLY at any t
///   G5  VestingWallet: nothing releasable before start; ~linear at midpoint;
///       everything at end; release() pays the beneficiary
///   G6  after revoking the deployer, the minter set is exactly {stakeEngine}
contract GenesisOneShotTest is Test {
    uint256 constant GENESIS = 1_000_000_000 * 1e18; // patch_genesis_1b: 1B exactly
    // patch_genesis_nolock: default genesis mints ALL of GENESIS to the treasury.
    // LOCKED below is only used by G5, which exercises the OPTIONAL lock path
    // (a lock added later by transferring treasury supply into a VestingWallet).
    uint256 constant LOCKED = 900_000_000 * 1e18;
    uint256 constant INCEPTION_TS = 1_778_544_000;
    uint64 constant VEST_DURATION = uint64(4 * 365 days);

    Authority authority;
    VSPToken token;
    VestingWallet vest;
    address deployer = address(this);
    address treasury = makeAddr("treasury");
    address stakeEngine = makeAddr("stakeEngine"); // stands in for the StakeEngine proxy
    address rando = makeAddr("rando");

    function setUp() public {
        vm.warp(INCEPTION_TS + 1 hours); // deploy shortly after inception
        authority = new Authority(deployer); // auto-grants deployer mint+burn
        VSPToken impl = new VSPToken(
            address(0),
            INCEPTION_TS,
            GENESIS,
            1e18, // flat growth: cap == INCEPTION_SUPPLY forever
            stakeEngine
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(VSPToken.initialize, (address(authority))));
        token = VSPToken(address(proxy));

        // genesis (no lock, patch_genesis_nolock): the whole supply to the treasury
        token.mint(treasury, GENESIS);

        // mirror the deploy script's end state: StakeEngine granted, deployer revoked
        authority.setMinter(stakeEngine, true);
        authority.setBurner(stakeEngine, true);
        authority.setMinter(deployer, false);
        authority.setBurner(deployer, false);
    }

    // G1
    function test_genesis_fills_flat_cap_exactly() public view {
        assertEq(token.totalSupply(), GENESIS);
        assertEq(token.totalSupply(), token.INCEPTION_SUPPLY());
        assertEq(token.maxAllowedSupply(), GENESIS);
    }

    // G2
    function test_capped_mint_reverts_forever_after_genesis() public {
        authority.setMinter(rando, true); // even a wrongly-granted minter...
        vm.warp(INCEPTION_TS + 3650 days); // ...even a decade later
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(VSPToken.MintExceedsTimeWindowCap.selector, GENESIS + 1, GENESIS));
        token.mint(rando, 1);
    }

    // G3
    function test_exempt_stake_engine_can_still_mint() public {
        vm.prank(stakeEngine);
        token.mint(stakeEngine, 500e18);
        assertEq(token.totalSupply(), GENESIS + 500e18);
        vm.prank(stakeEngine);
        token.burn(500e18);
        assertEq(token.totalSupply(), GENESIS);
    }

    // G4
    function test_flat_cap_never_grows(uint32 elapsed) public {
        vm.warp(INCEPTION_TS + uint256(elapsed));
        assertEq(token.maxAllowedSupply(), GENESIS);
    }

    // G5 — OPTIONAL lock path: the lock is not part of genesis; it can be added
    // later by moving treasury supply into a VestingWallet. Verifies the schedule
    // math and that the deferred path works unchanged.
    function test_vesting_schedule() public {
        vest = new VestingWallet(treasury, uint64(INCEPTION_TS), VEST_DURATION);
        vm.prank(treasury);
        token.transfer(address(vest), LOCKED);
        uint256 LIQUID = GENESIS - LOCKED;
        assertEq(token.balanceOf(address(vest)), LOCKED);
        assertEq(token.balanceOf(treasury), LIQUID);

        // nothing before start (warp back to just before inception)
        vm.warp(INCEPTION_TS - 1);
        assertEq(vest.releasable(address(token)), 0);

        // ~half at midpoint
        vm.warp(INCEPTION_TS + VEST_DURATION / 2);
        uint256 mid = vest.releasable(address(token));
        assertApproxEqRel(mid, LOCKED / 2, 1e12); // within 1e-6 relative

        vest.release(address(token)); // anyone may trigger; pays beneficiary
        assertEq(token.balanceOf(treasury), LIQUID + mid);

        // everything at end
        vm.warp(INCEPTION_TS + VEST_DURATION + 1);
        vest.release(address(token));
        assertEq(token.balanceOf(treasury), GENESIS);
        assertEq(token.balanceOf(address(vest)), 0);
    }

    // G5b — the no-lock genesis itself: whole supply sits with the treasury
    function test_genesis_no_lock_all_to_treasury() public view {
        assertEq(token.balanceOf(treasury), GENESIS);
        assertEq(token.totalSupply(), GENESIS);
    }

    // G6
    function test_minter_set_is_exactly_stake_engine() public view {
        assertTrue(authority.isMinter(stakeEngine));
        assertFalse(authority.isMinter(deployer));
        assertFalse(authority.isMinter(treasury));
        assertFalse(authority.isMinter(rando));
    }
}

/// MockCPAMM mechanics (rehearsal infra — still worth pinning down):
///   M1  mainnet constructor tripwire
///   M2  seed sets price; k holds across swaps (fee makes k non-decreasing)
///   M3  swap output matches x*y=k with 0.3% fee; minOut enforced
///   M4  remove returns the proportional slice including accrued fees
contract MockCPAMMTest is Test {
    VSPToken token; // reuse VSPToken as token0 for realism
    MockUSDC usdc;
    MockCPAMM pool;
    Authority authority;
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");

    function setUp() public {
        authority = new Authority(address(this));
        VSPToken impl = new VSPToken(address(0), block.timestamp, 1_000_000e18, 1e18, address(0));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(VSPToken.initialize, (address(authority))));
        token = VSPToken(address(proxy));
        usdc = new MockUSDC();
        pool = new MockCPAMM(IERC20(address(token)), IERC20(address(usdc)));

        token.mint(lp, 10_000e18);
        token.mint(trader, 1_000e18);
        usdc.mint(lp, 10_000e6);
        usdc.mint(trader, 1_000e6);
    }

    // M1
    function test_mainnet_tripwire() public {
        vm.chainId(43114);
        vm.expectRevert(MockCPAMM.MainnetForbidden.selector);
        new MockCPAMM(IERC20(address(token)), IERC20(address(usdc)));
        vm.chainId(31337);
    }

    function _seed(uint256 v, uint256 u) internal {
        vm.startPrank(lp);
        token.approve(address(pool), v);
        usdc.approve(address(pool), u);
        pool.addLiquidity(v, u);
        vm.stopPrank();
    }

    // M2 + M3
    function test_seed_price_and_swap_math() public {
        _seed(2_000e18, 2_000e6); // 1 USDC per VSP
        assertEq(pool.spotPrice0In1E18(), 1e6 * 1e18 / 1e18); // 1e6 units per 1e18 wei

        uint256 kBefore = pool.reserve0() * pool.reserve1();

        // trader buys VSP with 100 USDC
        vm.startPrank(trader);
        usdc.approve(address(pool), 100e6);
        uint256 inWithFee = uint256(100e6) * 997;
        uint256 expectedOut = (uint256(2_000e18) * inWithFee) / (uint256(2_000e6) * 1000 + inWithFee);
        uint256 got = pool.swap(false, 100e6, expectedOut);
        vm.stopPrank();

        assertEq(got, expectedOut);
        assertGe(pool.reserve0() * pool.reserve1(), kBefore); // fee accrues to k
        assertGt(pool.spotPrice0In1E18(), 1e6); // buys move price up

        // minOut enforcement
        vm.startPrank(trader);
        usdc.approve(address(pool), 10e6);
        vm.expectRevert();
        pool.swap(false, 10e6, type(uint256).max);
        vm.stopPrank();
    }

    // M4
    function test_remove_liquidity_includes_fees() public {
        _seed(2_000e18, 2_000e6);
        vm.startPrank(trader);
        usdc.approve(address(pool), 500e6);
        pool.swap(false, 500e6, 0);
        vm.stopPrank();

        uint256 myShares = pool.shares(lp);
        vm.prank(lp);
        (uint256 out0, uint256 out1) = pool.removeLiquidity(myShares);
        // sole LP gets everything back: post-swap reserves in full
        assertEq(out1, 2_500e6);
        assertGt(out0, 0);
        assertEq(pool.totalShares(), 0);
    }
}

contract MockUSDC {
    string public constant name = "Mock USDC";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}
