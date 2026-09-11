#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Verify only the frozen v30.1.5 publication-recovery assets."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile


MANIFEST = Path(__file__).with_name("v30_1_5_publication_manifest.json")
SLSA = "https://slsa.dev/provenance/v1"
SPDX = "https://spdx.dev/Document/v2.3"
SHA256 = re.compile(r"[0-9a-f]{64}")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def artifact_files(manifest):
    prefix = f"Blackcoin-{manifest['version']}"
    platforms = {
        "linux-64-bit": ["Linux-x86_64.tar.gz"],
        "linux-arm-64-bit": ["Linux-ARM64.tar.gz"],
        "windows-64-bit": ["Windows-x86_64-Portable.zip", "Windows-x86_64-Installer.exe"],
        "macos-64-bit": ["macOS-Intel-x86_64-Qt-app.zip", "macOS-Intel-x86_64-Qt-app.tar.gz"],
        "macos-arm-64-bit": ["macOS-Apple-Silicon-ARM64-Qt-app.zip", "macOS-Apple-Silicon-ARM64-Qt-app.tar.gz"],
    }
    groups = {
        f"release-{manifest['version']}-{platform}-primary-{manifest['source_sha']}":
        {f"{prefix}-{suffix}" for suffix in suffixes} | {f"{prefix}-{platform}-SOURCE_COMMIT.txt"}
        for platform, suffixes in platforms.items()
    }
    groups[f"release-{manifest['version']}-reproducibility-{manifest['source_sha']}"] = {
        f"{prefix}-REPRODUCIBILITY.txt"
    }
    return groups


def release_names(manifest):
    prefix = f"Blackcoin-{manifest['version']}"
    return set().union(*artifact_files(manifest).values()) | {
        "SOURCE_COMMIT.txt", "SHA256SUMS.txt", f"{prefix}-SBOM.spdx.json",
        f"{prefix}-provenance.intoto.json", f"{prefix}-UNSIGNED-PRODUCTION.txt",
        f"{prefix}-UNSIGNED-PRODUCTION.json",
    }


def validate_manifest(manifest):
    require(manifest["repository"] == "Blackcoin-Dev/Blackcoin", "unexpected repository")
    require(manifest["version"] == "30.1.5" and manifest["tag"] == "v30.1.5", "unexpected release")
    require(re.fullmatch(r"[0-9a-f]{40}", manifest["source_sha"]), "invalid source identity")
    artifacts = manifest["artifacts"]
    require(len(artifacts) == 6, "expected six pinned artifacts")
    require(len({item["id"] for item in artifacts}) == 6, "duplicate artifact IDs")
    require(len({item["name"] for item in artifacts}) == 6, "duplicate artifact names")
    require({item["name"] for item in artifacts} == set(artifact_files(manifest)), "artifact names differ")
    for item in artifacts:
        require(type(item["id"]) is int and item["id"] > 0, "invalid artifact ID")
        require(type(item["size_in_bytes"]) is int and 0 < item["size_in_bytes"] <= 1024**3, "invalid artifact size")
        require(re.fullmatch(r"sha256:[0-9a-f]{64}", item["digest"]), "invalid artifact digest")
    require(len(release_names(manifest)) == 20, "expected twenty release files")


def extract_archive(archive, destination, expected_names):
    """Validate the whole flat archive before creating any extracted files."""
    require(not destination.exists() and not destination.is_symlink(), "artifact destination already exists")
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        names = [entry.filename for entry in entries]
        require(len(names) == len(set(names)), "duplicate archive member")
        for entry in entries:
            name = entry.filename
            require(name not in ("", ".", "..") and "/" not in name and "\\" not in name,
                    "non-flat or traversing archive member")
            require(not entry.is_dir() and stat.S_IFMT(entry.external_attr >> 16) in (0, stat.S_IFREG),
                    "non-regular archive member")
            require(not entry.flag_bits & 1, "encrypted archive member")
        require(set(names) == expected_names, "artifact file inventory differs")
        require(sum(entry.file_size for entry in entries) <= 2 * 1024**3, "archive expansion exceeds bound")
        destination.mkdir()
        for entry in entries:
            with source.open(entry) as incoming, (destination / entry.filename).open("xb") as outgoing:
                shutil.copyfileobj(incoming, outgoing, length=1024 * 1024)


def download(manifest, output):
    validate_manifest(manifest)
    require(not output.is_symlink(), "output must not be a symlink")
    output.mkdir(parents=True, exist_ok=True)
    require(not any(output.iterdir()), "download output must be empty")
    groups = artifact_files(manifest)
    with tempfile.TemporaryDirectory(prefix="publication-recovery-") as temporary:
        for item in manifest["artifacts"]:
            archive = Path(temporary) / f"{item['id']}.zip"
            with archive.open("wb") as sink:
                subprocess.run([
                    "gh", "api",
                    f"repos/{manifest['repository']}/actions/artifacts/{item['id']}/zip",
                ], stdout=sink, check=True)
            require(archive.stat().st_size == item["size_in_bytes"], "artifact archive size differs")
            require(f"sha256:{sha256(archive)}" == item["digest"], "artifact archive digest differs")
            extract_archive(archive, output / item["name"], groups[item["name"]])
    return {
        "primary_dirs": [str(output / name) for name in sorted(groups) if "-primary-" in name],
        "reproducibility_dir": str(next(output / name for name in groups if "-reproducibility-" in name)),
    }


