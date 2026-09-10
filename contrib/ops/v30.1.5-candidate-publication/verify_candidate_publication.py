#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Fail-closed verification for a v30.1.5 artifact and registry handoff."""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import zipfile


REPO_ROOT = Path(__file__).resolve().parents[3]
CANDIDATE_ROOT = REPO_ROOT / "contrib" / "ops" / "v30.1.5-candidate-package"
PUBLICATION_ROOT = REPO_ROOT / "contrib" / "ops" / "v30.1.5-candidate-publication"
CANDIDATE_POLICY = CANDIDATE_ROOT / "policy.json"
CANDIDATE_VERIFIER = CANDIDATE_ROOT / "verify_candidate_bundle.sh"
CANDIDATE_METADATA = REPO_ROOT / "ci" / "release" / "generate_v30_1_5_candidate_metadata.py"
EXPECTED_REPOSITORY = "Blackcoin-Dev/Blackcoin"
EXPECTED_REGISTRY_REPOSITORY = "qqblackcoin/blackcoin-v4-gui"
EXPECTED_FINGERPRINT = "SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70"
EXPECTED_CLASSIFICATION = "V30_1_5_CANDIDATE_CANARY_ONLY"
EXPECTED_PACKAGING_WORKFLOW = ".github/workflows/v30.1.5-candidate-linux.yml"
EXPECTED_PACKAGING_WORKFLOW_NAME = "v30.1.5 Linux x86_64 canary candidate"
EXPECTED_REGISTRY_HOST = "registry-1.docker.io"
EXPECTED_CREDENTIAL_HOST = "docker.io"
EXPECTED_ACTOR = "Blackcoin-Dev"
EXPECTED_ACTIONS_APP_ID = 15368
EXPECTED_MERGE_COMMITTER = "web-flow"
EXPECTED_MERGE_AUTHOR_NAME = "Blackcoin-Dev"
EXPECTED_MERGE_AUTHOR_EMAIL = "298119138+Blackcoin-Dev@users.noreply.github.com"
EXPECTED_MERGE_COMMITTER_NAME = "GitHub"
EXPECTED_MERGE_COMMITTER_EMAIL = "noreply@github.com"
EXPECTED_SIGNING_PRINCIPAL = "298119138+Blackcoin-Dev@users.noreply.github.com"
EXPECTED_SIGNING_PUBLIC_KEY = (
    "ssh-ed25519 "
    "AAAAC3NzaC1lZDI1NTE5AAAAIBPYLwGcJFN4eoPcQ1mX43s6KzIib1t3P3fpMKKQer4h"
)
EXPECTED_BINARIES = (
    "blackcoin-cli",
    "blackcoin-qt",
    "blackcoin-tx",
    "blackcoin-util",
    "blackcoin-wallet",
    "blackcoind",
)
FULL_SHA_RE = re.compile(r"[0-9a-f]{40}")
HEX64_RE = re.compile(r"[0-9a-f]{64}")
DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}")
POSITIVE_RE = re.compile(r"[1-9][0-9]*")
NONCE_RE = re.compile(r"[0-9a-f]{64}")
SAFE_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,254}")
OCI_MANIFEST_TYPES = {
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
}
OCI_CONFIG_TYPES = {
    "application/vnd.oci.image.config.v1+json",
    "application/vnd.docker.container.image.v1+json",
}
OCI_LAYER_TYPES = {
    "application/vnd.oci.image.layer.v1.tar",
    "application/vnd.oci.image.layer.v1.tar+gzip",
    "application/vnd.oci.image.layer.v1.tar+zstd",
    "application/vnd.docker.image.rootfs.diff.tar.gzip",
}
MAX_ZIP_ENTRIES = 64
MAX_GITHUB_ZIP_BYTES = 8 * 1024 * 1024 * 1024
MAX_ZIP_UNCOMPRESSED = 12 * 1024 * 1024 * 1024
MAX_JSON_BYTES = 32 * 1024 * 1024
MAX_HEADER_BYTES = 1024 * 1024
MAX_TEXT_RECEIPT_BYTES = 1024 * 1024
MAX_OCI_ENTRIES = 1024
MAX_NONCE_LEDGER_BYTES = 16 * 1024 * 1024
MAX_BINARY_BYTES = 1024 * 1024 * 1024
MAX_AUTHORITY_LIFETIME = timedelta(minutes=30)
MAX_CLOCK_SKEW = timedelta(seconds=60)
UTC_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
SAFE_SYSTEM_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
CORE_CI_EVIDENCE_KEYS = {
    "schema", "workflow_path", "workflow_name", "base_workflow_blob_sha256",
    "source_workflow_blob_sha256", "event", "repository", "head_repository",
    "pull_request_number", "pull_request_head_sha", "pull_request_base_sha", "base_tree",
    "run_id", "run_attempt", "head_sha", "head_tree", "status", "conclusion",
    "workflow_actor", "workflow_triggering_actor", "run_completed_at", "base_branch",
    "authority_state", "current_main_sha", "current_main_authority_fresh",
    "pull_request_state", "pull_request_draft", "pull_request_mergeable",
    "pull_request_mergeable_state", "pull_request_merged", "pull_request_merged_at",
    "pull_request_merged_by", "merge_commit", "exact_head_run_count",
    "branch_protection", "required_checks", "thread_sanitizer_artifact",
}
PUBLICATION_COMPLETE_NAME = "PUBLICATION_COMPLETE.json"
PUBLICATION_SUMS_NAME = "PUBLICATION_SHA256SUMS"


class VerificationError(RuntimeError):
    """The requested publication identity is not proven."""


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def reject_duplicate_pairs(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise VerificationError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def decode_json(payload, description):
    require(len(payload) <= MAX_JSON_BYTES, f"{description} exceeds the size limit")
    try:
        text = payload.decode("utf-8")
        return json.loads(text, object_pairs_hook=reject_duplicate_pairs)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"cannot parse {description}: {error}") from error


def read_regular_bytes(path, description, limit=MAX_JSON_BYTES):
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise VerificationError(f"cannot open {description} safely: {error}") from error
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode), f"{description} is not a regular file")
        require(before.st_size <= limit, f"{description} exceeds the size limit")
        with os.fdopen(descriptor, "rb", closefd=False) as source:
            payload = source.read(limit + 1)
        after = os.fstat(descriptor)
        require(
            (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
            == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns),
            f"{description} changed while reading",
        )
        require(len(payload) == before.st_size and len(payload) <= limit,
                f"{description} size changed while reading")
        return payload
    finally:
        os.close(descriptor)


def load_json(path, description):
    return decode_json(read_regular_bytes(path, description), description)


def canonical_json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def write_new_json(path, value):
    require(not path.exists() and not path.is_symlink(), f"refusing to overwrite {path}")
    path.write_bytes(canonical_json_bytes(value))
    path.chmod(0o600)


def write_new_json_durable(path, value):
    """Create a mode-0600 JSON receipt and durably commit it and its directory."""
    path = Path(path)
    require(not path.exists() and not path.is_symlink(), f"refusing to overwrite {path}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    try:
        payload = canonical_json_bytes(value)
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            require(written > 0, f"could not write {path}")
            view = view[written:]
        os.fchmod(descriptor, 0o600)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def fsync_tree(root):
    """Durably commit every regular file and directory in one evidence tree."""
    root = Path(root)
    require(root.is_absolute() and root.is_dir() and not root.is_symlink(),
            "durable evidence root is missing, relative, or unsafe")
    directories = []
    for current, names, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        directories.append(current_path)
        for name in names:
            path = current_path / name
            require(path.is_dir() and not path.is_symlink(),
                    f"durable evidence directory is unsafe: {path}")
        for name in files:
            path = current_path / name
            flags = os.O_RDONLY
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            descriptor = os.open(path, flags)
            try:
                status = os.fstat(descriptor)
                require(stat.S_ISREG(status.st_mode),
                        f"durable evidence entry is not regular: {path}")
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
    for directory in reversed(directories):
        flags = os.O_RDONLY
        if hasattr(os, "O_DIRECTORY"):
            flags |= os.O_DIRECTORY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(directory, flags)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def publication_manifest_entries(root, manifest_path):
    """Verify the pre-completion evidence ledger and return its exact entries."""
    root = Path(root)
    manifest_path = Path(manifest_path)
    require(root.is_absolute() and root.is_dir() and not root.is_symlink(),
            "publication evidence root is missing, relative, or unsafe")
    require(manifest_path == root / PUBLICATION_SUMS_NAME,
            "publication checksum ledger path is not canonical")
    payload = read_regular_bytes(
        manifest_path, "publication checksum ledger", MAX_NONCE_LEDGER_BYTES
    )
    try:
        lines = payload.decode("utf-8").splitlines()
    except UnicodeError as error:
        raise VerificationError("publication checksum ledger is not UTF-8") from error
    entries = {}
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  (\./[^\n]+)", line)
        require(match is not None, "publication checksum ledger has a malformed line")
        digest, relative_text = match.groups()
        candidate = PurePosixPath(relative_text[2:])
        require(not candidate.is_absolute()
                and all(part not in ("", ".", "..") for part in candidate.parts)
                and "\\" not in relative_text,
                "publication checksum ledger contains an unsafe path")
        relative = candidate.as_posix()
        require(relative not in entries, "publication checksum ledger contains a duplicate")
        require(relative not in {PUBLICATION_SUMS_NAME, PUBLICATION_COMPLETE_NAME},
                "publication checksum ledger contains a self/completion entry")
        entries[relative] = digest
    require(list(entries) == sorted(entries),
            "publication checksum ledger is not sorted")
    actual = set()
    for current, names, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        for name in names:
            path = current_path / name
            require(path.is_dir() and not path.is_symlink(),
                    f"publication evidence directory is unsafe: {path}")
        for name in files:
            path = current_path / name
            require(path.is_file() and not path.is_symlink(),
                    f"publication evidence entry is unsafe: {path}")
            relative = path.relative_to(root).as_posix()
            if relative not in {PUBLICATION_SUMS_NAME, PUBLICATION_COMPLETE_NAME}:
                actual.add(relative)
    require(set(entries) == actual,
            "publication checksum ledger does not cover the exact evidence file set")
    for relative, expected in entries.items():
        observed, _ = sha256_regular_file(
            root.joinpath(*PurePosixPath(relative).parts),
            f"publication evidence {relative}",
        )
        require(observed == expected,
                f"publication evidence checksum mismatch: {relative}")
    return entries


def replay_registry_result(
    root,
    result_path,
    *,
    required_uid=0,
    canonical_bundle_check=None,
    source_identity_check=None,
    packaging_snapshot_check=None,
    publication_snapshot_check=None,
):
    """Reconstruct RESULT from original evidence and require byte-exact equality."""
    root = Path(root)
    result_path = Path(result_path)
    validate_output_anchor(root, root / "OUTPUT_ANCHOR.json", required_uid=required_uid)
    observed = load_json(result_path, "publication result")
    require(isinstance(observed, dict)
            and observed.get("publication_outcome") in {
                "tag-already-exact", "copy-succeeded", "copy-error-remote-exact"
            },
            "publication result outcome is malformed")
    registry = root / "registry"
    with tempfile.TemporaryDirectory(
        prefix=".publication-result-replay-", dir=root.parent
    ) as temporary:
        replay_path = Path(temporary) / "RESULT.json"
        expected = verify_registry_evidence(
            root / "VERIFIED_INPUT.json",
            root / "request.json",
            registry / "tag-manifest.json",
            registry / "tag-manifest.headers",
            registry / "digest-manifest.json",
            registry / "digest-manifest.headers",
            registry / "registry-config.json",
            registry / "registry-config.headers",
            registry / "local-image-inspect.json",
            registry / "EXTRACTED_BINARIES.json",
            root / "NONCE_CONSUMPTION.json",
            registry / "REGISTRY_AUTHFILE.json",
            observed["publication_outcome"],
            replay_path,
            required_uid=required_uid,
            canonical_bundle_check=canonical_bundle_check,
            source_identity_check=source_identity_check,
            packaging_snapshot_check=packaging_snapshot_check,
            publication_snapshot_check=publication_snapshot_check,
        )
        require(canonical_json_bytes(observed) == canonical_json_bytes(expected)
                and read_regular_bytes(result_path, "publication result")
                == read_regular_bytes(replay_path, "replayed publication result"),
                "publication result differs from a complete evidence replay")
    return observed


def publication_completion_value(
    root,
    result_path,
    manifest_path,
    *,
    completed_utc,
    required_uid=0,
    canonical_bundle_check=None,
    source_identity_check=None,
    packaging_snapshot_check=None,
    publication_snapshot_check=None,
):
    validate_output_anchor(
        Path(root), Path(root) / "OUTPUT_ANCHOR.json", required_uid=required_uid
    )
    entries = publication_manifest_entries(root, manifest_path)
    result_path = Path(result_path)
    require(result_path == Path(root) / "registry" / "RESULT.json",
            "publication result path is not canonical")
    result = replay_registry_result(
        root,
        result_path,
        required_uid=required_uid,
        canonical_bundle_check=canonical_bundle_check,
        source_identity_check=source_identity_check,
        packaging_snapshot_check=packaging_snapshot_check,
        publication_snapshot_check=publication_snapshot_check,
    )
    require(type(result.get("schema")) is int and result["schema"] == 2
            and result.get("result") == "passed",
            "publication result is not terminal-pass")
    immutable = result.get("immutable_image_ref")
    manifest_digest = result.get("registry_manifest_digest")
    require(isinstance(immutable, str)
            and immutable == f"{EXPECTED_REGISTRY_REPOSITORY}@{manifest_digest}"
            and is_digest(manifest_digest),
            "publication result immutable identity is malformed")
    require(result.get("handoff", {}).get("registry", {}).get("manifest_digest")
            == manifest_digest,
            "publication result handoff manifest changed")
    core = result["core_ci_evidence"]
    validate_core_ci_evidence_shape(core, source=result["source"], require_merged=True)
    completed = parse_utc(completed_utc, "publication completion timestamp")
    consumed = parse_utc(
        result["nonce_consumption"]["record"]["consumed_utc"],
        "publication nonce-consumption timestamp",
    )
    require(completed >= consumed,
            "publication completion predates nonce consumption")
    handoff = result["handoff"]
    packaging = result["packaging"]
    artifact = result["artifact"]
    publication_tooling = result["publication_tooling"]
    registry = result["registry"]
    nonce_receipt_path = Path(root) / "NONCE_CONSUMPTION.json"
    require(nonce_receipt_path.is_file() and not nonce_receipt_path.is_symlink(),
            "nonce-consumption receipt is absent or unsafe")
    copy_fields = {
        "copy_attempted": result["copy_attempted"],
        "copy_exit_success": result["copy_exit_success"],
        "published_by_this_operation": result["published_by_this_operation"],
    }
    expected_copy_fields = {
        "tag-already-exact": {
            "copy_attempted": False,
            "copy_exit_success": None,
            "published_by_this_operation": False,
        },
        "copy-succeeded": {
            "copy_attempted": True,
            "copy_exit_success": True,
            "published_by_this_operation": True,
        },
        "copy-error-remote-exact": {
            "copy_attempted": True,
            "copy_exit_success": False,
            "published_by_this_operation": None,
        },
    }
    expected_copy = expected_copy_fields.get(result["publication_outcome"])
    require(expected_copy is not None
            and copy_fields["copy_attempted"] is expected_copy["copy_attempted"]
            and copy_fields["copy_exit_success"] is expected_copy["copy_exit_success"]
            and copy_fields["published_by_this_operation"]
            is expected_copy["published_by_this_operation"],
            "publication copy-state truth changed")
    verification_fields = {
        "digest_refetch_verified": result["digest_refetch_verified"],
        "remote_config_bytes_verified": result["remote_config_bytes_verified"],
        "remote_exact_equality_verified": result["remote_exact_equality_verified"],
        "same_response_digest_verified": result["same_response_digest_verified"],
        "source_manifest_exact_equality_verified": (
            result["source_manifest_exact_equality_verified"]
        ),
    }
    require(all(value is True for value in verification_fields.values())
            and result["candidate_container_started"] is False,
            "publication verification is incomplete")
    return {
        "action": "complete-v30.1.5-candidate-publication",
        "artifact": {
            "api_metadata_sha256": artifact["api_metadata_sha256"],
            "bundle_sha256sums_sha256": result["bundle"]["sha256sums_sha256"],
            "id": artifact["id"],
            "name": artifact["name"],
            "zip_sha256": artifact["zip_sha256"],
        },
        "authorization": {
            "exclusive_writer_authority_sha256": (
                handoff["authorization"]["exclusive_writer_authority_sha256"]
            ),
            "nonce": handoff["authorization"]["nonce"],
            "nonce_consumption_sha256": sha256_file(nonce_receipt_path),
            "nonce_ledger_record_sha256": (
                handoff["authorization"]["nonce_ledger_record_sha256"]
            ),
        },
        "completed_utc": completed_utc,
        "core_ci": {
            "authority_state": core["authority_state"],
            "current_main_sha": core["current_main_sha"],
            "evidence_sha256": result["core_ci"]["evidence_sha256"],
            "merge_commit_sha": core["merge_commit"]["sha"],
            "pull_request_merged_at": core["pull_request_merged_at"],
            "run_attempt": core["run_attempt"],
            "run_completed_at": core["run_completed_at"],
            "run_id": core["run_id"],
        },
        "evidence_manifest": {
            "covered_file_count": len(entries),
            "path": PUBLICATION_SUMS_NAME,
            "sha256": sha256_file(manifest_path),
        },
        "handoff_sha256": canonical_subset_sha256(handoff),
        "packaging": {
            "package_sha256sums_sha256": packaging["package_sha256sums_sha256"],
            "run_attempt": packaging["run_attempt"],
            "run_id": packaging["run_id"],
            "run_metadata_sha256": packaging["run_metadata_sha256"],
            "tooling_commit": packaging["tooling_commit"],
            "tooling_tree": packaging["tooling_tree"],
        },
        "publication": {
            "candidate_container_started": False,
            **copy_fields,
            **verification_fields,
            "outcome": result["publication_outcome"],
        },
        "publication_authority_sha256": result["publication_authority_sha256"],
        "publication_tooling": {
            "commit": publication_tooling["commit"],
            "package_sha256sums_sha256": (
                publication_tooling["package_sha256sums_sha256"]
            ),
            "tree": publication_tooling["tree"],
        },
        "registry": {
            "config_digest": result["registry_config_digest"],
            "credential_host": registry["credential_host"],
            "host": registry["host"],
            "immutable_image_ref": immutable,
            "manifest_digest": manifest_digest,
            "registry_immutable_image_ref": result["registry_immutable_image_ref"],
            "repository": registry["repository"],
            "tag": registry["tag"],
        },
        "request_sha256": result["request_sha256"],
        "result": {
            "path": "registry/RESULT.json",
            "sha256": sha256_file(result_path),
        },
        "schema": 1,
        "source": {
            "commit": result["source"]["commit"],
            "tree": result["source"]["tree"],
        },
        "status": "complete",
    }


def create_publication_completion(
    root,
    result_path,
    manifest_path,
    output,
    *,
    required_uid=0,
    canonical_bundle_check=None,
    source_identity_check=None,
    packaging_snapshot_check=None,
    publication_snapshot_check=None,
):
    root = Path(root)
    output = Path(output)
    require(output == root / PUBLICATION_COMPLETE_NAME,
            "publication completion path is not canonical")
    completed_utc = datetime.now(timezone.utc).replace(microsecond=0).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    value = publication_completion_value(
        root,
        result_path,
        manifest_path,
        completed_utc=completed_utc,
        required_uid=required_uid,
        canonical_bundle_check=canonical_bundle_check,
        source_identity_check=source_identity_check,
        packaging_snapshot_check=packaging_snapshot_check,
        publication_snapshot_check=publication_snapshot_check,
    )
    write_new_json_durable(output, value)
    return value


def validate_publication_completion(
    root,
    completion_path,
    *,
    required_uid=0,
    canonical_bundle_check=None,
    source_identity_check=None,
    packaging_snapshot_check=None,
    publication_snapshot_check=None,
):
    root = Path(root)
    completion_path = Path(completion_path)
    require(completion_path == root / PUBLICATION_COMPLETE_NAME,
            "publication completion path is not canonical")
    validate_output_anchor(root, root / "OUTPUT_ANCHOR.json", required_uid=required_uid)
    completion_status = os.lstat(completion_path)
    require(stat.S_ISREG(completion_status.st_mode)
            and completion_status.st_uid == required_uid
            and stat.S_IMODE(completion_status.st_mode) == 0o600
            and completion_status.st_nlink == 1,
            "publication completion receipt ownership or mode changed")
    value = load_json(completion_path, "publication completion receipt")
    exact_keys(
        value,
        {"action", "artifact", "authorization", "completed_utc", "core_ci",
         "evidence_manifest", "handoff_sha256", "packaging", "publication",
         "publication_authority_sha256", "publication_tooling", "registry",
         "request_sha256", "result", "schema", "source", "status"},
        "publication completion receipt",
    )
    expected = publication_completion_value(
        root, root / "registry" / "RESULT.json", root / PUBLICATION_SUMS_NAME,
        completed_utc=value["completed_utc"],
        required_uid=required_uid,
        canonical_bundle_check=canonical_bundle_check,
        source_identity_check=source_identity_check,
        packaging_snapshot_check=packaging_snapshot_check,
        publication_snapshot_check=publication_snapshot_check,
    )
    require(canonical_json_bytes(value) == canonical_json_bytes(expected),
            "publication completion receipt changed")
    return value


def sha256_bytes(payload):
    return hashlib.sha256(payload).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_stream(source):
    digest = hashlib.sha256()
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(chunk)
    return digest.hexdigest()


def sha256_regular_file(path, description, max_size=None):
    """Hash one stable regular file without following a terminal symlink."""
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise VerificationError(f"cannot open {description} safely: {error}") from error
    digest = hashlib.sha256()
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode), f"{description} is not a regular file")
        if max_size is not None:
            require(before.st_size <= max_size, f"{description} exceeds the size limit")
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(descriptor)
        require(
            (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
            == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns),
            f"{description} changed while hashing",
        )
        return digest.hexdigest(), before
    finally:
        os.close(descriptor)


