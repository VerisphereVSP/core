// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LinkGraph.sol";
import "./interfaces/IVSPToken.sol";
import "./interfaces/IProtocolPolicy.sol";
import "./governance/GovernedUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PostRegistry
/// @notice Creates claims and links on-chain.
///         Supports gasless meta-transactions via ERC-2771.
///         Rejects duplicate claims (case-insensitive, whitespace-normalized).
///         Rejects duplicate links (same from, to, and challenge type).
///         Burns posting fees on creation (deflationary).
///
/// @dev    Post IDs start at 1 (not 0) so that downstream consumers can safely
///         use 0 / falsy checks as "no post" sentinels in JavaScript, Solidity
///         mappings, and database columns.
///
///         Link direction: from → to means "from provides evidence for/against to".
///         Example: createLink(from=S, to=F, isChallenge=true) means
///         "claim S challenges claim F" — S is outgoing, F receives incoming.
contract PostRegistry is GovernedUpgradeable {
    enum ContentType {
        Claim,
        Link
    }

    struct Post {
        address creator;
        uint256 timestamp;
        ContentType contentType;
        uint256 contentId;
        uint256 creationFee;
    }

    struct Claim {
        string text;
    }

    struct Link {
        uint256 fromPostId;
        uint256 toPostId;
        bool isChallenge;
    }

    mapping(uint256 => Post) private posts;
    Claim[] private claims;
    Link[] private links;

    uint256 public nextPostId;

    LinkGraph public linkGraph;
    IVSPToken public vspToken;
    IProtocolPolicy public protocolPolicy;

    /// @notice Maps normalized content hash to postId + 1.
    ///         Default 0 means no claim exists with that hash.
    mapping(bytes32 => uint256) private claimHashToPostIdPlusOne;

    // ─────────────────────────────────────────────────────────────────
    // Pause / Guardian (patch12b)
    // ─────────────────────────────────────────────────────────────────
    //
    // guardian can call pause() (fast emergency halt). Only governance
    // can unpause(), so resuming is a deliberate multisig+timelock step.
    address public guardian;
    bool public paused;
    bool internal _initializedV2;

    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event GuardianSet(address indexed oldGuardian, address indexed newGuardian);

    error WhenPaused();
    error ZeroAddressPolicy();
    error NotGuardianOrGovernance();
    error AlreadyInitializedV2();

    modifier whenNotPaused() {
        if (paused) {
            revert WhenPaused();
        }
        _;
    }

    event PostCreated(uint256 indexed postId, address indexed creator, ContentType contentType);
    event LinkGraphSet(address indexed linkGraph);
    event FeeBurned(uint256 indexed postId, uint256 feeAmount);
    /// @notice Emitted when a post's creator attaches an off-chain memo.
    /// Event-only (no storage); append-only (latest emission is current);
    /// contentHash = keccak256 of the memo content (tamper-evidence), uri locates it.
    event PostAnnotated(uint256 indexed postId, address indexed creator, bytes32 contentHash, string uri);

    error InvalidClaim();
    error ClaimTooLong(uint256 length, uint256 max);

    uint256 public constant MAX_CLAIM_LENGTH = 1000; // bundle05_d: tightened from 2000
    error DuplicateClaim(uint256 existingPostId);
    error DuplicateLink(uint256 fromPostId, uint256 toPostId, bool isChallenge);
    error FromPostDoesNotExist();
    error ToPostDoesNotExist();
    error FromPostMustBeClaim();
    error ToPostMustBeClaim();
    error PostDoesNotExist();
    error NotPostCreator();
    error LinkGraphZeroAddress();
    error LinkGraphNotSet();
    error FeeTransferFailed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder_) GovernedUpgradeable(trustedForwarder_) {}

    function initialize(address governance_, address vspToken_, address protocolPolicy_) external initializer {
        __GovernedUpgradeable_init(governance_);
        vspToken = IVSPToken(vspToken_);
        protocolPolicy = IProtocolPolicy(protocolPolicy_);
        nextPostId = 1;
    }

    /// @notice Set or update the LinkGraph address. Governance-only.
    function setLinkGraph(address linkGraph_) external onlyGovernance {
        if (linkGraph_ == address(0)) {
            revert LinkGraphZeroAddress();
        }
        linkGraph = LinkGraph(linkGraph_);
        emit LinkGraphSet(linkGraph_);
    }

    // -------- Pause / Guardian admin (patch12b) --------

    /// @notice One-shot V2 initializer. Sets initial Guardian after
    ///         upgrade-in-place. Only governance, only once.
    function initializeV2(address guardian_) external onlyGovernance {
        if (_initializedV2) {
            revert AlreadyInitializedV2();
        }
        _initializedV2 = true;
        guardian = guardian_;
        emit GuardianSet(address(0), guardian_);
    }

    /// @notice Pause new claim/link creation. Callable by Guardian
    ///         (fast emergency response) or by governance (deliberate).
    function pause() external {
        address sender = _msgSender();
        if (sender != guardian && sender != governance) {
            revert NotGuardianOrGovernance();
        }
        paused = true;
        emit Paused(sender);
    }

    /// @notice Unpause. Governance only — slower, deliberate restore.
    function unpause() external onlyGovernance {
        paused = false;
        emit Unpaused(_msgSender());
    }

    /// @notice Replace the Guardian. Governance only.
    function setGuardian(address newGuardian) external onlyGovernance {
        address old = guardian;
        guardian = newGuardian;
        emit GuardianSet(old, newGuardian);
    }

    // -------- Core write methods --------

    function createClaim(string calldata text_) external whenNotPaused returns (uint256 postId) {
        if (bytes(text_).length == 0) {
            revert InvalidClaim();
        }
        if (bytes(text_).length > MAX_CLAIM_LENGTH) {
            revert ClaimTooLong(bytes(text_).length, MAX_CLAIM_LENGTH);
        }

        // Duplicate check BEFORE charging fee -- no VSP burned on revert
        bytes32 normalizedHash = _normalizeAndHash(text_);
        uint256 existing = claimHashToPostIdPlusOne[normalizedHash];
        if (existing != 0) {
            revert DuplicateClaim(existing - 1);
        }

        postId = nextPostId++;

        uint256 fee = _chargeFee(postId);

        uint256 claimId = claims.length;
        claims.push(Claim({text: text_}));

        posts[postId] = Post({
            creator: _msgSender(),
            timestamp: block.timestamp,
            contentType: ContentType.Claim,
            contentId: claimId,
            creationFee: fee
        });

        claimHashToPostIdPlusOne[normalizedHash] = postId + 1;

        emit PostCreated(postId, _msgSender(), ContentType.Claim);
    }

    /// @notice Attach an off-chain memo to a post you created. Emits an event
    /// only -- no on-chain storage, no change to post creation cost. May be
    /// called repeatedly (append-only); off-chain consumers treat the latest
    /// PostAnnotated for a post as current. Content lives off-chain at `uri`;
    /// `contentHash` is keccak256(content) for tamper-evidence.
    /// @param postId The post to annotate (must exist and be caller's).
    /// @param contentHash keccak256 of the memo content.
    /// @param uri Locator for the memo content (e.g. https/ipfs).
    function setMemo(uint256 postId, bytes32 contentHash, string calldata uri) external whenNotPaused {
        if (!_exists(postId)) {
            revert PostDoesNotExist();
        }
        if (posts[postId].creator != _msgSender()) {
            revert NotPostCreator();
        }
        emit PostAnnotated(postId, _msgSender(), contentHash, uri);
    }

    /// @notice Create a link between two claims.
    /// @param fromPostId The claim providing evidence (outgoing end).
    /// @param toPostId   The claim receiving evidence (incoming end).
    /// @param isChallenge True if fromPostId challenges toPostId, false if it supports.
    function createLink(uint256 fromPostId, uint256 toPostId, bool isChallenge)
        external
        whenNotPaused
        returns (uint256 postId)
    {
        if (address(linkGraph) == address(0)) {
            revert LinkGraphNotSet();
        }
        if (!_exists(fromPostId)) {
            revert FromPostDoesNotExist();
        }
        if (!_exists(toPostId)) {
            revert ToPostDoesNotExist();
        }

        Post memory fromPost = posts[fromPostId];
        Post memory toPost = posts[toPostId];
        if (fromPost.contentType != ContentType.Claim) {
            revert FromPostMustBeClaim();
        }
        if (toPost.contentType != ContentType.Claim) {
            revert ToPostMustBeClaim();
        }

        // Duplicate link check BEFORE charging fee -- no VSP burned on revert
        if (linkGraph.hasEdge(fromPostId, toPostId, isChallenge)) {
            revert DuplicateLink(fromPostId, toPostId, isChallenge);
        }

        postId = nextPostId++;

        uint256 fee = _chargeFee(postId);

        uint256 linkId = links.length;
        links.push(Link({fromPostId: fromPostId, toPostId: toPostId, isChallenge: isChallenge}));

        posts[postId] = Post({
            creator: _msgSender(),
            timestamp: block.timestamp,
            contentType: ContentType.Link,
            contentId: linkId,
            creationFee: fee
        });

        linkGraph.addEdge(fromPostId, toPostId, postId, isChallenge);

        emit PostCreated(postId, _msgSender(), ContentType.Link);
    }

    // -------- View methods --------

    function getPost(uint256 postId) external view returns (Post memory) {
        return posts[postId];
    }

    function getClaim(uint256 claimId) external view returns (string memory) {
        return claims[claimId].text;
    }

    function getLink(uint256 linkId) external view returns (Link memory) {
        return links[linkId];
    }

    /// @notice Check if a claim with this text already exists on-chain.
    /// @return existingPostId The postId, or type(uint256).max if not found.
    function findClaim(string calldata text_) external view returns (uint256 existingPostId) {
        bytes32 h = _normalizeAndHash(text_);
        uint256 stored = claimHashToPostIdPlusOne[h];
        if (stored == 0) {
            return type(uint256).max;
        }
        return stored - 1;
    }

    // -------- Governance: backfill existing claims --------

    function backfillClaimHashes(uint256[] calldata postIds) external onlyGovernance {
        for (uint256 i = 0; i < postIds.length; i++) {
            uint256 pid = postIds[i];
            if (pid >= nextPostId) {
                continue;
            }

            Post memory p = posts[pid];
            if (p.contentType != ContentType.Claim) {
                continue;
            }

            string memory claimText = claims[p.contentId].text;
            bytes32 h = _normalizeBytes(bytes(claimText));

            if (claimHashToPostIdPlusOne[h] == 0) {
                claimHashToPostIdPlusOne[h] = pid + 1;
            }
        }
    }

    // -------- Internal --------

    function _normalizeAndHash(string calldata text_) internal pure returns (bytes32) {
        return _normalizeBytes(bytes(text_));
    }

    function _normalizeBytes(bytes memory raw) internal pure returns (bytes32) {
        bytes memory buf = new bytes(raw.length);
        uint256 j = 0;
        bool lastWasSpace = true;

        for (uint256 i = 0; i < raw.length; i++) {
            bytes1 ch = raw[i];

            if (ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D) {
                if (!lastWasSpace) {
                    buf[j++] = 0x20;
                    lastWasSpace = true;
                }
                continue;
            }

            if (ch >= 0x41 && ch <= 0x5A) {
                ch = bytes1(uint8(ch) + 32);
            }

            buf[j++] = ch;
            lastWasSpace = false;
        }

        if (j > 0 && buf[j - 1] == 0x20) {
            j--;
        }

        bytes memory result = new bytes(j);
        for (uint256 i = 0; i < j; i++) {
            result[i] = buf[i];
        }
        return keccak256(result);
    }

    function _chargeFee(uint256 postId) internal returns (uint256 fee) {
        fee = protocolPolicy.postingFeeVSP();
        if (fee == 0) {
            return 0;
        }

        bool ok = IERC20(address(vspToken)).transferFrom(_msgSender(), address(this), fee);
        if (!ok) {
            revert FeeTransferFailed();
        }

        vspToken.burn(fee);
        emit FeeBurned(postId, fee);
    }

    function _exists(uint256 postId) internal view returns (bool) {
        // H3 (security review 2026-09): IDs start at 1; posts[0] is an
        // uninitialized struct whose contentType defaults to Claim, so the
        // old `postId < nextPostId` made a phantom "claim 0" linkable and
        // scoreable with no text and no author.
        return postId != 0 && postId < nextPostId;
    }

    uint256[499] private __gap;

    /// @notice Replace the ProtocolPolicy address. Governance only.
    event ProtocolPolicySet(address indexed oldPolicy, address indexed newPolicy);

    function setProtocolPolicy(address newProtocolPolicy) external onlyGovernance {
        if (newProtocolPolicy == address(0)) {
            revert ZeroAddressPolicy();
        }
        address old = address(protocolPolicy);
        protocolPolicy = IProtocolPolicy(newProtocolPolicy);
        emit ProtocolPolicySet(old, newProtocolPolicy);
    }
}
