#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Read-only, one-shot v30.1.5 publication recovery authorization checks."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

import verify_source_identity as identity


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "ci/release/v30_1_5_publication_manifest.json"
MANIFEST_SHA256 = "d2d8542e27c0e3abee27cc53178d90072a36db862eac8f2f68e63c5d5ea42381"
ALLOWED_FILES = {
    ".github/workflows/build.yml",
    "ci/release/v30_1_5_publication_manifest.json",
    "ci/release/verify_publication_recovery_state.py",
    "ci/release/test_publication_recovery_state.py",
    "ci/release/verify_publication_recovery_assets.py",
    "ci/release/test_publication_recovery_assets.py",
    "doc/release-evidence/v30.1.5-publication-recovery.md",
}
NAMESPACE = "blackcoin-release-configuration"
RECEIPT_FIELDS = {
    "repository", "source_sha", "tag", "tag_object", "source_run_id", "source_run_attempt",
    "control_sha", "control_tag", "enabled", "captured_at", "expiry_epoch",
}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def strict_json(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, f"duplicate JSON field: {key}")
            result[key] = value
        return result

    def reject_constant(value):
        raise RuntimeError(f"non-JSON numeric constant: {value}")

    return json.loads(raw, object_pairs_hook=unique, parse_constant=reject_constant)


def load_manifest():
    require(MANIFEST.is_file() and not MANIFEST.is_symlink(), "unsafe publication manifest")
    raw = MANIFEST.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == MANIFEST_SHA256, "publication manifest changed")
    return strict_json(raw)


def command(*args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=False, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, **kwargs)


def git(*args):
    result = command("git", *args, text=True)
    require(result.returncode == 0, f"git verification command failed: {args[0]}")
    return result.stdout.strip()


def api(endpoint):
    result = command("gh", "api", "--hostname", "github.com", endpoint, text=True)
    require(result.returncode == 0, f"GitHub API read failed: {endpoint}")
    return strict_json(result.stdout)


def api_inventory(endpoint, key):
    records = []
    for page in range(1, 101):
        data = api(f"{endpoint}?per_page=100&page={page}")
        require(type(data.get("total_count")) is int and type(data.get(key)) is list,
                f"invalid {key} inventory response")
        if page == 1:
            total = data["total_count"]
            require(0 <= total <= 10000, f"unbounded {key} inventory")
        require(data["total_count"] == total, f"{key} inventory changed during pagination")
        records.extend(data[key])
        require(len(records) <= total, f"duplicate or excess {key} inventory")
        if len(records) == total:
            return records
        require(len(data[key]) == 100, f"incomplete {key} inventory")
    raise RuntimeError(f"incomplete {key} inventory")


def validate_environment(manifest, env, head):
    expected = {
        "GITHUB_ACTOR": manifest["actor"], "GITHUB_REPOSITORY": manifest["repository"],
        "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": f"refs/tags/{manifest['control_tag']}",
        "GITHUB_SHA": head, "GITHUB_WORKFLOW_SHA": head,
    }
    require(bool(identity.FULL_SHA_RE.fullmatch(head)), "invalid control commit")
    require(all(env.get(key) == value for key, value in expected.items()),
            "publication recovery event, actor, repository, ref, or workflow commit mismatch")
    require(head != manifest["source_sha"], "control commit must be separate from release source")


def validate_control_tree(manifest, head):
    require(git("rev-list", "--parents", "-n", "1", head).split() == [head, manifest["source_sha"]],
            "control commit must have the frozen source as its sole parent")
    changed = set(git("diff", "--name-only", "--no-renames", manifest["source_sha"], head).splitlines())
    require(changed == ALLOWED_FILES, "control commit changed an unexpected recovery file set")
    require(not git("status", "--porcelain", "--untracked-files=all"), "control checkout is not clean")
    for path in ALLOWED_FILES:
        entry = git("ls-tree", head, "--", path).split()
        require(len(entry) == 4 and entry[0] in {"100644", "100755"} and entry[1] == "blob",
                f"unsafe recovery tree entry: {path}")


