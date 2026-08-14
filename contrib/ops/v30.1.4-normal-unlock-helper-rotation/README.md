# Installed-v30.1.4 normal-unlock helper rotation

This fleet-owned package rotates only the installed normal-unlock helper and
the exact active consumers that pin it. The currently observed active PoW
quarantine cycle is supported by one exact helper-hash substitution; if an
exact predecessor PoS-renewal supervisor exists, its already-sealed transform
is also supported. The package does not deploy Core or container bytes, change
ordinary-PoW policy, resolve claims, create or relay a transaction, spend a
fee, alter chain data, or modify either historical artifact.

The package is an offline artifact. No live audit or installation was performed
while producing it. `audit` is filesystem-only. `install` contacts the live
installed v30.1.4 fleet and normally unlocks each wallet for PoS, so it must not
run until a separate live authorization has been issued and encoded in the
run-local owner-only authority.

## Exact identities

- Package source parent: `af73ef239641639ca087639869c5a1c145aec6b6`.
- Installed helper predecessor: `acf28446e842fd0fa92b06c2ebc182e9da38fcde7bac06dd920d50a33e4e3dd1`.
- Corrected helper successor: `aa924baf0a9d384759019d50e3815e03e264b906c7b51ecc76023c854b91a3e7`.
- Active supervisor predecessor: `112ffbaa2702f9e4a9568948ef383cd22ae70876376c29602629e4c3d15d7341`.
- Active supervisor successor: `b879bb3833bc5786aa34918741550119cde4ddf71ca00f06b73cfe1863aaa8c0`.
- Active PoW-cycle path: `/boot/config/plugins/blackcoin-quantum-nodes/blackcoin_pow_quarantine_cycle.sh`.
- Active PoW-cycle predecessor: `1dbb72bd0e400806a8b1cdf9337cd28672f9242c5d18feb65dd6c64ce27b6f1c`.
- Active PoW-cycle successor: `9936417a89bc34ae9dbe7a22346ed0dd78d79fcee401a10481e6b5ccdcb54b67`.
- Immutable disabled PoW-cycle path: `/boot/config/plugins/blackcoin-quantum-nodes/blackcoin_pow_quarantine_cycle.v30.1.3-fee-capable.disabled`.
- Immutable disabled PoW-cycle identity: `156acca0ed86fbeba008d9f87eb862aa2f93fc32f57ed2995d7dc05dcdb7312d`.
- Failed historical job-10 receipt path: `/mnt/disk1/blackcoin-wallet-safety/runtime-audits/emergency-pos-renewal-20260814T034100Z.log`.
- Failed historical job-10 receipt identity: `23030a65f9b182534d82f6d67709b9cd088cbe6907bae56647d9780f9b9cf3cb`.
- Install path: `/boot/config/plugins/blackcoin-quantum-nodes/blackcoin_node_normal_unlock.sh`.

The supervisor change is not a broad string replacement. Three exact semantic
anchors transform the full predecessor identity into the full signed successor
identity. The successor gives the active helper the new hash while retaining
the old helper hash solely as the immutable historical job-10 contract identity.
Any other helper or supervisor identity, any unknown old/new pin reference, or
any changed transformation anchor blocks installation.

The active PoW-cycle transform is narrower: the exact predecessor must contain
the predecessor helper hash once and the successor hash zero times. Replacing
that one occurrence must produce the exact full successor identity. Both
identities must be root:root mode `0600`, single-linked regular files. The
cycle's behavior and ordinary-PoW policy are not edited. The shared PoW-cycle
lock prevents its once-per-minute cron consumer from observing mixed helper/pin
bytes.

The disabled v30.1.3 fee-capable cycle remains root:root mode `0600`, one link,
and byte-identical at its exact identity. It is recorded in
`immutable_historical_refs`, excluded from mutation order and backups, and
reverified after apply, before the terminal receipt, and after rollback. The
completed job10 evidence remains separately immutable.

The completed historical job-10 log is also a required immutable input. The
last read-only receipt records successful helper renewal for nodes `1..29,31,32`,
a node30 helper failure, and terminal helper-wave failure; node30 was renewed
separately under its supplement receipt. The queue entry is no longer active.
This package binds the exact log path, SHA256, root:root mode `0600`, one-link
identity, and protected-root ancestry. It never creates, edits, moves, or
deletes that log and does not recreate job 10.