def exact_keys(value, expected, description):
    require(isinstance(value, dict), f"{description} must be an object")
    require(set(value) == set(expected), f"{description} has unexpected or missing fields")


def validate_core_ci_evidence_shape(value, *, source=None, require_merged=False):
    """Require the exact terminal Core-CI schema before projecting its receipt."""
    exact_keys(value, CORE_CI_EVIDENCE_KEYS, "Core CI evidence")
    require(type(value["schema"]) is int and value["schema"] == 3,
            "Core CI evidence schema is not supported")
    require(type(value["run_id"]) is int and value["run_id"] > 0
            and type(value["run_attempt"]) is int and value["run_attempt"] > 0,
            "Core CI run identity is malformed")
    require(value["status"] == "completed" and value["conclusion"] == "success",
            "Core CI evidence is not terminal-success")
    require(value["event"] == "pull_request"
            and value["repository"] == EXPECTED_REPOSITORY
            and value["head_repository"] == EXPECTED_REPOSITORY
            and value["base_branch"] == "main"
            and value["workflow_actor"] == EXPECTED_ACTOR
            and value["workflow_triggering_actor"] == EXPECTED_ACTOR,
            "Core CI workflow authority changed")
    if source is not None:
        require(value["pull_request_head_sha"] == source["commit"]
                and value["head_sha"] == source["commit"]
                and value["head_tree"] == source["tree"],
                "Core CI source H/T changed")
    require(value["pull_request_head_sha"] == value["head_sha"],
            "Core CI pull-request head and run head differ")
    run_completed = parse_utc(value["run_completed_at"], "Core CI completion timestamp")
    require(value["current_main_authority_fresh"] is True,
            "Core CI current-main authority is not fresh")
    require(type(value["exact_head_run_count"]) is int
            and value["exact_head_run_count"] == 1,
            "Core CI exact-head run is not unique")
    require(value["authority_state"] in {"open", "merged"},
            "Core CI authority state is not supported")
    if require_merged:
        require(value["authority_state"] == "merged",
                "live publication requires terminal merged Core authority")
    if value["authority_state"] == "open":
        require(value["pull_request_state"] == "open"
                and value["pull_request_draft"] is False
                and value["pull_request_mergeable"] is True
                and value["pull_request_mergeable_state"] == "clean"
                and value["pull_request_merged"] is False
                and value["pull_request_merged_at"] is None
                and value["pull_request_merged_by"] is None
                and value["merge_commit"] is None
                and value["current_main_sha"] == value["pull_request_base_sha"],
                "open Core CI authority contains terminal merge state")
    else:
        merged_at = parse_utc(value["pull_request_merged_at"], "Core PR merge timestamp")
        require(value["pull_request_state"] == "closed"
                and value["pull_request_draft"] is False
                and value["pull_request_mergeable"] is None
                and value["pull_request_mergeable_state"] == "unknown"
                and value["pull_request_merged"] is True
                and value["pull_request_merged_by"] == EXPECTED_ACTOR
                and isinstance(value["merge_commit"], dict),
                "merged Core CI authority is incomplete")
        require(run_completed < merged_at,
                "Core PR merged before the exact successful run completed")
        merge = value["merge_commit"]
        exact_keys(
            merge,
            {"sha", "tree", "parents", "github_verified", "github_verification_reason",
             "author_login", "committer_login", "author", "committer"},
            "Core merge-commit evidence",
        )
        require(is_full_sha(merge["sha"])
                and value["current_main_sha"] == merge["sha"]
                and merge["tree"] == value["head_tree"]
                and merge["parents"] == [value["pull_request_base_sha"], value["head_sha"]],
                "Core merge identity, tree, or parent order changed")
        require(merge["github_verified"] is True
                and merge["github_verification_reason"] == "valid"
                and merge["author_login"] == EXPECTED_ACTOR
                and merge["committer_login"] == EXPECTED_MERGE_COMMITTER,
                "Core merge signature identity changed")
        exact_keys(merge["author"], {"name", "email", "date"}, "Core merge author")
        exact_keys(merge["committer"], {"name", "email", "date"}, "Core merge committer")
        require(merge["author"] == {
                    "name": EXPECTED_MERGE_AUTHOR_NAME,
                    "email": EXPECTED_MERGE_AUTHOR_EMAIL,
                    "date": value["pull_request_merged_at"],
                }
                and merge["committer"] == {
                    "name": EXPECTED_MERGE_COMMITTER_NAME,
                    "email": EXPECTED_MERGE_COMMITTER_EMAIL,
                    "date": value["pull_request_merged_at"],
                },
                "Core merge author or committer changed")
    protection = value["branch_protection"]
    exact_keys(protection, {"enabled", "enforcement_level", "contexts", "checks"},
               "Core branch-protection evidence")
    require(protection["enabled"] is True and protection["enforcement_level"] == "everyone",
            "Core branch protection is not fully enforced")
    contexts = protection["contexts"]
    protected = protection["checks"]
    checks = value["required_checks"]
    require(isinstance(contexts, list) and len(contexts) == 16
            and len(contexts) == len(set(contexts))
            and isinstance(protected, list) and len(protected) == len(contexts)
            and isinstance(checks, list) and len(checks) == len(contexts),
            "Core protected check inventory changed")
    check_ids = set()
    for name, protected_check, check in zip(contexts, protected, checks):
        require(isinstance(name, str) and name,
                "Core protected context name is malformed")
        exact_keys(protected_check, {"context", "app_id"}, "Core protected check")
        exact_keys(check, {"id", "name", "app_id", "status", "conclusion"},
                   "Core required check")
        require(protected_check == {"context": name, "app_id": EXPECTED_ACTIONS_APP_ID}
                and check["name"] == name
                and type(check["id"]) is int and check["id"] > 0
                and check["id"] not in check_ids
                and type(check["app_id"]) is int
                and check["app_id"] == EXPECTED_ACTIONS_APP_ID
                and check["status"] == "completed" and check["conclusion"] == "success",
                "Core required/protected check changed")
        check_ids.add(check["id"])
    sanitizer = value["thread_sanitizer_artifact"]
    exact_keys(
        sanitizer,
        {"id", "name", "size_in_bytes", "expired", "api_digest", "zip_sha256",
         "reports_sha256", "report"},
        "Core ThreadSanitizer artifact",
    )
    require(type(sanitizer["id"]) is int and sanitizer["id"] > 0
            and type(sanitizer["size_in_bytes"]) is int and sanitizer["size_in_bytes"] > 0
            and sanitizer["expired"] is False
            and sanitizer["api_digest"] == f"sha256:{sanitizer['zip_sha256']}"
            and is_hex64(sanitizer["zip_sha256"])
            and is_hex64(sanitizer["reports_sha256"]),
            "Core ThreadSanitizer artifact changed")
    report = sanitizer["report"]
    exact_keys(
        report,
        {"target_sha", "sanitizer", "report_count", "report_bytes",
         "framing_error_count", "collector_error_count", "artifact_error",
         "capture_complete"},
        "Core ThreadSanitizer report",
    )
    require(report["target_sha"] == value["head_sha"]
            and report["sanitizer"] == "thread-sanitizer",
            "Core ThreadSanitizer report target changed")
    for field in ("report_count", "report_bytes", "framing_error_count",
                  "collector_error_count", "artifact_error"):
        require(type(report[field]) is int and report[field] == 0,
                f"Core ThreadSanitizer report is not clean: {field}")
    require(type(report["capture_complete"]) is int and report["capture_complete"] == 1,
            "Core ThreadSanitizer capture is incomplete")
    return value


def absolute_path(value, description):
    require(isinstance(value, str) and value.startswith("/"), f"{description} must be absolute")
    path = Path(value)
    require(".." not in path.parts, f"{description} contains a parent traversal")
    return path


def secure_subprocess_environment(*, git=False):
    """Return the complete environment allowed across a subprocess boundary."""
    environment = {
        "HOME": "/var/empty",
        "LC_ALL": "C",
        "PATH": SAFE_SYSTEM_PATH,
        "PYTHONNOUSERSITE": "1",
        "TZ": "UTC",
        "XDG_CONFIG_HOME": "/var/empty",
    }
    if git:
        environment.update({
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_NO_REPLACE_OBJECTS": "1",
        })
    return environment


def protected_parent_chain(path, required_uid=0, *, final_mode=None):
    """Bind every real directory from / through one path's parent."""
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts,
            "protected path is not a safe absolute path")
    parent = path.parent
    entries = []
    current = Path("/")
    components = [current]
    for part in parent.parts[1:]:
        current /= part
        components.append(current)
    for index, directory in enumerate(components):
        try:
            before = os.lstat(directory)
            after = os.lstat(directory)
        except OSError as error:
            raise VerificationError(
                f"cannot inspect protected path ancestor: {directory}"
            ) from error
        identity = ("st_dev", "st_ino", "st_mode", "st_uid", "st_gid", "st_ctime_ns")
        require(all(getattr(before, field) == getattr(after, field) for field in identity),
                f"protected path ancestor changed: {directory}")
        require(stat.S_ISDIR(before.st_mode) and not stat.S_ISLNK(before.st_mode),
                f"protected path ancestor is not a real directory: {directory}")
        owner_ok = before.st_uid in {0, required_uid}
        mode_ok = stat.S_IMODE(before.st_mode) & 0o022 == 0
        # Non-root unit fixtures may live below a root-owned sticky temporary
        # directory. The production contract uses required_uid=0 and therefore
        # never takes this fixture-only allowance.
        if required_uid != 0 and before.st_uid == 0 and before.st_mode & stat.S_ISVTX:
            mode_ok = True
        require(owner_ok and mode_ok,
                f"protected path ancestor is not required-owner/non-writable: {directory}")
        if final_mode is not None and index == len(components) - 1:
            require(stat.S_IMODE(before.st_mode) == final_mode,
                    f"protected path parent mode is not {final_mode:04o}")
        entries.append((str(directory), before.st_dev, before.st_ino,
                        before.st_uid, before.st_gid, stat.S_IMODE(before.st_mode)))
    return tuple(entries)


def trusted_system_tool(name, *, required_uid=0):
    """Resolve a system tool to stable root-owned, non-writable bytes."""
    selected = shutil.which(name, path=SAFE_SYSTEM_PATH)
    require(selected is not None and Path(selected).is_absolute(),
            f"required system tool is unavailable: {name}")
    path = Path(selected)
    seen = set()
    for _ in range(32):
        require(path not in seen, f"system tool symlink loop: {name}")
        seen.add(path)
        protected_parent_chain(path, required_uid)
        try:
            before = os.lstat(path)
        except OSError as error:
            raise VerificationError(f"cannot inspect system tool safely: {name}") from error
        if not stat.S_ISLNK(before.st_mode):
            break
        require(before.st_uid == required_uid,
                f"system tool symlink is not required-owner: {name}")
        try:
            target = os.readlink(path)
            after = os.lstat(path)
        except OSError as error:
            raise VerificationError(f"cannot resolve system tool safely: {name}") from error
        require(
            (before.st_dev, before.st_ino, before.st_uid, before.st_gid,
             before.st_size, before.st_mtime_ns, before.st_ctime_ns)
            == (after.st_dev, after.st_ino, after.st_uid, after.st_gid,
                after.st_size, after.st_mtime_ns, after.st_ctime_ns),
            f"system tool symlink changed while resolving: {name}",
        )
        path = Path(target) if target.startswith("/") else path.parent / target
        path = Path(os.path.normpath(path))
        require(path.is_absolute() and ".." not in path.parts,
                f"system tool resolved to an unsafe path: {name}")
    else:
        raise VerificationError(f"system tool symlink depth exceeded: {name}")
    require(str(path).startswith(("/bin/", "/sbin/", "/usr/")),
            f"system tool resolved outside approved roots: {name}")
    protected_parent_chain(path, required_uid)
    try:
        before = os.stat(path, follow_symlinks=False)
        after = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise VerificationError(f"cannot stat system tool safely: {name}") from error
    stable = ("st_dev", "st_ino", "st_mode", "st_uid", "st_gid", "st_size",
              "st_mtime_ns", "st_ctime_ns")
    require(all(getattr(before, field) == getattr(after, field) for field in stable),
            f"system tool changed while resolving: {name}")
    require(stat.S_ISREG(before.st_mode) and before.st_uid == required_uid
            and stat.S_IMODE(before.st_mode) & 0o022 == 0,
            f"system tool is not root-owned immutable regular bytes: {name}")
    return str(path)


def expected_artifact_name(source, attempt):
    return f"v30.1.5-candidate-linux-x86_64-{source}-attempt-{attempt}"


def expected_registry_tag(source, run_id, attempt):
    return f"30.1.5-candidate-{source[:12]}-gha{run_id}-a{attempt}-pub1"


def is_full_sha(value):
    return isinstance(value, str) and FULL_SHA_RE.fullmatch(value) is not None


def is_hex64(value):
    return isinstance(value, str) and HEX64_RE.fullmatch(value) is not None


def is_digest(value):
    return isinstance(value, str) and DIGEST_RE.fullmatch(value) is not None


def parse_utc(value, description):
    require(isinstance(value, str) and UTC_RE.fullmatch(value) is not None,
            f"{description} is not canonical UTC")
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError as error:
        raise VerificationError(f"{description} is invalid") from error
    require(parsed.strftime("%Y-%m-%dT%H:%M:%SZ") == value,
            f"{description} is not canonical UTC")
    return parsed


def canonical_subset_sha256(value):
    return sha256_bytes(canonical_json_bytes(value))


def publication_authority_value(value):
    """Return the complete path-independent identity an operator authorizes."""
    artifact = value["artifact"]
    packaging = value["packaging"]
    execution = value["execution"]
    return {
        "schema": 3,
        "action": "publish-v30.1.5-candidate",
        "source": value["source"],
        "core_ci": value["core_ci"],
        "packaging": {
            key: item for key, item in packaging.items() if key != "run_metadata_path"
        },
        "artifact": {
            key: item for key, item in artifact.items()
            if key not in {"api_metadata_path", "github_zip_path"}
        },
        "publication_tooling": value["publication_tooling"],
        "oci": value["oci"],
        "registry": value["registry"],
        "execution": {
            "execute": execution["execute"],
            "dispatch_enabled": execution["dispatch_enabled"],
            "exclusive_tag_writer": execution["exclusive_tag_writer"],
            "exclusive_writer_authority_sha256": execution["exclusive_writer_authority_sha256"],
            "nonce": execution["nonce"],
            "issued_utc": execution["issued_utc"],
            "expires_utc": execution["expires_utc"],
            "nonce_ledger_path": execution["nonce_ledger_path"],
        },
    }


