#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Generate and verify exact-SHA v30.1.5 candidate metadata."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
import tarfile


EXPECTED_CLASSIFICATION = "V30_1_5_CANDIDATE_CANARY_ONLY"
EXPECTED_REPOSITORY = "Blackcoin-Dev/Blackcoin"
EXPECTED_SOURCE_COMMIT = "a0695f22740e111d0487a194fb46f1bae05952c5"
EXPECTED_SOURCE_TREE = "86df040ae5eb8e819e940dd08364bcc177a72195"
EXPECTED_RELEASE_ANCESTOR = "13262151077cce3f72d07d17dc7725b2b6a8e1ab"
BLOCKED_AUTHORIZATION_STATE = "blocked_pending_final_signed_source_and_green_ci"
READY_AUTHORIZATION_STATE = "authorized_exact_signed_source_and_green_ci"
EXPECTED_SIGNER = "Blackcoin-Dev"
EXPECTED_ACTOR = "Blackcoin-Dev"
EXPECTED_FINGERPRINT = "SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70"
EXPECTED_BASE_MANIFEST = "sha256:7a384dd5f12c15fb41b36868d946007524bebf97650883d533635658641e04a2"
EXPECTED_BASE_CONFIG = "sha256:620146d14a57fe0d5d1fc29a7d913d47787ba924c96ba06eeb1ddbe8efb73909"
EXPECTED_BASE_REPOSITORY = "qqblackcoin/blackcoin-v4-gui"
EXPECTED_BASE_REFERENCE = f"{EXPECTED_BASE_REPOSITORY}@{EXPECTED_BASE_MANIFEST}"
EXPECTED_WORKFLOW_PATH = ".github/workflows/pr-gate.yml"
EXPECTED_WORKFLOW_NAME = "pull-request safety gate"
EXPECTED_CORE_CI_EVENT = "pull_request"
EXPECTED_CORE_CI_PR = 49
EXPECTED_CORE_CI_BASE = "19baffef25af36e177db2975780e0641b59753aa"
EXPECTED_CORE_CI_BASE_TREE = "f897d758aee1849f02126f0ee3b7a4be9bd3be8c"
EXPECTED_BASE_WORKFLOW_BLOB_SHA256 = "24c14f2fe4bd7b25de38e71a80bf05efcec00d2b3009c3efd4ad20b90bbda869"
EXPECTED_SOURCE_WORKFLOW_BLOB_SHA256 = "24c14f2fe4bd7b25de38e71a80bf05efcec00d2b3009c3efd4ad20b90bbda869"
EXPECTED_REQUIRED_CHECKS_APP_ID = 15368
EXPECTED_REQUIRED_CHECKS = (
    "source identity, workflow syntax, and lint",
    "pinned independent quantum crypto provenance",
    "pinned native build and unit tests",
    "measured worst-case quantum crypto resources (Linux x86_64)",
    "Linux ARM64 native cryptographic vectors and resources",
    "Linux ARM64 native UBSan block-harness gate",
    "Build pinned Windows x86_64 vector binaries",
    "Windows x86_64 native cryptographic vectors and resources",
    "macOS Intel native cryptographic vectors",
    "macOS Apple Silicon native cryptographic vectors",
    "critical Gold Rush, lifecycle, wallet, and recovery tests",
    "real v26.2, v28.4, v30.1, and candidate interoperability",
    "complete extended functional suite",
    "address-undefined-sanitizer consensus and liveness gate",
    "thread-sanitizer consensus and liveness gate",
    "source-pinned sanitizer regression smoke",
)
EXPECTED_BINARIES = (
    "blackcoin-cli",
    "blackcoin-qt",
    "blackcoin-tx",
    "blackcoin-util",
    "blackcoin-wallet",
    "blackcoind",
)
FULL_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
HEX_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
NUMERIC_RE = re.compile(r"^[1-9][0-9]*$")
OCI_MANIFEST_MEDIA_TYPE = "application/vnd.oci.image.manifest.v1+json"
OCI_CONFIG_MEDIA_TYPE = "application/vnd.oci.image.config.v1+json"
OCI_LAYER_MEDIA_TYPES = {
    "application/vnd.oci.image.layer.v1.tar",
    "application/vnd.oci.image.layer.v1.tar+gzip",
    "application/vnd.oci.image.layer.v1.tar+zstd",
}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha256(path):
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def sha256_stream(source):
    hasher = hashlib.sha256()
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        hasher.update(chunk)
    return hasher.hexdigest()


class DuplicateJsonKeyError(ValueError):
    """Raised when a JSON object repeats a key at any nesting depth."""


