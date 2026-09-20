// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPaxelRegistry} from "./interfaces/IPaxelRegistry.sol";

/// @title PaxelEventLog
/// @notice Append only lifecycle history for every Paxel passport. Entries are never modified
///         and never removed; this contract has no code path that could do either.
/// @dev Write access is decided entirely by PaxelRegistry.isIssuerOf.
contract PaxelEventLog {
    enum EventType {
        Transfer,
        DocumentAdded,
        ValuationReference,
        StatusChange,
        CorporateEvent
    }

    struct LogEntry {
        EventType eventType;
        bytes32 dataHash;
        address submittedBy;
        uint256 timestamp;
    }

    IPaxelRegistry public immutable registry;

    mapping(bytes32 => LogEntry[]) private history;

    event EventAdded(
        bytes32 indexed assetId,
        uint256 indexed index,
        EventType eventType,
        bytes32 dataHash,
        address indexed submittedBy,
        uint256 timestamp
    );

    error ZeroAddress();
    error ZeroDataHash();
    error NotIssuer(bytes32 assetId, address account);

    constructor(IPaxelRegistry registry_) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
    }

    /// @notice Appends an event to the history of `assetId`. Caller must be the asset's issuer.
    function addEvent(bytes32 assetId, EventType eventType, bytes32 dataHash) external {
        if (!registry.isIssuerOf(assetId, msg.sender)) revert NotIssuer(assetId, msg.sender);
        if (dataHash == bytes32(0)) revert ZeroDataHash();

        LogEntry[] storage entries = history[assetId];
        entries.push(
            LogEntry({eventType: eventType, dataHash: dataHash, submittedBy: msg.sender, timestamp: block.timestamp})
        );

        emit EventAdded(assetId, entries.length - 1, eventType, dataHash, msg.sender, block.timestamp);
    }

    /// @notice Full history of `assetId`, oldest first. Empty for an asset with no events.
    /// @dev Returns the whole array. For very long histories use historyLength and getHistoryRange.
    function getHistory(bytes32 assetId) external view returns (LogEntry[] memory) {
        return history[assetId];
    }

    /// @notice Number of entries recorded for `assetId`.
    function historyLength(bytes32 assetId) external view returns (uint256) {
        return history[assetId].length;
    }

    /// @notice Up to `limit` entries of `assetId` starting at `offset`, oldest first.
    function getHistoryRange(bytes32 assetId, uint256 offset, uint256 limit)
        external
        view
        returns (LogEntry[] memory page)
    {
        LogEntry[] storage entries = history[assetId];
        uint256 length = entries.length;
        if (offset >= length) return page;

        uint256 count = length - offset;
        if (limit < count) count = limit;

        page = new LogEntry[](count);
        for (uint256 i; i < count; ++i) {
            page[i] = entries[offset + i];
        }
    }
}
