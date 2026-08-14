# Blackcoin v30.1.5 rollout and native restart durability

This directory is a new, self-contained, identity-neutral offline consumer for
the eventual signed v30.1.5 Core release. It does not alter the immutable
v30.1.4 rollout transaction and does not source any v30.1.4 operations library.
It is currently **offline-only and nondeployable**.

The integration preseal binds the intended H0e62 source, tree, merge lineage,
and expected exact-SHA CI run as constraints. It does not assert that the run
succeeded or that a public artifact exists. The release remains fail-closed
until exact source/run, packaging, artifact, registry, Phase-A/Phase-B, and
handoff receipts are complete:

- source commit: `0e62ec0af3daefba30f87382d9b3cc8b00224e62`
- source tree: `d460eee11b7c8c6d5fffe6935f2e9a5d58e18aac`
- reviewed merge constraint: `e85668ed26ef75d92e234488cbd85e146f6ffd5a`
- ordered merge parents: `19baffef25af36e177db2975780e0641b59753aa`,
  `0e62ec0af3daefba30f87382d9b3cc8b00224e62`
- signer fingerprint: `SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70`
- network version: `300105`
- subversion: `/Blackcoin:30.1.5/`
- expected exact-SHA CI run: `31710198720`, head-bound to the source commit
  above; this package records a pending sentinel and contains no successful
  release-authorizing receipt

`rollout.env.example` deliberately contains an unresolved successful-CI
conclusion plus unresolved bundle, OCI,
binary, tooling, completed-Phase-B, package-seal, Compose, image-policy,
post-reconcile proof, handoff-receipt, guard, node30 probe, and
execution-authority values. Any one unresolved value prevents preflight.
The candidate image must use the canonical immutable
`qqblackcoin/blackcoin-v4-gui@sha256:...` reference; the historical
`hotfix-candidate` naming convention is not rollout authority. The 64-hex digest
suffix of that reference must exactly equal `CANDIDATE_OCI_MANIFEST_SHA256` in
both the reviewed environment and the release-identity document.

`SHA256SUMS` is an offline integration preseal over the exact twenty-two
non-manifest files. It seals tooling and hostile tests, including the PoS
unlock-renewal supervisor, its fleet-owned normal-unlock helper source, and the
audit-only node30 Free-Claim gate. It does
not validate Core product behavior, authorize a successful source/run or
public artifact, execute a canary, authorize a node30 fee/sign/broadcast, or
establish live-fleet acceptance. Any later receipt repin must regenerate
`VALIDATION.txt` and `SHA256SUMS` and repeat hostile review.

`topology.map` is the single sealed translation from logical nodes 1–32 to
Compose service names and container names. It records the preserved baseline's
zero-padded services `node01` through `node09`, unpadded services `node10`
through `node32`, the unsuffixed node1 container `blackcoin-v4-gui`, and
containers `blackcoin-v4-gui-2` through `blackcoin-v4-gui-32`. The renderer,
restart proof, failure containment, node30 path, and terminal census all use
that map. A missing logical node, duplicate node, duplicate service, duplicate
container, malformed row, extra or missing Compose service, or Compose
container mismatch fails before candidate mutation. This checked-in map
reflects the recorded baseline; it is not a fresh live-topology receipt and
does not make the package deployable. Final execution still requires the
reviewed Compose hash, handoff receipt, post-reconcile identity proof, and
nonce authorities.

## Acceptance contract

The final fleet result is one contract with two distinct roles:

- Nodes 1–29 and 31–32: legacy PoS active/searching with positive weight and
  regular Gold Rush PoW operational under the v30.1.5 typed-gate definition.
- Node 30: legacy PoS active, regular PoW disabled, and the separately protected
  Free Claim service healthy but still paused in explicit terminal state
  `pause_preserved_pending_separate_release`.

