# Gold Rush PoW claim lifecycle and recovery

This document describes the wallet behavior developed for Issue #37 and the
v30.1.5 candidate. The same-anchor continuation and typed
mining gate below are not part of the immutable `v30.1.4` tag. They are later
wallet and operator-safety changes, not changes to the Gold Rush consensus
rules shipped in v30.1.1 through v30.1.4. Historical release notes retain the
behavior of those releases and link here for the later recovery model.

## Claims, quarantine, and components

A wallet may have more than one historical unresolved `QQSPROOF`, and consensus
can evaluate a bounded set of up to 64 claims in one block. The post-release
hotfix candidate does not treat that protocol bound as permission to spend
additional fee anchors: while an authenticated family member is live, its
mining gate waits. The limit does not promise that any claim will be included
or credited.

A live claim and a quarantined claim are different states:

- A **live claim** is an unconfirmed wallet-authored claim currently in the
  local mempool. QQSPROOF carriers have a dedicated one-hour relay residence
  limit; ordinary transactions retain the node's existing mempool-expiry
  policy.
- A **quarantined claim** is an unconfirmed wallet-authored claim that is no
  longer in the local mempool. Another peer may still retain and later confirm
  it, so the wallet keeps its fee input reserved and generic abandonment remains
  unavailable.
- A **claim component** is the wallet-known graph of sibling conflicts and
  descendants associated with one nearest active-chain confirmed anchor. A
  component can contain many historical claim objects while requiring at most
  one recovery transaction for its current confirmed anchor.

The raw unresolved or quarantined object count is therefore not the miner gate.
The wallet separately reports live objects, raw quarantined objects, actionable
or indeterminate components, current anchors, and pending or confirmed
resolutions. Resolved descendants remain in wallet history for audit and reorg
safety, but do not independently create another recovery action.

For compatibility, `getpowmininginfo.quarantined_claims` retains the legacy
count that blocks claim creation in immutable v30.1.4. The complete audit count
is reported separately as `raw_quarantined_claims`. The v30.1.5 candidate
does not use either raw count as its mining decision: an authenticated family
may remain quarantined while the typed action relays or refreshes it. Unsafe or
indeterminate families still fail closed. Recovery never enables mining itself.

## Same-anchor continuation for QQP2, QQP3, and QQP4 claims

The v30.1.5 candidate's normal lifecycle for an exact
wallet-authored QQP2, QQP3, or QQP4 claim keeps one confirmed fee anchor
reserved until a member of that claim family confirms or the anchor is
otherwise spent on the active chain. A live member pauses another sibling in
that family; it does not prevent the aggregate wallet gate from servicing an
independent safe family.
If an eligible member has left the local mempool but is still inside its
dedicated one-hour relay lifetime, Core first relays those exact bytes.

When no family member is live or eligible for that exact relay, the typed
mining gate may authorize one new current-tip, current-policy sibling that
spends the same confirmed anchor and preserves the same legacy target and
quantum payout. Every sibling carries durable root, parent, family, and ordinal
metadata. The siblings conflict, so at most one can confirm and charge its
ordinary claim fee. This does not consume another wallet coin, create a chain
of recovery payments, or release the anchor for an unrelated claim.
The retained family supplies its own authenticated payout script, so waiting,
relaying, and refreshing it do not require or allocate the wallet's configured
future-new-anchor payout key. `getpowmininginfo.payout_address` describes that
separate configured binding and may therefore be empty or different while a
retained family is being serviced. Explicit one-call key-creation consent may
proactively bind or create the future-new-anchor payout so the non-HD-key
backup warning is delivered before background work continues.
Same-anchor siblings remain `QQSPROOF` claims; the candidate does not change
existing claim reward, winner, loser, late-claim, or reimbursement consensus
rules.

