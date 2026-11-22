#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Fail-closed checks of what the qualification workflow is given: the build run, the build.yml Windows artifact
and the unsigned canary bundle of that run.

The layout this relies on is the one .github/workflows/build.yml produces:
  artifact  release-<package_label>-windows-64-bit-<primary|verifier>-<target_sha>
            Blackcoin-<package_label>-<target_sha>-Windows-x86_64-Portable.zip
            Blackcoin-<package_label>-<target_sha>-Windows-x86_64-Installer.exe
            Blackcoin-<package_label>-<target_sha>-windows-64-bit-SOURCE_COMMIT.txt
  artifact  unsigned-canary-<package_label>-<target_sha>   (reproducibility job)
            every file of the canary bundle, <prefix>-MANIFEST-UNSIGNED.json (sha256 of each file, source commit, run id)
            and <prefix>-SHA256SUMS-UNSIGNED.txt
"""

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile

ARTIFACT_RE = re.compile(
    r"^release-(?P<label>[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?-(?:alpha|beta)[1-9][0-9]*)"
    r"-windows-64-bit-(?P<builder>primary|verifier)-(?P<sha>[0-9a-f]{40})$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


class Rejected(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Rejected(message)


def parse_artifact_name(name, target_sha):
    require(SHA_RE.match(target_sha) is not None, "target_sha must be a full lowercase 40-character commit SHA")
    match = ARTIFACT_RE.match(name)
    require(match is not None, "artifact_name is not a build.yml Windows artifact name: %r" % name)
    require(match.group("sha") == target_sha, "the artifact name carries a different commit than target_sha")
    label = match.group("label")
    prefix = "Blackcoin-%s-%s" % (label, target_sha)
    return {"label": label, "builder": match.group("builder"), "prefix": prefix,
            "canary_name": "unsigned-canary-%s-%s" % (label, target_sha),
            "portable": prefix + "-Windows-x86_64-Portable.zip",
            "installer": prefix + "-Windows-x86_64-Installer.exe",
            "source_commit": prefix + "-windows-64-bit-SOURCE_COMMIT.txt"}


def configured_version(configure_ac):
    """The version string build.yml derives from configure.ac (resolve-target job, lines 76-98)."""
    def find(name):
        match = re.search(r"^define\(_CLIENT_VERSION_%s, ([0-9]+)\)$" % name, configure_ac, re.MULTILINE)
        return match.group(1) if match else None
    major, minor, build = find("MAJOR"), find("MINOR"), find("BUILD")
    require(major is not None and minor is not None and build is not None, "configure.ac has no client version")
    revision = find("REVISION") or "0"
    rc = find("RC")
    require(rc is not None, "configure.ac has no release candidate number")
    version = "%s.%s.%s" % (major, minor, build)
    if revision != "0":
        version += "." + revision
    if rc != "0":
        version += "rc" + rc
    return version


def verify_run(run, target_sha):
    """`gh run view --json headSha,conclusion,status,event`: a finished successful dispatch of exactly target_sha."""
    require(run.get("headSha") == target_sha, "the build run's head is %r, not target_sha" % run.get("headSha"))
    require(run.get("status") == "completed" and run.get("conclusion") == "success",
            "the build run is %s/%s, not completed/success" % (run.get("status"), run.get("conclusion")))
    require(run.get("event") == "workflow_dispatch", "the build run is a %r event, not workflow_dispatch" % run.get("event"))
    return {"head_sha": run["headSha"], "event": run["event"], "url": run.get("url", "")}


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def listing(directory):
    names = sorted(os.listdir(directory))
    for name in names:
        path = os.path.join(directory, name)
        require(os.path.isfile(path) and not os.path.islink(path), "%s is not a regular file" % name)
    return names


def verify_files(build_dir, canary_dir, names, target_sha, build_run_id):
    """The artifact holds exactly the three expected files, the canary manifest and checksum list agree with them."""
    expected = sorted([names["portable"], names["installer"], names["source_commit"]])
    require(listing(build_dir) == expected, "the build artifact holds %s, expected exactly %s" % (listing(build_dir), expected))
    with open(os.path.join(build_dir, names["source_commit"]), "r", encoding="utf-8") as handle:
        require(handle.read().strip() == target_sha, "the source commit marker is not target_sha")
    hashes = {name: sha256_file(os.path.join(build_dir, name)) for name in expected}

    manifest_name = names["prefix"] + "-MANIFEST-UNSIGNED.json"
    sums_name = names["prefix"] + "-SHA256SUMS-UNSIGNED.txt"
    canary = listing(canary_dir)
    require(manifest_name in canary and sums_name in canary, "the canary bundle lacks its manifest or checksum list")
    with open(os.path.join(canary_dir, manifest_name), "r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    require(manifest.get("source", {}).get("commit") == target_sha, "the manifest names a different source commit")
    require(str(manifest.get("workflow", {}).get("run_id")) == str(build_run_id), "the manifest names a different build run")
    require(manifest.get("release", {}).get("published") is False, "the manifest does not say unpublished")
    listed = {entry["name"]: entry["sha256"] for entry in manifest.get("artifacts", [])}
    sums = {}
    with open(os.path.join(canary_dir, sums_name), "r", encoding="utf-8") as handle:
        for line in handle.read().splitlines():
            digest, _, name = line.partition("  ")
            sums[name] = digest
    for name in expected:
        require(listed.get(name) == hashes[name], "the manifest hash of %s does not match the downloaded file" % name)
        require(sums.get(name) == hashes[name], "the checksum list hash of %s does not match the downloaded file" % name)
    # every file of the canary bundle must match its own listed hash too (the bundle is what the hashes vouch for)
    for name in canary:
        if name in (sums_name, manifest_name):
            continue
        require(sums.get(name) == sha256_file(os.path.join(canary_dir, name)), "the canary file %s does not match its checksum" % name)
    return {"files": hashes, "manifest": manifest_name, "checksum_list": sums_name, "run_id": str(build_run_id),
            "source_commit": target_sha}


def selftest():
    sha = "a" * 40
    label = "30.1.7-beta1"
    names = parse_artifact_name("release-%s-windows-64-bit-primary-%s" % (label, sha), sha)
    assert names["prefix"] == "Blackcoin-%s-%s" % (label, sha)
    assert names["canary_name"] == "unsigned-canary-%s-%s" % (label, sha)
    for bad in ("release-%s-linux-64-bit-primary-%s" % (label, sha), "release-%s-windows-64-bit-primary-%s" % (label, "b" * 40),
                "release-30.1.7-windows-64-bit-primary-" + sha, "x"):
        try:
            parse_artifact_name(bad, sha)
            raise AssertionError("accepted %r" % bad)
        except Rejected:
            pass
    try:
        parse_artifact_name("release-%s-windows-64-bit-primary-%s" % (label, sha), "short")
        raise AssertionError("accepted a short sha")
    except Rejected:
        pass
    ac = "define(_CLIENT_VERSION_MAJOR, 30)\ndefine(_CLIENT_VERSION_MINOR, 1)\ndefine(_CLIENT_VERSION_BUILD, 7)\n" \
         "define(_CLIENT_VERSION_REVISION, 0)\ndefine(_CLIENT_VERSION_RC, 1)\n"
    assert configured_version(ac) == "30.1.7rc1"
    assert configured_version(ac.replace("REVISION, 0", "REVISION, 2").replace("RC, 1", "RC, 0")) == "30.1.7.2"
    good = {"headSha": sha, "status": "completed", "conclusion": "success", "event": "workflow_dispatch"}
    assert verify_run(good, sha)["head_sha"] == sha
    for change in ({"headSha": "b" * 40}, {"conclusion": "failure"}, {"status": "in_progress"}, {"event": "push"}):
        try:
            verify_run(dict(good, **change), sha)
            raise AssertionError("accepted %s" % change)
        except Rejected:
            pass
    with tempfile.TemporaryDirectory() as temporary:
        build = os.path.join(temporary, "build")
        canary = os.path.join(temporary, "canary")
        os.makedirs(build)
        os.makedirs(canary)
        contents = {names["portable"]: b"zip", names["installer"]: b"exe", names["source_commit"]: (sha + "\n").encode()}
        for name, data in contents.items():
            for directory in (build, canary):
                path = os.path.join(directory, name)
                with open(path, "wb") as handle:
                    handle.write(data)
        marker = names["prefix"] + "-UNSIGNED-CANARY.txt"
        marker_path = os.path.join(canary, marker)
        with open(marker_path, "wb") as handle:
            handle.write(b"unsigned")
        manifest = {"source": {"commit": sha}, "workflow": {"run_id": "42"}, "release": {"published": False},
                    "artifacts": [{"name": n, "sha256": hashlib.sha256(d).hexdigest()} for n, d in contents.items()]}
        with open(os.path.join(canary, names["prefix"] + "-MANIFEST-UNSIGNED.json"), "w", encoding="utf-8") as handle:
            json.dump(manifest, handle)
        lines = ["%s  %s" % (hashlib.sha256(d).hexdigest(), n) for n, d in contents.items()]
        lines.append("%s  %s" % (hashlib.sha256(b"unsigned").hexdigest(), marker))
        with open(os.path.join(canary, names["prefix"] + "-SHA256SUMS-UNSIGNED.txt"), "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
        assert verify_files(build, canary, names, sha, 42)["run_id"] == "42"
        for attack in ("extra", "tamper", "wrong-run", "wrong-commit"):
            copy_build, copy_canary = build + "-" + attack, canary + "-" + attack
            os.makedirs(copy_build)
            os.makedirs(copy_canary)
            for src, dst in ((build, copy_build), (canary, copy_canary)):
                for name in os.listdir(src):
                    source_path, target_path = os.path.join(src, name), os.path.join(dst, name)
                    with open(source_path, "rb") as a:
                        with open(target_path, "wb") as b:
                            b.write(a.read())
            run_id = 42
            if attack == "extra":
                extra = os.path.join(copy_build, "extra.txt")
                with open(extra, "wb"):
                    pass
            elif attack == "tamper":
                tampered = os.path.join(copy_build, names["portable"])
                with open(tampered, "wb") as handle:
                    handle.write(b"other")
            elif attack == "wrong-run":
                run_id = 43
            else:
                with open(os.path.join(copy_build, names["source_commit"]), "w", encoding="utf-8") as handle:
                    handle.write("b" * 40 + "\n")
            try:
                verify_files(copy_build, copy_canary, names, sha, run_id)
                raise AssertionError("accepted %s" % attack)
            except Rejected:
                pass
    print("verify_inputs self-test passed")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    parse = sub.add_parser("parse", help="print key=value lines (for GITHUB_OUTPUT) derived from the artifact name")
    parse.add_argument("--artifact-name", required=True)
    parse.add_argument("--target-sha", required=True)
    run = sub.add_parser("run", help="check `gh run view --json headSha,status,conclusion,event,url` output")
    run.add_argument("--json", required=True)
    run.add_argument("--target-sha", required=True)
    files = sub.add_parser("files", help="check the downloaded build artifact against the canary bundle")
    files.add_argument("--build-dir", required=True)
    files.add_argument("--canary-dir", required=True)
    files.add_argument("--artifact-name", required=True)
    files.add_argument("--target-sha", required=True)
    files.add_argument("--build-run-id", required=True)
    files.add_argument("--output", required=True)
    version = sub.add_parser("version", help="print the configured version of a checkout")
    version.add_argument("--configure-ac", required=True)
    sub.add_parser("selftest")
    args = parser.parse_args()
    try:
        if args.command == "selftest":
            return selftest()
        if args.command == "parse":
            for key, value in parse_artifact_name(args.artifact_name, args.target_sha).items():
                print("%s=%s" % (key, value))
        elif args.command == "run":
            with open(args.json, "r", encoding="utf-8") as handle:
                print(json.dumps(verify_run(json.load(handle), args.target_sha)))
        elif args.command == "files":
            names = parse_artifact_name(args.artifact_name, args.target_sha)
            evidence = verify_files(args.build_dir, args.canary_dir, names, args.target_sha, args.build_run_id)
            with open(args.output, "w", encoding="utf-8", newline="\n") as handle:
                json.dump(evidence, handle, indent=2, sort_keys=True)
            print("verified %d files against the canary manifest and checksum list" % len(evidence["files"]))
        else:
            with open(args.configure_ac, "r", encoding="utf-8") as handle:
                print(configured_version(handle.read()))
    except Rejected as error:
        print("rejected: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
