// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./base/SnapshotBase.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

/// Rehearsal of the VSP-SEC-003/004 mainnet upgrade path (patch_sec_upgrade_script): governance is the
/// TimelockController (Cold Safe = sole proposer/executor, minDelay 48 h), so the StakeEngine upgrade is
/// schedule(target = proxy, data = upgradeToAndCall(newImpl, ""), predecessor 0, salt) → 48 h →
/// execute. The tuple and the salt are the ones script/DeployStakeEngineImpl.s.sol prints; this test
/// proves the encoding (operation id == Timelock.hashOperation), the delay (execute reverts early),
/// that the proxy ends up on the new implementation, and that stakes, positions and the settlement
/// clock survive the upgrade unchanged.
contract SEC_UpgradeViaTimelock is SnapshotBase {
    address constant COLD_SAFE = address(0xC01D5AFE);
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    TimelockController tl;

    function _handGovernanceToTimelock() internal {
        address[] memory who = new address[](1);
        who[0] = COLD_SAFE;
        tl = new TimelockController(172800, who, who, address(0));
        se.proposeGovernance(address(tl));
        // the Timelock accepts through an operation of its own (as the Phase B hand-over did)
        bytes memory accept = abi.encodeWithSignature("acceptGovernance()");
        vm.prank(COLD_SAFE);
        tl.schedule(address(se), 0, accept, bytes32(0), keccak256("accept"), 172800);
        vm.warp(block.timestamp + 172800);
        vm.prank(COLD_SAFE);
        tl.execute(address(se), 0, accept, bytes32(0), keccak256("accept"));
        assertEq(se.governance(), address(tl), "Timelock governs");
        vm.warp(((block.timestamp / EPOCH) + 1) * EPOCH);
    }

    function test_SEC_upgradeThroughTimelock_preservesState() public {
        _handGovernanceToTimelock();
        // live state before the upgrade
        uint256 p = _claim("upgrade");
        _stake(A, p, 0, 1000e18);
        _stake(C, p, 1, 900e18);
        _nextEpoch();
        _keeperPass();
        uint256 epochBefore = se.getLastSnapshotEpoch(p);
        address oldImpl = address(uint160(uint256(vm.load(address(se), IMPL_SLOT))));

        // 1. anyone deploys the implementation (no owner; forwarder baked from the live proxy)
        address forwarder = se.trustedForwarder();
        vm.prank(address(0xDEB10));
        StakeEngine newImpl = new StakeEngine(forwarder);

        // 2. the tuple the script prints
        bytes memory data = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), bytes(""));
        bytes32 salt = keccak256("vsp-sec-003-004");
        bytes32 opId = keccak256(abi.encode(address(se), uint256(0), data, bytes32(0), salt));
        assertEq(opId, tl.hashOperation(address(se), 0, data, bytes32(0), salt), "operation id formula");

        // nobody but the Timelock may upgrade
        (bool ok,) =
            address(se).call(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), bytes("")));
        assertFalse(ok, "a direct upgrade call must revert (NotGovernance)");

        // 3. Cold Safe schedules; the delay is enforced
        vm.prank(COLD_SAFE);
        tl.schedule(address(se), 0, data, bytes32(0), salt, 172800);
        assertTrue(tl.isOperationPending(opId));
        // NB: with via_ir solc legitimately caches block.timestamp within a function (it cannot change
        // inside a real transaction); after vm.warp, read the clock through the cheatcode instead.
        uint256 readyAt = tl.getTimestamp(opId);
        assertEq(readyAt, vm.getBlockTimestamp() + 172800, "ready exactly 48 h after scheduling");
        _expectNotReady(data, salt);
        vm.warp(readyAt - 1);
        _expectNotReady(data, salt);

        // 4. 48 h later the Cold Safe executes. Readings taken in the same block, before and after:
        //    the views project with time, so "same block" is the fair comparison.
        vm.warp(tl.getTimestamp(opId));
        uint256 aBefore = se.getUserStake(A, p, 0);
        uint256 cBefore = se.getUserStake(C, p, 1);
        (uint256 S0, uint256 C0) = se.getTimeWeightedTotals(p, 0, 0);
        vm.prank(COLD_SAFE);
        tl.execute(address(se), 0, data, bytes32(0), salt);
        assertTrue(tl.isOperationDone(opId));
        address implNow = address(uint160(uint256(vm.load(address(se), IMPL_SLOT))));
        assertEq(implNow, address(newImpl), "proxy points at the new implementation");
        assertTrue(implNow != oldImpl);

        // 5. state preserved, protocol keeps settling
        assertEq(se.getUserStake(A, p, 0), aBefore, "A's position reads the same through the new implementation");
        assertEq(se.getUserStake(C, p, 1), cBefore, "C's position reads the same");
        assertEq(se.getLastSnapshotEpoch(p), epochBefore, "settlement clock preserved");
        assertEq(se.governance(), address(tl), "governance unchanged");
        (uint256 S, uint256 Cc) = se.getTimeWeightedTotals(p, 0, 0);
        assertEq(S, S0, "live support total intact");
        assertEq(Cc, C0, "live challenge total intact");
        _nextEpoch();
        _keeperPass();
        assertTrue(se.getLastSnapshotEpoch(p) > epochBefore, "settles after the upgrade");
    }

    /// execute before the delay has elapsed must revert with the Timelock's state error (Ready expected)
    function _expectNotReady(bytes memory data, bytes32 salt) internal {
        bytes32 id = tl.hashOperation(address(se), 0, data, bytes32(0), salt);
        bytes memory expected = abi.encodeWithSelector(
            TimelockController.TimelockUnexpectedOperationState.selector, id, bytes32(uint256(1 << 2))
        );
        vm.prank(COLD_SAFE);
        (bool ok, bytes memory err) = address(tl)
            .call(
                abi.encodeWithSignature(
                    "execute(address,uint256,bytes,bytes32,bytes32)", address(se), uint256(0), data, bytes32(0), salt
                )
            );
        assertFalse(ok, "execute before the delay must revert");
        assertEq(err, expected, "reverts because the operation is not Ready yet");
    }
}