The refresh path is deliberately narrow. Each mining-relevant component must be
an unforked, gap-free family of exact single-input wallet-authored carriers with
authenticated creation metadata and one unchanged anchor, target, and payout.
Multiple safe families are aggregated and one action family is selected
deterministically. Eligible absent bytes have priority over a paid refresh,
and a refresh has priority over waiting on an unrelated live or transiently
deferred family. Any wallet-relevant unsafe component closes the whole gate.
Purely incoming foreign proofs remain visible as audit history but cannot claim
mining authority over the recipient wallet. Wholly foreign UNKNOWN/non-authored
mixed history is likewise audit-only; once an ordinary member spends wallet
value or is marked from-me, the mixed graph fails closed. Adopted families,
ambiguous database state, future proof formats, and inconsistent lineage also
fail closed. A deterministic relay-policy rejection authorizes a
sibling only when a fresh full mempool test reproduces the exact low-fee
rejection on the same tip and wallet snapshot.

No claim input is released merely because its mempool or shadow-reward
eligibility window expires. Expired signed claim bytes can still be included
directly in a block during Gold Rush, so peer-retained bytes remain a live
base-chain conflict. Historical release-candidate retirement markers are
fail-closed input holds: wallet repair atomically reopens and quarantines those
records unless an active-chain conflict conclusively spent the anchor.
Fee-paying conflict recovery remains a separate,
explicit, default-off path under exact manual consent or bounded automatic
standing consent. The existing recovery engine can authorize that path for a
component it classifies as conflict-resolvable, including
`unbound_proof_may_revalidate`, even when the built-in miner's normal path can
continue the authenticated same-anchor family. Mining alone never invokes that
fee path, and same-anchor continuation does not require it.

## Typed mining-gate telemetry

The v30.1.5 candidate adds one complete, tip-pinned gate to
`getpowmininginfo`. Candidate-aware automation must require all of these fields
together; a partial set is invalid and fails closed:

- `mining_gate_coherent`, `mining_gate_action`,
  `mining_gate_can_submit`, and `mining_gate_database_ambiguous`;
- `mining_gate_unresolved_components`, `mining_gate_live_claims`,
  `mining_gate_eligible_claims`, and `mining_gate_family_claims`;
- `mining_gate_unsafe_claims` and `mining_gate_unsafe_components`; and
- `mining_gate_relay_txid`, `mining_gate_lineage_head_txid`, and
  `mining_gate_candidate_state_fingerprint`.

The safe action family is `create_new_anchor`, `wait_for_live`,
`wait_for_next_tip`, `relay_existing`, and `refresh_same_anchor`. Without a
worker override, `mining_gate_can_submit` is true only for
`create_new_anchor` and `refresh_same_anchor`; it is false for
`wait_for_live`, `relay_existing`, and `unsafe`. `wait_for_next_tip` is an
optional transient action override, so `mining_gate_can_submit` retains the
fresh inventory value and may be true or false. A true value does not authorize
bypassing the reported wait. Supervisors must accept a proven next-tip wait but
must never require observing it for liveness. `relay_existing` requires a
nonzero 64-character hexadecimal txid; a next-tip wait may retain that fresh
inventory relay txid. `unsafe`, an
incoherent snapshot, either database ambiguity flag, or a nonzero unsafe
claim/component count fails closed.
`getpowclaimrecoveryinfo.database_outcome_ambiguous` and
`getpowmininginfo.claim_recovery_database_outcome_ambiguous` must also remain
false before any wallet action.

Zero instantaneous hashrate is expected while the action waits or relays.
Likewise, unresolved, live, quarantined, blocking, family, and recovery counts
can remain nonzero for a safe authenticated family. Those raw counts are audit
evidence, not standalone health predicates, and must not be compared
numerically between immutable v30.1.4 and the candidate. Monitor active-tip
progress, action/fingerprint age, and hashrate as a separate bounded staleness
alert. Do not restart, unlock, spend, or rotate a payout key solely because that
alert fires.

