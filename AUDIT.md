# Paxel Contracts Audit

Scope: `src/PaxelRegistry.sol`, `src/PaxelEventLog.sol`, `src/interfaces/IPaxelRegistry.sol`.
Compiler 0.8.28, EVM Shanghai, OpenZeppelin Contracts v5.1.0 (`AccessControl`).

This is a short internal pass against a fixed checklist. It is not a third party audit.

## Result

| # | Check | Result |
| --- | --- | --- |
| 1 | Reentrancy exposure | Pass |
| 2 | Access control on every state changing function | Pass |
| 3 | Integer handling | Pass |
| 4 | Unbounded loops or array growth in the event log | Pass, with one documented note and a fix |
| 5 | Behavior when a role is revoked | Pass |
| 6 | Input validation on empty strings and zero addresses | Pass, fixed during the pass |
| 7 | No function can delete or overwrite an existing event | Pass |

## 1. Reentrancy exposure: Pass

Neither contract holds, receives or sends value. There are no `payable` functions, no `call`, no
token transfers and no callbacks. The only cross contract call is `PaxelEventLog.addEvent` calling
`registry.isIssuerOf`, which is declared `view`, so it is made with `STATICCALL` and cannot change
state. The registry address is `immutable` and set once in the constructor. The call happens before
the entry is appended.

## 2. Access control correctness: Pass

| Function | Required caller | Enforced by |
| --- | --- | --- |
| `PaxelRegistry.registerAsset` | holder of `ISSUER_ROLE` | `onlyRole(ISSUER_ROLE)` |
| `PaxelRegistry.publishPassport` | the passport's issuer, still holding `ISSUER_ROLE` | `_isIssuer`, else `NotIssuer` |
| `PaxelRegistry.updateStatus` | the passport's issuer (still holding `ISSUER_ROLE`) or `DEFAULT_ADMIN_ROLE` | `_isIssuer` or `hasRole`, else `NotIssuerOrAdmin` |
| `PaxelRegistry.grantRole` / `revokeRole` | admin of the role (`DEFAULT_ADMIN_ROLE`) | OpenZeppelin `onlyRole(getRoleAdmin(role))` |
| `PaxelRegistry.renounceRole` | the account itself | OpenZeppelin |
| `PaxelEventLog.addEvent` | the asset's issuer | `registry.isIssuerOf`, else `NotIssuer` |

Holding `ISSUER_ROLE` alone is not enough to write to another issuer's passport. This is covered
by `test_NonIssuer_CannotUpdateStatus` and `test_NonIssuer_CannotAddEvent`, which use a second
address that holds the role. `DEFAULT_ADMIN_ROLE` is granted only to the deployer in the constructor
and is not granted `ISSUER_ROLE` automatically. All read functions are open.

The fuzz tests `testFuzz_RegisterAsset_OnlyIssuerRoleSucceeds` and
`testFuzz_AddEvent_OnlyAssetIssuerSucceeds` mix the issuer, a second issuer, the admin, a stranger
and random addresses as callers, and assert that only the correct path ever succeeds.

Operational note, not a code issue: the admin key controls every issuer grant. It should be a
multisig or hardware wallet on mainnet.

## 3. Integer handling: Pass

Solidity 0.8.28 checked arithmetic is used everywhere, with no `unchecked` blocks. The only
arithmetic is `entries.length - 1` right after a `push`, so it is at least zero, and
`length - offset` and `offset + i` in `getHistoryRange`, which run only after `offset < length`
is checked and with `i < count <= length - offset`. `tokenizedAt` and `timestamp` store
`block.timestamp` in `uint256`. Enum parameters out of range are rejected by the ABI decoder
before any function logic runs.

## 4. Unbounded loops or array growth: Pass, with a note

No state changing function contains a loop. `addEvent` costs the same whether a history holds
one entry or a million.

The history array for an asset grows without a limit. That is intended: the log is permanent and
append only. Growth is paid for by the issuer, one entry per transaction, and only the asset's
own issuer can add entries, so no third party can spam or grief another asset's history.

The note is that `getHistory` returns the whole array. On a very long history an `eth_call` could
hit the node's gas or response size limit. Fix applied: `historyLength(assetId)` and
`getHistoryRange(assetId, offset, limit)` were added so callers can page through any history.
The loop in `getHistoryRange` is bounded by the caller supplied `limit` and is view only.

## 5. Behavior when a role is revoked: Pass

Issuer checks are made live against `hasRole(ISSUER_ROLE, account)` on every write, never cached.
After `revokeRole(ISSUER_ROLE, issuer)`:

