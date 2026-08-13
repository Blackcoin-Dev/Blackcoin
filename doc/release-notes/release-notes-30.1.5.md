# Blackcoin Core 30.1.5

Blackcoin Core v30.1.5 is a corrective wallet, staking, mining-policy, GUI,
telemetry, and test-fixture release. It supersedes immutable v30.1.4 only after
the exact Blackcoin-Dev-signed source commit and tag pass the release gate and
the corresponding artifacts are published. Until that publication occurs,
v30.1.4 remains the latest public release.

Wallet safety is tightened for origin-expired Gold Rush claims. Expiry of the
claim-specific mempool and reward window does not make already signed
transaction bytes invalid for direct block inclusion. The wallet therefore
keeps the confirmed anchor reserved until chain state or an explicit recovery
spend resolves it. Historical local retirement markers written by earlier
v30.1.5 release candidates are reopened and cleared without releasing the
anchor during migration or a failed database update.

The source commit and annotated tag are SSH-signed by Blackcoin-Dev. That
source identity does not Authenticode-sign Windows packages. macOS applications
retain identity-free ad-hoc launch signatures and are not notarized.

This release does not change consensus, reward amounts, competing-claim
reimbursement, Gold Rush eligibility, the quantum lifecycle, block or
transaction serialization, or wallet ownership.

## Gold Rush PoW claim continuation

The built-in miner now treats each strictly authenticated wallet-authored claim
family as one same-anchor lifecycle. Within one family, a live member blocks a
competing sibling. Across multiple safe families, the wallet first relays any
exact eligible absent carrier, then refreshes one family that has no live or
relayable member, and waits only when no independent relay or refresh work
remains. A refreshed sibling spends that family's confirmed anchor, preserves
its legacy target and quantum payout, and records durable family, root, parent,
and ordinal metadata. It does not select a second independent fee coin for
that continuation. Because same-family siblings conflict, at most one can
confirm and charge its ordinary claim fee. Waiting, relaying, or refreshing a
retained family uses its authenticated payout and does not allocate the
configured future-new-anchor payout key; `getpowmininginfo.payout_address` may
therefore be empty or different during that work. A caller that explicitly
grants one-call key-creation consent may proactively bind or create that future
payout so any non-HD-key backup warning is returned synchronously.

A locally persisted claim that has not entered the local mempool remains a
durably reserved family member instead of collapsing the typed mining gate
into an indeterminate permanent stop. A foreign incoming proof remains visible
as audit history but cannot pause a recipient wallet unless the component also
contains wallet-authored, from-me, adopted, or otherwise wallet-relevant claim
state. Malformed, mixed, forked, wallet-relevant foreign, or database-ambiguous
families still fail closed. Explicit fee-paying conflict recovery remains a
separate, default-off operator authority and is not invoked by the normal
same-anchor miner path.

`getpowmininginfo` exposes the coherent typed mining-gate snapshot used by the
worker. Supervisors must evaluate that typed state; raw unresolved or
quarantined object counts remain audit history and are not cross-version
health predicates. A safe wait or relay action can truthfully report zero
instantaneous hashrate.

## Atomic wallet authority for PoW workers

Wallet spend authority is generation-scoped inside Core. A manual lock, timed
relock, or staking-only scope transition synchronously reports
`wallet_locked_or_staking_only` and zero hashrate before returning. Sleeping
and active workers observe the generation change, discard stale proof work,
and recheck the same normal authority immediately before entering claim
submission.

GUI and RPC unlock paths apply the requested scope atomically with successful
passphrase verification. A staking-only unlock never briefly grants normal
transaction or Gold Rush claim-signing authority. A failed RPC credential
attempt to expand a staking-only wallet leaves its active scope and miner state
unchanged. A cancelled generic GUI normal-unlock prompt grants no normal
authority, leaves the wallet locked, and restores the staking-only preference
for its next unlock. A later successful normal unlock resumes the configured
worker group without duplicating workers or rotating the configured non-HD
quantum payout key.

With multiple workers, late state or hashrate updates cannot overwrite a
locked, disabled, or runtime-error terminal state. The cancellation guarantee
ends when `SubmitShadowPowClaim` enters its persistence and commit path; Core
does not claim to erase a durable wallet record or recall a transaction after
that boundary.

