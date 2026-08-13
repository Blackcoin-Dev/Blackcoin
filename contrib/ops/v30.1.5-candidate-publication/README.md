# v30.1.5 OCI publication and immutable handoff

This package closes the boundary between one exact GitHub Actions candidate
artifact and the immutable registry reference consumed by the v30.1.5 canary
and rollout process. It is generic across a final signed source commit `H` and
tree `T`, a successful Core-CI run and attempt, a successful packaging run and
attempt, and a signed publication-tooling snapshot. It is deliberately limited
to `Blackcoin-Dev/Blackcoin`, Docker Hub's `registry-1.docker.io` endpoint, and
the `qqblackcoin/blackcoin-v4-gui` repository.

The checked-in request is disabled. That path performs only local reads and
evidence-directory writes. It does not resolve or invoke Docker, Skopeo, curl,
a registry, Compose, or a node. There is no workflow-dispatch file here.

## One complete publication authority

A schema-3 live request authorizes one canonical object, not a mutable tag or a
partial collection of fields. Its SHA-256 binds all of the following:

- source repository, `H`, `T`, and the reviewed signing fingerprint;
- Core-CI workflow, run ID, run attempt, evidence digest, required-check set,
  and the ThreadSanitizer artifact ID, exact name, API digest, ZIP digest, and
  reports digest;
- packaging tooling commit/tree/package seal, workflow identity, terminal run
  ID and attempt, and terminal run-receipt digest;
- GitHub artifact ID, exact H/attempt name, API-receipt digest, downloaded ZIP
  digest, and the bundle's internal checksum-ledger digest;
- publication-tooling commit/tree and this exact six-file package seal;
- the OCI archive, manifest, config, ordered layer descriptors, ordered rootfs
  diff IDs, and all six executable hashes;
- registry host, credential host, repository, unique tag, and the deliberately
  selected absolute authfile path; and
- exclusive-writer receipt digest, nonce, issue/expiry times, and absolute
  durable nonce-ledger path.

Paths that merely locate already-digested GitHub or workflow-run receipts are
not semantic authority. Their bytes are copied and checked against the bound
digests. Credential and nonce-ledger paths are operational authority and are
therefore bound.

A live request must set `execute`, `dispatch_enabled`, and
`exclusive_tag_writer` to `true`; supply a fresh 32-byte lowercase-hex nonce;
use canonical second-resolution UTC timestamps with a maximum 30-minute
lifetime; and give this exact confirmation:

```text
PUBLISH_V30_1_5_CANDIDATE:<H>:<publication-authority-sha256>:<nonce>
```

Changing any authority field requires a new confirmation. A disabled request
must contain the exact all-false/all-null execution object shown in
`request.example.json`; partial arming is rejected.

The separate exclusive-writer JSON receipt is schema 1 and has exactly these
fields: `schema`, `action`, `repository`, `tag`, `source_commit`,
`packaging_run_id`, `packaging_run_attempt`, `nonce`, `issued_utc`,
`expires_utc`, `exclusive`, and `grantor`. The action is
`exclusive-v30.1.5-candidate-tag-write`, `exclusive` is true, and `grantor` is
`Blackcoin-Dev`. Every identity and time must equal the request.

## Terminal and signed evidence

The saved GitHub packaging-run response is a first-class terminal receipt. It
must prove the exact workflow path/name, `workflow_dispatch` event, run ID,
run attempt, signed packaging head commit/tree, source and head repository,
actor and triggering actor, `completed` status, and `success` conclusion. The
artifact API response must independently identify that same run and packaging
head.

The verifier checks three signed identities locally: source `H/T`, the
packaging-tooling commit/tree, and the publication-tooling commit/tree. The
packaging snapshot must equal the exact checked-in packaging files and seal.
The publication snapshot must equal this directory's exact six-file inventory
and seal. A working-tree replacement of either verifier cannot authorize a
publication.

The GitHub ZIP is capped before it is copied. Extraction rejects traversal,
nested paths, backslashes, case-folded or literal duplicates, links,
nonregular entries, encryption, excessive entry counts, and excessive
expansion. `github_zip_sha256` always means the downloaded ZIP bytes;
`bundle_sha256sums_sha256` always means the internal candidate checksum file.
They are never aliases.

Preparation writes `VERIFIED_INPUT.json` plus sealed source OCI manifest and
config bytes. Immediately before nonce consumption and again before the final
registry result, the verifier re-hashes all copied receipts and the ZIP,
re-extracts the ZIP to a scratch directory, byte-compares that extraction with
the prepared bundle, reruns the canonical candidate verifier, rechecks all
three signed snapshots, reconstructs `VERIFIED_INPUT.json`, and requires exact
equality. The receipt is never trusted as an assertion.