def reject_duplicate_json_keys(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise DuplicateJsonKeyError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def decode_json(payload, description):
    try:
        text = payload.decode("utf-8") if isinstance(payload, bytes) else payload
        return json.loads(text, object_pairs_hook=reject_duplicate_json_keys)
    except (UnicodeError, json.JSONDecodeError, DuplicateJsonKeyError) as error:
        raise RuntimeError(f"cannot parse {description}: {error}") from error


def canonical_json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def load_json(path, description, require_canonical=False):
    require(path.is_file() and not path.is_symlink(), f"{description} must be a regular file")
    try:
        payload = path.read_bytes()
    except OSError as error:
        raise RuntimeError(f"cannot read {description}: {error}") from error
    value = decode_json(payload, description)
    if require_canonical:
        require(
            payload == canonical_json_bytes(value),
            f"{description} must use canonical JSON serialization",
        )
    return value


def require_exact_keys(value, expected, description):
    require(isinstance(value, dict), f"{description} must be an object")
    require(set(value) == set(expected), f"{description} has unexpected or missing fields")


def validate_policy(policy_path):
    policy = load_json(policy_path, "candidate policy")
    require_exact_keys(
        policy,
        {
            "schema", "classification", "version", "authorization", "source",
            "core_ci", "base_image", "image", "artifacts", "binaries",
        },
        "candidate policy",
    )
    require(policy["schema"] == 2, "candidate policy schema is not supported")
    require(policy["classification"] == EXPECTED_CLASSIFICATION, "candidate classification changed")
    require(policy["version"] == "30.1.5", "candidate version must be 30.1.5")

    authorization = policy["authorization"]
    require_exact_keys(
        authorization,
        {
            "state", "dispatch_enabled", "temporary_source_pin", "core_ci_run_id",
            "core_ci_run_attempt", "thread_sanitizer_artifact",
        },
        "candidate authorization policy",
    )
    if authorization["state"] == BLOCKED_AUTHORIZATION_STATE:
        require(authorization["dispatch_enabled"] is False, "blocked candidate cannot be dispatchable")
        require(authorization["temporary_source_pin"] is True, "blocked candidate must identify its temporary source pin")
        require(authorization["core_ci_run_id"] is None, "blocked candidate cannot pin a Core CI run")
        require(authorization["core_ci_run_attempt"] is None, "blocked candidate cannot pin a Core CI run attempt")
        require(authorization["thread_sanitizer_artifact"] is None, "blocked candidate cannot pin a sanitizer artifact")
    elif authorization["state"] == READY_AUTHORIZATION_STATE:
        require(authorization["dispatch_enabled"] is True, "authorized candidate must be dispatchable")
        require(authorization["temporary_source_pin"] is False, "authorized candidate cannot retain a temporary source pin")
        require(
            type(authorization["core_ci_run_id"]) is int and authorization["core_ci_run_id"] > 0,
            "authorized candidate must pin a positive Core CI run ID",
        )
        require(
            type(authorization["core_ci_run_attempt"]) is int and authorization["core_ci_run_attempt"] > 0,
            "authorized candidate must pin a positive Core CI run attempt",
        )
        sanitizer = authorization["thread_sanitizer_artifact"]
        require_exact_keys(
            sanitizer,
            {"id", "name", "zip_sha256", "reports_sha256"},
            "authorized ThreadSanitizer artifact",
        )
        require(type(sanitizer["id"]) is int and sanitizer["id"] > 0, "sanitizer artifact ID is malformed")
        expected_artifact_name = (
            f"sanitizer-reports-thread-sanitizer-{EXPECTED_SOURCE_COMMIT}-attempt-"
            f"{authorization['core_ci_run_attempt']}"
        )
        require(sanitizer["name"] == expected_artifact_name, "sanitizer artifact name changed")
        require(
            isinstance(sanitizer["zip_sha256"], str) and HEX_SHA256_RE.fullmatch(sanitizer["zip_sha256"]),
            "sanitizer artifact ZIP digest is malformed",
        )
        require(
            isinstance(sanitizer["reports_sha256"], str) and HEX_SHA256_RE.fullmatch(sanitizer["reports_sha256"]),
            "sanitizer reports digest is malformed",
        )
    else:
        raise RuntimeError("candidate authorization state is not supported")

    source = policy["source"]
    require_exact_keys(
        source,
        {
            "repository", "commit", "tree", "immutable_release_ancestor", "actor", "signer",
            "signing_fingerprint", "configured_version", "release_candidate", "is_release",
        },
        "candidate source policy",
    )
    require(source["repository"] == EXPECTED_REPOSITORY, "source repository changed")
    require(source["commit"] == EXPECTED_SOURCE_COMMIT, "approved candidate source changed")
    require(source["tree"] == EXPECTED_SOURCE_TREE, "approved candidate source tree changed")
    require(source["immutable_release_ancestor"] == EXPECTED_RELEASE_ANCESTOR, "release ancestor changed")
    require(source["actor"] == EXPECTED_ACTOR, "workflow actor changed")
    require(source["signer"] == EXPECTED_SIGNER, "source signer changed")
    require(source["signing_fingerprint"] == EXPECTED_FINGERPRINT, "source signing key changed")
    require(source["configured_version"] == "30.1.5", "configured version changed")
    require(source["release_candidate"] == 0, "source must remain RC0")
    require(source["is_release"] is True, "source must retain CLIENT_VERSION_IS_RELEASE=true")

    core_ci = policy["core_ci"]
    require_exact_keys(
        core_ci,
        {
            "event", "pull_request_number", "head_sha", "head_tree", "base_sha", "base_tree", "repository",
            "head_repository", "workflow_path", "workflow_name",
            "base_workflow_blob_sha256", "source_workflow_blob_sha256",
            "required_checks_app_id", "required_checks",
        },
        "Core CI policy",
    )
    require(core_ci["event"] == EXPECTED_CORE_CI_EVENT, "Core CI event changed")
    require(core_ci["pull_request_number"] == EXPECTED_CORE_CI_PR, "Core CI pull request changed")
    require(core_ci["head_sha"] == EXPECTED_SOURCE_COMMIT, "Core CI policy head changed")
    require(core_ci["head_tree"] == EXPECTED_SOURCE_TREE, "Core CI policy head tree changed")
    require(core_ci["base_sha"] == EXPECTED_CORE_CI_BASE, "Core CI policy base changed")
    require(core_ci["base_tree"] == EXPECTED_CORE_CI_BASE_TREE, "Core CI policy base tree changed")
    require(core_ci["repository"] == EXPECTED_REPOSITORY, "Core CI repository changed")
    require(core_ci["head_repository"] == EXPECTED_REPOSITORY, "Core CI head repository changed")
    require(core_ci["workflow_path"] == EXPECTED_WORKFLOW_PATH, "Core CI workflow path changed")
    require(core_ci["workflow_name"] == EXPECTED_WORKFLOW_NAME, "Core CI workflow name changed")
    require(
        core_ci["base_workflow_blob_sha256"] == EXPECTED_BASE_WORKFLOW_BLOB_SHA256,
        "Core CI base workflow blob changed",
    )
    require(
        core_ci["source_workflow_blob_sha256"] == EXPECTED_SOURCE_WORKFLOW_BLOB_SHA256,
        "Core CI source workflow blob changed",
    )
    require(
        core_ci["required_checks"] == list(EXPECTED_REQUIRED_CHECKS),
        "Core CI required check set changed",
    )
    require(
        type(core_ci["required_checks_app_id"]) is int
        and core_ci["required_checks_app_id"] == EXPECTED_REQUIRED_CHECKS_APP_ID,
        "Core CI required-check app ID changed",
    )

    base = policy["base_image"]
    require_exact_keys(
        base,
        {"role", "repository", "reference", "manifest_digest", "config_digest"},
        "base-image policy",
    )
    require(
        base["role"] == "immutable-v30.1.4-rootfs-and-rollback-only",
        "v30.1.4 image must remain only the immutable rootfs and rollback base",
    )
    require(base["repository"] == EXPECTED_BASE_REPOSITORY, "base repository changed")
    require(base["reference"] == EXPECTED_BASE_REFERENCE, "base reference is not immutable v30.1.4")
    require(base["manifest_digest"] == EXPECTED_BASE_MANIFEST, "base manifest digest changed")
    require(base["config_digest"] == EXPECTED_BASE_CONFIG, "base config digest changed")

    image = policy["image"]
    require_exact_keys(
        image,
        {
            "repository", "tag_template", "archive_template", "os", "architecture",
            "user", "entrypoint", "cmd", "working_dir", "healthcheck",
        },
        "candidate-image policy",
    )
    require(image["repository"] == EXPECTED_BASE_REPOSITORY, "candidate image repository changed")
    require(image["tag_template"] == "30.1.5-candidate-{source12}-ci1", "candidate tag template changed")
    require(
        image["archive_template"] == "blackcoin-v4-gui-30.1.5-candidate-{source12}.oci.tar",
        "candidate archive template changed",
    )
    require(image["os"] == "linux" and image["architecture"] == "amd64", "candidate platform changed")
    require(image["user"] == "blackcoin", "candidate runtime user changed")
    require(image["entrypoint"] == ["/home/blackcoin/start-gui.sh"], "candidate entrypoint changed")
    require(image["cmd"] is None, "candidate Cmd must remain absent")
    require(image["working_dir"] == "/home/blackcoin", "candidate working directory changed")
    require(image["healthcheck"] is None, "candidate must preserve the base image's absent Healthcheck")

    artifacts = policy["artifacts"]
    require_exact_keys(artifacts, {"prefix_template", "github_artifact_template"}, "artifact policy")
    require(
        artifacts["prefix_template"] == "Blackcoin-30.1.5-candidate-{source12}",
        "artifact prefix changed",
    )
    require(
        artifacts["github_artifact_template"] ==
        "v30.1.5-candidate-linux-x86_64-{source40}-attempt-{attempt}",
        "GitHub artifact template changed",
    )
    require(policy["binaries"] == list(EXPECTED_BINARIES), "candidate binary inventory changed")
    return policy


def artifact_names(policy):
    source = policy["source"]["commit"]
    short = source[:12]
    prefix = policy["artifacts"]["prefix_template"].format(source12=short)
    archive = policy["image"]["archive_template"].format(source12=short)
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
        "oci_archive": archive,
        "oci_identity": f"{prefix}-OCI-IDENTITY.json",
        "manifest": f"{prefix}-MANIFEST.json",
        "provenance": f"{prefix}-PROVENANCE.intoto.json",
        "checksums": f"{prefix}-SHA256SUMS.txt",
    }