## GUI and operator transparency

Generic wallet-unlock prompts explicitly request temporary normal signing
authority. Staking-only controls remain explicit. A retained staking-only
preference while the encrypted wallet is locked is not displayed as an active
unlock. Scope-revocation paths lock first and fail closed if the wallet state
changes concurrently.

The GUI's **Review claim recovery...** flow, `blackcoin-cli` and other RPC
clients, and `blackcoind` all use the same active-tip-pinned Core recovery
inventory, plan identifier, fee calculation, and final revalidation. Manual
recovery signing or commit requires the exact reviewed plan plus explicit fee
and conflict-risk acknowledgement. Automatic fee-paying recovery remains off
by default and requires an explicit maximum fee per resolution, aggregate batch
fee cap, rolling fee budget, rolling fee/action window, maximum actions per
window, and minimum stale-block depth before the wallet records standing
authority.

The headless manual path enforces both exact consent steps. A mutating
`createshadowpowclaimresolution` call requires the `expected_plan_id` from its
prior dry-run preview. Its successful signing response includes a fresh
`current_plan` keyed to the exact persisted resolution txid. A side-effect-free
`commitshadowpowclaimresolution <resolution_txid>` preview is also available
after restart; only a later call with acknowledgement and that exact plan ID
may grant relay authority. A successful `sendshadowpowclaim` relay of retained
exact bytes returns a typed success response instead of reporting an error
after the relay side effect.

Configured, cached, and labeled automatic quantum payout bindings share one
validation rule: the address must be wallet-owned, durably stored, and an
ordinary direct quantum destination rather than a tiered or cold-stake alias.
For legacy label migration, current labels take precedence over older labels;
multiple different direct addresses at the same highest precedence fail
closed as ambiguous.

GUI mining and recovery prompts distinguish the normal authenticated
same-anchor path from optional fee-paying conflict recovery. A coherent safe
family waits while a member is live, relays an eligible absent member, or is
continued on its confirmed anchor without a recovery transaction; the
fee-paying option is shown separately and requires an exact recoverable plan.
That optional authority may apply even when the miner could continue an
authenticated `unbound_proof_may_revalidate` family, so the prompts disclose
the alternative and its conflict risk rather than presenting it as required
for mining. Persistent PoW consent also states that a locked or staking-only
wallet retains the configured worker at zero hashrate until a normal unlock
rather than silently discarding the operator's request.

## Validation and upgrade boundary

The v30.1.5 candidate includes focused unit and functional coverage for
same-anchor continuation, persisted-but-unrelayed claims, normal and
staking-only unlock, manual and timed relock, active-work cancellation,
multi-worker terminal telemetry, restart, reorg, reindex, and independent
competing-claim fixtures. Exact pinned-v30.1.4 coverage also opens one wallet
and datadir in the sequence v30.1.4, candidate, v30.1.4, candidate after the
candidate has written QQP2-to-QQP3 family metadata. The old daemon preserves
the unknown metadata through a normal wallet write, and the second candidate
open reconstructs the same authenticated family and anchor. A concurrent
two-version test sends candidate-authored same-anchor bytes through v30.1.4's
P2P admission path, includes them in a v30.1.4 PoS block, restarts both
versions, and checks removal and later reinclusion across a competing-branch
reorganization. Release publication still requires the exact-SHA repository
gate, reproducible candidate packaging, and a data-preserving canary before
fleet rollout.

Back up each wallet and take a cold datadir copy before replacing binaries.
Stop the existing process cleanly. Do not run two versions against one datadir.
An exact-active-tip authenticated schema-12 datadir produced by v30.1.4 does
not require an automatic rewind or reindex merely because the client version
changes. Any rollback must follow the reviewed canary or release procedure and
preserve wallet and chain state created after the upgrade. This tested rollback
boundary is data-compatible, not feature-equivalent: v30.1.4 does not
interpret the candidate's typed same-anchor family policy and may again report
`claim_quarantined` with zero PoW hashrate for a family the candidate can safely
relay or continue. Rollback therefore must not be represented as preserving
the candidate's regular-PoW liveness behavior.