Regular PoW does not require all 31 wallets to show positive hashrate in one
sample. `create_new_anchor` and `refresh_same_anchor` require `can_submit=true`.
They normally show positive hashrate or a strict `claims_submitted` increase.
Zero-work transitions remain valid intermediate polling, but cannot complete
the rollout without a bounded active-chain or action/family work witness and
cannot remain unwitnessed beyond the ten-minute no-progress window.
`wait_for_live`, `wait_for_next_tip`, and `relay_existing` may report
zero or transiently positive hashrate with any operational worker state (`ready`, `hashing`, or
`claim_in_flight`) only when the complete typed schema is
present, the gate is coherent, both ambiguity flags are false, unsafe
claim/component counts are zero, and authenticated lineage/relay fields are
consistent with the action. Each selected-family zero-hash observation is independently bound
to its tip, lineage head, relay txid, candidate-state fingerprint, sample time,
complete verbose recovery component, ordered claim descriptors, and the same
cut's verbose raw mempool. A selected gate-safe component must be one authenticated,
unspent, unresolved family with no resolution/ordinary nodes, and every counted
claim must have explicit authored provenance and the exact Core-reported carrier
shape. For the selected operational family, Core requires the raw
transaction-graph root set to equal the exact claim set and requires
`descendant_claims=0`; a same-family live count above one is unsafe. Generic
recovery and wallet-delta auditing still accepts internally coherent
nonselected inventory such as four claims, two graph roots, and two graph
descendants. That audit inventory is not liveness authority. Independently, the
ordered typed lineage has exactly one canonical explicit schema root or one
permitted implicit legacy QQP2/QQP3/QQP4 root. Later lineage members must use
valid metadata with one immutable generation/root, contiguous ordinals, and
exact parents.

Each operational sample also captures the signed-Core `getgoldrushstate`
QQP4 schedule projection inside the stable chain bracket. Its height and best
block must equal the sample cut; disabled schedules require height zero and
both active flags false; enabled schedules must derive both active flags
exactly from the invariant activation height. An implicit QQP2 or QQP3
`unsupported_version` disposition is accepted only when that authenticated
receipt says QQP4 is active for the next block. Mainnet's disabled schedule
therefore remains fail-closed while an explicitly scheduled test chain can
exercise Core's post-boundary compatibility rule.

Positive hash observed while Core reports a non-submit wait/relay action is
accepted as bounded convergence telemetry only. It is never credited as
operational progress; only submit-capable create/refresh hash work can reset
the no-progress budget.

`wait_for_live` records the complete authenticated component-wide live set,
binds every member to its exact same-cut verbose mempool entry and entry time
without treating absolute age as a health veto, and deterministically selects
the highest-ordinal live member even when the
lineage head itself is absent. `relay_existing`, and `wait_for_next_tip` with a
nonzero relay txid, must select an exact eligible member of the selected
component that is absent from the raw mempool, under its TTL, and has a future
relay expiry. The tooling does not guess Core's hidden per-tx suppression set
or reselect a family: an older eligible member may be selected after a newer
member was deterministically suppressed. Aggregate live, eligible, and family
counters cover every safe wallet-owned family and therefore need not equal the
selected component's counts. A zero-relay `wait_for_next_tip` instead binds the
absent lineage head; it may coexist with an eligible recovery candidate because
Core's snapshot-bound wallet-facing relay-rejection suppression clears the
relay field before publishing the cached wait action. A selected component
whose anchor is user-locked is accepted only as a fresh non-submit
`wait_for_next_tip` with a zero relay txid; it cannot authorize relay or
refresh. Aggregate live claims may exceed one only across independent safe
families.

Core may also publish one exact familyless `wait_for_next_tip` transition while
fresh new-anchor work is being established: `can_submit=true`, zero authoritative
unresolved/family/live/eligible counts, and null lineage-head and relay txids.
That shape has no selected component to look up, so its freshness payload is
null. Any partial family, nonzero authoritative component count, selected txid,
or attached component evidence fails closed. Repeating this transition does not
itself establish progress.

Across the complete series, every enabled zero-hash action is bounded by a
ten-minute no-progress window, and the full series is limited to 30 minutes.
An unchanged coherent wait is valid intermediate polling, but never a completed
rollout result. Progress means an advancing active-chain tip with strictly
greater fixed-width chainwork and nondecreasing height, current positive
create/refresh hash work,
a strict `claims_submitted` increase, a strict ordered lineage extension after
an authenticated prior observation of the same exact anchor/generation/root,
or the first live observation of a member previously authenticated absent in
that same family. Merely observing family A, B, C, or D for the first time is
selection, not progress. For a previously observed anchor outpoint, the full
anchor object, generation, and canonical root are immutable; the latest prior
observation of that outpoint must be an exact descriptor prefix of an extension,
or exactly equal when the head is unchanged. This remains true across
interleaved families. Head regression, middle rewrites,
generation/root/anchor churn, repeated live txids, action/relay churn, and
alternation among previously seen or newly selected safe states do not reset
the budget. Candidate-state fingerprint changes alone are not progress and
are also not distinct operational cuts because audit-only foreign inventory
contributes to that cache fingerprint.

