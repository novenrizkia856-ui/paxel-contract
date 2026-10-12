// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPaxelRegistry} from "./interfaces/IPaxelRegistry.sol";

/// @title PaxelAttestationRegistry
/// @notice Independent verifiers (auditors, custodians, licensed valuers, oracles) publish signed
///         attestations about specific passport facts. A passport never has to change to be verified.
/// @dev A fact is identified by its hash: the dataHash of an event log entry, the hash of the passport
///      metadata, or any other hash anchored passport content. The transaction sender is the signer.
///      Verification levels follow the Paxel trust model:
///        L0 self reported   no standing attestation
///        L1 attested        one independent verifier
///        L2 multi attested  two or more independent verifiers
///      Attestations are never deleted. A verifier may revoke its own attestation, which only stamps
///      revokedAt; the record stays readable. Roles are read from PaxelRegistry.
contract PaxelAttestationRegistry {
    struct Attestation {
        bytes32 assetId;
        bytes32 factHash;
        bytes32 evidenceHash;
        address verifier;
        uint64 attestedAt;
        uint64 revokedAt;
    }

    uint8 public constant LEVEL_SELF_REPORTED = 0;
    uint8 public constant LEVEL_ATTESTED = 1;
    uint8 public constant LEVEL_MULTI_ATTESTED = 2;

    IPaxelRegistry public immutable registry;

    /// @dev The attestation id is its index in this array.
    Attestation[] private attestations;
    mapping(bytes32 assetId => uint256[] ids) private assetAttestations;
    mapping(bytes32 assetId => mapping(bytes32 factHash => uint256[] ids)) private factAttestations;
    /// @dev id + 1 of the standing attestation by a verifier on a fact, 0 when there is none.
    mapping(bytes32 assetId => mapping(bytes32 factHash => mapping(address verifier => uint256))) private standing;

    event Attested(
        uint256 id,
        bytes32 indexed assetId,
        bytes32 indexed factHash,
        address indexed verifier,
        bytes32 evidenceHash,
        uint256 timestamp
    );
    event AttestationRevoked(
        uint256 id, bytes32 indexed assetId, bytes32 indexed factHash, address indexed verifier, uint256 timestamp
    );

    error ZeroAddress();
    error ZeroFactHash();
    error ZeroEvidenceHash();
    error NotVerifier(address account);
    error AssetNotFound(bytes32 assetId);
    error IssuerCannotAttest(bytes32 assetId, address account);
    error AlreadyAttested(uint256 id);
    error AttestationNotFound(uint256 id);
    error NotAttestationVerifier(uint256 id, address account);
    error AlreadyRevoked(uint256 id);

    constructor(IPaxelRegistry registry_) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
    }

    // ---------------------------------------------------------------------------------------------
    // Writes
    // ---------------------------------------------------------------------------------------------

    /// @notice Confirms `factHash` on passport `assetId`. `evidenceHash` anchors the verifier's own
    ///         report or certificate, kept offchain. Caller must hold VERIFIER_ROLE and must not be
    ///         the passport's issuer. One standing attestation per verifier per fact.
    function attest(bytes32 assetId, bytes32 factHash, bytes32 evidenceHash) external returns (uint256 id) {
        if (!registry.isVerifier(msg.sender)) revert NotVerifier(msg.sender);
        address issuer = registry.issuerOf(assetId);
        if (issuer == address(0)) revert AssetNotFound(assetId);
        if (issuer == msg.sender) revert IssuerCannotAttest(assetId, msg.sender);
        if (factHash == bytes32(0)) revert ZeroFactHash();
        if (evidenceHash == bytes32(0)) revert ZeroEvidenceHash();
        uint256 current = standing[assetId][factHash][msg.sender];
        if (current != 0) revert AlreadyAttested(current - 1);

        id = attestations.length;
        attestations.push(
            Attestation({
                assetId: assetId,
                factHash: factHash,
                evidenceHash: evidenceHash,
                verifier: msg.sender,
                attestedAt: uint64(block.timestamp),
                revokedAt: 0
            })
        );
        assetAttestations[assetId].push(id);
        factAttestations[assetId][factHash].push(id);
        standing[assetId][factHash][msg.sender] = id + 1;

        emit Attested(id, assetId, factHash, msg.sender, evidenceHash, block.timestamp);
    }

    /// @notice Withdraws an attestation. Only the verifier that signed it may revoke it, even after
    ///         losing VERIFIER_ROLE. The record stays readable with its revocation time.
    function revoke(uint256 id) external {
        Attestation storage attestation = _existing(id);
        if (attestation.verifier != msg.sender) revert NotAttestationVerifier(id, msg.sender);
        if (attestation.revokedAt != 0) revert AlreadyRevoked(id);

        attestation.revokedAt = uint64(block.timestamp);
        delete standing[attestation.assetId][attestation.factHash][msg.sender];

        emit AttestationRevoked(id, attestation.assetId, attestation.factHash, msg.sender, block.timestamp);
    }

    // ---------------------------------------------------------------------------------------------
    // Reads
    // ---------------------------------------------------------------------------------------------

    /// @notice Total attestations ever made, across all passports.
    function attestationCount() external view returns (uint256) {
        return attestations.length;
    }

    /// @notice One attestation by id. Reverts for an unknown id.
    function getAttestation(uint256 id) external view returns (Attestation memory) {
        return _existing(id);
    }

    /// @notice Number of attestations ever made on `assetId`, revoked ones included.
    function assetAttestationCount(bytes32 assetId) external view returns (uint256) {
        return assetAttestations[assetId].length;
    }

    /// @notice Up to `limit` attestations on `assetId` starting at `offset`, oldest first, with their ids.
    function getAssetAttestations(bytes32 assetId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, Attestation[] memory page)
    {
        return _page(assetAttestations[assetId], offset, limit);
    }

    /// @notice Every attestation on one fact of `assetId`, oldest first, with their ids.
    function getFactAttestations(bytes32 assetId, bytes32 factHash)
        external
        view
        returns (uint256[] memory ids, Attestation[] memory list)
    {
        uint256[] storage all = factAttestations[assetId][factHash];
        return _page(all, 0, all.length);
    }

    /// @notice Standing attestations on a fact: not revoked, by a verifier that still holds VERIFIER_ROLE.
    function activeAttestationCount(bytes32 assetId, bytes32 factHash) public view returns (uint256 count) {
        uint256[] storage ids = factAttestations[assetId][factHash];
        for (uint256 i; i < ids.length; ++i) {
            Attestation storage attestation = attestations[ids[i]];
            if (attestation.revokedAt == 0 && registry.isVerifier(attestation.verifier)) ++count;
        }
    }

    /// @notice Verification level of a fact: 0 self reported, 1 attested, 2 multi attested.
    function verificationLevel(bytes32 assetId, bytes32 factHash) external view returns (uint8) {
        uint256 count = activeAttestationCount(assetId, factHash);
        if (count >= 2) return LEVEL_MULTI_ATTESTED;
        if (count == 1) return LEVEL_ATTESTED;
        return LEVEL_SELF_REPORTED;
    }

    /// @notice Id of the standing attestation by `verifier` on a fact, and whether one exists.
    function standingAttestation(bytes32 assetId, bytes32 factHash, address verifier)
        external
        view
        returns (bool exists, uint256 id)
    {
        uint256 stored = standing[assetId][factHash][verifier];
        return stored == 0 ? (false, 0) : (true, stored - 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------

    function _existing(uint256 id) private view returns (Attestation storage) {
        if (id >= attestations.length) revert AttestationNotFound(id);
        return attestations[id];
    }

    function _page(uint256[] storage all, uint256 offset, uint256 limit)
        private
        view
        returns (uint256[] memory ids, Attestation[] memory page)
    {
        uint256 length = all.length;
        if (offset >= length) return (ids, page);
        uint256 count = length - offset;
        if (limit < count) count = limit;

        ids = new uint256[](count);
        page = new Attestation[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = all[offset + i];
            page[i] = attestations[ids[i]];
        }
    }
}
