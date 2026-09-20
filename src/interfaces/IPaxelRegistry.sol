// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IPaxelRegistry
/// @notice The slice of PaxelRegistry that PaxelEventLog depends on.
interface IPaxelRegistry {
    /// @notice True only when `account` is the recorded issuer of `assetId` and still holds ISSUER_ROLE.
    /// @dev Returns false for an asset id that was never registered. Never reverts.
    function isIssuerOf(bytes32 assetId, address account) external view returns (bool);
}
