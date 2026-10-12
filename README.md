# Paxel Contracts

Paxel is a permanent digital passport for tokenized real world assets: the identity, history and
verification layer for those assets. This repo holds the onchain smart contract layer from the Paxel
docs: the passport registry, the append only event log, access control and the attestation registry.

Every supported asset gets one passport. A passport is opened once by its issuer and never deleted.
Every change is a new entry in an append only history. Independent verifiers attest specific facts,
which gives each fact a verification level. Nothing is overwritten.

## Deployment

Target: Robinhood Chain mainnet (chain id 4663). Not deployed yet. `deployments/mainnet.json` appears
after the deploy. An earlier MVP build (registry and event log only) went to mainnet on 2026-09-17;
its record is kept in `deployments/archive-2026-09-17/` and the web no longer uses it.

## Contracts

| Contract | Purpose |
| --- | --- |
| `src/PaxelRegistry.sol` | Opens passports and stores issuer, status, metadata URI and tokenization time. Holds every role, so it is also the access control contract. |
| `src/PaxelEventLog.sol` | Append only lifecycle events per asset: event type, data hash, submitter, timestamp. |
| `src/PaxelAttestationRegistry.sol` | Verifiers attest passport facts with an evidence hash. Computes the L0, L1, L2 verification level of each fact. |
| `src/interfaces/IPaxelRegistry.sol` | `isIssuerOf`, `issuerOf`, `isVerifier`: the registry calls the other two contracts make. |

### Roles

- `DEFAULT_ADMIN_ROLE` goes to the deployer. The admin grants and revokes `ISSUER_ROLE` and `VERIFIER_ROLE` and may call `updateStatus` on any published passport.
- `ISSUER_ROLE` may register assets. An issuer writes only to passports it registered, and only while it still holds the role.
- `VERIFIER_ROLE` may attest facts on any passport except one it issued.
- Reads need no role.

### PaxelRegistry

| Function | Who | Effect |
| --- | --- | --- |
| `registerAsset(bytes32 assetId, string metadataURI)` | `ISSUER_ROLE` | New passport in `Draft`, caller is issuer. Reverts on a zero id, an empty URI or an existing id. |
| `publishPassport(bytes32 assetId)` | the asset's issuer | `Draft` to `Issued`. |
| `updateStatus(bytes32 assetId, Status newStatus)` | the asset's issuer or an admin | Sets any status except `Draft`. Only on a published passport. |
| `getPassport(bytes32 assetId)` | anyone | Returns the passport. Reverts with `AssetNotFound` for an unknown id. |
| `passports(bytes32 assetId)` | anyone | Public mapping getter. |
| `isIssuerOf(bytes32 assetId, address account)` | anyone | True when `account` is the issuer and still holds `ISSUER_ROLE`. |
| `issuerOf(bytes32 assetId)` | anyone | The registering address, or zero for an unknown id. |
| `isVerifier(address account)` | anyone | True while `account` holds `VERIFIER_ROLE`. |

Status values: `Draft, Issued, Active, Frozen, Disputed, Redeemed, Delisted, Defaulted` (0 to 7).

### PaxelEventLog

| Function | Who | Effect |
| --- | --- | --- |
| `addEvent(bytes32 assetId, EventType eventType, bytes32 dataHash)` | the asset's issuer (checked through `registry.isIssuerOf`) | Appends one entry. Reverts on a zero data hash. |
| `getHistory(bytes32 assetId)` | anyone | Every entry, oldest first. |
| `historyLength(bytes32 assetId)` | anyone | Number of entries. |
| `getHistoryRange(bytes32 assetId, uint256 offset, uint256 limit)` | anyone | One page of entries, for long histories. |

Event types: `Transfer, DocumentAdded, ValuationReference, StatusChange, CorporateEvent` (0 to 4).

### PaxelAttestationRegistry

