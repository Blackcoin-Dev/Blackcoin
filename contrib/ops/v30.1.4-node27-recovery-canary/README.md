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

## Four separate phases

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

`relay` is a later, separate invocation. It requires the exact sign receipt and
SHA256 plus a distinct mode-0600 authority that names the reviewed resolution
txid. It revalidates the persisted signed bytes and the exact managed plan, then
calls only `commitshadowpowclaimresolution TXID true`. It never calls generic
`sendrawtransaction`, abandon, fee-bump, replacement, unlock, mining-control,
Compose, or fleet operations. Relay is durable across restart; propagated bytes
cannot be recalled. A non-observed relay is receipted and exits nonzero.

`verify-final` is read-only. Acceptance requires either the exact resolution or
the retained original claim to have at least six active-chain confirmations,
the anchor to be spent, the recovery gate to be clear, PoS to be actively
staking with positive weight, regular PoW to have positive hashrate, and
`claims_submitted` to increase strictly above the recorded baseline of four.
The legacy and quantum key inventories and payout address must remain unchanged.

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

Signing is the last safe stop before public relay, but it still creates a
durable wallet transaction. After targeted relay there is no rollback that can
recall propagated bytes. Operators must stop on every nonzero exit, retain all
receipts and exact hashes, and use read-only reconciliation only. This tool
does not authorize fee bumping, replacement, abandonment, recovery/repair,
reindex/rewind, candidate deployment, fleet expansion, or a node-30 role change.

## Validation

Run `tests/run.sh` from this checkout. It uses an offline Docker transport mock;
it does not contact Docker or the live fleet. The suite covers successful
audit/sign/relay/final flows, both possible confirmed conflict winners, strict
receipt schema/hash/mode/ownership bindings, runtime and wallet identity
hostiles, tip/component/fee drift, signed-byte shape violation, deferred relay,
and independent terminal failures for confirmations, PoS, PoW hashrate, PoW
intent, and claim submission.

`VALIDATION.txt` records the checked byte set and test receipt. `SHA256SUMS`
seals every non-manifest file in this directory. Any edit invalidates the tool
self-hash and every authority receipt created for earlier bytes.
