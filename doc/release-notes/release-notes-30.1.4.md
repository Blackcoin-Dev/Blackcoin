# Blackcoin Core 30.1.4

Blackcoin Core v30.1.4 is a wallet-safety and observability maintenance
release. It does not change consensus, rewards, Gold Rush eligibility, quantum
lifecycle rules, or wallet ownership.

> **Post-release addendum:** the same-anchor continuation, typed mining gate,
> and locked-wallet PoW worker resumption described in the marked subsection
> below are a post-release v30.1.4 hotfix candidate. They are not part of the
> immutable `v30.1.4` tag.

## Development-fund retirement and quantum replacement

The legacy development-fund address and coinstake payment path are removed.
`-donatetodevfund` is compatibility-only, nonzero values are ignored with a
warning, and the legacy RPC setter cannot enable a payment.

The separate Quantum Quasar development donation defaults to zero and requires
a fresh choice in each wallet. Consent is durably bound to the active network,
exact direct quantum recipient, and percentage. A recipient rotation disables
the prior choice until the operator explicitly authorizes the new address.
There is no mandatory treasury or consensus tax. Full address, checksum,
startup, RPC, GUI, lifecycle, and fail-closed details are in
`doc/qq-development-donation.md`.

## Gold Rush PoW claim lifecycle

### Post-release v30.1.4 hotfix candidate

The candidate handles exact wallet-authored QQP2/QQP3/QQP4 claim carriers as
follows. Their confirmed fee anchor remains reserved until a member of the
authenticated family confirms or that anchor is otherwise spent. The enabled
built-in miner first relays exact still-eligible bytes. Once that exact relay is no longer
available, the typed gate may author a current-tip, current-policy sibling that
spends the same anchor and preserves the target and quantum payout. The
conflicting siblings cannot both confirm, so this continuation consumes no
second wallet coin and charges at most the one ordinary fee of the member that
confirms.

Each newly authored carrier stores schema, family, root, and ordinal metadata;
every non-root refresh also stores its direct parent. The same-anchor mining
path fails closed on malformed, adopted, mixed, forked, or ambiguous history.
Strict locally authored unbound QQP2 singletons and exact locally authored
origin-bound QQP3/QQP4 carriers are not retired merely because an original
policy window expires. Zero-payment retirement remains narrow and legacy-only.
Separately, fee-paying conflict recovery remains an explicit, default-off path
under the existing exact manual or bounded automatic consent gates, including
for `unbound_proof_may_revalidate`; the built-in miner does not invoke that
authority for authenticated same-anchor continuation.
Preview, persistence, and broadcast authority remain separate and all
execution paths revalidate the exact plan.
Same-anchor siblings remain `QQSPROOF` claims, and the candidate does not
change existing claim reward or reimbursement consensus rules.

`getpowmininginfo.quarantined_claims` retains its immutable-v30.1.4
compatibility meaning. Candidate-aware supervisors use the complete typed gate,
so an authenticated family can relay or refresh with that count nonzero.
`raw_quarantined_claims` separately reports retained audit and reorg history;
neither legacy count authorizes a recovery fee.

The candidate exposes the complete `mining_gate_*` snapshot in
`getpowmininginfo`. Safe actions are `create_new_anchor`, `wait_for_live`,
`wait_for_next_tip`, `relay_existing`, and `refresh_same_anchor`; `unsafe`
fails closed. Without a worker override, `mining_gate_can_submit` is true only
for create/refresh and false for wait-for-live, relay, and unsafe. A next-tip
wait is an optional transient action override, so can-submit retains the fresh
inventory value and may be true or false; true never bypasses the wait.
Supervisors accept the action when present but never require observing it for
liveness. They require coherent tips, no database ambiguity, and zero unsafe
claims/components, but must not require positive instantaneous hashrate or
zero unresolved/quarantined/family counts for a waiting or relay action, and
must not compare those raw counts across the immutable release and candidate.

Disabling the built-in PoW miner now cancels a proof that has been found but
has not yet entered claim submission. The stop operation therefore cannot
create a new fee-paying wallet transaction from that pending proof.

Explicit `-powmining=1` now starts an encrypted wallet's configured worker in a
waiting state during daemon/wallet startup or restart. The same worker resumes after a
normal wallet unlock, using the configured thread and per-core CPU limits and
the configured or previously stored payout key. A staking-only unlock never
authorizes PoW claim signing, and direct interactive start requests remain
strict while locked.

## PoS and PoW coexistence

When staking is enabled, PoW claim input selection protects one mature,
stakeable legacy coin by default. Configure the count with
`-powclaimreservestakecoins`; setting it to zero disables this local protection.
If every otherwise eligible claim coin is protected, Core returns the typed
`stake_reserve_protected` state rather than consuming the last legacy stake
candidate.

`getstakinginfo` now returns a coherent worker snapshot with explicit
`staking_state`, `staking_reason`, `worker_running`, `eligible`, snapshot
sequence, active height, stake weight, cache height, and search interval. A
normal new-tip refresh does not report the worker as stopped solely because an
instantaneous search interval is zero.

## Wallet-scoped QQSIGNAL status

`getgoldrushinfo.wallet_qqsignal` reports only the wallet selected by
`-rpcwallet`. It distinguishes `none`, `mempool`, `confirmed`, `expired`,
`superseded`, and `reorg_removed`; reports transaction, activation, expiration,
confirmation, solve, target, and payout data; and retains per-wallet history.
New signals persist `manual` or `automatic` provenance. Older records without
durable provenance report `unknown`.

## Wallet and CLI reliability

`setqqdevelopmentdonation` now parses its percentage consistently in the CLI
and RPC named-argument paths. Failed legacy-wallet migration also preserves
the original database-creation diagnostic after a successful automatic backup
restore, instead of returning an empty error message. The original wallet and
its migration backup remain intact.

## Upgrade and rollback

A datadir whose exact active tip already has authenticated Quantum Quasar
schema-12 replay state starts normally. v30.1.4 does not force another rewind
or reindex based on the prior 30.x version string. Explicit command-line
`-reindex-chainstate` and `-reindex` remain intentional one-shot operator
actions; persistent true values in configuration remain rejected.

Back up each wallet and take a cold datadir copy before replacing binaries.
Validate one canary first: wallet names, legacy and quantum keys, transaction
history, data paths, chain tip, P2P, PoS, PoW, and a second normal restart. To
roll back, stop v30.1.4 cleanly and restore the complete pre-upgrade datadir
copy before starting the older binary. Never run two versions on one datadir.
