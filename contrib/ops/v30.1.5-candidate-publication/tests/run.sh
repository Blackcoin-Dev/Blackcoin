#!/usr/bin/env bash
export LC_ALL=C
set -Eeuo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1

TEST_ROOT=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
PACKAGE_ROOT=$(CDPATH='' cd -P -- "$TEST_ROOT/.." && pwd -P) || exit 1
REPO_ROOT=$(CDPATH='' cd -P -- "$PACKAGE_ROOT/../../.." && pwd -P) || exit 1
readonly TEST_ROOT PACKAGE_ROOT REPO_ROOT
readonly VERIFY="$PACKAGE_ROOT/verify_candidate_publication.py"
readonly PUBLISH="$PACKAGE_ROOT/publish_candidate_oci.sh"
readonly EXAMPLE="$PACKAGE_ROOT/request.example.json"
readonly CANDIDATE_TEST="$REPO_ROOT/ci/release/test_v30_1_5_candidate_metadata.py"
readonly CANDIDATE_METADATA="$REPO_ROOT/ci/release/generate_v30_1_5_candidate_metadata.py"
readonly CANDIDATE_POLICY="$REPO_ROOT/contrib/ops/v30.1.5-candidate-package/policy.json"
readonly SUMS="$PACKAGE_ROOT/SHA256SUMS"

fail()
{
    printf 'publication adapter test failed: %s\n' "$*" >&2
    exit 1
}

for path in "$VERIFY" "$PUBLISH" "$EXAMPLE" "$CANDIDATE_TEST" \
    "$CANDIDATE_METADATA" "$CANDIDATE_POLICY" "$SUMS"; do
    [[ -f "$path" && ! -L "$path" ]] || fail "required path is absent or unsafe: $path"
done
[[ -z "$(find "$PACKAGE_ROOT" -type l -print -quit)" &&
   -z "$(find "$PACKAGE_ROOT" ! -type d ! -type f -print -quit)" ]] ||
    fail 'publication package contains a symlink or nonregular entry'
bash -n "$PUBLISH" "$TEST_ROOT/run.sh"
python3 -m py_compile "$VERIFY"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$PUBLISH" "$TEST_ROOT/run.sh"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/v3015-publication-tests.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM
export V3015_TEST_TMP="$TMP"
export V3015_TEST_REPO="$REPO_ROOT"
export V3015_TEST_VERIFY="$VERIFY"
export V3015_TEST_PUBLICATION_COMMIT="${V3015_TEST_PUBLICATION_COMMIT:-$(git -C "$REPO_ROOT" rev-parse HEAD)}"

python3 - <<'PY'
from datetime import datetime, timedelta, timezone
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import warnings
import zipfile

root = Path(os.environ["V3015_TEST_TMP"])
repo = Path(os.environ["V3015_TEST_REPO"])
verify_path = Path(os.environ["V3015_TEST_VERIFY"])
publication_commit = os.environ["V3015_TEST_PUBLICATION_COMMIT"]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