def require_regular_artifacts(directory, expected_names, allowed_extra=()):
    require(directory.is_dir() and not directory.is_symlink(), "artifact directory is missing or unsafe")
    entries = list(directory.iterdir())
    require(
        all(entry.is_file() and not entry.is_symlink() for entry in entries),
        "artifact set contains a nonregular entry",
    )
    actual = {entry.name for entry in entries}
    require(
        actual == set(expected_names) | set(allowed_extra),
        "artifact directory has an unexpected or missing file",
    )


def inspect_binary_tar(path):
    require(path.is_file() and not path.is_symlink(), "binary archive must be a regular file")
    try:
        with tarfile.open(path, mode="r:gz") as archive:
            members = archive.getmembers()
            require(
                [member.name for member in members] == list(EXPECTED_BINARIES),
                "binary archive inventory or order changed",
            )
            hashes = {}
            for member in members:
                require(member.isfile(), f"binary archive member is not a regular file: {member.name}")
                require(member.size > 0, f"binary archive member is empty: {member.name}")
                require(member.mode & 0o111, f"binary archive member is not executable: {member.name}")
                extracted = archive.extractfile(member)
                require(extracted is not None, f"cannot read binary archive member: {member.name}")
                hashes[member.name] = sha256_stream(extracted)
    except (tarfile.TarError, OSError) as error:
        raise RuntimeError(f"cannot inspect binary archive: {error}") from error
    return hashes


def validate_source_signature(path, policy):
    value = load_json(path, "source-signature evidence")
    require_exact_keys(
        value,
        {
            "schema", "commit", "tree", "repository", "signer", "format", "fingerprint",
            "local_git_verified", "github_verified", "github_verification_reason",
            "workflow_actor", "workflow_triggering_actor",
        },
        "source-signature evidence",
    )
    source = policy["source"]
    require(value["schema"] == 2, "source-signature schema is not supported")
    require(value["commit"] == source["commit"], "signature evidence is bound to another commit")
    require(value["tree"] == source["tree"], "signature evidence is bound to another source tree")
    require(value["repository"] == source["repository"], "signature evidence repository changed")
    require(value["signer"] == source["signer"], "signature evidence signer changed")
    require(value["format"] == "ssh", "candidate source must use an SSH signature")
    require(value["fingerprint"] == source["signing_fingerprint"], "signature fingerprint changed")
    require(value["local_git_verified"] is True, "local Git signature verification is absent")
    require(value["github_verified"] is True, "GitHub source verification is absent")
    require(value["github_verification_reason"] == "valid", "GitHub source verification is not valid")
    require(value["workflow_actor"] == EXPECTED_ACTOR, "workflow actor changed")
    require(value["workflow_triggering_actor"] == EXPECTED_ACTOR, "workflow triggering actor changed")
    return value


