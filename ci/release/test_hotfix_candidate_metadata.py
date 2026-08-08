#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Tests for fail-closed post-release hotfix-candidate metadata."""

import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest


TOOLS = Path(__file__).resolve().parent
REPO = TOOLS.parents[1]
POLICY = REPO / "contrib" / "ops" / "v30.1.4-hotfix-candidate-package" / "policy.json"
MODULE_PATH = TOOLS / "generate_hotfix_candidate_metadata.py"
SPEC = importlib.util.spec_from_file_location("hotfix_candidate_metadata", MODULE_PATH)
METADATA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(METADATA)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


class HotfixCandidateMetadataTest(unittest.TestCase):
    adapter_sha = "a" * 40
    workflow_run_id = "123456"
    workflow_run_attempt = "2"

    def create_binary_tar(self, path, names=None):
        names = tuple(names or METADATA.EXPECTED_BINARIES)
        with tarfile.open(path, mode="w:gz", format=tarfile.PAX_FORMAT) as archive:
            for name in names:
                payload = f"fixture binary: {name}\n".encode("utf-8")
                member = tarfile.TarInfo(name)
                member.size = len(payload)
                member.mode = 0o755
                member.uid = 0
                member.gid = 0
                member.mtime = 1
                archive.addfile(member, io.BytesIO(payload))

    def create_oci_archive(self, path, labels):
        def encoded(value):
            return (json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")

        def digest(payload):
            return f"sha256:{hashlib.sha256(payload).hexdigest()}"

        layer = b"fixture uncompressed OCI layer\n"
        layer_digest = digest(layer)
        config = {
            "architecture": "amd64",
            "config": {
                "Cmd": None,
                "Entrypoint": ["/home/blackcoin/start-gui.sh"],
                "Healthcheck": None,
                "Labels": labels,
                "User": "blackcoin",
                "WorkingDir": "/home/blackcoin",
            },
            "os": "linux",
            "rootfs": {"diff_ids": [layer_digest], "type": "layers"},
        }
        config_payload = encoded(config)
        config_digest = digest(config_payload)
        manifest = {
            "config": {
                "digest": config_digest,
                "mediaType": METADATA.OCI_CONFIG_MEDIA_TYPE,
                "size": len(config_payload),
            },
            "layers": [
                {
                    "digest": layer_digest,
                    "mediaType": "application/vnd.oci.image.layer.v1.tar",
                    "size": len(layer),
                }
            ],
            "mediaType": METADATA.OCI_MANIFEST_MEDIA_TYPE,
            "schemaVersion": 2,
        }
        manifest_payload = encoded(manifest)
        manifest_digest = digest(manifest_payload)
        source = METADATA.EXPECTED_SOURCE_COMMIT
        reference = f"qqblackcoin/blackcoin-v4-gui:30.1.4-hotfix-candidate-{source[:12]}-ci1"
        index = {
            "manifests": [
                {
                    "annotations": {"org.opencontainers.image.ref.name": reference},
                    "digest": manifest_digest,
                    "mediaType": METADATA.OCI_MANIFEST_MEDIA_TYPE,
                    "size": len(manifest_payload),
                }
            ],
            "schemaVersion": 2,
        }
        files = {
            "oci-layout": encoded({"imageLayoutVersion": "1.0.0"}),
            "index.json": encoded(index),
            f"blobs/sha256/{manifest_digest.removeprefix('sha256:')}": manifest_payload,
            f"blobs/sha256/{config_digest.removeprefix('sha256:')}": config_payload,
            f"blobs/sha256/{layer_digest.removeprefix('sha256:')}": layer,
        }
        with tarfile.open(path, mode="w", format=tarfile.PAX_FORMAT) as archive:
            for name, payload in sorted(files.items()):
                member = tarfile.TarInfo(name)
                member.size = len(payload)
                member.mode = 0o644
                member.uid = 0
                member.gid = 0
                member.mtime = 1
                archive.addfile(member, io.BytesIO(payload))
        return manifest_digest, config_digest

    def create_fixture(self, root):
        policy = METADATA.validate_policy(POLICY)
        names = METADATA.artifact_names(policy)
        binary_tar = root / names["binary_tar"]
        self.create_binary_tar(binary_tar)
        binary_hashes = METADATA.inspect_binary_tar(binary_tar)
        (root / names["binary_sums"]).write_text(
            "".join(f"{digest}  {name}\n" for name, digest in binary_hashes.items()),
            encoding="utf-8",
        )
        (root / names["source_commit"]).write_text(
            f"{METADATA.EXPECTED_SOURCE_COMMIT}\n", encoding="utf-8"
        )
        artifact_hash = METADATA.sha256(binary_tar)
        (root / names["reproducibility"]).write_text(
            "\n".join(
                (
                    f"source_commit={METADATA.EXPECTED_SOURCE_COMMIT}",
                    "method=two-isolated-builds-byte-identical",
                    f"primary_artifact_sha256={artifact_hash}",
                    f"verifier_artifact_sha256={artifact_hash}",
                    "result=passed",
                    "",
                )
            ),
            encoding="utf-8",
        )
        (root / names["notice"]).write_text(
            "\n".join(
                (
                    "POST-RELEASE HOTFIX CANDIDATE - CANARY ONLY - NOT A RELEASE",
                    f"source_commit={METADATA.EXPECTED_SOURCE_COMMIT}",
                    "core_version_self_report=30.1.4",
                    "signed_source=true",
                    "artifact_platform_signed=false",
                    "tag=none",
                    "published=false",
                    "registry_pushed=false",
                    "",
                )
            ),
            encoding="utf-8",
        )
        signature = {
            "schema": 1,
            "commit": METADATA.EXPECTED_SOURCE_COMMIT,
            "repository": METADATA.EXPECTED_REPOSITORY,
            "signer": METADATA.EXPECTED_SIGNER,
            "format": "ssh",
            "fingerprint": METADATA.EXPECTED_FINGERPRINT,
            "local_git_verified": True,
            "github_verified": True,
            "github_verification_reason": "valid",
            "workflow_actor": METADATA.EXPECTED_ACTOR,
            "workflow_triggering_actor": METADATA.EXPECTED_ACTOR,
        }
        write_json(root / names["source_signature"], signature)
        core_ci = {
            "schema": 1,
            "workflow_path": METADATA.EXPECTED_WORKFLOW_PATH,
            "workflow_name": METADATA.EXPECTED_WORKFLOW_NAME,
            "workflow_blob_sha256": METADATA.EXPECTED_WORKFLOW_BLOB_SHA256,
            "event": METADATA.EXPECTED_CORE_CI_EVENT,
            "repository": METADATA.EXPECTED_REPOSITORY,
            "head_repository": METADATA.EXPECTED_REPOSITORY,
            "pull_request_number": METADATA.EXPECTED_CORE_CI_PR,
            "pull_request_head_sha": METADATA.EXPECTED_SOURCE_COMMIT,
            "pull_request_base_sha": METADATA.EXPECTED_CORE_CI_BASE,
            "run_id": 987654,
            "head_sha": METADATA.EXPECTED_SOURCE_COMMIT,
            "status": "completed",
            "conclusion": "success",
        }
        write_json(root / names["core_ci"], core_ci)
        (root / names["toolchain"]).write_text(
            "\n".join(
                (
                    f"source_commit={METADATA.EXPECTED_SOURCE_COMMIT}",
                    f"workflow_run_id={self.workflow_run_id}",
                    f"workflow_run_attempt={self.workflow_run_attempt}",
                    "runner_image=ubuntu-22.04",
                    "host=x86_64-pc-linux-gnu",
                    "build_matrix=primary,verifier",
                    "depends_cache_reused=false",
                    "compiler=g++ fixture",
                    "binutils=GNU ld fixture",
                    "make=GNU Make fixture",
                    "packages=automake=fixture,libtool=fixture",
                    f"depends_tracked_source_tree_sha256={'1' * 64}",
                    "",
                )
            ),
            encoding="utf-8",
        )
        archive = root / names["oci_archive"]
        source = METADATA.EXPECTED_SOURCE_COMMIT
        labels = METADATA.expected_candidate_labels(
            policy,
            binary_hashes,
            METADATA.sha256(binary_tar),
            METADATA.sha256(root / names["binary_sums"]),
        )
        manifest_digest, config_digest = self.create_oci_archive(archive, labels)
        identity = {
            "schema": 1,
            "classification": METADATA.EXPECTED_CLASSIFICATION,
            "source_commit": source,
            "image_reference": f"qqblackcoin/blackcoin-v4-gui:30.1.4-hotfix-candidate-{source[:12]}-ci1",
            "archive_name": archive.name,
            "archive_sha256": METADATA.sha256(archive),
            "image_manifest_digest": manifest_digest,
            "image_config_digest": config_digest,
            "base_reference": METADATA.EXPECTED_BASE_REFERENCE,
            "base_manifest_digest": METADATA.EXPECTED_BASE_MANIFEST,
            "base_config_digest": METADATA.EXPECTED_BASE_CONFIG,
            "os": "linux",
            "architecture": "amd64",
            "user": "blackcoin",
            "entrypoint": ["/home/blackcoin/start-gui.sh"],
            "cmd": None,
            "working_dir": "/home/blackcoin",
            "healthcheck": None,
            "rootfs_base_prefix_exact": True,
            "candidate_added_rootfs_layers": 1,
            "oci_roundtrip_verified": True,
            "published": False,
            "registry_pushed": False,
            "labels": labels,
            "binaries": binary_hashes,
        }
        write_json(root / names["oci_identity"], identity)
        return policy, names

    def generate_and_seal(self, root):
        policy, names = self.create_fixture(root)
        manifest_path = root / names["manifest"]
        provenance_path = root / names["provenance"]
        METADATA.generate(
            POLICY,
            root,
            self.adapter_sha,
            self.workflow_run_id,
            self.workflow_run_attempt,
            manifest_path,
            provenance_path,
        )
        checksum_path = root / names["checksums"]
        lines = []
        for path in sorted(root.iterdir(), key=lambda entry: entry.name):
            if path != checksum_path:
                lines.append(f"{METADATA.sha256(path)}  {path.name}")
        checksum_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return policy, names

    def reseal_checksums(self, root, names):
        checksum_path = root / names["checksums"]
        lines = []
        for path in sorted(root.iterdir(), key=lambda entry: entry.name):
            if path != checksum_path:
                lines.append(f"{METADATA.sha256(path)}  {path.name}")
        checksum_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def test_generate_and_verify_exact_candidate_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, names = self.generate_and_seal(root)
            manifest = METADATA.verify(POLICY, root)
            self.assertEqual(manifest["source"]["commit"], METADATA.EXPECTED_SOURCE_COMMIT)
            self.assertEqual(manifest["build"]["tooling_commit"], self.adapter_sha)
            self.assertEqual(manifest["build"]["workflow_definition_commit"], self.adapter_sha)
            self.assertEqual(manifest["build"]["workflow_run_id"], int(self.workflow_run_id))
            self.assertEqual(
                manifest["build"]["workflow_run_attempt"],
                int(self.workflow_run_attempt),
            )
            self.assertIsNone(manifest["release"]["tag"])
            self.assertFalse(manifest["release"]["published"])
            self.assertFalse(manifest["release"]["registry_pushed"])
            provenance = json.loads((root / names["provenance"]).read_text(encoding="utf-8"))
            manifest_subject = next(item for item in provenance["subject"] if item["name"] == names["manifest"])
            self.assertEqual(manifest_subject["digest"]["sha256"], METADATA.sha256(root / names["manifest"]))
            internal = provenance["predicate"]["buildDefinition"]["internalParameters"]
            self.assertEqual(internal["workflowRunAttempt"], int(self.workflow_run_attempt))
            self.assertEqual(
                provenance["predicate"]["runDetails"]["metadata"]["invocationId"],
                f"https://github.com/{METADATA.EXPECTED_REPOSITORY}/actions/runs/"
                f"{self.workflow_run_id}/attempts/{self.workflow_run_attempt}",
            )

    def test_json_inputs_reject_duplicate_keys_at_any_depth(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "policy.json"
            text = POLICY.read_text(encoding="utf-8")
            path.write_text(
                text.replace('"schema": 1,', '"schema": 1,\n  "schema": 1,', 1),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(RuntimeError, "duplicate JSON key: schema"):
                METADATA.validate_policy(path)

        validators = {
            "source_signature": METADATA.validate_source_signature,
            "core_ci": METADATA.validate_core_ci,
        }
        for kind, validator in validators.items():
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                policy, names = self.create_fixture(root)
                path = root / names[kind]
                text = path.read_text(encoding="utf-8")
                path.write_text(
                    text.replace('"schema": 1,', '"schema": 1,\n  "schema": 1,', 1),
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(RuntimeError, "duplicate JSON key: schema"):
                    validator(path, policy)

    def test_sealed_manifest_and_provenance_reject_duplicate_keys(self):
        cases = {
            "manifest": '  "schema": 1,\n',
            "provenance": '  "_type": "https://in-toto.io/Statement/v1",\n',
        }
        for kind, duplicate_line in cases.items():
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                _, names = self.generate_and_seal(root)
                path = root / names[kind]
                text = path.read_text(encoding="utf-8")
                self.assertTrue(text.startswith("{\n"))
                path.write_text("{\n" + duplicate_line + text[2:], encoding="utf-8")
                self.reseal_checksums(root, names)
                with self.assertRaisesRegex(RuntimeError, "duplicate JSON key"):
                    METADATA.verify(POLICY, root)

    def test_sealed_manifest_and_provenance_require_canonical_bytes(self):
        for kind in ("manifest", "provenance"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                _, names = self.generate_and_seal(root)
                path = root / names[kind]
                value = json.loads(path.read_text(encoding="utf-8"))
                path.write_text(
                    json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n",
                    encoding="utf-8",
                )
                self.reseal_checksums(root, names)
                with self.assertRaisesRegex(RuntimeError, "canonical JSON serialization"):
                    METADATA.verify(POLICY, root)

    def test_toolchain_attempt_must_match_metadata_attempt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy, names = self.create_fixture(root)
            path = root / names["toolchain"]
            text = path.read_text(encoding="utf-8")
            expected = f"workflow_run_attempt={self.workflow_run_attempt}"
            self.assertEqual(text.count(expected), 1)
            path.write_text(
                text.replace(expected, "workflow_run_attempt=99"),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(RuntimeError, "unexpected fixed value"):
                METADATA.validate_toolchain(
                    path,
                    policy,
                    self.workflow_run_id,
                    self.workflow_run_attempt,
                )

    def test_policy_rejects_candidate_source_substitution(self):
        with tempfile.TemporaryDirectory() as temporary:
            policy = json.loads(POLICY.read_text(encoding="utf-8"))
            policy["source"]["commit"] = "0" * 40
            path = Path(temporary) / "policy.json"
            write_json(path, policy)
            with self.assertRaisesRegex(RuntimeError, "approved candidate source changed"):
                METADATA.validate_policy(path)

    def test_policy_rejects_core_ci_identity_substitution(self):
        substitutions = {
            "event": "workflow_dispatch",
            "pull_request_number": METADATA.EXPECTED_CORE_CI_PR + 1,
            "head_sha": "0" * 40,
            "base_sha": "0" * 40,
            "repository": "substituted/Blackcoin",
            "head_repository": "substituted/Blackcoin",
            "workflow_blob_sha256": "0" * 64,
        }
        for field, replacement in substitutions.items():
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                policy = json.loads(POLICY.read_text(encoding="utf-8"))
                policy["core_ci"][field] = replacement
                path = Path(temporary) / "policy.json"
                write_json(path, policy)
                with self.assertRaisesRegex(RuntimeError, "Core CI"):
                    METADATA.validate_policy(path)

    def test_binary_archive_requires_gui_daemon_cli_and_all_six_tools(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "candidate.tar.gz"
            self.create_binary_tar(
                path,
                names=tuple(name for name in METADATA.EXPECTED_BINARIES if name != "blackcoin-qt"),
            )
            with self.assertRaisesRegex(RuntimeError, "binary archive inventory"):
                METADATA.inspect_binary_tar(path)

    def test_source_signature_must_match_pinned_blackcoin_dev_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy, names = self.create_fixture(root)
            path = root / names["source_signature"]
            value = json.loads(path.read_text(encoding="utf-8"))
            value["fingerprint"] = "SHA256:substitution"
            write_json(path, value)
            with self.assertRaisesRegex(RuntimeError, "signature fingerprint changed"):
                METADATA.validate_source_signature(path, policy)

    def test_source_signature_requires_original_and_triggering_blackcoin_dev_actors(self):
        for field in ("workflow_actor", "workflow_triggering_actor"):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                policy, names = self.create_fixture(root)
                path = root / names["source_signature"]
                value = json.loads(path.read_text(encoding="utf-8"))
                value[field] = "substituted-actor"
                write_json(path, value)
                with self.assertRaisesRegex(RuntimeError, "workflow .*actor changed"):
                    METADATA.validate_source_signature(path, policy)

    def test_core_ci_requires_exact_pr_event_repositories_head_base_and_workflow(self):
        substitutions = {
            "event": "workflow_dispatch",
            "repository": "substituted/Blackcoin",
            "head_repository": "substituted/Blackcoin",
            "pull_request_number": METADATA.EXPECTED_CORE_CI_PR + 1,
            "pull_request_head_sha": "0" * 40,
            "pull_request_base_sha": "0" * 40,
            "workflow_blob_sha256": "0" * 64,
        }
        for field, replacement in substitutions.items():
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                policy, names = self.create_fixture(root)
                path = root / names["core_ci"]
                value = json.loads(path.read_text(encoding="utf-8"))
                value[field] = replacement
                write_json(path, value)
                with self.assertRaisesRegex(RuntimeError, "Core CI"):
                    METADATA.validate_core_ci(path, policy)

    def validate_fixture_text(self, root, policy, names, kind):
        if kind == "toolchain":
            return METADATA.validate_toolchain(
                root / names["toolchain"],
                policy,
                self.workflow_run_id,
                self.workflow_run_attempt,
            )
        return METADATA.validate_text_evidence(root, names, policy)

    def test_text_evidence_rejects_duplicate_contradictory_keys(self):
        cases = {
            "notice": ("published=false", "published=true"),
            "reproducibility": ("result=passed", "result=failed"),
            "toolchain": ("depends_cache_reused=false", "depends_cache_reused=true"),
        }
        for kind, (_, contradictory) in cases.items():
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                policy, names = self.create_fixture(root)
                path = root / names[kind]
                path.write_text(path.read_text(encoding="utf-8") + f"{contradictory}\n", encoding="utf-8")
                with self.assertRaisesRegex(RuntimeError, "duplicate key"):
                    self.validate_fixture_text(root, policy, names, kind)

    def test_text_evidence_rejects_unknown_keys(self):
        for kind in ("notice", "reproducibility", "toolchain"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                policy, names = self.create_fixture(root)
                path = root / names[kind]
                path.write_text(path.read_text(encoding="utf-8") + "unknown_key=true\n", encoding="utf-8")
                with self.assertRaisesRegex(RuntimeError, "key inventory or order changed"):
                    self.validate_fixture_text(root, policy, names, kind)

    def test_text_evidence_rejects_missing_keys(self):
        cases = {
            "notice": "registry_pushed=false",
            "reproducibility": "result=passed",
            "toolchain": "depends_tracked_source_tree_sha256=",
        }
        for kind, prefix in cases.items():
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                policy, names = self.create_fixture(root)
                path = root / names[kind]
                lines = [
                    line for line in path.read_text(encoding="utf-8").splitlines()
                    if not line.startswith(prefix)
                ]
                path.write_text("\n".join(lines) + "\n", encoding="utf-8")
                with self.assertRaisesRegex(RuntimeError, "key inventory or order changed"):
                    self.validate_fixture_text(root, policy, names, kind)

    def test_text_evidence_rejects_single_value_contradictions(self):
        cases = {
            "notice": ("published=false", "published=true"),
            "reproducibility": ("result=passed", "result=failed"),
            "toolchain": ("runner_image=ubuntu-22.04", "runner_image=ubuntu-latest"),
        }
        for kind, (expected, replacement) in cases.items():
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                policy, names = self.create_fixture(root)
                path = root / names[kind]
                text = path.read_text(encoding="utf-8")
                self.assertEqual(text.count(expected), 1)
                path.write_text(text.replace(expected, replacement), encoding="utf-8")
                with self.assertRaises(RuntimeError):
                    self.validate_fixture_text(root, policy, names, kind)

    def test_oci_archive_hash_and_base_identity_are_mandatory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, names = self.create_fixture(root)
            (root / names["oci_archive"]).write_bytes(b"changed archive\n")
            with self.assertRaisesRegex(RuntimeError, "OCI archive hash does not match"):
                METADATA.generate(
                    POLICY,
                    root,
                    self.adapter_sha,
                    self.workflow_run_id,
                    self.workflow_run_attempt,
                    root / names["manifest"],
                    root / names["provenance"],
                )

    def test_oci_archive_internal_layout_and_digest_links_are_mandatory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, names = self.create_fixture(root)
            archive = root / names["oci_archive"]
            archive.write_bytes(b"not an OCI layout archive\n")
            identity_path = root / names["oci_identity"]
            identity = json.loads(identity_path.read_text(encoding="utf-8"))
            identity["archive_sha256"] = METADATA.sha256(archive)
            write_json(identity_path, identity)
            with self.assertRaisesRegex(RuntimeError, "cannot inspect OCI archive"):
                METADATA.generate(
                    POLICY,
                    root,
                    self.adapter_sha,
                    self.workflow_run_id,
                    self.workflow_run_attempt,
                    root / names["manifest"],
                    root / names["provenance"],
                )

    def test_exact_bundle_checksum_rejects_post_seal_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, names = self.generate_and_seal(root)
            with (root / names["notice"]).open("a", encoding="utf-8") as notice:
                notice.write("mutation=true\n")
            with self.assertRaisesRegex(RuntimeError, "bundle checksum mismatch"):
                METADATA.verify(POLICY, root)


if __name__ == "__main__":
    unittest.main()
