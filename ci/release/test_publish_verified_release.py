#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Offline receipt, inventory and one-shot publication regressions."""

import base64
from copy import deepcopy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import publish_verified_release as publisher


REPOSITORY = "Blackcoin-Dev/Blackcoin"
SOURCE = "a" * 40
TAG_OBJECT = "b" * 40
TAG = "v30.1.5.1"
REMOTE_TAG = {"ref": f"refs/tags/{TAG}", "object": {"type": "tag", "sha": TAG_OBJECT}}


class VerifiedPublisherTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.dist = self.root / "dist"
        self.dist.mkdir()
        for name in publisher.release_names(TAG[1:]) - {"SHA256SUMS.txt"}:
            value = SOURCE + "\n" if name.endswith("SOURCE_COMMIT.txt") else name + "\n"
            (self.dist / name).write_text(value, encoding="utf-8")
        checksums = "".join(f"{publisher.sha256(path)}  {path.name}\n" for path in sorted(self.dist.iterdir()))
        (self.dist / "SHA256SUMS.txt").write_text(checksums, encoding="utf-8")
        self.expected = publisher.inventory(self.dist, TAG[1:], SOURCE)
        self.notes = self.root / "notes.md"
        self.notes.write_text("Exact approved release notes.\n", encoding="utf-8")
        self.receipt = {
            "repository": REPOSITORY, "source_sha": SOURCE, "tag": TAG, "tag_object": TAG_OBJECT,
            "enabled": True, "captured_at": 900, "expiry_epoch": 1100,
        }

    def release(self, draft):
        return {
            "id": 42, "tag_name": TAG, "name": f"Blackcoin Core {TAG}",
            "url": f"https://api.github.com/repos/{REPOSITORY}/releases/42",
            "target_commitish": SOURCE, "body": self.notes.read_text(encoding="utf-8"),
            "draft": draft, "prerelease": False, "immutable": not draft,
            "assets": [{"name": name, "size": size, "digest": digest, "state": "uploaded"}
                       for name, (size, digest) in self.expected.items()],
        }

    def test_receipt_is_exact_typed_fresh_and_bounded(self):
        publisher.validate_receipt(self.receipt, REPOSITORY, SOURCE, TAG, TAG_OBJECT, 1000)
        changes = (
            {"repository": "different"}, {"source_sha": "c" * 40}, {"tag": "v30.1.5"},
            {"tag_object": "c" * 40}, {"enabled": 1}, {"enabled": False},
            {"captured_at": True}, {"captured_at": "900"}, {"captured_at": 1001},
            {"expiry_epoch": 1000}, {"expiry_epoch": "1100"}, {"expiry_epoch": 87301}, {"extra": True},
        )
        for change in changes:
            with self.subTest(change=change), self.assertRaises(ValueError):
                publisher.validate_receipt({**self.receipt, **change}, REPOSITORY, SOURCE, TAG, TAG_OBJECT, 1000)
        with self.assertRaisesRegex(ValueError, "duplicate JSON"):
            publisher.read_json('{"enabled":false,"enabled":true}')

    def test_receipt_signature_uses_pinned_signer_namespace_and_exact_bytes(self):
        payload = json.dumps(self.receipt).encode()
        env = {publisher.RECEIPT_ENV: base64.b64encode(payload).decode(),
               publisher.SIGNATURE_ENV: base64.b64encode(b"signed bytes").decode()}
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(publisher.subprocess, "check_output", side_effect=[SOURCE, SOURCE, TAG_OBJECT]), \
                mock.patch.object(publisher.subprocess, "run") as verify, \
                mock.patch.object(publisher.time, "time", return_value=1000):
            publisher.check_receipt(REPOSITORY, SOURCE, TAG)
        command = verify.call_args.args[0]
        self.assertEqual(command[:3], ["ssh-keygen", "-Y", "verify"])
        self.assertEqual(command[command.index("-I") + 1], publisher.EXPECTED_EMAIL)
        self.assertEqual(command[command.index("-n") + 1], "blackcoin-immutable-releases")
        self.assertEqual(verify.call_args.kwargs["input"], payload)
        self.assertIs(verify.call_args.kwargs["check"], True)

    def test_missing_receipt_wrong_checkout_and_bad_signature_fail(self):
        env = {publisher.RECEIPT_ENV: base64.b64encode(json.dumps(self.receipt).encode()).decode(),
               publisher.SIGNATURE_ENV: base64.b64encode(b"signature").decode()}
        for fault in ("missing", "checkout", "signature"):
            with self.subTest(fault=fault), \
                    mock.patch.dict(os.environ, {} if fault == "missing" else env, clear=True), \
                    mock.patch.object(publisher.subprocess, "check_output",
                                      side_effect=["c" * 40 if fault == "checkout" else SOURCE, SOURCE, TAG_OBJECT]), \
                    mock.patch.object(publisher.subprocess, "run",
                                      side_effect=subprocess.CalledProcessError(1, "ssh-keygen")), \
                    self.assertRaises((ValueError, subprocess.CalledProcessError)):
                publisher.check_receipt(REPOSITORY, SOURCE, TAG)

    def test_inventory_is_exact_and_refuses_source_checksum_or_symlink_drift(self):
        self.assertEqual(len(self.expected), 20)
        for fault in ("extra", "marker", "checksum", "symlink"):
            with self.subTest(fault=fault):
                target = self.dist / ("extra" if fault == "extra" else "SOURCE_COMMIT.txt")
                original = target.read_bytes() if target.exists() else None
                if fault == "checksum":
                    target = self.dist / "SHA256SUMS.txt"
                    original = target.read_bytes()
                    target.write_bytes(original + original.splitlines()[0] + b"\n")
                elif fault == "symlink":
                    target.unlink()
                    target.symlink_to(self.notes)
                else:
                    target.write_text("wrong", encoding="utf-8")
                with self.assertRaises(ValueError):
                    publisher.inventory(self.dist, TAG[1:], SOURCE)
                target.unlink()
                if original is not None:
                    target.write_bytes(original)

    def test_authenticated_listing_rejects_existing_or_duplicate_release(self):
        for pages in ([[self.release(True)]], [[self.release(False)]], [[self.release(True)], [self.release(True)]]):
            with mock.patch.object(publisher, "gh_json", return_value=pages), self.assertRaises(ValueError):
                publisher.listed_release(REPOSITORY, TAG, required=False)
        with mock.patch.object(publisher, "gh_json", return_value=[[], [self.release(True)]]) as query:
            self.assertEqual(publisher.listed_release(REPOSITORY, TAG, required=True)["id"], 42)
            self.assertEqual(query.call_args.args[1:], ("--paginate", "--slurp"))

    def test_remote_tag_must_match_exact_receipted_annotated_object(self):
        with mock.patch.object(publisher, "gh_json", return_value=REMOTE_TAG) as query:
            publisher.verify_remote_tag(REPOSITORY, TAG, TAG_OBJECT)
            query.assert_called_once_with(f"repos/{REPOSITORY}/git/ref/tags/{TAG}")
        for field in ("ref", "type", "sha"):
            changed = deepcopy(REMOTE_TAG)
            if field == "ref":
                changed[field] = "refs/tags/v30.1.5"
            else:
                changed["object"][field] = "commit" if field == "type" else "c" * 40
            with self.subTest(field=field), mock.patch.object(publisher, "gh_json", return_value=changed), \
                    self.assertRaises(ValueError):
                publisher.verify_remote_tag(REPOSITORY, TAG, TAG_OBJECT)

    def test_release_identity_body_and_asset_mutation_are_not_tolerated(self):
        body = self.notes.read_text(encoding="utf-8")
        for fault in ("id", "tag_name", "target_commitish", "name", "body", "url", "prerelease", "duplicate", "size", "digest"):
            release = self.release(True)
            if fault == "duplicate":
                release["assets"][1] = deepcopy(release["assets"][0])
            elif fault in ("size", "digest"):
                release["assets"][0][fault] = 1 if fault == "size" else "sha256:" + "0" * 64
            else:
                release[fault] = "wrong"
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                publisher.validate_release(release, REPOSITORY, SOURCE, TAG, body, self.expected, 42)

    def test_publish_creates_and_patches_once_using_only_numeric_draft_reads(self):
        draft, final = self.release(True), self.release(False)
        responses = [[[]], REMOTE_TAG, [[draft]], draft, REMOTE_TAG, final, final, final]
        with mock.patch.object(publisher, "check_receipt", return_value=TAG_OBJECT) as receipt, \
                mock.patch.object(publisher, "gh_json", side_effect=responses) as api, \
                mock.patch.object(publisher.subprocess, "run") as create:
            result = publisher.publish(REPOSITORY, SOURCE, TAG, self.dist, self.notes)
        self.assertEqual(result, {"release_id": 42, "tag": TAG, "immutable": True, "assets": 20})
        self.assertEqual(receipt.call_count, 2)
        self.assertEqual(sum(call.args[0].endswith(f"git/ref/tags/{TAG}") for call in api.call_args_list), 2)
        self.assertEqual(create.call_count, 1)
        self.assertEqual(create.call_args.args[0][:4], ["gh", "release", "create", TAG])
        patches = [call for call in api.call_args_list if "PATCH" in call.args]
        self.assertEqual(len(patches), 1)
        self.assertEqual(patches[0].args, (f"repos/{REPOSITORY}/releases/42", "--method", "PATCH",
                                         "-F", "draft=false", "-F", "prerelease=false", "-f", "make_latest=true"))
        self.assertFalse(any("releases/tags/" in call.args[0] for call in api.call_args_list))

    def test_failed_creation_is_not_retried_and_existing_release_is_not_modified(self):
        for existing in (False, True):
            responses = [[[self.release(True)]]] if existing else [[[]], REMOTE_TAG]
            with self.subTest(existing=existing), mock.patch.object(publisher, "check_receipt", return_value=TAG_OBJECT), \
                    mock.patch.object(publisher, "gh_json", side_effect=responses) as api, \
                    mock.patch.object(publisher.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "gh")) as create, \
                    self.assertRaises((ValueError, subprocess.CalledProcessError)):
                publisher.publish(REPOSITORY, SOURCE, TAG, self.dist, self.notes)
            self.assertEqual(create.call_count, 0 if existing else 1)
            self.assertEqual(api.call_count, 1 if existing else 2)

    def test_nonimmutable_publication_has_bounded_read_only_polling(self):
        draft, final = self.release(True), self.release(False)
        final["immutable"] = False
        responses = [[[]], REMOTE_TAG, [[draft]], draft, REMOTE_TAG, final] + [final] * 12
        with mock.patch.object(publisher, "check_receipt", return_value=TAG_OBJECT), \
                mock.patch.object(publisher, "gh_json", side_effect=responses) as api, \
                mock.patch.object(publisher.subprocess, "run") as create, \
                mock.patch.object(publisher.time, "sleep") as sleep, \
                self.assertRaisesRegex(ValueError, "polling bound"):
            publisher.publish(REPOSITORY, SOURCE, TAG, self.dist, self.notes)
        self.assertEqual(create.call_count, 1)
        self.assertEqual(sum("PATCH" in call.args for call in api.call_args_list), 1)
        self.assertEqual(sleep.call_count, 11)


if __name__ == "__main__":
    unittest.main()