def publication_authority_sha256(value):
    return canonical_subset_sha256(publication_authority_value(value))


# Compatibility names retained for consumers of the schema-2 helper API. The
# value is now the complete schema-3 authority, not the former partial intent.
publication_intent_value = publication_authority_value
publication_intent_sha256 = publication_authority_sha256


def expected_live_confirmation(value, nonce):
    return (
        f"PUBLISH_V30_1_5_CANDIDATE:{value['source']['commit']}:"
        f"{publication_authority_sha256(value)}:{nonce}"
    )


def validate_request_value(value, *, enforce_time=True, now=None):
    exact_keys(
        value,
        {
            "schema", "source", "core_ci", "packaging", "artifact",
            "publication_tooling", "oci", "registry", "execution",
        },
        "request",
    )
    require(type(value["schema"]) is int and value["schema"] == 3,
            "request schema is not supported")

    source = value["source"]
    exact_keys(source, {"repository", "commit", "tree", "signing_fingerprint"}, "source request")
    require(source["repository"] == EXPECTED_REPOSITORY, "source repository changed")
    require(is_full_sha(source["commit"]) and is_full_sha(source["tree"]), "source H/T is malformed")
    require(source["signing_fingerprint"] == EXPECTED_FINGERPRINT,
            "source signing fingerprint changed")

    core = value["core_ci"]
    exact_keys(
        core,
        {
            "workflow_path", "run_id", "run_attempt", "evidence_sha256",
            "required_checks_sha256", "thread_sanitizer_artifact",
        },
        "Core CI request",
    )
    require(core["workflow_path"] == ".github/workflows/pr-gate.yml",
            "Core CI workflow path changed")
    for key in ("run_id", "run_attempt"):
        require(type(core[key]) is int and core[key] > 0, f"Core CI {key} is malformed")
    require(is_hex64(core["evidence_sha256"]) and is_hex64(core["required_checks_sha256"]),
            "Core CI receipt digest is malformed")
    sanitizer = core["thread_sanitizer_artifact"]
    exact_keys(
        sanitizer,
        {"id", "name", "api_digest", "zip_sha256", "reports_sha256"},
        "Core CI ThreadSanitizer artifact request",
    )
    require(type(sanitizer["id"]) is int and sanitizer["id"] > 0,
            "ThreadSanitizer artifact ID is malformed")
    require(
        sanitizer["name"] == (
            f"sanitizer-reports-thread-sanitizer-{source['commit']}-attempt-{core['run_attempt']}"
        ),
        "ThreadSanitizer artifact name changed",
    )
    require(is_hex64(sanitizer["zip_sha256"]) and is_hex64(sanitizer["reports_sha256"]),
            "ThreadSanitizer artifact digest is malformed")
    require(sanitizer["api_digest"] == f"sha256:{sanitizer['zip_sha256']}",
            "ThreadSanitizer API digest changed")

    packaging = value["packaging"]
    exact_keys(
        packaging,
        {
            "tooling_commit", "tooling_tree", "package_sha256sums_sha256",
            "workflow_path", "workflow_name", "run_id", "run_attempt",
            "run_metadata_path", "run_metadata_sha256",
        },
        "packaging request",
    )
    require(is_full_sha(packaging["tooling_commit"]) and is_full_sha(packaging["tooling_tree"]),
            "packaging tooling H/T is malformed")
    require(is_hex64(packaging["package_sha256sums_sha256"])
            and is_hex64(packaging["run_metadata_sha256"]),
            "packaging receipt digest is malformed")
    require(packaging["workflow_path"] == EXPECTED_PACKAGING_WORKFLOW
            and packaging["workflow_name"] == EXPECTED_PACKAGING_WORKFLOW_NAME,
            "packaging workflow identity changed")
    for key in ("run_id", "run_attempt"):
        require(type(packaging[key]) is int and packaging[key] > 0,
                f"packaging {key} is malformed")
    absolute_path(packaging["run_metadata_path"], "packaging run metadata path")

    artifact = value["artifact"]
    exact_keys(
        artifact,
        {
            "id", "name", "api_metadata_path", "api_metadata_sha256",
            "github_zip_path", "github_zip_sha256", "bundle_sha256sums_sha256",
        },
        "artifact request",
    )
    require(type(artifact["id"]) is int and artifact["id"] > 0,
            "artifact ID is malformed")
    require(
        artifact["name"] == expected_artifact_name(source["commit"], packaging["run_attempt"]),
        "artifact name is not exact-H/attempt scoped",
    )
    absolute_path(artifact["api_metadata_path"], "artifact API metadata path")
    absolute_path(artifact["github_zip_path"], "GitHub artifact ZIP path")
    for key in ("api_metadata_sha256", "github_zip_sha256", "bundle_sha256sums_sha256"):
        require(is_hex64(artifact[key]), f"artifact {key} is malformed")

    publication = value["publication_tooling"]
    exact_keys(publication, {"commit", "tree", "package_sha256sums_sha256"},
               "publication tooling request")
    require(is_full_sha(publication["commit"]) and is_full_sha(publication["tree"]),
            "publication tooling H/T is malformed")
    require(is_hex64(publication["package_sha256sums_sha256"]),
            "publication tooling package seal is malformed")

    oci = value["oci"]
    exact_keys(
        oci,
        {"archive_sha256", "manifest_digest", "config_digest", "layers", "rootfs_diff_ids", "binaries"},
        "OCI request",
    )
    require(is_hex64(oci["archive_sha256"]), "OCI archive digest is malformed")
    require(is_digest(oci["manifest_digest"]) and is_digest(oci["config_digest"]),
            "OCI manifest/config digest is malformed")
    require(isinstance(oci["layers"], list) and oci["layers"], "OCI layer list is empty")
    layer_digests = set()
    for layer in oci["layers"]:
        exact_keys(layer, {"mediaType", "digest", "size"}, "OCI layer request")
        require(layer["mediaType"] in OCI_LAYER_TYPES and is_digest(layer["digest"]),
                "OCI layer identity is malformed")
        require(type(layer["size"]) is int and layer["size"] >= 0,
                "OCI layer size is malformed")
        require(layer["digest"] not in layer_digests, "OCI layer digest is duplicated")
        layer_digests.add(layer["digest"])
    require(isinstance(oci["rootfs_diff_ids"], list)
            and len(oci["rootfs_diff_ids"]) == len(oci["layers"])
            and all(is_digest(item) for item in oci["rootfs_diff_ids"]),
            "OCI rootfs diff-ID list is malformed")
    binaries = oci["binaries"]
    require(isinstance(binaries, dict) and set(binaries) == set(EXPECTED_BINARIES),
            "OCI binary inventory changed")
    require(all(is_hex64(digest) for digest in binaries.values()),
            "OCI binary digest is malformed")

    registry = value["registry"]
    exact_keys(
        registry,
        {"host", "credential_host", "repository", "tag", "authfile_path"},
        "registry request",
    )
    require(registry["host"] == EXPECTED_REGISTRY_HOST, "registry host changed")
    require(registry["credential_host"] == EXPECTED_CREDENTIAL_HOST,
            "registry credential host changed")
    require(registry["repository"] == EXPECTED_REGISTRY_REPOSITORY,
            "registry repository is not the reviewed Blackcoin repository")
    absolute_path(registry["authfile_path"], "registry authfile path")
    expected_tag = expected_registry_tag(source["commit"], packaging["run_id"], packaging["run_attempt"])
    require(registry["tag"] == expected_tag, "registry tag is not exact-H/run/attempt scoped")
    require(registry["tag"] != "latest" and ":" not in registry["tag"] and "@" not in registry["tag"],
            "registry tag is mutable-only or malformed")

    execution = value["execution"]
    exact_keys(
        execution,
        {
            "execute", "dispatch_enabled", "exclusive_tag_writer",
            "exclusive_writer_authority_path", "exclusive_writer_authority_sha256",
            "nonce", "issued_utc", "expires_utc", "nonce_ledger_path", "confirmation",
        },
        "execution request",
    )
    for key in ("execute", "dispatch_enabled", "exclusive_tag_writer"):
        require(isinstance(execution[key], bool), f"execution {key} must be boolean")
    if execution["execute"]:
        require(execution["dispatch_enabled"] is True, "live execution lacks dispatch clearance")
        require(execution["exclusive_tag_writer"] is True,
                "exclusive tag-writer authority is absent")
        nonce = execution["nonce"]
        require(isinstance(nonce, str) and NONCE_RE.fullmatch(nonce) is not None,
                "live execution nonce is not 32-byte hex")
        absolute_path(execution["exclusive_writer_authority_path"],
                      "exclusive-writer authority path")
        require(is_hex64(execution["exclusive_writer_authority_sha256"]),
                "exclusive-writer authority digest is malformed")
        absolute_path(execution["nonce_ledger_path"], "nonce ledger path")
        issued = parse_utc(execution["issued_utc"], "authority issued time")
        expires = parse_utc(execution["expires_utc"], "authority expiry time")
        require(issued < expires and expires - issued <= MAX_AUTHORITY_LIFETIME,
                "authority lifetime is invalid")
        if enforce_time:
            current = now if now is not None else datetime.now(timezone.utc)
            require(current.tzinfo is not None, "current time lacks a timezone")
            current = current.astimezone(timezone.utc)
            require(issued - MAX_CLOCK_SKEW <= current <= expires,
                    "live authority is not currently valid")
        require(execution["confirmation"] == expected_live_confirmation(value, nonce),
                "live confirmation is not exact")
    else:
        require(
            execution == {
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
            },
            "disabled execution request is partially armed",
        )
    return value


def load_request(path, *, enforce_time=True, now=None):
    return load_request_with_sha(path, enforce_time=enforce_time, now=now)[0]


def load_request_with_sha(path, *, enforce_time=True, now=None):
    payload = read_regular_bytes(path, "publication request")
    return (
        validate_request_value(
            decode_json(payload, "publication request"), enforce_time=enforce_time, now=now
        ),
        sha256_bytes(payload),
    )


def copy_regular_file(source_path, destination, expected_sha=None, max_size=None):
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(source_path, flags)
    except OSError as error:
        raise VerificationError(f"cannot open input safely: {source_path}: {error}") from error
    digest = hashlib.sha256()
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode), f"input is not a regular file: {source_path}")
        if max_size is not None:
            require(before.st_size <= max_size, f"input exceeds the size limit: {source_path}")
        with os.fdopen(descriptor, "rb", closefd=False) as source, destination.open("xb") as target:
            copied = 0
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                copied += len(chunk)
                if max_size is not None:
                    require(copied <= max_size, f"input exceeds the size limit: {source_path}")
                digest.update(chunk)
                target.write(chunk)
            target.flush()
            os.fsync(target.fileno())
        after = os.fstat(descriptor)
        require(
            (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
            == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns),
            f"input changed while copying: {source_path}",
        )
    finally:
        os.close(descriptor)
    destination.chmod(0o600)
    observed = digest.hexdigest()
    if expected_sha is not None:
        require(observed == expected_sha, f"input digest changed: {source_path}")
    return observed, before.st_size


def validate_github_metadata(path, request, zip_sha, zip_size):
    metadata = load_json(path, "GitHub artifact API metadata")
    require(isinstance(metadata, dict), "GitHub artifact API metadata must be an object")
    artifact = request["artifact"]
    source = request["source"]
    packaging = request["packaging"]
    require(isinstance(metadata.get("id"), int) and not isinstance(metadata["id"], bool),
            "GitHub artifact ID is malformed")
    require(metadata.get("id") == artifact["id"], "GitHub artifact ID changed")
    require(metadata.get("name") == artifact["name"], "GitHub artifact name changed")
    require(metadata.get("expired") is False, "GitHub artifact is expired")
    require(isinstance(metadata.get("size_in_bytes"), int)
            and not isinstance(metadata["size_in_bytes"], bool)
            and metadata["size_in_bytes"] >= 0, "GitHub artifact ZIP size is malformed")
    require(metadata.get("size_in_bytes") == zip_size, "GitHub artifact ZIP size changed")
    require(metadata.get("digest") == f"sha256:{zip_sha}", "GitHub API ZIP digest changed")
    api_base = f"https://api.github.com/repos/{source['repository']}/actions/artifacts/{artifact['id']}"
    require(metadata.get("url") == api_base, "GitHub artifact API URL changed")
    require(metadata.get("archive_download_url") == f"{api_base}/zip", "GitHub artifact ZIP URL changed")
    workflow_run = metadata.get("workflow_run")
    require(isinstance(workflow_run, dict), "GitHub artifact workflow-run receipt is missing")
    require(isinstance(workflow_run.get("id"), int) and not isinstance(workflow_run["id"], bool),
            "GitHub artifact workflow-run ID is malformed")
    require(workflow_run.get("id") == packaging["run_id"], "artifact packaging run changed")
    require(
        workflow_run.get("head_sha") == packaging["tooling_commit"],
        "artifact workflow head is not the packaging tooling commit",
    )
    return metadata


def validate_packaging_run(path, request):
    run = load_json(path, "packaging workflow-run metadata")
    require(isinstance(run, dict), "packaging workflow-run metadata must be an object")
    source = request["source"]
    packaging = request["packaging"]
    require(type(run.get("id")) is int and run["id"] == packaging["run_id"],
            "packaging run ID changed")
    require(type(run.get("run_attempt")) is int
            and run["run_attempt"] == packaging["run_attempt"],
            "packaging run attempt changed")
    require(run.get("path") == packaging["workflow_path"]
            and run.get("name") == packaging["workflow_name"],
            "packaging workflow identity changed")
    require(run.get("event") == "workflow_dispatch", "packaging run event changed")
    require(run.get("head_sha") == packaging["tooling_commit"],
            "packaging run tooling commit changed")
    head_commit = run.get("head_commit")
    require(isinstance(head_commit, dict)
            and head_commit.get("id") == packaging["tooling_commit"]
            and head_commit.get("tree_id") == packaging["tooling_tree"],
            "packaging run tooling H/T receipt changed")
    repository = run.get("repository")
    head_repository = run.get("head_repository")
    require(isinstance(repository, dict) and repository.get("full_name") == source["repository"],
            "packaging run repository changed")
    require(isinstance(head_repository, dict)
            and head_repository.get("full_name") == source["repository"],
            "packaging run head repository changed")
    actor = run.get("actor")
    triggering_actor = run.get("triggering_actor")
    require(isinstance(actor, dict) and actor.get("login") == EXPECTED_ACTOR,
            "packaging run actor changed")
    require(isinstance(triggering_actor, dict)
            and triggering_actor.get("login") == EXPECTED_ACTOR,
            "packaging run triggering actor changed")
    require(run.get("status") == "completed" and run.get("conclusion") == "success",
            "packaging run is not terminal-successful")
    return run


def validate_exclusive_writer_authority(path, request):
    receipt = load_json(path, "exclusive-writer authority receipt")
    exact_keys(
        receipt,
        {
            "schema", "action", "repository", "tag", "source_commit",
            "packaging_run_id", "packaging_run_attempt", "nonce", "issued_utc",
            "expires_utc", "exclusive", "grantor",
        },
        "exclusive-writer authority receipt",
    )
    execution = request["execution"]
    packaging = request["packaging"]
    require(type(receipt["schema"]) is int and receipt["schema"] == 1,
            "exclusive-writer authority schema changed")
    require(receipt["action"] == "exclusive-v30.1.5-candidate-tag-write",
            "exclusive-writer authority action changed")
    require(receipt["repository"] == request["registry"]["repository"]
            and receipt["tag"] == request["registry"]["tag"],
            "exclusive-writer registry identity changed")
    require(receipt["source_commit"] == request["source"]["commit"],
            "exclusive-writer source changed")
    require(type(receipt["packaging_run_id"]) is int
            and receipt["packaging_run_id"] == packaging["run_id"]
            and type(receipt["packaging_run_attempt"]) is int
            and receipt["packaging_run_attempt"] == packaging["run_attempt"],
            "exclusive-writer packaging run changed")
    require(receipt["nonce"] == execution["nonce"]
            and receipt["issued_utc"] == execution["issued_utc"]
            and receipt["expires_utc"] == execution["expires_utc"],
            "exclusive-writer time or nonce changed")
    require(receipt["exclusive"] is True and receipt["grantor"] == EXPECTED_ACTOR,
            "exclusive-writer grant is absent")
    return receipt


def safe_extract_zip(zip_path, destination):
    destination.mkdir(mode=0o700)
    try:
        with zipfile.ZipFile(zip_path) as archive:
            infos = archive.infolist()
            require(0 < len(infos) <= MAX_ZIP_ENTRIES, "artifact ZIP entry count is unsafe")
            names = []
            folded = set()
            total = 0
            for info in infos:
                name = info.filename
                candidate = PurePosixPath(name)
                require(
                    name and not name.endswith("/") and not candidate.is_absolute()
                    and candidate.as_posix() == name and len(candidate.parts) == 1
                    and all(part not in ("", ".", "..") for part in candidate.parts)
                    and "\\" not in name and SAFE_NAME_RE.fullmatch(name) is not None,
                    f"artifact ZIP contains an unsafe path: {name}",
                )
                require(name not in names and name.casefold() not in folded,
                        f"artifact ZIP contains a duplicate path: {name}")
                require(not (info.flag_bits & 0x1), f"artifact ZIP entry is encrypted: {name}")
                mode = (info.external_attr >> 16) & 0xFFFF
                file_type = stat.S_IFMT(mode)
                require(file_type in (0, stat.S_IFREG), f"artifact ZIP entry is not regular: {name}")
                require(info.file_size >= 0, f"artifact ZIP entry size is malformed: {name}")
                total += info.file_size
                require(total <= MAX_ZIP_UNCOMPRESSED, "artifact ZIP expands beyond the size limit")
                names.append(name)
                folded.add(name.casefold())
            for info in infos:
                target = destination / info.filename
                with archive.open(info, "r") as source, target.open("xb") as output:
                    copied = 0
                    for chunk in iter(lambda: source.read(1024 * 1024), b""):
                        copied += len(chunk)
                        require(copied <= info.file_size, f"ZIP entry expanded beyond metadata: {info.filename}")
                        output.write(chunk)
                    require(copied == info.file_size, f"ZIP entry size changed: {info.filename}")
                target.chmod(0o600)
            return tuple(names)
    except (OSError, zipfile.BadZipFile) as error:
        raise VerificationError(f"cannot extract artifact ZIP: {error}") from error


