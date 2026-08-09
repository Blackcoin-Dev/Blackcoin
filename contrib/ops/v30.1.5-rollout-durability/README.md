# Blackcoin v30.1.5 rollout and native restart durability

This directory is a new, self-contained consumer for the signed v30.1.5 Core
source. It does not alter the immutable v30.1.4 rollout transaction and does not
source any v30.1.4 operations library. It is currently **offline-only and
nondeployable**.

The signed source identity and provisional exact-SHA CI run are pinned, but
the release remains fail-closed:

- source commit: `a0695f22740e111d0487a194fb46f1bae05952c5`
- source tree: `86df040ae5eb8e819e940dd08364bcc177a72195`
- signer fingerprint: `SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70`
- network version: `300105`
- subversion: `/Blackcoin:30.1.5/`
- exact-SHA CI run: `31336502539`, attempt 1, `pull_request`, base
  `19baffef25af36e177db2975780e0641b59753aa`, head-matched and still
  `in_progress` with no successful conclusion recorded

`rollout.env.example` deliberately contains an unresolved successful-CI
conclusion plus unresolved bundle, OCI,
binary, tooling, completed-Phase-B, package-seal, Compose, image-policy,
post-reconcile proof, handoff-receipt, guard, node30 probe, and
execution-authority values. Any one unresolved value prevents preflight.
The candidate image must use the canonical immutable
`qqblackcoin/blackcoin-v4-gui@sha256:...` reference; the historical
`hotfix-candidate` naming convention is not rollout authority.
`SHA256SUMS` seals the exact fourteen non-manifest files in this provisionally
source/CI-bound package. That byte seal is package-integrity evidence only; it
is not rollout authority. Recording a successful R conclusion and later
bundle/OCI/Phase-B/handoff identities is a separate change and must regenerate
both `VALIDATION.txt` and `SHA256SUMS`.

## Acceptance contract

The final fleet result is one contract with two distinct roles:

- Nodes 1–29 and 31–32: legacy PoS active/searching with positive weight and
  regular Gold Rush PoW operational under the v30.1.5 typed-gate definition.
- Node 30: legacy PoS active, regular PoW disabled, and the separately protected
  Free Claim service healthy and unpaused.

Regular PoW does not require all 31 wallets to show positive hashrate in one
sample. `create_new_anchor` and `refresh_same_anchor` require `can_submit=true`.
Every sampled interval touching either action must contain positive hashrate at
an endpoint or a strict `claims_submitted` increase; one earlier positive
sample cannot satisfy a later idle interval.
`wait_for_live`, `wait_for_next_tip`, and `relay_existing` may report
`claim_in_flight` and zero hashrate only when the complete typed schema is
present, the gate is coherent, both ambiguity flags are false, unsafe
claim/component counts are zero, and authenticated lineage/relay fields are
consistent with the action. Four samples must span at least three strictly
advancing tips. An unchanged `wait_for_next_tip` fingerprint across a tip
change fails liveness.

The inventory-derived typed gate remains authoritative. This package never
compares unresolved or quarantine counts with v30.1.4 and never treats positive
hashrate alone as safety evidence.

## Native restart proof

For each regular-PoW node, `native_restart_durability.sh`:

1. verifies the signed source, successful exact-SHA CI, sealed artifact/image
   and all six runtime binary identities, completed no-rewind Phase B, package seal, Compose
   hash, and normal-unlock helper hash;
2. recreates the service with the immutable v30.1.5 image and exact Core-native
   settings `-walletbroadcast=1`, `-autostartstaking=1`, `-powmining=1`, `-powminingthreads=1`, and
   `-powminingcpu=1`;
3. establishes candidate operation with the pinned normal-unlock-only helper;
4. performs a controlled restart;
5. proves the restarted process is locked, retains both worker intents, shows
   zero locked-wallet hashrate and `claims_submitted=0`, and has not been
   repaired by an enable RPC;
6. invokes only the same normal-unlock helper, then proves PoS and action-aware
   PoW liveness across at least three tip changes; and
7. proves complete before/after transaction inventories, exact added/removed
   txids, exact recovery schema/policy/metrics/resolution inventories, and one
   allowed class per new transaction; authenticated claims must retain an
   unspent authenticated anchor plus origin/input-bound lineage whose
   family/root/parent/ordinal relationships independently match the typed
   component; recovery summary counters must exactly match typed node and
   component details; and
