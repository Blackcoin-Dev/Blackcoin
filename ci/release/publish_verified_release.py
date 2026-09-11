#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Publish one fully verified release using a fresh developer-signed configuration receipt."""

import argparse
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

from verify_source_identity import (
    EXPECTED_EMAIL,
    EXPECTED_REPOSITORY,
    validate_allowed_signers,
)


RECEIPT_NAMESPACE = "blackcoin-immutable-releases"
RECEIPT_ENV = "IMMUTABLE_RELEASE_RECEIPT_B64"
SIGNATURE_ENV = "IMMUTABLE_RELEASE_RECEIPT_SIGNATURE_B64"
MAX_RECEIPT_LIFETIME = 86400


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(data):
    return json.loads(data, object_pairs_hook=unique_object)


def validate_identity(repository, source_sha, tag):
    require(repository == EXPECTED_REPOSITORY, "unexpected release repository")
    require(re.fullmatch(r"[0-9a-f]{40}", source_sha), "invalid source commit")
    require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:\.[1-9][0-9]*)?", tag), "invalid final release tag")


def validate_receipt(receipt, repository, source_sha, tag, tag_object, now):
    require(isinstance(receipt, dict) and set(receipt) == {
        "repository", "source_sha", "tag", "tag_object", "enabled", "captured_at", "expiry_epoch",
    }, "configuration receipt fields differ")
    for field, expected in (("repository", repository), ("source_sha", source_sha),
                            ("tag", tag), ("tag_object", tag_object)):
        require(type(receipt[field]) is str and receipt[field] == expected, f"receipt {field} differs")
    require(receipt["enabled"] is True, "immutable releases were not enabled")
    captured, expiry = receipt["captured_at"], receipt["expiry_epoch"]
    require(type(captured) is int and type(expiry) is int, "receipt times must be integer Unix seconds")
    require(0 < captured <= now < expiry, "configuration receipt is future-dated or expired")
    require(0 < expiry - captured <= MAX_RECEIPT_LIFETIME, "configuration receipt lifetime exceeds 86400 seconds")


