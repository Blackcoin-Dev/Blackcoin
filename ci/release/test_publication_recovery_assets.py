#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Offline regressions for the frozen publication-only recovery verifier."""

from copy import deepcopy
import hashlib
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile

import verify_publication_recovery_assets as assets


class PublicationRecoveryAssetsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.manifest = json.loads(assets.MANIFEST.read_text(encoding="utf-8"))
        self.dist = self.root / "dist"
        self.dist.mkdir()
        for name in assets.release_names(self.manifest) - {"SHA256SUMS.txt"}:
            (self.dist / name).write_text(name + "\n", encoding="utf-8")
        self.expected = {path.name: assets.sha256(path) for path in self.dist.iterdir()}
        self.checksums = "".join(f"{digest}  {name}\n" for name, digest in sorted(self.expected.items()))
        (self.dist / "SHA256SUMS.txt").write_text(self.checksums, encoding="utf-8")
        self.notes = self.root / "notes.md"
        self.notes.write_text("Exact source-signed release notes.\n", encoding="utf-8")

    def attestation(self, predicate_type):
        statement = {
            "_type": "https://in-toto.io/Statement/v1", "predicateType": predicate_type,
            "subject": [{"name": name, "digest": {"sha256": digest}} for name, digest in self.expected.items()],
            "predicate": {},
        }
        if predicate_type == assets.SLSA:
            statement["predicate"] = {"runDetails": {"metadata": {"invocationId":
                "https://github.com/Blackcoin-Dev/Blackcoin/actions/runs/34564576294/attempts/2"}}}
        return [{"verificationResult": {"statement": statement}}]

    def release(self, phase):
        return {
            "tag_name": "v30.1.5", "name": "Blackcoin Core v30.1.5",
            "body": self.notes.read_text(encoding="utf-8"),
            "target_commitish": self.manifest["source_sha"],
            "draft": phase == "draft", "prerelease": False, "immutable": phase == "published",
            "assets": [{"name": path.name, "size": path.stat().st_size,
                        "digest": f"sha256:{assets.sha256(path)}", "state": "uploaded"}
                       for path in self.dist.iterdir()],
        }

    @staticmethod
    def archive(entries):
        stream = io.BytesIO()
        with warnings.catch_warnings(), zipfile.ZipFile(stream, "w") as archive:
            warnings.simplefilter("ignore", UserWarning)
            for name, value in entries:
                archive.writestr(name, value)
        return stream.getvalue()

    def test_exact_dist_and_both_verified_attestations(self):
        self.assertEqual(len(assets.dist_inventory(self.manifest, self.dist)), 20)
        paths = []
        for predicate_type, name in ((assets.SLSA, "slsa.json"), (assets.SPDX, "spdx.json")):
            path = self.root / name
            path.write_text(json.dumps(self.attestation(predicate_type)), encoding="utf-8")
            paths.append(path)
        self.assertEqual(assets.verify(self.manifest, self.dist, *paths),
                         {"verified_subjects": 19, "release_files": 20})

    def test_checksum_corruption_duplicates_and_inventory_changes_fail(self):
        checksum = self.dist / "SHA256SUMS.txt"
        for text in (self.checksums + self.checksums.splitlines()[0] + "\n",
                     self.checksums.replace("  ", " ", 1),
                     self.checksums[65:], self.checksums.replace(next(iter(self.expected.values())), "0" * 64)):
            with self.subTest(text=text[:70]):
                checksum.write_text(text, encoding="utf-8")
                with self.assertRaises(ValueError):
                    assets.dist_inventory(self.manifest, self.dist)
        checksum.write_text(self.checksums, encoding="utf-8")
        extra = self.dist / "unexpected"
        extra.write_text("extra", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "inventory"):
            assets.dist_inventory(self.manifest, self.dist)
        extra.unlink()
        subject = self.dist / next(iter(self.expected))
        subject.write_text("corrupted", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "checksums"):
            assets.dist_inventory(self.manifest, self.dist)

    def test_symlink_subject_is_refused(self):
        subject = self.dist / next(iter(self.expected))
        subject.unlink()
        subject.symlink_to(self.notes)
        with self.assertRaisesRegex(ValueError, "regular files"):
            assets.dist_inventory(self.manifest, self.dist)

    def test_attestation_duplicates_wrong_subjects_and_wrong_run_fail(self):
        for fault in ("duplicate", "missing", "digest", "unverified", "predicate", "run"):
            with self.subTest(fault=fault):
                data = self.attestation(assets.SLSA)
                statement = data[0]["verificationResult"]["statement"]
                if fault == "duplicate":
                    statement["subject"].append(deepcopy(statement["subject"][0]))
                elif fault == "missing":
                    statement["subject"].pop()
                elif fault == "digest":
                    statement["subject"][0]["digest"]["sha256"] = "0" * 64
                elif fault == "unverified":
                    data = [{"statement": statement}]
                elif fault == "predicate":
                    statement["predicateType"] = assets.SPDX
                else:
                    statement["predicate"]["runDetails"]["metadata"]["invocationId"] += "0"
                with self.assertRaises(ValueError):
                    assets.verify_attestation(self.manifest, data, self.expected, assets.SLSA)
        unrelated = self.attestation(assets.SLSA)
        unrelated[0]["verificationResult"]["statement"]["predicate"]["runDetails"]["metadata"]["invocationId"] += "0"
        assets.verify_attestation(self.manifest, unrelated + self.attestation(assets.SLSA), self.expected, assets.SLSA)

    def test_draft_and_immutable_published_metadata(self):
        for phase in ("draft", "published"):
            result = assets.verify_release(self.manifest, self.dist, self.notes, self.release(phase), phase)
            self.assertEqual(result, {"verified_assets": 20, "phase": phase})

    def test_release_metadata_asset_duplicates_and_identity_drift_fail(self):
        for fault in ("tag_name", "name", "body", "target_commitish", "draft", "prerelease",
                      "immutable", "duplicate", "size", "digest", "state"):
            with self.subTest(fault=fault):
                release = self.release("published")
                if fault in ("draft", "prerelease", "immutable"):
                    release[fault] = not release[fault]
                elif fault == "duplicate":
                    release["assets"][1] = deepcopy(release["assets"][0])
                elif fault == "size":
                    release["assets"][0]["size"] += 1
                elif fault in ("digest", "state"):
                    release["assets"][0][fault] = "invalid"
                else:
                    release[fault] += "changed"
                with self.assertRaises(ValueError):
                    assets.verify_release(self.manifest, self.dist, self.notes, release, "published")

    def test_archive_traversal_symlinks_and_duplicates_fail_before_extraction(self):
        symlink = zipfile.ZipInfo("safe")
        symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
        for entries in ([('../escape', b'x')], [('/absolute', b'x')], [('a\\b', b'x')],
                        [('nested/file', b'x')], [('safe/', b'')], [(symlink, b'target')],
                        [('safe', b'x'), ('safe', b'y')]):
            with self.subTest(entries=str(entries)):
                archive = self.root / "unsafe.zip"
                archive.write_bytes(self.archive(entries))
                destination = self.root / "extracted"
                with self.assertRaises(ValueError):
                    assets.extract_archive(archive, destination, {"safe"})
                self.assertFalse(destination.exists())

    def test_download_uses_only_six_pinned_ids_and_verifies_archive_identity(self):
        manifest = deepcopy(self.manifest)
        archives = {}
        groups = assets.artifact_files(manifest)
        for item in manifest["artifacts"]:
            payload = self.archive([(name, name.encode()) for name in sorted(groups[item["name"]])])
            archives[item["id"]] = payload
            item["size_in_bytes"] = len(payload)
            item["digest"] = "sha256:" + hashlib.sha256(payload).hexdigest()

        def fake_gh(command, *, stdout, check):
            self.assertEqual(command[:2], ["gh", "api"])
            self.assertEqual(command[2].split("/")[:5], ["repos", "Blackcoin-Dev", "Blackcoin", "actions", "artifacts"])
            self.assertEqual(command[2].split("/")[-1], "zip")
            self.assertIs(check, True)
            stdout.write(archives[int(command[2].split("/")[-2])])

        with mock.patch.object(assets.subprocess, "run", side_effect=fake_gh) as runner:
            output = self.root / "download"
            result = assets.download(manifest, output)
            self.assertEqual(runner.call_count, 6)
            self.assertEqual(len(result["primary_dirs"]), 5)
            self.assertEqual({path.name for path in output.iterdir()}, set(groups))
            for name, expected in groups.items():
                self.assertEqual({path.name for path in (output / name).iterdir()}, expected)
            for field, invalid in (("size_in_bytes", 1), ("digest", "sha256:" + "0" * 64)):
                changed = deepcopy(manifest)
                changed["artifacts"][0][field] = invalid
                with self.assertRaisesRegex(ValueError, "archive .* differs"):
                    assets.download(changed, self.root / field)

    def test_manifest_duplicate_and_extra_artifacts_are_refused(self):
        for fault in ("duplicate_id", "duplicate_name", "extra"):
            manifest = deepcopy(self.manifest)
            if fault == "extra":
                manifest["artifacts"].append(deepcopy(manifest["artifacts"][0]))
            else:
                key = "id" if fault == "duplicate_id" else "name"
                manifest["artifacts"][1][key] = manifest["artifacts"][0][key]
            with self.assertRaises(ValueError):
                assets.validate_manifest(manifest)


if __name__ == "__main__":
    unittest.main()
