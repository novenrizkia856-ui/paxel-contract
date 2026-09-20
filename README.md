# Paxel Contracts

Paxel is a permanent digital passport for tokenized real world assets: the identity, history and
verification layer for those assets. This repo holds the on chain registry and event log.

Every supported asset gets one passport. A passport is opened once by its issuer and never deleted.
Every change is a new entry in an append only history. Nothing is overwritten.

## Deployment

Robinhood Chain mainnet (chain id 4663), deployed 2026-09-17. Deployer and registry admin:
`0x28d836E46c698Ccc530B4D981b089eC14bE39757`.

| Contract | Address | Deploy transaction |
| --- | --- | --- |
| PaxelRegistry | [`0x864427fd9De98a71eFFd239178726254E83054ed`](https://robinhoodchain.blockscout.com/address/0x864427fd9De98a71eFFd239178726254E83054ed) | [`0x833c777c…5a2780`](https://robinhoodchain.blockscout.com/tx/0x833c777ce2bb3af0e60565ed1d1c4f68ab45edb1c2a3a234887087ec8e5a2780) |
| PaxelEventLog | [`0xB783c3b4119b2ed1290BC827727D1Aab8Ea6D985`](https://robinhoodchain.blockscout.com/address/0xB783c3b4119b2ed1290BC827727D1Aab8Ea6D985) | [`0xc625a254…ea1348`](https://robinhoodchain.blockscout.com/tx/0xc625a2543995915c05c9240ecae2f7b4e679d570358c9a995f862eaba8ea1348) |

`deployments/mainnet.json` holds the same values. Checked on chain after deploy: the deployer holds
`DEFAULT_ADMIN_ROLE`, and `PaxelEventLog.registry()` returns the registry address.

Source verification: Blockscout's API sits behind a Cloudflare challenge, so `forge verify-contract`
could not reach it. Verify through the Blockscout UI with **Solidity (Standard JSON input)**, compiler
`v0.8.28`, using `deployments/verify/PaxelRegistry.standard-input.json` and
`deployments/verify/PaxelEventLog.standard-input.json`. The event log's constructor argument is in
`deployments/verify/PaxelEventLog.constructor-args.txt`.

## Contracts

| Contract | Purpose |
| --- | --- |
| `src/PaxelRegistry.sol` | Opens passports and stores issuer, status, metadata URI and tokenization time. Holds the roles. |
| `src/PaxelEventLog.sol` | Append only lifecycle events per asset: event type, data hash, submitter, timestamp. |
| `src/interfaces/IPaxelRegistry.sol` | `isIssuerOf`, the only registry call the event log makes. |

### Roles

- `DEFAULT_ADMIN_ROLE` goes to the deployer. The admin grants and revokes `ISSUER_ROLE` and may call `updateStatus` on any published passport.
- `ISSUER_ROLE` is granted per address by the admin. A holder may register assets. It writes only to passports it registered, and only while it still holds the role.
- Reads need no role.

### PaxelRegistry

| Function | Who | Effect |
| --- | --- | --- |
| `registerAsset(bytes32 assetId, string metadataURI)` | `ISSUER_ROLE` | New passport in `Draft`, caller is issuer. Reverts on a zero id, an empty URI or an existing id. |
| `publishPassport(bytes32 assetId)` | the asset's issuer | `Draft` to `Issued`. |
| `updateStatus(bytes32 assetId, Status newStatus)` | the asset's issuer or an admin | Sets any status except `Draft`. Only on a published passport. |
| `getPassport(bytes32 assetId)` | anyone | Returns the passport. Reverts with `AssetNotFound` for an unknown id. |
| `isIssuerOf(bytes32 assetId, address account)` | anyone | True when `account` is the issuer and still holds `ISSUER_ROLE`. |
| `passports(bytes32 assetId)` | anyone | Public mapping getter. |

Status values: `Draft, Issued, Active, Frozen, Disputed, Redeemed, Delisted, Defaulted` (0 to 7).

### PaxelEventLog

| Function | Who | Effect |
| --- | --- | --- |
| `addEvent(bytes32 assetId, EventType eventType, bytes32 dataHash)` | the asset's issuer (checked through `registry.isIssuerOf`) | Appends one entry. Reverts on a zero data hash. |
| `getHistory(bytes32 assetId)` | anyone | Every entry, oldest first. |
| `historyLength(bytes32 assetId)` | anyone | Number of entries. |
| `getHistoryRange(bytes32 assetId, uint256 offset, uint256 limit)` | anyone | One page of entries, for long histories. |

Event types: `Transfer, DocumentAdded, ValuationReference, StatusChange, CorporateEvent` (0 to 4).

There is no function in either contract that deletes or overwrites a passport or an event.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/).

```bash
git clone --recursive <repo url>
forge build
forge test
```

Tests:

- `test/PaxelRegistry.t.sol` covers registering, publishing, status updates and reads.
- `test/PaxelEventLog.t.sol` covers adding events and reading history.
- `test/PaxelSecurity.t.sol` covers role checks, revocation, duplicate ids and a fuzz pass on `registerAsset` and `addEvent`.

## Deploy

Target network: **Robinhood Chain mainnet**, chain id `4663`, RPC
`https://rpc.mainnet.chain.robinhood.com` (public and rate limited), explorer
`https://robinhoodchain.blockscout.com`, gas token ETH. The chain id was confirmed by querying the RPC.

`script/Deploy.s.sol` deploys the registry, then the event log wired to it. It reads:

| Variable | Meaning |
| --- | --- |
| `RPC_URL` | RPC endpoint, passed as `--rpc-url` |
| `PRIVATE_KEY` | Deployer key. The deployer becomes the registry admin. Optional for a dry run with `--sender`. |
| `CHAIN_ID` | Expected chain id. The script stops if the RPC reports another one. |
| `DEPLOY_NETWORK` | Output name, `deployments/<DEPLOY_NETWORK>.json` |
| `NETWORK_NAME` | Network label written to the export |
| `EXPLORER_BASE_URL` | Explorer base URL written to the export |

`.env` is gitignored. Copy `.env.example` to `.env` (the example already holds the Robinhood Chain
values) and paste the deployer key into `PRIVATE_KEY`. Forge loads `.env` automatically.

```bash
set -a; . ./.env; set +a
forge script script/Deploy.s.sol --rpc-url "$RPC_URL"
forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --broadcast
```

The first command only simulates against the live chain. The second one sends the transactions and
writes `deployments/mainnet.json` with the network, chain id, deployer and both addresses. A dry run
on Robinhood Chain mainnet estimated about 1.8M gas, roughly 0.0002 ETH at 0.095 gwei.

Verify both contracts on Blockscout:

```bash
forge verify-contract <PaxelRegistry> src/PaxelRegistry.sol:PaxelRegistry --chain-id 4663 --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api
forge verify-contract <PaxelEventLog> src/PaxelEventLog.sol:PaxelEventLog --chain-id 4663 --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api --constructor-args $(cast abi-encode "constructor(address)" <PaxelRegistry>)
```

After deploying, grant issuers from the admin key:

```bash
cast send <PaxelRegistry> "grantRole(bytes32,address)" $(cast keccak "ISSUER_ROLE") <issuer> --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"
```

## Web handoff

Fill `config/contracts.config.js` in the web repo:

```js
export const CONTRACTS = {
  network: "",              // network name
  chainId: "",              // chain id
  tokenAddress: "",         // leave empty, no token yet
  passportRegistry: "",     // PaxelRegistry address
  eventLog: "",             // PaxelEventLog address
  accessControl: "",        // same as passportRegistry, roles live there
  attestationRegistry: ""   // leave empty, not built in this phase
};
```

## Not in this phase

Attestations, delegated write access, a soulbound identity token, cross chain mirroring and any
dispute workflow beyond the status flag are deliberately not implemented.

See `AUDIT.md` for the security checklist.
