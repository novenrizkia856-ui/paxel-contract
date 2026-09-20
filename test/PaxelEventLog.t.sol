// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PaxelRegistry} from "../src/PaxelRegistry.sol";
import {PaxelEventLog} from "../src/PaxelEventLog.sol";
import {IPaxelRegistry} from "../src/interfaces/IPaxelRegistry.sol";

contract PaxelEventLogTest is Test {
    PaxelRegistry internal registry;
    PaxelEventLog internal eventLog;

    address internal admin = makeAddr("admin");
    address internal issuer = makeAddr("issuer");

    bytes32 internal constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 internal constant ASSET = keccak256("PXL-0001-7342");
    bytes32 internal constant DOC = keccak256("deed.pdf");
    bytes32 internal constant VALUATION = keccak256("valuation-2026-q3.json");
    bytes32 internal constant TRANSFER = keccak256("transfer-0001");

    function setUp() public {
        vm.startPrank(admin);
        registry = new PaxelRegistry();
        eventLog = new PaxelEventLog(registry);
        registry.grantRole(ISSUER_ROLE, issuer);
        vm.stopPrank();

        vm.startPrank(issuer);
        registry.registerAsset(ASSET, "ipfs://bafy-passport-0001");
        registry.publishPassport(ASSET);
        vm.stopPrank();
    }

    function test_Constructor_StoresRegistry() public view {
        assertEq(address(eventLog.registry()), address(registry));
    }

    function test_Constructor_RevertsOnZeroRegistry() public {
        vm.expectRevert(PaxelEventLog.ZeroAddress.selector);
        new PaxelEventLog(IPaxelRegistry(address(0)));
    }

    function test_AddEvent_AsIssuer() public {
        vm.warp(1_760_000_000);
        vm.expectEmit(address(eventLog));
        emit PaxelEventLog.EventAdded(ASSET, 0, PaxelEventLog.EventType.DocumentAdded, DOC, issuer, 1_760_000_000);
        vm.prank(issuer);
        eventLog.addEvent(ASSET, PaxelEventLog.EventType.DocumentAdded, DOC);

        PaxelEventLog.LogEntry[] memory h = eventLog.getHistory(ASSET);
        assertEq(h.length, 1);
        assertEq(uint8(h[0].eventType), uint8(PaxelEventLog.EventType.DocumentAdded));
        assertEq(h[0].dataHash, DOC);
        assertEq(h[0].submittedBy, issuer);
        assertEq(h[0].timestamp, 1_760_000_000);
    }

    function test_GetHistory_ReturnsEntriesInOrder() public {
        vm.startPrank(issuer);
        vm.warp(100);
        eventLog.addEvent(ASSET, PaxelEventLog.EventType.DocumentAdded, DOC);
        vm.warp(200);
        eventLog.addEvent(ASSET, PaxelEventLog.EventType.ValuationReference, VALUATION);
        vm.warp(300);
        eventLog.addEvent(ASSET, PaxelEventLog.EventType.Transfer, TRANSFER);
        vm.stopPrank();

        PaxelEventLog.LogEntry[] memory h = eventLog.getHistory(ASSET);
        assertEq(h.length, 3);
        assertEq(eventLog.historyLength(ASSET), 3);
        assertEq(h[0].dataHash, DOC);
        assertEq(h[1].dataHash, VALUATION);
        assertEq(uint8(h[1].eventType), uint8(PaxelEventLog.EventType.ValuationReference));
        assertEq(h[2].dataHash, TRANSFER);
        assertEq(h[2].timestamp, 300);
    }

    function test_AddEvent_AllowsSameHashTwiceAsSeparateEntries() public {
        vm.startPrank(issuer);
        eventLog.addEvent(ASSET, PaxelEventLog.EventType.CorporateEvent, DOC);
        eventLog.addEvent(ASSET, PaxelEventLog.EventType.CorporateEvent, DOC);
        vm.stopPrank();
        assertEq(eventLog.historyLength(ASSET), 2);
    }

    function test_AddEvent_WorksWhileDraft() public {
        bytes32 draft = keccak256("PXL-0002");
        vm.startPrank(issuer);
        registry.registerAsset(draft, "ipfs://bafy-passport-0002");
        eventLog.addEvent(draft, PaxelEventLog.EventType.DocumentAdded, DOC);
        vm.stopPrank();
        assertEq(eventLog.historyLength(draft), 1);
    }

    function test_AddEvent_RevertsOnZeroDataHash() public {
        vm.prank(issuer);
        vm.expectRevert(PaxelEventLog.ZeroDataHash.selector);
        eventLog.addEvent(ASSET, PaxelEventLog.EventType.StatusChange, bytes32(0));
    }

    function test_AddEvent_RevertsForUnknownAsset() public {
        bytes32 unknown = keccak256("never registered");
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(PaxelEventLog.NotIssuer.selector, unknown, issuer));
        eventLog.addEvent(unknown, PaxelEventLog.EventType.Transfer, DOC);
    }

    function test_GetHistory_EmptyForUnknownAsset() public view {
        assertEq(eventLog.getHistory(keccak256("nothing")).length, 0);
    }

    function test_GetHistoryRange_Pages() public {
        vm.startPrank(issuer);
        for (uint256 i = 1; i <= 5; ++i) {
            eventLog.addEvent(ASSET, PaxelEventLog.EventType.CorporateEvent, bytes32(i));
        }
        vm.stopPrank();

        PaxelEventLog.LogEntry[] memory page = eventLog.getHistoryRange(ASSET, 1, 2);
        assertEq(page.length, 2);
        assertEq(page[0].dataHash, bytes32(uint256(2)));
        assertEq(page[1].dataHash, bytes32(uint256(3)));

        page = eventLog.getHistoryRange(ASSET, 3, 10);
        assertEq(page.length, 2);
        assertEq(page[1].dataHash, bytes32(uint256(5)));

        assertEq(eventLog.getHistoryRange(ASSET, 5, 10).length, 0);
        assertEq(eventLog.getHistoryRange(ASSET, 0, 0).length, 0);
    }

    function test_AdminCannotAddEvent() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PaxelEventLog.NotIssuer.selector, ASSET, admin));
        eventLog.addEvent(ASSET, PaxelEventLog.EventType.StatusChange, DOC);
    }
}