8. fails closed on any unclassified or abandoned wallet transaction, new
   key/address, payout change, database ambiguity, cleanup/resolution activity,
   recovery fee/counter change, stale wallet-generation/tip state, or
   incomplete transaction inventory.

There is no wallet, chain, or dataset rewind path. A post-launch failure invokes
containment only: automatic restart is disabled, the affected candidate
container is stopped, and all live data is preserved. The tooling never starts
old Core automatically and never constructs a claim-resolution transaction.

Authenticated lineaged origin-bound claims remain reserved on their confirmed
anchor and use exact relay or `refresh_same_anchor`. This package does not
retire those claims, select another UTXO, or pay a recovery fee. Zero-payment
retirement is relevant only to the separate legacy/non-lineaged record path.

## Node 30

Node30 is never included in a regular-PoW wave. Its Compose overlay pins
`-powmining=0`. Final rollout remains blocked until a separately reviewed,
root-owned `0700`, single-linked, non-symlink read-only Free Claim probe with
non-writable ancestry is identity-pinned. Under fleet locks, the probe is
copied into the root-owned run directory, fsynced, rehashed, and executed only
from those pinned bytes. The probe must emit
the exact JSON contract accepted by `v3015_node30_result_is_valid`: node30,
signed source identity, normal wallet unlock, active legacy PoS, regular PoW
disabled, `healthy=true`, `paused=false`, and zero recovery activity/fee.
It must also bind the candidate recreation and controlled restart, prove locked
PoS intent and disabled regular-PoW intent before the normal unlock, preserve
Free Claim intent, and report four healthy samples over at least three tips.
The probe must not unpause, unlock, broadcast, or mutate the service. Its tool
hash is distinct from each output hash and is bound through release identity,
rollout authority, node30 result, terminal census, and fleet result. A second
fresh terminal probe must again span at least three advancing tips. Every Core
chain/network/wallet/PoS/PoW surface is resampled after that terminal probe so
an intervening lock, staking-only unlock, sync/peer loss, PoS loss, or Free
Claim pause fails acceptance.
The rollout itself—not the probe—verifies node30's immutable image, all six
executables, PID 1, argument vector, network identity, locked PoS intent, and
disabled regular-PoW intent before the normal unlock. The probe owns only the
separately protected Free Claim service truth and multi-tip observations.

## Runtime guard and transaction boundary

`guard_rollout_maintenance_block.sh.inc` defines a v30.1.5-only maintenance
marker. `install_runtime_guard_3015_compat.sh render` produces review bytes from
an exact audited guard. `apply` requires a separately hashed reviewed render and
nonce-bound authority. The fleet transaction creates the maintenance marker
before any candidate service mutation. On success it removes the marker only
after the complete evidence set verifies. On failure it leaves the marker and
contained live data for investigation.

The current scaffold does not publish the persistent Compose/image-policy
handoff. It instead requires two exact, hashed receipts plus an exact hashed
post-Compose candidate-identity proof. Those objects bind source/image role
mapping, pre/post Compose and image-policy paths and hashes, both rendered
guards, semantic 300105 acceptance, atomic installation, parent-directory
durability, and the post-reconcile runtime identity. Bare review booleans are
ignored and cannot authorize rollout. All receipt/proof paths and hashes remain
unresolved in the template, so every preflight remains fail-closed until a
separate reviewed integration transaction creates those exact bytes.

The ZFS run authority uses a same-filesystem hard link as its atomic
no-clobber commit point. The maintenance marker lives on the reviewed VFAT
`/boot` filesystem, where hard links are unavailable, so it instead uses GNU
`mv -nT` from a same-directory temporary file and requires that temporary name
to disappear. Both paths fsync the file and parent directory and reread the
exact bytes. A preexisting or racing marker and a partial durability failure
cannot be overwritten or treated as authority. Removal requires the originally
recorded bytes and also fsyncs the parent directory.

No script in this package installs a recurring host keeper, restarts a failed
miner in a loop, rotates VPN identity, creates an address/key, or pays a
recovery fee.

## Evidence

The final evidence directory is flat, root-owned `0700`, with root-owned,
single-linked `0600` files. It contains:

- one release identity and one nonce-bound rollout authority;
- one result for every regular-PoW node;
- separate initial and terminal node30 raw Free Claim probe envelopes, with
  distinct tool/output identities, plus one derived node30 result;
