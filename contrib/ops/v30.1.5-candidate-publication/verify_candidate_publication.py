#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Fail-closed verification for a v30.1.5 artifact and registry handoff."""

from __future__ import annotations

import argparse
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
CANDIDATE_POLICY = CANDIDATE_ROOT / "policy.json"
CANDIDATE_VERIFIER = CANDIDATE_ROOT / "verify_candidate_bundle.sh"
CANDIDATE_METADATA = REPO_ROOT / "ci" / "release" / "generate_v30_1_5_candidate_metadata.py"
EXPECTED_REPOSITORY = "Blackcoin-Dev/Blackcoin"
EXPECTED_REGISTRY_REPOSITORY = "qqblackcoin/blackcoin-v4-gui"
EXPECTED_FINGERPRINT = "SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70"
EXPECTED_CLASSIFICATION = "V30_1_5_CANDIDATE_CANARY_ONLY"
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
MAX_ZIP_UNCOMPRESSED = 12 * 1024 * 1024 * 1024
MAX_JSON_BYTES = 32 * 1024 * 1024
MAX_HEADER_BYTES = 1024 * 1024
MAX_TEXT_RECEIPT_BYTES = 1024 * 1024
MAX_OCI_ENTRIES = 1024


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


def exact_keys(value, expected, description):
    require(isinstance(value, dict), f"{description} must be an object")
    require(set(value) == set(expected), f"{description} has unexpected or missing fields")


def absolute_path(value, description):
    require(isinstance(value, str) and value.startswith("/"), f"{description} must be absolute")
    path = Path(value)
    require(".." not in path.parts, f"{description} contains a parent traversal")
    return path


def expected_artifact_name(source, attempt):
    return f"v30.1.5-candidate-linux-x86_64-{source}-attempt-{attempt}"


def expected_registry_tag(source, run_id, attempt):
    return f"30.1.5-candidate-{source[:12]}-gha{run_id}-a{attempt}-pub1"


def publication_intent_value(value):
    """Return the path-independent identity that an operator authorizes."""
    identity = value["identity"]
    artifact = value["artifact"]
    return {
        "schema": value["schema"],
        "identity": identity,
        "artifact": {
            "id": artifact["id"],
            "name": artifact["name"],
            "packaging_run_id": artifact["packaging_run_id"],
            "packaging_run_attempt": artifact["packaging_run_attempt"],
            "api_metadata_sha256": artifact["api_metadata_sha256"],
            "github_zip_sha256": artifact["github_zip_sha256"],
            "bundle_sha256sums_sha256": artifact["bundle_sha256sums_sha256"],
        },
        "registry": value["registry"],
    }


def publication_intent_sha256(value):
    return sha256_bytes(canonical_json_bytes(publication_intent_value(value)))


def expected_live_confirmation(value, nonce):
    return (
        f"PUBLISH_V30_1_5_CANDIDATE:{value['identity']['source_commit']}:"
        f"{publication_intent_sha256(value)}:{nonce}"
    )


