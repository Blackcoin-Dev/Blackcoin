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

python3 - <<'PY'
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tarfile
import unittest
import warnings
import zipfile

root = Path(os.environ["V3015_TEST_TMP"])
repo = Path(os.environ["V3015_TEST_REPO"])
verify_path = Path(os.environ["V3015_TEST_VERIFY"])

def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

publication = load_module("publication", verify_path)
metadata = load_module("metadata", repo / "ci/release/generate_v30_1_5_candidate_metadata.py")
candidate_tests = load_module("candidate_tests", repo / "ci/release/test_v30_1_5_candidate_metadata.py")
policy_path = repo / "contrib/ops/v30.1.5-candidate-package/policy.json"
source = metadata.EXPECTED_SOURCE_COMMIT
tree = metadata.EXPECTED_SOURCE_TREE
tooling = "bad55a3a321d33ac5294cfcbc230b9ae7e5b1594"
tooling_tree = "27b3d3c0bfd966433595239f8dbd36a0a143ef55"
core_run = 987654
packaging_run = 123456
attempt = 2

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")

def make_policy(directory, ready=False):
    value = json.loads(policy_path.read_text(encoding="utf-8"))
    if ready:
        value["authorization"] = {
            "state": metadata.READY_AUTHORIZATION_STATE,
            "dispatch_enabled": True,
            "temporary_source_pin": False,
            "core_ci_run_id": core_run,
        }
    output = directory / ("ready-policy.json" if ready else "blocked-policy.json")
    write_json(output, value)
    return output