def validate_core_ci(path, policy):
    value = load_json(path, "Core CI evidence")
    require_exact_keys(
        value,
        {
            "schema", "workflow_path", "workflow_name", "base_workflow_blob_sha256",
            "source_workflow_blob_sha256", "event",
            "repository", "head_repository", "pull_request_number", "pull_request_head_sha",
            "pull_request_base_sha", "base_tree", "run_id", "run_attempt", "head_sha", "head_tree",
            "status", "conclusion", "workflow_actor", "workflow_triggering_actor",
            "base_branch", "base_branch_head_sha", "strict_base_fresh",
            "pull_request_state", "pull_request_draft", "pull_request_mergeable",
            "pull_request_mergeable_state", "exact_head_run_count",
            "required_checks", "thread_sanitizer_artifact",
        },
        "Core CI evidence",
    )
    require(value["schema"] == 2, "Core CI evidence schema is not supported")
    require(value["workflow_path"] == policy["core_ci"]["workflow_path"], "Core CI workflow path changed")
    require(value["workflow_name"] == policy["core_ci"]["workflow_name"], "Core CI workflow name changed")
    require(
        value["base_workflow_blob_sha256"] == policy["core_ci"]["base_workflow_blob_sha256"],
        "Core CI base workflow blob changed",
    )
    require(
        value["source_workflow_blob_sha256"] == policy["core_ci"]["source_workflow_blob_sha256"],
        "Core CI source workflow blob changed",
    )
    require(value["event"] == policy["core_ci"]["event"], "Core CI event changed")
    require(value["repository"] == policy["core_ci"]["repository"], "Core CI repository changed")
    require(
        value["head_repository"] == policy["core_ci"]["head_repository"],
        "Core CI head repository changed",
    )
    require(
        value["pull_request_number"] == policy["core_ci"]["pull_request_number"],
        "Core CI pull request changed",
    )
    require(
        value["pull_request_head_sha"] == policy["core_ci"]["head_sha"],
        "Core CI pull request head changed",
    )
    require(
        value["pull_request_base_sha"] == policy["core_ci"]["base_sha"],
        "Core CI pull request base changed",
    )
    require(value["base_tree"] == policy["core_ci"]["base_tree"], "Core CI base tree changed")
    require(type(value["run_id"]) is int and value["run_id"] > 0, "Core CI run ID is malformed")
    if policy["authorization"]["state"] == READY_AUTHORIZATION_STATE:
        require(
            value["run_id"] == policy["authorization"]["core_ci_run_id"],
            "Core CI evidence does not match the authorized exact run",
        )
        require(
            value["run_attempt"] == policy["authorization"]["core_ci_run_attempt"],
            "Core CI evidence does not match the authorized exact run attempt",
        )
    require(type(value["run_attempt"]) is int and value["run_attempt"] > 0, "Core CI run attempt is malformed")
    require(value["head_sha"] == policy["core_ci"]["head_sha"], "Core CI ran against another source")
    require(value["head_tree"] == policy["core_ci"]["head_tree"], "Core CI ran against another source tree")
    require(value["status"] == "completed", "Core CI did not complete")
    require(value["conclusion"] == "success", "Core CI did not pass")
    require(value["workflow_actor"] == EXPECTED_ACTOR, "Core CI actor changed")
    require(value["workflow_triggering_actor"] == EXPECTED_ACTOR, "Core CI triggering actor changed")
    require(value["base_branch"] == "main", "Core CI base branch changed")
    require(value["base_branch_head_sha"] == policy["core_ci"]["base_sha"], "strict Core base is stale")
    require(value["strict_base_fresh"] is True, "strict Core base freshness is not proven")
    require(value["pull_request_state"] == "open", "Core pull request is not open")
    require(value["pull_request_draft"] is False, "Core pull request is draft")
    require(value["pull_request_mergeable"] is True, "Core pull request is not mergeable")
    require(
        value["pull_request_mergeable_state"] == "clean",
        "Core pull request does not satisfy current protection",
    )
    require(
        type(value["exact_head_run_count"]) is int and value["exact_head_run_count"] == 1,
        "Core CI exact-head pull-request run is not unique",
    )
    checks = value["required_checks"]
    require(isinstance(checks, list) and len(checks) == len(EXPECTED_REQUIRED_CHECKS), "Core CI check count changed")
    check_names = []
    check_ids = set()
    for check in checks:
        require_exact_keys(check, {"id", "name", "app_id", "status", "conclusion"}, "Core CI required check")
        require(type(check["id"]) is int and check["id"] > 0, "Core CI check ID is malformed")
        require(check["id"] not in check_ids, "Core CI check ID is duplicated")
        check_ids.add(check["id"])
        require(
            type(check["app_id"]) is int and check["app_id"] == EXPECTED_REQUIRED_CHECKS_APP_ID,
            "Core CI required-check app changed",
        )
        require(check["status"] == "completed", "Core CI required check did not complete")
        require(check["conclusion"] == "success", "Core CI required check did not pass")
        check_names.append(check["name"])
    require(check_names == list(EXPECTED_REQUIRED_CHECKS), "Core CI protected check set changed")

    sanitizer = value["thread_sanitizer_artifact"]
    require_exact_keys(
        sanitizer,
        {
            "id", "name", "size_in_bytes", "expired", "api_digest", "zip_sha256",
            "reports_sha256", "report",
        },
        "ThreadSanitizer artifact evidence",
    )
    require(type(sanitizer["id"]) is int and sanitizer["id"] > 0, "sanitizer artifact ID is malformed")
    require(type(sanitizer["size_in_bytes"]) is int and sanitizer["size_in_bytes"] > 0, "sanitizer artifact is empty")
    require(sanitizer["expired"] is False, "sanitizer artifact expired")
    require(
        isinstance(sanitizer["zip_sha256"], str) and HEX_SHA256_RE.fullmatch(sanitizer["zip_sha256"]),
        "sanitizer artifact ZIP digest is malformed",
    )
    require(sanitizer["api_digest"] == f"sha256:{sanitizer['zip_sha256']}", "sanitizer API digest changed")
    require(
        isinstance(sanitizer["reports_sha256"], str) and HEX_SHA256_RE.fullmatch(sanitizer["reports_sha256"]),
        "sanitizer reports digest is malformed",
    )
    if policy["authorization"]["state"] == READY_AUTHORIZATION_STATE:
        authorized_sanitizer = policy["authorization"]["thread_sanitizer_artifact"]
        for field in ("id", "name", "zip_sha256", "reports_sha256"):
            require(sanitizer[field] == authorized_sanitizer[field], f"authorized sanitizer {field} changed")
    report = sanitizer["report"]
    require_exact_keys(
        report,
        {
            "target_sha", "sanitizer", "report_count", "report_bytes", "framing_error_count",
            "collector_error_count", "artifact_error", "capture_complete",
        },
        "ThreadSanitizer report evidence",
    )
    require(report["target_sha"] == policy["source"]["commit"], "sanitizer report target changed")
    require(report["sanitizer"] == "thread-sanitizer", "sanitizer report kind changed")
    for field in (
        "report_count", "report_bytes", "framing_error_count", "collector_error_count", "artifact_error",
    ):
        require(type(report[field]) is int and report[field] == 0, f"sanitizer report is not clean: {field}")
    require(
        type(report["capture_complete"]) is int and report["capture_complete"] == 1,
        "sanitizer report capture is incomplete",
    )
    return value


def validate_binary_sums(path, binary_hashes):
    require(path.is_file() and not path.is_symlink(), "binary checksum evidence must be a regular file")
    entries = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (blackcoin(?:-[a-z]+|d))", line)
        require(match is not None, "binary checksum evidence contains a malformed line")
        digest, name = match.groups()
        require(name not in entries, "binary checksum evidence contains a duplicate")
        entries[name] = digest
    require(entries == binary_hashes, "binary checksum evidence does not match the archive")
    return sha256(path)