def bundle_names(source):
    prefix = f"Blackcoin-30.1.5-candidate-{source[:12]}"
    return {
        "prefix": prefix,
        "binary_tar": f"{prefix}-Linux-x86_64.tar.gz",
        "binary_sums": f"{prefix}-BINARY_SHA256SUMS.txt",
        "source_commit": f"{prefix}-SOURCE_COMMIT.txt",
        "source_tree": f"{prefix}-SOURCE_TREE.txt",
        "reproducibility": f"{prefix}-REPRODUCIBILITY.txt",
        "notice": f"{prefix}-UNSIGNED-CANARY.txt",
        "source_signature": f"{prefix}-SOURCE-SIGNATURE.json",
        "core_ci": f"{prefix}-CORE-CI.json",
        "toolchain": f"{prefix}-TOOLCHAIN.txt",
        "oci_archive": f"blackcoin-v4-gui-30.1.5-candidate-{source[:12]}.oci.tar",
        "oci_identity": f"{prefix}-OCI-IDENTITY.json",
        "manifest": f"{prefix}-MANIFEST.json",
        "provenance": f"{prefix}-PROVENANCE.intoto.json",
        "checksums": f"{prefix}-SHA256SUMS.txt",
    }


def parse_bundle_checksums(bundle, names, expected_sha):
    checksum_path = bundle / names["checksums"]
    require(checksum_path.is_file() and not checksum_path.is_symlink(), "bundle SHA256SUMS is absent")
    require(sha256_file(checksum_path) == expected_sha, "bundle SHA256SUMS digest changed")
    entries = {}
    lines = checksum_path.read_text(encoding="utf-8").splitlines()
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]{0,254})", line)
        require(match is not None, "bundle SHA256SUMS contains a malformed line")
        digest, name = match.groups()
        require(name not in entries, "bundle SHA256SUMS contains a duplicate")
        entries[name] = digest
    require(list(entries) == sorted(entries), "bundle SHA256SUMS is not sorted")
    expected_files = set(names.values()) - {names["prefix"], names["checksums"]}
    require(set(entries) == expected_files, "bundle SHA256SUMS does not cover the exact file set")
    actual_files = {entry.name for entry in bundle.iterdir() if entry.is_file() and not entry.is_symlink()}
    require(actual_files == expected_files | {names["checksums"]}, "artifact ZIP file set changed")
    require(all(entry.is_file() and not entry.is_symlink() for entry in bundle.iterdir()),
            "artifact ZIP produced a nonregular entry")
    for name, digest in entries.items():
        require(sha256_file(bundle / name) == digest, f"bundle checksum mismatch: {name}")
    return entries


def inspect_binary_tar(path):
    require(path.is_file() and not path.is_symlink(), "binary archive is missing or unsafe")
    hashes = {}
    try:
        with tarfile.open(path, mode="r:gz") as archive:
            members = archive.getmembers()
            require(tuple(member.name for member in members) == EXPECTED_BINARIES,
                    "binary archive does not contain the exact six executables")
            for member in members:
                require(member.isfile() and not member.issym() and not member.islnk(),
                        f"binary archive entry is not regular: {member.name}")
                require(member.size > 0 and member.mode & 0o111,
                        f"binary archive entry is empty or not executable: {member.name}")
                source = archive.extractfile(member)
                require(source is not None, f"cannot read binary: {member.name}")
                hashes[member.name] = sha256_stream(source)
    except (OSError, tarfile.TarError) as error:
        raise VerificationError(f"cannot inspect binary archive: {error}") from error
    return hashes


def parse_binary_sums(path):
    entries = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (blackcoin(?:-[a-z]+|d))", line)
        require(match is not None, "binary SHA256SUMS contains a malformed line")
        digest, name = match.groups()
        require(name not in entries, "binary SHA256SUMS contains a duplicate")
        entries[name] = digest
    require(tuple(entries) == EXPECTED_BINARIES, "binary SHA256SUMS order or inventory changed")
    return entries


def descriptor_blob(archive, members, descriptor, description, media_types, read_limit=None):
    require(isinstance(descriptor, dict), f"{description} descriptor must be an object")
    require(descriptor.get("mediaType") in media_types, f"{description} media type changed")
    digest = descriptor.get("digest")
    size = descriptor.get("size")
    require(DIGEST_RE.fullmatch(digest or "") is not None, f"{description} digest is malformed")
    require(isinstance(size, int) and not isinstance(size, bool) and size >= 0,
            f"{description} size is malformed")
    name = f"blobs/sha256/{digest.removeprefix('sha256:')}"
    require(name in members, f"OCI archive is missing {description}")
    member = members[name]
    require(member.size == size, f"{description} descriptor size changed")
    source = archive.extractfile(member)
    require(source is not None, f"cannot read {description}")
    payload = source.read(read_limit + 1) if read_limit is not None else None
    if read_limit is not None:
        require(len(payload) == member.size and len(payload) <= read_limit,
                f"{description} exceeds the size limit or changed while reading")
        observed = sha256_bytes(payload)
    else:
        observed = sha256_stream(source)
    require(f"sha256:{observed}" == digest, f"{description} digest changed")
    return name, digest, payload


def inspect_oci_archive(path):
    require(path.is_file() and not path.is_symlink(), "OCI archive is missing or unsafe")
    try:
        with tarfile.open(path, mode="r:") as archive:
            members = {}
            seen_names = set()
            archive_members = archive.getmembers()
            require(0 < len(archive_members) <= MAX_OCI_ENTRIES,
                    "OCI archive entry count is unsafe")
            for member in archive_members:
                name = member.name.rstrip("/") if member.isdir() else member.name
                candidate = PurePosixPath(name)
                require(
                    name and not candidate.is_absolute() and candidate.as_posix() == name
                    and all(part not in ("", ".", "..") for part in candidate.parts),
                    f"OCI archive contains an unsafe path: {member.name}",
                )
                require(name not in seen_names, f"OCI archive contains a duplicate entry: {name}")
                seen_names.add(name)
                if member.isdir():
                    require(name in {"blobs", "blobs/sha256"}, f"unexpected OCI directory: {name}")
                    continue
                require(member.isfile() and not member.issym() and not member.islnk(),
                        f"OCI archive entry is not regular: {name}")
                members[name] = member

            def read_small(name, description, limit):
                require(name in members, f"OCI archive is missing {description}")
                member = members[name]
                require(member.size <= limit, f"{description} exceeds the size limit")
                source = archive.extractfile(member)
                require(source is not None, f"cannot read {description}")
                payload = source.read(limit + 1)
                require(len(payload) == member.size, f"{description} size changed")
                return payload

            layout = decode_json(read_small("oci-layout", "OCI layout", 4096), "OCI layout")
            require(layout == {"imageLayoutVersion": "1.0.0"}, "OCI layout marker changed")
            index = decode_json(read_small("index.json", "OCI index", 1024 * 1024), "OCI index")
            require(isinstance(index, dict) and index.get("schemaVersion") == 2, "OCI index changed")
            descriptors = index.get("manifests")
            require(isinstance(descriptors, list) and len(descriptors) == 1,
                    "OCI archive must contain one manifest")
            index_descriptor = descriptors[0]
            manifest_name, manifest_digest, manifest_payload = descriptor_blob(
                archive, members, index_descriptor, "image manifest", OCI_MANIFEST_TYPES, 4 * 1024 * 1024
            )
            annotations = index_descriptor.get("annotations")
            require(isinstance(annotations, dict), "OCI reference annotation is missing")
            image_reference = annotations.get("org.opencontainers.image.ref.name")
            require(isinstance(image_reference, str), "OCI image reference is missing")
            manifest = decode_json(manifest_payload, "OCI image manifest")
            require(isinstance(manifest, dict) and manifest.get("schemaVersion") == 2,
                    "OCI image manifest changed")
            require(manifest.get("mediaType") in OCI_MANIFEST_TYPES, "OCI manifest media type changed")
            config_name, config_digest, config_payload = descriptor_blob(
                archive, members, manifest.get("config"), "image config", OCI_CONFIG_TYPES, 16 * 1024 * 1024
            )
            layers = manifest.get("layers")
            require(isinstance(layers, list) and layers, "OCI manifest has no layers")
            layer_names = []
            for number, layer in enumerate(layers):
                name, _, _ = descriptor_blob(
                    archive, members, layer, f"image layer {number}", OCI_LAYER_TYPES
                )
                layer_names.append(name)
            require(len(layer_names) == len(set(layer_names)), "OCI manifest repeats a layer")
            expected = {"oci-layout", "index.json", manifest_name, config_name, *layer_names}
            require(set(members) == expected, "OCI archive has an unexpected or missing blob")
            config = decode_json(config_payload, "OCI image config")
            require(isinstance(config, dict), "OCI image config must be an object")
            rootfs = config.get("rootfs")
            require(isinstance(rootfs, dict) and rootfs.get("type") == "layers",
                    "OCI rootfs metadata changed")
            diff_ids = rootfs.get("diff_ids")
            require(isinstance(diff_ids, list) and len(diff_ids) == len(layers),
                    "OCI config and manifest layer counts differ")
            require(all(DIGEST_RE.fullmatch(item or "") is not None for item in diff_ids),
                    "OCI rootfs diff ID is malformed")
            return {
                "image_reference": image_reference,
                "manifest_digest": manifest_digest,
                "config_digest": config_digest,
                "manifest": manifest,
                "manifest_bytes": manifest_payload,
                "config": config,
                "config_bytes": config_payload,
                "layer_count": len(layers),
                "layers": [
                    {
                        "mediaType": layer["mediaType"],
                        "digest": layer["digest"],
                        "size": layer["size"],
                    }
                    for layer in layers
                ],
                "rootfs_diff_ids": list(diff_ids),
            }
    except (OSError, tarfile.TarError) as error:
        raise VerificationError(f"cannot inspect OCI archive: {error}") from error


def verify_git_identity(commit, tree, description):
    git = trusted_system_tool("git")
    ssh_keygen = trusted_system_tool("ssh-keygen")
    environment = secure_subprocess_environment(git=True)
    with tempfile.TemporaryDirectory(prefix="blackcoin-publication-signers-") as temporary:
        allowed_signers = Path(temporary) / "allowed_signers"
        allowed_signers.write_text(
            f'{EXPECTED_SIGNING_PRINCIPAL} namespaces="git" '
            f"{EXPECTED_SIGNING_PUBLIC_KEY}\n",
            encoding="utf-8",
        )
        allowed_signers.chmod(0o600)
        git_prefix = [
            git,
            "--no-replace-objects",
            "-c", "gpg.format=ssh",
            "-c", f"gpg.ssh.allowedSignersFile={allowed_signers}",
            "-c", f"gpg.ssh.program={ssh_keygen}",
            "-C", str(REPO_ROOT),
        ]
        try:
            observed_tree = subprocess.run(
                [*git_prefix, "rev-parse", f"{commit}^{{tree}}"],
                check=True, text=True, capture_output=True, env=environment,
                timeout=60,
            ).stdout.strip()
            signature = subprocess.run(
                [*git_prefix, "verify-commit", commit],
                check=True, text=True, capture_output=True, env=environment,
                timeout=60,
            )
            identities = subprocess.run(
                [*git_prefix, "show", "-s",
                 "--format=%an%x00%ae%x00%cn%x00%ce", commit],
                check=True, capture_output=True, env=environment, timeout=60,
            ).stdout.rstrip(b"\n").split(b"\x00")
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            raise VerificationError(
                f"{description} commit or signature is unavailable"
            ) from error
    require(observed_tree == tree, f"{description} tree changed")
    expected_signature = (
        f'Good "git" signature for {EXPECTED_SIGNING_PRINCIPAL} '
        f"with ED25519 key {EXPECTED_FINGERPRINT}"
    )
    signature_lines = [
        line.strip() for line in (signature.stdout + signature.stderr).splitlines()
        if line.strip()
    ]
    require(signature_lines.count(expected_signature) == 1
            and not any(line.startswith('Good "git" signature')
                        and line != expected_signature for line in signature_lines),
            f"{description} signature fingerprint changed")
    require(identities == [
                b"Blackcoin-Dev", EXPECTED_SIGNING_PRINCIPAL.encode("ascii"),
                b"Blackcoin-Dev", EXPECTED_SIGNING_PRINCIPAL.encode("ascii"),
            ],
            f"{description} author or committer identity changed")


def git_snapshot_bytes(git, commit, relative):
    """Read one commit path with replace refs and ambient Git config disabled."""
    try:
        return subprocess.run(
            [git, "--no-replace-objects", "-C", str(REPO_ROOT),
             "show", f"{commit}:{relative}"],
            check=True, capture_output=True,
            env=secure_subprocess_environment(git=True), timeout=60,
        ).stdout
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise VerificationError(
            f"signed snapshot path is absent from its commit: {relative}"
        ) from error


def git_snapshot_tree_entry(git, commit, relative):
    try:
        return subprocess.run(
            [git, "--no-replace-objects", "-C", str(REPO_ROOT),
             "ls-tree", commit, "--", relative],
            check=True, capture_output=True, text=True,
            env=secure_subprocess_environment(git=True), timeout=60,
        ).stdout.strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise VerificationError(
            f"signed snapshot tree path is absent: {relative}"
        ) from error


def verify_packaging_snapshot(commit, tree):
    verify_git_identity(commit, tree, "packaging tooling")
    git = trusted_system_tool("git")
    relative_paths = (
        ".github/workflows/v30.1.5-candidate-linux.yml",
        "ci/release/generate_v30_1_5_candidate_metadata.py",
        "contrib/ops/v30.1.5-candidate-package/build_candidate_bundle.sh",
        "contrib/ops/v30.1.5-candidate-package/policy.json",
        "contrib/ops/v30.1.5-candidate-package/SHA256SUMS",
        "contrib/ops/v30.1.5-candidate-package/verify_candidate_bundle.sh",
    )
    for relative in relative_paths:
        current = REPO_ROOT / relative
        require(current.is_file() and not current.is_symlink(), f"packaging tooling path is unsafe: {relative}")
        committed = git_snapshot_bytes(git, commit, relative)
        require(current.read_bytes() == committed, f"packaging tooling path differs from its commit: {relative}")
    package_sums = CANDIDATE_ROOT / "SHA256SUMS"
    entries = {}
    for line in package_sums.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._/-]+)", line)
        require(match is not None, "candidate package seal is malformed")
        digest, name = match.groups()
        candidate = PurePosixPath(name)
        require(
            name not in entries and not candidate.is_absolute() and candidate.as_posix() == name
            and all(part not in ("", ".", "..") for part in candidate.parts),
            "candidate package seal has an unsafe name",
        )
        entries[name] = digest
    actual = {
        entry.relative_to(CANDIDATE_ROOT).as_posix()
        for entry in CANDIDATE_ROOT.rglob("*")
        if entry.is_file() and not entry.is_symlink()
        and entry.relative_to(CANDIDATE_ROOT).as_posix() != "SHA256SUMS"
    }
    require(set(entries) == actual, "candidate package seal file set changed")
    for name, digest in entries.items():
        path = CANDIDATE_ROOT.joinpath(*PurePosixPath(name).parts)
        require(path.is_file() and not path.is_symlink(), f"candidate package seal path is unsafe: {name}")
        require(sha256_file(path) == digest, f"candidate package seal mismatch: {name}")
    return sha256_file(package_sums)


def verify_publication_snapshot(commit, tree):
    """Bind every executing publication-adapter byte to one signed commit."""
    verify_git_identity(commit, tree, "publication tooling")
    git = trusted_system_tool("git")
    relative_names = (
        "README.md",
        "SHA256SUMS",
        "publish_candidate_oci.sh",
        "request.example.json",
        "tests/run.sh",
        "verify_candidate_publication.py",
    )
    expected_relative = {
        f"contrib/ops/v30.1.5-candidate-publication/{name}" for name in relative_names
    }
    expected_modes = {
        "README.md": "100644",
        "SHA256SUMS": "100644",
        "publish_candidate_oci.sh": "100755",
        "request.example.json": "100644",
        "tests/run.sh": "100755",
        "verify_candidate_publication.py": "100755",
    }
    actual_relative = {
        entry.relative_to(REPO_ROOT).as_posix()
        for entry in PUBLICATION_ROOT.rglob("*")
        if entry.is_file() and not entry.is_symlink()
    }
    require(actual_relative == expected_relative,
            "publication tooling package file set changed")
    all_entries = tuple(PUBLICATION_ROOT.rglob("*"))
    require(not any(entry.is_symlink() for entry in all_entries),
            "publication tooling package contains a symlink")
    require(all(entry.is_file() or entry.is_dir() for entry in all_entries),
            "publication tooling package contains a nonregular entry")
    actual_directories = {
        entry.relative_to(PUBLICATION_ROOT).as_posix()
        for entry in all_entries if entry.is_dir()
    }
    require(actual_directories == {"tests"},
            "publication tooling package directory set changed")
    for relative in sorted(expected_relative):
        current = REPO_ROOT / relative
        committed = git_snapshot_bytes(git, commit, relative)
        tree_entry = git_snapshot_tree_entry(git, commit, relative)
        require(current.read_bytes() == committed,
                f"publication tooling path differs from its commit: {relative}")
        match = re.fullmatch(r"(100644|100755) blob [0-9a-f]{40}\t(.+)", tree_entry)
        name = current.relative_to(PUBLICATION_ROOT).as_posix()
        require(match is not None and match.group(2) == relative
                and match.group(1) == expected_modes[name],
                f"publication tooling committed mode changed: {relative}")
        current_executable = bool(stat.S_IMODE(current.stat().st_mode) & 0o111)
        require(current_executable == (expected_modes[name] == "100755"),
                f"publication tooling working mode changed: {relative}")

    sums = PUBLICATION_ROOT / "SHA256SUMS"
    entries = {}
    for line in sums.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._/-]+)", line)
        require(match is not None, "publication package seal is malformed")
        digest, name = match.groups()
        candidate = PurePosixPath(name)
        require(
            name not in entries and not candidate.is_absolute()
            and candidate.as_posix() == name
            and all(part not in ("", ".", "..") for part in candidate.parts),
            "publication package seal has an unsafe name",
        )
        entries[name] = digest
    require(set(entries) == set(relative_names) - {"SHA256SUMS"},
            "publication package seal file set changed")
    for name, digest in entries.items():
        path = PUBLICATION_ROOT.joinpath(*PurePosixPath(name).parts)
        require(path.is_file() and not path.is_symlink(),
                f"publication package seal path is unsafe: {name}")
        require(sha256_file(path) == digest,
                f"publication package seal mismatch: {name}")
    return sha256_file(sums)


