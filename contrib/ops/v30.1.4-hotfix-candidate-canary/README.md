# v30.1.5 candidate: node 27 two-phase canary

This directory contains a candidate-only, two-phase node 27 transaction for a
post-v30.1.4 correction candidate for v30.1.5. It is not an alteration of the
immutable v30.1.4 release or final canary.

The current tooling bytes are deliberately candidate-identity-neutral and
nondeployable. No mutable candidate source, Core-CI run, adapter tooling
commit, artifact run, or image digest is committed. A reviewed environment must inject
`HOTFIX_CANDIDATE_SOURCE_SHA` and `HOTFIX_CANDIDATE_RELEASE_VERSION`; every
derived name and every sealed bundle identity must then agree with those two
values. The release input is accepted only when it is exactly `30.1.5`.
Unresolved placeholders fail Phase A, Phase B, and evidence-verifier preflight.
A later, separate repin must bind the final Blackcoin-Dev-signed source commit,
successful exact-SHA Core CI run, signed adapter tooling/workflow commit, and
sealed candidate artifact identities before either live phase may run.

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
   wallet relay, proves the repaired `PERSISTED_PENDING` PoW-claim path, and is
   the only phase that may restore a pre-candidate dataset image.
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

The current `SHA256SUMS` binds the exact paths and bytes of all eight non-seal
identity-neutral payloads. The frozen offline hostile suite passed 247/247
assertions in 114 seconds with all tested package hashes unchanged. Unresolved
candidate identity inputs remain independently fail closed under that seal, so
it is not execution authority. The later final signed v30.1.5
source/CI/adapter/bundle repin is a separate commit and must regenerate and
revalidate the seal again. Live preflight treats `SHA256SUMS` as the ninth
required regular file and rejects extra or non-regular objects, symlinks,
unsafe ownership or modes, and multiply linked files.

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
gate telemetry, zero unsafe claims/components, and continuously disabled PoS.
It must contain at least one newly authored `PERSISTED_PENDING` QQSPROOF and a
real, contiguous same-anchor/same-family/same-root lineage across the tip
window. Every member must remain quarantined, unconfirmed, non-abandoned,
absent from the local mempool/active chain, and absent from two independent
observer mempools. Any observer failure is unclassifiable and prohibits the
data operation.

Authenticated lineaged origin-bound claims are deliberately retained on their
confirmed anchor. Their normal lifecycle is exact-byte relay or an
authenticated `refresh_same_anchor` continuation, without a recovery
transaction, distinct UTXO, or recovery fee. Zero-payment retirement remains a
legacy/non-lineaged-record behavior and is not an expected outcome for the
family exercised by this canary.

Phase A rejects every new wallet transaction other than that exact claim
family. It also proves unchanged payout/key inventory, no coinstake, no
cleanup/resolution/recovery transaction, no unrelated spend, no payout
rotation, no abandonment, and no recovery-fee/counter/txid change.

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
and wallet processing, normally unlocks, explicitly enables PoS, then restores
the observed PoW policy. Success leaves the exact candidate running and keeps
the durable marker and maintenance/guard authority in place pending the
separately reviewed rollout-consumer integration.

Any failure after Phase B begins mutating state or publishes
`PROMOTED_NO_REWIND` stops PoW and PoS where possible, locks the wallet,
disables automatic restart, stops the candidate, and preserves the four live
datasets, marker, reservations, and evidence. A pre-mutation validation failure
exits without changing or stopping the immutable baseline. No failure path
starts old Core or changes live dataset history.

Phase B also seals the raw evidence used to classify every new wallet
transaction. The offline verifier independently recomputes the only permitted
classes—an authenticated Gold Rush claim, a confirmed coinstake, or an
authenticated synthetic claim payout—and cross-binds that raw file through
the wallet delta, final envelope, and result. Unknown, conflicting, unrelated,
or insufficiently authenticated wallet activity contains the candidate.

Phase B proves an explicitly controlled runtime transition. It does not prove
Core-native restart durability because it intentionally starts with automatic
staking and PoW disabled and then enables the desired workers explicitly.

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
may change. The rollout consumer, its live predicates, the runtime guard, and
the transaction tests, documentation, validation, and seal require separate
path-level clearance for that lane.

The proposed zero-overlap boundary for separate review is a new, independently
sealed `contrib/ops/v30.1.5-rollout-durability/` package. It must consume the
exact Phase-B result and package seal, adopt node 27 without recreating it or
rewinding data, use unique v30.1.5 authority/lock/state names, and must not
source either the v30.1.4 rollout libraries or this canary's Phase-specific
typed contract.