## Durable one-shot execution

Live operation requires root. The original request and exclusive-writer
receipt must be root-owned mode 0600. The selected authfile must be an absolute,
single-linked, root-owned regular file with mode 0600. The script passes that
file explicitly to `skopeo copy --authfile`; it never relies on Docker's
ambient credential context. Before consuming the nonce, the verifier runs
`skopeo login --get-login` against the bound `docker.io` credential host using
that exact authfile. The resulting receipt records only path, ownership, mode,
selected Skopeo metadata, and success of the compatibility probe. It records no
credential bytes, username, token, or authfile digest.

The nonce-ledger parent must be root-owned mode 0700. The ledger is a
single-linked regular file, root-owned mode 0600, capped at 16 MiB, locked
independently, and composed of canonical JSON lines. The verifier rejects a
repeated nonce or authority digest, appends the complete consumption identity,
fsyncs the ledger and parent, and then durably creates
`NONCE_CONSUMPTION.json`. A crash after append but before receipt creation burns
the nonce and requires a new authority; it cannot replay the old one.

Nonce consumption occurs under the global publication lock and before any
Docker or registry read/write. It is not rolled back on failure.

## OCI and registry proof

The exact OCI archive is imported under a nonce-scoped local reference with
digest preservation, and Docker must report the sealed config digest. Candidate
bytes are never executed. The script creates a container but never starts it,
requires state `created`, copies the six `/usr/local/bin` files to a protected
host directory, hashes regular non-symlink bytes on the host, and removes the
stopped container. The final receipt records `container_started: false`.

The unique H/run/attempt tag is preflighted twice. If absent, Skopeo copies the
sealed archive with both `--authfile` and `--preserve-digests`. A nonzero copy
exit is treated as ambiguous because a registry can commit before the client
observes success. The script does not retry or infer success. It refetches the
tag and continues only if the ordinary final gate proves exact equality. The
nonce remains consumed in every branch. No `RESULT.json` or rollout authority
is emitted unless every final check passes.

The tag response must carry one same-response `Docker-Content-Digest` equal to
its body hash and the sealed source-manifest digest. The tag bytes must be
exactly equal to the sealed source manifest, including the config descriptor
and every ordered layer media type, digest, and size. A digest refetch must
return the same bytes. The referenced config bytes must exactly equal the
sealed source config and reproduce its labels, platform, and binary ledger.

Only then does the adapter emit
`qqblackcoin/blackcoin-v4-gui@sha256:<manifest>`. The mutable tag is explicitly
non-authoritative. `registry/RESULT.json` contains the complete authority,
source/Core/packaging/artifact/publication receipts, exact local and remote OCI
graphs, nonce-consumption and credential-operational receipts, stopped-
container binary proof, publication outcome, and a schema-2 structured handoff
that cross-binds the same identities. `PUBLICATION_SHA256SUMS` seals the
resulting evidence tree.

## Operation

Copy `request.example.json` outside the repository and replace every identity,
path, and digest from reviewed evidence. Save both the artifact API response
and the terminal packaging workflow-run API response. Keep the execution object
exactly disabled for offline verification:

```bash
contrib/ops/v30.1.5-candidate-publication/publish_candidate_oci.sh \
  /absolute/request.json /absolute/new-evidence-directory
```

Successful offline output includes `VERIFIED_INPUT.json`, copied API/run/ZIP
receipts, the extracted bundle, and exact source OCI manifest/config bytes. It
prints `NO_DOCKER_OR_REGISTRY_OPERATION_PERFORMED=true` and emits no image
authority.

For live execution, independently review the offline evidence, create a fresh
root-owned mode-0600 request and exclusive-writer receipt, create a protected
root-owned mode-0700 nonce-ledger directory, select a root-owned mode-0600
Skopeo-compatible authfile, and use a new absent output path. Do not enable the
request without external coordination granting exclusive authority over the
exact unique tag.

## Review validation

The local suite is offline:

```bash
bash contrib/ops/v30.1.5-candidate-publication/tests/run.sh
```

It builds canonical blocked and ready candidates and attacks the authority
tuple, confirmation, timestamps, terminal run receipt, ZIP parser and cap,
prepared-state receipt, nonce ledger/replay, stopped-container extraction
receipt, registry headers/refetch/config, exact OCI layer graph, credential
contract, ambiguous-copy branch, handoff, disabled wrapper, and package seal.
It does not contact GitHub or a registry and does not invoke Docker, Skopeo,
Compose, or any node.