def run_canonical_bundle_verifier(bundle):
    require(CANDIDATE_POLICY.is_file() and not CANDIDATE_POLICY.is_symlink(), "candidate policy is unsafe")
    require(CANDIDATE_VERIFIER.is_file() and not CANDIDATE_VERIFIER.is_symlink(), "candidate verifier is unsafe")
    require(CANDIDATE_METADATA.is_file() and not CANDIDATE_METADATA.is_symlink(), "candidate metadata verifier is unsafe")
    environment = secure_subprocess_environment()
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    python = trusted_system_tool("python3")
    try:
        subprocess.run(
            [python, "-I", "-B", str(CANDIDATE_METADATA),
             "verify", "--policy", str(CANDIDATE_POLICY),
             "--bundle", str(bundle)],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=environment, timeout=300,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        message = getattr(error, "stderr", b"")
        message = (message or b"").decode("utf-8", errors="replace").strip()
        raise VerificationError(f"canonical candidate bundle verifier failed: {message}") from error


def validate_manifest_and_oci(bundle, names, request, checksum_entries):
    source_request = request["source"]
    core_request = request["core_ci"]
    packaging = request["packaging"]
    oci_request = request["oci"]
    source = source_request["commit"]
    tree = source_request["tree"]
    require((bundle / names["source_commit"]).read_text(encoding="utf-8") == f"{source}\n",
            "bundle source marker changed")
    require((bundle / names["source_tree"]).read_text(encoding="utf-8") == f"{tree}\n",
            "bundle source-tree marker changed")
    manifest = load_json(bundle / names["manifest"], "candidate manifest")
    exact_keys(
        manifest,
        {"schema", "classification", "package", "source", "authorization", "core_ci", "build",
         "base_image", "image", "reproducibility", "release", "artifacts"},
        "candidate manifest",
    )
    require(manifest["schema"] == 2 and manifest["classification"] == EXPECTED_CLASSIFICATION,
            "candidate manifest classification changed")
    require(manifest["package"] == {
        "name": names["prefix"], "version": "30.1.5", "platform": "linux/amd64"
    }, "candidate package identity changed")
    source_value = manifest["source"]
    require(source_value.get("repository") == source_request["repository"], "manifest repository changed")
    require(source_value.get("commit") == source and source_value.get("tree") == tree,
            "manifest H/T identity changed")
    signature = source_value.get("signature")
    require(isinstance(signature, dict) and signature.get("schema") == 2,
            "manifest source signature is absent")
    require(signature.get("commit") == source and signature.get("tree") == tree,
            "manifest source signature H/T changed")
    require(signature.get("fingerprint") == source_request["signing_fingerprint"]
            and signature.get("local_git_verified") is True
            and signature.get("github_verified") is True
            and signature.get("github_verification_reason") == "valid",
            "manifest source signature is not verified")
    core_ci = manifest["core_ci"]
    core_ci_file = bundle / names["core_ci"]
    core_ci_evidence = load_json(core_ci_file, "Core CI evidence")
    require(core_ci == core_ci_evidence, "manifest and Core CI evidence differ")
    require(sha256_file(core_ci_file) == core_request["evidence_sha256"],
            "Core CI evidence digest changed")
    validate_core_ci_evidence_shape(
        core_ci, source=source_request, require_merged=request["execution"]["execute"]
    )
    require(core_ci["run_id"] == core_request["run_id"]
            and core_ci["run_attempt"] == core_request["run_attempt"],
            "manifest Core CI run R changed")
    require(core_ci.get("head_sha") == source and core_ci.get("head_tree") == tree,
            "manifest Core CI H/T changed")
    require(core_ci.get("status") == "completed" and core_ci.get("conclusion") == "success",
            "manifest Core CI is not successful")
    require(core_ci.get("workflow_path") == core_request["workflow_path"],
            "manifest Core CI workflow changed")
    require(canonical_subset_sha256(core_ci.get("required_checks"))
            == core_request["required_checks_sha256"],
            "Core CI required-check receipt changed")
    sanitizer_evidence = core_ci.get("thread_sanitizer_artifact")
    require(isinstance(sanitizer_evidence, dict), "Core CI sanitizer receipt is absent")
    sanitizer_request = core_request["thread_sanitizer_artifact"]
    require(
        {
            key: sanitizer_evidence.get(key)
            for key in ("id", "name", "api_digest", "zip_sha256", "reports_sha256")
        } == sanitizer_request,
        "Core CI sanitizer receipt changed",
    )
    build = manifest["build"]
    require(build.get("tooling_commit") == packaging["tooling_commit"]
            and build.get("workflow_definition_commit") == packaging["tooling_commit"],
            "manifest packaging tooling commit changed")
    require(build.get("workflow_run_id") == packaging["run_id"]
            and build.get("workflow_run_attempt") == packaging["run_attempt"],
            "manifest packaging run/attempt changed")
    authorization = manifest["authorization"]
    blocked = {
        "state": "blocked_pending_final_signed_source_and_green_ci",
        "dispatch_enabled": False,
        "temporary_source_pin": True,
        "core_ci_run_id": None,
        "core_ci_run_attempt": None,
        "thread_sanitizer_artifact": None,
    }
    authorization_ready = authorization.get("state") == "authorized_exact_signed_source_and_green_ci"
    if authorization_ready:
        exact_keys(
            authorization,
            {
                "state", "dispatch_enabled", "temporary_source_pin", "core_ci_run_id",
                "core_ci_run_attempt", "thread_sanitizer_artifact",
            },
            "candidate authorization",
        )
        require(authorization["dispatch_enabled"] is True
                and authorization["temporary_source_pin"] is False
                and authorization["core_ci_run_id"] == core_request["run_id"]
                and authorization["core_ci_run_attempt"] == core_request["run_attempt"],
                "ready candidate authorization tuple is inconsistent")
        core_attempt = authorization["core_ci_run_attempt"]
        require(type(core_attempt) is int and core_attempt > 0,
                "authorized Core CI run attempt is malformed")
        sanitizer = authorization["thread_sanitizer_artifact"]
        exact_keys(sanitizer, {"id", "name", "zip_sha256", "reports_sha256"},
                   "authorized ThreadSanitizer artifact")
        require(type(sanitizer["id"]) is int and sanitizer["id"] > 0,
                "authorized ThreadSanitizer artifact ID is malformed")
        require(sanitizer["name"] == (
            f"sanitizer-reports-thread-sanitizer-{source}-attempt-{core_attempt}"
        ), "authorized ThreadSanitizer artifact name changed")
        require(HEX64_RE.fullmatch(sanitizer["zip_sha256"] or "") is not None
                and HEX64_RE.fullmatch(sanitizer["reports_sha256"] or "") is not None,
                "authorized ThreadSanitizer artifact digest is malformed")
    else:
        require(authorization == blocked, "candidate authorization tuple is inconsistent")
    if request["execution"]["execute"]:
        require(authorization_ready, "live publication cannot use a blocked candidate")
    require(manifest["release"] == {
        "tag": None, "published": False, "registry_pushed": False, "canary_only": True
    }, "candidate pre-publication state changed")

    binary_hashes = inspect_binary_tar(bundle / names["binary_tar"])
    require(parse_binary_sums(bundle / names["binary_sums"]) == binary_hashes,
            "six-binary checksum ledger changed")
    oci = inspect_oci_archive(bundle / names["oci_archive"])
    oci_identity = load_json(bundle / names["oci_identity"], "OCI identity")
    require(manifest["image"] == oci_identity, "manifest and OCI identity differ")
    require(oci_identity.get("schema") == 2 and oci_identity.get("classification") == EXPECTED_CLASSIFICATION,
            "OCI identity schema/classification changed")
    require(oci_identity.get("source_commit") == source and oci_identity.get("source_tree") == tree,
            "OCI identity H/T changed")
    expected_local = f"{EXPECTED_REGISTRY_REPOSITORY}:30.1.5-candidate-{source[:12]}-ci1"
    require(oci_identity.get("image_reference") == expected_local
            and oci["image_reference"] == expected_local,
            "OCI local image reference changed")
    require(oci_identity.get("archive_name") == names["oci_archive"]
            and oci_identity.get("archive_sha256") == sha256_file(bundle / names["oci_archive"]),
            "OCI archive identity changed")
    require(oci_identity.get("image_manifest_digest") == oci["manifest_digest"],
            "OCI manifest digest changed")
    require(oci_identity.get("image_config_digest") == oci["config_digest"],
            "OCI config digest changed")
    require(oci_identity.get("binaries") == binary_hashes, "OCI six-binary ledger changed")
    require(oci_request == {
        "archive_sha256": sha256_file(bundle / names["oci_archive"]),
        "manifest_digest": oci["manifest_digest"],
        "config_digest": oci["config_digest"],
        "layers": oci["layers"],
        "rootfs_diff_ids": oci["rootfs_diff_ids"],
        "binaries": binary_hashes,
    }, "request OCI graph differs from the sealed archive")
    require(oci_identity.get("published") is False and oci_identity.get("registry_pushed") is False,
            "OCI pre-publication state changed")
    require(oci_identity.get("oci_roundtrip_verified") is True,
            "OCI archive round-trip evidence is absent")
    config = oci["config"]
    require(config.get("os") == "linux" and config.get("architecture") == "amd64",
            "OCI platform changed")
    runtime = config.get("config")
    require(isinstance(runtime, dict), "OCI runtime config is absent")
    require(runtime.get("User") == "blackcoin"
            and runtime.get("Entrypoint") == ["/home/blackcoin/start-gui.sh"],
            "OCI runtime identity changed")
    labels = runtime.get("Labels")
    require(isinstance(labels, dict), "OCI labels are absent")
    require(labels.get("org.blackcoin.source.commit") == source
            and labels.get("org.blackcoin.source.tree") == tree
            and labels.get("org.opencontainers.image.revision") == source,
            "OCI source labels changed")
    require(labels.get("org.blackcoin.artifact.sha256") == sha256_file(bundle / names["binary_tar"])
            and labels.get("org.blackcoin.sha256sums.sha256") == sha256_file(bundle / names["binary_sums"]),
            "OCI binary artifact labels changed")
    for binary, digest in binary_hashes.items():
        require(labels.get(f"org.blackcoin.binary.{binary}.sha256") == digest,
                f"OCI binary label changed: {binary}")
    require(labels.get("org.blackcoin.candidate.published") == "false"
            and labels.get("org.blackcoin.candidate.registry-pushed") == "false",
            "OCI assembly-state labels changed")
    artifacts = manifest["artifacts"]
    require(isinstance(artifacts, list), "manifest artifact inventory is absent")
    manifest_artifacts = {}
    for item in artifacts:
        require(isinstance(item, dict) and set(item) == {"name", "sha256", "size"},
                "manifest artifact entry changed")
        require(item["name"] not in manifest_artifacts, "manifest artifact inventory has a duplicate")
        manifest_artifacts[item["name"]] = item["sha256"]
    for artifact_name, digest in manifest_artifacts.items():
        require(checksum_entries.get(artifact_name) == digest,
                f"manifest artifact digest differs from bundle seal: {artifact_name}")
    return {
        "manifest": manifest,
        "authorization_ready": authorization_ready,
        "binary_hashes": binary_hashes,
        "oci": oci,
        "manifest_sha256": sha256_file(bundle / names["manifest"]),
        "provenance_sha256": sha256_file(bundle / names["provenance"]),
        "binary_tar_sha256": sha256_file(bundle / names["binary_tar"]),
        "binary_sums_sha256": sha256_file(bundle / names["binary_sums"]),
        "core_ci_evidence_sha256": sha256_file(core_ci_file),
        "core_ci_evidence": core_ci,
        "required_checks_sha256": canonical_subset_sha256(core_ci["required_checks"]),
    }


def compare_extracted_bundles(expected, observed):
    expected_files = {
        entry.name: entry for entry in expected.iterdir()
        if entry.is_file() and not entry.is_symlink()
    }
    observed_files = {
        entry.name: entry for entry in observed.iterdir()
        if entry.is_file() and not entry.is_symlink()
    }
    require(set(expected_files) == set(observed_files),
            "prepared bundle and artifact ZIP inventory differ")
    require(all(entry.is_file() and not entry.is_symlink() for entry in expected.iterdir())
            and all(entry.is_file() and not entry.is_symlink() for entry in observed.iterdir()),
            "prepared or re-extracted bundle contains an unsafe entry")
    for name in expected_files:
        require(sha256_file(expected_files[name]) == sha256_file(observed_files[name]),
                f"prepared bundle byte changed: {name}")


def revalidate_zip_extraction(root):
    scratch = Path(tempfile.mkdtemp(prefix=".publication-revalidation-", dir=root.parent))
    scratch.chmod(0o700)
    try:
        extracted = scratch / "bundle"
        safe_extract_zip(root / "artifact.zip", extracted)
        compare_extracted_bundles(root / "bundle", extracted)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def evaluate_prepared_inputs(
    root,
    *,
    enforce_time,
    revalidate_zip,
    now=None,
    canonical_bundle_check=None,
    source_identity_check=None,
    packaging_snapshot_check=None,
    publication_snapshot_check=None,
):
    request_path = root / "request.json"
    request, request_sha = load_request_with_sha(
        request_path, enforce_time=enforce_time, now=now
    )
    artifact = request["artifact"]
    packaging = request["packaging"]
    execution = request["execution"]

    api_path = root / "artifact-api.json"
    require(api_path.is_file() and not api_path.is_symlink(), "copied artifact API receipt is unsafe")
    api_sha = sha256_file(api_path)
    require(api_sha == artifact["api_metadata_sha256"], "copied artifact API digest changed")
    run_path = root / "packaging-run.json"
    require(run_path.is_file() and not run_path.is_symlink(), "copied packaging-run receipt is unsafe")
    run_sha = sha256_file(run_path)
    require(run_sha == packaging["run_metadata_sha256"], "copied packaging-run digest changed")
    zip_path = root / "artifact.zip"
    require(zip_path.is_file() and not zip_path.is_symlink(), "copied artifact ZIP is unsafe")
    zip_size = zip_path.stat().st_size
    require(zip_size <= MAX_GITHUB_ZIP_BYTES, "copied artifact ZIP exceeds the size limit")
    zip_sha = sha256_file(zip_path)
    require(zip_sha == artifact["github_zip_sha256"], "copied artifact ZIP digest changed")
    validate_github_metadata(api_path, request, zip_sha, zip_size)
    validate_packaging_run(run_path, request)

    exclusive_sha = None
    if execution["execute"]:
        exclusive_path = root / "exclusive-writer-authority.json"
        require(exclusive_path.is_file() and not exclusive_path.is_symlink(),
                "copied exclusive-writer authority is unsafe")
        exclusive_sha = sha256_file(exclusive_path)
        require(exclusive_sha == execution["exclusive_writer_authority_sha256"],
                "copied exclusive-writer authority digest changed")
        validate_exclusive_writer_authority(exclusive_path, request)
    else:
        require(not (root / "exclusive-writer-authority.json").exists(),
                "disabled request has an exclusive-writer authority file")

    bundle = root / "bundle"
    require(bundle.is_dir() and not bundle.is_symlink(), "prepared bundle is missing or unsafe")
    if revalidate_zip:
        revalidate_zip_extraction(root)
    names = bundle_names(request["source"]["commit"])
    checksum_entries = parse_bundle_checksums(
        bundle, names, artifact["bundle_sha256sums_sha256"]
    )
    if source_identity_check is None:
        verify_git_identity(request["source"]["commit"], request["source"]["tree"], "source")
    else:
        source_identity_check(request["source"]["commit"], request["source"]["tree"])
    if packaging_snapshot_check is None:
        packaging_seal_sha = verify_packaging_snapshot(
            packaging["tooling_commit"], packaging["tooling_tree"]
        )
    else:
        packaging_seal_sha = packaging_snapshot_check(
            packaging["tooling_commit"], packaging["tooling_tree"]
        )
    require(packaging_seal_sha == packaging["package_sha256sums_sha256"],
            "packaging package seal differs from the request")
    publication = request["publication_tooling"]
    if publication_snapshot_check is None:
        publication_seal_sha = verify_publication_snapshot(
            publication["commit"], publication["tree"]
        )
    else:
        publication_seal_sha = publication_snapshot_check(
            publication["commit"], publication["tree"]
        )
    require(publication_seal_sha == publication["package_sha256sums_sha256"],
            "publication package seal differs from the request")
    if canonical_bundle_check is None:
        run_canonical_bundle_verifier(bundle)
    else:
        canonical_bundle_check(bundle)
    detail = validate_manifest_and_oci(bundle, names, request, checksum_entries)
    return {
        "request": request,
        "request_sha256": request_sha,
        "api_sha256": api_sha,
        "packaging_run_sha256": run_sha,
        "zip_sha256": zip_sha,
        "zip_size": zip_size,
        "exclusive_writer_authority_sha256": exclusive_sha,
        "packaging_seal_sha256": packaging_seal_sha,
        "publication_seal_sha256": publication_seal_sha,
        "names": names,
        "detail": detail,
    }


def build_verified_receipt(root, evaluated, *, create_source_files):
    request = evaluated["request"]
    detail = evaluated["detail"]
    names = evaluated["names"]
    verified_dir = root / "verified"
    if create_source_files:
        verified_dir.mkdir(mode=0o700)
    else:
        require(verified_dir.is_dir() and not verified_dir.is_symlink(),
                "verified OCI directory is missing or unsafe")
    source_payloads = {
        "source-oci-manifest.json": detail["oci"]["manifest_bytes"],
        "source-oci-config.json": detail["oci"]["config_bytes"],
    }
    for name, payload in source_payloads.items():
        path = verified_dir / name
        if create_source_files:
            require(not path.exists() and not path.is_symlink(), f"refusing to overwrite {path}")
            path.write_bytes(payload)
            path.chmod(0o600)
        else:
            require(read_regular_bytes(path, f"verified {name}", MAX_JSON_BYTES) == payload,
                    f"verified {name} differs from the sealed OCI archive")

    source = request["source"]
    core = request["core_ci"]
    packaging = request["packaging"]
    artifact = request["artifact"]
    publication = request["publication_tooling"]
    oci = request["oci"]
    authority = publication_authority_value(request)
    authority_sha = publication_authority_sha256(request)
    return {
        "schema": 2,
        "status": "verified",
        "request_sha256": evaluated["request_sha256"],
        "publication_authority_sha256": authority_sha,
        "publication_authority": authority,
        "source": source,
        "core_ci": core,
        "core_ci_evidence": detail["core_ci_evidence"],
        "packaging": {
            **{key: item for key, item in packaging.items() if key != "run_metadata_path"},
            "run_metadata_path": "packaging-run.json",
            "run_metadata_sha256": evaluated["packaging_run_sha256"],
        },
        "github_artifact": {
            "id": artifact["id"],
            "name": artifact["name"],
            "packaging_run_id": packaging["run_id"],
            "packaging_run_attempt": packaging["run_attempt"],
            "api_metadata_path": "artifact-api.json",
            "api_metadata_sha256": evaluated["api_sha256"],
            "zip_path": "artifact.zip",
            "zip_sha256": evaluated["zip_sha256"],
            "zip_size": evaluated["zip_size"],
        },
        "publication_tooling": publication,
        "bundle": {
            "sha256sums_sha256": artifact["bundle_sha256sums_sha256"],
            "binary_archive_sha256": detail["binary_tar_sha256"],
            "binary_sha256sums_sha256": detail["binary_sums_sha256"],
            "manifest_sha256": detail["manifest_sha256"],
            "provenance_sha256": detail["provenance_sha256"],
            "packaging_package_sha256sums_sha256": evaluated["packaging_seal_sha256"],
            "publication_package_sha256sums_sha256": evaluated["publication_seal_sha256"],
            "directory": "bundle",
        },
        "oci": {
            "archive_path": f"bundle/{names['oci_archive']}",
            "archive_sha256": oci["archive_sha256"],
            "source_manifest_path": "verified/source-oci-manifest.json",
            "source_manifest_digest": oci["manifest_digest"],
            "source_config_path": "verified/source-oci-config.json",
            "source_config_digest": oci["config_digest"],
            "layers": oci["layers"],
            "rootfs_diff_ids": oci["rootfs_diff_ids"],
            "layer_count": len(oci["layers"]),
        },
        "binaries": oci["binaries"],
        "exclusive_writer_authority": (
            {
                "path": "exclusive-writer-authority.json",
                "sha256": evaluated["exclusive_writer_authority_sha256"],
            }
            if request["execution"]["execute"] else None
        ),
        "candidate_authorization_ready": detail["authorization_ready"],
        "execution": request["execution"],
        "publication_authorized": bool(
            request["execution"]["execute"] and detail["authorization_ready"]
        ),
        "mutable_tag_is_rollout_authority": False,
    }


def prepare_artifact(
    request_path,
    output,
    canonical_bundle_check=None,
    source_identity_check=None,
    packaging_snapshot_check=None,
    publication_snapshot_check=None,
):
    request_path = Path(request_path)
    output = Path(output)
    require(output.is_absolute(), "output directory must be absolute")
    require(not output.exists() and not output.is_symlink(), "output directory already exists")
    parent = output.parent
    require(parent.is_dir() and not parent.is_symlink(), "output parent is missing or unsafe")
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}.prepare-", dir=parent))
    temporary.chmod(0o700)
    try:
        copied_request = temporary / "request.json"
        request_sha, _ = copy_regular_file(request_path, copied_request, max_size=MAX_JSON_BYTES)
        request, parsed_request_sha = load_request_with_sha(copied_request)
        require(request_sha == parsed_request_sha, "copied request digest changed before validation")
        artifact = request["artifact"]
        packaging = request["packaging"]
        copy_regular_file(
            Path(artifact["api_metadata_path"]), temporary / "artifact-api.json",
            artifact["api_metadata_sha256"], MAX_JSON_BYTES,
        )
        copy_regular_file(
            Path(packaging["run_metadata_path"]), temporary / "packaging-run.json",
            packaging["run_metadata_sha256"], MAX_JSON_BYTES,
        )
        copy_regular_file(
            Path(artifact["github_zip_path"]), temporary / "artifact.zip",
            artifact["github_zip_sha256"], MAX_GITHUB_ZIP_BYTES,
        )
        if request["execution"]["execute"]:
            copy_regular_file(
                Path(request["execution"]["exclusive_writer_authority_path"]),
                temporary / "exclusive-writer-authority.json",
                request["execution"]["exclusive_writer_authority_sha256"],
                MAX_JSON_BYTES,
            )
        names = bundle_names(request["source"]["commit"])
        zip_names = safe_extract_zip(temporary / "artifact.zip", temporary / "bundle")
        require(set(zip_names) == set(names.values()) - {names["prefix"]},
                "GitHub artifact ZIP does not contain the exact candidate bundle")
        evaluated = evaluate_prepared_inputs(
            temporary,
            enforce_time=True,
            revalidate_zip=False,
            canonical_bundle_check=canonical_bundle_check,
            source_identity_check=source_identity_check,
            packaging_snapshot_check=packaging_snapshot_check,
            publication_snapshot_check=publication_snapshot_check,
        )
        verified = build_verified_receipt(temporary, evaluated, create_source_files=True)
        write_new_json(temporary / "VERIFIED_INPUT.json", verified)
        fsync_tree(temporary)
        os.replace(temporary, output)
        parent_descriptor = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(parent_descriptor)
        finally:
            os.close(parent_descriptor)
        return verified
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def revalidate_prepared_receipt(
    verified_path,
    request_path=None,
    *,
    enforce_time,
    now=None,
    canonical_bundle_check=None,
    source_identity_check=None,
    packaging_snapshot_check=None,
    publication_snapshot_check=None,
):
    """Recompute VERIFIED_INPUT from immutable inputs instead of trusting it."""
    verified_path = Path(verified_path)
    require(verified_path.name == "VERIFIED_INPUT.json",
            "verified artifact receipt has an unexpected name")
    require(verified_path.is_file() and not verified_path.is_symlink(),
            "verified artifact receipt is missing or unsafe")
    root = verified_path.parent
    if request_path is not None:
        request_path = Path(request_path)
        require(
            read_regular_bytes(request_path, "execution request")
            == read_regular_bytes(root / "request.json", "prepared execution request"),
            "execution request differs from the prepared request",
        )
    evaluated = evaluate_prepared_inputs(
        root,
        enforce_time=enforce_time,
        revalidate_zip=True,
        now=now,
        canonical_bundle_check=canonical_bundle_check,
        source_identity_check=source_identity_check,
        packaging_snapshot_check=packaging_snapshot_check,
        publication_snapshot_check=publication_snapshot_check,
    )
    expected = build_verified_receipt(root, evaluated, create_source_files=False)
    observed = load_json(verified_path, "verified artifact receipt")
    require(observed == expected,
            "verified artifact receipt differs from recomputed prepared evidence")
    return observed, evaluated


