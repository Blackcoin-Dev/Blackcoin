# Blackcoin Core 30.1.4

Blackcoin Core v30.1.4 is a wallet-safety and observability maintenance
release. It does not change consensus, rewards, Gold Rush eligibility, quantum
lifecycle rules, or wallet ownership.

## Gold Rush PoW claim lifecycle

New wallet-authored QQP3/QQP4 claim carriers are removed from the local
mempool after one hour. Their inputs remain reserved while the proof can still
be valid on the active branch. Once the authenticated origin-plus-64 window has
expired, Core can retire the exact local reservation without constructing,
signing, or broadcasting a second transaction and without paying a recovery
fee. A reorganization that removes the retirement observation reopens the
reservation.

Fee-paying conflict recovery remains available only as an explicit,
default-off fallback for components that cannot safely use zero-payment
retirement. Preview, persistence, and broadcast authority remain separate and
all execution paths revalidate the exact plan.

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
