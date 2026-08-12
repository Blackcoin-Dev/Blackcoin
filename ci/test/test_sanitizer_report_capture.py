#!/usr/bin/env python3
"""Hostile tests for fail-closed sanitizer report collection and extraction."""

import contextlib
import importlib.util
import io
import os
import stat
import subprocess
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
EXTRACTOR = ROOT / "ci" / "test" / "extract_sanitizer_reports.py"
EMITTER = ROOT / "ci" / "test" / "emit_sanitizer_reports.py"
WORKFLOW = ROOT / ".github" / "workflows" / "pr-gate.yml"
DRIVER = ROOT / "ci" / "test" / "06_script_b.sh"
TARGET_SHA = "1" * 40


def load_script(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


EMITTER_MODULE = load_script("blackcoin_sanitizer_emitter", EMITTER)
EXTRACTOR_MODULE = load_script("blackcoin_sanitizer_extractor", EXTRACTOR)


class SanitizerReportCaptureTests(unittest.TestCase):
    def run_extractor(self, stream: bytes, output: Path) -> subprocess.CompletedProcess:
        return subprocess.run(
            [
                "python3",
                str(EXTRACTOR),
                "--output",
                str(output),
                "--target-sha",
                TARGET_SHA,
                "--sanitizer",
                "thread-sanitizer",
            ],
            input=stream,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def run_emitter(
        self, scratch: Path, source_status: int = 0, prepare: bool = False
    ) -> subprocess.CompletedProcess:
        environment = os.environ.copy()
        environment["BASE_SCRATCH_DIR"] = str(scratch)
        argument = "--prepare" if prepare else str(source_status)
        return subprocess.run(
            ["python3", str(EMITTER), argument],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def run_extractor_in_process(
        self,
        stream: bytes,
        output: Path,
        report_limit: int,
        total_limit: int,
    ) -> int:
        stdin = types.SimpleNamespace(buffer=io.BytesIO(stream))
        stdout = types.SimpleNamespace(buffer=io.BytesIO())
        stderr = io.StringIO()
        arguments = [
            str(EXTRACTOR),
            "--output",
            str(output),
            "--target-sha",
            TARGET_SHA,
            "--sanitizer",
            "thread-sanitizer",
        ]
        with contextlib.ExitStack() as stack:
            stack.enter_context(
                mock.patch.object(
                    EXTRACTOR_MODULE, "MAX_REPORT_BYTES", report_limit
                )
            )
            stack.enter_context(
                mock.patch.object(
                    EXTRACTOR_MODULE, "MAX_TOTAL_REPORT_BYTES", total_limit
                )
            )
            stack.enter_context(
                mock.patch.object(EXTRACTOR_MODULE.sys, "argv", arguments)
            )
            stack.enter_context(
                mock.patch.object(EXTRACTOR_MODULE.sys, "stdin", stdin)
            )
            stack.enter_context(
                mock.patch.object(EXTRACTOR_MODULE.sys, "stdout", stdout)
            )
            stack.enter_context(
                mock.patch.object(EXTRACTOR_MODULE.sys, "stderr", stderr)
            )
            return EXTRACTOR_MODULE.main()

    def test_zero_reports_excludes_ordinary_output(self):
        ordinary = b"HOME=/root\nordinary-build-output\n"
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "reports.log"
            result = self.run_extractor(ordinary, output)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(result.stdout, ordinary)
            artifact = output.read_text(encoding="utf-8")
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertIn(f"target_sha={TARGET_SHA}\n", artifact)
            self.assertIn("sanitizer=thread-sanitizer\n", artifact)
            self.assertIn("report_count=0\n", artifact)
            self.assertIn("framing_error_count=0\n", artifact)
            self.assertIn("capture_complete=1\n", artifact)
            self.assertNotIn("HOME=/root", artifact)
            self.assertNotIn("ordinary-build-output", artifact)

    def test_complete_reports_and_payload_markers_are_preserved(self):
        stream = (
            b"ordinary-before\n"
            b"@@BLACKCOIN_SANITIZER_REPORT_BEGIN@@ tsan.11\n"
            b"@@BLACKCOIN_SANITIZER_REPORT_DATA@@ tsan.11\tfirst stack\n"
            b"@@BLACKCOIN_SANITIZER_REPORT_DATA@@ tsan.11\t"
            b"@@BLACKCOIN_SANITIZER_REPORT_BEGIN@@ forged payload\n"
            b"@@BLACKCOIN_SANITIZER_REPORT_END@@ tsan.11\n"
            b"@@BLACKCOIN_SANITIZER_REPORT_BEGIN@@ tsan.12\n"
            b"@@BLACKCOIN_SANITIZER_REPORT_DATA@@ tsan.12\tsecond stack\n"
            b"@@BLACKCOIN_SANITIZER_REPORT_END@@ tsan.12"
        )
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "reports.log"
            result = self.run_extractor(stream, output)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertIn(b"ordinary-before\n", result.stdout)
            self.assertIn(b"first stack\n", result.stdout)
            artifact = output.read_text(encoding="utf-8")
            self.assertIn("first stack\n", artifact)
            self.assertIn(
                "@@BLACKCOIN_SANITIZER_REPORT_BEGIN@@ forged payload\n",
                artifact,
            )
            self.assertIn("second stack\n", artifact)
            self.assertIn("report_count=2\n", artifact)
            self.assertIn("framing_error_count=0\n", artifact)
            self.assertNotIn("ordinary-before", artifact)

    def test_malformed_framing_fails_closed_without_capturing_ordinary_output(self):
        cases = {
            "nested": (
                b"@@BLACKCOIN_SANITIZER_REPORT_BEGIN@@ tsan.1\n"
                b"@@BLACKCOIN_SANITIZER_REPORT_BEGIN@@ tsan.2\n"
                b"@@BLACKCOIN_SANITIZER_REPORT_END@@ tsan.1\n"
            ),
            "orphan-end": b"@@BLACKCOIN_SANITIZER_REPORT_END@@ tsan.1\n",
            "mismatched-end": (
                b"@@BLACKCOIN_SANITIZER_REPORT_BEGIN@@ tsan.1\n"
                b"@@BLACKCOIN_SANITIZER_REPORT_END@@ tsan.2\n"
            ),
            "incomplete": b"@@BLACKCOIN_SANITIZER_REPORT_BEGIN@@ tsan.1\n",
            "invalid-name": b"@@BLACKCOIN_SANITIZER_REPORT_BEGIN@@ ../secret\n",
            "collector-error": (
                b"@@BLACKCOIN_SANITIZER_COLLECTOR_ERROR@@ report-read-failed\n"
            ),
            "unknown-record": b"@@BLACKCOIN_SANITIZER_UNKNOWN@@ value\n",
        }
        for name, framing in cases.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "reports.log"
                ordinary = b"ordinary-after\n"
                result = self.run_extractor(framing + ordinary, output)
                self.assertEqual(result.returncode, 74)
                self.assertIn(ordinary, result.stdout)
                artifact = output.read_text(encoding="utf-8")
                self.assertIn("framing_error_count=", artifact)
                self.assertNotIn("ordinary-after", artifact)

    def test_unwritable_output_fails_after_consuming_input(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            ordinary = b"ordinary-output\n"
            result = self.run_extractor(ordinary, output)
            self.assertEqual(result.returncode, 75)
            self.assertEqual(result.stdout, ordinary)

    def test_stale_output_cannot_be_reused_after_finalization_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            output = parent / "reports.log"
            stale = b"STALE_CAPTURE\ncapture_complete=1\n"
            output.write_bytes(stale)
            parent.chmod(0o500)
            try:
                result = self.run_extractor(b"ordinary-output\n", output)
            finally:
                parent.chmod(0o700)
            self.assertEqual(result.returncode, 75)
            self.assertEqual(result.stdout, b"ordinary-output\n")
            self.assertEqual(output.read_bytes(), stale)

    def test_unsafe_existing_output_is_never_replaced_or_followed(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            target = parent / "target"
            target.write_text("target-unchanged\n", encoding="utf-8")
            output = parent / "reports.log"
            output.symlink_to(target)
            result = self.run_extractor(b"ordinary-output\n", output)
            self.assertEqual(result.returncode, 75)
            self.assertTrue(output.is_symlink())
            self.assertEqual(target.read_text(encoding="utf-8"), "target-unchanged\n")

    def test_emitter_frames_only_regular_tsan_pid_files(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            reports = scratch / "sanitizer-output"
            reports.mkdir(mode=0o700)
            (reports / "tsan.123").write_bytes(b"line one\nline two")
            environment = os.environ.copy()
            environment["BASE_SCRATCH_DIR"] = str(scratch)
            emitted = subprocess.run(
                ["python3", str(EMITTER), "0"],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(emitted.returncode, 66, emitted.stderr.decode())
            self.assertIn(
                b"@@BLACKCOIN_SANITIZER_REPORT_BEGIN@@ tsan.123\n",
                emitted.stdout,
            )
            self.assertIn(
                b"@@BLACKCOIN_SANITIZER_REPORT_DATA@@ tsan.123\tline two\n",
                emitted.stdout,
            )
            with tempfile.TemporaryDirectory() as output_directory:
                output = Path(output_directory) / "reports.log"
                extracted = self.run_extractor(emitted.stdout, output)
                self.assertEqual(extracted.returncode, 0, extracted.stderr.decode())
                self.assertIn("line one\nline two\n", output.read_text())

    def test_emitter_rejects_unexpected_entries_without_masking_source_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            reports = scratch / "sanitizer-output"
            reports.mkdir(mode=0o700)
            target = scratch / "outside"
            target.write_text("not a report", encoding="utf-8")
            (reports / "tsan.7").symlink_to(target)
            (reports / "unexpected").write_text("unexpected", encoding="utf-8")
            environment = os.environ.copy()
            environment["BASE_SCRATCH_DIR"] = str(scratch)

            clean_source = subprocess.run(
                ["python3", str(EMITTER), "0"],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(clean_source.returncode, 74)
            self.assertNotIn(b"not a report", clean_source.stdout)
            self.assertNotIn(b"unexpected\n", clean_source.stdout)

            failed_source = subprocess.run(
                ["python3", str(EMITTER), "66"],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(failed_source.returncode, 66)
            self.assertIn(
                b"@@BLACKCOIN_SANITIZER_COLLECTOR_ERROR@@",
                failed_source.stdout,
            )

    def test_emitter_rejects_missing_symlinked_and_empty_report_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            environment = os.environ.copy()
            environment["BASE_SCRATCH_DIR"] = str(scratch)

            missing = subprocess.run(
                ["python3", str(EMITTER), "0"],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn(b"COLLECTOR_ERROR", missing.stdout)

            outside = scratch / "outside"
            outside.mkdir(mode=0o700)
            (outside / "tsan.77").write_text("outside", encoding="utf-8")
            reports = scratch / "sanitizer-output"
            reports.symlink_to(outside, target_is_directory=True)
            symlinked = subprocess.run(
                ["python3", str(EMITTER), "0"],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertNotEqual(symlinked.returncode, 0)
            self.assertIn(b"COLLECTOR_ERROR", symlinked.stdout)
            self.assertNotIn(b"outside", symlinked.stdout)

            reports.unlink()
            reports.mkdir(mode=0o700)
            (reports / "tsan.88").write_bytes(b"")
            empty = subprocess.run(
                ["python3", str(EMITTER), "0"],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertNotEqual(empty.returncode, 0)
            self.assertIn(b"COLLECTOR_ERROR", empty.stdout)

            (reports / "tsan.88").unlink()
            target = scratch / "target"
            target.write_text("target", encoding="utf-8")
            (reports / "tsan.99").symlink_to(target)
            file_symlink = subprocess.run(
                ["python3", str(EMITTER), "0"],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertNotEqual(file_symlink.returncode, 0)
            self.assertIn(b"COLLECTOR_ERROR", file_symlink.stdout)
            self.assertNotIn(b"target\n", file_symlink.stdout)

    def test_emitter_rejects_scratch_symlink_hardlink_and_writable_report(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            real_scratch = root / "real-scratch"
            real_scratch.mkdir(mode=0o700)
            real_reports = real_scratch / "sanitizer-output"
            real_reports.mkdir(mode=0o700)
            (real_reports / "tsan.1").write_text("symlink payload", encoding="utf-8")
            scratch_link = root / "scratch-link"
            scratch_link.symlink_to(real_scratch, target_is_directory=True)
            environment = os.environ.copy()
            environment["BASE_SCRATCH_DIR"] = str(scratch_link)
            symlinked = subprocess.run(
                ["python3", str(EMITTER), "0"],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertNotEqual(symlinked.returncode, 0)
            self.assertIn(b"COLLECTOR_ERROR", symlinked.stdout)
            self.assertNotIn(b"symlink payload", symlinked.stdout)

            scratch = root / "scratch"
            scratch.mkdir(mode=0o700)
            reports = scratch / "sanitizer-output"
            reports.mkdir(mode=0o700)
            outside = scratch / "outside"
            outside.write_text("hardlink payload", encoding="utf-8")
            os.link(outside, reports / "tsan.2")
            environment["BASE_SCRATCH_DIR"] = str(scratch)
            hardlink = subprocess.run(
                ["python3", str(EMITTER), "0"],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertNotEqual(hardlink.returncode, 0)
            self.assertIn(b"COLLECTOR_ERROR", hardlink.stdout)
            self.assertNotIn(b"hardlink payload", hardlink.stdout)

            (reports / "tsan.2").unlink()
            writable = reports / "tsan.3"
            writable.write_text("writable payload", encoding="utf-8")
            writable.chmod(0o666)
            unsafe_mode = subprocess.run(
                ["python3", str(EMITTER), "0"],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertNotEqual(unsafe_mode.returncode, 0)
            self.assertIn(b"COLLECTOR_ERROR", unsafe_mode.stdout)
            self.assertNotIn(b"writable payload", unsafe_mode.stdout)

    def test_emitter_preserves_source_status_when_a_report_exists(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            reports = scratch / "sanitizer-output"
            reports.mkdir(mode=0o700)
            (reports / "tsan.4").write_text("real race\n", encoding="utf-8")
            emitted = self.run_emitter(scratch, source_status=23)
            self.assertEqual(emitted.returncode, 23)
            self.assertIn(b"real race", emitted.stdout)

    def test_prepare_clears_only_verified_report_files_without_traversal(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            reports = scratch / "sanitizer-output"
            reports.mkdir(mode=0o700)
            (reports / "tsan.1").write_text("stale", encoding="utf-8")
            prepared = self.run_emitter(scratch, prepare=True)
            self.assertEqual(prepared.returncode, 0, prepared.stdout.decode())
            self.assertEqual(list(reports.iterdir()), [])
            self.assertEqual(reports.stat().st_mode & 0o777, 0o700)

            nested = reports / "nested"
            nested.mkdir()
            (nested / "do-not-delete").write_text("sentinel", encoding="utf-8")
            rejected = self.run_emitter(scratch, prepare=True)
            self.assertEqual(rejected.returncode, 74)
            self.assertIn(b"unsafe-preexisting-report-entry", rejected.stdout)
            self.assertEqual(
                (nested / "do-not-delete").read_text(encoding="utf-8"),
                "sentinel",
            )

    def test_prepare_rejects_report_directory_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            outside = scratch / "outside"
            outside.mkdir(mode=0o700)
            sentinel = outside / "tsan.9"
            sentinel.write_text("outside", encoding="utf-8")
            (scratch / "sanitizer-output").symlink_to(
                outside, target_is_directory=True
            )
            rejected = self.run_emitter(scratch, prepare=True)
            self.assertEqual(rejected.returncode, 74)
            self.assertIn(b"sanitizer-report-directory-prepare-error", rejected.stdout)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "outside")

    def test_emitter_captures_first_sixteen_reports_and_marks_truncation(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            reports = scratch / "sanitizer-output"
            reports.mkdir(mode=0o700)
            for report_id in range(17):
                (reports / f"tsan.{report_id}").write_text(
                    f"stack {report_id}", encoding="utf-8"
                )
            emitted = self.run_emitter(scratch)
            self.assertEqual(emitted.returncode, 66)
            self.assertEqual(emitted.stdout.count(EMITTER_MODULE.BEGIN), 16)
            selected = sorted(
                f"tsan.{report_id}".encode("ascii") for report_id in range(17)
            )[:16]
            emitted_names = [
                line[len(EMITTER_MODULE.BEGIN):]
                for line in emitted.stdout.splitlines()
                if line.startswith(EMITTER_MODULE.BEGIN)
            ]
            self.assertEqual(emitted_names, selected)
            self.assertNotIn(b"tsan.9", emitted_names)
            self.assertIn(
                b"@@BLACKCOIN_SANITIZER_COLLECTOR_ERROR@@ "
                b"too-many-sanitizer-reports\n",
                emitted.stdout,
            )
            with tempfile.TemporaryDirectory() as output_directory:
                output = Path(output_directory) / "reports.log"
                extracted = self.run_extractor(emitted.stdout, output)
                self.assertEqual(extracted.returncode, 74)
                artifact = output.read_text(encoding="utf-8")
                self.assertIn("report_count=16\n", artifact)
                self.assertIn(
                    "collector_error=too-many-sanitizer-reports\n",
                    artifact,
                )
                self.assertNotIn("stack 9\n", artifact)

    def test_emitter_rejects_oversized_file_aggregate_and_record(self):
        self.assertEqual(EMITTER_MODULE.MAX_REPORTS, 16)
        self.assertEqual(EMITTER_MODULE.MAX_REPORT_BYTES, 32 * 1024 * 1024)
        self.assertEqual(
            EMITTER_MODULE.MAX_TOTAL_REPORT_BYTES, 64 * 1024 * 1024
        )
        self.assertEqual(EMITTER_MODULE.MAX_RECORD_BYTES, 1024 * 1024)
        self.assertEqual(
            EXTRACTOR_MODULE.MAX_REPORT_BYTES,
            EMITTER_MODULE.MAX_REPORT_BYTES,
        )
        self.assertEqual(
            EXTRACTOR_MODULE.MAX_TOTAL_REPORT_BYTES,
            EMITTER_MODULE.MAX_TOTAL_REPORT_BYTES,
        )
        self.assertEqual(
            EXTRACTOR_MODULE.MAX_RECORD_BYTES,
            EMITTER_MODULE.MAX_RECORD_BYTES,
        )
        self.assertEqual(
            EXTRACTOR_MODULE.MAX_REPORT_NAME_BYTES,
            EMITTER_MODULE.MAX_REPORT_NAME_BYTES,
        )
        self.assertEqual(
            EXTRACTOR_MODULE.COLLECTOR_ERROR_REASONS,
            {
                reason.encode("ascii")
                for reason in EMITTER_MODULE.COLLECTOR_ERROR_REASONS
            },
        )

        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            reports = scratch / "sanitizer-output"
            reports.mkdir(mode=0o700)
            with (reports / "tsan.1").open("wb") as oversized:
                oversized.truncate(EMITTER_MODULE.MAX_REPORT_BYTES + 1)
            rejected = self.run_emitter(scratch)
            self.assertEqual(rejected.returncode, 74)
            self.assertIn(b"report-exceeds-size-limit", rejected.stdout)

            (reports / "tsan.1").write_bytes(
                b"x" * EMITTER_MODULE.MAX_RECORD_BYTES
            )
            oversized_record = self.run_emitter(scratch)
            self.assertEqual(oversized_record.returncode, 74)
            self.assertIn(b"report-record-exceeds-size-limit", oversized_record.stdout)

            (reports / "tsan.1").write_bytes(b"12345")
            (reports / "tsan.2").write_bytes(b"67890")
            with mock.patch.object(
                EMITTER_MODULE, "MAX_TOTAL_REPORT_BYTES", 8
            ):
                collected, errors = EMITTER_MODULE.collect_reports(scratch)
            self.assertEqual(len(collected), 1)
            self.assertIn(
                "sanitizer-reports-exceed-total-size-limit", errors
            )

    def test_extractor_rejects_seventeenth_report_and_oversized_record(self):
        stream = b"".join(
            b"@@BLACKCOIN_SANITIZER_REPORT_BEGIN@@ tsan.%d\n"
            b"@@BLACKCOIN_SANITIZER_REPORT_DATA@@ tsan.%d\tstack %d\n"
            b"@@BLACKCOIN_SANITIZER_REPORT_END@@ tsan.%d\n"
            % (report_id, report_id, report_id, report_id)
            for report_id in range(17)
        )
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "reports.log"
            rejected = self.run_extractor(stream, output)
            self.assertEqual(rejected.returncode, 74)
            artifact = output.read_text(encoding="utf-8")
            self.assertIn("report_count=16\n", artifact)
            self.assertIn("framing_error=report-count-limit\n", artifact)
            self.assertNotIn("stack 16", artifact)

        oversized = (
            b"@@BLACKCOIN_SANITIZER_REPORT_BEGIN@@ tsan.1\n"
            b"@@BLACKCOIN_SANITIZER_REPORT_DATA@@ tsan.1\t"
            + b"x" * EXTRACTOR_MODULE.MAX_RECORD_BYTES
            + b"\n@@BLACKCOIN_SANITIZER_REPORT_END@@ tsan.1\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "reports.log"
            rejected = self.run_extractor(oversized, output)
            self.assertEqual(rejected.returncode, 74)
            artifact = output.read_text(encoding="utf-8")
            self.assertIn("framing_error=record-size-limit\n", artifact)
            self.assertIn("report_count=0\n", artifact)
            self.assertLess(output.stat().st_size, 4096)

    def test_extractor_enforces_per_report_and_aggregate_limits(self):
        oversized_report = (
            b"@@BLACKCOIN_SANITIZER_REPORT_BEGIN@@ tsan.1\n"
            b"@@BLACKCOIN_SANITIZER_REPORT_DATA@@ tsan.1\t12345\n"
            b"@@BLACKCOIN_SANITIZER_REPORT_DATA@@ tsan.1\t67890\n"
            b"@@BLACKCOIN_SANITIZER_REPORT_END@@ tsan.1\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "reports.log"
            status = self.run_extractor_in_process(
                oversized_report, output, report_limit=8, total_limit=64
            )
            self.assertEqual(status, 74)
            artifact = output.read_text(encoding="utf-8")
            self.assertIn("framing_error=report-size-limit\n", artifact)
            self.assertIn("report_count=0\n", artifact)

        oversized_aggregate = (
            b"@@BLACKCOIN_SANITIZER_REPORT_BEGIN@@ tsan.1\n"
            b"@@BLACKCOIN_SANITIZER_REPORT_DATA@@ tsan.1\t12345\n"
            b"@@BLACKCOIN_SANITIZER_REPORT_END@@ tsan.1\n"
            b"@@BLACKCOIN_SANITIZER_REPORT_BEGIN@@ tsan.2\n"
            b"@@BLACKCOIN_SANITIZER_REPORT_DATA@@ tsan.2\t67890\n"
            b"@@BLACKCOIN_SANITIZER_REPORT_END@@ tsan.2\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "reports.log"
            status = self.run_extractor_in_process(
                oversized_aggregate, output, report_limit=16, total_limit=8
            )
            self.assertEqual(status, 74)
            artifact = output.read_text(encoding="utf-8")
            self.assertIn("framing_error=total-size-limit\n", artifact)
            self.assertIn("report_count=1\n", artifact)
            self.assertIn("report_bytes=6\n", artifact)

    def test_collector_reason_is_validated_preserved_and_printed(self):
        valid = (
            b"@@BLACKCOIN_SANITIZER_COLLECTOR_ERROR@@ "
            b"unsafe-or-unstable-report\n"
        )
        invalid = (
            b"@@BLACKCOIN_SANITIZER_COLLECTOR_ERROR@@ "
            b"operator-controlled-text\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "reports.log"
            rejected = self.run_extractor(valid, output)
            self.assertEqual(rejected.returncode, 74)
            self.assertIn(
                b"sanitizer collector error: unsafe-or-unstable-report",
                rejected.stderr,
            )
            self.assertIn(
                "collector_error=unsafe-or-unstable-report\n",
                output.read_text(encoding="utf-8"),
            )

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "reports.log"
            rejected = self.run_extractor(invalid, output)
            self.assertEqual(rejected.returncode, 74)
            artifact = output.read_text(encoding="utf-8")
            self.assertIn("framing_error=invalid-collector-error\n", artifact)
            self.assertNotIn("operator-controlled-text", artifact)

    def test_final_artifact_is_unlinked_when_directory_fsync_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "reports.log"
            flags = os.O_RDONLY | os.O_DIRECTORY
            directory_fd = os.open(directory, flags)
            real_fsync = os.fsync

            def fail_directory_fsync(descriptor):
                if stat.S_ISDIR(os.fstat(descriptor).st_mode):
                    raise OSError("injected directory fsync failure")
                return real_fsync(descriptor)

            try:
                diagnostics = io.StringIO()
                with contextlib.redirect_stderr(diagnostics):
                    with mock.patch.object(
                        EXTRACTOR_MODULE.os,
                        "fsync",
                        side_effect=fail_directory_fsync,
                    ):
                        installed = EXTRACTOR_MODULE.install_artifact(
                            directory_fd, output.name, b"capture_complete=1\n"
                        )
                self.assertFalse(installed)
                self.assertFalse(output.exists())
                self.assertIn("directory fsync failure", diagnostics.getvalue())
            finally:
                os.close(directory_fd)

    def test_post_replace_open_and_fstat_failures_remove_final_artifact(self):
        for failure in ("open", "fstat"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() \
                    as directory:
                output = Path(directory) / "reports.log"
                directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
                real_open = os.open
                real_fstat = os.fstat
                verification_fd = None

                def intercept_open(path, flags, mode=0o777, *, dir_fd=None):
                    nonlocal verification_fd
                    if path == output.name and dir_fd == directory_fd:
                        if failure == "open":
                            raise OSError("injected installed-artifact open failure")
                        verification_fd = real_open(
                            path, flags, mode, dir_fd=dir_fd
                        )
                        return verification_fd
                    return real_open(path, flags, mode, dir_fd=dir_fd)

                def intercept_fstat(descriptor):
                    if failure == "fstat" and descriptor == verification_fd:
                        raise OSError("injected installed-artifact fstat failure")
                    return real_fstat(descriptor)

                try:
                    diagnostics = io.StringIO()
                    with contextlib.redirect_stderr(diagnostics):
                        with mock.patch.object(
                            EXTRACTOR_MODULE.os, "open", side_effect=intercept_open
                        ), mock.patch.object(
                            EXTRACTOR_MODULE.os,
                            "fstat",
                            side_effect=intercept_fstat,
                        ):
                            installed = EXTRACTOR_MODULE.install_artifact(
                                directory_fd,
                                output.name,
                                b"capture_complete=1\n",
                            )
                    self.assertFalse(installed)
                    self.assertFalse(output.exists())
                    self.assertIn(f"{failure} failure", diagnostics.getvalue())
                finally:
                    os.close(directory_fd)

    def test_unlink_failure_leaves_status_75_artifact_non_authoritative(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "reports.log"
            real_fstat = os.fstat
            real_unlink = os.unlink
            fstat_calls = 0

            def fail_verification_fstat(descriptor):
                nonlocal fstat_calls
                fstat_calls += 1
                if fstat_calls == 3:
                    raise OSError("injected installed-artifact fstat failure")
                return real_fstat(descriptor)

            def fail_final_unlink(path, *, dir_fd=None):
                if path == output.name and dir_fd is not None:
                    raise OSError("injected installed-artifact unlink failure")
                return real_unlink(path, dir_fd=dir_fd)

            with mock.patch.object(
                EXTRACTOR_MODULE.os, "fstat", side_effect=fail_verification_fstat
            ), mock.patch.object(
                EXTRACTOR_MODULE.os, "unlink", side_effect=fail_final_unlink
            ):
                status = self.run_extractor_in_process(
                    b"ordinary-output\n",
                    output,
                    report_limit=EXTRACTOR_MODULE.MAX_REPORT_BYTES,
                    total_limit=EXTRACTOR_MODULE.MAX_TOTAL_REPORT_BYTES,
                )
            self.assertEqual(status, EXTRACTOR_MODULE.ARTIFACT_ERROR_STATUS)
            self.assertTrue(output.exists())
            workflow = WORKFLOW.read_text(encoding="utf-8")
            self.assertIn(
                '[[ "$extractor_status" -eq 0 || "$extractor_status" -eq 74 ]]',
                workflow,
            )
            self.assertNotIn('"$extractor_status" -eq 75', workflow)

    def test_final_artifact_is_unlinked_when_directory_close_fails_after_close(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "reports.log"
            output.write_text("capture_complete=1\n", encoding="utf-8")
            directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
            real_close = os.close
            failed = False

            def fail_first_close(descriptor):
                nonlocal failed
                if descriptor == directory_fd and not failed:
                    failed = True
                    real_close(descriptor)
                    raise OSError("injected directory close failure")
                return real_close(descriptor)

            diagnostics = io.StringIO()
            with contextlib.redirect_stderr(diagnostics):
                with mock.patch.object(
                    EXTRACTOR_MODULE.os, "close", side_effect=fail_first_close
                ):
                    closed = EXTRACTOR_MODULE.close_output_directory(
                        directory_fd, output, artifact_installed=True
                    )
            self.assertFalse(closed)
            self.assertFalse(output.exists())
            self.assertIn("directory close failed", diagnostics.getvalue())

    def test_workflow_preserves_source_status_and_limits_artifact_scope(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        driver = DRIVER.read_text(encoding="utf-8")
        self.assertEqual(EXTRACTOR_MODULE.CAPTURE_ERROR_STATUS, 74)
        self.assertEqual(EXTRACTOR_MODULE.ARTIFACT_ERROR_STATUS, 75)
        self.assertIn('pipeline_status=("${PIPESTATUS[@]}")', workflow)
        self.assertIn('if [[ "$test_status" -ne 0 ]]', workflow)
        self.assertIn('exit "$test_status"', workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertIn("matrix.name == 'thread-sanitizer'", workflow)
        self.assertIn("mktemp -d", workflow)
        self.assertIn("steps.sanitizer-gate.outputs.report_ready == 'true'", workflow)
        self.assertIn("steps.sanitizer-gate.outputs.report_log", workflow)
        self.assertIn(
            '[[ "$extractor_status" -eq 0 || "$extractor_status" -eq 74 ]]',
            workflow,
        )
        self.assertIn("grep -Fxq 'capture_complete=1'", workflow)
        self.assertIn("^collector_error_count=[0-9]+$", workflow)
        self.assertIn('[[ ! -e "$report_log" && ! -L "$report_log" ]]', workflow)
        self.assertIn("github.run_attempt", workflow)
        self.assertNotIn('>> "$report_log"', workflow)
        self.assertNotIn("tee \"$report_log\"", workflow)
        self.assertNotIn(
            'rm -rf -- "${BASE_SCRATCH_DIR}/sanitizer-output"', driver
        )
        self.assertIn("emit_sanitizer_reports_on_exit()", driver)
        self.assertIn("emit_sanitizer_reports.py\" --prepare", driver)
        self.assertIn("emit_sanitizer_reports.py", driver)
        self.assertIn("trap - EXIT", driver)
        self.assertIn('exit "$source_status"', driver)


if __name__ == "__main__":
    unittest.main()