The latest read-only live receipt says the supervisor install root and the
top-level supervisor/job10 objects are absent. The transform support for an
exact predecessor supervisor is a fail-closed audit rule, not permission to
invent or install an absent consumer.

The corrected helper accepts canonical node numbers `1` through `32`, including
node30. It omits `-rpcwallet` for the unnamed wallet and preserves one exact
`-rpcwallet=<name>` argv element for a named wallet. The passphrase remains
stdin-only. The helper's only wallet mutations are normal wallet unlock and PoS
enablement.

## Transaction contract

The transaction acquires the established rollout, endpoint, cutover, PoW-cycle,
wallet-runtime, and helper-rotation locks, followed by all 32 node-runtime
locks. Under those locks it re-audits the exact authorized plan, writes and
hash-seals predecessor backups, transforms each exact active consumer in
sorted path order, and atomically replaces the helper. For the current live
shape, the mutation order is the active PoW-cycle followed by the helper. The
immutable disabled cycle is never a backup or write target. The transaction
then releases node locks so the helper can obtain each node's own runtime lock.

Node30 is the first canary. Its unnamed-wallet path must converge to normal
unlock and active PoS while ordinary PoW remains disabled. Only then does the
transaction process nodes `1..29,31,32`. A final coherent verification cut is
taken under all 32 runtime locks in ascending order. Every node must be healthy,
on main, out of IBD, fully header-synced, peered, running exact v30.1.4, loaded
with its one manifested wallet, normally unlocked for more than 12 hours, and
actively staking with positive weight. Regular-node PoW policy and node30's
ordinary-PoW-disabled role must match the preflight projection.

On failure, later helper calls stop. All transaction-owned file changes are
restored from the exact predecessor backups under the node locks and a failure
receipt records every attempted node and rollback result. For the current live
shape, rollback restores both the active cycle predecessor and helper
predecessor, then proves the disabled artifact is still byte-identical. A
wallet already normally unlocked before a later-node failure is deliberately not relocked:
wallet relocking would be a separate live mutation and would reduce PoS
availability. The receipt makes that partial helper-attempt prefix explicit.

## Owner-only live handoff

First install or copy this exact sealed directory to a root-owned, non-writable
location on the fleet host. Verify its package inventory before use:

```sh
cd /root/blackcoin-v30.1.4-normal-unlock-helper-rotation
sha256sum --strict -c SHA256SUMS
python3 helper_rotation.py --help
```

Choose a fresh run name directly beneath the fixed audit root and perform the
read-only filesystem audit:

```sh
install -d -m 700 -o root -g root \
  /mnt/disk1/blackcoin-wallet-safety/runtime-audits/normal-unlock-helper-rotation
python3 helper_rotation.py audit \
  --run-dir /mnt/disk1/blackcoin-wallet-safety/runtime-audits/normal-unlock-helper-rotation/<fresh-run>
```

Do not reuse the prior failed run
`20260814T050000Z-aa924baf`. Its blocked `PLAN.json` SHA256 is
`61db70b30d36af745222d7f2ee4b1772550fa18f3c3910bd6b19ebfb36faf5af` and
its `AUDIT.json` SHA256 is
`6be13d99625e321ec42a43fb1c8e8ffad85d302c3c02f2c306835a22d0ee6b2c`.
Those immutable receipts establish why the earlier package could not proceed;
they are not install authority for this successor package.

The audit creates immutable `PLAN.json`, `AUDIT.json`, and
`AUTHORITY.template.json` objects with `.sha256` sidecars. It makes no Docker,
RPC, wallet, or network call. Continue only when `PLAN.json.state` is `READY`,
every active consumer is understood, every historical job-10 reference is
classified immutable, every disabled historical reference is exact, and
`unsupported_refs` is empty. Given the last observed filesystem state, a fresh
plan must bind all of the following or remain blocked:

- helper identity `acf28446e842fd0fa92b06c2ebc182e9da38fcde7bac06dd920d50a33e4e3dd1`;
- exactly one active consumer, the active PoW-cycle, with before identity
  `1dbb72bd0e400806a8b1cdf9337cd28672f9242c5d18feb65dd6c64ce27b6f1c`,
  after identity
  `9936417a89bc34ae9dbe7a22346ed0dd78d79fcee401a10481e6b5ccdcb54b67`,
  one replacement occurrence, and replacement kind
  `exact-single-helper-pin-substitution`;
