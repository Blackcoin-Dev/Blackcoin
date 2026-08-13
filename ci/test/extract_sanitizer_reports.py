#!/usr/bin/env python3
"""Extract bounded, framed sanitizer evidence from a CI output stream.

Framing separates expected tool records from ordinary process output. It is not
an authentication mechanism; the workflow's immutable checkout and isolated job
are the trust boundary for the emitter and extractor.
"""

import argparse
import io
import os
import re
import secrets
import stat
import sys
from pathlib import Path
from typing import Optional, Set, Tuple


BEGIN = b"@@BLACKCOIN_SANITIZER_REPORT_BEGIN@@ "
DATA = b"@@BLACKCOIN_SANITIZER_REPORT_DATA@@ "
END = b"@@BLACKCOIN_SANITIZER_REPORT_END@@ "
COLLECTOR_ERROR = b"@@BLACKCOIN_SANITIZER_COLLECTOR_ERROR@@ "
RESERVED = b"@@BLACKCOIN_SANITIZER_"
NAME_RE = re.compile(rb"tsan\.[0-9]+\Z")
SHA_RE = re.compile(r"[0-9a-f]{40}\Z")
MATRIX_RE = re.compile(r"[a-z0-9-]+\Z")

MAX_REPORTS = 16
MAX_REPORT_BYTES = 32 * 1024 * 1024
MAX_TOTAL_REPORT_BYTES = 64 * 1024 * 1024
MAX_RECORD_BYTES = 1024 * 1024
MAX_REPORT_NAME_BYTES = 64
CAPTURE_ERROR_STATUS = 74
ARTIFACT_ERROR_STATUS = 75

# This is the emitter's complete error vocabulary. Unknown reasons are framing
# failures and are never copied into the evidence artifact.
COLLECTOR_ERROR_REASONS = frozenset({
    b"invalid-source-status",
    b"missing-sanitizer-scratch-directory",
    b"non-absolute-sanitizer-scratch-directory",
    b"unsafe-or-missing-sanitizer-scratch-directory",
    b"unsafe-sanitizer-scratch-directory-metadata",
    b"sanitizer-report-directory-prepare-error",
    b"unsafe-report-directory-metadata",
    b"unsafe-preexisting-report-entry",
    b"report-directory-changed-during-preparation",
    b"too-many-sanitizer-reports",
    b"unexpected-report-entry",
    b"unsafe-or-unstable-report",
    b"report-exceeds-size-limit",
    b"report-record-exceeds-size-limit",
    b"sanitizer-reports-exceed-total-size-limit",
    b"report-directory-changed-during-collection",
    b"sanitizer-report-collection-io-error",
    b"sanitizer-report-descriptor-close-error",
    b"sanitizer-report-output-error",
})


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--target-sha", required=True)
    parser.add_argument("--sanitizer", required=True)
    return parser.parse_args()


def strip_record_newline(record: bytes) -> bytes:
    if record.endswith(b"\n"):
        record = record[:-1]
    if record.endswith(b"\r"):
        record = record[:-1]
    return record


def report_name_is_valid(name: bytes) -> bool:
    return len(name) <= MAX_REPORT_NAME_BYTES and NAME_RE.fullmatch(name) is not None


def open_output_directory(output: Path) -> Tuple[Optional[int], bool]:
    if any(
        not hasattr(os, name)
        for name in ("O_CLOEXEC", "O_DIRECTORY", "O_NOFOLLOW")
    ) or os.open not in os.supports_dir_fd:
        print("sanitizer artifact descriptor APIs are unavailable", file=sys.stderr)
        return None, False
    if output.name in ("", ".", ".."):
        print("sanitizer artifact output name is unsafe", file=sys.stderr)
        return None, False
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW
    try:
        directory_fd = os.open(output.parent, flags)
    except OSError as error:
        print(f"sanitizer artifact directory open failed: {error}", file=sys.stderr)
        return None, False
    metadata = os.fstat(directory_fd)
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid():
        os.close(directory_fd)
        print("sanitizer artifact directory metadata is unsafe", file=sys.stderr)
        return None, False
    return directory_fd, True


