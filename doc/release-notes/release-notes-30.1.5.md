# Blackcoin Core 30.1.5

Blackcoin Core v30.1.5 is a corrective wallet, staking, mining-policy, GUI,
telemetry, and test-fixture release. It supersedes immutable v30.1.4 only after
the exact Blackcoin-Dev-signed source commit and tag pass the release gate and
the corresponding artifacts are published. Until that publication occurs,
v30.1.4 remains the latest public release.

The source commit and annotated tag are SSH-signed by Blackcoin-Dev. That
source identity does not Authenticode-sign Windows packages. macOS applications
retain identity-free ad-hoc launch signatures and are not notarized.

This release does not change consensus, reward amounts, competing-claim
reimbursement, Gold Rush eligibility, the quantum lifecycle, block or
transaction serialization, or wallet ownership.

## Gold Rush PoW claim continuation

The built-in miner now treats a strictly authenticated wallet-authored claim
family as one same-anchor lifecycle. It relays an exact eligible carrier when
possible and otherwise may append one current-policy sibling that spends the
same confirmed anchor, preserves the legacy target and quantum payout, and
records durable family, root, parent, and ordinal metadata. It does not select
a second independent fee coin for that continuation. Because the siblings
conflict, at most one can confirm and charge its ordinary claim fee.

A locally persisted claim that has not entered the local mempool remains a
durably reserved family member instead of collapsing the typed mining gate
into an indeterminate permanent stop. Malformed, mixed, foreign, forked, or
database-ambiguous families still fail closed. Explicit fee-paying conflict
recovery remains a separate, default-off operator authority and is not invoked
by the normal same-anchor miner path.

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

## Validation and upgrade boundary

The v30.1.5 candidate includes focused unit and functional coverage for
same-anchor continuation, persisted-but-unrelayed claims, normal and
staking-only unlock, manual and timed relock, active-work cancellation,
multi-worker terminal telemetry, restart, reorg, reindex, and independent
competing-claim fixtures. Release publication still requires the exact-SHA
repository gate, reproducible candidate packaging, and a data-preserving
canary before fleet rollout.

Back up each wallet and take a cold datadir copy before replacing binaries.
Stop the existing process cleanly. Do not run two versions against one datadir.
An exact-active-tip authenticated schema-12 datadir produced by v30.1.4 does
not require an automatic rewind or reindex merely because the client version
changes. Any rollback must follow the reviewed canary or release procedure and
preserve wallet and chain state created after the upgrade.