def inspect_oci_archive(path):
    """Validate a single-image OCI layout archive and every descriptor digest."""
    require(path.is_file() and not path.is_symlink(), "OCI archive must be a regular file")

    def parse_json(payload, description):
        value = decode_json(payload, description)
        require(isinstance(value, dict), f"{description} must be an object")
        return value

    try:
        with tarfile.open(path, mode="r:") as archive:
            files = {}
            for member in archive.getmembers():
                name = member.name.rstrip("/") if member.isdir() else member.name
                candidate = PurePosixPath(name)
                require(
                    name and not candidate.is_absolute() and candidate.as_posix() == name and
                    all(part not in ("", ".", "..") for part in candidate.parts),
                    f"OCI archive contains an unsafe path: {member.name}",
                )
                if member.isdir():
                    require(name in {"blobs", "blobs/sha256"}, f"unexpected OCI directory: {name}")
                    continue
                require(member.isfile(), f"OCI archive entry is not a regular file: {name}")
                require(name not in files, f"OCI archive contains a duplicate entry: {name}")
                files[name] = member

            def read_member(name, description, limit):
                require(name in files, f"OCI archive is missing {description}")
                member = files[name]
                require(member.size <= limit, f"{description} exceeds the size limit")
                source = archive.extractfile(member)
                require(source is not None, f"cannot read {description}")
                payload = source.read(limit + 1)
                require(len(payload) == member.size, f"{description} size changed while reading")
                return payload

            def descriptor_blob(descriptor, description, media_types, read_limit=None):
                require(isinstance(descriptor, dict), f"{description} descriptor must be an object")
                require(descriptor.get("mediaType") in media_types, f"{description} media type changed")
                digest = descriptor.get("digest")
                size = descriptor.get("size")
                require(DIGEST_RE.fullmatch(digest or "") is not None, f"{description} digest is malformed")
                require(isinstance(size, int) and not isinstance(size, bool) and size >= 0,
                        f"{description} size is malformed")
                blob_name = f"blobs/sha256/{digest.removeprefix('sha256:')}"
                require(blob_name in files, f"OCI archive is missing the {description} blob")
                member = files[blob_name]
                require(member.size == size, f"{description} descriptor size does not match")
                source = archive.extractfile(member)
                require(source is not None, f"cannot read the {description} blob")
                require(f"sha256:{sha256_stream(source)}" == digest, f"{description} digest does not match")
                payload = None
                if read_limit is not None:
                    payload = read_member(blob_name, f"{description} blob", read_limit)
                return blob_name, digest, payload

            layout = parse_json(read_member("oci-layout", "OCI layout marker", 4096), "OCI layout marker")
            require(layout == {"imageLayoutVersion": "1.0.0"}, "OCI layout marker changed")
            index = parse_json(read_member("index.json", "OCI index", 1024 * 1024), "OCI index")
            require(index.get("schemaVersion") == 2, "OCI index schema changed")
            manifests = index.get("manifests")
            require(isinstance(manifests, list) and len(manifests) == 1,
                    "OCI archive must contain exactly one image manifest")
            index_descriptor = manifests[0]
            manifest_name, manifest_digest, manifest_payload = descriptor_blob(
                index_descriptor,
                "image manifest",
                {OCI_MANIFEST_MEDIA_TYPE},
                4 * 1024 * 1024,
            )
            annotations = index_descriptor.get("annotations")
            require(isinstance(annotations, dict), "OCI index reference annotation is missing")
            image_reference = annotations.get("org.opencontainers.image.ref.name")
            require(isinstance(image_reference, str) and image_reference,
                    "OCI index image reference is missing")

            manifest = parse_json(manifest_payload, "OCI image manifest")
            require(manifest.get("schemaVersion") == 2, "OCI image manifest schema changed")
            require(manifest.get("mediaType") == OCI_MANIFEST_MEDIA_TYPE,
                    "OCI image manifest media type changed")
            config_name, config_digest, config_payload = descriptor_blob(
                manifest.get("config"),
                "image config",
                {OCI_CONFIG_MEDIA_TYPE},
                16 * 1024 * 1024,
            )
            layers = manifest.get("layers")
            require(isinstance(layers, list) and layers, "OCI image manifest has no layers")
            layer_names = []
            for index_number, descriptor in enumerate(layers):
                layer_name, _, _ = descriptor_blob(
                    descriptor,
                    f"image layer {index_number}",
                    OCI_LAYER_MEDIA_TYPES,
                )
                layer_names.append(layer_name)
            require(len(layer_names) == len(set(layer_names)), "OCI image repeats a layer descriptor")

            expected_files = {
                "oci-layout", "index.json", manifest_name, config_name, *layer_names,
            }
            require(set(files) == expected_files, "OCI archive contains an unexpected or missing blob")
            config = parse_json(config_payload, "OCI image config")
            rootfs = config.get("rootfs")
            require(isinstance(rootfs, dict) and rootfs.get("type") == "layers",
                    "OCI image rootfs metadata changed")
            diff_ids = rootfs.get("diff_ids")
            require(isinstance(diff_ids, list) and len(diff_ids) == len(layers),
                    "OCI config and manifest layer counts differ")
            require(all(DIGEST_RE.fullmatch(value or "") is not None for value in diff_ids),
                    "OCI rootfs contains a malformed diff ID")
            return {
                "manifest_digest": manifest_digest,
                "config_digest": config_digest,
                "image_reference": image_reference,
                "config": config,
            }
    except (OSError, tarfile.TarError) as error:
        raise RuntimeError(f"cannot inspect OCI archive: {error}") from error


def expected_candidate_labels(policy, binary_hashes, artifact_sha256, binary_sums_sha256):
    source = policy["source"]["commit"]
    source_tree = policy["source"]["tree"]
    labels = {
        "org.blackcoin.release.channel": "v30.1.5-candidate",
        "org.blackcoin.release.qualification": "canary-only-not-release",
        "org.blackcoin.release.tag": "none",
        "org.blackcoin.candidate.kind": "v30.1.5-candidate",
        "org.blackcoin.candidate.published": "false",
        "org.blackcoin.candidate.registry-pushed": "false",
        "org.blackcoin.deployment.scope": "canary-only",
        "org.blackcoin.source.commit": source,
        "org.blackcoin.source.tree": source_tree,
        "org.blackcoin.source.verification": "blackcoin-dev-ssh-plus-github-verified",
        "org.opencontainers.image.revision": source,
        "org.opencontainers.image.version": f"30.1.5-candidate-{source[:12]}",
        "org.blackcoin.rollback.base.image": policy["base_image"]["reference"],
        "org.blackcoin.rollback.base.image.id": policy["base_image"]["config_digest"],
        "org.blackcoin.artifact.sha256": artifact_sha256,
        "org.blackcoin.sha256sums.sha256": binary_sums_sha256,
        "org.blackcoin.package.verification": "two-build-reproducible-plus-binary-sha256",
    }
    for name, digest in sorted(binary_hashes.items()):
        labels[f"org.blackcoin.binary.{name}.sha256"] = digest
    return labels


