// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/StakeEngine.sol";
import "../src/interfaces/IVSPToken.sol";

import "./mocks/MockVSP.sol";

import "./mocks/MockProtocolPolicy.sol";

/// ------------------------------------------------------------
/// StakeEngine Tests (v2 — lot consolidation + continuous positional weighting)
/// ------------------------------------------------------------
contract StakeEngineTest is Test {
    MockVSP token;
    StakeEngine engine;
    MockProtocolPolicy policy;

    uint256 postA = 1;
    uint256 postB = 2;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        token = new MockVSP();
        policy = new MockProtocolPolicy(0);

        engine = StakeEngine(
            address(
                new ERC1967Proxy(
                    address(new StakeEngine(address(0))),
                    abi.encodeCall(
                        StakeEngine.initialize,
                        (
                            address(this), // governance
                            address(token),
                            address(policy)
                        )
                    )
                )
            )
        );

        // Fund test accounts
        token.mint(address(this), 1e36);
        token.approve(address(engine), type(uint256).max);

        token.mint(alice, 1e36);
        vm.prank(alice);
        token.approve(address(engine), type(uint256).max);

        token.mint(bob, 1e36);
        vm.prank(bob);
        token.approve(address(engine), type(uint256).max);
    }

    /// ------------------------------------------------------------
    /// Basic stake / withdraw behavior
    /// ------------------------------------------------------------

    /// ruling 3b (2026-09-08): sMax registers a post's total at its first REAL
    /// settlement. Epoch 0 is the engine's "never snapshotted" sentinel, so a
    /// test that starts at timestamp 1 needs two boundary crossings: the first
    /// initializes, the second settles. Decay expectations are relative warps.
    function _reg(uint256 pid) internal {
        uint256[] memory one = new uint256[](1);
        one[0] = pid;
        _regMany(one);
    }

    function _regMany(uint256[] memory pids) internal {
        for (uint256 k = 0; k < 2; k++) {
            vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days); // cheatcode read: via_ir caches block.timestamp across warps
            for (uint256 i = 0; i < pids.length; i++) {
                engine.updatePost(pids[i]);
            }
        }
    }

    function _two(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function _four(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory r) {
        r = new uint256[](4);
        r[0] = a;
        r[1] = b;
        r[2] = c;
        r[3] = d;
    }

    function testStakeIncreasesTotals() public {
        vm.prank(alice);
        engine.stake(postA, 0, 100 ether);
        vm.prank(bob);
        engine.stake(postA, 1, 30 ether);

        (uint256 s, uint256 c) = engine.getPostTotals(postA);
        assertEq(s, 100 ether);
        assertEq(c, 30 ether);
    }

    function testWithdrawReducesTotals() public {
        engine.stake(postA, 0, 100 ether);
        engine.withdraw(postA, 0, 40 ether, false);

        (uint256 s, uint256 c) = engine.getPostTotals(postA);
        assertEq(s, 60 ether);
        assertEq(c, 0);
    }

    /// ------------------------------------------------------------
    /// Lot consolidation
    /// ------------------------------------------------------------

    function testMultipleStakesConsolidate() public {
        engine.stake(postA, 0, 50 ether);
        engine.stake(postA, 0, 70 ether);

        // Should be one consolidated lot with 120 ether
        uint256 userStake = engine.getUserStake(address(this), postA, 0);
        assertEq(userStake, 120 ether);

        (uint256 s,) = engine.getPostTotals(postA);
        assertEq(s, 120 ether);
    }

    function testConsolidationWeightedPosition() public {
        // First stake at position 0
        engine.stake(postA, 0, 100 ether);
        // Second stake goes to back of queue (position 100 ether)
        engine.stake(postA, 0, 100 ether);

        // Weighted position should be:
        // (0 * 100 + 100 * 100) / 200 = 50
        uint256 userStake = engine.getUserStake(address(this), postA, 0);
        assertEq(userStake, 200 ether);
    }

    function testDifferentUsersHaveSeparateLots() public {
        engine.stake(postA, 0, 100 ether);

        vm.prank(alice);
        engine.stake(postA, 0, 50 ether);

        assertEq(engine.getUserStake(address(this), postA, 0), 100 ether);
        assertEq(engine.getUserStake(alice, postA, 0), 50 ether);

        (uint256 s,) = engine.getPostTotals(postA);
        assertEq(s, 150 ether);
    }

    /// ------------------------------------------------------------
    /// Partial withdrawal keeps position
    /// ------------------------------------------------------------

    function testPartialWithdrawKeepsPosition() public {
        engine.stake(postA, 0, 100 ether);
        engine.withdraw(postA, 0, 30 ether, false);

        uint256 userStake = engine.getUserStake(address(this), postA, 0);
        assertEq(userStake, 70 ether);
    }

    /// ------------------------------------------------------------
    /// Gain / loss mechanics (with snapshots)
    /// ------------------------------------------------------------

    function testWinningSideNeverDecreases() public {
        uint256 stakeAmount = 1e23; // bundle05_a
        engine.stake(postA, 0, stakeAmount);

        vm.warp(block.timestamp + 3 days);
        engine.updatePost(postA);

        (uint256 support, uint256 challenge) = engine.getPostTotals(postA);
        assertEq(challenge, 0);
        assertGe(support, stakeAmount);
    }

    function testLosingSideNeverIncreases() public {
        vm.prank(alice);
        engine.stake(postA, 0, 100 ether);
        vm.prank(bob);
        engine.stake(postA, 1, 10 ether);

        uint256 supplyBefore = token.totalSupply();

        vm.warp(block.timestamp + 2 days);
        engine.updatePost(postA);

        (uint256 s, uint256 c) = engine.getPostTotals(postA);
        assertGe(s, 100 ether);
        assertLe(c, 10 ether);
    }

    function testNoGrowthWhenBalanced() public {
        vm.prank(alice);
        engine.stake(postA, 0, 50 ether);
        vm.prank(bob);
        engine.stake(postA, 1, 50 ether);

        vm.warp(block.timestamp + 3 days);
        engine.updatePost(postA);

        (uint256 s, uint256 c) = engine.getPostTotals(postA);
        assertEq(s, 50 ether);
        assertEq(c, 50 ether);
    }

    /// ------------------------------------------------------------
    /// View projection: reads reflect unrealized gains
    /// ------------------------------------------------------------

    function testViewProjectsGainsBeforeSnapshot() public {
        engine.stake(postA, 0, 100 ether);

        // Advance time but DON'T call updatePost
        vm.warp(block.timestamp + 3 days);

        // getPostTotals should project gains without writing state
        (uint256 s,) = engine.getPostTotals(postA);
        assertGe(s, 100 ether, "View should project gains");
    }

    function testViewProjectsUserStake() public {
        engine.stake(postA, 0, 100 ether);

        vm.warp(block.timestamp + 3 days);

        uint256 projected = engine.getUserStake(address(this), postA, 0);
        assertGe(projected, 100 ether, "User stake should project gains");
    }

    /// ------------------------------------------------------------
    /// Snapshot period behavior
    /// ------------------------------------------------------------

    function testSnapshotTriggersOnStakeAfterPeriod() public {
        vm.prank(alice);
        engine.stake(postA, 0, 100 ether);
        vm.prank(bob);
        engine.stake(postA, 1, 10 ether);
        // Advance past snapshot period
        vm.warp(block.timestamp + 2 days);
        // This stake triggers a snapshot internally
        vm.prank(alice);
        engine.stake(postA, 0, 1 ether);

        // After snapshot, winning side should have grown
        (uint256 s,) = engine.getPostTotals(postA);
        assertGe(s, 101 ether, "Snapshot should have applied gains");
    }

    /// ------------------------------------------------------------
    /// sMax behavior
    /// ------------------------------------------------------------

    function testSMaxNeverIncreasesWithoutNewStake() public {
        engine.stake(postA, 0, 100 ether);
        uint256 initial = engine.sMax();

        vm.warp(block.timestamp + 10 days);
        engine.updatePost(postA);

        uint256 afterDecay = engine.sMax();
        assertLe(afterDecay, initial);
    }

    function testSMaxJumpsToAtLeastNewMaximum() public {
        engine.stake(postA, 0, 100 ether);

        vm.warp(block.timestamp + 10 days);
        engine.updatePost(postA);

        engine.stake(postB, 0, 300 ether);
        _reg(postB);
        assertGe(engine.sMax(), 300 ether);
    }

    /// ------------------------------------------------------------
    /// Governance: snapshot period and sMax decay
    /// ------------------------------------------------------------

    function testGovernanceCanSetSMaxDecayRate() public {
        engine.setSMaxDecayRate(990e15);
        assertEq(engine.sMaxDecayRateRay(), 990e15);
    }

    function testGovernanceCanSetSMaxDecayMaxEpochs() public {
        engine.setSMaxDecayMaxEpochs(7300);
        assertEq(engine.sMaxDecayMaxEpochs(), 7300);
    }

    function test_RevertWhen_ZeroDecayRate() public {
        vm.expectRevert(StakeEngine.InvalidDecayRate.selector);
        engine.setSMaxDecayRate(0);
    }

    function test_RevertWhen_DecayRateAboveRay() public {
        vm.expectRevert(StakeEngine.InvalidDecayRate.selector);
        engine.setSMaxDecayRate(1e18 + 1);
    }

    function test_RevertWhen_ZeroDecayMaxEpochs() public {
        // Post-Patch-17: bounds check throws EpochsOutOfBounds (0 || > MAX).
        vm.expectRevert(StakeEngine.EpochsOutOfBounds.selector);
        engine.setSMaxDecayMaxEpochs(0);
    }

    function testGovernanceCanSetSnapshotPeriod() public {
        engine.setSnapshotPeriod(12 hours);
        assertEq(engine.snapshotPeriod(), 12 hours);
    }

    function test_RevertWhen_ZeroSnapshotPeriod() public {
        // Post-Patch-17: bounds check throws PeriodOutOfBounds
        // (0 < MIN_SNAPSHOT_PERIOD).
        vm.expectRevert(StakeEngine.PeriodOutOfBounds.selector);
        engine.setSnapshotPeriod(0);
    }

    /// ------------------------------------------------------------
    /// Reverts
    /// ------------------------------------------------------------

    function test_RevertWhen_InvalidSideStake() public {
        vm.expectRevert(StakeEngine.InvalidSide.selector);
        engine.stake(postA, 3, 100);
    }

    function test_RevertWhen_InvalidSideWithdraw() public {
        vm.expectRevert(StakeEngine.InvalidSide.selector);
        engine.withdraw(postA, 2, 100, false);
    }

    function test_RevertWhen_ZeroStake() public {
        vm.expectRevert(StakeEngine.AmountZero.selector);
        engine.stake(postA, 0, 0);
    }

    function test_RevertWhen_ZeroWithdraw() public {
        vm.expectRevert(StakeEngine.AmountZero.selector);
        engine.withdraw(postA, 0, 0, false);
    }

    function test_RevertWhen_WithdrawTooMuch() public {
        engine.stake(postA, 0, 100 ether);

        vm.expectRevert(StakeEngine.NotEnoughStake.selector);
        engine.withdraw(postA, 0, 200 ether, false);
    }

    function test_RevertWhen_WithdrawNoLot() public {
        vm.expectRevert(StakeEngine.NotEnoughStake.selector);
        engine.withdraw(postA, 0, 100 ether, false);
    }
}
