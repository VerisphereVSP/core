// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakeEngine.sol";
import "../src/VSPToken.sol";
import "../src/authority/Authority.sol";
import "./mocks/MockProtocolPolicy.sol";

/// S-02 FINAL — same finding, but against the REAL VSPToken + Authority,
/// not MockVSP. Removes the "your mock caused it" objection.
///
/// Real-token specifics that matter here:
///   - mint/burn are role-gated via Authority (isMinter / isBurner)
///   - StakeEngine must be BOTH minter and burner
///   - StakeEngine is EXEMPT from the time-based supply cap
///     (constructor arg stakeEngine_ == STAKE_ENGINE_ADDRESS)
contract S02RealTokenPoC is Test {
    StakeEngine eng;
    VSPToken vsp;
    Authority authority;
    MockProtocolPolicy policy;

    uint256 constant POST = 7;
    uint256 constant DEPLOY_RATE_MAX = 693805319167998976;
    uint256 constant BIG = 1000e18;
    uint256 constant N_HONEST = 10;

    address attacker = address(0xA77AC7E2);

    function _deploy() internal {
        // StakeEngine proxy address must be known before the token, because the
        // token takes it as an immutable. Deploy engine proxy first with a
        // placeholder token, then wire. Simpler: predict via CREATE ordering is
        // fragile, so deploy engine impl+proxy first using address(0) token and
        // re-initialize is not possible (initializer). Instead: deploy token with
        // a computed engine address using vm.computeCreateAddress.
        //
        // Cleanest reliable path: deploy the engine proxy FIRST but initialize it
        // AFTER the token exists. ERC1967Proxy requires init data at construction,
        // so instead we precompute the engine proxy address.

        address engineImpl = address(new StakeEngine(address(0)));

        // engine proxy will be the next contract created by this test contract
        // after the token + authority. Compute it explicitly.
        // Order below: authority -> tokenImpl -> tokenProxy -> engineProxy
        policy = new MockProtocolPolicy(0);
        policy.setRates(0, DEPLOY_RATE_MAX);

        uint256 nonceNow = vm.getNonce(address(this));
        // creation order from here: authority(+0), tokenImpl(+1), tokenProxy(+2), engineProxy(+3)
        address predictedEngine = vm.computeCreateAddress(address(this), nonceNow + 3);

        authority = new Authority(address(this));
        VSPToken tokenImpl = new VSPToken(
            address(0),
            block.timestamp,
            1_000_000_000e18, // large inception supply so the cap is never the binding constraint
            2e18,
            predictedEngine
        );
        ERC1967Proxy tokenProxy =
            new ERC1967Proxy(address(tokenImpl), abi.encodeCall(VSPToken.initialize, (address(authority))));
        vsp = VSPToken(address(tokenProxy));

        ERC1967Proxy engProxy = new ERC1967Proxy(
            engineImpl, abi.encodeCall(StakeEngine.initialize, (address(this), address(vsp), address(policy)))
        );
        eng = StakeEngine(address(engProxy));

        require(address(eng) == predictedEngine, "engine address prediction failed");

        // StakeEngine needs mint + burn rights
        authority.setMinter(address(eng), true);
        authority.setBurner(address(eng), true);
    }

    function _fund(address who, uint256 amt) internal {
        vsp.mint(who, amt); // this test contract is owner => minter
        vm.prank(who);
        vsp.approve(address(eng), type(uint256).max);
    }

    struct Result {
        uint256 minted;
        uint256 attackerGain;
        uint256 honestGainSum;
        uint256 claims;
        uint256 engineBal;
    }

    function _scenario(bool useGhost) internal returns (Result memory r) {
        vm.warp(86400 * 1000);
        _deploy();

        if (useGhost) {
            _fund(attacker, 1);
            vm.prank(attacker);
            eng.stake(POST, 0, 1);
            vm.prank(attacker);
            eng.withdraw(POST, 0, 1, true);
        }

        for (uint256 i = 0; i < N_HONEST; i++) {
            address h = address(uint160(0x5000 + i));
            _fund(h, BIG);
            vm.prank(h);
            eng.stake(POST, 0, BIG);
        }

        _fund(attacker, BIG);
        vm.prank(attacker);
        eng.stake(POST, 0, BIG);

        address chal = address(0xBEEF);
        _fund(chal, 1);
        vm.prank(chal);
        eng.stake(POST, 1, 1);

        uint256 supplyBefore = vsp.totalSupply();

        vm.warp(block.timestamp + 30 days);
        eng.updatePost(POST);

        r.minted = vsp.totalSupply() - supplyBefore;
        r.attackerGain = eng.getUserStake(attacker, POST, 0) - BIG;
        for (uint256 i = 0; i < N_HONEST; i++) {
            r.honestGainSum += eng.getUserStake(address(uint160(0x5000 + i)), POST, 0) - BIG;
        }
        (uint256 s, uint256 c) = eng.getPostTotals(POST);
        r.claims = s + c;
        r.engineBal = vsp.balanceOf(address(eng));
    }

    function test_S02_RealToken() public {
        Result memory a = _scenario(true);
        Result memory b = _scenario(false);

        emit log("=== REAL VSPToken + Authority ===");
        emit log_named_uint("minted WITH ghost", a.minted);
        emit log_named_uint("minted WITHOUT ghost", b.minted);
        emit log_named_uint("attacker gain WITH ghost", a.attackerGain);
        emit log_named_uint("attacker gain WITHOUT ghost", b.attackerGain);
        emit log_named_uint("honest sum WITH ghost", a.honestGainSum);
        emit log_named_uint("honest sum WITHOUT ghost", b.honestGainSum);
        emit log_named_uint("claims WITH ghost", a.claims);
        emit log_named_uint("engine bal WITH ghost", a.engineBal);

        uint256 excess = a.attackerGain - b.attackerGain;
        uint256 shortfall = b.honestGainSum - a.honestGainSum;
        emit log_named_uint("attacker excess", excess);
        emit log_named_uint("honest shortfall", shortfall);

        // Same three claims as the mock-based severity test
        assertEq(a.minted, b.minted, "no extra inflation caused by the ghost");
        assertGe(a.engineBal, a.claims, "engine remains solvent");
        assertEq(excess, shortfall, "zero-sum transfer, exact to the wei");
        // patch_prA_s02_regression: with the S-02 v2 fix the ghost path must yield ZERO advantage.
        assertEq(a.attackerGain, b.attackerGain, "S-02 regression: ghost yields no advantage");
    }
}
