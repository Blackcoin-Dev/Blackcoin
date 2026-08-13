#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.

import copy
import hashlib
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ci" / "release"))

import generate_v30_1_5_candidate_metadata as metadata  # noqa: E402
import verify_v30_1_5_core_ci as verifier  # noqa: E402


POLICY = ROOT / "contrib" / "ops" / "v30.1.5-candidate-package" / "policy.json"


def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")


class CoreCiReceiptTests(unittest.TestCase):
    RUN_ID = 987654
    RUN_ATTEMPT = 3
    ARTIFACT_ID = 765432

    def clean_report(self, *, source=metadata.EXPECTED_SOURCE_COMMIT):
        return (
            f"target_sha={source}\n"
            "sanitizer=thread-sanitizer\n"
            "report_count=0\n"
            "report_bytes=0\n"
            "framing_error_count=0\n"
            "collector_error_count=0\n"
            "artifact_error=0\n"
            "capture_complete=1\n"
        ).encode("ascii")

    def write_zip(self, path, report=None, *, member="reports.log", extra=False, mode=stat.S_IFREG | 0o600):
        if report is None:
            report = self.clean_report()
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            info = zipfile.ZipInfo(member)
            info.external_attr = mode << 16
            archive.writestr(info, report)
            if extra:
                archive.writestr("extra", b"unexpected")
        return report

    def fixture(self, directory, *, report=None, zip_options=None):
        directory = Path(directory)
        artifact_zip = directory / "artifact.zip"
        report = self.write_zip(artifact_zip, report, **(zip_options or {}))
        zip_sha = metadata.sha256(artifact_zip)
        reports_sha = hashlib.sha256(report).hexdigest()
        artifact_name = (
            f"sanitizer-reports-thread-sanitizer-{metadata.EXPECTED_SOURCE_COMMIT}-attempt-{self.RUN_ATTEMPT}"
        )
        policy = json.loads(POLICY.read_text(encoding="utf-8"))
        policy["authorization"] = {
            "state": metadata.READY_AUTHORIZATION_STATE,
            "dispatch_enabled": True,
            "temporary_source_pin": False,
            "core_ci_run_id": self.RUN_ID,
            "core_ci_run_attempt": self.RUN_ATTEMPT,
            "thread_sanitizer_artifact": {
                "id": self.ARTIFACT_ID,
                "name": artifact_name,
                "zip_sha256": zip_sha,
                "reports_sha256": reports_sha,
            },
        }
        run = {
            "id": self.RUN_ID,
            "check_suite_id": 246810,
            "run_attempt": self.RUN_ATTEMPT,
            "path": metadata.EXPECTED_WORKFLOW_PATH,
            "name": metadata.EXPECTED_WORKFLOW_NAME,
            "event": metadata.EXPECTED_CORE_CI_EVENT,
            "head_sha": metadata.EXPECTED_SOURCE_COMMIT,
            "head_commit": {
                "id": metadata.EXPECTED_SOURCE_COMMIT,
                "tree_id": metadata.EXPECTED_SOURCE_TREE,
            },
            "repository": {"full_name": metadata.EXPECTED_REPOSITORY},
            "head_repository": {"full_name": metadata.EXPECTED_REPOSITORY},
            "pull_requests": [{
                "number": metadata.EXPECTED_CORE_CI_PR,
                "head": {"sha": metadata.EXPECTED_SOURCE_COMMIT},
                "base": {"sha": metadata.EXPECTED_CORE_CI_BASE},
            }],
            "status": "completed",
            "conclusion": "success",
            "actor": {"login": metadata.EXPECTED_ACTOR},
            "triggering_actor": {"login": metadata.EXPECTED_ACTOR},
        }
        jobs = [
            {
                "id": 1000 + index,
                "name": name,
                "run_id": self.RUN_ID,
                "run_attempt": self.RUN_ATTEMPT,
                "head_sha": metadata.EXPECTED_SOURCE_COMMIT,
                "status": "completed",
                "conclusion": "success",
            }
            for index, name in enumerate(metadata.EXPECTED_REQUIRED_CHECKS)
        ]
        artifacts = [{
            "id": self.ARTIFACT_ID,
            "name": artifact_name,
            "expired": False,
            "size_in_bytes": artifact_zip.stat().st_size,
            "digest": f"sha256:{zip_sha}",
            "workflow_run": {
                "id": self.RUN_ID,
                "head_sha": metadata.EXPECTED_SOURCE_COMMIT,
            },
        }]
        main_ref = {
            "ref": "refs/heads/main",
            "object": {"type": "commit", "sha": metadata.EXPECTED_CORE_CI_BASE},
        }
        pull_request = {
            "number": metadata.EXPECTED_CORE_CI_PR,
            "state": "open",
            "draft": False,
            "mergeable": True,
            "mergeable_state": "clean",
            "head": {
                "sha": metadata.EXPECTED_SOURCE_COMMIT,
                "repo": {"full_name": metadata.EXPECTED_REPOSITORY},
            },
            "base": {
                "ref": "main",
                "sha": metadata.EXPECTED_CORE_CI_BASE,
                "repo": {"full_name": metadata.EXPECTED_REPOSITORY},
            },
        }
        workflow_runs = {"total_count": 1, "workflow_runs": [copy.deepcopy(run)]}
        check_runs = {
            "total_count": len(jobs),
            "check_runs": [
                {
                    "id": job["id"],
                    "name": job["name"],
                    "head_sha": metadata.EXPECTED_SOURCE_COMMIT,
                    "status": "completed",
                    "conclusion": "success",
                    "app": {"id": metadata.EXPECTED_REQUIRED_CHECKS_APP_ID},
                    "check_suite": {"id": run["check_suite_id"]},
                }
                for job in jobs
            ],
        }
        return policy, run, {"total_count": len(jobs), "jobs": jobs}, {
            "total_count": len(artifacts), "artifacts": artifacts,
        }, main_ref, pull_request, workflow_runs, check_runs, artifact_zip

    def validate(
        self, directory, policy, run, jobs, artifacts, main_ref, pull_request,
        workflow_runs, check_runs, artifact_zip,
    ):
        directory = Path(directory)
        policy_path = directory / "policy.json"
        write_json(policy_path, policy)
        checked_policy = metadata.validate_policy(policy_path)
        verifier.validate_run(run, checked_policy)
        verifier.validate_unique_exact_run(workflow_runs, checked_policy)
        verifier.validate_current_authority(main_ref, pull_request, checked_policy)
        checked_jobs = verifier.validate_jobs(jobs, check_runs, run, checked_policy)
        checked_artifact = verifier.validate_artifact(artifacts, artifact_zip, checked_policy)
        evidence = verifier.build_evidence(checked_policy, checked_jobs, checked_artifact)
        evidence_path = directory / "core-ci.json"
        verifier.write_canonical_new(evidence_path, evidence)
        self.assertEqual(metadata.validate_core_ci(evidence_path, checked_policy), evidence)
        return evidence

    def test_exact_sixteen_green_checks_and_zero_report_artifact_are_accepted(self):
        with tempfile.TemporaryDirectory() as temporary:
            values = self.fixture(temporary)
            evidence = self.validate(temporary, *values)
            self.assertEqual(
                [check["name"] for check in evidence["required_checks"]],
                list(metadata.EXPECTED_REQUIRED_CHECKS),
            )
            self.assertEqual(evidence["thread_sanitizer_artifact"]["report"]["report_count"], 0)

    def test_aggregate_success_cannot_hide_missing_extra_duplicate_or_failed_job(self):
        mutations = {
            "missing": lambda jobs: jobs["jobs"].pop(),
            "extra": lambda jobs: jobs["jobs"].append({**jobs["jobs"][0], "id": 99999, "name": "extra"}),
            "duplicate": lambda jobs: jobs["jobs"].__setitem__(1, {**jobs["jobs"][0], "id": 99998}),
            "failed": lambda jobs: jobs["jobs"][0].update({"conclusion": "failure"}),
            "wrong-attempt": lambda jobs: jobs["jobs"][0].update({"run_attempt": self.RUN_ATTEMPT + 1}),
            "wrong-run": lambda jobs: jobs["jobs"][0].update({"run_id": self.RUN_ID + 1}),
            "wrong-head": lambda jobs: jobs["jobs"][0].update({"head_sha": "0" * 40}),
            "duplicate-id": lambda jobs: jobs["jobs"][1].update({"id": jobs["jobs"][0]["id"]}),
            "boolean-id": lambda jobs: jobs["jobs"][0].update({"id": True}),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                policy, run, jobs, artifacts, main_ref, pull_request, workflow_runs, check_runs, artifact_zip = self.fixture(temporary)
                mutate(jobs)
                jobs["total_count"] = len(jobs["jobs"])
                with self.assertRaises(RuntimeError):
                    self.validate(
                        temporary, policy, run, jobs, artifacts, main_ref, pull_request,
                        workflow_runs, check_runs, artifact_zip,
                    )

    def test_exact_head_pull_request_run_must_be_unique_and_identical(self):
        mutations = (
            lambda document: document.update({"total_count": 0, "workflow_runs": []}),
            lambda document: document.update({"total_count": True}),
            lambda document: document.update({
                "total_count": 2,
                "workflow_runs": document["workflow_runs"] + [copy.deepcopy(document["workflow_runs"][0])],
            }),
            lambda document: document["workflow_runs"][0].update({"id": self.RUN_ID + 1}),
            lambda document: document["workflow_runs"][0].update({"run_attempt": self.RUN_ATTEMPT + 1}),
            lambda document: document["workflow_runs"][0].update({"head_sha": "0" * 40}),
            lambda document: document["workflow_runs"][0].update({"event": "workflow_dispatch"}),
            lambda document: document["workflow_runs"][0].update({"path": ".github/workflows/other.yml"}),
            lambda document: document["workflow_runs"][0].update({"name": "other"}),
        )
        for mutate in mutations:
            with self.subTest(mutate=mutate), tempfile.TemporaryDirectory() as temporary:
                values = list(self.fixture(temporary))
                mutate(values[6])
                with self.assertRaises(RuntimeError):
                    self.validate(temporary, *values)

    def test_exact_check_runs_and_actions_app_are_bound_to_jobs(self):
        mutations = (
            lambda checks: checks.update({"total_count": 0}),
            lambda checks: checks.update({"total_count": True}),
            lambda checks: checks["check_runs"].pop(),
            lambda checks: checks["check_runs"][0].update({"id": 1}),
            lambda checks: checks["check_runs"][0].update({"id": True}),
            lambda checks: checks["check_runs"][0].update({"name": "other"}),
            lambda checks: checks["check_runs"][0].update({"head_sha": "0" * 40}),
            lambda checks: checks["check_runs"][0]["app"].update({"id": 1}),
            lambda checks: checks["check_runs"][0]["app"].update({"id": True}),
            lambda checks: checks["check_runs"][0]["check_suite"].update({"id": 1}),
            lambda checks: checks["check_runs"][0].update({"conclusion": "failure"}),
        )
        for mutate in mutations:
            with self.subTest(mutate=mutate), tempfile.TemporaryDirectory() as temporary:
                values = list(self.fixture(temporary))
                mutate(values[7])
                with self.assertRaises(RuntimeError):
                    self.validate(temporary, *values)

    def test_run_identity_attempt_pr_status_and_tree_substitutions_are_rejected(self):
        mutations = (
            lambda run: run.update({"run_attempt": self.RUN_ATTEMPT + 1}),
            lambda run: run.update({"run_attempt": True}),
            lambda run: run.update({"id": True}),
            lambda run: run.update({"check_suite_id": True}),
            lambda run: run.update({"head_sha": "0" * 40}),
            lambda run: run["head_commit"].update({"tree_id": "0" * 40}),
            lambda run: run.update({"conclusion": "failure"}),
            lambda run: run["actor"].update({"login": "Other"}),
            lambda run: run["triggering_actor"].update({"login": "Other"}),
            lambda run: run["pull_requests"][0].update({"number": 50}),
            lambda run: run["pull_requests"][0]["base"].update({"sha": "0" * 40}),
        )
        for mutate in mutations:
            with self.subTest(mutate=mutate), tempfile.TemporaryDirectory() as temporary:
                policy, run, jobs, artifacts, main_ref, pull_request, workflow_runs, check_runs, artifact_zip = self.fixture(temporary)
                mutate(run)
                with self.assertRaises(RuntimeError):
                    self.validate(
                        temporary, policy, run, jobs, artifacts, main_ref, pull_request,
                        workflow_runs, check_runs, artifact_zip,
                    )

    def test_artifact_id_name_expiry_size_api_and_download_digests_are_bound(self):
        mutations = (
            lambda artifacts: artifacts["artifacts"][0].update({"id": self.ARTIFACT_ID + 1}),
            lambda artifacts: artifacts["artifacts"][0].update({"id": True}),
            lambda artifacts: artifacts["artifacts"][0].update({"name": "wrong"}),
            lambda artifacts: artifacts["artifacts"][0].update({"expired": True}),
            lambda artifacts: artifacts["artifacts"][0].update({"size_in_bytes": 0}),
            lambda artifacts: artifacts["artifacts"][0].update({"size_in_bytes": 1}),
            lambda artifacts: artifacts["artifacts"][0].update({"size_in_bytes": True}),
            lambda artifacts: artifacts["artifacts"][0].update({"digest": "sha256:" + "0" * 64}),
            lambda artifacts: artifacts["artifacts"][0]["workflow_run"].update({"id": self.RUN_ID + 1}),
            lambda artifacts: artifacts["artifacts"][0]["workflow_run"].update({"head_sha": "0" * 40}),
        )
        for mutate in mutations:
            with self.subTest(mutate=mutate), tempfile.TemporaryDirectory() as temporary:
                policy, run, jobs, artifacts, main_ref, pull_request, workflow_runs, check_runs, artifact_zip = self.fixture(temporary)
                mutate(artifacts)
                with self.assertRaises(RuntimeError):
                    self.validate(
                        temporary, policy, run, jobs, artifacts, main_ref, pull_request,
                        workflow_runs, check_runs, artifact_zip,
                    )

    def test_current_strict_main_and_pull_request_freshness_are_required(self):
        mutations = (
            lambda main_ref, pull: main_ref["object"].update({"sha": "0" * 40}),
            lambda main_ref, pull: main_ref.update({"ref": "refs/heads/other"}),
            lambda main_ref, pull: pull.update({"state": "closed"}),
            lambda main_ref, pull: pull.update({"draft": True}),
            lambda main_ref, pull: pull.update({"mergeable": False}),
            lambda main_ref, pull: pull.update({"mergeable_state": "blocked"}),
            lambda main_ref, pull: pull["head"].update({"sha": "0" * 40}),
            lambda main_ref, pull: pull["head"]["repo"].update({"full_name": "other/repo"}),
            lambda main_ref, pull: pull["base"].update({"ref": "other"}),
            lambda main_ref, pull: pull["base"].update({"sha": "0" * 40}),
        )
        for mutate in mutations:
            with self.subTest(mutate=mutate), tempfile.TemporaryDirectory() as temporary:
                policy, run, jobs, artifacts, main_ref, pull_request, workflow_runs, check_runs, artifact_zip = self.fixture(temporary)
                mutate(main_ref, pull_request)
                with self.assertRaises(RuntimeError):
                    self.validate(
                        temporary, policy, run, jobs, artifacts, main_ref, pull_request,
                        workflow_runs, check_runs, artifact_zip,
                    )

    def test_duplicate_named_artifact_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            policy, run, jobs, artifacts, main_ref, pull_request, workflow_runs, check_runs, artifact_zip = self.fixture(temporary)
            artifacts["artifacts"].append({**artifacts["artifacts"][0], "id": self.ARTIFACT_ID + 1})
            artifacts["total_count"] = 2
            with self.assertRaisesRegex(RuntimeError, "missing or duplicated"):
                self.validate(
                    temporary, policy, run, jobs, artifacts, main_ref, pull_request,
                    workflow_runs, check_runs, artifact_zip,
                )

    def test_zip_inventory_path_and_symlink_substitutions_are_rejected(self):
        options = (
            {"extra": True},
            {"member": "nested/reports.log"},
            {"member": "../reports.log"},
            {"mode": stat.S_IFLNK | 0o777},
        )
        for option in options:
            with self.subTest(option=option), tempfile.TemporaryDirectory() as temporary:
                values = self.fixture(temporary, zip_options=option)
                with self.assertRaises(RuntimeError):
                    self.validate(temporary, *values)

    def test_every_nonzero_incomplete_or_wrong_target_report_is_rejected(self):
        replacements = (
            (b"report_count=0\n", b"report_count=1\n"),
            (b"report_bytes=0\n", b"report_bytes=9\n"),
            (b"framing_error_count=0\n", b"framing_error_count=1\n"),
            (b"collector_error_count=0\n", b"collector_error_count=1\n"),
            (b"artifact_error=0\n", b"artifact_error=1\n"),
            (b"capture_complete=1\n", b"capture_complete=0\n"),
            (metadata.EXPECTED_SOURCE_COMMIT.encode(), b"0" * 40),
        )
        for old, new in replacements:
            with self.subTest(old=old), tempfile.TemporaryDirectory() as temporary:
                report = self.clean_report().replace(old, new)
                values = self.fixture(temporary, report=report)
                with self.assertRaises(RuntimeError):
                    self.validate(temporary, *values)

    def test_extra_duplicate_reordered_or_non_ascii_report_field_is_rejected(self):
        clean = self.clean_report()
        reports = (
            clean + b"extra=0\n",
            clean.replace(b"report_count=0\n", b"report_count=0\nreport_count=0\n"),
            b"sanitizer=thread-sanitizer\n" + clean.replace(b"sanitizer=thread-sanitizer\n", b""),
            clean.replace(b"sanitizer=thread-sanitizer", b"sanitizer=thread-sanitizer\xff"),
            clean.rstrip(b"\n"),
        )
        for report in reports:
            with self.subTest(report=report[:40]), tempfile.TemporaryDirectory() as temporary:
                values = self.fixture(temporary, report=report)
                with self.assertRaises(RuntimeError):
                    self.validate(temporary, *values)

    def test_blocked_or_partially_ready_policy_cannot_validate_runtime_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            policy, run, jobs, artifacts, main_ref, pull_request, workflow_runs, check_runs, artifact_zip = self.fixture(temporary)
            for field in ("core_ci_run_id", "core_ci_run_attempt", "thread_sanitizer_artifact"):
                changed = copy.deepcopy(policy)
                changed["authorization"][field] = None
                write_json(Path(temporary) / f"{field}.json", changed)
                with self.assertRaises(RuntimeError):
                    metadata.validate_policy(Path(temporary) / f"{field}.json")

    def test_evidence_output_is_exclusive_and_canonical(self):
        with tempfile.TemporaryDirectory() as temporary:
            values = self.fixture(temporary)
            evidence = self.validate(temporary, *values)
            output = Path(temporary) / "core-ci.json"
            self.assertEqual(
                output.read_text(encoding="utf-8"),
                json.dumps(evidence, sort_keys=True, separators=(",", ":")) + "\n",
            )
            with self.assertRaises(FileExistsError):
                verifier.write_canonical_new(output, evidence)


if __name__ == "__main__":
    unittest.main()