After version and image identity independently verify immutable v30.1.4,
absence of every typed field identifies its legacy telemetry. Field absence
alone does not identify a binary. Once a candidate starts, automation must
never silently fall back to legacy quarantine-count or positive-hashrate
predicates.

## QQP2 and QQP3 eligibility

Claims created before height 5,993,200 use QQP2 rules. At height 5,993,200 the
QQP3 canonical competing-claim rule begins. A QQP3 claim is eligible at its
authenticated origin height and for up to 64 later blocks while its origin
parent remains on the active branch. A claim inside that origin-plus-64 window
is live for recovery classification even if it is not currently in the local
mempool. The recovery classifier must not infer terminal status from a reject
string or elapsed wall-clock time.

QQP2 does not commit an origin height or input into its proof hash. A QQP2 proof
that fails against the pinned tip can therefore become valid against a later
descendant context without changing its transaction bytes. Its typed
`unbound_proof_may_revalidate` disposition is therefore never described as
permanently dead or terminal. The classifier reports it separately from both
terminal and generic retryable failures.

For a strict wallet-authored singleton with an authenticated confirmed anchor,
the candidate first relays eligible exact QQP2 bytes and otherwise appends one
current-policy sibling spending that same anchor. The old and new claim cannot
both confirm, and no second fee input is consumed. A separately fee-paying
resolution remains available only through exact manual conflict consent or an
explicit bounded automatic policy. That separately authorized engine can act
on an `unbound_proof_may_revalidate` component even though same-anchor
continuation is the normal built-in-miner path. Generic transient or
indeterminate conditions, local state errors, future-origin proofs, and
future-version proofs remain fail-closed and cannot authorize recovery.

## v30.1.4 compatibility boundary

The regression suite pins the historical daemon and CLI to the checked-in
v30.1.4 provenance manifest. It exercises an exact wallet and datadir through
v30.1.4, the candidate, v30.1.4 again, and the candidate again after the
candidate has written a QQP3 sibling and durable family metadata for a QQP2
root. The older wallet code can open the database, read both exact transaction
byte strings, preserve the candidate's unrecognized transaction metadata, and
perform an ordinary address-book write. Reopening with the candidate restores
the same family fingerprint, confirmed anchor, target, payout, lineage, and
zero-recovery-spend result.

The functional harness first leaves its opt-in RPC documentation checker
enabled and requires v30.1.4 to diagnose the candidate-only response keys.
It then disables only that diagnostic to model the release default and performs
the old-version read and write checks. The test never deletes, renames, or
normalizes the candidate metadata.

That round trip proves wallet-data compatibility; it does not backport the
typed mining gate. When v30.1.4 sees the quarantined historical member, its
legacy global quarantine check can keep the built-in PoW worker in
`claim_quarantined` at zero hashrate even while the candidate recognizes a
safe live or refreshable member of the same family. Operators must not infer
candidate PoW liveness from successful rollback startup or wallet readability.

The suite separately runs exact v30.1.4 and the candidate at the same time. A
candidate-created QQP3 same-anchor carrier is independently accepted and then
delivered through v30.1.4's transaction P2P path. v30.1.4 includes those exact
bytes in a PoS block; both versions restart on the byte-identical block. A
longer competing PoS branch disconnects it, removes the synthetic payout, and
returns the still-valid carrier for admission before v30.1.4 includes it on
the winning branch. A final isolated restart reproduces the shared block bytes
and candidate family state. These assertions cover the protocol-compatible
transaction, block, restart, and reorganization boundary without claiming that
v30.1.4 implements candidate-only wallet policy.

## One shared recovery engine

The Issue #37 release uses one component classifier and one resolver for GUI,
CLI/RPC, daemon, and optional automatic operation. Public commands and fields
must be taken from the built-in help of the installed build; this document does
not assign names to surfaces that a particular build may not expose.

The resolver separates three authorities:

