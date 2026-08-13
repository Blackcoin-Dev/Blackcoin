# v30.1.5 candidate: node 27 two-phase canary

This directory contains a candidate-only, two-phase node 27 transaction for a
post-v30.1.4 correction candidate for v30.1.5. It is not an alteration of the
immutable v30.1.4 release or final canary.

The current tooling bytes are deliberately not pinned to a Core candidate.
`__FINAL_SIGNED_CORE_SHA__` and `__FINAL_EXACT_SHA_CORE_CI_RUN_ID__` are
invalid sentinels, so production identity preflight fails closed until a later
reviewed identity-only repin replaces both with one Blackcoin-Dev-signed source
and its successful exact-SHA Core safety run. The exact PR base
`19baffef25af36e177db2975780e0641b59753aa` and unchanged
`.github/workflows/pr-gate.yml` SHA-256
`24c14f2fe4bd7b25de38e71a80bf05efcec00d2b3009c3efd4ad20b90bbda869`
remain pinned. Phase A and the offline verifier require the repinned run to be
`completed` with conclusion `success`; queued, in-progress, failed,
superseded-run, wrong-base, or wrong-workflow evidence fails closed.

The exact-SHA Core run will qualify Core only. It is not the later candidate
packaging run. The signed adapter tooling/workflow commit, candidate workflow
run and attempt, bundle, OCI graph, image ID, provenance, and six-binary ledger
also remain unresolved. Their placeholders fail Phase A, Phase B, and
evidence-verifier preflight. The release input is accepted only when it is
exactly `30.1.5`.

The naming and metadata predicates match the current reviewed v30.1.5 adapter
profile: `Blackcoin-30.1.5-candidate-<source12>`, GitHub artifact
`v30.1.5-candidate-linux-x86_64-<source40>-attempt-<attempt>`, OCI archive
`blackcoin-v4-gui-30.1.5-candidate-<source12>.oci.tar`, and local image tag
`30.1.5-candidate-<source12>-ci1`. The adapter worktree is not itself authority:
its final signed tooling commit and sealed package identity remain unresolved
and must be supplied by the later repin.

The immutable base remains pinned to:

- source `13262151077cce3f72d07d17dc7725b2b6a8e1ab`;
- manifest `sha256:7a384dd5f12c15fb41b36868d946007524bebf97650883d533635658641e04a2`;
- image/config ID `sha256:620146d14a57fe0d5d1fc29a7d913d47787ba924c96ba06eeb1ddbe8efb73909`.

The immutable final-canary script and manifest are byte-pinned and unchanged.
No file here builds, pulls, loads, publishes, tags, or releases an image.

## Why the canary is split

`-walletbroadcast=0` prevents wallet-transaction relay. It does not prevent a
PoS worker from signing, accepting, persisting, and announcing a coinstake
block. Rewinding wallet and chain datasets after active PoS could therefore
erase local signing/spend records while peers retain the block.

The safety boundary is consequently irreversible:

1. Phase A disables PoS and every automatic wallet-signing feature, suppresses
   wallet relay, proves a coherent no-spend typed PoW path, and is the only phase
   that may restore a pre-candidate dataset image.
2. Phase B is a separately confirmed promotion. Before candidate launch it
   durably records `PROMOTED_NO_REWIND`. It takes no snapshot. It preserves all
   live datasets. Failure can only stop and contain the candidate.

Phase A never invokes Phase B.

## Exact nine-file package

1. `node27-v30.1.4-hotfix-candidate.no-recovery-spend.sh` — Phase A only.
2. `node27-v30.1.4-hotfix-candidate.promote-no-data-rewind.sh` — Phase B only.
3. `candidate.env.example`.
4. `lib/typed_contract.sh`.
5. `verify-evidence.sh`.
6. `tests/run.sh`.
7. `README.md`.
8. `VALIDATION.txt`.
9. `SHA256SUMS`.

The six exact environment, contract, phase, test, and verifier payloads are
frozen for this identity-neutral preseal. The SHA-256 of their ordered
`sha256sum` list, in manifest order with the two narrative files omitted, is
`48bb93d2daa00f059fb2ec0db110d55c3a74b37d2d38cda78b891128f6f3f7f8`.
`SHA256SUMS` mechanically binds those six payloads together with the final
`README.md` and `VALIDATION.txt` bytes.

A completed preseal review additionally requires strict manifest verification,
exact package topology and static checks, a local full sealed 528-assertion
hostile replay with all nine package-file hashes unchanged, and an independent
post-seal review recorded outside this package. This narrative intentionally
does not attest or predict an external review result and does not embed a
volatile replay path.

