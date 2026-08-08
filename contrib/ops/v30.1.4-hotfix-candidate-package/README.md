# v30.1.4 Linux x86_64 hotfix-candidate packaging

This package defines a post-release, canary-only build path for the exact
Blackcoin Core source commit
`8a3a5aa1c01caf57acc694b836398c5acba969d0`. It does not modify or reuse the
immutable v30.1.4 release/tag publication adapters. The Core binaries may
truthfully self-report `v30.1.4`; every artifact name and metadata record calls
the output a post-release hotfix candidate.

## Current authority boundary

The workflow is review-only while it exists only on a branch. It is **not
dispatchable** and must not be invoked, copied into another workflow, assembled
manually, or triggered through `pull_request_target`, `repository_dispatch`, or
another event. A future build requires separate clearance and the reviewed
workflow to be merged to the default branch first. This package contains no
release, tag, registry-push, package-publication, or deployment path.

Pull requests run fixture and static tests only. A separately cleared
`workflow_dispatch` must be initiated by `Blackcoin-Dev` from an exact
Blackcoin-Dev SSH-signed tooling commit and must supply:

- the exact source SHA pinned in `policy.json`;
- a numeric Core CI run ID for the exact pull-request #49 run of
  `.github/workflows/pr-gate.yml`, with event `pull_request`, repository and head
  repository `Blackcoin-Dev/Blackcoin`, head `8a3a5aa1c01c...`, base
  `19baffef25af...`, pinned workflow blob SHA256
  `24c14f2fe4bd7b25de38e71a80bf05efcec00d2b3009c3efd4ad20b90bbda869`, and
  status/conclusion `completed`/`success`; and
- `BUILD_V30_1_4_HOTFIX_CANDIDATE_LINUX_X86_64` as the explicit confirmation.

Both the original workflow actor and the actor triggering the current run
attempt must be `Blackcoin-Dev`. The authorization job and every build and
assembly job enforce both identities independently. Authorization, raw-build,
and final artifact names include the exact `github.run_attempt`, so a partial
rerun cannot consume evidence or binaries from an earlier attempt. The
authorization evidence records both actors.
The workflow records the Core source SHA and the tooling/workflow-definition
SHA separately. Candidate source cannot affect authorization until the tooling
commit has been verified against the pinned Blackcoin-Dev ED25519 fingerprint.

## Build and image contract

Two isolated Ubuntu 22.04 jobs build the same exact source without a shared
depends cache. Their complete raw artifacts must be byte-identical. The binary
archive contains these six executable root entries and no others:

1. `blackcoin-cli`
2. `blackcoin-qt`
3. `blackcoin-tx`
4. `blackcoin-util`
5. `blackcoin-wallet`
6. `blackcoind`

Every binary must be a Linux x86_64 PIE and report the full clean source commit.
The build records the workflow run and attempt, runner, host, compiler,
binutils, make, installed package versions, and a digest over every tracked
`depends` path and its bytes. The inventory comes from sorted
`git ls-files -z -- depends`; ignored and untracked build output is excluded.

The OCI adapter pulls only the immutable v30.1.4 base:

```text
qqblackcoin/blackcoin-v4-gui@sha256:7a384dd5f12c15fb41b36868d946007524bebf97650883d533635658641e04a2
config sha256:620146d14a57fe0d5d1fc29a7d913d47787ba924c96ba06eeb1ddbe8efb73909
```

It performs a `--pull=false --network=none` one-layer build after that exact
digest has been verified locally. It preserves the base user, entrypoint, Cmd,
working directory, exposed ports, and absent image Healthcheck. No-network,
read-only probes cover all six hashes, GUI startup/version through Xvfb, daemon
and CLI versions, and an isolated regtest daemon/CLI RPC round trip. The local
image is converted to an OCI archive; it is never pushed.

## Bundle contract

For source `8a3a5aa1c01c...`, the GitHub Actions artifact is named:

```text
hotfix-candidate-30.1.4-linux-x86_64-8a3a5aa1c01caf57acc694b836398c5acba969d0-attempt-<run_attempt>
```