Consecutive observations with the exact same operational-authority projection
are collapsed before transition-budget accounting. The projection includes the
stable tip/height/chainwork cut, processed wallet tip, the typed gate and
worker work/submission fields, and the complete selected-family freshness
evidence other than host time, candidate-state fingerprint, and unrelated raw
mempool entries. Audit-only wallet-generation/fingerprint churn and legacy or
raw recovery counters are excluded from this projection. This permits several
unchanged five-second polls and unrelated foreign/ordinary mempool changes
without inventing transitions. Any same-tip action, selected family, relay,
work, component, or selected live-set change remains a distinct observation
and receives no progress credit merely for changing. The raw timestamps remain
in evidence: an unchanged series spanning more than ten minutes fails, and the
whole series remains limited to 30 minutes.

The sampler continues beyond its minimum four observations until the complete
contract has a liveness witness, with a ten-minute no-progress deadline and a
30-minute evidence bound; it does not exhaust a raw sample-count cap while a
coherent wait is being polled. Adjacent observations
may share one tip only when height and chainwork are identical, allowing
same-cut authority or work changes to remain visible. A changed tip must have
strictly greater fixed-width chainwork and nondecreasing height, and a compressed sequence of distinct tips may never
revisit an earlier tip. The candidate-state fingerprint must be a valid nonzero
64-hex value and internally match each observation; it is a cache-key
constituent, so neither it nor an action, relay, family, or sample switch is
progress. Fingerprint-only churn is collapsed for the bounded operational
budget, while action/relay/family changes remain visible and non-crediting.

Core does not expose when a gate action first began before the restart. The
package therefore proves bounded, freshly sampled current state from existing
recovery, mempool-time, relay-expiry, and host sample-time evidence. It does
not claim a longer historical action-age guarantee that Core does not report.

The inventory-derived typed gate remains authoritative. This package never
compares unresolved, quarantine, retained-history, pending, confirmed, or
rolling-fee counters with v30.1.4. Nonzero coherent telemetry is not a health
veto. Legacy unresolved/quarantine counter arithmetic is type-checked but is
not used to infer typed-gate safety. The authoritative
`mining_gate_unresolved_components` field is different: `create_new_anchor` and
the exact familyless next-tip transition require it to be zero, while a
selected-family action requires at least one authoritative component. Positive
hashrate alone is never safety evidence.

The RPC `payout_address` field is the process-local configured future-payout
setting, not the persisted payout of a selected retained family, and it may be
empty while Core safely waits, relays, or refreshes retained work. The
migration and candidate-native audits permit it to remain empty or resolve
only to an already-present owned quantum key without key/address inventory
growth. They permit only the known same-address legacy-to-canonical label
normalization and do not present this field as selected-family payout
evidence. The selected action and family come only from the exact Core gate and
authenticated recovery component; the host never reconstructs or overrides
Core's wallet-wide RELAY > REFRESH > WAIT_FOR_NEXT_TIP > WAIT_FOR_LIVE
selection. When the wallet audit classifies a candidate-authored claim that is
confirmed and no longer present in recovery, it decodes the exact persisted
raw carrier and binds its target and payout to every authenticated predecessor's
preserved before-state carrier, including an exact candidate-before v30.1.4
implicit root. Thus payout continuity is proved from wallet-local transaction
evidence rather than from the process-local future-payout setting.

Verbose recovery may retain an audit-only foreign component with either the
default null outpoint or one common nonnull foreign prevout; both carry zero
amount and an empty script because they provide no wallet anchor authority. The
validator requires unauthenticated, unspent-false, user-lock-false state, at
least one claim, and only `unknown`, not-wallet-authored, not-from-me nodes,
including any mixed ordinary siblings. Every such claim is bound to the exact
`unanchored_claim_txids` inventory. It cannot be the selected mining family or
liveness progress. A newly arriving ordinary or claim-shaped external credit is
safe when exact `gettransaction` evidence proves positive receive-only rows, no
wallet fee/debit or control metadata, and (when confirmed) exact active-chain
block membership. Watch-only receive rows are permitted. Recovery may contain
no matching node, or one unique matching audit-only foreign component; any
wallet-relevant or ambiguous match fails closed. An active-chain synthetic Gold
Rush payout is separately bound to `getshadowtransaction`, the exact source
transaction bytes and proof tuple, the active source block, and the payout
amount/address/script. Its source need not have been authored by the recipient
wallet. Both portable locked migration and the candidate-native audit enforce
the external-receive class.