- the exact runtime-policy and persistent-Compose receipts plus the
  post-reconcile identity proof;
- one fresh terminal 32-node census and one fleet result bound to its hash; and
- an exact `SHA256SUMS` inventory.

Each regular result binds its expected filename/node identity, recreated
container, locked restart, normal unlock only, four or more chain samples,
typed PoS/PoW observations, and the raw before/after wallet audit. The terminal
census resamples all 32 nodes and derives the 32/32 PoS and 31/31 regular-PoW
lists and counts. Package-owned result/authority envelopes use exact outer key
sets. `verify-evidence.sh` rejects swaps, duplicates, omissions,
node30 role leakage, missing/extra/nested/linked/tampered evidence, partial
schema, ambiguity, unsafe or stale gates, recovery fees, repair RPCs, false
counts, raw-probe mismatch, or a paused Free Claim service.

## Offline validation

The only currently authorized execution is local and offline:

```bash
bash -n contrib/ops/v30.1.5-rollout-durability/*.sh \
  contrib/ops/v30.1.5-rollout-durability/lib/*.sh
shellcheck -x contrib/ops/v30.1.5-rollout-durability/*.sh \
  contrib/ops/v30.1.5-rollout-durability/lib/*.sh \
  contrib/ops/v30.1.5-rollout-durability/tests/run.sh \
  contrib/ops/v30.1.5-rollout-durability/guard_rollout_maintenance_block.sh.inc
contrib/ops/v30.1.5-rollout-durability/tests/run.sh
```

Do not run `fleet_rollout.sh apply`, `native_restart_durability.sh`, or the
guard installer against a live host until all placeholders are replaced from
one sealed candidate, replacement run `R` is complete and successful for `H`, the
nine-path Phase B result is complete/no-rewind, the node30 probe is reviewed,
the identity-repinned package is independently reviewed and resealed, and
fresh exact collision/live authority is recorded.

## Remaining external dependencies

No Core RPC/schema change is requested by this package. Before live clearance,
the following external facts remain mandatory:

1. successful completion of exact-H Core CI run `31336502539`, or a separately
   reviewed superseding signed H/R pair (superseded checkpoints are not
   authority);
2. sealed Linux x86_64 bundle, OCI, image ID/digest, tooling, and executable
   identities for the signed source;
3. a complete verified Phase-A/Phase-B nine-path canary with Phase B promoted
   and no data rewind;
4. the exact read-only node30 Free Claim health probe contract and bytes;
5. a locked live Compose hash and reviewed v30.1.5-compatible runtime guard;
6. independent review and regeneration of the identity-repinned package seal
   and validation record;
7. exact persistent Compose/image-policy handoff receipts, the separately
   hashed post-reconcile identity proof, and inherited runtime/endpoint guard
   compatibility with 300105; and
8. a fresh nonce-bound execution authority.

Until all eight exist, the package is intentionally non-runnable.

## Replacement-identity repin ledger

Do not repin from an active CI run, an informational checkpoint, or an
unpublished bundle. Once the release task supplies one final reconciled set,
update and review these groups in order:

1. `SOURCE_SHA`, `SOURCE_TREE`, signer fingerprint, signature-verification
   receipt, `CORE_CI_RUN_ID`, CI head, conclusion, and allowed workflow;
2. artifact name/run/attempt, sealed bundle, OCI archive/manifest, immutable
   image ref/config ID, packaging-tooling, manifest, provenance, and all six
   executable hashes;
3. completed Phase-B result and durable promotion-marker paths/hashes, the
   shared Phase-A result, exact nine-path tooling/script/verifier/contract
   identities, and the nine-path canary seal, after both files pass their exact
   no-rewind schemas and cross-bindings;
4. locked live Compose, audited and rendered guard-pair hashes, pinned normal
   unlock helper, reviewed read-only node30 probe, and separately reviewed
   persistent Compose/image-policy/300105 guard handoff receipts and the exact
   post-reconcile identity proof;
5. regenerated `VALIDATION.txt`, then `SHA256SUMS` over the other fourteen
   package files, then the external hash of that manifest; and
6. `ROLLOUT_IDENTITY_RECONCILED=1` and fresh matching live/native/guard
   nonce-bound authorities only after independent collision clearance.

Run the complete offline suite again after each repin. A change in any earlier
group invalidates every later group and requires resealing; no prior candidate
SHA or CI run remains authority.