def make_bundle(directory, ready=False):
    directory.mkdir()
    case = candidate_tests.V3015CandidateMetadataTest()
    case.workflow_run_id = str(packaging_run)
    case.workflow_run_attempt = str(attempt)
    _, names = case.create_fixture(directory)
    selected_policy = make_policy(directory.parent, ready)
    metadata.generate(
        selected_policy, directory, tooling, str(packaging_run), str(attempt),
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
        if extra:
            extra(archive)

def make_request(case_root, ready=False, live=False):
    bundle = case_root / "bundle"
    names, selected_policy = make_bundle(bundle, ready)
    archive = case_root / "artifact.zip"
    zip_bundle(bundle, archive)
    artifact_id = 7654321
    artifact_name = publication.expected_artifact_name(source, attempt)
    assert artifact_name == f"v30.1.5-candidate-linux-x86_64-{source}-attempt-{attempt}"
    api = {
        "id": artifact_id,
        "name": artifact_name,
        "size_in_bytes": archive.stat().st_size,
        "expired": False,
        "digest": "sha256:" + sha(archive),
        "url": f"https://api.github.com/repos/Blackcoin-Dev/Blackcoin/actions/artifacts/{artifact_id}",
        "archive_download_url": f"https://api.github.com/repos/Blackcoin-Dev/Blackcoin/actions/artifacts/{artifact_id}/zip",
        "workflow_run": {"id": packaging_run, "head_sha": tooling},
    }
    api_path = case_root / "artifact-api.json"
    write_json(api_path, api)
    nonce = "9" * 64 if live else None
    request = {
        "schema": 1,
        "identity": {
            "repository": "Blackcoin-Dev/Blackcoin",
            "source_commit": source,
            "source_tree": tree,
            "core_ci_run_id": core_run,
            "packaging_tooling_commit": tooling,
            "packaging_tooling_tree": tooling_tree,
        },
        "artifact": {
            "id": artifact_id,
            "name": artifact_name,
            "packaging_run_id": packaging_run,
            "packaging_run_attempt": attempt,
            "api_metadata_path": str(api_path),
            "api_metadata_sha256": sha(api_path),
            "github_zip_path": str(archive),
            "github_zip_sha256": sha(archive),
            "bundle_sha256sums_sha256": sha(bundle / names["checksums"]),
        },
        "registry": {
            "repository": "qqblackcoin/blackcoin-v4-gui",
            "tag": publication.expected_registry_tag(source, packaging_run, attempt),
        },
        "execution": {
            "execute": live,
            "dispatch_enabled": live,
            "exclusive_tag_writer": live,
            "nonce": nonce,
            "confirmation": f"PUBLISH_V30_1_5_CANDIDATE:{source}:{nonce}" if live else None,
        },
    }
    request_path = case_root / "request.json"
    write_json(request_path, request)
    return request_path, bundle, names, selected_policy

blocked_root = root / "blocked"
blocked_root.mkdir()
blocked_request, blocked_bundle, blocked_names, blocked_policy = make_request(blocked_root)
prepared = root / "prepared"
value = publication.prepare_artifact(blocked_request, prepared)
assert value["publication_authorized"] is False
assert value["candidate_authorization_ready"] is False
assert value["github_artifact"]["zip_sha256"] != value["bundle"]["sha256sums_sha256"]
assert set(value["binaries"]) == set(publication.EXPECTED_BINARIES)

def expect_request_failure(label, mutate, file_mutate=None):
    case = root / ("hostile-" + label)
    shutil.copytree(blocked_root, case)
    request_path = case / "request.json"
    request = json.loads(request_path.read_text(encoding="utf-8"))
    request["artifact"]["api_metadata_path"] = str(case / "artifact-api.json")
    request["artifact"]["github_zip_path"] = str(case / "artifact.zip")
    mutate(request)
    if file_mutate:
        file_mutate(case, request)
    write_json(request_path, request)
    try:
        publication.prepare_artifact(request_path, root / ("out-" + label))
    except (publication.VerificationError, OSError):
        return
    raise AssertionError(f"hostile case passed: {label}")

expect_request_failure("H", lambda r: r["identity"].__setitem__("source_commit", "f" * 40))
expect_request_failure("T", lambda r: r["identity"].__setitem__("source_tree", "f" * 40))
expect_request_failure("R", lambda r: r["identity"].__setitem__("core_ci_run_id", core_run + 1))
expect_request_failure("tooling", lambda r: r["identity"].__setitem__("packaging_tooling_commit", "f" * 40))
expect_request_failure("run", lambda r: r["artifact"].__setitem__("packaging_run_id", packaging_run + 1))
expect_request_failure("attempt", lambda r: r["artifact"].__setitem__("packaging_run_attempt", attempt + 1))
expect_request_failure("api-sha", lambda r: r["artifact"].__setitem__("api_metadata_sha256", "f" * 64))
expect_request_failure("zip-sha", lambda r: r["artifact"].__setitem__("github_zip_sha256", "f" * 64))
expect_request_failure("internal-sha", lambda r: r["artifact"].__setitem__("bundle_sha256sums_sha256", "f" * 64))
expect_request_failure("mutable-tag", lambda r: r["registry"].__setitem__("tag", "latest"))
expect_request_failure("partial-execute", lambda r: r["execution"].__setitem__("dispatch_enabled", True))

def mutate_api_receipt(case, request, mutate):
    api_path = case / "artifact-api.json"
    api = json.loads(api_path.read_text(encoding="utf-8"))
    mutate(api)
    write_json(api_path, api)
    request["artifact"]["api_metadata_sha256"] = sha(api_path)

expect_request_failure(
    "api-advertised-zip",
    lambda r: None,
    lambda case, request: mutate_api_receipt(
        case, request, lambda api: api.__setitem__("digest", "sha256:" + "f" * 64)
    ),
)
expect_request_failure(
    "api-workflow-run",
    lambda r: None,
    lambda case, request: mutate_api_receipt(
        case, request, lambda api: api["workflow_run"].__setitem__("id", packaging_run + 1)
    ),
)

def missing_nonce(request):
    request["execution"] = {
        "execute": True, "dispatch_enabled": True, "exclusive_tag_writer": True,
        "nonce": None, "confirmation": None,
    }
expect_request_failure("missing-nonce", missing_nonce)

def arm_blocked_request(request):
    nonce = "8" * 64
    request["execution"] = {
        "execute": True,
        "dispatch_enabled": True,
        "exclusive_tag_writer": True,
        "nonce": nonce,
        "confirmation": f"PUBLISH_V30_1_5_CANDIDATE:{source}:{nonce}",
    }

expect_request_failure("blocked-live", arm_blocked_request)

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

def traversal(case, request):
    rewrite_zip(case, request, lambda archive: (
        zipfile.ZipFile(archive, "w").writestr("../escape", b"bad")
    ))
expect_request_failure("zip-traversal", lambda r: None, traversal)

def duplicate(case, request):
    def writer(path):
        with zipfile.ZipFile(path, "w") as archive:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                archive.writestr("duplicate", b"one")
                archive.writestr("duplicate", b"two")
    rewrite_zip(case, request, writer)
expect_request_failure("zip-duplicate", lambda r: None, duplicate)

def symlink(case, request):
    def writer(path):
        with zipfile.ZipFile(path, "w") as archive:
            info = zipfile.ZipInfo("link")
            info.create_system = 3
            info.external_attr = (0o120777 << 16)
            archive.writestr(info, "target")
    rewrite_zip(case, request, writer)
expect_request_failure("zip-symlink", lambda r: None, symlink)

with tarfile.open(root / "missing-binary.tar.gz", "w:gz") as archive:
    for name in publication.EXPECTED_BINARIES[:-1]:
        payload = b"x"
        member = tarfile.TarInfo(name)
        member.size = 1
        member.mode = 0o755
        archive.addfile(member, io.BytesIO(payload))
try:
    publication.inspect_binary_tar(root / "missing-binary.tar.gz")
except publication.VerificationError:
    pass
else:
    raise AssertionError("missing sixth executable passed")

bad_oci = root / "bad.oci.tar"
bad_oci.write_bytes(b"not oci")
try:
    publication.inspect_oci_archive(bad_oci)
except publication.VerificationError:
    pass
else:
    raise AssertionError("invalid OCI passed")

tampered_oci = root / "tampered.oci.tar"
changed_blob = False
with tarfile.open(blocked_bundle / blocked_names["oci_archive"], "r:") as source_archive:
    with tarfile.open(tampered_oci, "w", format=tarfile.PAX_FORMAT) as target_archive:
        for member in source_archive.getmembers():
            source_file = source_archive.extractfile(member)
            payload = source_file.read() if source_file is not None else None
            if member.isfile() and member.name.startswith("blobs/sha256/") and not changed_blob:
                payload += b"tamper"
                member.size = len(payload)
                changed_blob = True
            target_archive.addfile(member, io.BytesIO(payload) if payload is not None else None)
assert changed_blob
try:
    publication.inspect_oci_archive(tampered_oci)
except publication.VerificationError:
    pass
else:
    raise AssertionError("OCI blob digest tamper passed")

ready_root = root / "ready"
ready_root.mkdir()
ready_request, ready_bundle, ready_names, ready_policy = make_request(ready_root, ready=True, live=True)
ready_prepared = root / "ready-prepared"
ready_value = publication.prepare_artifact(
    ready_request,
    ready_prepared,
    canonical_bundle_check=lambda bundle: metadata.verify(ready_policy, bundle),
)
assert ready_value["publication_authorized"] is True
source_manifest = ready_prepared / ready_value["oci"]["source_manifest_path"]
source_config = ready_prepared / ready_value["oci"]["source_config_path"]
manifest_digest = "sha256:" + sha(source_manifest)
headers = (
    "HTTP/1.1 200 OK\r\n"
    "Content-Type: application/vnd.oci.image.manifest.v1+json\r\n"
    f"Docker-Content-Digest: {manifest_digest}\r\n\r\n"
)
tag_headers = root / "tag.headers"
digest_headers = root / "digest.headers"
tag_headers.write_text(headers, encoding="ascii")
digest_headers.write_text(headers, encoding="ascii")
tag_body = root / "tag.json"
digest_body = root / "digest.json"
shutil.copy2(source_manifest, tag_body)
shutil.copy2(source_manifest, digest_body)
config_headers = root / "config.headers"
config_headers.write_text("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\r\n", encoding="ascii")
config_body = root / "config.json"
shutil.copy2(source_config, config_body)
config = json.loads(source_config.read_text(encoding="utf-8"))
inspect = [{
    "Id": ready_value["oci"]["source_config_digest"],
    "Os": "linux",
    "Architecture": "amd64",
    "Config": config["config"],
}]
inspect_path = root / "inspect.json"
write_json(inspect_path, inspect)
embedded = root / "embedded.txt"
embedded.write_text(
    "".join(f"{digest}  /usr/local/bin/{name}\n" for name, digest in ready_value["binaries"].items()),
    encoding="utf-8",
)
result_path = root / "RESULT.json"
result = publication.verify_registry_evidence(
    ready_prepared / "VERIFIED_INPUT.json", ready_prepared / "request.json",
    tag_body, tag_headers, digest_body, digest_headers, config_body, config_headers,
    inspect_path, embedded, True, result_path,
)
assert result["immutable_image_ref"] == "qqblackcoin/blackcoin-v4-gui@" + manifest_digest
assert result["mutable_tag_is_rollout_authority"] is False
assert result["handoff"]["github_artifact_zip_sha256"] != result["handoff"]["candidate_bundle_sha256sums_sha256"]
assert result["handoff"]["candidate_bundle_sha256"] == result["handoff"]["candidate_bundle_sha256sums_sha256"]
assert result["handoff"]["candidate_tooling_sha256"] == result["handoff"]["candidate_packaging_tooling_sha256"]
assert {
    "candidate_artifact_name", "candidate_artifact_run_id",
    "candidate_artifact_run_attempt", "candidate_image_ref", "candidate_image_id",
    "candidate_bundle_sha256", "candidate_oci_archive_sha256",
    "candidate_oci_manifest_sha256", "candidate_tooling_sha256",
    "candidate_manifest_sha256", "candidate_provenance_sha256", "binary_sha256s",
}.issubset(result["handoff"])

def expect_registry_failure(label, mutate):
    case = root / ("registry-" + label)
    case.mkdir()
    paths = {}
    for name, original in {
        "tag_body": tag_body, "tag_headers": tag_headers,
        "digest_body": digest_body, "digest_headers": digest_headers,
        "config_body": config_body, "config_headers": config_headers,
        "inspect": inspect_path, "embedded": embedded,
    }.items():
        paths[name] = case / original.name
        shutil.copy2(original, paths[name])
    mutate(paths)
    try:
        publication.verify_registry_evidence(
            ready_prepared / "VERIFIED_INPUT.json", ready_prepared / "request.json",
            paths["tag_body"], paths["tag_headers"], paths["digest_body"],
            paths["digest_headers"], paths["config_body"], paths["config_headers"],
            paths["inspect"], paths["embedded"], False, case / "result.json",
        )
    except publication.VerificationError:
        return
    raise AssertionError(f"hostile registry case passed: {label}")

expect_registry_failure("wrong-header-digest", lambda p: p["tag_headers"].write_text(
    headers.replace(manifest_digest, "sha256:" + "f" * 64), encoding="ascii"))
expect_registry_failure("duplicate-digest", lambda p: p["tag_headers"].write_text(
    headers.replace("\r\n\r\n", f"\r\nDocker-Content-Digest: {manifest_digest}\r\n\r\n"), encoding="ascii"))
expect_registry_failure("refetch-body", lambda p: p["digest_body"].write_bytes(b"{}\n"))
expect_registry_failure("config-body", lambda p: p["config_body"].write_bytes(b"{}\n"))
expect_registry_failure("sixth-binary", lambda p: p["embedded"].write_text(
    "".join(p["embedded"].read_text().splitlines(True)[:-1]), encoding="utf-8"))

def wrong_config_size(paths):
    value = json.loads(paths["tag_body"].read_text(encoding="utf-8"))
    value["config"]["size"] += 1
    for body_key, headers_key in (("tag_body", "tag_headers"), ("digest_body", "digest_headers")):
        write_json(paths[body_key], value)
        changed_digest = "sha256:" + sha(paths[body_key])
        paths[headers_key].write_text(
            headers.replace(manifest_digest, changed_digest), encoding="ascii"
        )

expect_registry_failure("config-size", wrong_config_size)

print("PASS publication-python-offline-and-hostile-fixtures")
PY

# Exercise the actual disabled wrapper with mock live tools. The fixture and
# request were built by the Python suite and use the canonical checked-in
# blocked policy, so the real candidate verifier remains in the path.
MOCK="$TMP/mock-bin"
mkdir "$MOCK"
for command in docker curl skopeo; do
    printf '#!/bin/sh\nprintf "called\\n" >>"%s"\nexit 99\n' \
        "$TMP/live-tool-called" >"$MOCK/$command"
    chmod +x "$MOCK/$command"
done
PATH="$MOCK:$PATH" "$PUBLISH" "$TMP/blocked/request.json" "$TMP/wrapper-prepared" \
    >"$TMP/wrapper.stdout"
grep -Fqx "OFFLINE_VERIFICATION_ONLY=$TMP/wrapper-prepared/VERIFIED_INPUT.json" "$TMP/wrapper.stdout"
grep -Fqx 'NO_DOCKER_OR_REGISTRY_OPERATION_PERFORMED=true' "$TMP/wrapper.stdout"
[[ ! -e "$TMP/live-tool-called" ]] || fail 'disabled wrapper invoked a live tool'

python3 - "$EXAMPLE" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["execution"] == {
    "execute": False,
    "dispatch_enabled": False,
    "exclusive_tag_writer": False,
    "nonce": None,
    "confirmation": None,
}
assert value["artifact"]["github_zip_sha256"] == "0" * 64
assert value["artifact"]["bundle_sha256sums_sha256"] == "0" * 64
assert "github_zip_sha256" != "bundle_sha256sums_sha256"
assert value["registry"]["repository"] == "qqblackcoin/blackcoin-v4-gui"
assert "@" not in value["registry"]["tag"] and value["registry"]["tag"] != "latest"
PY

grep -Fq 'github_zip_sha256' "$VERIFY" "$EXAMPLE" "$PACKAGE_ROOT/README.md"
grep -Fq 'bundle_sha256sums_sha256' "$VERIFY" "$EXAMPLE" "$PACKAGE_ROOT/README.md"
grep -Fq 'same_response_digest_verified' "$VERIFY"
grep -Fq 'digest_refetch_verified' "$VERIFY"
grep -Fq 'remote_config_bytes_verified' "$VERIFY"
grep -Fq 'mutable_tag_is_rollout_authority' "$VERIFY"
grep -Fq 'NO_DOCKER_OR_REGISTRY_OPERATION_PERFORMED=true' "$PUBLISH"
grep -Fq "docker push \"\$TARGET_REF\"" "$PUBLISH"
grep -Fq "skopeo copy \"oci-archive:\$OCI_ARCHIVE\" \"docker-daemon:\$LOCAL_REF\"" "$PUBLISH"

cmp -s \
    <(cd "$PACKAGE_ROOT" && find . -type f ! -path './SHA256SUMS' -print | sort) \
    <(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {
        name=$2; sub(/^\\*/, "", name); print "./" name
    }' "$SUMS" | sort) || fail 'package checksum manifest does not cover the exact file set'
(cd "$PACKAGE_ROOT" && sha256sum --strict --check SHA256SUMS >/dev/null) ||
    fail 'publication package checksum verification failed'

printf 'PASS publication-disabled-wrapper-no-live-tools\n'
printf 'PASS publication-static-contract-and-package-seal\n'