def validate_oci_identity(
    path,
    archive_path,
    policy,
    binary_hashes,
    artifact_sha256,
    binary_sums_sha256,
):
    value = load_json(path, "OCI identity evidence")
    require_exact_keys(
        value,
        {
            "schema", "classification", "source_commit", "source_tree", "image_reference", "archive_name",
            "archive_sha256", "image_manifest_digest", "image_config_digest", "base_reference",
            "base_manifest_digest", "base_config_digest", "os", "architecture", "user",
            "entrypoint", "cmd", "working_dir", "healthcheck", "rootfs_base_prefix_exact",
            "candidate_added_rootfs_layers", "oci_roundtrip_verified", "published",
            "registry_pushed", "labels", "binaries",
        },
        "OCI identity evidence",
    )
    source = policy["source"]["commit"]
    expected_ref = f"{policy['image']['repository']}:{policy['image']['tag_template'].format(source12=source[:12])}"
    require(value["schema"] == 2, "OCI identity schema is not supported")
    require(value["classification"] == EXPECTED_CLASSIFICATION, "OCI classification changed")
    require(value["source_commit"] == source, "OCI identity is bound to another source")
    require(value["source_tree"] == policy["source"]["tree"], "OCI identity is bound to another source tree")
    require(value["image_reference"] == expected_ref, "OCI image reference changed")
    require(value["archive_name"] == archive_path.name, "OCI archive name changed")
    require(HEX_SHA256_RE.fullmatch(value["archive_sha256"] or "") is not None, "OCI archive hash is malformed")
    require(value["archive_sha256"] == sha256(archive_path), "OCI archive hash does not match")
    require(DIGEST_RE.fullmatch(value["image_manifest_digest"] or "") is not None, "OCI manifest digest is malformed")
    require(DIGEST_RE.fullmatch(value["image_config_digest"] or "") is not None, "OCI config digest is malformed")
    archive = inspect_oci_archive(archive_path)
    require(archive["image_reference"] == expected_ref, "OCI archive image reference changed")
    require(archive["manifest_digest"] == value["image_manifest_digest"],
            "OCI manifest digest does not match the archive")
    require(archive["config_digest"] == value["image_config_digest"],
            "OCI config digest does not match the archive")
    require(value["base_reference"] == policy["base_image"]["reference"], "OCI base reference changed")
    require(value["base_manifest_digest"] == policy["base_image"]["manifest_digest"], "OCI base manifest changed")
    require(value["base_config_digest"] == policy["base_image"]["config_digest"], "OCI base config changed")
    image = policy["image"]
    for key in ("os", "architecture", "user", "entrypoint", "cmd", "working_dir", "healthcheck"):
        require(value[key] == image[key], f"OCI runtime field changed: {key}")
    config = archive["config"]
    require(config.get("os") == image["os"] and config.get("architecture") == image["architecture"],
            "OCI archive platform changed")
    runtime = config.get("config")
    require(isinstance(runtime, dict), "OCI archive runtime config is missing")
    runtime_fields = {
        "User": "user",
        "Entrypoint": "entrypoint",
        "Cmd": "cmd",
        "WorkingDir": "working_dir",
        "Healthcheck": "healthcheck",
    }
    for config_key, policy_key in runtime_fields.items():
        require(runtime.get(config_key) == image[policy_key],
                f"OCI archive runtime field changed: {config_key}")
    require(value["rootfs_base_prefix_exact"] is True, "OCI rootfs does not preserve the exact base prefix")
    require(value["candidate_added_rootfs_layers"] == 1, "OCI candidate must add exactly one layer")
    require(value["oci_roundtrip_verified"] is True, "OCI archive round-trip verification is absent")
    require(value["published"] is False, "candidate OCI must not be classified as published")
    require(value["registry_pushed"] is False, "candidate OCI must not be classified as registry-pushed")
    labels = expected_candidate_labels(policy, binary_hashes, artifact_sha256, binary_sums_sha256)
    require(value["labels"] == labels, "candidate OCI labels changed")
    archive_labels = runtime.get("Labels")
    require(isinstance(archive_labels, dict), "OCI archive labels are missing")
    require(all(archive_labels.get(key) == expected for key, expected in labels.items()),
            "OCI archive candidate labels changed")
    require(value["binaries"] == binary_hashes, "candidate OCI binary hashes changed")
    return value


def parse_exact_key_value_evidence(path, description, expected_keys, header=None):
    require(path.is_file() and not path.is_symlink(), f"{description} must be a regular file")
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise RuntimeError(f"cannot read {description}: {error}") from error
    require(text.endswith("\n") and "\r" not in text, f"{description} must use canonical LF lines")
    lines = text[:-1].split("\n")
    require(all(line for line in lines), f"{description} contains an empty line")
    if header is not None:
        require(lines and lines[0] == header, f"{description} header changed")
        lines = lines[1:]

    values = {}
    observed_keys = []
    for line in lines:
        match = re.fullmatch(r"([a-z][a-z0-9_]*)=(.+)", line)
        require(match is not None, f"{description} contains a malformed line")
        key, value = match.groups()
        require(key not in values, f"{description} contains a duplicate key: {key}")
        observed_keys.append(key)
        values[key] = value
    require(tuple(observed_keys) == tuple(expected_keys), f"{description} key inventory or order changed")
    return values


def validate_text_evidence(directory, names, policy):
    source = policy["source"]["commit"]
    source_tree = policy["source"]["tree"]
    source_marker = (directory / names["source_commit"]).read_text(encoding="utf-8")
    require(source_marker == f"{source}\n", "source marker does not contain the exact approved commit")
    source_tree_marker = (directory / names["source_tree"]).read_text(encoding="utf-8")
    require(source_tree_marker == f"{source_tree}\n", "source-tree marker does not contain the exact approved tree")

    notice = parse_exact_key_value_evidence(
        directory / names["notice"],
        "candidate notice",
        (
            "source_commit", "core_version_self_report", "signed_source",
            "artifact_platform_signed", "tag", "published", "registry_pushed",
        ),
        header="V30.1.5 CANDIDATE - CANARY ONLY - NOT A RELEASE",
    )
    expected_notice = {
        "source_commit": source,
        "core_version_self_report": "30.1.5",
        "signed_source": "true",
        "artifact_platform_signed": "false",
        "tag": "none",
        "published": "false",
        "registry_pushed": "false",
    }
    require(notice == expected_notice, "candidate notice contains an unexpected value")

    reproducibility = parse_exact_key_value_evidence(
        directory / names["reproducibility"],
        "reproducibility evidence",
        (
            "source_commit", "method", "primary_artifact_sha256",
            "verifier_artifact_sha256", "result",
        ),
    )
    require(reproducibility["source_commit"] == source, "reproducibility source changed")
    require(
        reproducibility["method"] == "two-isolated-builds-byte-identical",
        "reproducibility method changed",
    )
    require(reproducibility["result"] == "passed", "reproducibility result did not pass")
    primary_hash = reproducibility["primary_artifact_sha256"]
    verifier_hash = reproducibility["verifier_artifact_sha256"]
    require(HEX_SHA256_RE.fullmatch(primary_hash) is not None, "primary reproducibility hash is malformed")
    require(HEX_SHA256_RE.fullmatch(verifier_hash) is not None, "verifier reproducibility hash is malformed")
    require(primary_hash == verifier_hash, "independent binary archives differ")
    require(primary_hash == sha256(directory / names["binary_tar"]), "reproducibility hash is stale")
    return {
        "method": "two-isolated-builds-byte-identical",
        "result": "passed",
        "artifact_sha256": primary_hash,
    }


