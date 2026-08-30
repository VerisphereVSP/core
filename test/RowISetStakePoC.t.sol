// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// ROW I — `setStake()` multi-leg flow.
///
/// setStake is the only entry point that can FLIP a user between sides. It does
/// so by calling _doWithdraw on the old side and then _increaseUser on the new
/// one (lines 532-556), each of which re-enters the position machinery. Two
/// concrete risks worth testing rather than asserting:
///
///   R1: I.5 bypass. `stake()` reverts with OppositeSideStaked, but setStake
///       flips deliberately. If the old-side clear ever leaves residue (bucket
///       rounding, ghost lot), the user ends up holding BOTH sides.
///   R2: conservation. Each leg does an external transfer interleaved with state
///       mutation. Net token movement must equal the net position change.
contract RowISetStakePoC is Test {
    StakeEngine eng;
    MockVSP vsp;
    MockProtocolPolicy policy;

    uint256 constant DEPLOY_RATE_MAX = 693805319167998976;
    uint256 constant POST = 1;
    uint256 constant C = 100;

    address alice = address(0xA11CE);

    function setUp() public {
        vm.warp(86400 * 1000);
        vsp = new MockVSP();
        policy = new MockProtocolPolicy(0);
        policy.setRates(0, DEPLOY_RATE_MAX);
        eng = StakeEngine(
            address(
                new ERC1967Proxy(
                    address(new StakeEngine(address(0))),
                    abi.encodeCall(StakeEngine.initialize, (address(this), address(vsp), address(policy)))
                )
            )
        );
        vsp.mint(address(this), 1e33);
        vsp.approve(address(eng), type(uint256).max);
    }

    function _fund(address who, uint256 amt) internal {
        vsp.mint(who, amt);
        vm.prank(who);
        vsp.approve(address(eng), type(uint256).max);
    }

    function _bothSides(address who) internal view returns (uint256 sup, uint256 chal) {
        sup = eng.getUserStake(who, POST, 0);
        chal = eng.getUserStake(who, POST, 1);
    }

    /// R1 fuzz: random flip sequences must never leave a user on both sides.
    function testFuzz_I5_NeverBothSidesAfterFlips(int256 t1, int256 t2, int256 t3, uint16 warpDays) public {
        int256 CAP = 1_000_000e18;
        t1 = t1 % CAP;
        t2 = t2 % CAP;
        t3 = t3 % CAP;
        uint256 d = uint256(warpDays) % 400;

        _fund(alice, 5_000_000e18);
        // give the post an opponent so settlement does something
        _fund(address(0xBEEF), 1000e18);
        vm.prank(address(0xBEEF));
        eng.stake(POST, 0, 1000e18);

        int256[3] memory targets = [t1, t2, t3];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(alice);
            eng.setStake(POST, targets[i]);

            (uint256 sup, uint256 chal) = _bothSides(alice);
            assertFalse(sup > 0 && chal > 0, "I.5 VIOLATED: alice holds both sides after setStake");

            if (d > 0) {
                vm.warp(block.timestamp + d * 1 days);
                eng.updatePost(POST);
                (sup, chal) = _bothSides(alice);
                assertFalse(sup > 0 && chal > 0, "I.5 VIOLATED after settlement");
            }
        }

        // solvency must hold through all of it
        (uint256 s, uint256 c) = eng.getPostTotals(POST);
        assertGe(vsp.balanceOf(address(eng)), s + c, "solvency broken by setStake flips");
    }

    /// R1 targeted: flip from a BUCKET position, where rounding is most likely to
    /// leave residue. Fill ranked first so alice lands in the bucket.
    function test_I5_FlipFromBucketPosition() public {
        for (uint256 i = 0; i < C; i++) {
            _fund(address(uint160(0x100000 + i)), 10e18);
            vm.prank(address(uint160(0x100000 + i)));
            eng.stake(POST, 1, 10e18); // challenge side ranked
        }
        _fund(alice, 100e18);
        vm.prank(alice);
        eng.setStake(POST, -5e18); // small challenge -> bucket

        (uint256 sup0, uint256 chal0) = _bothSides(alice);
        emit log_named_uint("alice support before flip", sup0);
        emit log_named_uint("alice challenge before flip (bucket)", chal0);

        // settle so bucketIndexRay moves off RAY
        _fund(address(0xBEEF), 1e18);
        vm.prank(address(0xBEEF));
        eng.stake(POST, 0, 1e18);
        vm.warp(block.timestamp + 120 days);
        eng.updatePost(POST);

        uint256 chalMid = eng.getUserStake(alice, POST, 1);
        emit log_named_uint("alice challenge after settle", chalMid);

        // now flip to support
        vm.prank(alice);
        eng.setStake(POST, 7e18);

        (uint256 sup1, uint256 chal1) = _bothSides(alice);
        emit log_named_uint("alice support after flip", sup1);
        emit log_named_uint("alice challenge after flip (must be 0)", chal1);

        assertEq(chal1, 0, "I.5: residue left on the old side after a bucket flip");
        (uint256 s, uint256 c) = eng.getPostTotals(POST);
        assertGe(vsp.balanceOf(address(eng)), s + c, "solvency after bucket flip");
    }

    /// R2: net token movement equals net position change across a flip.
    function test_R2_ConservationAcrossFlip() public {
        _fund(alice, 1000e18);
        _fund(address(0xBEEF), 500e18);
        vm.prank(address(0xBEEF));
        eng.stake(POST, 0, 500e18);

        uint256 walletBefore = vsp.balanceOf(alice);

        vm.prank(alice);
        eng.setStake(POST, -200e18); // 200 challenge
        vm.prank(alice);
        eng.setStake(POST, 150e18); // flip to 150 support

        (uint256 sup, uint256 chal) = _bothSides(alice);
        uint256 walletAfter = vsp.balanceOf(alice);

        emit log_named_uint("wallet before", walletBefore);
        emit log_named_uint("wallet after", walletAfter);
        emit log_named_uint("position support", sup);
        emit log_named_uint("position challenge", chal);
        emit log_named_uint("wallet spent", walletBefore - walletAfter);

        assertEq(chal, 0, "old side not cleared");
        assertEq(walletBefore - walletAfter, sup, "R2: tokens moved != position held");
    }
}
