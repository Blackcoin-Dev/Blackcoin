# Node 27 installed-v30.1.4 fee-recovery canary

This is an offline-reviewed, single-subject operator tool. It does not itself
authorize or execute a live action. No financial-authority receipt, wallet
signature, transaction bytes, fleet receipt, or live acceptance evidence is
included in this package.

The tool is pinned to the already-installed node 27 runtime and one retained
claim family. It accepts only service `node27`, container
`blackcoin-v4-gui-27`, Compose project `blackcoin30`, the sealed image reference
and image ID in the script, network version `300104`, subversion
`/Blackcoin:30.1.4/`, and the unnamed wallet. It cannot loop over the fleet and
cannot act on node 30.

The live transport is the canonical `/usr/bin/docker` only. The script starts
with `/bin/bash -p`, clears shell-injection variables, installs a minimal
absolute PATH, hashes the transport, and binds its owner/group/mode and complete
ancestry into receipts. The repository mock is accepted only through an exact
nonroot internal test hook for the sealed sibling fixture.

## Six command modes

Running with no phase selects `audit`. `audit` is read-only and writes a
machine-readable receipt for an exact stable runtime, active tip, wallet,
component, claim, anchor, plan, fee, payout, key inventory, PoS state, and PoW
state. It prints the exact JSON shape needed for a later sign-only authority.

`sign-only` requires the exact audit receipt and its SHA256 plus a separate,
canonical, owner-only mode-0600 financial-authority JSON and SHA256. The tool
repeats the audit and rejects any change to the runtime, tip, wallet generation,
component, subject, plan, fee, key inventory, or baseline. Its only wallet
mutation is the exact Core `resolveallshadowpowclaims` `sign_only` operation. It
requires one input, one same-script output, a final sequence, no change output,
no new key or payout, one persisted transaction, no mempool presence, and no
relay authority. A successful draft is durable and has no public delete path.
Before any current-state resample or mutation, it acquires the canonical shared
rollout, endpoint, node-cutover, PoW-quarantine, wallet-runtime, and dedicated
node27 recovery locks in that fixed order. Receipts bind exact paths,
device/inode identities, ownership, mode, and link count.

`relay` is deliberately nondeployable on installed v30.1.4. That Core RPC can
commit a freshly recomputed internal plan, but it does not atomically consume
the externally reviewed plan, active tip, height, wallet generation, component
fingerprint, and raw-transaction hash. A block can therefore arrive after a
shell precheck and before the mutation. Post-call validation cannot recall
bytes already relayed. The mode exits with the exact interface blocker before
it parses receipts, acquires locks, contacts the transport, or invokes an RPC.
The tool's RPC wrapper independently rejects
`commitshadowpowclaimresolution`. A future successor must provide reviewed
targeted-commit semantics and durable consumed-plan metadata before a separate
stage can make relay eligible.

`reconcile-sign` is read-only crash recovery for a missing sign-only receipt.
It requires the original exact audit and sign authority, acquires the same lock
set, and reconstructs evidence only from the exact persisted raw transaction,
decoded shape, current recovery component, signed preview, stable chain, key
inventory, and mempool-policy result.

`reconcile-relay` is read-only observation, not relay reconstruction. It can
identify the reviewed bytes in mempool or on chain even after the historical
observation context expires, but it cannot prove which plan the missing commit
result consumed. Its receipt is therefore
`EXACT_BYTES_OBSERVED_UNATTRIBUTED` or `AMBIGUOUS_CONTAINED`; it contains no
fabricated commit acknowledgements and is explicitly inadmissible as a relay or
final-acceptance receipt.

`verify-final` is also unavailable in this installed-v30.1.4 stage because no
admissible relay receipt can be produced. It exits before receipt parsing or
RPC. Read-only observations must not be relabeled as terminal acceptance.

## Financial boundary

The exact canary resolution fee, per-resolution cap, and total cap are all
`0.00019100 BLK` at `100 sat/vB` for one 191-vbyte transaction. The subject
anchor is `3e5437d71a2ba10e7cf1ab7b02ec458847d081a97041efd1e5336660b22cde87:0`.
The retained claim is
`2e76269d688a5c218703b800516a9c0b0b2757d5077a14c84a6473e33006103d`.
The resolution returns `9.83307830 BLK` to the exact original anchor script.
The original claim or the resolution may confirm. The original QQP2 proof may
revalidate on a descendant, and the resolution can forfeit the claim's quantum
payout. Future ordinary PoW claim fees are outside this one-transaction cap.

Every input receipt must be a single-link mode-0600 file under owned,
nonwritable ancestry. The tool opens and inode-pins two descriptors, verifies
the exact raw hash, and parses only that under-lock snapshot; later path reads
cannot substitute new authority bytes. Every tool-authored receipt uses
same-directory no-clobber publication, fsyncs temporary and committed files
plus the parent directory, rereads exact bytes, and publishes a durable
mode-0600 SHA256 sidecar under the same ancestry rule. Sign-only still creates
a durable wallet transaction, so operators must stop on every nonzero exit and
retain all receipts and exact hashes. This tool does not authorize public
relay, fee bumping, replacement, abandonment, recovery/repair, reindex/rewind,
candidate deployment, fleet expansion, or a node-30 role change.

## Validation

Run `tests/run.sh` from this checkout. It uses an offline Docker transport mock;
it does not contact Docker or the live fleet. The suite covers audit/sign-only
and sign reconciliation, the installed relay and final-acceptance hard
blockers, strict receipt schema/hash/mode/ownership/link-count/ancestry
bindings, under-lock byte snapshots, runtime and wallet identity hostiles,
shared-lock contention and path swaps, PATH/BASH_ENV/transport substitution,
tip/chainwork/wallet/component/plan and mempool-policy drift, a tip change after
`testmempoolaccept`, signed-byte shape violation, durable receipt sidecars,
exact-byte unattributed observation, expired observation context, and
`AMBIGUOUS_CONTAINED` evidence.

`PRODUCT-TEST-RECEIPT.json` is a machine-readable offline-fixture receipt. It
binds the exact tool, mock, hostile runner, assertion count, and log hash and
states the stable-chain, wallet/component/plan/raw-byte/mempool/lock/reconcile
predicates exercised. It is future evidence only: it contains no public
artifact receipt, financial authority, live mutation, or deployment claim.

`VALIDATION.txt` records the checked byte set and test receipt. `SHA256SUMS`
seals every non-manifest file in this directory. Any edit invalidates the tool
self-hash and every authority receipt created for earlier bytes.