## Native restart proof

For each regular-PoW node, `native_restart_durability.sh`:

1. verifies the signed source, successful exact-SHA CI, sealed artifact/image
   and all six runtime binary identities, completed no-rewind Phase B, package seal, Compose
   hash, and normal-unlock helper hash;
2. resolves the logical node through the sealed topology, proves the merged
   Compose model has exactly the mapped services and containers, and recreates
   that service with the immutable v30.1.5 image and exact Core-native
   settings `-walletbroadcast=1`, `-autostartstaking=1`, `-powmining=1`, `-powminingthreads=1`, and
   `-powminingcpu=1`;
3. proves a portable locked pre-unlock migration guard over wallet name,
   singleton loaded-wallet identity, transaction inventory, keys, and payout,
   without interpreting v30.1.4 recovery classifications; the candidate capture
   uses verbose recovery and permits only the exact safe external-receive
   class described above, then establishes operation with the pinned
   normal-unlock-only helper;
4. performs a controlled restart;
5. bounded-polls recognized transient startup states, then proves the restarted
   process is locked, retains both worker intents, shows
   zero locked-wallet hashrate and `claims_submitted=0`, and has not been
   repaired by an enable RPC;
6. invokes only the same normal-unlock helper, then proves PoS and action-aware
   PoW liveness across at least four stable observations, retaining
   authority/work changes sampled on an identical tip cut; and
7. proves a candidate-native locked-baseline-to-final audit with verbose recovery,
   complete transaction inventories, no removed txids, and one allowed class per new
   transaction. No added transaction may be cleanup, recovery, or resolution;
   a newly reported component resolution/ordinary ID must already belong to the
   locked-baseline wallet inventory. Rolling recovery counters are not
   authority. Authenticated claims must retain authenticated anchor provenance
   plus the exact Core-reported QQP2/QQP3/QQP4
   carrier/binding tuple; one canonical explicit or permitted implicit root;
   and lineage family/root/parent/ordinal relationships that independently
   match the typed component; each candidate recovery cut must remain internally
   coherent with its typed node and component details. A candidate-authored
   claim remains an authenticated class if it later confirms, resolves, or is
   exactly expired-retired; an abandoned row is permitted only for that exact
   expired-retired authenticated node; and
8. fails closed on any unclassified or unauthorized abandoned wallet transaction,
   new key/address inventory, unowned/non-quantum future payout, database ambiguity,
   cleanup/resolution activity,
   a new fee-bearing recovery/resolution transaction record, automatic recovery
   authority, stale wallet-generation/tip state, or
   incomplete transaction inventory.

Before the first Compose mutation, the proof captures one and only one loaded
wallet name. Empty and named wallets (including `default_wallet`) are both
supported. Candidate pre-unlock, locked-restart, every liveness sample, final
wallet audit, and terminal census must all retain that exact name and the exact
singleton `listwallets` result. A missing, additional, or coherently renamed
wallet fails rather than silently switching RPC scope.

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
from those pinned bytes. The probe must implement the challenged schema-2 JSON
contract accepted by `v3015_node30_probe_output_is_valid`. The rollout passes
the exact observation kind, rollout nonce, source SHA, immutable image
reference, image ID, and probe tool SHA. Every probe sample must echo those
identities and carry contiguous sample indices/times, one exact loaded wallet,
and contemporaneous Core before/after snapshots of best hash, blocks, headers,
and IBD state. The Core snapshots must be equal around the service observation
and must match the sample tip/height and PoS heights. After the external probe
returns, the rollout queries `getblockheader` for every reported tip, requires
the returned hash/height and positive confirmations to match, timestamps those
active-chain rechecks, and only then finishes and validates the envelope.
Node30 must report normal wallet unlock, active legacy PoS, regular PoW
disabled, `healthy=true`, `paused=false`, and zero recovery activity/fee.
It must also bind the candidate recreation and controlled restart, prove locked
PoS intent and disabled regular-PoW intent before the normal unlock, preserve
Free Claim intent, and report four or more healthy samples over globally unique
advancing tips.
The probe must not unpause, unlock, broadcast, or mutate the service. Its tool
hash is distinct from each output hash and is bound through release identity,
rollout authority, node30 result, terminal census, and fleet result. A second
fresh terminal probe must again span at least three advancing tips. Every Core
chain/network/wallet/PoS/PoW surface is resampled after that terminal probe so
an intervening lock, staking-only unlock, sync/peer loss, PoS loss, or Free
Claim pause fails acceptance.
Initial and terminal envelopes must share the same source/image/tool/nonce
identity, and terminal sampling must begin only after initial completion.
The rollout itself—not the probe—verifies node30's immutable image, all six
executables, PID 1, argument vector, network identity, locked PoS intent, and
disabled regular-PoW intent before the normal unlock. The probe owns only the
separately protected Free Claim service truth and multi-tip observations.
This repository does not supply that external root-owned probe. Offline
fixtures model its schema-2 output, but live preflight must remain blocked until
reviewed probe bytes implement the exact challenge CLI and contract above.

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

