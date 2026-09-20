// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PaxelRegistry} from "../src/PaxelRegistry.sol";
import {PaxelEventLog} from "../src/PaxelEventLog.sol";

contract PaxelSecurityTest is Test {
    PaxelRegistry internal registry;
    PaxelEventLog internal eventLog;

    address internal admin = makeAddr("admin");
    address internal issuer = makeAddr("issuer");
    address internal otherIssuer = makeAddr("otherIssuer");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 internal constant ASSET = keccak256("PXL-0001-7342");
    bytes32 internal constant DATA = keccak256("data");
    string internal constant URI = "ipfs://bafy-passport-0001";

    function setUp() public {
        vm.startPrank(admin);
        registry = new PaxelRegistry();
        eventLog = new PaxelEventLog(registry);
        registry.grantRole(ISSUER_ROLE, issuer);
        registry.grantRole(ISSUER_ROLE, otherIssuer);
        vm.stopPrank();
    }

    function _registerAndPublish(bytes32 assetId) internal {
        vm.startPrank(issuer);
        registry.registerAsset(assetId, URI);
        registry.publishPassport(assetId);
        vm.stopPrank();
    }

    /// @dev Mixes the known actors into the fuzzed callers so the success path is exercised too.
    function _caller(uint256 pick, address random) internal view returns (address) {
        uint256 k = pick % 5;
        if (k == 0) return issuer;
        if (k == 1) return otherIssuer;
        if (k == 2) return admin;
        if (k == 3) return stranger;
        return random;
    }

    // An address without ISSUER_ROLE cannot register an asset
    function test_NoIssuerRole_CannotRegister() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ISSUER_ROLE)
        );
        registry.registerAsset(ASSET, URI);
    }

    // An address that is not the issuer of an asset cannot update its status or add an event
    function test_NonIssuer_CannotUpdateStatus() public {
        _registerAndPublish(ASSET);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PaxelRegistry.NotIssuerOrAdmin.selector, ASSET, stranger));
        registry.updateStatus(ASSET, PaxelRegistry.Status.Frozen);

        // Holding ISSUER_ROLE is not enough, it must be this asset's issuer
        vm.prank(otherIssuer);
        vm.expectRevert(abi.encodeWithSelector(PaxelRegistry.NotIssuerOrAdmin.selector, ASSET, otherIssuer));
        registry.updateStatus(ASSET, PaxelRegistry.Status.Frozen);
    }

    function test_NonIssuer_CannotAddEvent() public {
        _registerAndPublish(ASSET);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PaxelEventLog.NotIssuer.selector, ASSET, stranger));
        eventLog.addEvent(ASSET, PaxelEventLog.EventType.Transfer, DATA);

        vm.prank(otherIssuer);
        vm.expectRevert(abi.encodeWithSelector(PaxelEventLog.NotIssuer.selector, ASSET, otherIssuer));
        eventLog.addEvent(ASSET, PaxelEventLog.EventType.Transfer, DATA);

        assertEq(eventLog.historyLength(ASSET), 0);
    }

    // Revoking ISSUER_ROLE immediately blocks further writes from that address
    function test_RevokedIssuer_IsBlockedImmediately() public {
        bytes32 draft = keccak256("PXL-0002");
        _registerAndPublish(ASSET);
        vm.prank(issuer);
        registry.registerAsset(draft, URI);

        vm.prank(admin);
        registry.revokeRole(ISSUER_ROLE, issuer);
        assertFalse(registry.isIssuerOf(ASSET, issuer));

        vm.startPrank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, issuer, ISSUER_ROLE)
        );
        registry.registerAsset(keccak256("PXL-0003"), URI);

        vm.expectRevert(abi.encodeWithSelector(PaxelRegistry.NotIssuer.selector, draft, issuer));
        registry.publishPassport(draft);

        vm.expectRevert(abi.encodeWithSelector(PaxelRegistry.NotIssuerOrAdmin.selector, ASSET, issuer));
        registry.updateStatus(ASSET, PaxelRegistry.Status.Active);

        vm.expectRevert(abi.encodeWithSelector(PaxelEventLog.NotIssuer.selector, ASSET, issuer));
        eventLog.addEvent(ASSET, PaxelEventLog.EventType.Transfer, DATA);
        vm.stopPrank();

        // The passport itself stays readable and the admin can still act on it
        vm.prank(admin);
        registry.updateStatus(ASSET, PaxelRegistry.Status.Frozen);
        assertEq(registry.getPassport(ASSET).issuer, issuer);
    }

    // Registering the same asset id twice reverts, for the same issuer and for another issuer
    function test_DuplicateAssetId_Reverts() public {
        vm.prank(issuer);
        registry.registerAsset(ASSET, URI);

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(PaxelRegistry.AssetAlreadyRegistered.selector, ASSET));
        registry.registerAsset(ASSET, "ipfs://other");

        vm.prank(otherIssuer);
        vm.expectRevert(abi.encodeWithSelector(PaxelRegistry.AssetAlreadyRegistered.selector, ASSET));
        registry.registerAsset(ASSET, "ipfs://other");

        assertEq(registry.getPassport(ASSET).metadataURI, URI);
    }

    // Fuzz: random callers and asset ids, only a holder of ISSUER_ROLE can register
    function testFuzz_RegisterAsset_OnlyIssuerRoleSucceeds(uint256 pick, address random, bytes32 assetId) public {
        vm.assume(assetId != bytes32(0));
        address caller = _caller(pick, random);

        vm.prank(caller);
        try registry.registerAsset(assetId, URI) {
            assertTrue(caller == issuer || caller == otherIssuer, "registered without ISSUER_ROLE");
            assertEq(registry.getPassport(assetId).issuer, caller);
        } catch {
            assertTrue(caller != issuer && caller != otherIssuer, "issuer was refused");
        }
    }

    // Fuzz: random callers and asset ids, only the asset's own issuer can add an event
    function testFuzz_AddEvent_OnlyAssetIssuerSucceeds(uint256 pick, address random, bytes32 assetId, uint8 kind)
        public
    {
        vm.assume(assetId != bytes32(0));
        address caller = _caller(pick, random);
        PaxelEventLog.EventType eventType = PaxelEventLog.EventType(bound(kind, 0, 4));
        _registerAndPublish(assetId);

        vm.prank(caller);
        try eventLog.addEvent(assetId, eventType, DATA) {
            assertEq(caller, issuer, "event added by someone other than the issuer");
            assertEq(eventLog.historyLength(assetId), 1);
        } catch {
            assertTrue(caller != issuer, "issuer was refused");
            assertEq(eventLog.historyLength(assetId), 0);
        }
    }
}