- `registerAsset` reverts with `AccessControlUnauthorizedAccount`
- `publishPassport` reverts with `NotIssuer`
- `updateStatus` reverts with `NotIssuerOrAdmin`
- `isIssuerOf` returns false, so `PaxelEventLog.addEvent` reverts with `NotIssuer`

The passport keeps its recorded issuer and history, stays readable, and the admin can still call
`updateStatus` on it, for example to set `Frozen`. If the role is granted again, the address
regains write access to the passports it registered. Covered by
`test_RevokedIssuer_IsBlockedImmediately` and confirmed in the Anvil walkthrough below.

## 6. Input validation: Pass, fixed during the pass

| Input | Handling |
| --- | --- |
| `registerAsset` with `assetId == 0` | reverts `ZeroAssetId`. A zero id would be ambiguous with an unset key. |
| `registerAsset` with an empty `metadataURI` | reverts `EmptyMetadataURI` |
| `registerAsset` with an existing id | reverts `AssetAlreadyRegistered` |
| `publishPassport`, `updateStatus`, `getPassport` on an unknown id | revert `AssetNotFound` |
| `updateStatus` to `Draft`, or on a passport still in `Draft` | revert `InvalidStatus` / `NotPublished`. A passport leaves Draft only through `publishPassport` and never returns. |
| `addEvent` with `dataHash == 0` | reverts `ZeroDataHash` |
| `addEvent` on an unknown id | reverts `NotIssuer`, since `isIssuerOf` returns false |
| `PaxelEventLog` constructor with a zero registry | reverts `ZeroAddress` |
| `grantRole` to the zero address | reverts `ZeroAddress`. Added in this pass as an override; OpenZeppelin allows it by default. |

The issuer address itself is always `msg.sender`, so it can never be zero.

## 7. No delete or overwrite of events: Pass

`PaxelEventLog` has exactly one state changing function, `addEvent`, and it only calls `push` on
`history[assetId]`. The `history` mapping is `private`. There is no `pop`, no `delete`, no indexed
assignment into an existing entry, no setter, no upgrade proxy, no `selfdestruct` and no
`delegatecall` anywhere in either contract. The registry reference is `immutable`, so the write
rule cannot be swapped out.

In `PaxelRegistry`, a passport is written in full only once, inside `registerAsset`, guarded by
`AssetAlreadyRegistered`. Afterwards only `status` can change, and every change emits
`StatusUpdated`. `issuer`, `metadataURI` and `tokenizedAt` have no write path. No function deletes
a passport.

## Verification

`forge build`: compiles cleanly with no warnings. The one lint note, on the public `registry`
immutable not being SCREAMING_SNAKE_CASE, is excluded in `foundry.toml` because renaming it would
change the ABI getter.

`forge test`: 35 tests passed, 0 failed.

- `PaxelRegistry.t.sol`: 17
- `PaxelEventLog.t.sol`: 11
- `PaxelSecurity.t.sol`: 7, including 2 fuzz tests at 512 runs each

### Anvil walkthrough

Deployed with `script/Deploy.s.sol` to a fresh local Anvil node (chain id 31337), then driven with
`cast`. Admin is Anvil account 0, issuer is account 1, stranger is account 2.

| Step | Action | Outcome |
| --- | --- | --- |
| 0 | Deploy script, simulate, then broadcast | Registry and event log deployed, event log wired to registry |
| 0 | Deploy script with a wrong `CHAIN_ID` | Stopped with "CHAIN_ID does not match the RPC" |
| 1 | Admin grants `ISSUER_ROLE` to issuer | success |
| 2 | Issuer `registerAsset` | success, status Draft |
| 3 | Issuer `publishPassport` | success, status Issued |
| 4 | Issuer `updateStatus` to Active | success |
| 5 to 7 | Issuer `addEvent`: DocumentAdded, ValuationReference, Transfer | success, 3 entries |
| 8 | Stranger `addEvent` | reverted `NotIssuer` |
| 9 | Stranger `updateStatus` | reverted `NotIssuerOrAdmin` |
| 10 | Stranger `registerAsset` | reverted `AccessControlUnauthorizedAccount` |
| 11 | Issuer registers the same id again | reverted `AssetAlreadyRegistered` |
| 12 | `getPassport`, `isIssuerOf`, `getHistory` | issuer, status Active, URI and timestamp correct; 3 entries in order with submitter and timestamps |
| 13 | Admin revokes issuer, issuer calls `addEvent` | reverted `NotIssuer` |
| 14 | Admin `updateStatus` to Frozen | success. History still has 3 entries. |

There were no unexpected reverts. No mainnet RPC has been used.