`pos_unlock_renewal_supervisor.sh` is a bounded offline supervisor design for
renewing normal wallet unlock through the corrected, package-local helper
`blackcoin_node_normal_unlock.sh`, SHA256
`aa924baf0a9d384759019d50e3815e03e264b906c7b51ecc76023c854b91a3e7`.
The helper accepts each canonical integer node 1 through 32. Its wallet-RPC
argv builder omits `-rpcwallet` for the unnamed wallet and preserves one exact
selector argument for a nonempty wallet name. The passphrase remains stdin-only.
The supervisor's independent read-only census uses the same selector rule, so
node30's unnamed wallet is observed without emitting the invalid empty selector.
The installed supervisor is a root:root-owned, single-linked mode `0600` object on
the Unraid boot filesystem; both cron and manual operation invoke it through
exact `/bin/bash`, so no executable bit is required. Initial-install resumption
accepts only an empty install root, the exact current supervisor singleton, or
the observed predecessor supervisor SHA256
`d433532d25187f763a67b57f4028a167cb7905b52b2382184ceaf7b27c3ca89d`
as a mode `0600` singleton with no cron. The predecessor singleton is replaced
atomically with the current sealed bytes before any companion object is added.
Every other partial install inventory fails closed without deletion or chmod.
The helper contains no ordinary-PoW, claim-recovery, relay, payment, key, or
address action. It may only perform normal wallet unlock and explicitly retain
PoS intent, followed by read-only wallet/staking convergence checks.
This offline package does not replace the installed helper. A separate live
installation authority must stage these exact signed bytes as root-owned mode
`0600`, prove their SHA256 after the durable rename, and preserve a rollback
copy before the renewal supervisor can accept them.
Its install mode remains disabled without an exact authority receipt. Runtime
requires the durable installation receipt, exact package/tool/topology/image/
manifest identities, one wallet, synchronized main-chain stable census,
peers, active PoS, the intended 31 regular-PoW roles, and node30 ordinary PoW
disabled. It acquires the canonical rollout, endpoint, cutover, PoW, and wallet
locks before its private global/node locks; rechecks authority lifetime before
each helper call; invokes nodes sequentially once per cycle; retries only
read-only census sampling; emits a non-PASS PARTIAL receipt for incomplete
post-observation; and supports explicit authority rotation/deactivation. It
cannot read or write regular-PoW intent, remove the maintenance inhibitor,
touch chain/config/key/transaction data, or reproduce the historical root `at`
job 10. That historical job used predecessor helper SHA256
`acf28446e842fd0fa92b06c2ebc182e9da38fcde7bac06dd920d50a33e4e3dd1`;
its node validator excluded node30 and its empty selector was not valid for the
unnamed wallet. `job-10-one-shot-contract.json` preserves those predecessor
bytes only as a historical audit contract. This corrected package makes no
installation or execution claim and does not rewrite the failed predecessor
receipt.

`node30_free_claim_release.sh` is audit-capable but release-ineligible. Audit
requires no fee/spend authority and binds a fresh stable tip, wallet, queue,
candidate legacy fee observation, payout script, public-artifact/package,
fleet, and pause-preserved finalization cut. The reviewed public QQP2/QQP3 RPC
cannot bind an exact fee input or maximum total fee, and no reviewed atomic
one-shot dispatcher/re-pause receipt exists. Therefore the contract accepts no
fee/sign/broadcast receipt, exports no pause-marker transition primitive, and
terminates every release request fail-closed after comparing the prior audit
with a fresh under-lock resample. Node30 ordinary PoW remains disabled.