def validate_verification(data, sha):
    require(data.get("sha") == sha and data.get("verification", {}).get("verified") is True and
            data["verification"].get("reason") == "valid", "GitHub signed-object verification is not valid")


def verify_signed_objects(manifest, head):
    repo = manifest["repository"]
    for sha in (manifest["source_sha"], head):
        identity.verify_commit(sha)
        identity.verify_ssh_signature(sha, "commit", identity.EXPECTED_SSH_FINGERPRINT)
        data = api(f"repos/{repo}/git/commits/{sha}")
        validate_verification(data, sha)
        if sha == head:
            require([parent.get("sha") for parent in data.get("parents", [])] == [manifest["source_sha"]],
                    "GitHub control parent mismatch")
    for tag, sha in ((manifest["tag"], manifest["source_sha"]), (manifest["control_tag"], head)):
        identity.verify_tag(tag, sha, identity.EXPECTED_SSH_FINGERPRINT)
        tag_object = git("rev-parse", f"refs/tags/{tag}")
        if tag == manifest["tag"]:
            require(tag_object == manifest["tag_object"], "release tag object changed")
        ref = api(f"repos/{repo}/git/ref/tags/{tag}")
        require(ref.get("ref") == f"refs/tags/{tag}" and
                ref.get("object", {}).get("type") == "tag" and ref["object"].get("sha") == tag_object,
                "GitHub tag ref differs from signed local object")
        data = api(f"repos/{repo}/git/tags/{tag_object}")
        validate_verification(data, tag_object)
        require(data.get("tag") == tag and data.get("object", {}).get("type") == "commit" and
                data["object"].get("sha") == sha, "GitHub annotated tag target mismatch")


def validate_source_run(manifest, run, jobs, artifacts):
    fixed = {
        "id": manifest["source_run_id"], "run_attempt": manifest["source_run_attempt"],
        "event": "push", "head_sha": manifest["source_sha"], "head_branch": manifest["tag"],
        "path": ".github/workflows/build.yml", "name": "v30.1.5 signed maintenance release build",
        "status": "completed", "conclusion": "failure",
    }
    require(all(type(run.get(key)) is type(value) and run[key] == value for key, value in fixed.items()),
            "source release run identity or terminal state mismatch")
    for key in ("repository", "head_repository"):
        require(run.get(key, {}).get("full_name") == manifest["repository"], "source run repository mismatch")
    for key in ("actor", "triggering_actor"):
        require(run.get(key, {}).get("login") == manifest["actor"], "source run actor mismatch")
    expected = {item["id"]: item for item in manifest["jobs"]}
    require(len(jobs) == len(expected) and {item.get("id") for item in jobs} == set(expected),
            "source job inventory changed")
    for job in jobs:
        require({key: job.get(key) for key in ("id", "name", "conclusion")} == expected[job["id"]] and
                job.get("status") == "completed" and job.get("run_id") == manifest["source_run_id"] and
                job.get("run_attempt") == manifest["source_run_attempt"] and job.get("head_sha") == manifest["source_sha"],
                "source job identity or result mismatch")
        if job["conclusion"] == "failure":
            steps = job.get("steps", [])
            require([{key: step.get(key) for key in ("name", "conclusion")} for step in steps] ==
                    manifest["publisher_steps"] and all(step.get("status") == "completed" for step in steps),
                    "source publisher failure boundary changed")
    by_id = {item.get("id"): item for item in artifacts}
    require(len(by_id) == len(artifacts), "duplicate artifact identity")
    for expected_artifact in manifest["artifacts"]:
        item = by_id.get(expected_artifact["id"], {})
        require({key: item.get(key) for key in expected_artifact} == expected_artifact and
                item.get("expired") is False, "required artifact changed, expired, or missing")
        require(sum(other.get("name") == expected_artifact["name"] for other in artifacts) == 1,
                "ambiguous required artifact name")
        require(item.get("workflow_run", {}).get("id") == manifest["source_run_id"] and
                item["workflow_run"].get("head_sha") == manifest["source_sha"] and
                item["workflow_run"].get("head_branch") == manifest["tag"], "artifact source run mismatch")


