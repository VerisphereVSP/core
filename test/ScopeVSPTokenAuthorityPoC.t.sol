// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/VSPToken.sol";
import "../src/authority/Authority.sol";

/// SCOPE COVERAGE — VSPToken.sol + authority/Authority.sol
///
/// These two files were marked reviewed on a read-only basis. Everything asserted
/// about them in the report is verified here with a running test instead.
///
/// Targets, quoted from the source:
///   VSPToken:146-160  mint(): time cap enforced, STAKE_ENGINE_ADDRESS exempt
///   VSPToken:132-144  maxAllowedSupply(): PRB pow, behaviour at extreme elapsed
///   VSPToken:169-172  burnFrom(): must spend allowance
///   Authority:60-68   acceptOwner(): two-step, no zero-check on this path
///   Authority:74-82   setMinter/setBurner: onlyOwner
contract ScopeVSPTokenAuthorityPoC is Test {
    VSPToken tok;
    Authority auth;

    address governance = address(this);
    address engine = address(0xE9E9E9);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant INCEPTION_SUPPLY = 1_000_000e18;
    uint256 constant GROWTH_2X = 2e18; // doubles per year

    function setUp() public {
        vm.warp(86400 * 1000);
        auth = new Authority(governance);
        VSPToken impl = new VSPToken(address(0), block.timestamp, INCEPTION_SUPPLY, GROWTH_2X, engine);
        tok = VSPToken(address(new ERC1967Proxy(address(impl), abi.encodeCall(VSPToken.initialize, (address(auth))))));
        auth.setMinter(engine, true);
        auth.setBurner(engine, true);
    }

    // ── VSPToken: the time-based mint cap ────────────────────────────

    /// A capped (non-engine) minter must NOT be able to exceed maxAllowedSupply.
    function test_VSP_CappedMinterCannotExceedCap() public {
        uint256 cap = tok.maxAllowedSupply();
        emit log_named_uint("maxAllowedSupply at inception", cap);
        assertEq(cap, INCEPTION_SUPPLY, "at inception the cap is the inception supply");

        // governance is a minter (bootstrapped in the Authority constructor)
        tok.mint(alice, cap); // exactly at the cap must succeed
        assertEq(tok.totalSupply(), cap, "mint to exactly the cap failed");

        // one wei more must revert
        vm.expectRevert();
        tok.mint(alice, 1);
        emit log("capped minter correctly blocked at the ceiling");
    }

    /// STAKE_ENGINE_ADDRESS must be exempt — and ONLY that address.
    function test_VSP_EngineExemptButOnlyEngine() public {
        uint256 cap = tok.maxAllowedSupply();
        tok.mint(alice, cap); // fill to the ceiling

        // engine mints far beyond the cap: allowed by design
        vm.prank(engine);
        tok.mint(bob, cap * 10);
        assertEq(tok.totalSupply(), cap * 11, "engine exemption not working");
        emit log_named_uint("supply after engine over-mint", tok.totalSupply());

        // a different minter, even with the role, must still be capped
        auth.setMinter(alice, true);
        vm.prank(alice);
        vm.expectRevert();
        tok.mint(alice, 1);
        emit log("non-engine minter still capped after engine exceeded it");
    }

    /// Non-minters must be rejected outright.
    function test_VSP_NonMinterRejected() public {
        vm.prank(bob);
        vm.expectRevert(); // NotMinter
        tok.mint(bob, 1);

        vm.prank(bob);
        vm.expectRevert(); // NotBurner
        tok.burn(1);
    }

    /// maxAllowedSupply uses PRB pow. Check it grows as documented and does not
    /// revert or overflow at long horizons.
    function test_VSP_MaxAllowedSupplyGrowthCurve() public {
        // Use ABSOLUTE timestamps off the recorded inception, not chained relative
        // warps: chaining made an earlier version of this test read 2x at both the
        // 1-year and 2-year points and produce a false failure.
        uint256 inception = tok.INCEPTION_TIMESTAMP();
        uint256 atStart = tok.maxAllowedSupply();
        vm.warp(inception + 365 days);
        uint256 at1y = tok.maxAllowedSupply();
        vm.warp(inception + 730 days);
        uint256 at2y = tok.maxAllowedSupply();

        emit log_named_uint("cap at inception", atStart);
        emit log_named_uint("cap after 1 year", at1y);
        emit log_named_uint("cap after 2 years", at2y);

        // base 2e18 => doubling per year, within rounding
        assertApproxEqRel(at1y, atStart * 2, 1e15, "1-year cap is not ~2x");
        assertApproxEqRel(at2y, atStart * 4, 1e15, "2-year cap is not ~4x");
    }

    /// Extreme elapsed: must not revert. This is the overflow question the
    /// journal flagged on `pow`.
    function test_VSP_MaxAllowedSupplyExtremeElapsed() public {
        vm.warp(block.timestamp + 100 * 365 days);
        uint256 cap100y = tok.maxAllowedSupply();
        emit log_named_uint("cap after 100 years", cap100y);
        assertGt(cap100y, INCEPTION_SUPPLY, "cap did not grow over 100 years");
    }

    /// burnFrom must require an allowance — no burning other people's tokens.
    function test_VSP_BurnFromRequiresAllowance() public {
        tok.mint(alice, 1000e18);

        // governance is a burner but has no allowance from alice
        vm.expectRevert();
        tok.burnFrom(alice, 100e18);

        vm.prank(alice);
        tok.approve(governance, 100e18);
        tok.burnFrom(alice, 100e18);
        assertEq(tok.balanceOf(alice), 900e18, "burnFrom did not burn the approved amount");
        emit log("burnFrom correctly gated on allowance");
    }

    // ── Authority: two-step ownership + role gating ──────────────────

    /// Ownership must not transfer until the proposed owner accepts.
    function test_AUTH_TwoStepOwnershipRequiresAccept() public {
        auth.proposeOwner(alice);
        assertEq(auth.owner(), governance, "owner changed on propose alone");
        assertEq(auth.pendingOwner(), alice, "pendingOwner not set");

        // a third party cannot accept
        vm.prank(bob);
        vm.expectRevert(); // NotPendingOwner
        auth.acceptOwner();
        assertEq(auth.owner(), governance, "owner changed by a non-pending caller");

        vm.prank(alice);
        auth.acceptOwner();
        assertEq(auth.owner(), alice, "accept did not transfer ownership");
        assertEq(auth.pendingOwner(), address(0), "pendingOwner not cleared");
    }

    /// A pending proposal must be overridable, and the stale proposal must die.
    function test_AUTH_ProposalCanBeReplaced() public {
        auth.proposeOwner(alice);
        auth.proposeOwner(bob); // replace
        assertEq(auth.pendingOwner(), bob, "proposal not replaced");

        vm.prank(alice);
        vm.expectRevert(); // alice is stale now
        auth.acceptOwner();
        emit log("stale proposal correctly rejected");
    }

    /// proposeOwner must reject the zero address (the guard the journal noted).
    function test_AUTH_ProposeZeroRejected() public {
        vm.expectRevert(); // ZeroAddress
        auth.proposeOwner(address(0));
    }

    /// Role changes must be owner-only, and must follow ownership after transfer.
    function test_AUTH_RoleGatingFollowsOwnership() public {
        vm.prank(bob);
        vm.expectRevert(); // NotOwner
        auth.setMinter(bob, true);

        // hand ownership to alice
        auth.proposeOwner(alice);
        vm.prank(alice);
        auth.acceptOwner();

        // old owner loses the power
        vm.expectRevert(); // NotOwner
        auth.setMinter(bob, true);

        // new owner has it
        vm.prank(alice);
        auth.setMinter(bob, true);
        assertTrue(auth.isMinter(bob), "new owner cannot grant minter");
        emit log("role gating tracks ownership correctly");
    }

    /// The constructor bootstrap must grant BOTH roles to the initial owner.
    function test_AUTH_ConstructorBootstrap() public {
        Authority fresh = new Authority(alice);
        assertEq(fresh.owner(), alice, "owner not set");
        assertTrue(fresh.isMinter(alice), "bootstrap minter missing");
        assertTrue(fresh.isBurner(alice), "bootstrap burner missing");

        vm.expectRevert(); // ZeroAddress
        new Authority(address(0));
    }
}
