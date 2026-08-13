# v30.1.5 OCI publication and immutable handoff

This directory closes the boundary between one exact GitHub Actions candidate
artifact and the immutable registry reference required by the v30.1.5 canary
and rollout consumers. It is identity-generic across the final source commit
`H`, source tree `T`, successful Core-CI run `R`, packaging tooling commit/tree,
and packaging run/attempt. It is deliberately specific to the reviewed
`Blackcoin-Dev/Blackcoin` source and `qqblackcoin/blackcoin-v4-gui` registry
repository.

The checked-in request is disabled. Offline verification is the default and
does not invoke Docker, Skopeo, curl, a registry, Compose, or a node. There is
no workflow-dispatch file in this package. A live request must atomically set
`execute`, `dispatch_enabled`, and `exclusive_tag_writer` to `true`, provide a
fresh 32-byte lowercase-hex nonce, and use the exact confirmation
`PUBLISH_V30_1_5_CANDIDATE:<H>:<nonce>`. Partial arming is rejected.

## Distinct artifact digests

The request and receipts never collapse these two values:

- `github_zip_sha256` is the SHA-256 of the GitHub artifact API ZIP. It must
  equal both the independently pinned request value and the API response's
  `digest` field. The API artifact ID, exact H/attempt name, size, non-expired
  state, URL, packaging run, and packaging tooling head must also match.
- `bundle_sha256sums_sha256` is the SHA-256 of the candidate bundle's internal
  `Blackcoin-30.1.5-candidate-<H12>-SHA256SUMS.txt`. That file must cover the
  exact other thirteen flat files and every covered byte.

The ZIP extractor rejects traversal, nested paths, backslashes, case-folded or
literal duplicates, symlinks, nonregular entries, encryption, and excessive
expansion. The canonical candidate verifier is then run against the exact
checked-in policy and tooling snapshot from the signed packaging commit.

## Verified graph

Before live execution, the adapter independently checks:

1. signed source `H` and tree `T`, signed packaging commit/tree, successful
   schema-2 Core-CI run `R`, exact packaging run/attempt, and the GitHub API
   artifact receipt;
2. the exact fourteen-file bundle, internal checksum ledger, canonical
   manifest/provenance, and blocked-or-ready authorization tuple (live mode
   requires the ready tuple);
3. the six executable root entries and their binary ledger;
4. the complete single-image OCI descriptor graph, every blob digest and size,
   manifest/config digests, Linux/amd64 runtime identity, source labels, and
   six binary labels; and
5. the distinction between pre-publication assembly evidence and the later
   publication receipt. The immutable OCI config truthfully records that the
   assembly workflow itself did not push. The post-assembly transition is
   proven by `registry/RESULT.json`; the source config is never rewritten.

Live mode imports that exact OCI archive under a nonce-derived local tag,
requires the imported config ID, and hashes all six `/usr/local/bin`
executables in a no-network, read-only container. It preflights the unique
H/run/attempt registry tag under explicit exclusive-writer authority. An
already-existing tag is accepted only if the later registry proof shows the
exact expected config. A missing tag is pushed through the operator's existing
Docker credential context.

The tag GET must return a `Docker-Content-Digest` equal to the SHA-256 of that
same response body. The adapter refetches by that digest and requires identical
bytes, then fetches the referenced config blob and requires byte identity with
the sealed OCI config. Only after those checks does it emit
`qqblackcoin/blackcoin-v4-gui@sha256:<manifest>`. The mutable tag is explicitly
recorded as non-authoritative.

## Operation

Copy `request.example.json` outside the repository and replace every identity,
path, and digest from reviewed evidence. The GitHub API metadata should be the
saved response from `GET /repos/Blackcoin-Dev/Blackcoin/actions/artifacts/<id>`;
the ZIP must be the bytes downloaded from that response's archive URL.

For offline verification:

```bash
contrib/ops/v30.1.5-candidate-publication/publish_candidate_oci.sh \
  /absolute/request.json /absolute/new-evidence-directory
```

Keep the execution object exactly disabled. Successful output contains
`VERIFIED_INPUT.json`, the copied API response and ZIP, the safely extracted
bundle, and the exact source OCI manifest/config. It emits
`NO_DOCKER_OR_REGISTRY_OPERATION_PERFORMED=true` and no image authority.

For live publication, independently review that offline receipt, create a new
root-owned mode-0600 request with the live tuple and fresh nonce, and use a new
absent root-owned evidence path. Root and an existing authenticated Docker
context are required. The script does not log credentials. Do not execute this
branch until the exact artifact exists and external release coordination has
granted exclusive tag-writer authority.

`registry/RESULT.json` provides both the immutable image reference and a
consumer handoff object. It preserves the API ZIP digest and internal bundle
seal as different fields and carries the OCI archive/manifest/config,
manifest/provenance, packaging-tooling seal, and all six executable hashes.
The handoff's `candidate_bundle_sha256` is the internal bundle SHA256SUMS-file
digest (also named `candidate_bundle_sha256sums_sha256`); it is never the
separate `github_artifact_zip_sha256`. `candidate_tooling_sha256` is the
checked-in packaging package's SHA256SUMS-file digest. These names map directly
to the durability package's candidate identity inputs without weakening their
provenance.
`PUBLICATION_SHA256SUMS` seals the complete evidence tree after success.

## Review validation

The permitted local suite is offline:

```bash
bash contrib/ops/v30.1.5-candidate-publication/tests/run.sh
```

It creates synthetic canonical candidate artifacts and hostile ZIP, H/T/R,
tooling, checksum, OCI, executable, nonce, header, refetch, and config cases.
Mock Docker and curl executables prove the disabled shell branch never reaches
live tools. The tests do not contact GitHub or a registry and do not mutate a
Docker daemon, Compose, or any node.