A valid checksum seal proves identity-neutral offline tooling integrity only;
it does not prove Core correctness or grant execution authority. Recording the
final source/run and adapter/bundle identities remains a separate reviewed
repin and seal. Live preflight treats `SHA256SUMS` as the ninth required regular
file and rejects a mismatch, extra or non-regular objects, symlinks, unsafe
ownership or modes, and multiply linked files.

The test suite retains signed commit
`309731e3340f380e48cb67f94a243725465420fb` only as an immutable diagnostic
source oracle for the typed RPC/API shape exercised by the offline fixtures.
That commit is a revoked, failed predecessor. It is not substituted into the
production identity sentinels and supplies no Core, packaging, seal, canary, or
rollout authority.

## Unlock-helper audit

The external node helper was inspected read-only and was not executed during
the audit. Its exact SHA-256 is
`acf28446e842fd0fa92b06c2ebc182e9da38fcde7bac06dd920d50a33e4e3dd1`.
It is a regular root-owned `0600` file, and `bash -n` passes. Its only mutating
RPC is a normal (not staking-only) `walletpassphrase` unlock. Its remaining RPCs
are read-only `listwallets`, `getwalletinfo`, and `getstakinginfo` checks. It
does not call staking, PoW, transaction relay, recovery, address/key, payout,
or broadcast RPCs. Evidence records only this sanitized classification and
file identity; it never records the helper body or wallet passphrase.

Phase A rechecks the same bytes, metadata, syntax, method allowlist, and
non-staking unlock argument immediately before use. Failure has no embedded
secret fallback.

## Sealed wrapper

Directly replacing the image entrypoint is not behaviorally equivalent. Both
phases use an exec-form `/bin/bash -c` wrapper that reproduces the immutable
`start-gui.sh` setup exactly: `DISPLAY=:0`, Xvfb, fluxbox, loopback x11vnc, and
websockify. The only startup-body change is the final command:

```text
exec /usr/local/bin/blackcoin-qt -datadir=/home/blackcoin/.blackcoin "$@"
```

The exact body includes one terminal LF and is pinned to
`753acc9904b48c411f5514abface930f79d72d00c9d73e91435a6511877d47b4`.
The fixed `$0` sentinel is `node27-hotfix-candidate`. Each create is stopped
before inspection. After every start or restart, evidence binds image, user,
workdir, entrypoint, command, mounts, network namespace, `/proc/1/exe`, its
hash, and the NUL-delimited runtime argv. Phase A then synchronously stops and
joins the x11vnc and websockify interaction services before the first wallet
unlock, and repeats that shutdown and proof after the intentional candidate
restart. Xvfb, fluxbox, and Core remain available to the sealed runtime; no
interactive VNC or web surface remains during the signing proof.

## Phase A: reversible proof

Phase A uses exactly these process flags, in this order:

```text
-walletbroadcast=0
-blocksonly=1
-staking=0
-autostartstaking=0
-powmining=0
-qqautoshadowsignal=0
-qqautodemurrageattest=0
```

It then normally unlocks the wallet and explicitly starts only
`setpowmining true 1 1 false`. `-staking=0` remains the process-hard staking
gate across RPC, GUI, and post-init paths. `-blocksonly=1` preserves
block/header/tip progress but does not make RPC-submitted transactions safe;
the transaction therefore separately proves all of the following throughout
candidate execution:

- `localrelay=false` and every peer has `relaytxes=false` with no
  `relay`/`forcerelay` permission;
- RPC is loopback-only and unpublished to the host. The shared VPN namespace
  can reach the loopback TCP listener, so evidence must additionally prove an
  unauthenticated request is rejected and that no RPC cookie, configuration,
  wallet secret, authentication environment value, sensitive mount, or Docker
  control surface is available to any namespace peer;
- walletnotify and ZMQ transaction-export endpoints are absent;
- no unauthorized container shares the VPN namespace;
- the VPN container publishes no RPC, VNC, or websockify port;
- the observed 8080 listener is blocked by the VPN firewall and active probes
  from host-loopback, host-LAN, VPN-ingress, and unauthorized shared-namespace
  paths are inaccessible;
- keeper/API/guard automation is nonce-bound and suspended.

An unavailable or ambiguous surface is not treated as safe.