publication = load_module("publication", verify_path)
metadata = load_module("metadata", repo / "ci/release/generate_v30_1_5_candidate_metadata.py")
candidate_tests = load_module(
    "candidate_tests", repo / "ci/release/test_v30_1_5_candidate_metadata.py"
)
policy_path = repo / "contrib/ops/v30.1.5-candidate-package/policy.json"
package_root = verify_path.parent
source = metadata.EXPECTED_SOURCE_COMMIT
tree = metadata.EXPECTED_SOURCE_TREE
tooling = subprocess.run(
    ["git", "-C", str(repo), "rev-parse", "HEAD"],
    check=True, capture_output=True, text=True,
).stdout.strip()
tooling_tree = subprocess.run(
    ["git", "-C", str(repo), "rev-parse", "HEAD^{tree}"],
    check=True, capture_output=True, text=True,
).stdout.strip()
publication_tree = subprocess.run(
    ["git", "-C", str(repo), "rev-parse", f"{publication_commit}^{{tree}}"],
    check=True, capture_output=True, text=True,
).stdout.strip()
core_run = 987654
core_attempt = 1
packaging_run = 123456
packaging_attempt = 2
uid = os.getuid()


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    Path(path).write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def utc(value):
    return value.astimezone(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def make_policy(directory, ready=False):
    value = json.loads(policy_path.read_text(encoding="utf-8"))
    if ready:
        value["authorization"] = {
            "state": metadata.READY_AUTHORIZATION_STATE,
            "dispatch_enabled": True,
            "temporary_source_pin": False,
            "core_ci_run_id": core_run,
            "core_ci_run_attempt": core_attempt,
            "thread_sanitizer_artifact": {
                "id": 765432,
                "name": f"sanitizer-reports-thread-sanitizer-{source}-attempt-{core_attempt}",
                "zip_sha256": "a" * 64,
                "reports_sha256": "b" * 64,
            },
        }
    else:
        value["authorization"] = {
            "state": "blocked_pending_final_signed_source_and_green_ci",
            "dispatch_enabled": False,
            "temporary_source_pin": True,
            "core_ci_run_id": None,
            "core_ci_run_attempt": None,
            "thread_sanitizer_artifact": None,
        }
    output = directory / ("ready-policy.json" if ready else "blocked-policy.json")
    write_json(output, value)
    return output


def make_bundle(directory, ready=False):
    directory.mkdir()
    case = candidate_tests.V3015CandidateMetadataTest()
    case.workflow_run_id = str(packaging_run)
    case.workflow_run_attempt = str(packaging_attempt)
    selected_policy = make_policy(directory.parent, ready)
    selected_authorization = json.loads(
        selected_policy.read_text(encoding="utf-8")
    )["authorization"]
    assert (selected_authorization["state"] == metadata.READY_AUTHORIZATION_STATE) is ready
    assert selected_authorization["dispatch_enabled"] is ready
    assert selected_authorization["core_ci_run_id"] == (core_run if ready else None)
    assert selected_authorization["core_ci_run_attempt"] == (
        core_attempt if ready else None
    )
    # The imported candidate test helper normally reads its checked-in POLICY
    # global. Point it at the explicit synthetic blocked/ready policy before it
    # constructs any evidence, so a later checked-in authorization transition
    # cannot silently change either publication fixture.
    original_fixture_policy = candidate_tests.POLICY
    candidate_tests.POLICY = selected_policy
    try:
        _, names = case.create_fixture(directory)
    finally:
        candidate_tests.POLICY = original_fixture_policy
    metadata.generate(
        selected_policy, directory, tooling, str(packaging_run), str(packaging_attempt),
        directory / names["manifest"], directory / names["provenance"],
    )
    checksum = directory / names["checksums"]
    checksum.write_text(
        "".join(
            f"{sha(path)}  {path.name}\n"
            for path in sorted(directory.iterdir(), key=lambda item: item.name)
            if path != checksum
        ),
        encoding="utf-8",
    )
    metadata.verify(selected_policy, directory)
    return names, selected_policy


def zip_bundle(bundle, output, extra=None):
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(bundle.iterdir(), key=lambda item: item.name):
            archive.write(path, arcname=path.name)
        if extra is not None:
            extra(archive)


def callbacks(policy):
    return {
        "canonical_bundle_check": lambda bundle: metadata.verify(policy, bundle),
        "source_identity_check": lambda commit, commit_tree: (
            (_ for _ in ()).throw(AssertionError("source callback identity changed"))
            if (commit, commit_tree) != (source, tree) else None
        ),
        "packaging_snapshot_check": lambda commit, commit_tree: (
            (_ for _ in ()).throw(AssertionError("packaging callback identity changed"))
            if (commit, commit_tree) != (tooling, tooling_tree)
            else sha(repo / "contrib/ops/v30.1.5-candidate-package/SHA256SUMS")
        ),
        "publication_snapshot_check": lambda commit, commit_tree: (
            (_ for _ in ()).throw(AssertionError("publication callback identity changed"))
            if (commit, commit_tree) != (publication_commit, publication_tree)
            else sha(package_root / "SHA256SUMS")
        ),
    }


def make_request(case_root, *, ready=False, live=False, nonce_digit="9"):
    case_root.mkdir()
    bundle = case_root / "bundle"
    names, selected_policy = make_bundle(bundle, ready)
    archive = case_root / "artifact.zip"
    zip_bundle(bundle, archive)
    core_path = bundle / names["core_ci"]
    core = json.loads(core_path.read_text(encoding="utf-8"))
    oci = publication.inspect_oci_archive(bundle / names["oci_archive"])
    binary_hashes = publication.inspect_binary_tar(bundle / names["binary_tar"])

    run = {
        "id": packaging_run,
        "run_attempt": packaging_attempt,
        "path": publication.EXPECTED_PACKAGING_WORKFLOW,
        "name": publication.EXPECTED_PACKAGING_WORKFLOW_NAME,
        "event": "workflow_dispatch",
        "head_sha": tooling,
        "head_commit": {"id": tooling, "tree_id": tooling_tree},
        "repository": {"full_name": publication.EXPECTED_REPOSITORY},
        "head_repository": {"full_name": publication.EXPECTED_REPOSITORY},
        "actor": {"login": publication.EXPECTED_ACTOR},
        "triggering_actor": {"login": publication.EXPECTED_ACTOR},
        "status": "completed",
        "conclusion": "success",
    }
    run_path = case_root / "packaging-run.json"
    write_json(run_path, run)
    artifact_id = 7654321
    artifact_name = publication.expected_artifact_name(source, packaging_attempt)
    api = {
        "id": artifact_id,
        "name": artifact_name,
        "size_in_bytes": archive.stat().st_size,
        "expired": False,
        "digest": "sha256:" + sha(archive),
        "url": (
            f"https://api.github.com/repos/{publication.EXPECTED_REPOSITORY}/"
            f"actions/artifacts/{artifact_id}"
        ),
        "archive_download_url": (
            f"https://api.github.com/repos/{publication.EXPECTED_REPOSITORY}/"
            f"actions/artifacts/{artifact_id}/zip"
        ),
        "workflow_run": {"id": packaging_run, "head_sha": tooling},
    }
    api_path = case_root / "artifact-api.json"
    write_json(api_path, api)
    authfile = case_root / "registry-auth.json"
    write_json(authfile, {"auths": {"docker.io": {"auth": "test-only"}}})
    authfile.chmod(0o600)
    ledger_parent = case_root / "nonce-ledger"
    ledger_parent.mkdir(mode=0o700)
    ledger_path = ledger_parent / "used.jsonl"

    sanitizer = core["thread_sanitizer_artifact"]
    now = datetime.now(timezone.utc).replace(microsecond=0)
    request = {
        "schema": 3,
        "source": {
            "repository": publication.EXPECTED_REPOSITORY,
            "commit": source,
            "tree": tree,
            "signing_fingerprint": publication.EXPECTED_FINGERPRINT,
        },
        "core_ci": {
            "workflow_path": core["workflow_path"],
            "run_id": core["run_id"],
            "run_attempt": core["run_attempt"],
            "evidence_sha256": sha(core_path),
            "required_checks_sha256": publication.canonical_subset_sha256(
                core["required_checks"]
            ),
            "thread_sanitizer_artifact": {
                key: sanitizer[key]
                for key in ("id", "name", "api_digest", "zip_sha256", "reports_sha256")
            },
        },
        "packaging": {
            "tooling_commit": tooling,
            "tooling_tree": tooling_tree,
            "package_sha256sums_sha256": sha(
                repo / "contrib/ops/v30.1.5-candidate-package/SHA256SUMS"
            ),
            "workflow_path": publication.EXPECTED_PACKAGING_WORKFLOW,
            "workflow_name": publication.EXPECTED_PACKAGING_WORKFLOW_NAME,
            "run_id": packaging_run,
            "run_attempt": packaging_attempt,
            "run_metadata_path": str(run_path),
            "run_metadata_sha256": sha(run_path),
        },
        "artifact": {
            "id": artifact_id,
            "name": artifact_name,
            "api_metadata_path": str(api_path),
            "api_metadata_sha256": sha(api_path),
            "github_zip_path": str(archive),
            "github_zip_sha256": sha(archive),
            "bundle_sha256sums_sha256": sha(bundle / names["checksums"]),
        },
        "publication_tooling": {
            "commit": publication_commit,
            "tree": publication_tree,
            "package_sha256sums_sha256": sha(package_root / "SHA256SUMS"),
        },
        "oci": {
            "archive_sha256": sha(bundle / names["oci_archive"]),
            "manifest_digest": oci["manifest_digest"],
            "config_digest": oci["config_digest"],
            "layers": oci["layers"],
            "rootfs_diff_ids": oci["rootfs_diff_ids"],
            "binaries": binary_hashes,
        },
        "registry": {
            "host": publication.EXPECTED_REGISTRY_HOST,
            "credential_host": publication.EXPECTED_CREDENTIAL_HOST,
            "repository": publication.EXPECTED_REGISTRY_REPOSITORY,
            "tag": publication.expected_registry_tag(
                source, packaging_run, packaging_attempt
            ),
            "authfile_path": str(authfile),
        },
        "execution": {
            "execute": live,
            "dispatch_enabled": live,
            "exclusive_tag_writer": live,
            "exclusive_writer_authority_path": None,
            "exclusive_writer_authority_sha256": None,
            "nonce": None,
            "issued_utc": None,
            "expires_utc": None,
            "nonce_ledger_path": None,
            "confirmation": None,
        },
    }
    if live:
        nonce = nonce_digit * 64
        issued = utc(now - timedelta(seconds=5))
        expires = utc(now + timedelta(minutes=20))
        exclusive = {
            "schema": 1,
            "action": "exclusive-v30.1.5-candidate-tag-write",
            "repository": request["registry"]["repository"],
            "tag": request["registry"]["tag"],
            "source_commit": source,
            "packaging_run_id": packaging_run,
            "packaging_run_attempt": packaging_attempt,
            "nonce": nonce,
            "issued_utc": issued,
            "expires_utc": expires,
            "exclusive": True,
            "grantor": publication.EXPECTED_ACTOR,
        }
        exclusive_path = case_root / "exclusive-writer-authority.json"
        write_json(exclusive_path, exclusive)
        exclusive_path.chmod(0o600)
        request["execution"] = {
            "execute": True,
            "dispatch_enabled": True,
            "exclusive_tag_writer": True,
            "exclusive_writer_authority_path": str(exclusive_path),
            "exclusive_writer_authority_sha256": sha(exclusive_path),
            "nonce": nonce,
            "issued_utc": issued,
            "expires_utc": expires,
            "nonce_ledger_path": str(ledger_path),
            "confirmation": None,
        }
        request["execution"]["confirmation"] = publication.expected_live_confirmation(
            request, nonce
        )
    request_path = case_root / "request.json"
    write_json(request_path, request)
    return request_path, bundle, names, selected_policy


def expect_failure(label, operation):
    try:
        operation()
    except (publication.VerificationError, OSError, ValueError):
        return
    raise AssertionError(f"hostile case passed: {label}")


# The signed publication snapshot, packaging snapshot, and source signature are
# exercised directly. Pre-commit callers provide a signed ephemeral commit whose
# tree contains these exact package bytes.
assert publication.verify_publication_snapshot(
    publication_commit, publication_tree
) == sha(package_root / "SHA256SUMS")
assert publication.verify_packaging_snapshot(tooling, tooling_tree) == sha(
    repo / "contrib/ops/v30.1.5-candidate-package/SHA256SUMS"
)
publication.verify_git_identity(source, tree, "source")

blocked_root = root / "blocked"
blocked_request, blocked_bundle, blocked_names, blocked_policy = make_request(blocked_root)
blocked_prepared = root / "blocked-prepared"
blocked_value = publication.prepare_artifact(
    blocked_request, blocked_prepared, **callbacks(blocked_policy)
)
assert blocked_value["publication_authorized"] is False
assert blocked_value["candidate_authorization_ready"] is False
assert blocked_value["publication_authority"]["schema"] == 3

ready_root = root / "ready"
ready_request, ready_bundle, ready_names, ready_policy = make_request(
    ready_root, ready=True, live=True
)
ready_prepared = root / "ready-prepared"
ready_value = publication.prepare_artifact(
    ready_request, ready_prepared, **callbacks(ready_policy)
)
assert ready_value["publication_authorized"] is True
ready_request_value = json.loads(ready_request.read_text(encoding="utf-8"))
assert ready_value["publication_authority_sha256"] == publication.publication_authority_sha256(
    ready_request_value
)
assert ready_request_value["execution"]["confirmation"] == publication.expected_live_confirmation(
    ready_request_value, ready_request_value["execution"]["nonce"]
)

# Every identity-bearing field in the authorization tuple invalidates a stale
# confirmation. Paths used only to locate already-digested receipts are excluded.
authority_mutations = [
    ("source-commit", lambda v: v["source"].__setitem__("commit", "f" * 40)),
    ("source-tree", lambda v: v["source"].__setitem__("tree", "f" * 40)),
    ("core-run", lambda v: v["core_ci"].__setitem__("run_id", core_run + 1)),
    ("core-attempt", lambda v: v["core_ci"].__setitem__("run_attempt", core_attempt + 1)),
    ("core-evidence", lambda v: v["core_ci"].__setitem__("evidence_sha256", "f" * 64)),
    ("core-checks", lambda v: v["core_ci"].__setitem__("required_checks_sha256", "f" * 64)),
    ("tsan-id", lambda v: v["core_ci"]["thread_sanitizer_artifact"].__setitem__("id", 1)),
    ("tsan-name", lambda v: v["core_ci"]["thread_sanitizer_artifact"].__setitem__("name", "x")),
    ("tsan-api", lambda v: v["core_ci"]["thread_sanitizer_artifact"].__setitem__("api_digest", "sha256:" + "f" * 64)),
    ("tsan-zip", lambda v: v["core_ci"]["thread_sanitizer_artifact"].__setitem__("zip_sha256", "f" * 64)),
    ("tsan-reports", lambda v: v["core_ci"]["thread_sanitizer_artifact"].__setitem__("reports_sha256", "f" * 64)),
    ("packaging-commit", lambda v: v["packaging"].__setitem__("tooling_commit", "f" * 40)),
    ("packaging-tree", lambda v: v["packaging"].__setitem__("tooling_tree", "f" * 40)),
    ("packaging-seal", lambda v: v["packaging"].__setitem__("package_sha256sums_sha256", "f" * 64)),
    ("packaging-run", lambda v: v["packaging"].__setitem__("run_id", packaging_run + 1)),
    ("packaging-attempt", lambda v: v["packaging"].__setitem__("run_attempt", packaging_attempt + 1)),
    ("packaging-receipt", lambda v: v["packaging"].__setitem__("run_metadata_sha256", "f" * 64)),
    ("artifact-id", lambda v: v["artifact"].__setitem__("id", 1)),
    ("artifact-name", lambda v: v["artifact"].__setitem__("name", "x")),
    ("artifact-api", lambda v: v["artifact"].__setitem__("api_metadata_sha256", "f" * 64)),
    ("artifact-zip", lambda v: v["artifact"].__setitem__("github_zip_sha256", "f" * 64)),
    ("bundle-seal", lambda v: v["artifact"].__setitem__("bundle_sha256sums_sha256", "f" * 64)),
    ("publication-commit", lambda v: v["publication_tooling"].__setitem__("commit", "f" * 40)),
    ("publication-tree", lambda v: v["publication_tooling"].__setitem__("tree", "f" * 40)),
    ("publication-seal", lambda v: v["publication_tooling"].__setitem__("package_sha256sums_sha256", "f" * 64)),
    ("oci-archive", lambda v: v["oci"].__setitem__("archive_sha256", "f" * 64)),
    ("oci-manifest", lambda v: v["oci"].__setitem__("manifest_digest", "sha256:" + "f" * 64)),
    ("oci-config", lambda v: v["oci"].__setitem__("config_digest", "sha256:" + "f" * 64)),
    ("oci-layer", lambda v: v["oci"]["layers"][0].__setitem__("digest", "sha256:" + "f" * 64)),
    ("oci-diff", lambda v: v["oci"]["rootfs_diff_ids"].__setitem__(0, "sha256:" + "f" * 64)),
    ("oci-binary", lambda v: v["oci"]["binaries"].__setitem__("blackcoind", "f" * 64)),
    ("registry-host", lambda v: v["registry"].__setitem__("host", "evil.example")),
    ("credential-host", lambda v: v["registry"].__setitem__("credential_host", "evil.example")),
    ("repository", lambda v: v["registry"].__setitem__("repository", "evil/image")),
    ("tag", lambda v: v["registry"].__setitem__("tag", "latest")),
    ("authfile", lambda v: v["registry"].__setitem__("authfile_path", "/tmp/other-auth")),
    ("exclusive-receipt", lambda v: v["execution"].__setitem__("exclusive_writer_authority_sha256", "f" * 64)),
    ("nonce", lambda v: v["execution"].__setitem__("nonce", "8" * 64)),
    ("issued", lambda v: v["execution"].__setitem__("issued_utc", "2026-01-01T00:00:00Z")),
    ("expires", lambda v: v["execution"].__setitem__("expires_utc", "2026-01-01T00:10:00Z")),
    ("ledger", lambda v: v["execution"].__setitem__("nonce_ledger_path", "/tmp/other-ledger")),
]
original_authority = publication.publication_authority_sha256(ready_request_value)
for label, mutate in authority_mutations:
    changed = copy.deepcopy(ready_request_value)
    mutate(changed)
    assert publication.publication_authority_sha256(changed) != original_authority, label
    expect_failure(label + "-stale-confirmation", lambda changed=changed: (
        publication.validate_request_value(changed)
    ))

# Canonical timestamps reject expired, future, overlong, and noncanonical grants.
clock = datetime.now(timezone.utc).replace(microsecond=0)
for label, issued, expires, observed in (
    ("expired", clock - timedelta(minutes=20), clock - timedelta(seconds=1), clock),
    ("future", clock + timedelta(minutes=2), clock + timedelta(minutes=10), clock),
    ("overlong", clock, clock + timedelta(minutes=31), clock),
):
    changed = copy.deepcopy(ready_request_value)
    changed["execution"]["issued_utc"] = utc(issued)
    changed["execution"]["expires_utc"] = utc(expires)
    changed["execution"]["confirmation"] = publication.expected_live_confirmation(
        changed, changed["execution"]["nonce"]
    )
    expect_failure(label + "-authority", lambda changed=changed, observed=observed: (
        publication.validate_request_value(changed, now=observed)
    ))

# Terminal packaging-run evidence is independently copied, digested, and
# checked. Updating the request digest cannot turn nonterminal/wrong-run bytes
# into acceptable evidence.
for label, mutate in (
    ("run-status", lambda value: value.__setitem__("status", "in_progress")),
    ("run-conclusion", lambda value: value.__setitem__("conclusion", "failure")),
    ("run-attempt", lambda value: value.__setitem__("run_attempt", packaging_attempt + 1)),
    ("run-tree", lambda value: value["head_commit"].__setitem__("tree_id", "f" * 40)),
    ("run-actor", lambda value: value["actor"].__setitem__("login", "attacker")),
    ("run-workflow", lambda value: value.__setitem__("path", ".github/workflows/other.yml")),
):
    case = root / ("terminal-" + label)
    request_path, _, _, policy = make_request(case)
    request = json.loads(request_path.read_text(encoding="utf-8"))
    run_path = case / "packaging-run.json"
    run = json.loads(run_path.read_text(encoding="utf-8"))
    mutate(run)
    write_json(run_path, run)
    request["packaging"]["run_metadata_sha256"] = sha(run_path)
    write_json(request_path, request)
    expect_failure(
        label,
        lambda request_path=request_path, policy=policy, label=label: publication.prepare_artifact(
            request_path, root / ("terminal-out-" + label), **callbacks(policy)
        ),
    )

# ZIP traversal, duplicate, symlink, and compressed-input cap defenses.
def rewrite_zip(case, request, writer):
    archive = case / "artifact.zip"
    archive.unlink()
    writer(archive)
    api_path = case / "artifact-api.json"
    api = json.loads(api_path.read_text(encoding="utf-8"))
    api["size_in_bytes"] = archive.stat().st_size
    api["digest"] = "sha256:" + sha(archive)
    write_json(api_path, api)
    request["artifact"]["github_zip_sha256"] = sha(archive)
    request["artifact"]["api_metadata_sha256"] = sha(api_path)


def traversal(path):
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("../escape", b"bad")


def duplicate(path):
    with zipfile.ZipFile(path, "w") as archive:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            archive.writestr("duplicate", b"one")
            archive.writestr("duplicate", b"two")


def symlink(path):
    with zipfile.ZipFile(path, "w") as archive:
        info = zipfile.ZipInfo("link")
        info.create_system = 3
        info.external_attr = 0o120777 << 16
        archive.writestr(info, "target")


for label, writer in (("zip-traversal", traversal), ("zip-duplicate", duplicate), ("zip-symlink", symlink)):
    case = root / label
    request_path, _, _, policy = make_request(case)
    request = json.loads(request_path.read_text(encoding="utf-8"))
    rewrite_zip(case, request, writer)
    write_json(request_path, request)
    expect_failure(
        label,
        lambda request_path=request_path, policy=policy, label=label: publication.prepare_artifact(
            request_path, root / (label + "-out"), **callbacks(policy)
        ),
    )
small = root / "too-large-input"
small.write_bytes(b"12")
expect_failure(
    "github-zip-byte-cap",
    lambda: publication.copy_regular_file(small, root / "too-large-copy", max_size=1),
)

# Revalidation recomputes the prepared receipt and re-extracts the original ZIP;
# neither a forged receipt nor post-prepare evidence mutation survives.
def expect_prepared_tamper(label, mutate):
    case = root / ("prepared-" + label)
    shutil.copytree(ready_prepared, case)
    mutate(case)
    expect_failure(
        "prepared-" + label,
        lambda: publication.revalidate_prepared_receipt(
            case / "VERIFIED_INPUT.json", case / "request.json",
            enforce_time=True, **callbacks(ready_policy)
        ),
    )


expect_prepared_tamper("forged-receipt", lambda case: (
    (lambda value: (value.__setitem__("publication_authorized", False),
                    write_json(case / "VERIFIED_INPUT.json", value)))(
        json.loads((case / "VERIFIED_INPUT.json").read_text(encoding="utf-8"))
    )
))
expect_prepared_tamper("bundle-byte", lambda case: (
    (case / "bundle" / ready_names["source_commit"]).write_text("f" * 40 + "\n")
))
expect_prepared_tamper("zip-byte", lambda case: (
    (case / "artifact.zip").write_bytes((case / "artifact.zip").read_bytes() + b"x")
))
expect_prepared_tamper("source-manifest", lambda case: (
    (case / "verified/source-oci-manifest.json").write_bytes(b"{}\n")
))

# Durable one-shot ledger: first consumption succeeds, exact replay burns shut,
# and the receipt must point to the exact canonical record in the ledger.
ledger = Path(ready_request_value["execution"]["nonce_ledger_path"])
nonce_receipt_path = ready_prepared / "NONCE_CONSUMPTION.json"
nonce_receipt = publication.consume_nonce(
    ready_prepared / "VERIFIED_INPUT.json", ready_prepared / "request.json",
    ledger, nonce_receipt_path, required_uid=uid, **callbacks(ready_policy)
)
assert publication.validate_nonce_consumption(
    nonce_receipt_path, ready_request_value, ready_value, required_uid=uid
) == nonce_receipt
expect_failure(
    "nonce-replay",
    lambda: publication.consume_nonce(
        ready_prepared / "VERIFIED_INPUT.json", ready_prepared / "request.json",
        ledger, nonce_receipt_path, required_uid=uid, **callbacks(ready_policy)
    ),
)
assert ledger.read_bytes().count(b"\n") == 1
linked_ledger_parent = root / "linked-ledger-parent"
linked_ledger_parent.symlink_to(ledger.parent, target_is_directory=True)
expect_failure(
    "nonce-ledger-parent-symlink",
    lambda: publication.open_ledger_parent(
        linked_ledger_parent / ledger.name, uid
    ),
)
truncated_ledger = root / "truncated-ledger"
truncated_ledger.write_bytes(b'{"schema":1}')
expect_failure(
    "nonce-ledger-torn-record",
    lambda: publication.decode_nonce_ledger(truncated_ledger.read_bytes()),
)

# Candidate binaries are copied out of a never-started container in production;
# this helper proves the host-side exact-six-file hash gate and rejects links.
extracted = root / "extracted"
extracted.mkdir()
with tarfile.open(ready_bundle / ready_names["binary_tar"], "r:gz") as archive:
    for member in archive.getmembers():
        source_file = archive.extractfile(member)
        assert source_file is not None
        extracted_path = extracted / member.name
        extracted_path.write_bytes(source_file.read())
        extracted_path.chmod(0o755)
binary_receipt_path = root / "EXTRACTED_BINARIES.json"
binary_receipt = publication.verify_extracted_binaries(
    ready_prepared / "VERIFIED_INPUT.json", extracted, binary_receipt_path
)
assert binary_receipt["container_started"] is False
tampered_extract = root / "tampered-extracted"
shutil.copytree(extracted, tampered_extract)
(tampered_extract / "blackcoind").write_bytes(b"tamper")
expect_failure(
    "extracted-binary-byte",
    lambda: publication.verify_extracted_binaries(
        ready_prepared / "VERIFIED_INPUT.json", tampered_extract, root / "bad-binary.json"
    ),
)
linked_extract = root / "linked-extracted"
shutil.copytree(extracted, linked_extract)
(linked_extract / "blackcoind").unlink()
(linked_extract / "blackcoind").symlink_to(linked_extract / "blackcoin-cli")
expect_failure(
    "extracted-binary-symlink",
    lambda: publication.verify_extracted_binaries(
        ready_prepared / "VERIFIED_INPUT.json", linked_extract, root / "link-binary.json"
    ),
)

# Registry proof fixtures use the exact source manifest/config bytes. The final
# verifier re-runs the full prepared-state gate before considering these files.
source_manifest = ready_prepared / ready_value["oci"]["source_manifest_path"]
source_config = ready_prepared / ready_value["oci"]["source_config_path"]
manifest_digest = "sha256:" + sha(source_manifest)
headers_text = (
    "HTTP/1.1 200 OK\r\n"
    "Content-Type: application/vnd.oci.image.manifest.v1+json\r\n"
    f"Docker-Content-Digest: {manifest_digest}\r\n\r\n"
)
tag_headers = root / "tag.headers"
digest_headers = root / "digest.headers"
tag_headers.write_text(headers_text, encoding="ascii")
digest_headers.write_text(headers_text, encoding="ascii")
tag_body = root / "tag.json"
digest_body = root / "digest.json"
shutil.copy2(source_manifest, tag_body)
shutil.copy2(source_manifest, digest_body)
config_headers = root / "config.headers"
config_headers.write_text("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\r\n", encoding="ascii")
config_body = root / "config.json"
shutil.copy2(source_config, config_body)
config = json.loads(source_config.read_text(encoding="utf-8"))
local_ref = f"blackcoin-v3015-publication:{source[:12]}-{ready_request_value['execution']['nonce'][:12]}"
inspect_path = root / "inspect.json"
write_json(inspect_path, [{
    "Id": ready_value["oci"]["source_config_digest"],
    "RepoTags": [local_ref],
    "Os": "linux",
    "Architecture": "amd64",
    "Config": config["config"],
}])
auth_receipt_path = root / "REGISTRY_AUTHFILE.json"
write_json(auth_receipt_path, {
    "schema": 1,
    "status": "verified",
    "registry_host": publication.EXPECTED_REGISTRY_HOST,
    "credential_host": publication.EXPECTED_CREDENTIAL_HOST,
    "authfile_path": ready_request_value["registry"]["authfile_path"],
    "authfile_uid": uid,
    "authfile_gid": os.getgid(),
    "authfile_mode": "0600",
    "authfile_single_link": True,
    "skopeo_path": "/usr/bin/skopeo",
    "skopeo_uid": uid,
    "skopeo_mode": "0755",
    "compatibility_probe": "skopeo-login-get-login-succeeded",
    "secrets_recorded": False,
})


def registry_call(output, outcome="tag-already-exact", paths=None):
    paths = paths or {
        "tag_body": tag_body, "tag_headers": tag_headers,
        "digest_body": digest_body, "digest_headers": digest_headers,
        "config_body": config_body, "config_headers": config_headers,
        "inspect": inspect_path, "binaries": binary_receipt_path,
        "nonce": nonce_receipt_path, "authfile": auth_receipt_path,
    }
    return publication.verify_registry_evidence(
        ready_prepared / "VERIFIED_INPUT.json", ready_prepared / "request.json",
        paths["tag_body"], paths["tag_headers"], paths["digest_body"],
        paths["digest_headers"], paths["config_body"], paths["config_headers"],
        paths["inspect"], paths["binaries"], paths["nonce"], paths["authfile"],
        outcome, output, required_uid=uid, **callbacks(ready_policy)
    )


result_path = root / "RESULT.json"
result = registry_call(result_path)
assert result["immutable_image_ref"] == (
    publication.EXPECTED_REGISTRY_REPOSITORY + "@" + manifest_digest
)
assert result["publication_authority"] == ready_value["publication_authority"]
assert result["remote_oci"]["layers"] == ready_value["oci"]["layers"]
assert result["candidate_container_started"] is False
assert result["registry"]["authfile"]["secrets_recorded"] is False
assert result["handoff"]["source"] == ready_value["source"]
assert result["handoff"]["core_ci"] == ready_value["core_ci"]
assert result["handoff"]["packaging"] == ready_value["packaging"]
assert result["handoff"]["publication_tooling"] == ready_value["publication_tooling"]
assert result["handoff"]["oci"]["layers"] == ready_value["oci"]["layers"]
assert result["handoff"]["registry"]["immutable_image_ref"] == result["immutable_image_ref"]
assert result["handoff"]["candidate_artifact_name"] == ready_value["github_artifact"]["name"]
assert result["handoff"]["candidate_packaging_run_id"] == packaging_run
assert result["handoff"]["candidate_packaging_run_attempt"] == packaging_attempt
assert result["handoff"]["github_artifact_zip_sha256"] == ready_value["github_artifact"]["zip_sha256"]
assert result["handoff"]["candidate_bundle_sha256"] == ready_value["bundle"]["sha256sums_sha256"]
assert result["handoff"]["github_artifact_zip_sha256"] != result["handoff"]["candidate_bundle_sha256"]
assert result["handoff"]["candidate_tooling_sha256"] == result["handoff"]["candidate_packaging_tooling_sha256"]
assert result["handoff"]["candidate_image_ref"] == result["immutable_image_ref"]
assert result["handoff"]["binary_sha256s"] == ready_value["binaries"]

ambiguous_path = root / "RESULT-AMBIGUOUS.json"
ambiguous = registry_call(ambiguous_path, "copy-error-remote-exact")
assert ambiguous["copy_exit_success"] is False
assert ambiguous["published_now"] is False
assert ambiguous["source_manifest_exact_equality_verified"] is True


def expect_registry_failure(label, mutate):
    case = root / ("registry-" + label)
    case.mkdir()
    originals = {
        "tag_body": tag_body, "tag_headers": tag_headers,
        "digest_body": digest_body, "digest_headers": digest_headers,
        "config_body": config_body, "config_headers": config_headers,
        "inspect": inspect_path, "binaries": binary_receipt_path,
        "nonce": nonce_receipt_path, "authfile": auth_receipt_path,
    }
    paths = {}
    for key, original in originals.items():
        paths[key] = case / (key + original.suffix)
        shutil.copy2(original, paths[key])
    mutate(paths)
    output = case / "RESULT.json"
    expect_failure(label, lambda: registry_call(output, paths=paths))
    assert not output.exists(), label


expect_registry_failure("wrong-header-digest", lambda p: p["tag_headers"].write_text(
    headers_text.replace(manifest_digest, "sha256:" + "f" * 64), encoding="ascii"
))
expect_registry_failure("duplicate-digest", lambda p: p["tag_headers"].write_text(
    headers_text.replace("\r\n\r\n", f"\r\nDocker-Content-Digest: {manifest_digest}\r\n\r\n"),
    encoding="ascii",
))
expect_registry_failure("refetch-body", lambda p: p["digest_body"].write_bytes(b"{}\n"))
expect_registry_failure("config-body", lambda p: p["config_body"].write_bytes(b"{}\n"))


def substitute_layer(paths):
    manifest = json.loads(paths["tag_body"].read_text(encoding="utf-8"))
    manifest["layers"][0]["digest"] = "sha256:" + "f" * 64
    for body_key, header_key in (("tag_body", "tag_headers"), ("digest_body", "digest_headers")):
        write_json(paths[body_key], manifest)
        changed = "sha256:" + sha(paths[body_key])
        paths[header_key].write_text(
            headers_text.replace(manifest_digest, changed), encoding="ascii"
        )


expect_registry_failure("substituted-layer", substitute_layer)
expect_registry_failure("binary-receipt", lambda p: (
    (lambda value: (value["binaries"].__setitem__("blackcoind", "f" * 64),
                    write_json(p["binaries"], value)))(
        json.loads(p["binaries"].read_text(encoding="utf-8"))
    )
))
expect_registry_failure("nonce-receipt", lambda p: (
    (lambda value: (value["record"].__setitem__("nonce", "8" * 64),
                    write_json(p["nonce"], value)))(
        json.loads(p["nonce"].read_text(encoding="utf-8"))
    )
))
expect_registry_failure("authfile-contract", lambda p: (
    (lambda value: (value.__setitem__("secrets_recorded", True),
                    write_json(p["authfile"], value)))(
        json.loads(p["authfile"].read_text(encoding="utf-8"))
    )
))

# The credential verifier must prove compatibility without disclosing the
# authfile bytes, digest, username, or Skopeo stdout. A safe fake executable is
# sufficient here; the production shell supplies its pinned real Skopeo path.
fake_skopeo = root / "fake-skopeo"
fake_skopeo.write_text("#!/bin/sh\nprintf '%s\\n' test-user\n", encoding="utf-8")
fake_skopeo.chmod(0o755)
auth_probe_path = root / "AUTH-PROBE.json"
auth_probe = publication.verify_registry_authfile(
    ready_request, fake_skopeo, auth_probe_path, required_uid=uid
)
serialized_probe = auth_probe_path.read_text(encoding="utf-8")
assert auth_probe["secrets_recorded"] is False
assert "test-user" not in serialized_probe
assert "test-only" not in serialized_probe
assert sha(Path(ready_request_value["registry"]["authfile_path"])) not in serialized_probe
assert set(auth_probe) == {
    "schema", "status", "registry_host", "credential_host", "authfile_path",
    "authfile_uid", "authfile_gid", "authfile_mode", "authfile_single_link",
    "skopeo_path", "skopeo_uid", "skopeo_mode", "compatibility_probe",
    "secrets_recorded",
}

print("PASS publication-schema3-authority-and-hostile-fixtures")
PY

# Exercise the actual disabled wrapper. Because execution is false, it exits
# before resolving or invoking curl, Docker, skopeo, flock, or registry auth.
"$PUBLISH" "$TMP/blocked/request.json" "$TMP/wrapper-prepared" >"$TMP/wrapper.stdout"
grep -Fqx "OFFLINE_VERIFICATION_ONLY=$TMP/wrapper-prepared/VERIFIED_INPUT.json" \
    "$TMP/wrapper.stdout"
grep -Fqx 'NO_DOCKER_OR_REGISTRY_OPERATION_PERFORMED=true' "$TMP/wrapper.stdout"

python3 - "$EXAMPLE" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["schema"] == 3
assert set(value) == {
    "schema", "source", "core_ci", "packaging", "artifact",
    "publication_tooling", "oci", "registry", "execution",
}
assert value["execution"] == {
    "execute": False,
    "dispatch_enabled": False,
    "exclusive_tag_writer": False,
    "exclusive_writer_authority_path": None,
    "exclusive_writer_authority_sha256": None,
    "nonce": None,
    "issued_utc": None,
    "expires_utc": None,
    "nonce_ledger_path": None,
    "confirmation": None,
}
assert value["registry"]["host"] == "registry-1.docker.io"
assert value["registry"]["credential_host"] == "docker.io"
assert value["registry"]["repository"] == "qqblackcoin/blackcoin-v4-gui"
assert value["registry"]["authfile_path"].startswith("/")
assert value["oci"]["layers"]
PY

# Static safety contract: candidate bytes are never executed; live credentials
# are explicit; every curl disables ambient configuration; an ambiguous copy is
# accepted only through the same exact remote-equality verifier.
# shellcheck disable=SC2016
! grep -Eq '(^|[[:space:]])docker[[:space:]]+run|"\$DOCKER"[[:space:]]+run' "$PUBLISH" ||
    fail 'publisher can execute a candidate container'
# shellcheck disable=SC2016
grep -Fq '"$DOCKER" create --pull=never --network none' "$PUBLISH"
# shellcheck disable=SC2016
grep -Fq '"$DOCKER" cp' "$PUBLISH"
grep -Fq 'consume-nonce --verified' "$PUBLISH"
# shellcheck disable=SC2016
grep -Fq 'copy --authfile "$AUTHFILE" --preserve-digests' "$PUBLISH"
grep -Fq 'copy-error-remote-exact' "$PUBLISH" "$VERIFY"
grep -Fq 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$PUBLISH"
! grep -Fq 'docker push' "$PUBLISH" || fail 'publisher retains a Docker push path'
awk '/"\$CURL"/ && $0 !~ /"\$CURL" --disable/ { bad=1 } END { exit bad }' "$PUBLISH" ||
    fail 'a curl invocation can load ambient configuration'
python3 - "$PUBLISH" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text(encoding="utf-8")
consume = text.index('consume-nonce --verified')
assert consume < text.index('image inspect "$LOCAL_REF"')
assert consume < text.index('"$SKOPEO" copy --authfile')
assert 'docker run' not in text
PY

cmp -s \
    <(cd "$PACKAGE_ROOT" && find . -type f ! -path './SHA256SUMS' -print | sort) \
    <(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {
        name=$2; sub(/^\\*/, "", name); print "./" name
    }' "$SUMS" | sort) || fail 'package checksum manifest does not cover the exact file set'
(cd "$PACKAGE_ROOT" && sha256sum --strict --check SHA256SUMS >/dev/null) ||
    fail 'publication package checksum verification failed'

printf 'PASS publication-disabled-wrapper-no-live-tools\n'
printf 'PASS publication-static-contract-and-package-seal\n'
