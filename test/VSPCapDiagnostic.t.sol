// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/VSPToken.sol";
import "../src/authority/Authority.sol";

/// DIAGNOSTIC: why did maxAllowedSupply() read 2x at both 1 year and 2 years?
/// Either my test was wrong, or the growth curve genuinely stalls. Find out
/// before claiming anything.
contract VSPCapDiagnostic is Test {
    VSPToken tok;
    Authority auth;
    uint256 constant INCEPTION_SUPPLY = 1_000_000e18;
    uint256 constant GROWTH_2X = 2e18;
    uint256 t0;

    function setUp() public {
        vm.warp(86400 * 1000);
        t0 = block.timestamp;
        auth = new Authority(address(this));
        VSPToken impl = new VSPToken(address(0), t0, INCEPTION_SUPPLY, GROWTH_2X, address(0xE9));
        tok = VSPToken(address(new ERC1967Proxy(address(impl), abi.encodeCall(VSPToken.initialize, (address(auth))))));
    }

    function test_sweepCapOverTime() public {
        uint256[9] memory days_ = [uint256(0), 91, 182, 365, 400, 500, 730, 1095, 1460];
        for (uint256 i = 0; i < days_.length; i++) {
            vm.warp(t0 + days_[i] * 1 days);
            emit log_named_uint("--- days elapsed", days_[i]);
            emit log_named_uint("    block.timestamp", block.timestamp);
            emit log_named_uint("    maxAllowedSupply", tok.maxAllowedSupply());
        }
    }

    /// Read the immutables the contract actually got, and recompute by hand.
    function test_inspectImmutables() public {
        emit log_named_uint("INCEPTION_TIMESTAMP", tok.INCEPTION_TIMESTAMP());
        emit log_named_uint("INCEPTION_SUPPLY", tok.INCEPTION_SUPPLY());
        emit log_named_uint("GROWTH_BASE_PER_YEAR", tok.GROWTH_BASE_PER_YEAR());
        emit log_named_uint("t0 in test", t0);
    }
}