The evidence must span at least three distinct advancing tips, advancing
chainwork, no IBD, current wallet processing, complete identity-bound typed
gate telemetry, a coherent and unambiguous database view, zero unsafe
claims/components, and continuously disabled PoS. Nonzero unresolved,
quarantined, blocking, raw, retired, or resolved history is telemetry, not a
health veto. Legacy PoW unresolved/live/quarantine counters and recovery
blocking/actionable/indeterminate counts are independently type-checked
telemetry; no arithmetic relationship among them is a health predicate, and
legacy inventory counters are not required to agree across the two RPC views.
Candidate recovery-operation same-cut relationships remain structural
coherence checks, and candidate counters are never required to equal immutable
v30.1.4 counters. Mining-gate family/live counters are aggregate authority
telemetry and are not required to equal the claim/live counts in the one
Core-selected component authenticated by an observation. A
`create_new_anchor` report nevertheless has no authoritative unresolved
component or family. The compatibility `.components` count is not required to
equal the length of the full audit `component_details` inventory. The full
inventory must nevertheless be a partition: one node txid cannot appear in two
components.

The product contract permits all five safe typed actions. A bounded
`wait_for_live`, `relay_existing`, or `wait_for_next_tip` path may legitimately
create no wallet transaction. Phase-A progress schema 5 therefore accepts any
sealed series of at least three advancing observations; each per-sample envelope
and the repeated terminal stable-cut receipt use schema 4. The claim proof accepts
zero or more exact newly authored claim subsets. Each nonempty subset is mapped once to a complete
authenticated component, is a contiguous suffix of that component's canonical
lineage, and carries its own authenticated anchor. Preexisting family members
remain part of the complete component proof but are not falsely treated as
claims created or required to remain unpublished by this canary. An empty
candidate set maps to no component or anchor; vacuous component selection is
rejected.

The package classifies every new wallet row as an authenticated wallet-authored
claim, an authenticated synthetic claim payout, a confirmed coinstake, or an
external receive proven to have no wallet debit. An unconfirmed receive that is
present in recovery telemetry must match exactly one audit-only foreign
component; a confirmed receive is bound to its active-chain block. These rows
remain outside candidate-authored lineage, anchor, nonpublication, and progress
evidence.

The tooling never chooses a family, action, or relay target for Core. It binds
Core's reported lineage head to one unambiguous authenticated component and,
when a relay txid is present, proves that exact txid is an eligible, absent,
unexpired member of that selected component. It deliberately does not
recompute a highest-ordinal relay choice: per-tx suppression may make another
eligible member the correct reselection. Global action priority, the
all-safe-families-live condition, and per-tx suppression are signed-Core
product semantics; the host does not reconstruct or override them after Core
reports a coherent, nonambiguous, zero-unsafe typed gate. Exact selected-family
persisted payout/target remains an RPC observability limitation supplied by
signed-Core evidence, not inferred from the process-local payout field.
The legacy `payout_address` field is configured-future payout, not the selected
family's persisted payout: it may be empty for retained wait/relay/refresh
work, and is required nonempty only for `create_new_anchor`.

Each repeated Phase-A terminal cut independently passes the full typed
observation validator, including selected-component authentication and exact
raw-mempool binding. Cross-cut equality then binds only the chain/wallet cut,
recovery-policy authority, and Core's operational mining-gate projection:
enabled/action/submission authority, authoritative unsafe counts, selected
lineage head/relay, aggregate family/live/eligible/unresolved counts, and
inventory-tip coherence. Full audit component details, unanchored and retained
history, compatibility counters, and candidate-state fingerprint are not
cross-cut health predicates.

### Bounded worker liveness

Every Phase-A envelope and Phase-B progress sample includes a verbose raw
mempool snapshot from the same stable cut as the typed PoW gate and recovery
inventory. Each operational cut also carries the exact six-field
`getgoldrushstate` projection for QQP4 activation. The receipt is bound to the
same tip and height; its activation-disabled/height schedule is invariant
across Phase-A progress and terminal cuts and Phase-B baseline, progress, and
final cuts. A selected QQP2 or QQP3 `unsupported_version` member is accepted
only when that cut reports `qqp4_active_next_block=true`; QQP4 never receives
that legacy exception. Generic retained history without an operational receipt
is not reinterpreted. The common validator binds the chain tip and height across those
objects and permits at most one advancing-tip transition while an enabled PoW
worker lacks an action-appropriate progress witness. The bound applies to all
five typed actions: `create_new_anchor`, `refresh_same_anchor`, `wait_for_live`,
`wait_for_next_tip`, and `relay_existing`.

Only these observations reset the bound:

- positive hashrate under a submit-capable create or refresh action;
- an increase in Core's `claims_submitted` counter;
- an exact append-only lineage extension to a previously observed authenticated
  family under its stable anchor-outpoint/root identity; or
- growth of the exact authoritative live-txid set for that authenticated
  component.