def validate_request_value(value):
    exact_keys(value, {"schema", "identity", "artifact", "registry", "execution"}, "request")
    require(value["schema"] == 2, "request schema is not supported")
    identity = value["identity"]
    exact_keys(
        identity,
        {
            "repository",
            "source_commit",
            "source_tree",
            "core_ci_run_id",
            "packaging_tooling_commit",
            "packaging_tooling_tree",
        },
        "request identity",
    )
    require(identity["repository"] == EXPECTED_REPOSITORY, "source repository changed")
    for key in ("source_commit", "source_tree", "packaging_tooling_commit", "packaging_tooling_tree"):
        require(FULL_SHA_RE.fullmatch(identity[key] or "") is not None, f"{key} is malformed")
    require(
        isinstance(identity["core_ci_run_id"], int)
        and not isinstance(identity["core_ci_run_id"], bool)
        and identity["core_ci_run_id"] > 0,
        "Core CI run ID is malformed",
    )

    artifact = value["artifact"]
    exact_keys(
        artifact,
        {
            "id",
            "name",
            "packaging_run_id",
            "packaging_run_attempt",
            "api_metadata_path",
            "api_metadata_sha256",
            "github_zip_path",
            "github_zip_sha256",
            "bundle_sha256sums_sha256",
        },
        "artifact request",
    )
    for key in ("id", "packaging_run_id", "packaging_run_attempt"):
        require(
            isinstance(artifact[key], int) and not isinstance(artifact[key], bool) and artifact[key] > 0,
            f"artifact {key} is malformed",
        )
    expected_name = expected_artifact_name(
        identity["source_commit"], artifact["packaging_run_attempt"]
    )
    require(artifact["name"] == expected_name, "artifact name is not exact-H/attempt scoped")
    absolute_path(artifact["api_metadata_path"], "artifact API metadata path")
    absolute_path(artifact["github_zip_path"], "GitHub artifact ZIP path")
    for key in ("api_metadata_sha256", "github_zip_sha256", "bundle_sha256sums_sha256"):
        require(HEX64_RE.fullmatch(artifact[key] or "") is not None, f"artifact {key} is malformed")

    registry = value["registry"]
    exact_keys(registry, {"repository", "tag"}, "registry request")
    require(
        registry["repository"] == EXPECTED_REGISTRY_REPOSITORY,
        "registry repository is not the reviewed Blackcoin repository",
    )
    expected_tag = expected_registry_tag(
        identity["source_commit"], artifact["packaging_run_id"], artifact["packaging_run_attempt"]
    )
    require(registry["tag"] == expected_tag, "registry tag is not exact-H/run/attempt scoped")
    require(registry["tag"] != "latest" and ":" not in registry["tag"] and "@" not in registry["tag"],
            "registry tag is mutable-only or malformed")

    execution = value["execution"]
    exact_keys(
        execution,
        {"execute", "dispatch_enabled", "exclusive_tag_writer", "nonce", "confirmation"},
        "execution request",
    )
    for key in ("execute", "dispatch_enabled", "exclusive_tag_writer"):
        require(isinstance(execution[key], bool), f"execution {key} must be boolean")
    if execution["execute"]:
        require(execution["dispatch_enabled"] is True, "live execution lacks dispatch clearance")
        require(execution["exclusive_tag_writer"] is True, "exclusive tag-writer authority is absent")
        nonce = execution["nonce"]
        require(NONCE_RE.fullmatch(nonce or "") is not None, "live execution nonce is not 32-byte hex")
        expected_confirmation = expected_live_confirmation(value, nonce)
        require(execution["confirmation"] == expected_confirmation, "live confirmation is not exact")
    else:
        require(execution == {
            "execute": False,
            "dispatch_enabled": False,
            "exclusive_tag_writer": False,
            "nonce": None,
            "confirmation": None,
        }, "disabled execution request is partially armed")
    return value


def load_request(path):
    return load_request_with_sha(path)[0]


def load_request_with_sha(path):
    payload = read_regular_bytes(path, "publication request")
    return validate_request_value(decode_json(payload, "publication request")), sha256_bytes(payload)


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
    identity = request["identity"]
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
    api_base = f"https://api.github.com/repos/{identity['repository']}/actions/artifacts/{artifact['id']}"
    require(metadata.get("url") == api_base, "GitHub artifact API URL changed")
    require(metadata.get("archive_download_url") == f"{api_base}/zip", "GitHub artifact ZIP URL changed")
    workflow_run = metadata.get("workflow_run")
    require(isinstance(workflow_run, dict), "GitHub artifact workflow-run receipt is missing")
    require(isinstance(workflow_run.get("id"), int) and not isinstance(workflow_run["id"], bool),
            "GitHub artifact workflow-run ID is malformed")
    require(workflow_run.get("id") == artifact["packaging_run_id"], "artifact packaging run changed")
    require(
        workflow_run.get("head_sha") == identity["packaging_tooling_commit"],
        "artifact workflow head is not the packaging tooling commit",
    )
    return metadata


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
            }
    except (OSError, tarfile.TarError) as error:
        raise VerificationError(f"cannot inspect OCI archive: {error}") from error


def verify_git_identity(commit, tree, description):
    try:
        observed_tree = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "rev-parse", f"{commit}^{{tree}}"],
            check=True, text=True, capture_output=True,
        ).stdout.strip()
        signature = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "verify-commit", commit],
            check=True, text=True, capture_output=True,
        )
    except subprocess.CalledProcessError as error:
        raise VerificationError(f"{description} commit or signature is unavailable") from error
    require(observed_tree == tree, f"{description} tree changed")
    signature_text = signature.stdout + signature.stderr
    require("Good \"git\" signature" in signature_text and EXPECTED_FINGERPRINT in signature_text,
            f"{description} signature fingerprint changed")


def verify_packaging_snapshot(commit, tree):
    verify_git_identity(commit, tree, "packaging tooling")
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
        try:
            committed = subprocess.run(
                ["git", "-C", str(REPO_ROOT), "show", f"{commit}:{relative}"],
                check=True, capture_output=True,
            ).stdout
        except subprocess.CalledProcessError as error:
            raise VerificationError(f"packaging tooling path is absent from its commit: {relative}") from error
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


