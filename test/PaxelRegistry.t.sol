// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PaxelRegistry} from "../src/PaxelRegistry.sol";

contract PaxelRegistryTest is Test {
    PaxelRegistry internal registry;

    address internal admin = makeAddr("admin");
    address internal issuer = makeAddr("issuer");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 internal constant ASSET = keccak256("PXL-0001-7342");
    string internal constant URI = "ipfs://bafy-passport-0001";

    function setUp() public {
        vm.prank(admin);
        registry = new PaxelRegistry();
        vm.prank(admin);
        registry.grantRole(ISSUER_ROLE, issuer);
    }

    function _register() internal {
        vm.prank(issuer);
        registry.registerAsset(ASSET, URI);
    }

    function _publish() internal {
        _register();
        vm.prank(issuer);
        registry.publishPassport(ASSET);
    }

    // ---- deployment ----

    function test_DeployerIsAdmin() public view {
        assertTrue(registry.hasRole(bytes32(0), admin));
        assertFalse(registry.hasRole(ISSUER_ROLE, admin));
    }

    // ---- registerAsset ----

    function test_RegisterAsset_CreatesDraftPassport() public {
        vm.warp(1_750_000_000);
        vm.expectEmit(address(registry));
        emit PaxelRegistry.AssetRegistered(ASSET, issuer, URI, 1_750_000_000);
        _register();

        PaxelRegistry.Passport memory p = registry.getPassport(ASSET);
        assertEq(p.issuer, issuer);
        assertEq(uint8(p.status), uint8(PaxelRegistry.Status.Draft));
        assertEq(p.metadataURI, URI);
        assertEq(p.tokenizedAt, 1_750_000_000);
    }

    function test_RegisterAsset_RevertsOnZeroAssetId() public {
        vm.prank(issuer);
        vm.expectRevert(PaxelRegistry.ZeroAssetId.selector);
        registry.registerAsset(bytes32(0), URI);
    }

    function test_RegisterAsset_RevertsOnEmptyMetadataURI() public {
        vm.prank(issuer);
        vm.expectRevert(PaxelRegistry.EmptyMetadataURI.selector);
        registry.registerAsset(ASSET, "");
    }

    // ---- publishPassport ----

    function test_PublishPassport_MovesDraftToIssued() public {
        _register();
        vm.expectEmit(address(registry));
        emit PaxelRegistry.PassportPublished(ASSET, issuer);
        vm.prank(issuer);
        registry.publishPassport(ASSET);

        assertEq(uint8(registry.getPassport(ASSET).status), uint8(PaxelRegistry.Status.Issued));
    }

    function test_PublishPassport_RevertsWhenNotDraft() public {
        _publish();
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(PaxelRegistry.NotDraft.selector, ASSET));
        registry.publishPassport(ASSET);
    }

    function test_PublishPassport_RevertsForUnknownAsset() public {
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(PaxelRegistry.AssetNotFound.selector, ASSET));
        registry.publishPassport(ASSET);
    }

    function test_PublishPassport_RevertsForAdmin() public {
        _register();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PaxelRegistry.NotIssuer.selector, ASSET, admin));
        registry.publishPassport(ASSET);
    }

    // ---- updateStatus ----

    function test_UpdateStatus_ByIssuer() public {
        _publish();
        vm.expectEmit(address(registry));
        emit PaxelRegistry.StatusUpdated(ASSET, PaxelRegistry.Status.Issued, PaxelRegistry.Status.Active, issuer);
        vm.prank(issuer);
        registry.updateStatus(ASSET, PaxelRegistry.Status.Active);

        assertEq(uint8(registry.getPassport(ASSET).status), uint8(PaxelRegistry.Status.Active));
    }

    function test_UpdateStatus_ByAdmin() public {
        _publish();
        vm.prank(admin);
        registry.updateStatus(ASSET, PaxelRegistry.Status.Frozen);

        assertEq(uint8(registry.getPassport(ASSET).status), uint8(PaxelRegistry.Status.Frozen));
    }

    function test_UpdateStatus_EveryPublishedStatusIsReachable() public {
        _publish();
        for (uint8 s = uint8(PaxelRegistry.Status.Issued); s <= uint8(PaxelRegistry.Status.Defaulted); ++s) {
            vm.prank(issuer);
            registry.updateStatus(ASSET, PaxelRegistry.Status(s));
            assertEq(uint8(registry.getPassport(ASSET).status), s);
        }
    }

    function test_UpdateStatus_RevertsWhileDraft() public {
        _register();
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(PaxelRegistry.NotPublished.selector, ASSET));
        registry.updateStatus(ASSET, PaxelRegistry.Status.Active);
    }

    function test_UpdateStatus_RevertsBackToDraft() public {
        _publish();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PaxelRegistry.InvalidStatus.selector, PaxelRegistry.Status.Draft));
        registry.updateStatus(ASSET, PaxelRegistry.Status.Draft);
    }

    // ---- reads ----

    function test_GetPassport_RevertsForUnknownAsset() public {
        vm.expectRevert(abi.encodeWithSelector(PaxelRegistry.AssetNotFound.selector, ASSET));
        registry.getPassport(ASSET);
    }

    function test_Reads_NeedNoRole() public {
        _publish();
        vm.prank(stranger);
        PaxelRegistry.Passport memory p = registry.getPassport(ASSET);
        assertEq(p.issuer, issuer);

        (address storedIssuer,, string memory storedURI,) = registry.passports(ASSET);
        assertEq(storedIssuer, issuer);
        assertEq(storedURI, URI);
    }

    function test_IsIssuerOf() public {
        assertFalse(registry.isIssuerOf(ASSET, issuer));
        _register();
        assertTrue(registry.isIssuerOf(ASSET, issuer));
        assertFalse(registry.isIssuerOf(ASSET, stranger));
        assertFalse(registry.isIssuerOf(ASSET, admin));
        assertFalse(registry.isIssuerOf(ASSET, address(0)));
    }

    // ---- roles ----

    function test_GrantRole_RevertsOnZeroAddress() public {
        bytes32 role = ISSUER_ROLE;
        vm.prank(admin);
        vm.expectRevert(PaxelRegistry.ZeroAddress.selector);
        registry.grantRole(role, address(0));
    }
}