def canonical_json_line(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def nonce_record_value(request, request_sha, authority_sha, consumed_utc, uid):
    packaging = request["packaging"]
    registry = request["registry"]
    execution = request["execution"]
    return {
        "schema": 1,
        "action": "consume-v30.1.5-publication-authority",
        "request_sha256": request_sha,
        "publication_authority_sha256": authority_sha,
        "source_commit": request["source"]["commit"],
        "packaging_run_id": packaging["run_id"],
        "packaging_run_attempt": packaging["run_attempt"],
        "publication_tooling_commit": request["publication_tooling"]["commit"],
        "registry_host": registry["host"],
        "repository": registry["repository"],
        "tag": registry["tag"],
        "nonce": execution["nonce"],
        "issued_utc": execution["issued_utc"],
        "expires_utc": execution["expires_utc"],
        "consumed_utc": consumed_utc,
        "uid": uid,
    }


NONCE_RECORD_FIELDS = {
    "schema", "action", "request_sha256", "publication_authority_sha256",
    "source_commit", "packaging_run_id", "packaging_run_attempt",
    "publication_tooling_commit", "registry_host", "repository", "tag",
    "nonce", "issued_utc", "expires_utc", "consumed_utc", "uid",
}


def validate_nonce_record(record, description="nonce ledger record"):
    exact_keys(record, NONCE_RECORD_FIELDS, description)
    require(type(record["schema"]) is int and record["schema"] == 1
            and record["action"] == "consume-v30.1.5-publication-authority",
            f"{description} schema or action changed")
    require(is_hex64(record["request_sha256"])
            and is_hex64(record["publication_authority_sha256"])
            and is_full_sha(record["source_commit"])
            and is_full_sha(record["publication_tooling_commit"])
            and NONCE_RE.fullmatch(record["nonce"] or "") is not None,
            f"{description} digest identity is malformed")
    require(type(record["packaging_run_id"]) is int and record["packaging_run_id"] > 0
            and type(record["packaging_run_attempt"]) is int
            and record["packaging_run_attempt"] > 0,
            f"{description} run identity is malformed")
    require(record["registry_host"] == EXPECTED_REGISTRY_HOST
            and record["repository"] == EXPECTED_REGISTRY_REPOSITORY
            and isinstance(record["tag"], str),
            f"{description} registry identity is malformed")
    issued = parse_utc(record["issued_utc"], f"{description} issued time")
    expires = parse_utc(record["expires_utc"], f"{description} expiry time")
    consumed = parse_utc(record["consumed_utc"], f"{description} consumption time")
    require(issued <= consumed <= expires and expires - issued <= MAX_AUTHORITY_LIFETIME,
            f"{description} consumption time is outside its authority")
    require(type(record["uid"]) is int and record["uid"] >= 0,
            f"{description} uid is malformed")
    return record


def open_absolute_directory_nofollow(path, description):
    """Open an absolute directory through the kernel with no terminal symlink."""
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts,
            f"{description} path is not a safe absolute path")
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        return os.open(path, flags)
    except OSError as error:
        raise VerificationError(f"cannot open {description} safely: {error}") from error


def protected_directory_chain(path, required_uid=0):
    """Return a stable identity ledger for one protected absolute directory chain."""
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts,
            "protected directory path is not a safe absolute path")
    entries = []
    current = Path("/")
    components = [current]
    for part in path.parts[1:]:
        current /= part
        components.append(current)
    for index, current in enumerate(components):
        try:
            status = os.lstat(current)
        except OSError as error:
            raise VerificationError(f"cannot inspect protected directory: {current}") from error
        require(stat.S_ISDIR(status.st_mode) and not stat.S_ISLNK(status.st_mode),
                f"protected directory component is not a real directory: {current}")
        owner_ok = status.st_uid in {0, required_uid}
        mode_ok = stat.S_IMODE(status.st_mode) & 0o022 == 0
        if required_uid != 0 and status.st_uid == 0 and status.st_mode & stat.S_ISVTX:
            mode_ok = True
        require(owner_ok and mode_ok,
                f"protected directory component is not required-owner/non-writable: {current}")
        if index == len(components) - 1:
            require(status.st_uid == required_uid
                    and stat.S_IMODE(status.st_mode) == 0o700,
                    "live evidence directory must have mode 0700")
        entries.append({
            "path": str(current),
            "device": status.st_dev,
            "inode": status.st_ino,
            "uid": status.st_uid,
            "gid": status.st_gid,
            "mode": f"{stat.S_IMODE(status.st_mode):04o}",
        })
    require(entries[-1]["path"] == str(path),
            "protected directory chain did not terminate at the evidence root")
    return entries


def create_output_anchor(root, output, *, required_uid=0):
    root = Path(root)
    output = Path(output)
    require(output == root / "OUTPUT_ANCHOR.json",
            "live output-anchor path is not canonical")
    value = {
        "schema": 1,
        "status": "anchored",
        "root": str(root),
        "required_uid": required_uid,
        "chain": protected_directory_chain(root, required_uid),
    }
    write_new_json_durable(output, value)
    return value


def validate_output_anchor(root, anchor, *, required_uid=0):
    root = Path(root)
    anchor = Path(anchor)
    require(anchor == root / "OUTPUT_ANCHOR.json",
            "live output-anchor path is not canonical")
    observed = load_json(anchor, "live output-anchor receipt")
    expected = {
        "schema": 1,
        "status": "anchored",
        "root": str(root),
        "required_uid": required_uid,
        "chain": protected_directory_chain(root, required_uid),
    }
    require(canonical_json_bytes(observed) == canonical_json_bytes(expected),
            "live evidence directory identity changed")
    return observed


def open_ledger_parent(path, required_uid):
    parent = path.parent
    chain_before = protected_parent_chain(path, required_uid, final_mode=0o700)
    try:
        descriptor = open_absolute_directory_nofollow(parent, "nonce ledger parent")
    except (OSError, VerificationError) as error:
        raise VerificationError(f"cannot open nonce ledger parent safely: {error}") from error
    status = os.fstat(descriptor)
    try:
        require(stat.S_ISDIR(status.st_mode) and status.st_uid == required_uid
                and stat.S_IMODE(status.st_mode) == 0o700,
                "nonce ledger parent must have the required owner and mode 0700")
        require(protected_parent_chain(path, required_uid, final_mode=0o700)
                == chain_before,
                "nonce ledger directory ancestry changed while opening")
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def decode_nonce_ledger(payload):
    require(not payload or payload.endswith(b"\n"),
            "nonce ledger has a torn final record")
    records = []
    seen_nonces = set()
    seen_authorities = set()
    offset = 0
    for number, line in enumerate(payload.splitlines(keepends=True), 1):
        require(line.endswith(b"\n") and line != b"\n",
                f"nonce ledger record {number} is malformed")
        record = validate_nonce_record(
            decode_json(line[:-1], f"nonce ledger record {number}"),
            f"nonce ledger record {number}",
        )
        require(line == canonical_json_line(record),
                f"nonce ledger record {number} is not canonical")
        require(record["nonce"] not in seen_nonces
                and record["publication_authority_sha256"] not in seen_authorities,
                "nonce ledger contains a duplicate authority")
        seen_nonces.add(record["nonce"])
        seen_authorities.add(record["publication_authority_sha256"])
        records.append((offset, record, line))
        offset += len(line)
    return records, seen_nonces, seen_authorities


