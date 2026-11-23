#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Validate the REPRODUCIBILITY.txt report of a release build.

The report lists, for every compared target, one SHA-256 digest line for every
file of the primary build. This tool parses the report strictly and requires a
valid digest entry for every expected compared artifact. It rejects missing,
duplicate, malformed and unexpected entries.
"""

import argparse
import hashlib
from pathlib import Path
import re
import sys


DIGEST_LINE_RE = re.compile(r"^(?P<digest>[0-9a-f]{64})  (?P<target>[^/\s]+)/(?P<path>\S.*)$")
TARGET_LINE_RE = re.compile(r"^target=(?P<target>[^/\s=]+)$")
FULL_SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def sha256(path):
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def _bad_path(path):
    parts = path.split("/")
    return any(part in ("", ".", "..") for part in parts) or "\\" in path


def parse_report(text):
    """Return (header, targets, source_commit). Raise RuntimeError on any malformed line.

    header is a dict of the three metadata fields. targets maps each target to a
    dict of relative path to digest.
    """
    if not text.endswith("\n"):
        raise RuntimeError("reproducibility report does not end with a newline")
    lines = text[:-1].split("\n")
    header = {}
    for key in ("package_label", "prerelease_channel", "configured_version"):
        if not lines or not lines[0].startswith(key + "="):
            raise RuntimeError(f"reproducibility report must start with {key}=")
        value = lines.pop(0)[len(key) + 1:]
        if not value or value != value.strip():
            raise RuntimeError(f"reproducibility report has an empty or padded {key}")
        header[key] = value

    targets = {}
    current = None
    source_commit = None
    for number, line in enumerate(lines, start=4):
        if source_commit is not None:
            raise RuntimeError(f"line {number}: text after source_commit")
        if line.startswith("source_commit="):
            source_commit = line[len("source_commit="):]
            if not FULL_SHA_RE.fullmatch(source_commit):
                raise RuntimeError(f"line {number}: malformed source_commit")
            if current is not None and not targets[current]:
                raise RuntimeError(f"target {current} has no digest entry")
            current = None
            continue
        target_match = TARGET_LINE_RE.fullmatch(line)
        if target_match:
            if current is not None and not targets[current]:
                raise RuntimeError(f"target {current} has no digest entry")
            current = target_match.group("target")
            if current in targets:
                raise RuntimeError(f"line {number}: duplicate target {current}")
            targets[current] = {}
            continue
        digest_match = DIGEST_LINE_RE.fullmatch(line)
        if digest_match is None:
            raise RuntimeError(f"line {number}: malformed report line")
        if current is None:
            raise RuntimeError(f"line {number}: digest entry before any target line")
        if digest_match.group("target") != current:
            raise RuntimeError(
                f"line {number}: digest entry names target {digest_match.group('target')} "
                f"inside the block of target {current}"
            )
        path = digest_match.group("path")
        if _bad_path(path):
            raise RuntimeError(f"line {number}: unsafe artifact path {path!r}")
        if path in targets[current]:
            raise RuntimeError(f"line {number}: duplicate digest entry for {current}/{path}")
        targets[current][path] = digest_match.group("digest")
    if source_commit is None:
        raise RuntimeError("reproducibility report has no source_commit line")
    if not targets:
        raise RuntimeError("reproducibility report has no target")
    return header, targets, source_commit


def check_header(header, source_commit, *, package_label, prerelease_channel,
                 configured_version, source_sha):
    expected = {
        "package_label": package_label,
        "prerelease_channel": prerelease_channel,
        "configured_version": configured_version,
    }
    for key, value in expected.items():
        if header[key] != value:
            raise RuntimeError(f"reproducibility report {key} is {header[key]!r}, expected {value!r}")
    if source_commit != source_sha:
        raise RuntimeError("reproducibility report source_commit does not match the exact source")


def check_expected(targets, expected):
    """expected maps target to a dict of relative path to digest."""
    if targets.keys() != expected.keys():
        missing = sorted(expected.keys() - targets.keys())
        unexpected = sorted(targets.keys() - expected.keys())
        raise RuntimeError(
            "reproducibility report targets differ from the compared builds"
            + (f"; missing: {', '.join(missing)}" if missing else "")
            + (f"; unexpected: {', '.join(unexpected)}" if unexpected else "")
        )
    for target, files in expected.items():
        recorded = targets[target]
        missing = sorted(files.keys() - recorded.keys())
        if missing:
            raise RuntimeError(f"digest entry missing for {target}/{missing[0]}")
        unexpected = sorted(recorded.keys() - files.keys())
        if unexpected:
            raise RuntimeError(f"digest entry for a file that was not compared: {target}/{unexpected[0]}")
        for path, digest in files.items():
            if recorded[path] != digest:
                raise RuntimeError(f"digest entry for {target}/{path} does not match the file")


def check_flat_artifacts(targets, files):
    """files maps a top-level artifact name to its digest (the canary bundle layout)."""
    for name, digest in sorted(files.items()):
        entries = [(target, recorded[name]) for target, recorded in targets.items() if name in recorded]
        if not entries:
            raise RuntimeError(f"digest entry missing for {name}")
        if len(entries) > 1:
            raise RuntimeError(f"digest entry for {name} appears under more than one target")
        if entries[0][1] != digest:
            raise RuntimeError(f"digest entry for {name} does not match the file")


def collect_primaries(artifacts, package_label, source_sha):
    """Return {target: {relative path: digest}} for every primary build directory."""
    prefix = f"release-{package_label}-"
    suffix = f"-primary-{source_sha}"
    expected = {}
    for primary in sorted(artifacts.glob(f"{prefix}*{suffix}")):
        if not primary.is_dir():
            continue
        target = primary.name[len(prefix):-len(suffix)]
        files = {}
        for entry in sorted(primary.rglob("*")):
            if entry.is_symlink():
                raise RuntimeError(f"release artifact must not be a symbolic link: {entry}")
            if entry.is_dir():
                continue
            if not entry.is_file():
                raise RuntimeError(f"unsupported release artifact type: {entry}")
            files[entry.relative_to(primary).as_posix()] = sha256(entry)
        if not files:
            raise RuntimeError(f"primary build directory is empty: {primary}")
        expected[target] = files
    if not expected:
        raise RuntimeError("no primary build directory was found")
    return expected


def validate(report, artifacts, *, package_label, prerelease_channel, configured_version, source_sha):
    header, targets, source_commit = parse_report(report.read_text(encoding="utf-8"))
    check_header(
        header, source_commit,
        package_label=package_label,
        prerelease_channel=prerelease_channel,
        configured_version=configured_version,
        source_sha=source_sha,
    )
    expected = collect_primaries(artifacts, package_label, source_sha)
    check_expected(targets, expected)
    return sum(len(files) for files in expected.values())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--artifacts", required=True, type=Path)
    parser.add_argument("--package-label", required=True)
    parser.add_argument("--prerelease-channel", required=True)
    parser.add_argument("--configured-version", required=True)
    parser.add_argument("--source-sha", required=True)
    args = parser.parse_args()
    count = validate(
        args.report, args.artifacts,
        package_label=args.package_label,
        prerelease_channel=args.prerelease_channel,
        configured_version=args.configured_version,
        source_sha=args.source_sha,
    )
    print(f"Reproducibility report lists {count} valid digest entries, one for every compared artifact")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as error:
        print(f"reproducibility report is invalid: {error}", file=sys.stderr)
        sys.exit(1)