A fact is identified by its hash: usually the `dataHash` of an event log entry, or the hash of the
passport metadata. The verifier signs by sending the transaction. `evidenceHash` anchors the verifier's
own report or certificate, which stays offchain.

| Function | Who | Effect |
| --- | --- | --- |
| `attest(bytes32 assetId, bytes32 factHash, bytes32 evidenceHash)` | `VERIFIER_ROLE`, not the passport issuer | Records an attestation and returns its id. One standing attestation per verifier per fact. |
| `revoke(uint256 id)` | the verifier that signed it | Stamps `revokedAt`. The record stays readable. |
| `verificationLevel(bytes32 assetId, bytes32 factHash)` | anyone | 0 self reported, 1 attested, 2 multi attested. |
| `activeAttestationCount(bytes32 assetId, bytes32 factHash)` | anyone | Attestations not revoked, by verifiers that still hold the role. |
| `getAttestation(uint256 id)` | anyone | One attestation. |
| `getAssetAttestations(bytes32 assetId, uint256 offset, uint256 limit)` | anyone | One page of a passport's attestations with their ids. |
| `getFactAttestations(bytes32 assetId, bytes32 factHash)` | anyone | Every attestation on one fact with their ids. |
| `standingAttestation(bytes32 assetId, bytes32 factHash, address verifier)` | anyone | Whether the verifier has a standing attestation on the fact, and its id. |
| `attestationCount()`, `assetAttestationCount(bytes32 assetId)` | anyone | Totals, revoked ones included. |

Revoking a verifier's role drops its attestations from the level count at once, without touching the record.

There is no function in any contract that deletes or overwrites a passport, an event or an attestation.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/) (installed in `~/.foundry/bin`).

```bash
forge build
forge test
```

- `test/PaxelRegistry.t.sol`: registering, publishing, status updates and reads.
- `test/PaxelEventLog.t.sol`: adding events and reading history.
- `test/PaxelAttestationRegistry.t.sol`: attesting, revoking, verification levels and the revert cases.
- `test/PaxelSecurity.t.sol`: role checks, revocation, duplicate ids and a fuzz pass.

## Deploy

Target network: **Robinhood Chain mainnet**, chain id `4663`, RPC `https://rpc.mainnet.chain.robinhood.com`,
explorer `https://robinhoodchain.blockscout.com`, gas token ETH.

1. Paste the deployer private key after `PRIVATE_KEY=` in `.env`. Everything else is already set.
   The deployer becomes the admin of every contract and needs about 0.0002 ETH for gas.
2. Run:

```bash
bash deploy-mainnet.sh
```

The script checks `.env`, runs the tests, simulates against the live chain, then broadcasts the three
contracts and writes `deployments/mainnet.json`. A dry run on 2026-10-12 used about 3.0M gas, roughly
0.00012 ETH at 0.04 gwei.

`script/Deploy.s.sol` reads `RPC_URL`, `PRIVATE_KEY`, `CHAIN_ID` (the script stops if the RPC reports
another chain), `DEPLOY_NETWORK`, `NETWORK_NAME` and `EXPLORER_BASE_URL`.

After deploying, grant roles from the admin key, or from the admin panel in the Paxel app:

```bash
cast send <PaxelRegistry> "grantRole(bytes32,address)" $(cast keccak "ISSUER_ROLE") <issuer> --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"
cast send <PaxelRegistry> "grantRole(bytes32,address)" $(cast keccak "VERIFIER_ROLE") <verifier> --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"
```

## Web handoff

In `paxel-web`, run `npm run contracts:sync`. It copies the addresses and deploy block from
`deployments/mainnet.json` into `config/contracts.config.js`. Commit and push the web repo.
The web ABIs in `paxel-web/assets/js/app/abi.js` come from `out/`; regenerate them if a contract changes.

## Not in this phase

Delegated write access for platforms, a soulbound passport identity token, cross chain mirroring and a
dispute workflow beyond the status flag are not implemented, as in the MVP scope of the Paxel docs.

See `AUDIT.md` for the internal checklist.
