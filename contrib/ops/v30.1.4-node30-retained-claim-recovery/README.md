# Installed-v30.1.4 node30 retained-claim recovery

This fleet-only v2 package resolves node30's one retained legacy QQP2 claim while
preserving three independent invariants: normal PoS remains active, ordinary
PoW remains disabled, and the Free-Claim pause marker remains installed. It
does not release the Free-Claim worker, invoke that worker, modify its queue,
or change node30's role. The public Core/release lane is outside this package.

The package is bound to signed installed source commit
`13262151077cce3f72d07d17dc7725b2b6a8e1ab`, tree
`a6f7757c34b70fab841905765462d6769112d049`, and signer fingerprint
`SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70`. It also records the exact
confidential read-only predecessor receipt SHA256
`ca084d6d76fb67532fd65ff8b44943bc3a8c12f589708a11872417223066eec9`
and the exact user-order SHA256
`0252ebcc3dc2ca8a20e8b9708738c30f9c32f6b0dea213bb8937467b2dab2dff`.
No live runtime identities, wallet secrets, addresses, outpoints, signed bytes,
or executable financial authority are checked in.

## Runtime contract

The operator supplies an owner-only mode-0600 schema-2 manifest bound to
`installed-v30.1.4-node30-retained-claim-recovery/v2`. Live execution
requires root, `/usr/bin/docker` with its exact sealed hash, the installed
image and executable hashes, the unnamed node30 wallet, exact production
Free-Claim paths, and the complete reviewed lock set. The pause marker,
wrapper, and preserved worker must retain their exact hashes. The tool pins
wallet RPCs to the inspected container ID and stops on runtime replacement.
Every command revalidates the loaded-wallet array as exactly `[""]`, the
selected wallet as the unnamed wallet, and `getwalletinfo.walletname` as empty.
Every mutating phase acquires the complete lock set through canonical,
owner-controlled directories and unique owner-only regular lock files. It
creates absent locks with `O_EXCL`; it never follows, relinks, or silently
changes the mode of an existing lock.

The test transport is accepted only for nonroot execution and only when its
repository fixture bytes match the hash compiled into the tool. Live mode
cannot substitute a test transport.

## Phase sequence

`audit` is read-only. It requires a healthy, peered, synchronized, unpruned
main-chain node; normal unlock; active PoS with positive weight; ordinary PoW
disabled with zero hashrate; one nonambiguous retained-claim blocker; an
authenticated unspent anchor; and one exact 191-vbyte recovery capped at
`0.00019100 BLK` at `100 atoms/vB`. A persisted draft is the installed
`classification=resolution_pending`, `status=reuse_managed` state; a fresh
unsigned action is `classification=current_branch_ineligible`. The
tip-relative component fingerprint may rebind only while the anchor,
generation fingerprint, claim set, fee, vsize, input/output amounts, and risk
family remain exact. It emits a mode-0600 audit and a complete
Phase-A authority template.

`phase-a` accepts only a separately created mode-0600 authority whose supplied
SHA256 binds the audit, runtime, tool, shared primitive, installed source,
exact user order, exact fee and risk acknowledgements. It writes and fsyncs a
no-clobber intent before the sole Phase-A mutation:

```json
{"action":"sign_only","expected_plan_id":"<fresh-plan>","acknowledge_fee_and_conflict_risk":true,"fee_rate":"100","max_fee_per_resolution":"0.00019100","max_total_fee":"0.00019100"}
```

The exact RPC return is durably published before any post-call wallet read.
The result must be one exact persisted nonrelayable signed transaction. A
missing RPC response is never retried. `reconcile-a` can observe the exact
persisted bytes after an unmatched intent; otherwise it requires a new audit
and authority.

`phase-b-preview` is read-only and binds the exact Phase-A signed transaction,
fresh plan, runtime, wallet selection, PoS state, disabled ordinary-PoW role,
and pause artifacts. Transaction identity contains only immutable txid, raw
and decoded hashes, input, output, script, and vsize. Confirmations and
blockhash are a separate observation and may change without changing the
authorized bytes. That observation also binds the installed wallet's typed
`qq_shadow_pow_resolution_relay_authorized` metadata (`"0"` before Phase B,
`"1"` after durable authority) to the preview's relay state. The preview
independently reads the active-chain anchor
with `gettxout(outpoint,false)`, proves its value, proves the one output uses
the exact same script, and computes `anchor value - signed output =
0.00019100 BLK`; it never trusts the RPC's declared fee alone. It emits the
separate Phase-B authority template. If the anchor is already spent by an
authenticated active-chain component transaction, it emits no Phase-B spend
authority.

Installed v30.1.4 `blackcoin-cli` exits successfully with exactly empty stdout
when `gettxout` addresses a spent outpoint. The node30 transport maps only that
exact method and zero-byte output to typed `None`. Whitespace, invalid JSON,
nonzero exit, and empty output from every other RPC remain fatal.

