#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Verify the exact protected Core-CI result and zero-report TSan artifact."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import zipfile

import generate_v30_1_5_candidate_metadata as metadata


MAX_REPORT_BYTES = 16 * 1024 * 1024
REPORT_KEYS = (
    "target_sha",
    "sanitizer",
    "report_count",
    "report_bytes",
    "framing_error_count",
    "collector_error_count",
    "artifact_error",
    "capture_complete",
)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha256_bytes(value):
    return hashlib.sha256(value).hexdigest()


def sha256_file(path):
    require(path.is_file() and not path.is_symlink(), f"not a regular file: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_github_timestamp(value, description):
    require(isinstance(value, str), f"{description} is missing")
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError as error:
        raise RuntimeError(f"{description} is malformed") from error
    require(parsed.strftime("%Y-%m-%dT%H:%M:%SZ") == value, f"{description} is not canonical")
    return parsed


def load_api_json(path, description):
    return metadata.load_json(path, description)


def validate_run(run, policy):
    authorization = policy["authorization"]
    core = policy["core_ci"]
    run_id = authorization["core_ci_run_id"]
    run_attempt = authorization["core_ci_run_attempt"]
    require(type(run.get("id")) is int and run["id"] == run_id, "Core CI run ID changed")
    require(
        type(run.get("run_attempt")) is int and run["run_attempt"] == run_attempt,
        "Core CI run attempt changed",
    )
    require(type(run.get("check_suite_id")) is int and run["check_suite_id"] > 0, "Core CI check suite is malformed")
    require(run.get("path") == core["workflow_path"], "Core CI workflow path changed")
    require(run.get("name") == core["workflow_name"], "Core CI workflow name changed")
    require(run.get("event") == core["event"], "Core CI event changed")
    require(run.get("head_sha") == core["head_sha"], "Core CI head changed")
    require(run.get("status") == "completed", "Core CI did not complete")
    require(run.get("conclusion") == "success", "Core CI did not pass")
    parse_github_timestamp(run.get("updated_at"), "Core CI completion timestamp")
    require(run.get("actor", {}).get("login") == metadata.EXPECTED_ACTOR, "Core CI actor changed")
    require(
        run.get("triggering_actor", {}).get("login") == metadata.EXPECTED_ACTOR,
        "Core CI triggering actor changed",
    )
    require(run.get("repository", {}).get("full_name") == core["repository"], "Core CI repository changed")
    require(
        run.get("head_repository", {}).get("full_name") == core["head_repository"],
        "Core CI head repository changed",
    )
    head_commit = run.get("head_commit")
    require(isinstance(head_commit, dict), "Core CI head commit is missing")
    require(head_commit.get("id") == core["head_sha"], "Core CI head commit changed")
    require(head_commit.get("tree_id") == core["head_tree"], "Core CI head tree changed")
    pull_requests = run.get("pull_requests")
    require(isinstance(pull_requests, list), "Core CI pull request binding is malformed")
    if core["authority_state"] == "open":
        require(len(pull_requests) == 1, "open Core CI pull request binding changed")
        pull_request = pull_requests[0]
        require(
            type(pull_request.get("number")) is int
            and pull_request["number"] == core["pull_request_number"],
            "Core CI pull request changed",
        )
        require(pull_request.get("head", {}).get("sha") == core["head_sha"], "Core CI PR head changed")
        require(pull_request.get("base", {}).get("sha") == core["base_sha"], "Core CI PR base changed")
    elif core["authority_state"] == "merged":
        require(not pull_requests, "terminal merged Core CI run binding changed")
    else:
        raise RuntimeError("Core CI authority is not dispatchable")


def validate_jobs(jobs_document, check_runs_document, run, policy):
    jobs = jobs_document.get("jobs")
    require(isinstance(jobs, list), "Core CI jobs response is malformed")
    require(
        type(jobs_document.get("total_count")) is int and jobs_document["total_count"] == len(jobs),
        "Core CI jobs response is incomplete",
    )
    expected_names = policy["core_ci"]["required_checks"]
    require(len(jobs) == len(expected_names), "Core CI job count changed")
    by_name = {}
    job_ids = set()
    for job in jobs:
        require(isinstance(job, dict), "Core CI job record is malformed")
        name = job.get("name")
        require(isinstance(name, str) and name, "Core CI job name is malformed")
        require(name not in by_name, "Core CI contains a duplicate job name")
        require(type(job.get("id")) is int and job["id"] > 0, "Core CI job ID is malformed")
        require(job["id"] not in job_ids, "Core CI contains a duplicate job ID")
        job_ids.add(job["id"])
        require(
            type(job.get("run_id")) is int
            and job["run_id"] == policy["authorization"]["core_ci_run_id"],
            "Core CI job run ID changed",
        )
        require(
            type(job.get("run_attempt")) is int
            and job["run_attempt"] == policy["authorization"]["core_ci_run_attempt"],
            "Core CI job attempt changed",
        )
        require(job.get("head_sha") == policy["core_ci"]["head_sha"], "Core CI job head changed")
        require(job.get("status") == "completed", f"Core CI job did not complete: {name}")
        require(job.get("conclusion") == "success", f"Core CI job did not pass: {name}")
        by_name[name] = job
    require(set(by_name) == set(expected_names), "Core CI protected job set changed")
    check_runs = check_runs_document.get("check_runs")
    require(isinstance(check_runs, list), "Core CI check-runs response is malformed")
    require(
        type(check_runs_document.get("total_count")) is int
        and check_runs_document["total_count"] == len(check_runs)
        and len(check_runs) == len(expected_names),
        "Core CI check-run inventory changed or is incomplete",
    )
    check_runs_by_name = {}
    for check_run in check_runs:
        require(isinstance(check_run, dict), "Core CI check-run record is malformed")
        name = check_run.get("name")
        require(isinstance(name, str) and name and name not in check_runs_by_name, "Core CI check-run name is malformed or duplicated")
        require(type(check_run.get("id")) is int and check_run["id"] > 0, "Core CI check-run ID is malformed")
        require(check_run["id"] == by_name.get(name, {}).get("id"), "Core CI job/check-run identity changed")
        require(check_run.get("head_sha") == policy["core_ci"]["head_sha"], "Core CI check-run head changed")
        require(check_run.get("status") == "completed", f"Core CI check run did not complete: {name}")
        require(check_run.get("conclusion") == "success", f"Core CI check run did not pass: {name}")
        require(
            type(check_run.get("check_suite", {}).get("id")) is int
            and check_run["check_suite"]["id"] == run["check_suite_id"],
            "Core CI check suite changed",
        )
        require(
            type(check_run.get("app", {}).get("id")) is int
            and check_run["app"]["id"] == policy["core_ci"]["required_checks_app_id"],
            "Core CI check-run app changed",
        )
        check_runs_by_name[name] = check_run
    require(set(check_runs_by_name) == set(expected_names), "Core CI protected check-run set changed")
    return [
        {
            "id": by_name[name]["id"],
            "name": name,
            "app_id": check_runs_by_name[name]["app"]["id"],
            "status": "completed",
            "conclusion": "success",
        }
        for name in expected_names
    ]


def validate_unique_exact_run(workflow_runs_document, policy):
    runs = workflow_runs_document.get("workflow_runs")
    require(isinstance(runs, list), "exact-head workflow-runs response is malformed")
    require(
        type(workflow_runs_document.get("total_count")) is int
        and workflow_runs_document["total_count"] == 1
        and len(runs) == 1,
        "Core CI exact-head pull-request run is not unique",
    )
    run = runs[0]
    require(isinstance(run, dict), "exact-head workflow run is malformed")
    authorization = policy["authorization"]
    core = policy["core_ci"]
    require(
        type(run.get("id")) is int and run["id"] == authorization["core_ci_run_id"],
        "unique Core CI run ID changed",
    )
    require(
        type(run.get("run_attempt")) is int
        and run["run_attempt"] == authorization["core_ci_run_attempt"],
        "unique Core CI attempt changed",
    )
    require(run.get("head_sha") == core["head_sha"], "unique Core CI head changed")
    require(run.get("event") == core["event"], "unique Core CI event changed")
    require(run.get("path") == core["workflow_path"], "unique Core CI workflow path changed")
    require(run.get("name") == core["workflow_name"], "unique Core CI workflow name changed")


def validate_merge_commit(merge_commit, merged_at, policy):
    core = policy["core_ci"]
    expected_sha = core["merge_commit_sha"]
    require(isinstance(merge_commit, dict), "Core merge commit response is missing")
    require(merge_commit.get("sha") == expected_sha, "Core merge commit changed")
    commit = merge_commit.get("commit")
    require(isinstance(commit, dict), "Core merge commit metadata is missing")
    require(commit.get("tree", {}).get("sha") == core["head_tree"], "Core merge tree differs from the tested tree")
    parents = merge_commit.get("parents")
    require(isinstance(parents, list) and len(parents) == 2, "Core merge is not an exact two-parent merge commit")
    require(
        [parent.get("sha") if isinstance(parent, dict) else None for parent in parents]
        == [core["base_sha"], core["head_sha"]],
        "Core merge parent order or identity changed",
    )
    verification = commit.get("verification")
    require(isinstance(verification, dict), "Core merge verification is missing")
    require(verification.get("verified") is True, "Core merge commit is not verified")
    require(verification.get("reason") == "valid", "Core merge verification is not valid")
    require(isinstance(verification.get("signature"), str) and verification["signature"], "Core merge signature is missing")
    require(isinstance(verification.get("payload"), str) and verification["payload"], "Core merge signed payload is missing")
    author_account = merge_commit.get("author")
    committer_account = merge_commit.get("committer")
    require(isinstance(author_account, dict), "Core merge author account is missing")
    require(isinstance(committer_account, dict), "Core merge signer account is missing")
    require(author_account.get("login") == metadata.EXPECTED_MERGE_ACTOR, "Core merge author changed")
    require(
        committer_account.get("login") == metadata.EXPECTED_MERGE_COMMITTER,
        "Core merge signer identity changed",
    )
    author = commit.get("author")
    committer = commit.get("committer")
    require(isinstance(author, dict), "Core merge author metadata is missing")
    require(isinstance(committer, dict), "Core merge committer metadata is missing")
    require(author.get("name") == metadata.EXPECTED_MERGE_AUTHOR_NAME, "Core merge author name changed")
    require(author.get("email") == metadata.EXPECTED_MERGE_AUTHOR_EMAIL, "Core merge author email changed")
    require(committer.get("name") == metadata.EXPECTED_MERGE_COMMITTER_NAME, "Core merge committer name changed")
    require(committer.get("email") == metadata.EXPECTED_MERGE_COMMITTER_EMAIL, "Core merge committer email changed")
    parse_github_timestamp(author.get("date"), "Core merge author timestamp")
    parse_github_timestamp(committer.get("date"), "Core merge committer timestamp")
    require(author["date"] == merged_at and committer["date"] == merged_at, "Core merge timestamp changed")
    return {
        "sha": expected_sha,
        "tree": core["head_tree"],
        "parents": [core["base_sha"], core["head_sha"]],
        "github_verified": True,
        "github_verification_reason": "valid",
        "author_login": metadata.EXPECTED_MERGE_ACTOR,
        "committer_login": metadata.EXPECTED_MERGE_COMMITTER,
        "author": {
            "name": author["name"],
            "email": author["email"],
            "date": author["date"],
        },
        "committer": {
            "name": committer["name"],
            "email": committer["email"],
            "date": committer["date"],
        },
    }


def validate_current_authority(main_branch, pull_request, merge_commit, run, policy):
    core = policy["core_ci"]
    require(isinstance(main_branch, dict), "Core main branch response is malformed")
    require(isinstance(pull_request, dict), "Core pull request response is malformed")
    require(main_branch.get("name") == "main", "Core base branch changed")
    require(main_branch.get("protected") is True, "Core main branch is not protected")
    protection = main_branch.get("protection")
    require(isinstance(protection, dict) and protection.get("enabled") is True, "Core main protection is not enabled")
    status_checks = protection.get("required_status_checks")
    require(isinstance(status_checks, dict), "Core main required-status-check protection is missing")
    require(status_checks.get("enforcement_level") == "everyone", "Core protection enforcement level changed")
    expected_names = core["required_checks"]
    require(status_checks.get("contexts") == expected_names, "Core protected context set changed")
    checks = status_checks.get("checks")
    require(isinstance(checks, list) and len(checks) == len(expected_names), "Core protected check set changed")
    protected_checks = []
    for name, check in zip(expected_names, checks):
        require(isinstance(check, dict) and set(check) == {"context", "app_id"}, "Core protected check is malformed")
        require(check.get("context") == name, "Core protected check order or name changed")
        require(
            type(check.get("app_id")) is int and check["app_id"] == core["required_checks_app_id"],
            "Core protected check app changed",
        )
        protected_checks.append({"context": name, "app_id": check["app_id"]})
    require(
        type(pull_request.get("number")) is int
        and pull_request["number"] == core["pull_request_number"],
        "current pull request changed",
    )
    require(pull_request.get("head", {}).get("sha") == core["head_sha"], "current pull request head changed")
    require(pull_request.get("head", {}).get("repo", {}).get("full_name") == core["head_repository"], "current PR head repository changed")
    require(pull_request.get("base", {}).get("ref") == "main", "current pull request base branch changed")
    require(pull_request.get("base", {}).get("sha") == core["base_sha"], "current pull request base changed")
    require(pull_request.get("base", {}).get("repo", {}).get("full_name") == core["repository"], "current PR base repository changed")
    authority_state = core["authority_state"]
    run_completed_at = run.get("updated_at")
    parse_github_timestamp(run_completed_at, "Core CI completion timestamp")
    if authority_state == "open":
        require(main_branch.get("commit", {}).get("sha") == core["base_sha"], "strict Core base is no longer fresh")
        require(pull_request.get("state") == "open", "current pull request is not open")
        require(pull_request.get("draft") is False, "current pull request is draft")
        require(pull_request.get("merged") is False, "current pull request unexpectedly merged")
        require(pull_request.get("mergeable") is True, "current pull request is not mergeable")
        require(pull_request.get("mergeable_state") == "clean", "current pull request does not satisfy current protection")
        merged_at = None
        merged_by = None
        merge_evidence = None
    elif authority_state == "merged":
        require(
            main_branch.get("commit", {}).get("sha") == core["merge_commit_sha"],
            "current Core main is not the exact approved merge commit",
        )
        require(pull_request.get("state") == "closed", "merged Core pull request is not closed")
        require(pull_request.get("draft") is False, "merged Core pull request was draft")
        require(pull_request.get("merged") is True, "Core pull request is not merged")
        require(pull_request.get("mergeable") is None, "terminal Core pull request mergeability changed")
        require(pull_request.get("mergeable_state") == "unknown", "terminal Core pull request state changed")
        require(pull_request.get("merge_commit_sha") == core["merge_commit_sha"], "Core PR merge commit changed")
        merged_at = pull_request.get("merged_at")
        merge_time = parse_github_timestamp(merged_at, "Core PR merge timestamp")
        require(pull_request.get("closed_at") == merged_at, "Core PR close and merge timestamps differ")
        merged_by_account = pull_request.get("merged_by")
        require(isinstance(merged_by_account, dict), "Core PR merger identity is missing")
        merged_by = merged_by_account.get("login")
        require(merged_by == metadata.EXPECTED_MERGE_ACTOR, "Core PR merger changed")
        require(
            parse_github_timestamp(run_completed_at, "Core CI completion timestamp") < merge_time,
            "Core PR merged before the exact successful run completed",
        )
        merge_evidence = validate_merge_commit(merge_commit, merged_at, policy)
    else:
        raise RuntimeError("Core CI authority is not dispatchable")
    return {
        "authority_state": authority_state,
        "run_completed_at": run_completed_at,
        "current_main_sha": main_branch["commit"]["sha"],
        "current_main_authority_fresh": True,
        "pull_request_state": pull_request["state"],
        "pull_request_draft": False,
        "pull_request_mergeable": pull_request.get("mergeable"),
        "pull_request_mergeable_state": pull_request.get("mergeable_state"),
        "pull_request_merged": pull_request.get("merged"),
        "pull_request_merged_at": merged_at,
        "pull_request_merged_by": merged_by,
        "merge_commit": merge_evidence,
        "branch_protection": {
            "enabled": True,
            "enforcement_level": "everyone",
            "contexts": list(expected_names),
            "checks": protected_checks,
        },
    }


def validate_reports(data, expected_source):
    require(len(data) <= MAX_REPORT_BYTES, "ThreadSanitizer reports.log is too large")
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError as error:
        raise RuntimeError("ThreadSanitizer reports.log is not ASCII") from error
    require(text.endswith("\n"), "ThreadSanitizer reports.log lacks a final newline")
    lines = text.splitlines()
    require(len(lines) == len(REPORT_KEYS), "ThreadSanitizer reports.log field count changed")
    values = {}
    for line in lines:
        require(line.count("=") == 1, "ThreadSanitizer reports.log contains a malformed line")
        key, value = line.split("=", 1)
        require(key in REPORT_KEYS, "ThreadSanitizer reports.log contains an unexpected field")
        require(key not in values, "ThreadSanitizer reports.log contains a duplicate field")
        values[key] = value
    require(tuple(values) == REPORT_KEYS, "ThreadSanitizer reports.log field order changed")
    require(values["target_sha"] == expected_source, "ThreadSanitizer target SHA changed")
    require(values["sanitizer"] == "thread-sanitizer", "sanitizer artifact kind changed")
    for key in (
        "report_count",
        "report_bytes",
        "framing_error_count",
        "collector_error_count",
        "artifact_error",
    ):
        require(values[key] == "0", f"ThreadSanitizer artifact is not clean: {key}")
    require(values["capture_complete"] == "1", "ThreadSanitizer capture is incomplete")
    return {
        "target_sha": values["target_sha"],
        "sanitizer": values["sanitizer"],
        "report_count": 0,
        "report_bytes": 0,
        "framing_error_count": 0,
        "collector_error_count": 0,
        "artifact_error": 0,
        "capture_complete": 1,
    }


def read_reports_from_zip(path):
    require(path.is_file() and not path.is_symlink(), "ThreadSanitizer artifact ZIP is not a regular file")
    try:
        with zipfile.ZipFile(path) as archive:
            members = archive.infolist()
            require(len(members) == 1, "ThreadSanitizer artifact ZIP inventory changed")
            member = members[0]
            member_path = PurePosixPath(member.filename)
            require(member.filename == "reports.log", "ThreadSanitizer artifact ZIP member changed")
            require(not member.is_dir(), "ThreadSanitizer artifact ZIP member is a directory")
            require(not member_path.is_absolute() and ".." not in member_path.parts, "unsafe artifact ZIP path")
            mode = member.external_attr >> 16
            file_type = stat.S_IFMT(mode)
            require(file_type in (0, stat.S_IFREG), "ThreadSanitizer artifact ZIP member is not regular")
            require(member.file_size <= MAX_REPORT_BYTES, "ThreadSanitizer artifact ZIP member is too large")
            require(member.flag_bits & 0x1 == 0, "ThreadSanitizer artifact ZIP member is encrypted")
            data = archive.read(member)
            require(len(data) == member.file_size, "ThreadSanitizer artifact ZIP member is truncated")
            return data
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        if isinstance(error, RuntimeError):
            raise
        raise RuntimeError("ThreadSanitizer artifact ZIP is invalid") from error


def validate_artifact(artifacts_document, artifact_zip, policy):
    artifacts = artifacts_document.get("artifacts")
    require(isinstance(artifacts, list), "Core CI artifacts response is malformed")
    require(
        type(artifacts_document.get("total_count")) is int
        and artifacts_document["total_count"] == len(artifacts),
        "Core CI artifacts response is incomplete",
    )
    expected = policy["authorization"]["thread_sanitizer_artifact"]
    matches = [artifact for artifact in artifacts if artifact.get("name") == expected["name"]]
    require(len(matches) == 1, "exact ThreadSanitizer artifact is missing or duplicated")
    artifact = matches[0]
    require(
        type(artifact.get("id")) is int and artifact["id"] == expected["id"],
        "ThreadSanitizer artifact ID changed",
    )
    require(artifact.get("expired") is False, "ThreadSanitizer artifact expired")
    require(type(artifact.get("size_in_bytes")) is int and artifact["size_in_bytes"] > 0, "ThreadSanitizer artifact is empty")
    require(artifact["size_in_bytes"] == artifact_zip.stat().st_size, "ThreadSanitizer artifact size changed")
    workflow_run = artifact.get("workflow_run")
    require(isinstance(workflow_run, dict), "ThreadSanitizer artifact workflow binding is missing")
    require(
        type(workflow_run.get("id")) is int
        and workflow_run["id"] == policy["authorization"]["core_ci_run_id"],
        "sanitizer artifact run changed",
    )
    require(workflow_run.get("head_sha") == policy["source"]["commit"], "sanitizer artifact source changed")
    zip_sha256 = sha256_file(artifact_zip)
    require(zip_sha256 == expected["zip_sha256"], "ThreadSanitizer artifact ZIP digest changed")
    require(artifact.get("digest") == f"sha256:{zip_sha256}", "ThreadSanitizer artifact API digest changed")
    reports = read_reports_from_zip(artifact_zip)
    reports_sha256 = sha256_bytes(reports)
    require(reports_sha256 == expected["reports_sha256"], "ThreadSanitizer reports.log digest changed")
    report = validate_reports(reports, policy["source"]["commit"])
    return {
        "id": artifact["id"],
        "name": artifact["name"],
        "size_in_bytes": artifact["size_in_bytes"],
        "expired": False,
        "api_digest": artifact["digest"],
        "zip_sha256": zip_sha256,
        "reports_sha256": reports_sha256,
        "report": report,
    }


def build_evidence(policy, required_checks, sanitizer_artifact, current_authority):
    core = policy["core_ci"]
    authorization = policy["authorization"]
    return {
        "schema": 3,
        "workflow_path": core["workflow_path"],
        "workflow_name": core["workflow_name"],
        "base_workflow_blob_sha256": core["base_workflow_blob_sha256"],
        "source_workflow_blob_sha256": core["source_workflow_blob_sha256"],
        "event": core["event"],
        "repository": core["repository"],
        "head_repository": core["head_repository"],
        "pull_request_number": core["pull_request_number"],
        "pull_request_head_sha": core["head_sha"],
        "pull_request_base_sha": core["base_sha"],
        "base_tree": core["base_tree"],
        "run_id": authorization["core_ci_run_id"],
        "run_attempt": authorization["core_ci_run_attempt"],
        "head_sha": core["head_sha"],
        "head_tree": core["head_tree"],
        "status": "completed",
        "conclusion": "success",
        "workflow_actor": metadata.EXPECTED_ACTOR,
        "workflow_triggering_actor": metadata.EXPECTED_ACTOR,
        "run_completed_at": current_authority["run_completed_at"],
        "base_branch": "main",
        "authority_state": current_authority["authority_state"],
        "current_main_sha": current_authority["current_main_sha"],
        "current_main_authority_fresh": current_authority["current_main_authority_fresh"],
        "pull_request_state": current_authority["pull_request_state"],
        "pull_request_draft": current_authority["pull_request_draft"],
        "pull_request_mergeable": current_authority["pull_request_mergeable"],
        "pull_request_mergeable_state": current_authority["pull_request_mergeable_state"],
        "pull_request_merged": current_authority["pull_request_merged"],
        "pull_request_merged_at": current_authority["pull_request_merged_at"],
        "pull_request_merged_by": current_authority["pull_request_merged_by"],
        "merge_commit": current_authority["merge_commit"],
        "exact_head_run_count": 1,
        "branch_protection": current_authority["branch_protection"],
        "required_checks": required_checks,
        "thread_sanitizer_artifact": sanitizer_artifact,
    }


def write_canonical_new(path, value):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    descriptor = os.open(path, flags, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as destination:
            json.dump(value, destination, sort_keys=True, separators=(",", ":"))
            destination.write("\n")
    except BaseException:
        try:
            Path(path).unlink()
        except OSError:
            pass
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--run-json", type=Path, required=True)
    parser.add_argument("--jobs-json", type=Path, required=True)
    parser.add_argument("--artifacts-json", type=Path, required=True)
    parser.add_argument("--main-branch-json", type=Path, required=True)
    parser.add_argument("--pull-request-json", type=Path, required=True)
    parser.add_argument("--merge-commit-json", type=Path, required=True)
    parser.add_argument("--workflow-runs-json", type=Path, required=True)
    parser.add_argument("--check-runs-json", type=Path, required=True)
    parser.add_argument("--artifact-zip", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    policy = metadata.validate_policy(args.policy)
    require(
        policy["authorization"]["state"] == metadata.READY_AUTHORIZATION_STATE,
        "candidate authorization is not ready",
    )
    run = load_api_json(args.run_json, "Core CI run response")
    jobs = load_api_json(args.jobs_json, "Core CI jobs response")
    artifacts = load_api_json(args.artifacts_json, "Core CI artifacts response")
    main_branch = load_api_json(args.main_branch_json, "Core main branch response")
    pull_request = load_api_json(args.pull_request_json, "Core pull request response")
    merge_commit = load_api_json(args.merge_commit_json, "Core merge commit response")
    workflow_runs = load_api_json(args.workflow_runs_json, "Core exact-head workflow-runs response")
    check_runs = load_api_json(args.check_runs_json, "Core check-runs response")
    validate_run(run, policy)
    validate_unique_exact_run(workflow_runs, policy)
    current_authority = validate_current_authority(main_branch, pull_request, merge_commit, run, policy)
    required_checks = validate_jobs(jobs, check_runs, run, policy)
    sanitizer_artifact = validate_artifact(artifacts, args.artifact_zip, policy)
    evidence = build_evidence(policy, required_checks, sanitizer_artifact, current_authority)
    write_canonical_new(args.output, evidence)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, zipfile.BadZipFile) as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        raise SystemExit(1)