def run_canonical_bundle_verifier(bundle):
    require(CANDIDATE_POLICY.is_file() and not CANDIDATE_POLICY.is_symlink(), "candidate policy is unsafe")
    require(CANDIDATE_VERIFIER.is_file() and not CANDIDATE_VERIFIER.is_symlink(), "candidate verifier is unsafe")
    require(CANDIDATE_METADATA.is_file() and not CANDIDATE_METADATA.is_symlink(), "candidate metadata verifier is unsafe")
    environment = os.environ.copy()
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    try:
        subprocess.run(
            ["python3", str(CANDIDATE_METADATA), "verify", "--policy", str(CANDIDATE_POLICY),
             "--bundle", str(bundle)],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment,
        )
    except subprocess.CalledProcessError as error:
        message = error.stderr.decode("utf-8", errors="replace").strip()
        raise VerificationError(f"canonical candidate bundle verifier failed: {message}") from error


def validate_manifest_and_oci(bundle, names, request, checksum_entries):
    identity = request["identity"]
    artifact = request["artifact"]
    source = identity["source_commit"]
    tree = identity["source_tree"]
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
    require(source_value.get("repository") == EXPECTED_REPOSITORY, "manifest repository changed")
    require(source_value.get("commit") == source and source_value.get("tree") == tree,
            "manifest H/T identity changed")
    signature = source_value.get("signature")
    require(isinstance(signature, dict) and signature.get("schema") == 2,
            "manifest source signature is absent")
    require(signature.get("commit") == source and signature.get("tree") == tree,
            "manifest source signature H/T changed")
    require(signature.get("fingerprint") == EXPECTED_FINGERPRINT
            and signature.get("local_git_verified") is True
            and signature.get("github_verified") is True
            and signature.get("github_verification_reason") == "valid",
            "manifest source signature is not verified")
    core_ci = manifest["core_ci"]
    require(core_ci.get("schema") == 2 and core_ci.get("run_id") == identity["core_ci_run_id"],
            "manifest Core CI run R changed")
    require(core_ci.get("head_sha") == source and core_ci.get("head_tree") == tree,
            "manifest Core CI H/T changed")
    require(core_ci.get("status") == "completed" and core_ci.get("conclusion") == "success",
            "manifest Core CI is not successful")
    build = manifest["build"]
    require(build.get("tooling_commit") == identity["packaging_tooling_commit"]
            and build.get("workflow_definition_commit") == identity["packaging_tooling_commit"],
            "manifest packaging tooling commit changed")
    require(build.get("workflow_run_id") == artifact["packaging_run_id"]
            and build.get("workflow_run_attempt") == artifact["packaging_run_attempt"],
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
                and authorization["core_ci_run_id"] == identity["core_ci_run_id"],
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
    }