`phase-b` accepts only a distinct mode-0600 authority bound to the Phase-A and
Phase-B-preview receipt hashes and the exact signed-transaction identity. It
writes and fsyncs a no-clobber intent before the only Phase-B mutation:

```json
{"action":"commit_and_broadcast","expected_plan_id":"<fresh-plan>","acknowledge_fee_and_conflict_risk":true,"max_fee_per_resolution":"0.00019100","max_total_fee":"0.00019100"}
```

The exact RPC response is fsynced as `phase-b-ack-node30.json` immediately on
return and before any chain, wallet, runtime, role, or pause read. The response
must acknowledge the exact plan/tip/height/wallet generation and fee and bind
the exact authorized hex. Counters are typed as integers. A complete response
must report zero newly signed drafts, one durable relay grant, exactly one
broadcast-or-already-in-mempool result, an empty error, and the exact bytes in
the mempool. A
structured failure after durable relay authority is recorded as
`EXACT_RELAY_AUTHORITY_PERSISTED_PENDING_RELAY`, never blindly retried, and
preserves the exact nonempty RPC error for the installed scheduler plus
read-only reconciliation. A response
lost before an ACK is observation-only under installed v30.1.4 because durable
metadata cannot reconstruct the consumed acknowledged plan receipt.
`phase-b` can resume only read-only from an exact intent+ACK chain;
`reconcile-b` never retries an unmatched intent. Post-intent observation first
takes a read-only mutex-serializing preview, then re-reads the anchor, durable
metadata, exact wallet inventory, and role. Both handle a confirmation that
races the RPC by proving exactly one allowlisted component transaction decodes
to an input spending the exact anchor, has active block-header membership,
matches the exact resolution identity when the resolution wins, and leaves
zero blockers. A terminal receipt is accepted on resume only after validating
the complete Phase-A, preview, authority, intent, ACK, result, lock, runtime,
wallet, role, and pause chain.

`monitor` is read-only. It requires an active-chain confirmation of either the
exact resolution or original claim, exactly one decoded transaction input that
spends the anchor, the anchor spent, zero retained blockers, active PoS,
disabled ordinary PoW, and unchanged Free-Claim pause artifacts.
It never claims that mempool presence alone cleared the blocker and never
releases or invokes the Free-Claim worker. An original-claim confirmation can
clear the retained component without authorizing or broadcasting the recovery.

Receipts created by signed predecessor commit `9b6ce967e581efcdeeeea1b8aee29c6146b9e9e5`
carry tool SHA256
`55b79cde81f6d00ff105c454b6106026dcae794aa60ef55f0c3b27016c8c3cd1`.
They are accepted only by `monitor`, only as a uniform audit/Phase-A/intent
chain, and only when the operator supplies an owner-only mode-0600 copy of the
exact `801ffe62929675725c1261c913683aa48ea2e4bd` product-test receipt:

```text
--predecessor-product-receipt <absolute-path> \
--predecessor-product-receipt-sha256 3dfe86f2eb0b539ab26655ed2edd12b74fceb7cf7c36a376926b7cf3ec7c7356
```

That compatibility evidence authorizes read-only monitoring only. Every
phase, reconciliation, signing, relay, and broadcast path continues to require
receipts created by the exact currently executing tool.

## Prohibited surfaces

The executable contains no targeted recovery commit, generic transaction,
fee-bump, abandon, wallet-unlock, mining-role, worker, Compose, deployment,
repair, recovery, reindex, or rewind call. Its RPC allowlist comes from the
hash-pinned signed fleet primitive. Receipt writes are owner-only, fsynced,
hard-link published, SHA256-sidecar bound, and no-clobber. A crash after a
valid owner-only JSON receipt is linked but before its publisher temporary
hard link is removed is recoverable only when that exact same-inode temporary
name is the sole second link. A crash before the sidecar is linked is
recoverable only by certifying the exact JSON and recreating the missing
sidecar. An unrecognized extra link or an existing malformed or mismatched
sidecar is never repaired.

## Validation

Run `tests/run.sh` as a nonroot user. The stateful mock contacts no Docker
daemon, SSH host, wallet, chain, or network. It exercises both exact phases,
authority hash/mode/order/cap gates, marker preservation, PoS and role
invariants, container-ID pinning, post-sign classification/fingerprint drift,
independent anchor-value/same-script fee proof, immutable transaction identity,
no-clobber replay rejection, JSON/sidecar crash recovery, immediate ACK
ordering, typed full and structured partial post-persistence outcomes, exact
wallet inventory on resume, lost-response reconciliation ordering, exact-byte
Phase B, publisher hard-link crash healing, hostile lock paths, unique decoded
original-claim and resolution confirmation races, complete authority-chain
tampering, the installed empty-stdout `gettxout` behavior, rejection of empty
stdout from every other RPC, authentic predecessor-receipt monitor
compatibility, rejection of missing or mismatched compatibility evidence,
rejection of predecessor receipts on phase commands, and active-chain
clearance.