A live/wait/relay action may report transient positive hashrate. Because those
actions are not submit-capable, that diagnostic alone is never credited as
progress and cannot reset the series budget.

The component generation fingerprint must remain stable for one
anchor-outpoint/root identity. A lineage at the same ordinal must be
byte-for-byte the same txid sequence; an extension must contain the prior
sequence as an exact prefix. Every live txid is recorded when first observed,
including the first sample and samples whose progress came from another
witness, so a later mempool replay cannot become progress. A genuinely new
live member may count once after the prior member is absent. Multiple
authenticated live members are each raw-mempool-bound, but cardinality alone is
not a host-side health veto: the package relies on Core's coherent,
database-unambiguous, zero-authoritative-unsafe gate. Switching to another
authenticated family, or returning to a previously selected family, is neither
failure nor progress; continuity is checked against the latest prior
observation of that same family.

For `wait_for_live`, every selected-component recovery member marked live must
have an exact entry in the captured verbose mempool, with entry time no later
than the observation and entry height no later than the current height. No
absolute mempool age or block-age cutoff substitutes for the separate series
progress budget. For `relay_existing`, the exact Core-selected relay txid must
resolve to an eligible, not-in-mempool member of the selected component whose
relay TTL is unexpired and whose expiry is later than the observation. A
nonzero `wait_for_next_tip` relay txid has the same membership proof. Both
actions may coexist with aggregate live claims in other clean wallet-owned
families. `wait_for_next_tip` remains bound to the sampled current tip and to
the same series-level budget. With a zero relay txid it may be either a
submit-capable cached override or a non-submit fresh deferral.

An implicit metadata-absent QQP2/3/4 ordinal-zero root remains an explicitly
authored wallet claim. Its serialized lineage family, root, and parent remain
the all-zero defaults; Core derives the canonical root from the node txid.
QQP2, QQP3, and QQP4 require their exact false/false, true/false, and true/true
origin/input binding tuples, respectively. The root also binds authored and
carrier metadata, the exact Core disposition set, the disposition/revalidation
relation, and proof-evaluation status. A singleton QQP2 root additionally binds
the active-branch-authored tip and a safe disposition. The absence of lineage
metadata does not permit a legacy-wallet-authored, adopted, unknown, or forged
descriptor.

An action change, relay-txid change, candidate-state-fingerprint change,
generation-fingerprint churn, or live/relay replay is not progress. Alternating
otherwise safe actions therefore cannot reset the bound. One no-progress tip
transition remains permitted so legitimate short waits and an unchanged
candidate-state fingerprint across fresh tips are accepted; a second such
transition fails closed.

Authenticated lineaged origin-bound claims are deliberately retained on their
confirmed anchor. Their normal lifecycle is exact-byte relay or an
authenticated `refresh_same_anchor` continuation, without a recovery
transaction, distinct UTXO, or recovery fee. Zero-payment retirement remains a
legacy/non-lineaged-record behavior and is not an expected outcome for the
family exercised by this canary.

Phase A rejects every new wallet transaction other than the exact claim
transactions authenticated by its action-specific proof. It also proves
unchanged payout/key inventory, no coinstake, no cleanup/resolution/recovery
transaction, no unrelated spend, no payout rotation, and no abandonment.
Every newly authored txid is bound to its component anchor and remains absent
from the local raw mempool, both observer mempools, and the active chain. No
wallet outpoint may be added; any removed outpoint must be one of those exact
authenticated authored anchors. An existing-family refresh may remove no new
outpoint because its anchor was already reserved before the canary.
Existing wallet txids and abandonment authority must be preserved, but
candidate-native `listtransactions` metadata may be reclassified. Recovery
counters and fee-exposure aggregates may age; actual transaction identities,
raw wallet classification, and the RPC journal prove that the canary created no
fee-bearing recovery action.

The terminal order is fixed:

1. complete the tip proof;
2. synchronously stop and join PoW;
3. capture a stable, complete wallet/claim/mempool/observer/no-fee terminal
   cut, restarting only that cut if the tip or wallet generation changes;
4. lock the wallet;
5. cleanly stop the candidate;
6. capture and hash the complete candidate logs through clean stop;
7. seal and verify the stopped-candidate evidence offline;
8. issue, fsync, re-read, and independently revalidate the positive
   nonce-bound `REWIND_SAFE` certificate.

Snapshot existence is never authority. Generic error/signal traps contain and
preserve state; they never perform a data operation or start old Core.