1. **Preview** is read-only. It pins the active-chain tip and wallet-processed
   tip, records the wallet generation, canonicalizes any selected claim to its
   current confirmed anchor, and returns one proposed same-script resolution per
   independent anchor. It reports the exact fee, aggregate fee, affected
   descendants, refusals, and a plan identifier. A preview does not sign,
   persist, broadcast, release a reservation, unlock a wallet, or enable mining.
2. **Sign and persist** requires a normally unlocked local-key wallet, explicit
   fee-and-conflict acknowledgement, and the exact current preview plan. It
   stores the signed transaction bytes durably. A signed draft has no relay
   authority and is not a generic restart-rebroadcast instruction.
3. **Commit and broadcast** is a separate explicit decision. The wallet first
   records durable authority for the exact signed bytes and then attempts relay.
   A retry reuses those bytes; it does not fee-bump, replace them, or create a
   second resolution for the same anchor generation.

The current headless flow makes both consent boundaries explicit. First call
`createshadowpowclaimresolution <claim_txid>` to obtain a claim-selector
preview. Signing requires that exact `plan_id` as `expected_plan_id`. A
successful signing response then returns `current_plan`, a fresh read-only
commit preview keyed to the exact signed resolution txid. Pass that nested
`plan_id` to `commitshadowpowclaimresolution <resolution_txid> true
<expected_plan_id>`. Calling `commitshadowpowclaimresolution
<resolution_txid>` without acknowledgement is side-effect-free and provides a
fresh commit plan after restart or for an authenticated legacy resolution.
Claim-selector and resolution-selector plans are intentionally not
interchangeable.

Immediately before signing, persistence, and relay, the engine rechecks the
active tip, wallet-processed tip, wallet generation, confirmed unspent anchor,
component fingerprint, fee limits, and exact transaction shape. A changed tip
or wallet state fails closed and requires a fresh plan. Independent anchors are
persisted before relay; subsequent relays can be deferred to a fresh pinned
pass if wallet or mempool state changes.

Claim provenance, quarantine observations, branch-age observations, signed
drafts, and relay authority become authoritative only after their complete
wallet-database transaction commits. A write failure leaves the prior live
record in force. An indeterminate commit outcome latches recovery closed until
the wallet is reloaded; neither the GUI nor an automatic scheduler may infer
spending authority from metadata whose durable state is unknown.

Manual recovery is available through the Issue #37 GUI and headless surfaces
that wrap this engine. Compatibility commands from older releases may remain,
but their help is authoritative for whether they expose only preview/signing or
also the separate commit step.

## Local relay-authority revocation

The v30.1.5 candidate can durably cancel this wallet's future relay authority
for one exact managed resolution without deleting the signed transaction or
making its anchor spendable:

```bash
blackcoin-cli -rpcwallet="Wallet Name" \
  revokeshadowpowclaimresolution "<resolution_txid>" true
```

The required `true` acknowledges that signed bytes may already exist in this
node's mempool, a peer, a miner, a log, or a backup. Local revocation cannot
recall those copies, undo an existing confirmation, or prevent either the
original claim or the conflicting resolution from confirming. After the
managed record is authenticated against a wallet with a chain interface, the
result reports the exact mempool snapshot and `may_still_confirm=true`. It also
reports whether relay authority was active, whether a new durable state was
committed, whether a local wallet broadcast is already reserved in flight,
whether the anchor remains reserved, and the resulting typed mining-gate
action. Observations that cannot be authenticated are omitted rather than
reported with default values.

Revocation is restriction-only and does not require a wallet unlock. It writes
the canonical durable state `relay_authorized=0, relay_revoked=1`; the
`relay_revoked` bit is a per-transaction tombstone, not the wallet-wide
automatic-recovery policy. The operation never abandons the transaction,
erases its signed bytes or metadata, removes it from the mempool, releases or
unlocks the shared anchor, enables normal coin selection, or enables mining.
An already-revoked record is an idempotent success. A local wallet broadcast
already in flight is refused without changing durable authority, so the
operator can wait for its verdict and retry.

