#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Focused fail-closed publication-state and signed-receipt regressions."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verify_publication_recovery_state as verifier  # noqa: E402


class PublicationRecoveryStateTests(unittest.TestCase):
    def setUp(self):
        self.manifest = verifier.load_manifest()
        self.head = "a" * 40
        self.now = 2_000_000_000

    def receipt(self):
        result = {key: self.manifest[key] for key in (
            "repository", "source_sha", "tag", "tag_object", "source_run_id", "source_run_attempt", "control_tag")}
        result.update(control_sha=self.head, enabled=True, captured_at=self.now - 10, expiry_epoch=self.now + 100)
        return result

    def environment(self):
        return {
            "GITHUB_ACTOR": self.manifest["actor"], "GITHUB_REPOSITORY": self.manifest["repository"],
            "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": f"refs/tags/{self.manifest['control_tag']}",
            "GITHUB_SHA": self.head, "GITHUB_WORKFLOW_SHA": self.head,
        }

    def evidence(self):
        manifest = self.manifest
        run = {
            "id": manifest["source_run_id"], "run_attempt": manifest["source_run_attempt"],
            "event": "push", "head_sha": manifest["source_sha"], "head_branch": manifest["tag"],
            "path": ".github/workflows/build.yml", "name": "v30.1.5 signed maintenance release build",
            "status": "completed", "conclusion": "failure",
            "repository": {"full_name": manifest["repository"]},
            "head_repository": {"full_name": manifest["repository"]},
            "actor": {"login": manifest["actor"]}, "triggering_actor": {"login": manifest["actor"]},
        }
        jobs = copy.deepcopy(manifest["jobs"])
        for job in jobs:
            job.update(status="completed", run_id=manifest["source_run_id"],
                       run_attempt=manifest["source_run_attempt"], head_sha=manifest["source_sha"])
            if job["conclusion"] == "failure":
                job["steps"] = [{**step, "status": "completed"} for step in manifest["publisher_steps"]]
        artifacts = [{**item, "expired": False, "workflow_run": {
            "id": manifest["source_run_id"], "head_sha": manifest["source_sha"], "head_branch": manifest["tag"],
        }} for item in manifest["artifacts"]]
        return run, jobs, artifacts

    def test_manifest_pin_and_duplicate_json_fields(self):
        self.assertEqual(self.manifest["source_sha"], "1038d1eed8e699580848dcca79de8f0f60430eb6")
        self.assertEqual(len(self.manifest["jobs"]), 36)
        self.assertEqual(len(self.manifest["artifacts"]), 6)
        for raw in ('{"enabled":true,"enabled":false}', '{"a":{"x":1,"x":2}}', '{"x":NaN}'):
            with self.assertRaises((RuntimeError, ValueError)):
                verifier.strict_json(raw)
        with mock.patch.object(verifier, "MANIFEST_SHA256", "0" * 64), self.assertRaises(RuntimeError):
            verifier.load_manifest()

    def test_exact_dispatch_environment(self):
        verifier.validate_environment(self.manifest, self.environment(), self.head)
        for key in self.environment():
            for value in (None, "wrong"):
                changed = self.environment()
                changed[key] = value
                with self.subTest(key=key, value=value), self.assertRaises(RuntimeError):
                    verifier.validate_environment(self.manifest, changed, self.head)
        with self.assertRaises(RuntimeError):
            verifier.validate_environment(self.manifest, self.environment(), self.manifest["source_sha"])

    def test_control_is_one_clean_commit_with_only_approved_regular_files(self):
        source = self.manifest["source_sha"]

        def git(*args):
            return {"rev-list": f"{self.head} {source}", "diff": "\n".join(verifier.ALLOWED_FILES),
                    "status": "", "ls-tree": "100644 blob " + "b" * 40 + "\t" + args[-1]}[args[0]]

        with mock.patch.object(verifier, "git", side_effect=git):
            verifier.validate_control_tree(self.manifest, self.head)
        for operation, value in (
                ("rev-list", f"{self.head} {source} {'b' * 40}"), ("rev-list", f"{self.head} {'b' * 40}"),
                ("diff", "\n".join(verifier.ALLOWED_FILES | {"src/wallet/wallet.cpp"})),
                ("diff", ".github/workflows/build.yml"), ("status", " M .github/workflows/build.yml"),
                ("ls-tree", "120000 blob " + "b" * 40 + "\tci/release/file")):
            with self.subTest(operation=operation), mock.patch.object(
                    verifier, "git", side_effect=lambda *args: value if args[0] == operation else git(*args)), \
                    self.assertRaises(RuntimeError):
                verifier.validate_control_tree(self.manifest, self.head)

    def test_source_run_and_jobs_require_exact_successes_and_known_publisher_failure(self):
        verifier.validate_source_run(self.manifest, *self.evidence())
        for key in self.evidence()[0]:
            run, jobs, artifacts = self.evidence()
            run[key] = {"full_name": "foreign", "login": "foreign"} if isinstance(run[key], dict) else "wrong"
            with self.subTest(run_field=key), self.assertRaises(RuntimeError):
                verifier.validate_source_run(self.manifest, run, jobs, artifacts)
        for key in ("id", "name", "conclusion", "status", "run_id", "run_attempt", "head_sha"):
            run, jobs, artifacts = self.evidence()
            jobs[0][key] = "wrong"
            with self.subTest(job_field=key), self.assertRaises(RuntimeError):
                verifier.validate_source_run(self.manifest, run, jobs, artifacts)
        for change in ("missing", "extra", "duplicate", "step_missing", "step_result", "step_order", "step_running"):
            run, jobs, artifacts = self.evidence()
            if change == "missing":
                jobs.pop(0)
            elif change == "extra":
                jobs.append(copy.deepcopy(jobs[0]))
            elif change == "duplicate":
                jobs[1] = copy.deepcopy(jobs[0])
            else:
                steps = next(job["steps"] for job in jobs if job["conclusion"] == "failure")
                if change == "step_missing":
                    steps.pop()
                elif change == "step_result":
                    steps[8]["conclusion"] = "success"
                elif change == "step_order":
                    steps.reverse()
                else:
                    steps[0]["status"] = "in_progress"
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                verifier.validate_source_run(self.manifest, run, jobs, artifacts)

    def test_required_artifacts_are_exact_unexpired_and_unambiguous(self):
        run, jobs, artifacts = self.evidence()
        verifier.validate_source_run(self.manifest, run, jobs, artifacts + [{"id": 1, "name": "unrelated"}])
        for key in ("id", "name", "digest", "size_in_bytes", "expired", "workflow_run"):
            run, jobs, artifacts = self.evidence()
            artifacts[0][key] = {} if key == "workflow_run" else "wrong"
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                verifier.validate_source_run(self.manifest, run, jobs, artifacts)
        for change in ("missing", "duplicate_id", "duplicate_name"):
            run, jobs, artifacts = self.evidence()
            if change == "missing":
                artifacts.pop()
            else:
                duplicate = copy.deepcopy(artifacts[0])
                if change == "duplicate_name":
                    duplicate["id"] = 1
                artifacts.append(duplicate)
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                verifier.validate_source_run(self.manifest, run, jobs, artifacts)

    def test_pagination_and_api_reads_fail_closed(self):
        pages = [{"total_count": 101, "jobs": [{"id": i} for i in range(100)]},
                 {"total_count": 101, "jobs": [{"id": 100}]}]
        with mock.patch.object(verifier, "api", side_effect=pages):
            self.assertEqual(len(verifier.api_inventory("endpoint", "jobs")), 101)
        for pages in ([{"total_count": 2, "jobs": []}], [{"total_count": 0, "jobs": [{}]}],
                      [{"total_count": True, "jobs": []}], [{"total_count": 10001, "jobs": []}]):
            with mock.patch.object(verifier, "api", side_effect=pages), self.assertRaises(RuntimeError):
                verifier.api_inventory("endpoint", "jobs")
        with mock.patch.object(verifier, "command", return_value=subprocess.CompletedProcess([], 1, "{}", "denied")), \
                self.assertRaises(RuntimeError):
            verifier.api("endpoint")

    def test_only_actual_http_404_proves_release_absence(self):
        for status, stdout, accepted in (
                (1, "HTTP/2.0 404 Not Found\n", True), (0, "HTTP/2.0 200 OK\n", False),
                (1, "HTTP/2.0 403 Forbidden\n", False), (1, "HTTP/2.0 500 Error\n", False),
                (1, "connection failed (HTTP 404)", False), (0, "HTTP/2.0 404 Not Found\n", False)):
            with self.subTest(stdout=stdout), mock.patch.object(
                    verifier, "command", return_value=subprocess.CompletedProcess([], status, stdout, "HTTP 404")):
                if accepted:
                    verifier.require_release_absent(self.manifest)
                else:
                    with self.assertRaises(RuntimeError):
                        verifier.require_release_absent(self.manifest)

    def test_github_verification_must_be_valid_for_exact_object(self):
        data = {"sha": self.head, "verification": {"verified": True, "reason": "valid"}}
        verifier.validate_verification(data, self.head)
        for changed in ({"sha": "b" * 40, "verification": data["verification"]},
                        {"sha": self.head, "verification": {"verified": True, "reason": "unknown_key"}},
                        {"sha": self.head, "verification": {"verified": False, "reason": "valid"}}):
            with self.assertRaises(RuntimeError):
                verifier.validate_verification(changed, self.head)

    def test_signed_source_control_and_both_remote_tags_are_bound(self):
        manifest = self.manifest
        control_object = "b" * 40
        prefix = f"repos/{manifest['repository']}/git/"
        responses = {}
        for sha in (manifest["source_sha"], self.head):
            responses[prefix + "commits/" + sha] = {
                "sha": sha, "verification": {"verified": True, "reason": "valid"},
                "parents": [{"sha": manifest["source_sha"]}],
            }
        for tag, sha, tag_object in ((manifest["tag"], manifest["source_sha"], manifest["tag_object"]),
                                     (manifest["control_tag"], self.head, control_object)):
            responses[prefix + "ref/tags/" + tag] = {
                "ref": f"refs/tags/{tag}", "object": {"type": "tag", "sha": tag_object},
            }
            responses[prefix + "tags/" + tag_object] = {
                "sha": tag_object, "tag": tag, "object": {"type": "commit", "sha": sha},
                "verification": {"verified": True, "reason": "valid"},
            }
        with mock.patch.object(verifier, "git", side_effect=lambda *args: control_object
                               if args[1].endswith(manifest["control_tag"]) else manifest["tag_object"]), \
                mock.patch.object(verifier.identity, "verify_commit") as commits, \
                mock.patch.object(verifier.identity, "verify_ssh_signature") as signatures, \
                mock.patch.object(verifier.identity, "verify_tag") as tags, \
                mock.patch.object(verifier, "api", side_effect=lambda endpoint: responses[endpoint]):
            verifier.verify_signed_objects(manifest, self.head)
            self.assertEqual(commits.call_count, 2)
            self.assertEqual(signatures.call_count, 2)
            self.assertEqual(tags.call_count, 2)
            for call in signatures.call_args_list:
                self.assertEqual(call.args[1:], ("commit", verifier.identity.EXPECTED_SSH_FINGERPRINT))
            for call in tags.call_args_list:
                self.assertEqual(call.args[2], verifier.identity.EXPECTED_SSH_FINGERPRINT)
            for endpoint, field, changed in (
                    (prefix + "commits/" + self.head, "parents", [{"sha": "c" * 40}]),
                    (prefix + "ref/tags/" + manifest["control_tag"], "object", {"type": "commit", "sha": self.head}),
                    (prefix + "tags/" + manifest["tag_object"], "object", {"type": "commit", "sha": self.head}),
                    (prefix + "tags/" + control_object, "verification", {"verified": False, "reason": "unsigned"})):
                original = responses[endpoint][field]
                responses[endpoint][field] = changed
                with self.subTest(endpoint=endpoint, field=field), self.assertRaises(RuntimeError):
                    verifier.verify_signed_objects(manifest, self.head)
                responses[endpoint][field] = original

    def test_receipt_exact_identity_fields_types_and_one_hour_validity(self):
        verifier.validate_receipt(self.receipt(), self.manifest, self.head, self.now)
        for key in verifier.RECEIPT_FIELDS:
            for mutation in ("remove", "change"):
                receipt = self.receipt()
                if mutation == "remove":
                    del receipt[key]
                else:
                    receipt[key] = "wrong"
                with self.subTest(key=key, mutation=mutation), self.assertRaises(RuntimeError):
                    verifier.validate_receipt(receipt, self.manifest, self.head, self.now)
        for changes in ({"extra": True}, {"enabled": 1}, {"enabled": False}, {"captured_at": True},
                        {"captured_at": self.now + 1}, {"expiry_epoch": self.now},
                        {"expiry_epoch": self.now + 3600}, {"captured_at": 0}):
            with self.subTest(changes=changes), self.assertRaises(RuntimeError):
                verifier.validate_receipt({**self.receipt(), **changes}, self.manifest, self.head, self.now)

    def test_receipt_signature_binds_exact_bytes_namespace_principal_and_fingerprint(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt, signature = Path(directory) / "receipt.json", Path(directory) / "receipt.sig"
            raw = (json.dumps(self.receipt()) + "\n").encode()
            receipt.write_bytes(raw)
            signature.write_bytes(b"test signature")
            line = (f'Good "{verifier.NAMESPACE}" signature for {verifier.identity.EXPECTED_EMAIL} '
                    f"with ED25519 key {verifier.identity.EXPECTED_SSH_FINGERPRINT}\n").encode()
            with mock.patch.object(verifier, "command", return_value=subprocess.CompletedProcess([], 0, line, b"")) as run:
                verifier.verify_receipt(receipt, signature, self.manifest, self.head, self.now)
                self.assertEqual(run.call_args.kwargs["input"], raw)
                args = run.call_args.args
                self.assertEqual(args[:3], ("ssh-keygen", "-Y", "verify"))
                self.assertEqual(args[args.index("-n") + 1], "blackcoin-release-configuration")
                self.assertEqual(args[args.index("-I") + 1], verifier.identity.EXPECTED_EMAIL)
            for status, output in ((1, line), (0, b"Good signature from another key\n")):
                with mock.patch.object(verifier, "command", return_value=subprocess.CompletedProcess([], status, output, b"")), \
                        self.assertRaises(RuntimeError):
                    verifier.verify_receipt(receipt, signature, self.manifest, self.head, self.now)
            with mock.patch.object(verifier, "command") as run, self.assertRaises(RuntimeError):
                verifier.verify_receipt(receipt, signature, self.manifest, self.head, self.now + 101)
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