After a certified restore, immutable v30.1.4 first starts with the same hard
quarantine flags and a locked wallet. Normal baseline policy remains disabled
until chainwork is at least the recorded Phase-A terminal chainwork, the old
terminal tip is active or is superseded by demonstrably greater work,
blocks equal headers, IBD is false, and wallet processing is current. Only then
are the four holds released and the four exact snapshots destroyed, child
before parent, with their absence proven. Baseline invocation, normal unlock,
PoS, and prior PoW policy are restored only after that proof.

Phase A exits with a sealed result and cannot launch Phase B.

## Phase B: irreversible promotion

Phase B requires a new exact confirmation containing the SHA-256 of the
verified Phase-A `RESULT.json`. It re-verifies the complete Phase-A evidence
and the absence proof. It publishes an external root-only
`PROMOTED_NO_REWIND` marker with a no-clobber same-filesystem operation, fsyncs
the file and parent directory, and rereads and rehashes the marker before
candidate launch.

Its fixed startup flags are:

```text
-walletbroadcast=1
-autostartstaking=0
-powmining=0
```

The candidate starts locked with both workers off. Phase B synchronizes chain
and wallet processing, normally unlocks, explicitly enables PoS, and explicitly
enables regular PoW for node 27 even when immutable v30.1.4 reported PoW off.
The enable RPC is intent, not liveness evidence; success additionally requires
active-only typed PoW progress and final evidence. Success leaves the exact candidate running and keeps
the durable marker and maintenance/guard authority in place pending the
separately reviewed rollout-consumer integration.

Any failure after Phase B begins mutating state or publishes
`PROMOTED_NO_REWIND` stops PoW and PoS where possible, locks the wallet,
disables automatic restart, stops the candidate, and preserves the four live
datasets, marker, reservations, and evidence. A pre-mutation validation failure
exits without changing or stopping the immutable baseline. No failure path
starts old Core or changes live dataset history.

Phase B also seals the raw evidence used to classify every new wallet
transaction. The offline verifier independently recomputes the four permitted
classes—an authenticated Gold Rush claim, a confirmed coinstake, an
authenticated synthetic claim payout, or an external no-debit receive—and
cross-binds that raw file through the wallet delta, final envelope, and result.
Unknown, conflicting, wallet-debiting, or insufficiently authenticated wallet
activity contains the candidate.

Phase B proves Core-native configured intent. It launches with automatic
staking and PoW enabled, observes both intents retained while the wallet is
locked with zero work, invokes only the normal wallet-unlock helper, and then
requires active PoS plus active hashing/submission or a coherent bounded safe
PoW wait. It forbids repair `staking true` and `setpowmining true` RPCs.

## Offline verifier

The verifier has three explicit modes:

```bash
./verify-evidence.sh phase-a-pre-rewind /path/to/phase-a/evidence
./verify-evidence.sh phase-a-final /path/to/phase-a/evidence
./verify-evidence.sh phase-b-final /path/to/phase-b/evidence
```

The first mode is the mandatory stopped-candidate gate before certificate
issuance. The final modes require exact file-set seals and cross-bind every
result, marker, invocation, source/image identity, and phase transition.

## Execution remains frozen

This offline package does not itself grant build, Docker, wallet, network,
fleet, registry, release, GitHub, or canary authority. Do not run either phase
until the exact Blackcoin-Dev-signed v30.1.5 source commit is final, mandatory
Core CI is green for that exact SHA, the exact candidate artifact identities
exist, an independent review accepts the regenerated package seal, and
separate node27 mutation clearance is recorded.

The existing fleet rollout consumer does not accept this new two-phase result
schema. Updating that consumer is intentionally out of scope and requires a
separate reviewed patch before any fleet rollout.

After the canary, a separate v30.1.5 identity-bound durability lane must prove
the native configured restart contract: `autostartstaking=1`, `powmining=1`,
one PoW thread, and one-percent CPU. A controlled restart must retain both
workers while the encrypted wallet is locked; a normal wallet unlock alone,
without a repair `staking true` or `setpowmining true` RPC, must resume legacy
PoS and either active hashing/submission or a coherent safe-wait Gold Rush
state. No recovery, cleanup, resolution transaction, or recovery-fee counter
may be created; aggregate counters may change only when raw transaction and
resolution identity proves no new durability-lane action. The rollout
consumer, its live predicates, the runtime guard, and
the transaction tests, documentation, validation, and seal require separate
path-level clearance for that lane.

The proposed zero-overlap boundary for separate review is a new, independently
sealed `contrib/ops/v30.1.5-rollout-durability/` package. It must consume the
exact Phase-B result and package seal, adopt node 27 without recreating it or
rewinding data, use unique v30.1.5 authority/lock/state names, and must not
source either the v30.1.4 rollout libraries or this canary's Phase-specific
typed contract.
