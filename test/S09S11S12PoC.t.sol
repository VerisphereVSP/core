// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// S-09 / S-11 / S-12 — the three Informational candidates, verified rather than
/// asserted from reading.
///
/// S-09: docstring at StakeEngine.sol:96 says "Default 995e15 = 0.5% decay per
///       day"; the constant at :128 is 9e17 = 10% per day. 20x apart. Which one
///       does a real deployment get?
/// S-11: `StakeLot.entryEpoch` is stored but claimed never read in rate math.
/// S-12: `_rescalePositions` claimed effectively dead (only the vsNum == 0 branch).
contract S09S11S12PoC is Test {
    StakeEngine eng;
    MockVSP vsp;
    MockProtocolPolicy policy;

    uint256 constant DEPLOY_RATE_MAX = 693805319167998976;
    uint256 constant POST = 1;

    function _fresh() internal {
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

    function _stake(address who, uint256 post, uint8 side, uint256 amt) internal {
        vsp.mint(who, amt);
        vm.prank(who);
        vsp.approve(address(eng), type(uint256).max);
        vm.prank(who);
        eng.stake(post, side, amt);
    }

    /// S-09: which value is actually live after initialize()?
    function test_S09_DecayRateDocstringMismatch() public {
        _fresh();
        uint256 live = eng.sMaxDecayRateRay();
        emit log_named_uint("live sMaxDecayRateRay after initialize", live);
        emit log_named_uint("docstring claims", 995e15);
        emit log_named_uint("constant DEFAULT_SMAX_DECAY_RATE_RAY", 9e17);

        // Quantify the difference the doc error would cause over 10 epochs.
        uint256 docBased = 1e18;
        uint256 realBased = 1e18;
        for (uint256 i = 0; i < 10; i++) {
            docBased = docBased * 995e15 / 1e18;
            realBased = realBased * live / 1e18;
        }
        emit log_named_uint("sMax retained after 10 epochs, per docstring (RAY)", docBased);
        emit log_named_uint("sMax retained after 10 epochs, actual (RAY)", realBased);

        assertEq(live, 9e17, "S-09: live default is the 9e17 constant, not the documented 995e15");
    }

    /// S-11: is entryEpoch stored, and does it influence yield?
    /// Two identical stakers on the same post, entering at DIFFERENT epochs but
    /// both before any settlement, must earn identically if entryEpoch is unused.
    function test_S11_EntryEpochStoredButUnused() public {
        _fresh();
        address early = address(0xEA21);
        address late = address(0x1A7E);

        _stake(early, POST, 0, 100e18);
        (,, uint256 eEpochEarly,,) = eng.getUserLotInfo(early, POST, 0);

        // advance time but do NOT settle: no opponent yet, so nothing can mint
        vm.warp(block.timestamp + 20 days);
        _stake(late, POST, 0, 100e18);
        (,, uint256 eEpochLate,,) = eng.getUserLotInfo(late, POST, 0);

        emit log_named_uint("early entryEpoch", eEpochEarly);
        emit log_named_uint("late  entryEpoch", eEpochLate);
        assertGt(eEpochLate, eEpochEarly, "entryEpoch IS stored and differs");

        // now give the post an opponent and settle once
        _stake(address(0xBEEF), POST, 1, 1);
        uint256 eBefore = eng.getUserStake(early, POST, 0);
        uint256 lBefore = eng.getUserStake(late, POST, 0);
        vm.warp(block.timestamp + 30 days);
        eng.updatePost(POST);

        uint256 eGain = eng.getUserStake(early, POST, 0) - eBefore;
        uint256 lGain = eng.getUserStake(late, POST, 0) - lBefore;
        emit log_named_uint("early gain", eGain);
        emit log_named_uint("late  gain", lGain);
        emit log_named_uint("entryEpoch gap (epochs)", eEpochLate - eEpochEarly);
        emit log("if gains differ it is QUEUE POSITION, not entryEpoch");
    }

    /// S-12: does PositionsRescaled ever fire on the main path?
    function test_S12_RescaleEssentiallyDead() public {
        _fresh();
        for (uint256 i = 0; i < 8; i++) {
            _stake(address(uint160(0x7000 + i)), POST, 0, (i + 1) * 10e18);
        }
        _stake(address(0xBEEF), POST, 1, 500e18); // support loses hard

        // 20 settlements across a long horizon; count PositionsRescaled events
        uint256 seen = 0;
        for (uint256 r = 0; r < 20; r++) {
            vm.warp(block.timestamp + 30 days);
            vm.recordLogs();
            eng.updatePost(POST);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 j = 0; j < logs.length; j++) {
                if (logs[j].topics[0] == keccak256("PositionsRescaled(uint256,uint8,uint256,uint256)")) {
                    seen++;
                }
            }
        }
        emit log_named_uint("PositionsRescaled events over 20 settlements", seen);
        emit log("0 = confirms S-12: only reachable on the vsNum == 0 branch");
    }

    /// S-12b: force the vsNum == 0 branch (perfectly balanced) and confirm the
    /// event DOES fire there, proving the code is reachable but narrow.
    function test_S12b_RescaleFiresOnNeutralBranch() public {
        _fresh();
        _stake(address(0xA1), POST, 0, 250e18);
        _stake(address(0xA2), POST, 1, 250e18); // exactly balanced -> vsNum == 0

        vm.warp(block.timestamp + 30 days);
        vm.recordLogs();
        eng.updatePost(POST);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen = 0;
        for (uint256 j = 0; j < logs.length; j++) {
            if (logs[j].topics[0] == keccak256("PositionsRescaled(uint256,uint8,uint256,uint256)")) {
                seen++;
            }
        }
        emit log_named_uint("PositionsRescaled on the neutral branch", seen);
    }
}