def remove_artifact(directory_fd: int, name: str) -> bool:
    try:
        existing = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return True
    except OSError as error:
        print(f"sanitizer artifact cleanup preflight failed: {error}", file=sys.stderr)
        return False
    if (
        not stat.S_ISREG(existing.st_mode)
        or existing.st_uid != os.geteuid()
        or existing.st_nlink != 1
    ):
        print("sanitizer artifact cleanup rejected an unsafe output", file=sys.stderr)
        return False
    try:
        os.unlink(name, dir_fd=directory_fd)
        os.fsync(directory_fd)
    except OSError as error:
        print(f"sanitizer artifact cleanup failed: {error}", file=sys.stderr)
        return False
    return True


def clear_artifact(directory_fd: int, name: str) -> bool:
    return remove_artifact(directory_fd, name)


def remove_installed_artifact(directory_fd: int, name: str) -> bool:
    """Remove an output this process installed in its already-open directory."""
    try:
        os.unlink(name, dir_fd=directory_fd)
        os.fsync(directory_fd)
    except FileNotFoundError:
        return True
    except OSError as error:
        print(f"sanitizer artifact cleanup failed: {error}", file=sys.stderr)
        return False
    return True


def install_artifact(
    directory_fd: int, output_name: str, contents: bytes
) -> bool:
    temporary_name: Optional[str] = None
    descriptor: Optional[int] = None
    verification_descriptor: Optional[int] = None
    temporary_identity: Optional[Tuple[int, int]] = None
    installed = False
    succeeded = False
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW
        for _ in range(32):
            candidate = f".{output_name}.{secrets.token_hex(16)}"
            try:
                descriptor = os.open(
                    candidate, flags, 0o600, dir_fd=directory_fd
                )
                temporary_name = candidate
                break
            except FileExistsError:
                continue
        if descriptor is None or temporary_name is None:
            raise OSError("cannot allocate a unique artifact temporary file")
        with os.fdopen(descriptor, "wb") as artifact:
            descriptor = None
            artifact.write(contents)
            artifact.flush()
            os.fsync(artifact.fileno())
            metadata = os.fstat(artifact.fileno())
            if not (
                stat.S_ISREG(metadata.st_mode)
                and metadata.st_uid == os.geteuid()
                and metadata.st_nlink == 1
                and stat.S_IMODE(metadata.st_mode) == 0o600
                and metadata.st_size == len(contents)
            ):
                raise OSError("temporary sanitizer artifact metadata mismatch")
            temporary_identity = (metadata.st_dev, metadata.st_ino)
        os.replace(
            temporary_name,
            output_name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
        temporary_name = None
        installed = True
        os.fsync(directory_fd)
        flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
        verification_descriptor = os.open(
            output_name, flags, dir_fd=directory_fd
        )
        metadata = os.fstat(verification_descriptor)
        if not (
            temporary_identity is not None
            and (metadata.st_dev, metadata.st_ino) == temporary_identity
            and stat.S_ISREG(metadata.st_mode)
            and metadata.st_uid == os.geteuid()
            and metadata.st_nlink == 1
            and stat.S_IMODE(metadata.st_mode) == 0o600
            and metadata.st_size == len(contents)
        ):
            raise OSError("installed sanitizer artifact metadata mismatch")
        descriptor_to_close = verification_descriptor
        verification_descriptor = None
        os.close(descriptor_to_close)
        succeeded = True
    except OSError as error:
        print(f"sanitizer artifact finalization failed: {error}", file=sys.stderr)
    finally:
        if verification_descriptor is not None:
            descriptor_to_close = verification_descriptor
            verification_descriptor = None
            try:
                os.close(descriptor_to_close)
            except OSError as error:
                print(
                    f"sanitizer artifact verification close failed: {error}",
                    file=sys.stderr,
                )
                succeeded = False
        if descriptor is not None:
            descriptor_to_close = descriptor
            descriptor = None
            try:
                os.close(descriptor_to_close)
            except OSError as error:
                print(
                    f"sanitizer artifact temporary close failed: {error}",
                    file=sys.stderr,
                )
                succeeded = False
        if temporary_name is not None:
            try:
                os.unlink(temporary_name, dir_fd=directory_fd)
                os.fsync(directory_fd)
            except OSError as error:
                print(
                    f"sanitizer artifact temporary cleanup failed: {error}",
                    file=sys.stderr,
                )
                succeeded = False
        if installed and not succeeded:
            if not remove_installed_artifact(directory_fd, output_name):
                print(
                    "sanitizer artifact final output cleanup failed",
                    file=sys.stderr,
                )
    return succeeded


def close_output_directory(
    directory_fd: int, output: Path, artifact_installed: bool
) -> bool:
    try:
        os.close(directory_fd)
        return True
    except OSError as error:
        print(f"sanitizer artifact directory close failed: {error}", file=sys.stderr)

    if artifact_installed:
        # POSIX leaves the descriptor state unspecified after a failed close,
        # so never retry or otherwise use it. Reopen the owned parent and remove
        # only the exact name this process installed.
        cleanup_fd, cleanup_ready = open_output_directory(output)
        if cleanup_ready and cleanup_fd is not None:
            remove_installed_artifact(cleanup_fd, output.name)
            try:
                os.close(cleanup_fd)
            except OSError:
                pass
    return False


def main() -> int:
    args = parse_args()
    if not SHA_RE.fullmatch(args.target_sha):
        raise SystemExit(
            "target SHA must be exactly 40 lowercase hexadecimal characters"
        )
    if not MATRIX_RE.fullmatch(args.sanitizer):
        raise SystemExit("sanitizer name contains unsupported characters")

    output_directory_fd, output_ready = open_output_directory(args.output)
    if output_directory_fd is not None:
        output_ready = clear_artifact(output_directory_fd, args.output.name)

    artifact = io.BytesIO()
    artifact.write(f"target_sha={args.target_sha}\n".encode())
    artifact.write(f"sanitizer={args.sanitizer}\n".encode())

    active: Optional[bytes] = None
    active_payload: Optional[io.BytesIO] = None
    discarding: Optional[bytes] = None
    completed = 0
    completed_bytes = 0
    framing_errors = 0
    collector_errors = 0
    seen: Set[bytes] = set()
    recorded_framing_errors: Set[str] = set()
    recorded_collector_errors: Set[bytes] = set()
    stdout_failed = False

    def framing_error(reason: str) -> None:
        nonlocal framing_errors
        framing_errors += 1
        if reason not in recorded_framing_errors:
            recorded_framing_errors.add(reason)
            artifact.write(f"framing_error={reason}\n".encode())
            print(f"sanitizer framing error: {reason}", file=sys.stderr)

    def collector_error(reason: bytes) -> None:
        nonlocal collector_errors
        collector_errors += 1
        if reason not in recorded_collector_errors:
            recorded_collector_errors.add(reason)
            artifact.write(b"collector_error=" + reason + b"\n")
            print(
                "sanitizer collector error: " + reason.decode("ascii"),
                file=sys.stderr,
            )

    def write_stdout(contents: bytes) -> None:
        nonlocal stdout_failed
        if stdout_failed:
            return
        try:
            sys.stdout.buffer.write(contents)
        except OSError:
            stdout_failed = True
            framing_error("stdout-write-error")

    def invalidate_active_report() -> None:
        nonlocal active, active_payload, discarding
        if active is not None:
            discarding = active
            active = None
            active_payload = None

    def process_record(raw: bytes) -> None:
        nonlocal active, active_payload, completed, completed_bytes, discarding
        if raw.startswith(BEGIN):
            name = strip_record_newline(raw[len(BEGIN):])
            if active is not None or discarding is not None:
                framing_error("nested-begin")
            elif not report_name_is_valid(name) or name in seen:
                framing_error("invalid-or-duplicate-begin")
            elif len(seen) >= MAX_REPORTS:
                framing_error("report-count-limit")
                discarding = name
            else:
                active = name
                active_payload = io.BytesIO()
                seen.add(name)
            return

        if raw.startswith(DATA):
            record = strip_record_newline(raw[len(DATA):])
            name, separator, payload = record.partition(b"\t")
            if discarding is not None and separator == b"\t" and name == discarding:
                return
            if (
                active is None
                or active_payload is None
                or separator != b"\t"
                or name != active
            ):
                framing_error("orphan-or-mismatched-data")
                return
            next_size = active_payload.tell() + len(payload) + 1
            if next_size > MAX_REPORT_BYTES:
                framing_error("report-size-limit")
                invalidate_active_report()
                return
            if completed_bytes + next_size > MAX_TOTAL_REPORT_BYTES:
                framing_error("total-size-limit")
                invalidate_active_report()
                return
            active_payload.write(payload + b"\n")
            write_stdout(payload + b"\n")
            return

        if raw.startswith(END):
            name = strip_record_newline(raw[len(END):])
            if discarding is not None and name == discarding:
                discarding = None
            elif active is None or active_payload is None or name != active:
                framing_error("orphan-or-mismatched-end")
            else:
                payload = active_payload.getbuffer()
                artifact.write(BEGIN + active + b"\n")
                artifact.write(payload)
                artifact.write(END + active + b"\n")
                completed_bytes += payload.nbytes
                payload.release()
                completed += 1
                active = None
                active_payload = None
            return

        if raw.startswith(COLLECTOR_ERROR):
            reason = strip_record_newline(raw[len(COLLECTOR_ERROR):])
            if reason not in COLLECTOR_ERROR_REASONS:
                framing_error("invalid-collector-error")
            else:
                collector_error(reason)
            return

        if raw.startswith(RESERVED):
            framing_error("unknown-record")
            write_stdout(raw)
            return

        write_stdout(raw)

    while True:
        raw = sys.stdin.buffer.readline(MAX_RECORD_BYTES + 1)
        if not raw:
            break
        if len(raw) <= MAX_RECORD_BYTES:
            process_record(raw)
            continue

        reserved_record = raw.startswith(RESERVED)
        if reserved_record:
            framing_error("record-size-limit")
            invalidate_active_report()
        else:
            write_stdout(raw)
        while not raw.endswith(b"\n"):
            raw = sys.stdin.buffer.readline(MAX_RECORD_BYTES + 1)
            if not raw:
                break
            if not reserved_record:
                write_stdout(raw)

    if active is not None or discarding is not None:
        framing_error("incomplete-report")
    try:
        sys.stdout.buffer.flush()
    except OSError:
        stdout_failed = True
        framing_error("stdout-write-error")

    artifact.write(f"report_count={completed}\n".encode())
    artifact.write(f"report_bytes={completed_bytes}\n".encode())
    artifact.write(f"framing_error_count={framing_errors}\n".encode())
    artifact.write(f"collector_error_count={collector_errors}\n".encode())
    artifact.write(b"artifact_error=0\n")
    artifact.write(b"capture_complete=1\n")

    artifact_installed = False
    if output_ready and output_directory_fd is not None:
        artifact_installed = install_artifact(
            output_directory_fd, args.output.name, artifact.getvalue()
        )
    directory_closed = True
    if output_directory_fd is not None:
        directory_closed = close_output_directory(
            output_directory_fd, args.output, artifact_installed
        )
        if not directory_closed:
            artifact_installed = False

    if not artifact_installed or not directory_closed:
        return ARTIFACT_ERROR_STATUS
    if framing_errors or collector_errors or stdout_failed:
        return CAPTURE_ERROR_STATUS
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
