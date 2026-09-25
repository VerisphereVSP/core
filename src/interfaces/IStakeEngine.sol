// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStakeEngine {
    function SIDE_SUPPORT() external pure returns (uint8);
    function SIDE_CHALLENGE() external pure returns (uint8);

    function stake(uint256 postId, uint8 side, uint256 amount) external;
    function withdraw(uint256 postId, uint8 side, uint256 amount, bool lifo) external;
    function updatePost(uint256 postId) external;

    /// @notice Returns projected totals (already includes unrealized gains/losses).
    function getPostTotals(uint256 postId) external view returns (uint256 support, uint256 challenge);

    // patch_game_b (whitepaper v17 §4.2.5)
    function getTimeWeightedTotals(uint256 postId, uint256 t0, uint256 t1)
        external
        view
        returns (uint256 support, uint256 challenge);
    function getLastSnapshotEpoch(uint256 postId) external view returns (uint256);
    function EPOCH_LENGTH() external view returns (uint256);

    /// @notice Returns projected user stake (already includes unrealized gains/losses).
    function getUserStake(address user, uint256 postId, uint8 side) external view returns (uint256);

    /// @notice Remove zero-amount ghost lots. Governance-only.
    function compactLots(uint256 postId, uint8 side) external;

    function sMaxDecayRateRay() external view returns (uint256);
    function sMaxDecayMaxEpochs() external view returns (uint256);
    function setSMaxDecayRate(uint256 newRate) external;
    function setSMaxDecayMaxEpochs(uint256 newMax) external;
    /// @notice Returns lot info for a user's position.
    /// @dev patch_prC_rulings S-11: entryEpoch dropped from the tuple.
    function getUserLotInfo(address user, uint256 postId, uint8 side)
        external
        view
        returns (uint256 amount, uint256 weightedPosition, uint256 sideTotal, uint256 positionWeight);

    /// @notice patch_prC_rulings S-03: permissionless sMax poke.
    function refreshSMax(uint256 postId) external;
}