def validate_toolchain(path, policy, workflow_run_id, workflow_run_attempt):
    values = parse_exact_key_value_evidence(
        path,
        "toolchain evidence",
        (
            "source_commit", "source_tree", "workflow_run_id", "workflow_run_attempt",
            "runner_image", "host", "build_matrix", "depends_cache_reused",
            "compiler", "binutils", "make", "packages",
            "depends_tracked_source_tree_sha256",
        ),
    )
    expected = {
        "source_commit": policy["source"]["commit"],
        "source_tree": policy["source"]["tree"],
        "workflow_run_id": str(workflow_run_id),
        "workflow_run_attempt": str(workflow_run_attempt),
        "runner_image": "ubuntu-22.04",
        "host": "x86_64-pc-linux-gnu",
        "build_matrix": "primary,verifier",
        "depends_cache_reused": "false",
    }
    require(
        all(values[key] == value for key, value in expected.items()),
        "toolchain evidence contains an unexpected fixed value",
    )
    require(
        NUMERIC_RE.fullmatch(values["workflow_run_id"]) is not None and
        NUMERIC_RE.fullmatch(values["workflow_run_attempt"]) is not None,
        "toolchain workflow run identity is malformed",
    )
    require(
        HEX_SHA256_RE.fullmatch(values["depends_tracked_source_tree_sha256"]) is not None,
        "tracked depends source-tree digest is malformed",
    )
    return {"evidence": path.name, "sha256": sha256(path)}


def artifact_inventory(directory, artifact_files):
    return [
        {"name": name, "sha256": sha256(directory / name), "size": (directory / name).stat().st_size}
        for name in sorted(artifact_files)
    ]


def build_documents(
    policy,
    directory,
    adapter_sha,
    workflow_run_id,
    workflow_run_attempt,
    allowed_extra=(),
):
    require(FULL_SHA_RE.fullmatch(adapter_sha or "") is not None, "adapter SHA must be a full lowercase commit")
    require(NUMERIC_RE.fullmatch(str(workflow_run_id)) is not None, "workflow run ID must be a positive integer")
    require(
        NUMERIC_RE.fullmatch(str(workflow_run_attempt)) is not None,
        "workflow run attempt must be a positive integer",
    )
    names = artifact_names(policy)
    base_artifacts = (
        names["binary_tar"],
        names["binary_sums"],
        names["source_commit"],
        names["source_tree"],
        names["reproducibility"],
        names["notice"],
        names["source_signature"],
        names["core_ci"],
        names["toolchain"],
        names["oci_archive"],
        names["oci_identity"],
    )
    require_regular_artifacts(directory, base_artifacts, allowed_extra)
    binary_hashes = inspect_binary_tar(directory / names["binary_tar"])
    binary_sums_sha256 = validate_binary_sums(directory / names["binary_sums"], binary_hashes)
    reproducibility = validate_text_evidence(directory, names, policy)
    signature = validate_source_signature(directory / names["source_signature"], policy)
    core_ci = validate_core_ci(directory / names["core_ci"], policy)
    toolchain = validate_toolchain(
        directory / names["toolchain"],
        policy,
        workflow_run_id,
        workflow_run_attempt,
    )
    oci = validate_oci_identity(
        directory / names["oci_identity"],
        directory / names["oci_archive"],
        policy,
        binary_hashes,
        sha256(directory / names["binary_tar"]),
        binary_sums_sha256,
    )
    source = policy["source"]["commit"]
    manifest = {
        "schema": 2,
        "classification": EXPECTED_CLASSIFICATION,
        "package": {
            "name": names["prefix"],
            "version": "30.1.5",
            "platform": "linux/amd64",
        },
        "source": {
            "repository": policy["source"]["repository"],
            "commit": source,
            "tree": policy["source"]["tree"],
            "immutable_release_ancestor": policy["source"]["immutable_release_ancestor"],
            "signature": signature,
        },
        "authorization": policy["authorization"],
        "core_ci": core_ci,
        "build": {
            "tooling_commit": adapter_sha,
            "workflow_definition_commit": adapter_sha,
            "workflow_path": ".github/workflows/v30.1.5-candidate-linux.yml",
            "workflow_run_id": int(workflow_run_id),
            "workflow_run_attempt": int(workflow_run_attempt),
            "toolchain": toolchain,
        },
        "base_image": policy["base_image"],
        "image": oci,
        "reproducibility": reproducibility,
        "release": {
            "tag": None,
            "published": False,
            "registry_pushed": False,
            "canary_only": True,
        },
        "artifacts": artifact_inventory(directory, base_artifacts),
    }
    repository_uri = f"git+https://github.com/{policy['source']['repository']}.git"
    workflow_uri = (
        f"https://github.com/{policy['source']['repository']}/.github/workflows/"
        f"v30.1.5-candidate-linux.yml@{adapter_sha}"
    )
    run_uri = f"https://github.com/{policy['source']['repository']}/actions/runs/{workflow_run_id}"
    provenance_subjects = [
        {"name": artifact["name"], "digest": {"sha256": artifact["sha256"]}}
        for artifact in manifest["artifacts"]
    ]
    provenance_subjects.append(
        {"name": names["manifest"], "digest": {"sha256": None}}
    )
    provenance = {
        "_type": "https://in-toto.io/Statement/v1",
        "subject": provenance_subjects,
        "predicateType": "https://slsa.dev/provenance/v1",
        "predicate": {
            "buildDefinition": {
                "buildType": workflow_uri,
                "externalParameters": {
                    "classification": EXPECTED_CLASSIFICATION,
                    "source": {
                        "uri": repository_uri,
                        "digest": {"gitCommit": source, "gitTree": policy["source"]["tree"]},
                    },
                    "baseImage": {
                        "uri": policy["base_image"]["reference"],
                        "digest": {"sha256": policy["base_image"]["manifest_digest"].removeprefix("sha256:")},
                    },
                    "tag": None,
                    "publish": False,
                },
                "internalParameters": {
                    "toolingCommit": adapter_sha,
                    "workflowDefinitionCommit": adapter_sha,
                    "coreCiRunId": core_ci["run_id"],
                    "workflowRunId": int(workflow_run_id),
                    "workflowRunAttempt": int(workflow_run_attempt),
                    "reproducibilityGate": "two-isolated-builds-byte-identical",
                },
                "resolvedDependencies": [
                    {
                        "uri": repository_uri,
                        "digest": {"gitCommit": source, "gitTree": policy["source"]["tree"]},
                    },
                    {
                        "uri": policy["base_image"]["repository"],
                        "digest": {"sha256": policy["base_image"]["manifest_digest"].removeprefix("sha256:")},
                    },
                ],
            },
            "runDetails": {
                "builder": {"id": run_uri},
                "metadata": {"invocationId": f"{run_uri}/attempts/{workflow_run_attempt}"},
            },
        },
    }
    return manifest, provenance, names


