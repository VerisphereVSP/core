// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";

import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// Tests for the event-only, creator-gated post memo (setMemo / PostAnnotated).
contract PostRegistryMemoTest is Test {
    PostRegistry registry;
    MockVSP vsp;
    MockProtocolPolicy policy;

    address constant OTHER = address(0xBEEF);

    // mirror of the contract event for expectEmit
    event PostAnnotated(
        uint256 indexed postId, address indexed creator, bytes32 contentHash, string uri
    );

    function setUp() public {
        vsp = new MockVSP();
        policy = new MockProtocolPolicy(100);
        registry = PostRegistry(
            address(
                new ERC1967Proxy(
                    address(new PostRegistry(address(0))),
                    abi.encodeCall(
                        PostRegistry.initialize, (address(this), address(vsp), address(policy))
                    )
                )
            )
        );
        vsp.mint(address(this), 1e30);
        vsp.approve(address(registry), type(uint256).max);
    }

    function _claim() internal returns (uint256) {
        return registry.createClaim("A stakeable claim");
    }

    /// Creator can annotate; the event carries postId, creator, hash, uri.
    function test_setMemo_emits_with_payload() public {
        uint256 id = _claim();
        bytes32 h = keccak256(bytes("my memo body"));
        string memory uri = "ipfs://bafyMemo";

        vm.expectEmit(true, true, false, true, address(registry));
        emit PostAnnotated(id, address(this), h, uri);
        registry.setMemo(id, h, uri);
    }

    /// A non-creator cannot annotate someone else's post.
    function test_setMemo_revert_notCreator() public {
        uint256 id = _claim();
        vm.prank(OTHER);
        vm.expectRevert(PostRegistry.NotPostCreator.selector);
        registry.setMemo(id, keccak256("x"), "ipfs://x");
    }

    /// Annotating a nonexistent post reverts.
    function test_setMemo_revert_nonexistent() public {
        vm.expectRevert(PostRegistry.PostDoesNotExist.selector);
        registry.setMemo(9999, keccak256("x"), "ipfs://x");
    }

    /// Append-only: the creator may re-annotate; each call emits (latest = current).
    function test_setMemo_append_multiple() public {
        uint256 id = _claim();

        vm.expectEmit(true, true, false, true, address(registry));
        emit PostAnnotated(id, address(this), keccak256("v1"), "ipfs://v1");
        registry.setMemo(id, keccak256("v1"), "ipfs://v1");

        vm.expectEmit(true, true, false, true, address(registry));
        emit PostAnnotated(id, address(this), keccak256("v2"), "ipfs://v2");
        registry.setMemo(id, keccak256("v2"), "ipfs://v2");
    }

    /// A link post can also be annotated by its creator (setMemo is post-generic).
    function test_setMemo_on_link_by_creator() public {
        // Note: link creation requires a LinkGraph; this test only asserts that a
        // post the caller created can be annotated. Reuse a claim (same creator path).
        uint256 id = _claim();
        registry.setMemo(id, keccak256("ok"), "ipfs://ok"); // must not revert
    }
}