- exactly one immutable historical reference, the disabled v30.1.3 cycle at
  identity `156acca0ed86fbeba008d9f87eb862aa2f93fc32f57ed2995d7dc05dcdb7312d`;
- exactly one historical job-10 reference, the completed failed log at identity
  `23030a65f9b182534d82f6d67709b9cd088cbe6907bae56647d9780f9b9cf3cb`;
- mutation order `[active PoW-cycle, normal-unlock helper]`; and
- no supervisor consumer, no unsupported reference, and state `READY`.

The audit accepts the exact existing Unraid storage boundary without changing
it: `/mnt/disk1` and `/mnt/disk1/blackcoin-wallet-safety` must both be
uid `99`, gid `100`, mode `0777`. The protected
`/mnt/disk1/blackcoin-wallet-safety/runtime-audits` directory and every
descendant through the run directory must be root:root mode `0700`. Symlinks,
different identities/modes, noncanonical paths, or a run outside that protected
subtree fail closed. These exact records are embedded in `PLAN.json`, bound by
the authority's plan hash, and rechecked at install and receipt verification.
Do not chmod or chown the Unraid disk/share prefix.

After a separate explicit live authorization, copy the exact template to the
same run directory as `AUTHORITY.json`. Fill every required field without
adding or removing a key. Set a nonzero 32-hex nonce, bind the exact external
authorization receipt in `authorization_context_sha256`, use a current validity
window no longer than one hour, set `state` to `authorized`, and set all five
authorization booleans to `true`. Preserve mode `0600`, root ownership, and
create `AUTHORITY.json.sha256` containing the exact file SHA256. The runtime
validator—not the JSON Schema alone—is authoritative.

Only then may the live transaction be invoked:

```sh
python3 helper_rotation.py install \
  --run-dir /mnt/disk1/blackcoin-wallet-safety/runtime-audits/normal-unlock-helper-rotation/<fresh-run> \
  --authority /mnt/disk1/blackcoin-wallet-safety/runtime-audits/normal-unlock-helper-rotation/<fresh-run>/AUTHORITY.json
python3 helper_rotation.py verify \
  --run-dir /mnt/disk1/blackcoin-wallet-safety/runtime-audits/normal-unlock-helper-rotation/<fresh-run>
```

The authority is consumed exactly once in `AUTHORITY-CONSUMED.json`. A success
has identical, hash-sealed `RESULT.json` and `TERMINAL.json` objects. A failure
has a hash-sealed `FAILURE.json`. `BACKUP-MANIFEST.json` binds the preserved
predecessor bytes. A consumed or terminal run cannot be reused.

## Separate persistence recommendation

After this transaction reaches `PASS`, persistent renewal should be installed
as an initial coherent activation from the already signed `af73ef2` durability
package, not as a rotation of a nonexistent installed set. Its package manifest
is `0c102acb2208279256c9b6137fb1bc0003eefd748b4fc336f576bf5753f591de`;
its supervisor is `b879bb3833bc5786aa34918741550119cde4ddf71ca00f06b73cfe1863aaa8c0`;
its immutable job10 contract is
`f5c47596731c0f56729d02d06a6d15c33adf0ac719f0ebca1f758caadd79ac0c`;
and its topology map is
`20598574496f82490073ca836c6bedcb98a229cd263698dc7b38896dae1cd260`.

That package's own `pos_unlock_renewal_supervisor.sh install` transaction must
receive a separate fresh owner authority with generation `1`, an all-zero
superseded-authority identity, the exact corrected helper identity, and enough
validity runway for one complete cycle. Its installer then creates the
supervisor, source manifest, authority pair, install receipt, job10 contract,
topology, and cron activation as one coherent initial set. It must follow—not
precede—the helper transaction because its preflight requires the corrected
helper already installed. This package does not create that authority or run
that separate activation.

## Validation

Run the source-hostile suite with:

```sh
python3 tests/run.py
```

The frozen validation result is recorded in `VALIDATION.txt`. The test suite is
offline and uses only temporary filesystem and fake-runtime fixtures.