def write_json(path, value):
    require(not path.exists() and not path.is_symlink(), f"refusing to overwrite metadata output: {path.name}")
    path.write_bytes(canonical_json_bytes(value))


def generate(
    policy_path,
    directory,
    adapter_sha,
    workflow_run_id,
    workflow_run_attempt,
    manifest_path,
    provenance_path,
):
    policy = validate_policy(policy_path)
    names = artifact_names(policy)
    require(
        manifest_path.parent.resolve() == directory.resolve(),
        "manifest output must be inside the artifact directory",
    )
    require(
        provenance_path.parent.resolve() == directory.resolve(),
        "provenance output must be inside the artifact directory",
    )
    require(manifest_path.name == names["manifest"], "manifest output name is not canonical")
    require(provenance_path.name == names["provenance"], "provenance output name is not canonical")
    manifest, provenance, _ = build_documents(
        policy,
        directory,
        adapter_sha,
        workflow_run_id,
        workflow_run_attempt,
    )
    write_json(manifest_path, manifest)
    provenance["subject"][-1]["digest"]["sha256"] = sha256(manifest_path)
    write_json(provenance_path, provenance)
    return manifest, provenance


def parse_checksums(path):
    require(path.is_file() and not path.is_symlink(), "checksum manifest must be a regular file")
    entries = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._-]+)", line)
        require(match is not None, "checksum manifest contains a malformed line")
        digest, name = match.groups()
        require(name not in entries, "checksum manifest contains a duplicate filename")
        entries[name] = digest
    require(entries, "checksum manifest is empty")
    require(list(entries) == sorted(entries), "checksum manifest is not sorted")
    return entries


def verify(policy_path, directory):
    policy = validate_policy(policy_path)
    names = artifact_names(policy)
    final_files = (
        names["binary_tar"], names["binary_sums"], names["source_commit"], names["source_tree"],
        names["reproducibility"], names["notice"],
        names["source_signature"], names["core_ci"], names["toolchain"],
        names["oci_archive"], names["oci_identity"],
        names["manifest"], names["provenance"], names["checksums"],
    )
    require_regular_artifacts(directory, final_files)
    checksums = parse_checksums(directory / names["checksums"])
    expected_covered = set(final_files) - {names["checksums"]}
    require(set(checksums) == expected_covered, "checksum manifest does not cover the exact bundle")
    for name, digest in checksums.items():
        require(sha256(directory / name) == digest, f"bundle checksum mismatch: {name}")

    manifest = load_json(
        directory / names["manifest"],
        "candidate manifest",
        require_canonical=True,
    )
    require_exact_keys(
        manifest,
        {
            "schema", "classification", "package", "source", "authorization", "core_ci", "build",
            "base_image", "image", "reproducibility", "release", "artifacts",
        },
        "candidate manifest",
    )
    adapter_sha = manifest.get("build", {}).get("tooling_commit")
    require(
        manifest.get("build", {}).get("workflow_definition_commit") == adapter_sha,
        "workflow and tooling commits differ",
    )
    workflow_run_id = manifest.get("build", {}).get("workflow_run_id")
    workflow_run_attempt = manifest.get("build", {}).get("workflow_run_attempt")

    staging_files = tuple(
        name
        for name in final_files
        if name not in (names["manifest"], names["provenance"], names["checksums"])
    )
    actual_files = {entry.name: entry for entry in directory.iterdir()}
    temporary_manifest = actual_files.pop(names["manifest"])
    temporary_provenance = actual_files.pop(names["provenance"])
    temporary_checksums = actual_files.pop(names["checksums"])
    require(set(actual_files) == set(staging_files), "candidate bundle base artifact set changed")
    # Rebuild the expected documents without mutating the sealed directory.
    expected_manifest, expected_provenance, _ = build_documents(
        policy,
        directory,
        adapter_sha,
        workflow_run_id,
        workflow_run_attempt,
        allowed_extra=(names["manifest"], names["provenance"], names["checksums"]),
    )
    require(manifest == expected_manifest, "candidate manifest is not canonical for the sealed artifacts")
    expected_provenance["subject"][-1]["digest"]["sha256"] = sha256(temporary_manifest)
    provenance = load_json(
        temporary_provenance,
        "candidate provenance",
        require_canonical=True,
    )
    require(provenance == expected_provenance, "candidate provenance is not canonical for the sealed artifacts")
    require(temporary_checksums.name == names["checksums"], "checksum filename changed")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    generate_parser = subparsers.add_parser("generate")
    generate_parser.add_argument("--policy", required=True, type=Path)
    generate_parser.add_argument("--artifacts", required=True, type=Path)
    generate_parser.add_argument("--adapter-sha", required=True)
    generate_parser.add_argument("--workflow-run-id", required=True)
    generate_parser.add_argument("--workflow-run-attempt", required=True)
    generate_parser.add_argument("--manifest", required=True, type=Path)
    generate_parser.add_argument("--provenance", required=True, type=Path)

    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--policy", required=True, type=Path)
    verify_parser.add_argument("--bundle", required=True, type=Path)
    policy_parser = subparsers.add_parser("validate-policy")
    policy_parser.add_argument("--policy", required=True, type=Path)
    args = parser.parse_args()

    if args.command == "generate":
        manifest, _ = generate(
            args.policy, args.artifacts, args.adapter_sha, args.workflow_run_id,
            args.workflow_run_attempt, args.manifest, args.provenance,
        )
        print(f"Wrote v30.1.5-candidate metadata for {len(manifest['artifacts'])} artifact(s)")
    elif args.command == "verify":
        manifest = verify(args.policy, args.bundle)
        print(f"Verified exact v30.1.5-candidate bundle {manifest['package']['name']}")
    else:
        policy = validate_policy(args.policy)
        print(f"Verified v30.1.5-candidate policy for {policy['source']['commit']}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as error:
        print(f"v30.1.5-candidate metadata failed: {error}", file=sys.stderr)
        sys.exit(1)
