# Gold Rush PoW claim lifecycle and recovery

This document describes the wallet behavior developed for Issue #37. It is a
later wallet and operator-safety change, not a change to the Gold Rush consensus
rules shipped in v30.1.1 through v30.1.3. Historical release notes retain the
behavior of those releases and link here for the later recovery model.

## Claims, quarantine, and components

A wallet may have more than one unresolved `QQSPROOF`. It may submit up to 64
independent claims that are still live in its local mempool. The limit matches
the bounded per-block proof-evaluation set; it does not promise that any claim
will be included or credited.

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

For compatibility with existing mining supervisors, `getpowmininginfo` keeps
`quarantined_claims` as the count that blocks claim creation. The complete
audit count is reported separately as `raw_quarantined_claims`; resolved
active-chain history can make that raw count nonzero without pausing PoW.

The built-in miner pauses while a quarantined component is actionable or cannot
be classified safely. It does not consume another fee input merely because a
different input is available. When all blocking components resolve, a miner
that was already enabled may resume. Recovery never enables mining itself.

## Zero-payment retirement for origin-bound claims

The normal v30.1.4 lifecycle for a newly wallet-authored QQP3 or QQP4 claim does
not create a conflicting recovery transaction. While the claim is eligible on
the active branch, the wallet retains the exact transaction and reserves its
input even after the one-hour mempool residence limit removes it from local
relay. Startup, import, periodic resend, and reorg retry do not grant an
over-age claim a new local relay lifetime.

After the authenticated origin plus the inclusive 64-block late window has
expired on one pinned active branch, Core may durably mark the exact locally
authored, single-input claim component retired on that branch. This transition
creates, signs, and broadcasts no transaction, pays no recovery fee, and
releases the local reservation. The marker records the observation height and
block hash. A reorg that removes that observation reopens and reclassifies the
claim before the input can be reused inconsistently.

This path is deliberately narrow. QQP2, adopted or foreign history, a future
origin or version, malformed or mixed graphs, ordinary descendants, active
mempool claims, and indeterminate local state remain reserved. Fee-paying
conflict recovery is an optional, default-off last resort for those separately
reviewed components; it is not the ordinary PoW liveness loop.

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

Resolving such a QQP2 component is a deliberate on-chain conflict, not an
abandonment of a dead transaction. It is available only through an exact manual
plan with explicit fee-and-conflict acknowledgement, or through the wallet's
explicit bounded automatic standing policy after the configured stale-depth,
rate, and fee gates pass. Either the unchanged QQP2 claim or the conflicting
resolution may confirm. Generic transient or indeterminate conditions, local
state errors, future-origin proofs, and future-version proofs remain fail-closed
and cannot authorize recovery.

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

Once the wallet has explicitly committed exact resolution bytes for a component
that cannot use zero-payment retirement, safe retries
may continue across restart without creating a new spend. Disabling automatic
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

The wallet releases no reservation merely because a claim left the mempool or
exceeded one hour of relay residence. It releases only after an active-chain
confirmation resolves the conflict or after the narrow, branch-scoped
origin-expiry retirement above. If the controlling block is disconnected, the
wallet reopens and reclassifies the component on the new pinned tip and restores
any required quarantine. A transaction already seen by peers cannot be
withdrawn.

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