def dist_inventory(manifest, dist):
    require(dist.is_dir() and not dist.is_symlink(), "unsafe release directory")
    paths = list(dist.iterdir())
    require({path.name for path in paths} == release_names(manifest), "release file inventory differs")
    require(all(path.is_file() and not path.is_symlink() and path.stat().st_size > 0 for path in paths),
            "release files must be nonempty regular files")
    inventory = {path.name: (path.stat().st_size, sha256(path)) for path in paths}
    expected = {name: digest for name, (_, digest) in inventory.items() if name != "SHA256SUMS.txt"}
    checksums = {}
    for line in (dist / "SHA256SUMS.txt").read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([^/\\]+)", line)
        require(match is not None, "malformed checksum entry")
        digest, name = match.groups()
        require(name not in checksums, "duplicate checksum entry")
        checksums[name] = digest
    require(checksums == expected, "checksums do not bind the exact nineteen subjects")
    return inventory


def subject_map(statement):
    subjects = statement.get("subject")
    require(isinstance(subjects, list), "missing attestation subjects")
    result = {}
    for subject in subjects:
        require(isinstance(subject, dict), "malformed attestation subject")
        name, digests = subject.get("name"), subject.get("digest")
        require(isinstance(name, str) and name not in result, "duplicate or invalid attestation subject")
        require(isinstance(digests, dict) and set(digests) == {"sha256"}
                and isinstance(digests["sha256"], str) and SHA256.fullmatch(digests["sha256"]),
                "invalid attestation subject digest")
        result[name] = digests["sha256"]
    return result


def verify_attestation(manifest, data, expected, predicate_type):
    """Input must be successful, policy-pinned `gh attestation verify --format json` output."""
    require(isinstance(data, list) and data, "missing verified attestations")
    invocation = (f"https://github.com/{manifest['repository']}/actions/runs/"
                  f"{manifest['source_run_id']}/attempts/{manifest['source_run_attempt']}")
    found = False
    for entry in data:
        verification = entry.get("verificationResult", {}) if isinstance(entry, dict) else {}
        statement = verification.get("statement", {})
        if not isinstance(statement, dict) or not statement:
            continue
        subjects = subject_map(statement)
        if statement.get("_type") != "https://in-toto.io/Statement/v1" or statement.get("predicateType") != predicate_type:
            continue
        if subjects != expected:
            continue
        if predicate_type == SLSA:
            actual = statement.get("predicate", {}).get("runDetails", {}).get("metadata", {}).get("invocationId")
            if actual != invocation:
                continue
        found = True
    require(found, "verified attestation does not bind the exact nineteen subjects")


def verify(manifest, dist, slsa, spdx):
    inventory = dist_inventory(manifest, dist)
    expected = {name: digest for name, (_, digest) in inventory.items() if name != "SHA256SUMS.txt"}
    for path, predicate_type in ((slsa, SLSA), (spdx, SPDX)):
        verify_attestation(manifest, json.loads(path.read_text(encoding="utf-8")), expected, predicate_type)
    return {"verified_subjects": len(expected), "release_files": len(inventory)}


def verify_release(manifest, dist, notes, release, phase):
    inventory = dist_inventory(manifest, dist)
    expected_fields = {
        "tag_name": manifest["tag"], "name": f"Blackcoin Core v{manifest['version']}",
        "body": notes.read_text(encoding="utf-8"), "target_commitish": manifest["source_sha"],
        "draft": phase == "draft", "prerelease": False,
    }
    require(phase in ("draft", "published"), "invalid release phase")
    for field, expected in expected_fields.items():
        require(release.get(field) == expected and type(release.get(field)) is type(expected),
                f"release {field} differs")
    if phase == "published":
        require(release.get("immutable") is True, "published release is not immutable")
    assets = release.get("assets")
    require(isinstance(assets, list) and len(assets) == 20, "release asset count differs")
    actual = {}
    for asset in assets:
        name = asset.get("name")
        require(isinstance(name, str) and name not in actual, "duplicate or invalid release asset")
        require(asset.get("state") == "uploaded", "release asset is not uploaded")
        require(type(asset.get("size")) is int and asset["size"] > 0, "invalid release asset size")
        actual[name] = (asset.get("size"), asset.get("digest"))
    expected = {name: (size, f"sha256:{digest}") for name, (size, digest) in inventory.items()}
    require(actual == expected, "release asset names, sizes or digests differ")
    return {"verified_assets": len(actual), "phase": phase}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("download").add_argument("--output", required=True, type=Path)
    verify_parser = commands.add_parser("verify")
    for name in ("dist", "slsa", "spdx"):
        verify_parser.add_argument(f"--{name}", required=True, type=Path)
    release_parser = commands.add_parser("release")
    for name in ("dist", "notes", "release"):
        release_parser.add_argument(f"--{name}", required=True, type=Path)
    release_parser.add_argument("--phase", required=True, choices=("draft", "published"))
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    validate_manifest(manifest)
    if args.command == "download":
        result = download(manifest, args.output)
    elif args.command == "verify":
        result = verify(manifest, args.dist, args.slsa, args.spdx)
    else:
        result = verify_release(manifest, args.dist, args.notes,
                                json.loads(args.release.read_text(encoding="utf-8")), args.phase)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