No package script rotates VPN identity, creates an address/key, performs a
recovery transaction, pays a recovery fee, reindexes/rewinds chain data, or
enables node30 ordinary PoW.

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
container, locked restart, normal unlock only, four or more stable
same-cut/tip-aware chain samples,
typed PoS/PoW observations, and the raw before/after wallet audit. The terminal
census resamples all 32 nodes and derives the 32/32 PoS and 31/31 regular-PoW
lists and counts. Package-owned result/authority envelopes use exact outer key
sets. `verify-evidence.sh` rejects swaps, duplicates, omissions,
node30 role leakage, missing/extra/nested/linked/tampered evidence, partial
schema, ambiguity, unsafe or stale gates, recovery fees, repair RPCs, false
counts, raw-probe mismatch, or a premature Free Claim unpause.

## Offline validation

The only currently authorized execution is local and offline:

```bash
bash -n contrib/ops/v30.1.5-rollout-durability/*.sh \
  contrib/ops/v30.1.5-rollout-durability/lib/*.sh \
  contrib/ops/v30.1.5-rollout-durability/tests/*.sh \
  contrib/ops/v30.1.5-rollout-durability/*.sh.inc
shellcheck -x contrib/ops/v30.1.5-rollout-durability/*.sh \
  contrib/ops/v30.1.5-rollout-durability/lib/*.sh \
  contrib/ops/v30.1.5-rollout-durability/tests/*.sh \
  contrib/ops/v30.1.5-rollout-durability/guard_rollout_maintenance_block.sh.inc
contrib/ops/v30.1.5-rollout-durability/tests/run.sh
contrib/ops/v30.1.5-fleet-semantic-integration-tests.sh
```

The final command is a commit-level integration runner. It executes this
package's aggregate suite—including the dedicated PoS-renewal and node30
release-gate suites—and then the separately sealed installed-v30.1.4 node27
sign-only/observation suite. It does not make either deployment payload depend
on the other at runtime.

Do not run `fleet_rollout.sh apply`, `native_restart_durability.sh`, or the
guard installer against a live host until all placeholders are replaced from
one sealed candidate, replacement run `R` is complete and successful for `H`, the
nine-path Phase B result is complete/no-rewind, the node30 probe is reviewed,
the identity-repinned package is independently reviewed and resealed, and
fresh exact collision/live authority is recorded.

## Remaining external dependencies

This package does not substitute host selection or filtering for Core behavior.
Before live clearance, the following external facts remain mandatory:

1. a successful exact-SHA CI receipt for H0e62 and expected run 31710198720,
   with its exact head, workflow, attempt, and successful conclusion recorded;
2. sealed Linux x86_64 bundle, OCI, image ID/digest, tooling, and executable
   identities for the signed source;
3. a complete verified Phase-A/Phase-B nine-path canary with Phase B promoted,
   no data rewind, and the exact relaxed candidate-native semantic authority;
   obsolete cross-version pending/fee/counter equality fields are rejected;
4. root-owned probe bytes that implement the exact challenged node30 schema-2
   CLI, identity echo, Core before/after sampling, and read-only service checks;
5. a locked live Compose hash and reviewed v30.1.5-compatible runtime guard;
6. independent review and regeneration of the identity-repinned package seal
   and validation record;
7. exact persistent Compose/image-policy handoff receipts, the separately
   hashed post-reconcile identity proof, and inherited runtime/endpoint guard
   compatibility with 300105; and
8. a fresh nonce-bound execution authority.

Until all eight exist, the package is intentionally non-runnable.

Node30 public release remains independently hard-disabled until reviewed Core
or one-shot worker semantics can enforce the exact input, total-fee cap,
single dispatch, terminal queue/payout evidence, and atomic re-pause. The
installed-v30.1.4 node27 canary likewise permits audit/sign-only only: its
targeted commit RPC cannot atomically consume the externally reviewed
plan/tip/wallet/component/raw-byte tuple, so node27 relay and final acceptance
remain nondeployable.

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
5. regenerated `VALIDATION.txt`, then `SHA256SUMS` over the other twenty-two
   package files, then the external hash of that manifest; and
6. `ROLLOUT_IDENTITY_RECONCILED=1` and fresh matching live/native/guard
   nonce-bound authorities only after independent collision clearance.

Run the complete offline suite again after each repin. A change in any earlier
group invalidates every later group and requires resealing; no prior candidate
SHA or CI run remains authority.
