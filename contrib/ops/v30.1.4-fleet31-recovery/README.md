# Installed-v30.1.4 fleet31 Phase-A recovery

This is a fleet-owned, Phase-A-only operator stage for the 31 regular-PoW
wallets: nodes 1–29 and 31–32. Node30 is structurally excluded. The public Core
development/release lane is outside this package.

The stage does not contain live runtime identities, financial authority,
wallet secrets, transaction bytes, or evidence of live execution. It does not
contact SSH by itself. An operator must supply a locally sealed mode-0600
runtime manifest with the exact installed image, executable, wallet, service,
container, Docker-transport, and lock identities.
Compose services use the exact zero-padded topology labels `node01` through
`node32`; node1's container remains `blackcoin-v4-gui` and other regular-node
containers remain `blackcoin-v4-gui-N` as declared by the sealed manifest.
For the sole unnamed wallet (`""`), the RPC transport omits `-rpcwallet`
entirely; it emits `-rpcwallet=<name>` only for a nonempty manifest wallet.

## Commands

`audit` takes a read-only stable chain cut for every regular-PoW node. It
requires main chain, no IBD, no pruning, peers, the exact installed signed
v30.1.4 source/runtime, normal unlock, active PoS, enabled PoW intent, exactly
one actionable quarantine component, and no indeterminate component. It calls
only `resolveallshadowpowclaims` in `preview` mode with an exact
`0.00019100 BLK` per-wallet cap and `100 atoms/vB` fee rate. The aggregate
31-wallet cap is exactly `0.00592100 BLK`.
If a normal block arrives after the stable preview but before the full
read-only node census finishes, `audit` retries the entire node envelope up to
five times. Runtime identity drift remains immediately fatal; continuous
chain/recovery-cut drift exhausts closed and never reaches a mutation.

The installed component fingerprint deliberately includes the active tip, so
Phase A permits that dynamic fingerprint to change only as part of the fresh,
stable, lock-held plan rebind authorized by the Phase-A receipt. The anchor,
generation fingerprint, claim set, classification, descendants, fee, vsize,
input, and output remain exact against the audit. The mutation response must
then match the exact fresh component, including its dynamic fingerprint.

`phase-a` accepts only a separate owner-only mode-0600 authority receipt. The
authority must bind the audit hash, tool hash, runtime-manifest hash, installed
source commit/tree, exact node set, fee rate and caps, action `sign_only`, and
risk acknowledgements. It also must authorize an immediate fresh-plan rebind
only when the component identity, transaction shape, and fee are unchanged
from the audit. Each node receives a durable no-clobber intent before the only
allowed wallet mutation:

```
resolveallshadowpowclaims {
  "action": "sign_only",
  "expected_plan_id": "<fresh exact plan>",
  "acknowledge_fee_and_conflict_risk": true,
  "fee_rate": "100",
  "max_fee_per_resolution": "0.00019100",
  "max_total_fee": "0.00019100"
}
```

The result must prove one exact signed transaction was persisted with zero
relay authority, zero broadcast, one input, one final-sequence input, one
same-wallet output, no change output, and the exact 191-vbyte fee. Per-node
intent/result receipts and SHA256 sidecars are mode 0600 and no-clobber.

`reconcile-a` is read-only crash handling. It never signs or retries an
unmatched intent. If the exact durable non-relayable bytes are observable, it
records that fact; if no mutation is observable, a new audit and authority are
required before that unfinished node may be attempted. The completed nodes
remain receipt-bound.

`phase-b-preview`, `reconcile-b`, and `monitor` contain read-only successor
logic for review. `phase-b` is unconditionally hard-disabled before it parses
receipts, acquires locks, contacts Docker, or invokes RPC. This stage cannot
grant relay authority or broadcast. Phase B requires a separately reviewed,
signed, and pushed follow-up stage plus a distinct exact-signed-byte financial
authority receipt.

The tool never calls `commitshadowpowclaimresolution`, `sendrawtransaction`,
`abandontransaction`, `bumpfee`, `setpowmining`, `walletpassphrase`, recovery,
repair, reindex, rewind, Compose, or deployment operations. The only mutating
RPC text in the executable is `resolveallshadowpowclaims`, whose action is
validated by phase.

## Risk boundary

A durable signed draft has no clean public cancellation path. A later
confirmed recovery pays the displayed base-chain fee and may permanently
forfeit the retained QQP2 proof’s chance at a future quantum payout. Phase A
does not authorize that confirmation, relay, broadcast, future claim fees, or
any action on node30. Installed v30.1.4 also cannot reconstruct the original
acknowledged plan/tip/generation receipt after a crash that occurred after a
durable Phase-B relay grant but before the RPC result; a successor must label
that state as observation-only and must never blind-retry it.

## Offline validation

Run `tests/run.sh`. The sealed nonroot mock is the only accepted test
transport. The suite exercises the exact 31-node set, node30 exclusion,
authority hash/mode/schema/cap/acknowledgement gates, per-node fee drift,
stable preview binding, no-relay Phase-A results, no-clobber receipts,
lost-response reconciliation, resumable unfinished nodes, and Phase-B
before-transport failure. It does not contact Docker, SSH, wallets, or the
network.
