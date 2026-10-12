// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PaxelRegistry} from "../src/PaxelRegistry.sol";
import {PaxelAttestationRegistry} from "../src/PaxelAttestationRegistry.sol";
import {IPaxelRegistry} from "../src/interfaces/IPaxelRegistry.sol";

contract PaxelAttestationRegistryTest is Test {
    PaxelRegistry internal registry;
    PaxelAttestationRegistry internal attestations;

    address internal admin = makeAddr("admin");
    address internal issuer = makeAddr("issuer");
    address internal auditor = makeAddr("auditor");
    address internal custodian = makeAddr("custodian");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 internal constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 internal constant ASSET = keccak256("PXL-0001-7342");
    bytes32 internal constant FACT = keccak256("deed.pdf");
    bytes32 internal constant EVIDENCE = keccak256("audit-report-2026.pdf");

    function setUp() public {
        vm.startPrank(admin);
        registry = new PaxelRegistry();
        attestations = new PaxelAttestationRegistry(registry);
        registry.grantRole(ISSUER_ROLE, issuer);
        registry.grantRole(VERIFIER_ROLE, auditor);
        registry.grantRole(VERIFIER_ROLE, custodian);
        vm.stopPrank();

        vm.prank(issuer);
        registry.registerAsset(ASSET, "ipfs://bafy-passport-0001");
    }

    function test_Constructor_RevertsOnZeroRegistry() public {
        vm.expectRevert(PaxelAttestationRegistry.ZeroAddress.selector);
        new PaxelAttestationRegistry(IPaxelRegistry(address(0)));
    }

    function test_Attest_StoresAndEmits() public {
        vm.warp(1_760_000_000);
        vm.expectEmit(address(attestations));
        emit PaxelAttestationRegistry.Attested(0, ASSET, FACT, auditor, EVIDENCE, 1_760_000_000);
        vm.prank(auditor);
        uint256 id = attestations.attest(ASSET, FACT, EVIDENCE);

        assertEq(id, 0);
        PaxelAttestationRegistry.Attestation memory a = attestations.getAttestation(id);
        assertEq(a.assetId, ASSET);
        assertEq(a.factHash, FACT);
        assertEq(a.evidenceHash, EVIDENCE);
        assertEq(a.verifier, auditor);
        assertEq(a.attestedAt, 1_760_000_000);
        assertEq(a.revokedAt, 0);
        assertEq(attestations.attestationCount(), 1);
        assertEq(attestations.assetAttestationCount(ASSET), 1);
    }

    function test_VerificationLevels_L0_L1_L2() public {
        assertEq(attestations.verificationLevel(ASSET, FACT), 0);
        vm.prank(auditor);
        attestations.attest(ASSET, FACT, EVIDENCE);
        assertEq(attestations.verificationLevel(ASSET, FACT), 1);
        vm.prank(custodian);
        attestations.attest(ASSET, FACT, keccak256("custody-statement.pdf"));
        assertEq(attestations.verificationLevel(ASSET, FACT), 2);
    }

    function test_Revoke_KeepsRecordAndLowersLevel() public {
        vm.prank(auditor);
        uint256 id = attestations.attest(ASSET, FACT, EVIDENCE);
        vm.warp(block.timestamp + 1 days);
        vm.prank(auditor);
        attestations.revoke(id);

        PaxelAttestationRegistry.Attestation memory a = attestations.getAttestation(id);
        assertEq(a.revokedAt, block.timestamp);
        assertEq(a.verifier, auditor);
        assertEq(attestations.verificationLevel(ASSET, FACT), 0);

        // A revoked attestation frees the verifier to attest the fact again
        vm.prank(auditor);
        assertEq(attestations.attest(ASSET, FACT, EVIDENCE), 1);
    }

    function test_VerifierRoleRevoked_DropsLevel() public {
        vm.prank(auditor);
        attestations.attest(ASSET, FACT, EVIDENCE);
        vm.prank(admin);
        registry.revokeRole(VERIFIER_ROLE, auditor);
        assertEq(attestations.verificationLevel(ASSET, FACT), 0);
        assertEq(attestations.assetAttestationCount(ASSET), 1);
    }

    function test_Attest_Reverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PaxelAttestationRegistry.NotVerifier.selector, stranger));
        attestations.attest(ASSET, FACT, EVIDENCE);

        bytes32 unknown = keccak256("unknown");
        vm.prank(auditor);
        vm.expectRevert(abi.encodeWithSelector(PaxelAttestationRegistry.AssetNotFound.selector, unknown));
        attestations.attest(unknown, FACT, EVIDENCE);

        vm.prank(admin);
        registry.grantRole(VERIFIER_ROLE, issuer);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(PaxelAttestationRegistry.IssuerCannotAttest.selector, ASSET, issuer));
        attestations.attest(ASSET, FACT, EVIDENCE);

        vm.startPrank(auditor);
        vm.expectRevert(PaxelAttestationRegistry.ZeroFactHash.selector);
        attestations.attest(ASSET, bytes32(0), EVIDENCE);
        vm.expectRevert(PaxelAttestationRegistry.ZeroEvidenceHash.selector);
        attestations.attest(ASSET, FACT, bytes32(0));
        attestations.attest(ASSET, FACT, EVIDENCE);
        vm.expectRevert(abi.encodeWithSelector(PaxelAttestationRegistry.AlreadyAttested.selector, 0));
        attestations.attest(ASSET, FACT, EVIDENCE);
        vm.stopPrank();
    }

    function test_Revoke_Reverts() public {
        vm.prank(auditor);
        uint256 id = attestations.attest(ASSET, FACT, EVIDENCE);

        vm.prank(custodian);
        vm.expectRevert(abi.encodeWithSelector(PaxelAttestationRegistry.NotAttestationVerifier.selector, id, custodian));
        attestations.revoke(id);

        vm.expectRevert(abi.encodeWithSelector(PaxelAttestationRegistry.AttestationNotFound.selector, 9));
        attestations.revoke(9);

        vm.startPrank(auditor);
        attestations.revoke(id);
        vm.expectRevert(abi.encodeWithSelector(PaxelAttestationRegistry.AlreadyRevoked.selector, id));
        attestations.revoke(id);
        vm.stopPrank();
    }

    function test_Pages_ReturnIdsInOrder() public {
        bytes32 other = keccak256("valuation.json");
        vm.prank(auditor);
        attestations.attest(ASSET, FACT, EVIDENCE);
        vm.prank(custodian);
        attestations.attest(ASSET, other, EVIDENCE);
        vm.prank(custodian);
        attestations.attest(ASSET, FACT, EVIDENCE);

        (uint256[] memory ids, PaxelAttestationRegistry.Attestation[] memory page) =
            attestations.getAssetAttestations(ASSET, 1, 10);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(page[1].verifier, custodian);

        (ids,) = attestations.getFactAttestations(ASSET, FACT);
        assertEq(ids.length, 2);
        assertEq(ids[1], 2);

        (bool exists, uint256 id) = attestations.standingAttestation(ASSET, other, custodian);
        assertTrue(exists);
        assertEq(id, 1);

        (ids,) = attestations.getAssetAttestations(ASSET, 5, 10);
        assertEq(ids.length, 0);
    }

    function test_Registry_VerifierReads() public view {
        assertTrue(registry.isVerifier(auditor));
        assertFalse(registry.isVerifier(stranger));
        assertEq(registry.issuerOf(ASSET), issuer);
        assertEq(registry.issuerOf(keccak256("unknown")), address(0));
    }
}