def check_receipt(repository, source_sha, tag):
    validate_identity(repository, source_sha, tag)
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    target = subprocess.check_output(["git", "rev-parse", f"refs/tags/{tag}^{{commit}}"], text=True).strip()
    tag_object = subprocess.check_output(["git", "rev-parse", f"refs/tags/{tag}^{{tag}}"], text=True).strip()
    require(head == source_sha == target, "checkout or annotated tag target differs")
    require(re.fullmatch(r"[0-9a-f]{40}", tag_object), "invalid annotated tag object")
    encoded, encoded_signature = os.environ.get(RECEIPT_ENV, ""), os.environ.get(SIGNATURE_ENV, "")
    require(0 < len(encoded) <= 16384 and 0 < len(encoded_signature) <= 16384, "signed configuration receipt is missing or oversized")
    payload = base64.b64decode(encoded, validate=True)
    signature = base64.b64decode(encoded_signature, validate=True)
    allowed_signers = validate_allowed_signers()
    with tempfile.TemporaryDirectory(prefix="release-configuration-") as temporary:
        signature_path = Path(temporary) / "receipt.sig"
        signature_path.write_bytes(signature)
        subprocess.run([
            "ssh-keygen", "-Y", "verify", "-f", str(allowed_signers), "-I", EXPECTED_EMAIL,
            "-n", RECEIPT_NAMESPACE, "-s", str(signature_path),
        ], input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    validate_receipt(read_json(payload), repository, source_sha, tag, tag_object, int(time.time()))
    return tag_object


def release_names(version):
    prefix = f"Blackcoin-{version}"
    suffixes = {
        "Linux-x86_64.tar.gz", "Linux-ARM64.tar.gz", "Windows-x86_64-Portable.zip",
        "Windows-x86_64-Installer.exe", "macOS-Intel-x86_64-Qt-app.zip",
        "macOS-Intel-x86_64-Qt-app.tar.gz", "macOS-Apple-Silicon-ARM64-Qt-app.zip",
        "macOS-Apple-Silicon-ARM64-Qt-app.tar.gz", "REPRODUCIBILITY.txt", "SBOM.spdx.json",
        "provenance.intoto.json", "UNSIGNED-PRODUCTION.txt", "UNSIGNED-PRODUCTION.json",
    }
    suffixes.update(f"{platform}-SOURCE_COMMIT.txt" for platform in (
        "linux-64-bit", "linux-arm-64-bit", "windows-64-bit", "macos-64-bit", "macos-arm-64-bit",
    ))
    return {f"{prefix}-{suffix}" for suffix in suffixes} | {"SOURCE_COMMIT.txt", "SHA256SUMS.txt"}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inventory(dist, version, source_sha):
    require(dist.is_dir() and not dist.is_symlink(), "unsafe release directory")
    paths = list(dist.iterdir())
    require({path.name for path in paths} == release_names(version), "release inventory must contain exactly the expected twenty files")
    result = {}
    for path in paths:
        require(path.is_file() and not path.is_symlink() and path.stat().st_size > 0, "unsafe or empty release asset")
        if path.name.endswith("SOURCE_COMMIT.txt"):
            require(path.read_text(encoding="utf-8") == source_sha + "\n", "release source marker differs")
        result[path.name] = (path.stat().st_size, f"sha256:{sha256(path)}")
    checksums = {}
    for line in (dist / "SHA256SUMS.txt").read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([^/\\]+)", line)
        require(match is not None, "malformed checksum entry")
        digest, name = match.groups()
        require(name not in checksums, "duplicate checksum entry")
        checksums[name] = f"sha256:{digest}"
    require(checksums == {name: digest for name, (_, digest) in result.items() if name != "SHA256SUMS.txt"},
            "checksums do not bind the exact nineteen subjects")
    return result


def gh_json(endpoint, *options):
    return read_json(subprocess.check_output(["gh", "api", endpoint, *options], text=True))


def verify_remote_tag(repository, tag, tag_object):
    remote = gh_json(f"repos/{repository}/git/ref/tags/{tag}")
    require(isinstance(remote, dict) and remote.get("ref") == f"refs/tags/{tag}", "remote tag ref differs")
    target = remote.get("object")
    require(isinstance(target, dict) and target.get("type") == "tag" and target.get("sha") == tag_object,
            "remote annotated tag object differs from signed configuration receipt")


def listed_release(repository, tag, *, required):
    pages = gh_json(f"repos/{repository}/releases?per_page=100", "--paginate", "--slurp")
    require(isinstance(pages, list) and all(isinstance(page, list) for page in pages), "invalid authenticated release listing")
    releases = [release for page in pages for release in page]
    ids = set()
    for release in releases:
        require(isinstance(release, dict), "invalid release listing entry")
        release_id = release.get("id")
        require(type(release_id) is int and release_id > 0 and release_id not in ids, "duplicate or invalid listed release ID")
        ids.add(release_id)
    matches = [release for release in releases if release.get("tag_name") == tag]
    require(len(matches) == (1 if required else 0), "release tag already exists or is not uniquely listed")
    return matches[0] if required else None


def validate_release(release, repository, source_sha, tag, body, expected, release_id):
    require(isinstance(release, dict), "invalid release response")
    fields = {"id": release_id, "tag_name": tag, "name": f"Blackcoin Core {tag}",
              "body": body, "target_commitish": source_sha, "prerelease": False}
    for field, value in fields.items():
        require(type(release.get(field)) is type(value) and release[field] == value, f"release {field} differs")
    require(type(release.get("draft")) is bool, "invalid release draft state")
    require(release.get("url") == f"https://api.github.com/repos/{repository}/releases/{release_id}", "release API identity differs")
    assets = release.get("assets")
    require(isinstance(assets, list) and len(assets) == 20, "release asset count differs")
    actual = {}
    for asset in assets:
        name = asset.get("name")
        require(isinstance(name, str) and name not in actual, "duplicate or invalid release asset")
        require(asset.get("state") == "uploaded" and type(asset.get("size")) is int, "release asset upload is incomplete")
        actual[name] = (asset["size"], asset.get("digest"))
    require(actual == expected, "release assets differ in names, sizes or SHA256 digests")


def publish(repository, source_sha, tag, dist, notes):
    tag_object = check_receipt(repository, source_sha, tag)
    expected = inventory(dist, tag[1:], source_sha)
    require(notes.is_file() and not notes.is_symlink(), "unsafe release notes")
    body = notes.read_text(encoding="utf-8")
    require(body.strip(), "empty release notes")
    listed_release(repository, tag, required=False)
    verify_remote_tag(repository, tag, tag_object)
    # This mutation is deliberately never retried. Any ambiguous failure
    # requires inspecting the authenticated listing before a separate repair.
    subprocess.run([
        "gh", "release", "create", tag, *[str(dist / name) for name in sorted(expected)],
        "--repo", repository, "--draft", "--verify-tag", "--target", source_sha,
        "--title", f"Blackcoin Core {tag}", "--notes-file", str(notes),
    ], check=True)
    listed = listed_release(repository, tag, required=True)
    release_id = listed["id"]
    endpoint = f"repos/{repository}/releases/{release_id}"
    draft = gh_json(endpoint)
    validate_release(draft, repository, source_sha, tag, body, expected, release_id)
    require(draft["draft"] is True, "new release is not a draft")
    tag_object = check_receipt(repository, source_sha, tag)
    verify_remote_tag(repository, tag, tag_object)
    gh_json(endpoint, "--method", "PATCH", "-F", "draft=false", "-F", "prerelease=false", "-f", "make_latest=true")
    for attempt in range(12):
        final = gh_json(endpoint)
        validate_release(final, repository, source_sha, tag, body, expected, release_id)
        if final["draft"] is False and final.get("immutable") is True:
            latest = gh_json(f"repos/{repository}/releases/latest")
            if type(latest.get("id")) is int and latest["id"] == release_id:
                return {"release_id": release_id, "tag": tag, "immutable": True, "assets": len(expected)}
        if attempt < 11:
            time.sleep(5)
    raise ValueError("published release did not become immutable and latest within the read-only polling bound")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check-receipt", "publish"))
    parser.add_argument("--repository", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--dist", type=Path)
    parser.add_argument("--notes", type=Path)
    args = parser.parse_args()
    if args.command == "check-receipt":
        check_receipt(args.repository, args.source_sha, args.tag)
        print("Verified fresh developer-signed immutable-release configuration receipt")
    else:
        require(args.dist is not None and args.notes is not None, "publish requires --dist and --notes")
        print(json.dumps(publish(args.repository, args.source_sha, args.tag, args.dist, args.notes), sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, RuntimeError, binascii.Error, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