def read_locked_ledger(descriptor):
    before = os.fstat(descriptor)
    require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1,
            "nonce ledger is not a single-linked regular file")
    require(before.st_size <= MAX_NONCE_LEDGER_BYTES,
            "nonce ledger exceeds the size limit")
    os.lseek(descriptor, 0, os.SEEK_SET)
    payload = b""
    while len(payload) <= MAX_NONCE_LEDGER_BYTES:
        chunk = os.read(
            descriptor, min(1024 * 1024, MAX_NONCE_LEDGER_BYTES + 1 - len(payload))
        )
        if not chunk:
            break
        payload += chunk
    after = os.fstat(descriptor)
    require(
        (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
        == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        and len(payload) == before.st_size and len(payload) <= MAX_NONCE_LEDGER_BYTES,
        "nonce ledger changed or exceeds the size limit",
    )
    return payload, before


def consume_nonce(
    verified_path,
    request_path,
    ledger_path,
    output,
    *,
    required_uid=0,
    now=None,
    canonical_bundle_check=None,
    source_identity_check=None,
    packaging_snapshot_check=None,
    publication_snapshot_check=None,
):
    """Burn a live authority exactly once before any mutable publication action."""
    current = now if now is not None else datetime.now(timezone.utc)
    require(current.tzinfo is not None, "current time lacks a timezone")
    current = current.astimezone(timezone.utc).replace(microsecond=0)
    verified, evaluated = revalidate_prepared_receipt(
        verified_path,
        request_path,
        enforce_time=True,
        now=current,
        canonical_bundle_check=canonical_bundle_check,
        source_identity_check=source_identity_check,
        packaging_snapshot_check=packaging_snapshot_check,
        publication_snapshot_check=publication_snapshot_check,
    )
    request = evaluated["request"]
    require(request["execution"]["execute"] is True
            and verified["publication_authorized"] is True,
            "nonce consumption requires a publication-authorized live request")
    ledger_path = Path(ledger_path)
    require(ledger_path.is_absolute()
            and str(ledger_path) == request["execution"]["nonce_ledger_path"],
            "nonce ledger path differs from the authorized path")
    output = Path(output)
    root = Path(verified_path).parent
    require(output == root / "NONCE_CONSUMPTION.json",
            "nonce-consumption receipt path is not canonical")
    parent_descriptor = open_ledger_parent(ledger_path, required_uid)
    flags = os.O_RDWR | os.O_APPEND | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(ledger_path.name, flags, 0o600, dir_fd=parent_descriptor)
    except OSError as error:
        os.close(parent_descriptor)
        raise VerificationError(f"cannot open nonce ledger safely: {error}") from error
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        payload, before = read_locked_ledger(descriptor)
        require(before.st_uid == required_uid and stat.S_IMODE(before.st_mode) == 0o600,
                "nonce ledger must have the required owner and mode 0600")
        _, seen_nonces, seen_authorities = decode_nonce_ledger(payload)
        nonce = request["execution"]["nonce"]
        authority_sha = verified["publication_authority_sha256"]
        require(nonce not in seen_nonces, "publication nonce has already been consumed")
        require(authority_sha not in seen_authorities,
                "publication authority has already been consumed")
        consumed_utc = current.strftime("%Y-%m-%dT%H:%M:%SZ")
        record = nonce_record_value(
            request, evaluated["request_sha256"], authority_sha, consumed_utc, required_uid
        )
        validate_nonce_record(record)
        line = canonical_json_line(record)
        require(before.st_size + len(line) <= MAX_NONCE_LEDGER_BYTES,
                "nonce ledger has no capacity for a complete record")
        os.lseek(descriptor, 0, os.SEEK_END)
        view = memoryview(line)
        while view:
            written = os.write(descriptor, view)
            require(written > 0, "could not append the nonce ledger")
            view = view[written:]
        os.fsync(descriptor)
        after = os.fstat(descriptor)
        require(after.st_size == before.st_size + len(line),
                "nonce ledger append was not exact")
        os.fsync(parent_descriptor)
    finally:
        os.close(descriptor)
        os.close(parent_descriptor)
    receipt = {
        "schema": 1,
        "status": "consumed",
        "ledger_path": str(ledger_path),
        "ledger_offset": before.st_size,
        "ledger_record_sha256": sha256_bytes(line),
        "record": record,
    }
    write_new_json_durable(output, receipt)
    return receipt


def validate_nonce_consumption(path, request, verified, *, required_uid=0):
    receipt = load_json(path, "nonce-consumption receipt")
    exact_keys(
        receipt,
        {"schema", "status", "ledger_path", "ledger_offset",
         "ledger_record_sha256", "record"},
        "nonce-consumption receipt",
    )
    require(type(receipt["schema"]) is int and receipt["schema"] == 1
            and receipt["status"] == "consumed",
            "nonce-consumption receipt status changed")
    require(receipt["ledger_path"] == request["execution"]["nonce_ledger_path"],
            "nonce-consumption ledger path changed")
    require(type(receipt["ledger_offset"]) is int and receipt["ledger_offset"] >= 0,
            "nonce-consumption ledger offset is malformed")
    record = validate_nonce_record(receipt["record"], "nonce-consumption record")
    require(record["uid"] == required_uid,
            "nonce-consumption uid differs from the required operator")
    require(receipt["ledger_record_sha256"] == sha256_bytes(canonical_json_line(record)),
            "nonce-consumption record digest changed")
    expected = nonce_record_value(
        request,
        verified["request_sha256"],
        verified["publication_authority_sha256"],
        record["consumed_utc"],
        record["uid"],
    )
    require(record == expected, "nonce-consumption identity differs from the authority")
    ledger = Path(receipt["ledger_path"])
    parent_descriptor = open_ledger_parent(ledger, required_uid)
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(ledger.name, flags, dir_fd=parent_descriptor)
    except OSError as error:
        os.close(parent_descriptor)
        raise VerificationError(f"cannot open consumed nonce ledger safely: {error}") from error
    try:
        fcntl.flock(descriptor, fcntl.LOCK_SH)
        payload, status = read_locked_ledger(descriptor)
        require(status.st_uid == required_uid and stat.S_IMODE(status.st_mode) == 0o600,
                "consumed nonce ledger ownership or mode changed")
        records, _, _ = decode_nonce_ledger(payload)
        line = canonical_json_line(record)
        offset = receipt["ledger_offset"]
        require(any(
            observed_offset == offset and observed == record and observed_line == line
            for observed_offset, observed, observed_line in records
        ), "nonce-consumption record is absent from the durable ledger")
    finally:
        os.close(descriptor)
        os.close(parent_descriptor)
    return receipt


def verify_extracted_binaries(verified_path, directory, output):
    """Hash docker-cp output on the host; no candidate binary is executed."""
    verified = load_json(Path(verified_path), "verified artifact receipt")
    expected = verified.get("binaries")
    require(isinstance(expected, dict) and set(expected) == set(EXPECTED_BINARIES)
            and all(is_hex64(item) for item in expected.values()),
            "verified binary ledger is malformed")
    directory = Path(directory)
    require(directory.is_dir() and not directory.is_symlink(),
            "extracted-binary directory is missing or unsafe")
    actual_names = {entry.name for entry in directory.iterdir()}
    require(actual_names == set(EXPECTED_BINARIES),
            "extracted-binary directory does not contain exactly six files")
    observed = {}
    for name in EXPECTED_BINARIES:
        digest, status = sha256_regular_file(
            directory / name, f"extracted binary {name}", MAX_BINARY_BYTES
        )
        require(status.st_size > 0 and stat.S_IMODE(status.st_mode) & 0o111,
                f"extracted binary is empty or not executable: {name}")
        observed[name] = digest
    require(observed == expected, "extracted image six-executable hashes changed")
    receipt = {
        "schema": 1,
        "status": "verified",
        "method": "stopped-container-docker-cp-host-sha256",
        "container_started": False,
        "binaries": observed,
    }
    write_new_json_durable(Path(output), receipt)
    return receipt


def validate_extracted_binary_receipt(path, verified):
    receipt = load_json(path, "extracted-binary receipt")
    exact_keys(
        receipt,
        {"schema", "status", "method", "container_started", "binaries"},
        "extracted-binary receipt",
    )
    require(receipt == {
        "schema": 1,
        "status": "verified",
        "method": "stopped-container-docker-cp-host-sha256",
        "container_started": False,
        "binaries": verified["binaries"],
    }, "extracted-binary receipt changed")
    return receipt


def verify_registry_authfile(
    request_path, skopeo_path, output=None, *, required_uid=0, timeout_seconds=60
):
    """Prove the selected protected authfile is readable by the selected skopeo."""
    request = load_request(request_path, enforce_time=False)
    require(request["execution"]["execute"] is True,
            "registry authfile verification requires a live request")
    authfile = Path(request["registry"]["authfile_path"])
    auth_chain_before = protected_parent_chain(
        authfile, required_uid, final_mode=0o700
    )
    try:
        auth_parent = open_absolute_directory_nofollow(
            authfile.parent, "registry authfile parent"
        )
    except (OSError, VerificationError) as error:
        raise VerificationError(f"cannot open registry authfile parent safely: {error}") from error
    try:
        parent_status = os.fstat(auth_parent)
        require(parent_status.st_uid == required_uid
                and stat.S_IMODE(parent_status.st_mode) & 0o022 == 0,
                "registry authfile parent is not protected by the required owner")
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            auth_descriptor = os.open(authfile.name, flags, dir_fd=auth_parent)
        except OSError as error:
            raise VerificationError(f"cannot open registry authfile safely: {error}") from error
        try:
            auth_status = os.fstat(auth_descriptor)
            require(stat.S_ISREG(auth_status.st_mode)
                    and auth_status.st_size <= MAX_JSON_BYTES
                    and auth_status.st_uid == required_uid
                    and stat.S_IMODE(auth_status.st_mode) == 0o600
                    and auth_status.st_nlink == 1,
                    "registry authfile must be a bounded, single-linked required-owner mode-0600 file")
            skopeo_path = Path(skopeo_path)
            require(skopeo_path.is_absolute() and skopeo_path.is_file()
                    and not skopeo_path.is_symlink(), "skopeo path is unsafe")
            tool_chain_before = protected_parent_chain(skopeo_path, required_uid)
            tool_status = os.stat(skopeo_path, follow_symlinks=False)
            require(stat.S_ISREG(tool_status.st_mode)
                    and tool_status.st_uid == required_uid
                    and stat.S_IMODE(tool_status.st_mode) & 0o022 == 0,
                    "skopeo must be required-owner and not group/world writable")
            try:
                probe = subprocess.run(
                    [str(skopeo_path), "login", "--get-login", "--authfile", str(authfile),
                     request["registry"]["credential_host"]],
                    check=True,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=secure_subprocess_environment(),
                    timeout=timeout_seconds,
                )
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                raise VerificationError(
                    "selected authfile is not skopeo-compatible for the credential host"
                ) from error
            current = os.stat(authfile.name, dir_fd=auth_parent, follow_symlinks=False)
            after = os.fstat(auth_descriptor)
            stable_fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
            require(
                all(getattr(auth_status, field) == getattr(current, field)
                    == getattr(after, field) for field in stable_fields),
                "registry authfile changed during its compatibility probe",
            )
            require(protected_parent_chain(
                        authfile, required_uid, final_mode=0o700
                    ) == auth_chain_before,
                    "registry authfile ancestry changed during its compatibility probe")
            require(protected_parent_chain(skopeo_path, required_uid)
                    == tool_chain_before,
                    "skopeo path ancestry changed during its compatibility probe")
            tool_after = os.stat(skopeo_path, follow_symlinks=False)
            require(all(getattr(tool_status, field) == getattr(tool_after, field)
                        for field in stable_fields),
                    "skopeo executable changed during its compatibility probe")
        finally:
            os.close(auth_descriptor)
    finally:
        os.close(auth_parent)
    require(bool(probe.stdout.strip()), "selected authfile has no skopeo login for the credential host")
    receipt = {
        "schema": 1,
        "status": "verified",
        "registry_host": request["registry"]["host"],
        "credential_host": request["registry"]["credential_host"],
        "authfile_path": str(authfile),
        "authfile_uid": auth_status.st_uid,
        "authfile_gid": auth_status.st_gid,
        "authfile_mode": "0600",
        "authfile_single_link": True,
        "skopeo_path": str(skopeo_path),
        "skopeo_uid": tool_status.st_uid,
        "skopeo_mode": f"{stat.S_IMODE(tool_status.st_mode):04o}",
        "compatibility_probe": "skopeo-login-get-login-succeeded",
        "secrets_recorded": False,
    }
    if output is not None:
        write_new_json_durable(Path(output), receipt)
    return receipt


def validate_registry_authfile_receipt(path, request, *, required_uid=0):
    receipt = load_json(path, "registry-authfile receipt")
    exact_keys(
        receipt,
        {"schema", "status", "registry_host", "credential_host", "authfile_path",
         "authfile_uid", "authfile_gid", "authfile_mode", "authfile_single_link",
         "skopeo_path", "skopeo_uid", "skopeo_mode", "compatibility_probe",
         "secrets_recorded"},
        "registry-authfile receipt",
    )
    require(type(receipt["schema"]) is int and receipt["schema"] == 1
            and receipt["status"] == "verified"
            and receipt["registry_host"] == request["registry"]["host"]
            and receipt["credential_host"] == request["registry"]["credential_host"]
            and receipt["authfile_path"] == request["registry"]["authfile_path"]
            and receipt["authfile_uid"] == required_uid
            and receipt["authfile_mode"] == "0600"
            and receipt["authfile_single_link"] is True
            and receipt["compatibility_probe"] == "skopeo-login-get-login-succeeded"
            and receipt["secrets_recorded"] is False,
            "registry-authfile operational contract changed")
    require(isinstance(receipt["authfile_gid"], int) and receipt["authfile_gid"] >= 0
            and isinstance(receipt["skopeo_path"], str)
            and receipt["skopeo_path"].startswith("/")
            and receipt["skopeo_uid"] == required_uid
            and re.fullmatch(r"0[0-7]{3}", receipt["skopeo_mode"] or "") is not None
            and int(receipt["skopeo_mode"], 8) & 0o022 == 0,
            "registry-authfile tool metadata is malformed")
    return receipt


def resolve_evidence_path(root, relative, description):
    require(isinstance(relative, str), f"{description} path is malformed")
    candidate = PurePosixPath(relative)
    require(not candidate.is_absolute() and all(part not in ("", ".", "..") for part in candidate.parts),
            f"{description} path is unsafe")
    path = root.joinpath(*candidate.parts)
    require(path.is_file() and not path.is_symlink(), f"{description} is missing or unsafe")
    require(path.resolve().is_relative_to(root.resolve()), f"{description} escapes the evidence root")
    return path


def parse_response_headers(path, description, require_digest):
    payload = read_regular_bytes(path, description, MAX_HEADER_BYTES)
    blocks = re.split(br"\r?\n\r?\n", payload)
    responses = []
    for block in blocks:
        lines = re.split(br"\r?\n", block)
        if not lines or not lines[0].startswith(b"HTTP/"):
            continue
        try:
            status = int(lines[0].split()[1])
        except (IndexError, ValueError) as error:
            raise VerificationError(f"{description} has a malformed status line") from error
        headers = {}
        for line in lines[1:]:
            require(b":" in line, f"{description} has a malformed header")
            name, value = line.split(b":", 1)
            try:
                key = name.decode("ascii").strip().lower()
                text = value.decode("ascii").strip()
            except UnicodeError as error:
                raise VerificationError(f"{description} has a non-ASCII header") from error
            headers.setdefault(key, []).append(text)
        responses.append((status, headers))
    require(responses, f"{description} has no HTTP response")
    status, headers = responses[-1]
    require(status == 200, f"{description} final HTTP status is not 200")
    digests = headers.get("docker-content-digest", [])
    if require_digest:
        require(len(digests) == 1 and DIGEST_RE.fullmatch(digests[0]) is not None,
                f"{description} lacks one valid same-response digest")
    else:
        require(all(DIGEST_RE.fullmatch(item) is not None for item in digests),
                f"{description} has a malformed content digest")
    return headers, digests


def verify_manifest_response(body_path, headers_path, description, expected_config):
    headers, digests = parse_response_headers(headers_path, description, True)
    body = read_regular_bytes(body_path, description, MAX_JSON_BYTES)
    observed = f"sha256:{sha256_bytes(body)}"
    require(digests == [observed], f"{description} body and same-response digest differ")
    content_types = headers.get("content-type", [])
    require(len(content_types) == 1 and content_types[0].split(";", 1)[0] in OCI_MANIFEST_TYPES,
            f"{description} content type changed")
    manifest = decode_json(body, description)
    require(isinstance(manifest, dict) and manifest.get("schemaVersion") == 2,
            f"{description} schema changed")
    require(manifest.get("mediaType") in OCI_MANIFEST_TYPES, f"{description} media type changed")
    config = manifest.get("config")
    require(isinstance(config, dict) and config.get("digest") == expected_config,
            f"{description} config digest changed")
    require(config.get("mediaType") in OCI_CONFIG_TYPES, f"{description} config media type changed")
    require(isinstance(config.get("size"), int) and not isinstance(config["size"], bool)
            and config["size"] >= 0, f"{description} config size is malformed")
    layers = manifest.get("layers")
    require(isinstance(layers, list) and layers, f"{description} has no layers")
    for layer in layers:
        require(isinstance(layer, dict) and DIGEST_RE.fullmatch(layer.get("digest") or "") is not None,
                f"{description} layer digest is malformed")
        require(layer.get("mediaType") in OCI_LAYER_TYPES, f"{description} layer media type changed")
        require(isinstance(layer.get("size"), int) and not isinstance(layer["size"], bool)
                and layer["size"] >= 0,
                f"{description} layer size is malformed")
    require(len({layer["digest"] for layer in layers}) == len(layers),
            f"{description} repeats a layer")
    return observed, manifest, body


def verify_registry_evidence(
    verified_path,
    request_path,
    tag_manifest,
    tag_headers,
    digest_manifest,
    digest_headers,
    config_body,
    config_headers,
    local_inspect,
    extracted_binaries,
    nonce_consumption,
    registry_authfile,
    publication_outcome,
    output,
    *,
    canonical_bundle_check=None,
    source_identity_check=None,
    packaging_snapshot_check=None,
    publication_snapshot_check=None,
    required_uid=0,
):
    verified_path = Path(verified_path)
    root = verified_path.parent
    verified, evaluated = revalidate_prepared_receipt(
        verified_path,
        request_path,
        enforce_time=False,
        canonical_bundle_check=canonical_bundle_check,
        source_identity_check=source_identity_check,
        packaging_snapshot_check=packaging_snapshot_check,
        publication_snapshot_check=publication_snapshot_check,
    )
    request = evaluated["request"]
    require(request["execution"]["execute"] is True,
            "registry verification requires live execution authority")
    require(verified["publication_authorized"] is True
            and verified["candidate_authorization_ready"] is True,
            "verified artifact receipt does not authorize publication")
    nonce_receipt = validate_nonce_consumption(
        Path(nonce_consumption), request, verified, required_uid=required_uid
    )
    authfile_receipt = validate_registry_authfile_receipt(
        Path(registry_authfile), request, required_uid=required_uid
    )
    binary_receipt = validate_extracted_binary_receipt(Path(extracted_binaries), verified)
    require(publication_outcome in {
        "tag-already-exact", "copy-succeeded", "copy-error-remote-exact"
    }, "publication outcome is malformed")
    expected_config = verified["oci"]["source_config_digest"]
    source_manifest_path = resolve_evidence_path(
        root, verified["oci"]["source_manifest_path"], "source OCI manifest"
    )
    source_manifest = read_regular_bytes(
        source_manifest_path, "source OCI manifest", MAX_JSON_BYTES
    )
    expected_manifest = verified["oci"]["source_manifest_digest"]
    require(expected_manifest == f"sha256:{sha256_bytes(source_manifest)}",
            "source OCI manifest digest changed")
    tag_digest, tag_value, tag_bytes = verify_manifest_response(
        Path(tag_manifest), Path(tag_headers), "tag manifest response", expected_config
    )
    digest_value, digest_json, digest_bytes = verify_manifest_response(
        Path(digest_manifest), Path(digest_headers), "digest manifest response", expected_config
    )
    require(tag_digest == digest_value and tag_bytes == digest_bytes and tag_value == digest_json,
            "tag manifest and digest refetch differ")
    require(tag_digest == expected_manifest and tag_bytes == source_manifest,
            "registry manifest differs from the sealed source OCI manifest")
    require(tag_value["layers"] == verified["oci"]["layers"],
            "registry layer graph differs from the sealed source OCI manifest")
    config_path = Path(config_body)
    config_header_path = Path(config_headers)
    _, config_digests = parse_response_headers(config_header_path, "registry config response", False)
    remote_config = read_regular_bytes(config_path, "registry config", MAX_JSON_BYTES)
    require(f"sha256:{sha256_bytes(remote_config)}" == expected_config,
            "registry config body differs from the source OCI config")
    require(tag_value["config"]["size"] == len(remote_config),
            "registry manifest config size differs from the verified config")
    require(all(item == expected_config for item in config_digests),
            "registry config response advertises another digest")
    source_config_path = resolve_evidence_path(root, verified["oci"]["source_config_path"], "source OCI config")
    require(remote_config == read_regular_bytes(
        source_config_path, "source OCI config", MAX_JSON_BYTES
    ), "remote config bytes differ from source OCI config")
    config = decode_json(remote_config, "registry config")
    runtime = config.get("config")
    require(isinstance(runtime, dict) and isinstance(runtime.get("Labels"), dict),
            "registry config labels are absent")
    labels = runtime["Labels"]
    source = verified["source"]
    require(labels.get("org.blackcoin.source.commit") == source["commit"]
            and labels.get("org.blackcoin.source.tree") == source["tree"],
            "registry config H/T labels changed")
    for binary, digest in verified["binaries"].items():
        require(labels.get(f"org.blackcoin.binary.{binary}.sha256") == digest,
                f"registry config binary label changed: {binary}")
    imported = load_json(Path(local_inspect), "imported image inspection")
    require(isinstance(imported, list) and len(imported) == 1, "imported image inspection changed")
    image = imported[0]
    require(image.get("Id") == expected_config and image.get("Os") == "linux"
            and image.get("Architecture") == "amd64", "imported image config/platform changed")
    expected_local_ref = (
        f"blackcoin-v3015-publication:{source['commit'][:12]}-"
        f"{request['execution']['nonce'][:12]}"
    )
    require(isinstance(image.get("RepoTags"), list)
            and expected_local_ref in image["RepoTags"],
            "imported image lacks the nonce-scoped local reference")
    imported_runtime = image.get("Config")
    require(isinstance(imported_runtime, dict) and imported_runtime.get("Labels") == labels,
            "imported image labels differ from the source config")
    require(binary_receipt["binaries"] == verified["binaries"],
            "host-extracted image binaries differ from the sealed ledger")
    require(request["registry"]["host"] == EXPECTED_REGISTRY_HOST
            and authfile_receipt["registry_host"] == EXPECTED_REGISTRY_HOST,
            "registry host is not the authorized endpoint")
    repository = request["registry"]["repository"]
    immutable = f"{repository}@{tag_digest}"
    registry_immutable = f"{request['registry']['host']}/{immutable}"
    copy_state = {
        "tag-already-exact": {
            "copy_attempted": False,
            "copy_exit_success": None,
            "published_by_this_operation": False,
        },
        "copy-succeeded": {
            "copy_attempted": True,
            "copy_exit_success": True,
            "published_by_this_operation": True,
        },
        "copy-error-remote-exact": {
            "copy_attempted": True,
            "copy_exit_success": False,
            "published_by_this_operation": None,
        },
    }[publication_outcome]
    core_evidence = verified["core_ci_evidence"]
    validate_core_ci_evidence_shape(
        core_evidence, source=verified["source"], require_merged=True
    )
    merge_commit_sha = (
        core_evidence["merge_commit"]["sha"]
        if core_evidence["merge_commit"] is not None else None
    )
    handoff = {
        "schema": 2,
        "classification": EXPECTED_CLASSIFICATION,
        "publication_authority_sha256": verified["publication_authority_sha256"],
        "request_sha256": verified["request_sha256"],
        "candidate_source_commit": verified["source"]["commit"],
        "candidate_source_tree": verified["source"]["tree"],
        "candidate_core_ci_run_id": verified["core_ci"]["run_id"],
        "candidate_core_ci_run_attempt": verified["core_ci"]["run_attempt"],
        "candidate_core_ci_evidence_sha256": verified["core_ci"]["evidence_sha256"],
        "candidate_core_ci_authority_state": core_evidence["authority_state"],
        "candidate_core_ci_current_main_sha": core_evidence["current_main_sha"],
        "candidate_core_ci_merge_commit_sha": merge_commit_sha,
        "candidate_core_ci_run_completed_at": core_evidence["run_completed_at"],
        "candidate_core_ci_merged_at": core_evidence["pull_request_merged_at"],
        "candidate_required_checks_sha256": verified["core_ci"]["required_checks_sha256"],
        "candidate_thread_sanitizer_artifact": verified["core_ci"]["thread_sanitizer_artifact"],
        "candidate_packaging_tooling_commit": verified["packaging"]["tooling_commit"],
        "candidate_packaging_tooling_tree": verified["packaging"]["tooling_tree"],
        "candidate_packaging_run_id": verified["packaging"]["run_id"],
        "candidate_packaging_run_attempt": verified["packaging"]["run_attempt"],
        "candidate_packaging_run_metadata_sha256": verified["packaging"]["run_metadata_sha256"],
        "candidate_artifact_id": verified["github_artifact"]["id"],
        "candidate_artifact_name": verified["github_artifact"]["name"],
        "candidate_artifact_run_id": verified["github_artifact"]["packaging_run_id"],
        "candidate_artifact_run_attempt": verified["github_artifact"]["packaging_run_attempt"],
        "github_artifact_api_metadata_sha256": verified["github_artifact"]["api_metadata_sha256"],
        "github_artifact_zip_sha256": verified["github_artifact"]["zip_sha256"],
        "candidate_bundle_sha256": verified["bundle"]["sha256sums_sha256"],
        "candidate_bundle_sha256sums_sha256": verified["bundle"]["sha256sums_sha256"],
        "candidate_manifest_sha256": verified["bundle"]["manifest_sha256"],
        "candidate_provenance_sha256": verified["bundle"]["provenance_sha256"],
        "candidate_tooling_sha256": verified["bundle"]["packaging_package_sha256sums_sha256"],
        "candidate_packaging_tooling_sha256": (
            verified["bundle"]["packaging_package_sha256sums_sha256"]
        ),
        "candidate_publication_tooling_commit": verified["publication_tooling"]["commit"],
        "candidate_publication_tooling_tree": verified["publication_tooling"]["tree"],
        "candidate_publication_tooling_sha256": (
            verified["bundle"]["publication_package_sha256sums_sha256"]
        ),
        "candidate_image_ref": immutable,
        "candidate_registry_image_ref": registry_immutable,
        "candidate_image_id": expected_config,
        "candidate_oci_archive_sha256": verified["oci"]["archive_sha256"],
        "candidate_oci_manifest_sha256": (
            verified["oci"]["source_manifest_digest"].removeprefix("sha256:")
        ),
        "candidate_oci_config_sha256": (
            verified["oci"]["source_config_digest"].removeprefix("sha256:")
        ),
        "candidate_oci_layers": verified["oci"]["layers"],
        "candidate_oci_rootfs_diff_ids": verified["oci"]["rootfs_diff_ids"],
        "binary_sha256s": verified["binaries"],
        "source": verified["source"],
        "core_ci": verified["core_ci"],
        "core_ci_evidence": core_evidence,
        "packaging": verified["packaging"],
        "artifact": verified["github_artifact"],
        "publication_tooling": verified["publication_tooling"],
        "bundle": verified["bundle"],
        "registry": {
            "host": request["registry"]["host"],
            "credential_host": request["registry"]["credential_host"],
            "repository": repository,
            "tag": request["registry"]["tag"],
            "tag_ref": f"{repository}:{request['registry']['tag']}",
            "manifest_digest": tag_digest,
            "config_digest": expected_config,
            "immutable_image_ref": immutable,
            "registry_immutable_image_ref": registry_immutable,
        },
        "oci": {
            "archive_sha256": verified["oci"]["archive_sha256"],
            "manifest_digest": verified["oci"]["source_manifest_digest"],
            "config_digest": verified["oci"]["source_config_digest"],
            "layers": verified["oci"]["layers"],
            "rootfs_diff_ids": verified["oci"]["rootfs_diff_ids"],
        },
        "binaries": verified["binaries"],
        "authorization": {
            "nonce": request["execution"]["nonce"],
            "issued_utc": request["execution"]["issued_utc"],
            "expires_utc": request["execution"]["expires_utc"],
            "nonce_ledger_path": request["execution"]["nonce_ledger_path"],
            "nonce_ledger_record_sha256": nonce_receipt["ledger_record_sha256"],
            "exclusive_writer_authority_sha256": (
                request["execution"]["exclusive_writer_authority_sha256"]
            ),
        },
    }
    result = {
        "schema": 2,
        "result": "passed",
        "request_sha256": verified["request_sha256"],
        "publication_authority_sha256": verified["publication_authority_sha256"],
        "publication_authority": verified["publication_authority"],
        "source": verified["source"],
        "core_ci": verified["core_ci"],
        "core_ci_evidence": core_evidence,
        "packaging": verified["packaging"],
        "publication_tooling": verified["publication_tooling"],
        "artifact": verified["github_artifact"],
        "bundle": verified["bundle"],
        "source_oci": verified["oci"],
        "remote_oci": {
            "manifest_digest": tag_digest,
            "config_digest": expected_config,
            "layers": tag_value["layers"],
            "manifest_exactly_equal_to_source": True,
            "config_exactly_equal_to_source": True,
        },
        "registry": {
            "host": request["registry"]["host"],
            "credential_host": request["registry"]["credential_host"],
            "repository": repository,
            "tag": request["registry"]["tag"],
            "authfile": authfile_receipt,
        },
        "target_tag": f"{repository}:{request['registry']['tag']}",
        "immutable_image_ref": immutable,
        "registry_immutable_image_ref": registry_immutable,
        "registry_manifest_digest": tag_digest,
        "registry_config_digest": expected_config,
        "binaries": verified["binaries"],
        "nonce_consumption": nonce_receipt,
        "exclusive_writer_authority": verified["exclusive_writer_authority"],
        "publication_outcome": publication_outcome,
        **copy_state,
        "same_response_digest_verified": True,
        "digest_refetch_verified": True,
        "source_manifest_exact_equality_verified": True,
        "remote_config_bytes_verified": True,
        "remote_exact_equality_verified": True,
        "stopped_container_binary_extraction": binary_receipt,
        "candidate_container_started": False,
        "mutable_tag_is_rollout_authority": False,
        "handoff": handoff,
    }
    require(result["handoff"]["registry"]["manifest_digest"]
            == result["source_oci"]["source_manifest_digest"]
            == result["registry_manifest_digest"],
            "handoff manifest identity is internally inconsistent")
    require(result["handoff"]["registry"]["config_digest"]
            == result["source_oci"]["source_config_digest"]
            == result["registry_config_digest"],
            "handoff config identity is internally inconsistent")
    require(result["handoff"]["registry"]["immutable_image_ref"]
            == result["immutable_image_ref"],
            "handoff immutable image reference changed")
    require(
        result["handoff"]["candidate_artifact_run_id"]
        == result["handoff"]["candidate_packaging_run_id"]
        == result["artifact"]["packaging_run_id"]
        and result["handoff"]["candidate_artifact_run_attempt"]
        == result["handoff"]["candidate_packaging_run_attempt"]
        == result["artifact"]["packaging_run_attempt"],
        "handoff packaging and artifact run identities differ",
    )
    require(
        result["handoff"]["github_artifact_zip_sha256"]
        == result["artifact"]["zip_sha256"]
        and result["handoff"]["candidate_bundle_sha256"]
        == result["handoff"]["candidate_bundle_sha256sums_sha256"]
        == result["bundle"]["sha256sums_sha256"]
        and result["handoff"]["github_artifact_zip_sha256"]
        != result["handoff"]["candidate_bundle_sha256sums_sha256"],
        "handoff ZIP and internal bundle seals are confused",
    )
    require(
        result["handoff"]["core_ci_evidence"] == result["core_ci_evidence"]
        and result["handoff"]["candidate_core_ci_evidence_sha256"]
        == verified["core_ci"]["evidence_sha256"]
        and result["handoff"]["candidate_core_ci_authority_state"]
        == result["core_ci_evidence"]["authority_state"]
        and result["handoff"]["candidate_core_ci_current_main_sha"]
        == result["core_ci_evidence"]["current_main_sha"]
        and result["handoff"]["candidate_core_ci_merge_commit_sha"] == merge_commit_sha
        and result["handoff"]["candidate_core_ci_run_completed_at"]
        == result["core_ci_evidence"]["run_completed_at"]
        and result["handoff"]["candidate_core_ci_merged_at"]
        == result["core_ci_evidence"]["pull_request_merged_at"],
        "handoff terminal Core-CI authority changed",
    )
    require(
        result["handoff"]["candidate_oci_layers"]
        == result["handoff"]["oci"]["layers"]
        == result["source_oci"]["layers"]
        == result["remote_oci"]["layers"]
        and result["handoff"]["binary_sha256s"] == result["binaries"],
        "handoff OCI graph or binary ledger changed",
    )
    write_new_json_durable(Path(output), result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare = subparsers.add_parser("prepare")
    prepare.add_argument("--request", required=True, type=Path)
    prepare.add_argument("--output", required=True, type=Path)
    consume = subparsers.add_parser("consume-nonce")
    consume.add_argument("--verified", required=True, type=Path)
    consume.add_argument("--request", required=True, type=Path)
    consume.add_argument("--ledger", required=True, type=Path)
    consume.add_argument("--output", required=True, type=Path)
    binaries = subparsers.add_parser("verify-extracted-binaries")
    binaries.add_argument("--verified", required=True, type=Path)
    binaries.add_argument("--directory", required=True, type=Path)
    binaries.add_argument("--output", required=True, type=Path)
    authfile = subparsers.add_parser("verify-authfile")
    authfile.add_argument("--request", required=True, type=Path)
    authfile.add_argument("--skopeo", required=True, type=Path)
    authfile.add_argument("--output", required=True, type=Path)
    validate_authfile = subparsers.add_parser("validate-authfile")
    validate_authfile.add_argument("--request", required=True, type=Path)
    validate_authfile.add_argument("--skopeo", required=True, type=Path)
    anchor = subparsers.add_parser("anchor-live-output")
    anchor.add_argument("--root", required=True, type=Path)
    anchor.add_argument("--output", required=True, type=Path)
    verify_anchor = subparsers.add_parser("verify-live-output-anchor")
    verify_anchor.add_argument("--root", required=True, type=Path)
    verify_anchor.add_argument("--anchor", required=True, type=Path)
    durable = subparsers.add_parser("fsync-tree")
    durable.add_argument("--root", required=True, type=Path)
    complete = subparsers.add_parser("complete-publication")
    complete.add_argument("--root", required=True, type=Path)
    complete.add_argument("--result", required=True, type=Path)
    complete.add_argument("--manifest", required=True, type=Path)
    complete.add_argument("--output", required=True, type=Path)
    verify_complete = subparsers.add_parser("verify-completion")
    verify_complete.add_argument("--root", required=True, type=Path)
    verify_complete.add_argument("--completion", required=True, type=Path)
    registry = subparsers.add_parser("verify-registry")
    registry.add_argument("--verified", required=True, type=Path)
    registry.add_argument("--request", required=True, type=Path)
    registry.add_argument("--tag-manifest", required=True, type=Path)
    registry.add_argument("--tag-headers", required=True, type=Path)
    registry.add_argument("--digest-manifest", required=True, type=Path)
    registry.add_argument("--digest-headers", required=True, type=Path)
    registry.add_argument("--config-body", required=True, type=Path)
    registry.add_argument("--config-headers", required=True, type=Path)
    registry.add_argument("--local-inspect", required=True, type=Path)
    registry.add_argument("--extracted-binaries", required=True, type=Path)
    registry.add_argument("--nonce-consumption", required=True, type=Path)
    registry.add_argument("--registry-authfile", required=True, type=Path)
    registry.add_argument(
        "--publication-outcome", required=True,
        choices=("tag-already-exact", "copy-succeeded", "copy-error-remote-exact"),
    )
    registry.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            value = prepare_artifact(args.request, args.output)
            print(
                f"VERIFIED_INPUT={args.output / 'VERIFIED_INPUT.json'} "
                f"PUBLICATION_AUTHORIZED={str(value['publication_authorized']).lower()}"
            )
        elif args.command == "consume-nonce":
            value = consume_nonce(
                args.verified, args.request, args.ledger, args.output
            )
            print(f"NONCE_CONSUMPTION={args.output} RECORD={value['ledger_record_sha256']}")
        elif args.command == "verify-extracted-binaries":
            verify_extracted_binaries(args.verified, args.directory, args.output)
            print(f"EXTRACTED_BINARIES={args.output}")
        elif args.command == "verify-authfile":
            verify_registry_authfile(args.request, args.skopeo, args.output)
            print(f"REGISTRY_AUTHFILE={args.output}")
        elif args.command == "validate-authfile":
            verify_registry_authfile(args.request, args.skopeo)
            print(f"REGISTRY_AUTHFILE_REVALIDATED={args.request}")
        elif args.command == "anchor-live-output":
            create_output_anchor(args.root, args.output)
            print(f"LIVE_OUTPUT_ANCHOR={args.output}")
        elif args.command == "verify-live-output-anchor":
            validate_output_anchor(args.root, args.anchor)
            print(f"LIVE_OUTPUT_ANCHOR_VERIFIED={args.anchor}")
        elif args.command == "fsync-tree":
            fsync_tree(args.root)
            print(f"DURABLE_EVIDENCE_ROOT={args.root}")
        elif args.command == "complete-publication":
            value = create_publication_completion(
                args.root, args.result, args.manifest, args.output
            )
            print(
                f"PUBLICATION_COMPLETE={args.output} "
                f"IMMUTABLE_IMAGE_REF={value['registry']['immutable_image_ref']}"
            )
        elif args.command == "verify-completion":
            value = validate_publication_completion(args.root, args.completion)
            print(
                f"PUBLICATION_COMPLETE_VERIFIED={args.completion} "
                f"IMMUTABLE_IMAGE_REF={value['registry']['immutable_image_ref']}"
            )
        else:
            value = verify_registry_evidence(
                args.verified, args.request, args.tag_manifest, args.tag_headers,
                args.digest_manifest, args.digest_headers, args.config_body,
                args.config_headers, args.local_inspect, args.extracted_binaries,
                args.nonce_consumption, args.registry_authfile,
                args.publication_outcome, args.output,
            )
            print(f"IMMUTABLE_IMAGE_REF={value['immutable_image_ref']}")
    except (OSError, UnicodeError, VerificationError) as error:
        parser.exit(1, f"v30.1.5 candidate publication verification failed: {error}\n")


if __name__ == "__main__":
    main()