The tombstone survives restart. The recovery scheduler, ordinary wallet relay
paths, and the successful-`sendrawtransaction` wallet callback cannot promote
or retry the tombstoned bytes. The raw-transaction RPC is still an explicit
node-level disclosure mechanism: a caller who possesses the hex can submit it
again, and revocation cannot make already accepted bytes disappear. Such a
submission does not clear the wallet tombstone or restore later scheduler
authority.

Reauthorization requires a new read-only preview for the current chain and
wallet generation, followed by an explicit exact-plan commit while the wallet
is normally unlocked. That commit atomically clears the tombstone and grants
authority only to the same authenticated transaction bytes. A plan created
before revocation is stale and cannot reauthorize anything. Generic relay
notifications and persisted-retry paths cannot perform this transition.

Database begin or write failures leave the prior authoritative state in force.
An indeterminate commit outcome latches recovery closed and reports
`durable_state_ambiguous=true`; reload the wallet and inspect the exact managed
record before relying on either the former authority or the requested
tombstone. Fields whose durable value cannot be known, including
`durable_state_changed`, `relay_authority_revoked`, and `locally_cancelled`,
are omitted from that ambiguous receipt rather than serialized as false.
Revocation likewise refuses malformed, foreign, legacy, missing,
unreserved, or database-ambiguous records instead of describing them as
locally cancelled.

## Complete recovery history and authorization receipts

Dedicated recovery status does not depend on the general transaction-history
page limit. The existing `getpowclaimrecoveryinfo true` response remains
available. For bounded responses, supply an options object:

```sh
blackcoin-cli -rpcwallet=example getpowclaimrecoveryinfo true '{"page_size":100}'
blackcoin-cli -rpcwallet=example getpowclaimrecoveryinfo true '{"page_size":100,"cursor":"TOKEN_FROM_PREVIOUS_PAGE"}'
```

`page_size` accepts 1 through 1000. A component header, each node, and each
transaction-list membership count as separate flat records, so one large
component cannot bypass the requested record bound. Read `pagination.next_cursor`
until `pagination.complete` is true. Cursors are opaque and bind the wallet,
active tip, wallet generation, and deterministic classified inventory. Restart
at the first page after a stale-cursor error; never combine pages from different
snapshots. Pagination is read-only and grants no recovery authority.

Managed nodes expose `authorization_receipt` when a valid exact-plan receipt
is available. It identifies the latest successful explicit authorization's
plan, tip/height, wallet generation, and origin. Core binds that receipt to the
exact witness transaction identity. Revoking local relay leaves the receipt
visible as historical evidence, not current permission. A later successful
exact-plan authorization replaces it. Missing or malformed older receipt data
is reported as null and does not reinterpret the record's existing relay
authority. The GUI uses the same Core receipt in recovery-review details.

Check `usage_available` before interpreting recovery-accounting numbers;
`getpowmininginfo` exposes the corresponding `recovery_usage_available` flag.
An unavailable snapshot is not zero usage and cannot authorize automatic
spending. Non-preview recovery actions and refusals emit stable wallet-scoped
`pow_claim_recovery_audit v=1` events with typed status/reason, plan and snapshot
identity, anchor/component, origin, fee, and an existing transaction identity
when applicable. Read-only preview and successful empty no-op requests do not
emit action events. No raw transaction, script, address, or key material is
included.

## Optional automatic recovery

Automatic recovery is wallet-scoped and off by default. An unset policy or
**Pause and ask** grants no standing spending authority. Enabling the seventh
control under **Staking & Mining → Optional automation** records explicit limits
for:

- the maximum fee for one resolution;
- the maximum aggregate fee in one pass;
- the rolling fee budget and window;
- the maximum number of actions in that window; and
- the minimum active-branch stale depth.