def prepare_artifact(
    request_path,
    output,
    canonical_bundle_check=None,
    source_identity_check=None,
    packaging_snapshot_check=None,
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
        request_sha, _ = copy_regular_file(
            request_path, copied_request, max_size=MAX_JSON_BYTES
        )
        request, parsed_request_sha = load_request_with_sha(copied_request)
        require(request_sha == parsed_request_sha, "copied request digest changed before validation")
        artifact = request["artifact"]
        copied_api = temporary / "artifact-api.json"
        api_sha, _ = copy_regular_file(
            Path(artifact["api_metadata_path"]), copied_api,
            artifact["api_metadata_sha256"], MAX_JSON_BYTES,
        )
        copied_zip = temporary / "artifact.zip"
        zip_sha, zip_size = copy_regular_file(
            Path(artifact["github_zip_path"]), copied_zip, artifact["github_zip_sha256"]
        )
        validate_github_metadata(copied_api, request, zip_sha, zip_size)
        bundle = temporary / "bundle"
        zip_names = safe_extract_zip(copied_zip, bundle)
        names = bundle_names(request["identity"]["source_commit"])
        require(set(zip_names) == set(names.values()) - {names["prefix"]},
                "GitHub artifact ZIP does not contain the exact candidate bundle")
        checksum_entries = parse_bundle_checksums(
            bundle, names, artifact["bundle_sha256sums_sha256"]
        )
        if source_identity_check is None:
            verify_git_identity(
                request["identity"]["source_commit"], request["identity"]["source_tree"], "source"
            )
        else:
            source_identity_check(request["identity"]["source_commit"], request["identity"]["source_tree"])
        if packaging_snapshot_check is None:
            packaging_seal_sha = verify_packaging_snapshot(
                request["identity"]["packaging_tooling_commit"],
                request["identity"]["packaging_tooling_tree"],
            )
        else:
            packaging_seal_sha = packaging_snapshot_check(
                request["identity"]["packaging_tooling_commit"],
                request["identity"]["packaging_tooling_tree"],
            )
        if canonical_bundle_check is None:
            run_canonical_bundle_verifier(bundle)
        else:
            canonical_bundle_check(bundle)
        detail = validate_manifest_and_oci(bundle, names, request, checksum_entries)
        verified_dir = temporary / "verified"
        verified_dir.mkdir(mode=0o700)
        source_manifest = verified_dir / "source-oci-manifest.json"
        source_manifest.write_bytes(detail["oci"]["manifest_bytes"])
        source_manifest.chmod(0o600)
        source_config = verified_dir / "source-oci-config.json"
        source_config.write_bytes(detail["oci"]["config_bytes"])
        source_config.chmod(0o600)
        verified = {
            "schema": 1,
            "status": "verified",
            "request_sha256": request_sha,
            "publication_intent_sha256": publication_intent_sha256(request),
            "identity": request["identity"],
            "github_artifact": {
                "id": artifact["id"],
                "name": artifact["name"],
                "packaging_run_id": artifact["packaging_run_id"],
                "packaging_run_attempt": artifact["packaging_run_attempt"],
                "api_metadata_sha256": api_sha,
                "zip_sha256": zip_sha,
                "zip_size": zip_size,
            },
            "bundle": {
                "sha256sums_sha256": artifact["bundle_sha256sums_sha256"],
                "binary_archive_sha256": detail["binary_tar_sha256"],
                "binary_sha256sums_sha256": detail["binary_sums_sha256"],
                "manifest_sha256": detail["manifest_sha256"],
                "provenance_sha256": detail["provenance_sha256"],
                "packaging_package_sha256sums_sha256": packaging_seal_sha,
                "directory": "bundle",
            },
            "oci": {
                "archive_path": f"bundle/{names['oci_archive']}",
                "archive_sha256": sha256_file(bundle / names["oci_archive"]),
                "source_manifest_path": "verified/source-oci-manifest.json",
                "source_manifest_digest": detail["oci"]["manifest_digest"],
                "source_config_path": "verified/source-oci-config.json",
                "source_config_digest": detail["oci"]["config_digest"],
                "layer_count": detail["oci"]["layer_count"],
            },
            "binaries": detail["binary_hashes"],
            "candidate_authorization_ready": detail["authorization_ready"],
            "execution": request["execution"],
            "publication_authorized": bool(
                request["execution"]["execute"] and detail["authorization_ready"]
            ),
            "mutable_tag_is_rollout_authority": False,
        }
        write_new_json(temporary / "VERIFIED_INPUT.json", verified)
        os.replace(temporary, output)
        return verified
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


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


def parse_embedded_sums(path):
    entries = {}
    try:
        payload = read_regular_bytes(
            path, "imported-image binary ledger", MAX_TEXT_RECEIPT_BYTES
        ).decode("utf-8")
    except UnicodeError as error:
        raise VerificationError("imported-image binary ledger is not UTF-8") from error
    for line in payload.splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  /usr/local/bin/(blackcoin(?:-[a-z]+|d))", line)
        require(match is not None, "imported-image binary ledger is malformed")
        digest, name = match.groups()
        require(name not in entries, "imported-image binary ledger has a duplicate")
        entries[name] = digest
    require(set(entries) == set(EXPECTED_BINARIES), "imported image lacks one of six executables")
    return entries


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
    embedded_sums,
    published_now,
    output,
):
    verified_path = Path(verified_path)
    root = verified_path.parent
    verified = load_json(verified_path, "verified artifact receipt")
    request_path = Path(request_path)
    request, request_sha = load_request_with_sha(request_path)
    require(request["execution"]["execute"] is True, "registry verification requires live execution authority")
    require(request_sha == verified.get("request_sha256"),
            "execution request differs from the artifact-verification request")
    require(verified.get("publication_authorized") is True
            and verified.get("candidate_authorization_ready") is True,
            "verified artifact receipt does not authorize publication")
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
    require(len(tag_value["layers"]) == verified["oci"]["layer_count"],
            "registry manifest layer count differs from the source OCI config")
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
    identity = verified["identity"]
    require(labels.get("org.blackcoin.source.commit") == identity["source_commit"]
            and labels.get("org.blackcoin.source.tree") == identity["source_tree"],
            "registry config H/T labels changed")
    for binary, digest in verified["binaries"].items():
        require(labels.get(f"org.blackcoin.binary.{binary}.sha256") == digest,
                f"registry config binary label changed: {binary}")
    imported = load_json(Path(local_inspect), "imported image inspection")
    require(isinstance(imported, list) and len(imported) == 1, "imported image inspection changed")
    image = imported[0]
    require(image.get("Id") == expected_config and image.get("Os") == "linux"
            and image.get("Architecture") == "amd64", "imported image config/platform changed")
    imported_runtime = image.get("Config")
    require(isinstance(imported_runtime, dict) and imported_runtime.get("Labels") == labels,
            "imported image labels differ from the source config")
    require(parse_embedded_sums(Path(embedded_sums)) == verified["binaries"],
            "imported image six-executable hashes changed")
    repository = request["registry"]["repository"]
    immutable = f"{repository}@{tag_digest}"
    result = {
        "schema": 1,
        "result": "passed",
        "source_commit": identity["source_commit"],
        "source_tree": identity["source_tree"],
        "core_ci_run_id": identity["core_ci_run_id"],
        "packaging_tooling_commit": identity["packaging_tooling_commit"],
        "packaging_tooling_tree": identity["packaging_tooling_tree"],
        "artifact": verified["github_artifact"],
        "bundle": verified["bundle"],
        "source_oci": verified["oci"],
        "target_tag": f"{repository}:{request['registry']['tag']}",
        "immutable_image_ref": immutable,
        "registry_manifest_digest": tag_digest,
        "registry_config_digest": expected_config,
        "binaries": verified["binaries"],
        "execution_nonce": request["execution"]["nonce"],
        "published_now": bool(published_now),
        "same_response_digest_verified": True,
        "digest_refetch_verified": True,
        "remote_config_bytes_verified": True,
        "imported_six_executables_verified": True,
        "mutable_tag_is_rollout_authority": False,
        "handoff": {
            "candidate_artifact_name": verified["github_artifact"]["name"],
            "candidate_artifact_run_id": verified["github_artifact"]["packaging_run_id"],
            "candidate_artifact_run_attempt": verified["github_artifact"]["packaging_run_attempt"],
            "github_artifact_zip_sha256": verified["github_artifact"]["zip_sha256"],
            "candidate_bundle_sha256": verified["bundle"]["sha256sums_sha256"],
            "candidate_bundle_sha256sums_sha256": verified["bundle"]["sha256sums_sha256"],
            "candidate_image_ref": immutable,
            "candidate_image_id": expected_config,
            "candidate_oci_archive_sha256": verified["oci"]["archive_sha256"],
            "candidate_oci_manifest_sha256": verified["oci"]["source_manifest_digest"].removeprefix("sha256:"),
            "candidate_manifest_sha256": verified["bundle"]["manifest_sha256"],
            "candidate_provenance_sha256": verified["bundle"]["provenance_sha256"],
            "candidate_tooling_sha256": verified["bundle"]["packaging_package_sha256sums_sha256"],
            "candidate_packaging_tooling_sha256": verified["bundle"]["packaging_package_sha256sums_sha256"],
            "binary_sha256s": verified["binaries"],
        },
    }
    write_new_json(Path(output), result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare = subparsers.add_parser("prepare")
    prepare.add_argument("--request", required=True, type=Path)
    prepare.add_argument("--output", required=True, type=Path)
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
    registry.add_argument("--embedded-sums", required=True, type=Path)
    registry.add_argument("--published-now", required=True, choices=("true", "false"))
    registry.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            value = prepare_artifact(args.request, args.output)
            print(
                f"VERIFIED_INPUT={args.output / 'VERIFIED_INPUT.json'} "
                f"PUBLICATION_AUTHORIZED={str(value['publication_authorized']).lower()}"
            )
        else:
            value = verify_registry_evidence(
                args.verified, args.request, args.tag_manifest, args.tag_headers,
                args.digest_manifest, args.digest_headers, args.config_body,
                args.config_headers, args.local_inspect, args.embedded_sums,
                args.published_now == "true", args.output,
            )
            print(f"IMMUTABLE_IMAGE_REF={value['immutable_image_ref']}")
    except (OSError, UnicodeError, VerificationError) as error:
        parser.exit(1, f"v30.1.5 candidate publication verification failed: {error}\n")


if __name__ == "__main__":
    main()