def require_release_absent(manifest):
    result = command("gh", "api", "--hostname", "github.com", "--include",
                     f"repos/{manifest['repository']}/releases/tags/{manifest['tag']}", text=True)
    statuses = re.findall(r"^HTTP/\S+ ([0-9]{3})(?:\s|$)", result.stdout, re.MULTILINE)
    require(result.returncode != 0 and statuses == ["404"],
            "release absence is not proven by an exact HTTP 404")


def validate_receipt(receipt, manifest, head, now):
    require(type(receipt) is dict and set(receipt) == RECEIPT_FIELDS, "receipt fields are missing or unexpected")
    expected = {key: manifest[key] for key in (
        "repository", "source_sha", "tag", "tag_object", "source_run_id", "source_run_attempt", "control_tag")}
    expected.update(control_sha=head, enabled=True)
    require(all(type(receipt[key]) is type(value) and receipt[key] == value for key, value in expected.items()),
            "receipt identity or immutable-release enabled state mismatch")
    captured, expiry = receipt["captured_at"], receipt["expiry_epoch"]
    require(type(captured) is int and type(expiry) is int and type(now) is int and
            0 < captured <= now < expiry and 0 < expiry - captured <= 3600,
            "receipt is future-dated, expired, or exceeds its one-hour lifetime")


def verify_receipt(path, signature, manifest, head, now=None):
    path, signature = Path(path), Path(signature)
    for item in (path, signature):
        require(item.is_file() and not item.is_symlink() and 0 < item.stat().st_size <= 65536,
                "unsafe or oversized receipt/signature file")
    raw = path.read_bytes()
    receipt = strict_json(raw)
    validate_receipt(receipt, manifest, head, int(time.time()) if now is None else now)
    signers = identity.validate_allowed_signers()
    result = command("ssh-keygen", "-Y", "verify", "-f", str(signers), "-I", identity.EXPECTED_EMAIL,
                     "-n", NAMESPACE, "-s", str(signature), input=raw)
    expected = f'Good "{NAMESPACE}" signature for {identity.EXPECTED_EMAIL} with ED25519 key {identity.EXPECTED_SSH_FINGERPRINT}'
    output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
    require(result.returncode == 0 and expected in output.splitlines(), "configuration receipt SSH signature is not trusted")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    state = modes.add_parser("state")
    state.add_argument("--acknowledgement", required=True)
    receipt = modes.add_parser("receipt")
    receipt.add_argument("--receipt", required=True)
    receipt.add_argument("--signature", required=True)
    args = parser.parse_args()
    manifest = load_manifest()
    os.chdir(ROOT)
    head = git("rev-parse", "HEAD")
    validate_environment(manifest, os.environ, head)
    if args.mode == "receipt":
        verify_receipt(args.receipt, args.signature, manifest, head)
        print(f"signed immutable-release configuration is current for {head}")
        return
    require(args.acknowledgement == manifest["acknowledgement"], "publication acknowledgement mismatch")
    validate_control_tree(manifest, head)
    verify_signed_objects(manifest, head)
    endpoint = f"repos/{manifest['repository']}/actions/runs/{manifest['source_run_id']}"
    run = api(endpoint)
    jobs = api_inventory(f"{endpoint}/attempts/{manifest['source_run_attempt']}/jobs", "jobs")
    artifacts = api_inventory(f"{endpoint}/artifacts", "artifacts")
    validate_source_run(manifest, run, jobs, artifacts)
    require_release_absent(manifest)
    print(f"publication recovery state verified: source={manifest['source_sha']} control={head} "
          f"source_run={manifest['source_run_id']} attempt={manifest['source_run_attempt']} "
          f"jobs={len(jobs)} required_artifacts={len(manifest['artifacts'])}; release HTTP 404")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, KeyError, TypeError, OSError) as error:
        sys.exit(f"publication recovery refused: {error}")