`getpowclaimrecoveryinfo` reports the recorded policy and current component
gate without creating, signing, or broadcasting. `setpowclaimrecovery` records
`unset`, `pause_and_ask`, or `automatic`; automatic mode requires every bounded
limit in that RPC's help.

Headless startup settings may seed a policy only for a wallet that has not
already recorded a choice. A persisted wallet choice wins. Automatic recovery
requires an already-enabled PoW miner, synchronized chain and wallet tips,
wallet broadcasting, normal local-key unlock for a new signature, authenticated
wallet-authored or explicitly adopted provenance, and a component that the
shared classifier finds safe. It will not unlock the wallet, enable the miner,
adopt unknown history, abandon a claim, or override any fee, rate, or staleness
limit. The narrow typed QQP2 descendant-revalidation disposition is eligible
only with the risk disclosure and standing consent above; it does not make
generic transient, local-error, future-origin, future-version, or indeterminate
states recoverable.

The corresponding startup seed is
`-autoresolvefailedclaims=automatic` or
`-autoresolvefailedclaims=pause-and-ask`. Automatic mode also requires explicit
values for `-autoresolvemaxfee`, `-autoresolvebatchfeecap`,
`-autoresolverollingfeebudget`, `-autoresolverollingwindow`,
`-autoresolvemaxactions`, and `-autoresolvestaleblocks`. Omitting the seed
records no choice and grants no spending authority.

The rolling action and fee windows use active-chain median time, not the host's
wall clock. Moving the system clock forward or backward cannot expire prior
automatic actions. Records created by an older wall-clock-based build are
treated as age zero when their stored time is ahead of the current chain clock,
without moving the window past other recent actions. Their transaction
timestamp provides a floor when old metadata is behind it.

Once the wallet has explicitly committed exact resolution bytes for a
component, safe retries may continue across restart without creating a new
spend. Disabling automatic
recovery prevents new automatic actions; it cannot recall a transaction that
was already propagated. Disabling the built-in PoW miner and committing a
recovery action are serialized per wallet: whichever operation starts first
reaches a definitive result before the other can change that authority. A
disabled miner is never restarted by recovery.

## Confirmation outcomes and reorgs

Broadcast does not guarantee mempool acceptance or confirmation. Peers that
retain the original claim may reject the conflict. Only a transaction that
confirms pays its base-chain fee.

- If the **resolution confirms first**, it returns the anchor value to the same
  wallet script minus its ordinary base-chain fee. The conflicting claims and
  descendants cannot confirm on that active branch. The resolution fee is not
  a shadow claim fee and receives no shadow reimbursement.
- If the **original claim confirms first**, the competing resolution cannot
  confirm on that active branch. The wallet retains the record for audit and
  rolling-budget accounting, reclassifies the surviving graph, and may discover
  a new frontier after the claim output is confirmed and spendable. A later
  frontier is a new plan; one call cannot promise to finish every future branch.

The wallet releases no reservation merely because a claim left the mempool,
exceeded one hour of relay residence, or exhausted its original
origin-plus-64 window. It releases only after an active-chain confirmation
spends the anchor. If the controlling block is disconnected, the wallet
reopens and reclassifies the component on the new pinned tip and restores any
required quarantine. A transaction already seen by peers cannot be withdrawn.

## Operator checks

Before authorizing a manual plan or automatic policy, verify:

- the node is synchronized and not reindexing or importing;
- the wallet is normally unlocked, not staking-only, and uses local private
  keys;
- the preview identifies the expected current anchor and component;
- every proposed fee is positive and inside the chosen per-action, batch, and
  rolling limits; and
- the warning describes both confirmation outcomes and the possibility of a
  later frontier.

Keep wallet backups current. Recovery records and policy metadata are wallet
state and must survive restart and reorg alongside the transactions they
describe.