Its exact file set uses prefix
`Blackcoin-30.1.4-hotfix-candidate-8a3a5aa1c01c` and contains:

- `-Linux-x86_64.tar.gz`
- `-BINARY_SHA256SUMS.txt`
- `-SOURCE_COMMIT.txt`
- `-REPRODUCIBILITY.txt`
- `-UNSIGNED-CANARY.txt`
- `-SOURCE-SIGNATURE.json`
- `-CORE-CI.json`
- `-TOOLCHAIN.txt`
- `-OCI-IDENTITY.json`
- `-MANIFEST.json`
- `-PROVENANCE.intoto.json`
- `-SHA256SUMS.txt`
- `blackcoin-v4-gui-30.1.4-hotfix-candidate-8a3a5aa1c01c.oci.tar`

The manifest has schema `1` and classification
`POST_RELEASE_HOTFIX_CANDIDATE_CANARY_ONLY`. It binds the exact signed source,
immutable v30.1.4 ancestor, successful Core CI run, tooling and workflow SHA,
workflow run/attempt, toolchain evidence, base manifest/config, binary archive,
all six binary hashes, OCI archive/manifest/config, and every evidence file.
Its release object is fixed to `tag: null`, `published: false`,
`registry_pushed: false`, and `canary_only: true`.

The OCI identity has the same classification and records:

- local image reference
  `qqblackcoin/blackcoin-v4-gui:30.1.4-hotfix-candidate-8a3a5aa1c01c-ci1`;
- OCI archive SHA256, OCI manifest digest, candidate config/image digest, and
  the workflow-recorded successful archive-to-daemon round-trip result;
- immutable base reference, manifest digest, and config digest;
- Linux/amd64 runtime fields and the workflow-recorded exact base-rootfs-prefix
  plus one-layer result;
- `published: false` and `registry_pushed: false`; and
- the exact six embedded binary hashes and candidate labels.

Required candidate labels are:

```text
org.blackcoin.release.channel=post-release-hotfix-candidate
org.blackcoin.release.qualification=canary-only-not-release
org.blackcoin.release.tag=none
org.blackcoin.candidate.kind=post-release-hotfix-candidate
org.blackcoin.candidate.published=false
org.blackcoin.candidate.registry-pushed=false
org.blackcoin.deployment.scope=canary-only
org.blackcoin.source.commit=<full source SHA>
org.blackcoin.source.verification=blackcoin-dev-ssh-plus-github-verified
org.opencontainers.image.revision=<full source SHA>
org.opencontainers.image.version=30.1.4-hotfix-candidate-<source12>
org.blackcoin.base.image=<immutable base reference>
org.blackcoin.base.image.id=<immutable base config digest>
org.blackcoin.artifact.sha256=<candidate binary archive hash>
org.blackcoin.sha256sums.sha256=<candidate binary checksum-file hash>
org.blackcoin.package.verification=two-build-reproducible-plus-binary-sha256
org.blackcoin.binary.<binary>.sha256=<exact hash>  # for all six binaries
```

`verify_candidate_bundle.sh` is read-only. It requires the exact file set,
strict checksum coverage, canonical manifest/provenance reconstruction, the
pinned source/base/signature/Core-CI identities, and all internal digest links.
Duplicate JSON keys are rejected in policy and evidence documents; sealed
manifest and provenance bytes must use the generator's sorted, indented,
LF-terminated canonical JSON serialization.
The exact authorized GitHub Actions run remains the external trust boundary:
the standalone bundle is not externally signed or attested, and the offline
verifier does not independently replay the base-prefix or OCI round-trip checks.

## Review validation

The permitted branch-only validation is:

```bash
python3 ci/release/test_hotfix_candidate_metadata.py
bash contrib/ops/v30.1.4-hotfix-candidate-package/tests/run.sh
```

These tests use synthetic binary tar and OCI metadata fixtures. They do not run
Docker, pull an image, access a registry, dispatch a workflow, or publish an
artifact.
