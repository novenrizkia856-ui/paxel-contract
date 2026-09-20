// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IPaxelRegistry} from "./interfaces/IPaxelRegistry.sol";

/// @title PaxelRegistry
/// @notice One permanent passport per tokenized real world asset. A passport is opened once by
///         its issuer and is never deleted. Reads are open to everyone.
/// @dev Roles: DEFAULT_ADMIN_ROLE (the deployer) grants and revokes ISSUER_ROLE. An issuer writes
///      only to the passports it registered, and only while it still holds ISSUER_ROLE.
contract PaxelRegistry is AccessControl, IPaxelRegistry {
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    enum Status {
        Draft,
        Issued,
        Active,
        Frozen,
        Disputed,
        Redeemed,
        Delisted,
        Defaulted
    }

    struct Passport {
        address issuer;
        Status status;
        string metadataURI;
        uint256 tokenizedAt;
    }

    mapping(bytes32 => Passport) public passports;

    event AssetRegistered(bytes32 indexed assetId, address indexed issuer, string metadataURI, uint256 tokenizedAt);
    event PassportPublished(bytes32 indexed assetId, address indexed issuer);
    event StatusUpdated(bytes32 indexed assetId, Status previousStatus, Status newStatus, address indexed updatedBy);

    error ZeroAssetId();
    error EmptyMetadataURI();
    error ZeroAddress();
    error AssetAlreadyRegistered(bytes32 assetId);
    error AssetNotFound(bytes32 assetId);
    error NotIssuer(bytes32 assetId, address account);
    error NotIssuerOrAdmin(bytes32 assetId, address account);
    error NotDraft(bytes32 assetId);
    error NotPublished(bytes32 assetId);
    error InvalidStatus(Status status);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Writes
    // ---------------------------------------------------------------------------------------------

    /// @notice Opens a passport in Draft status with the caller recorded as its issuer.
    function registerAsset(bytes32 assetId, string calldata metadataURI) external onlyRole(ISSUER_ROLE) {
        if (assetId == bytes32(0)) revert ZeroAssetId();
        if (bytes(metadataURI).length == 0) revert EmptyMetadataURI();
        if (passports[assetId].issuer != address(0)) revert AssetAlreadyRegistered(assetId);

        passports[assetId] = Passport({
            issuer: msg.sender, status: Status.Draft, metadataURI: metadataURI, tokenizedAt: block.timestamp
        });

        emit AssetRegistered(assetId, msg.sender, metadataURI, block.timestamp);
    }

    /// @notice Moves a passport from Draft to Issued. Only the passport's issuer may publish.
    function publishPassport(bytes32 assetId) external {
        Passport storage passport = _existing(assetId);
        if (!_isIssuer(passport, msg.sender)) revert NotIssuer(assetId, msg.sender);
        if (passport.status != Status.Draft) revert NotDraft(assetId);

        passport.status = Status.Issued;

        emit PassportPublished(assetId, msg.sender);
        emit StatusUpdated(assetId, Status.Draft, Status.Issued, msg.sender);
    }

    /// @notice Sets the status of a published passport. Caller must be its issuer or an admin.
    /// @dev A passport leaves Draft only through publishPassport and can never return to Draft.
    function updateStatus(bytes32 assetId, Status newStatus) external {
        Passport storage passport = _existing(assetId);
        if (!_isIssuer(passport, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotIssuerOrAdmin(assetId, msg.sender);
        }
        if (passport.status == Status.Draft) revert NotPublished(assetId);
        if (newStatus == Status.Draft) revert InvalidStatus(newStatus);

        Status previous = passport.status;
        passport.status = newStatus;

        emit StatusUpdated(assetId, previous, newStatus, msg.sender);
    }

    /// @notice Grants a role. Rejects the zero address.
    function grantRole(bytes32 role, address account) public override {
        if (account == address(0)) revert ZeroAddress();
        super.grantRole(role, account);
    }

    // ---------------------------------------------------------------------------------------------
    // Reads
    // ---------------------------------------------------------------------------------------------

    /// @notice Returns the passport for `assetId`. Reverts if it was never registered.
    function getPassport(bytes32 assetId) external view returns (Passport memory) {
        return _existing(assetId);
    }

    /// @inheritdoc IPaxelRegistry
    function isIssuerOf(bytes32 assetId, address account) external view returns (bool) {
        Passport storage passport = passports[assetId];
        return passport.issuer != address(0) && _isIssuer(passport, account);
    }

    // ---------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------

    function _existing(bytes32 assetId) private view returns (Passport storage passport) {
        passport = passports[assetId];
        if (passport.issuer == address(0)) revert AssetNotFound(assetId);
    }

    /// @dev Revoking ISSUER_ROLE blocks every further write from that address immediately.
    function _isIssuer(Passport storage passport, address account) private view returns (bool) {
        return passport.issuer == account && hasRole(ISSUER_ROLE, account);
    }
}
