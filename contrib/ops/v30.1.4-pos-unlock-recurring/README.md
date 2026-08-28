# Recurring v30.1.4 PoS unlock

This package is a fleet-only successor to the generation-two PoS unlock
supervisor at source commit `1c24e78327610cc2d8c3c9eec6d0d8b35adfc26d`.
It removes the expiring external execution-authority dependency from routine
PoS liveness. It does not alter public Core or any release design.

The wrapper accepts no arguments and no authority file. Once installed as the
exact root-owned, single-linked mode-`0600` path below, the supplied cron entry
runs it hourly. A nonblocking mutex makes overlapping cron/manual invocations a
durable `SKIPPED_BUSY` no-op. The wrapper takes the same five shared fleet
locks, global renewal lock, and 32 renewal-node locks as the installed
supervisor before it invokes any helper.

The only mutating implementation is the existing installed helper:

- path: `/boot/config/plugins/blackcoin-quantum-nodes/blackcoin_node_normal_unlock.sh`
- SHA256: `aa924baf0a9d384759019d50e3815e03e264b906c7b51ecc76023c854b91a3e7`

The wrapper verifies and snapshots those exact root-owned bytes under the held
locks, then invokes the snapshot once for each canonical integer node 1–32.
The helper retains its exact one-wallet manifest comparison, secret
ownership/mode/shape checks, stdin-only passphrase handling, normal 24-hour
unlock, `staking true`, and active positive-weight convergence proof. The
wrapper contains no transaction, fee, payment, key, ordinary-PoW, chain,
repair, reindex, rewind, or node-role operation. A helper failure does not keep
later nodes from being attempted.

Every invocation writes one concise root-owned mode-`0600` receipt beneath
`/mnt/disk1/blackcoin-wallet-safety/runtime-audits/pos-unlock-recurring`.
Receipts bind the wrapper and helper SHA256 values and the exact attempted,
succeeded, and failed node sets. `PASS` requires all 32 helpers. `PARTIAL`
records incomplete work; the next scheduled invocation is an ordinary new
cycle, not a retry of a financial or one-shot action.

## Installation contract

The signed source package makes no live installation claim. A fleet operator
must independently verify `SHA256SUMS`, create these root-owned directories,
atomically install the exact files, and replace the old supervisor cron only
after an immediate manual `PASS`:

1. Wrapper path:
   `/boot/config/plugins/blackcoin-quantum-nodes/pos-unlock-recurring/pos_unlock_recurring.sh`
   as `root:root`, mode `0600`, one link.
2. Receipt root:
   `/mnt/disk1/blackcoin-wallet-safety/runtime-audits/pos-unlock-recurring`
   as `root:root`, mode `0700`.
3. Cron path: `/etc/cron.d/blackcoin-pos-unlock-recurring` from the exact
   supplied cron bytes, as `root:root`, mode `0600`, one link.

The old expiring authority and its receipts remain immutable historical
evidence. They are not runtime inputs to this successor and need not be
deleted.
