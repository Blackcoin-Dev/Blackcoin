#!/usr/bin/env python3
"""Prepare and emit bounded, file-backed TSan evidence for CI."""

import bisect
import os
import re
import stat
import sys
from pathlib import Path
from typing import Iterator, List, Optional, Tuple


BEGIN = b"@@BLACKCOIN_SANITIZER_REPORT_BEGIN@@ "
DATA = b"@@BLACKCOIN_SANITIZER_REPORT_DATA@@ "
END = b"@@BLACKCOIN_SANITIZER_REPORT_END@@ "
COLLECTOR_ERROR = b"@@BLACKCOIN_SANITIZER_COLLECTOR_ERROR@@ "
NAME_RE = re.compile(rb"tsan\.[0-9]+\Z")

MAX_REPORTS = 16
MAX_REPORT_BYTES = 32 * 1024 * 1024
MAX_TOTAL_REPORT_BYTES = 64 * 1024 * 1024
MAX_RECORD_BYTES = 1024 * 1024
MAX_REPORT_NAME_BYTES = 64
SANITIZER_FAILURE_STATUS = 66
COLLECTION_FAILURE_STATUS = 74

# The extractor accepts only this fixed vocabulary. Keep the two lists identical
# so arbitrary output cannot be smuggled into the evidence artifact as an error.
COLLECTOR_ERROR_REASONS = frozenset({
    "invalid-source-status",
    "missing-sanitizer-scratch-directory",
    "non-absolute-sanitizer-scratch-directory",
    "unsafe-or-missing-sanitizer-scratch-directory",
    "unsafe-sanitizer-scratch-directory-metadata",
    "sanitizer-report-directory-prepare-error",
    "unsafe-report-directory-metadata",
    "unsafe-preexisting-report-entry",
    "report-directory-changed-during-preparation",
    "too-many-sanitizer-reports",
    "unexpected-report-entry",
    "unsafe-or-unstable-report",
    "report-exceeds-size-limit",
    "report-record-exceeds-size-limit",
    "sanitizer-reports-exceed-total-size-limit",
    "report-directory-changed-during-collection",
    "sanitizer-report-collection-io-error",
    "sanitizer-report-descriptor-close-error",
    "sanitizer-report-output-error",
})


class ReportReadError(OSError):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def descriptor_flags() -> int:
    required = ("O_CLOEXEC", "O_DIRECTORY", "O_NOFOLLOW")
    if any(not hasattr(os, name) for name in required):
        raise OSError("required descriptor flags are unavailable")
    if os.open not in os.supports_dir_fd:
        raise OSError("descriptor-relative open is unavailable")
    return os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW


def parse_source_status(value: str) -> Optional[int]:
    try:
        status = int(value, 10)
    except ValueError:
        return None
    return status if 0 <= status <= 255 and str(status) == value else None


def emit_collector_error(reason: str) -> None:
    if reason not in COLLECTOR_ERROR_REASONS:
        raise ValueError("collector error reason is not in the fixed vocabulary")
    sys.stdout.buffer.write(COLLECTOR_ERROR + reason.encode("ascii") + b"\n")


def append_error(errors: List[str], reason: str) -> None:
    if reason not in COLLECTOR_ERROR_REASONS:
        raise ValueError("collector error reason is not in the fixed vocabulary")
    if reason not in errors:
        errors.append(reason)


def report_name_is_valid(name: bytes) -> bool:
    return len(name) <= MAX_REPORT_NAME_BYTES and NAME_RE.fullmatch(name) is not None


def iter_report_lines(payload: bytes) -> Iterator[bytes]:
    """Yield normalized lines without allocating an unbounded split list."""
    offset = 0
    while offset < len(payload):
        newline = payload.find(b"\n", offset)
        if newline < 0:
            line = payload[offset:]
            offset = len(payload)
        else:
            line = payload[offset:newline]
            offset = newline + 1
        if line.endswith(b"\r"):
            line = line[:-1]
        yield line


def select_directory_entries(
    directory_fd: int, limit: int
) -> Tuple[int, List[str]]:
    """Return the lexicographically first entries with bounded memory."""
    selected: List[str] = []
    count = 0
    with os.scandir(directory_fd) as entries:
        for entry in entries:
            count += 1
            if len(selected) < limit:
                bisect.insort(selected, entry.name)
            elif limit and entry.name < selected[-1]:
                bisect.insort(selected, entry.name)
                selected.pop()
    return count, selected


def report_directory_metadata_is_safe(metadata: os.stat_result) -> bool:
    return (
        stat.S_ISDIR(metadata.st_mode)
        and metadata.st_uid == os.geteuid()
        and stat.S_IMODE(metadata.st_mode) == 0o700
    )


def scratch_directory_metadata_is_safe(metadata: os.stat_result) -> bool:
    return stat.S_ISDIR(metadata.st_mode) and metadata.st_uid == os.geteuid()


def named_directory_is_same(
    scratch_fd: int, directory_metadata: os.stat_result
) -> bool:
    current = os.stat(
        "sanitizer-output", dir_fd=scratch_fd, follow_symlinks=False
    )
    return (
        stat.S_ISDIR(current.st_mode)
        and current.st_dev == directory_metadata.st_dev
        and current.st_ino == directory_metadata.st_ino
        and current.st_uid == directory_metadata.st_uid
        and current.st_mode == directory_metadata.st_mode
        and current.st_nlink > 0
    )


def close_descriptors(
    descriptors: Tuple[Optional[int], ...], errors: List[str]
) -> None:
    for descriptor in descriptors:
        if descriptor is None:
            continue
        try:
            os.close(descriptor)
        except OSError:
            append_error(errors, "sanitizer-report-descriptor-close-error")


def open_scratch(scratch: Path) -> Tuple[int, int]:
    if not scratch.is_absolute():
        raise ValueError("non-absolute-sanitizer-scratch-directory")
    flags = descriptor_flags()
    try:
        scratch_fd = os.open(scratch, flags)
    except OSError as error:
        raise ValueError(
            "unsafe-or-missing-sanitizer-scratch-directory"
        ) from error
    try:
        if not scratch_directory_metadata_is_safe(os.fstat(scratch_fd)):
            raise ValueError("unsafe-sanitizer-scratch-directory-metadata")
    except BaseException:
        os.close(scratch_fd)
        raise
    return scratch_fd, flags


def prepare_report_directory(scratch: Path) -> List[str]:
    """Create or securely empty the report directory without path traversal."""
    errors: List[str] = []
    scratch_fd: Optional[int] = None
    directory_fd: Optional[int] = None
    try:
        scratch_fd, flags = open_scratch(scratch)
        try:
            os.mkdir("sanitizer-output", 0o700, dir_fd=scratch_fd)
            os.fsync(scratch_fd)
        except FileExistsError:
            pass
        directory_fd = os.open("sanitizer-output", flags, dir_fd=scratch_fd)
        directory_metadata = os.fstat(directory_fd)
        if not report_directory_metadata_is_safe(directory_metadata):
            append_error(errors, "unsafe-report-directory-metadata")
        else:
            entry_count, entries = select_directory_entries(
                directory_fd, MAX_REPORTS + 1
            )
            if entry_count > MAX_REPORTS:
                append_error(errors, "too-many-sanitizer-reports")
            for entry in entries:
                name = os.fsencode(entry)
                try:
                    metadata = os.stat(
                        entry, dir_fd=directory_fd, follow_symlinks=False
                    )
                except OSError:
                    append_error(errors, "unsafe-preexisting-report-entry")
                    break
                if (
                    not report_name_is_valid(name)
                    or not stat.S_ISREG(metadata.st_mode)
                    or metadata.st_uid != os.geteuid()
                    or metadata.st_nlink != 1
                ):
                    append_error(errors, "unsafe-preexisting-report-entry")
                    break
            if not errors:
                for entry in entries:
                    os.unlink(entry, dir_fd=directory_fd)
                os.fsync(directory_fd)
                remaining_count, _ = select_directory_entries(directory_fd, 1)
                if remaining_count or not named_directory_is_same(
                    scratch_fd, directory_metadata
                ):
                    append_error(
                        errors,
                        "report-directory-changed-during-preparation",
                    )
    except ValueError as error:
        append_error(errors, str(error))
    except OSError:
        append_error(errors, "sanitizer-report-directory-prepare-error")
    finally:
        close_descriptors((directory_fd, scratch_fd), errors)
    return errors


def read_stable_report(directory_fd: int, name: bytes) -> bytes:
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
    fd = os.open(os.fsdecode(name), flags, dir_fd=directory_fd)
    try:
        before = os.fstat(fd)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or stat.S_IMODE(before.st_mode) & 0o022
        ):
            raise ReportReadError("unsafe-or-unstable-report")
        if before.st_size <= 0:
            raise ReportReadError("unsafe-or-unstable-report")
        if before.st_size > MAX_REPORT_BYTES:
            raise ReportReadError("report-exceeds-size-limit")

        chunks: List[bytes] = []
        total = 0
        while True:
            chunk = os.read(fd, 64 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > MAX_REPORT_BYTES:
                raise ReportReadError("report-exceeds-size-limit")

        after = os.fstat(fd)
        if (
            before.st_dev != after.st_dev
            or before.st_ino != after.st_ino
            or before.st_uid != after.st_uid
            or before.st_mode != after.st_mode
            or before.st_nlink != after.st_nlink
            or before.st_size != after.st_size
            or before.st_mtime_ns != after.st_mtime_ns
            or before.st_ctime_ns != after.st_ctime_ns
            or total != before.st_size
        ):
            raise ReportReadError("unsafe-or-unstable-report")
        return b"".join(chunks)
    finally:
        os.close(fd)


def framed_payload_size(name: bytes, payload: bytes) -> Tuple[int, Optional[str]]:
    total = 0
    for line in iter_report_lines(payload):
        if len(DATA) + len(name) + 1 + len(line) + 1 > MAX_RECORD_BYTES:
            return 0, "report-record-exceeds-size-limit"
        total += len(line) + 1
        if total > MAX_REPORT_BYTES:
            return 0, "report-exceeds-size-limit"
    return total, None


def directory_identity(value: os.stat_result) -> Tuple[int, ...]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_uid,
        value.st_mode,
        value.st_nlink,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def collect_reports(
    scratch: Path,
) -> Tuple[List[Tuple[bytes, bytes]], List[str]]:
    errors: List[str] = []
    reports: List[Tuple[bytes, bytes]] = []
    scratch_fd: Optional[int] = None
    directory_fd: Optional[int] = None
    try:
        scratch_fd, flags = open_scratch(scratch)
        directory_fd = os.open("sanitizer-output", flags, dir_fd=scratch_fd)
        directory_stat = os.fstat(directory_fd)
        if not report_directory_metadata_is_safe(directory_stat):
            append_error(errors, "unsafe-report-directory-metadata")
        else:
            entry_count_before, entries_before = select_directory_entries(
                directory_fd, MAX_REPORTS
            )
            if entry_count_before > MAX_REPORTS:
                append_error(errors, "too-many-sanitizer-reports")
            total_bytes = 0
            for entry in entries_before[:MAX_REPORTS]:
                name = os.fsencode(entry)
                if not report_name_is_valid(name):
                    append_error(errors, "unexpected-report-entry")
                    continue
                try:
                    payload = read_stable_report(directory_fd, name)
                except ReportReadError as error:
                    append_error(errors, error.reason)
                    continue
                except OSError:
                    append_error(errors, "unsafe-or-unstable-report")
                    continue
                payload_size, payload_error = framed_payload_size(name, payload)
                if payload_error is not None:
                    append_error(errors, payload_error)
                    continue
                if total_bytes + payload_size > MAX_TOTAL_REPORT_BYTES:
                    append_error(
                        errors,
                        "sanitizer-reports-exceed-total-size-limit",
                    )
                    continue
                total_bytes += payload_size
                reports.append((name, payload))
            entry_count_after, entries_after = select_directory_entries(
                directory_fd, MAX_REPORTS
            )
            directory_after = os.fstat(directory_fd)
            if (
                entry_count_before != entry_count_after
                or entries_before != entries_after
                or directory_identity(directory_stat)
                != directory_identity(directory_after)
                or not named_directory_is_same(scratch_fd, directory_stat)
            ):
                append_error(
                    errors,
                    "report-directory-changed-during-collection",
                )
                reports.clear()
    except ValueError as error:
        append_error(errors, str(error))
        reports.clear()
    except OSError:
        append_error(errors, "sanitizer-report-collection-io-error")
        reports.clear()
    finally:
        close_descriptors((directory_fd, scratch_fd), errors)
    return reports, errors


def get_scratch() -> Tuple[Optional[Path], List[str]]:
    scratch_value = os.environ.get("BASE_SCRATCH_DIR")
    if not scratch_value:
        return None, ["missing-sanitizer-scratch-directory"]
    scratch = Path(scratch_value)
    if not scratch.is_absolute():
        return None, ["non-absolute-sanitizer-scratch-directory"]
    return scratch, []


def emit_reports(
    reports: List[Tuple[bytes, bytes]], errors: List[str]
) -> bool:
    try:
        for name, payload in reports:
            sys.stdout.buffer.write(BEGIN + name + b"\n")
            for line in iter_report_lines(payload):
                sys.stdout.buffer.write(DATA + name + b"\t" + line + b"\n")
            sys.stdout.buffer.write(END + name + b"\n")
        for reason in errors:
            emit_collector_error(reason)
        sys.stdout.buffer.flush()
    except OSError:
        return False
    return True


def main() -> int:
    scratch, errors = get_scratch()
    if sys.argv[1:] == ["--prepare"]:
        if scratch is not None:
            errors.extend(prepare_report_directory(scratch))
        if not emit_reports([], errors):
            return COLLECTION_FAILURE_STATUS
        return 0 if not errors else COLLECTION_FAILURE_STATUS

    if len(sys.argv) != 2:
        emit_reports([], ["invalid-source-status"])
        return 70
    source_status = parse_source_status(sys.argv[1])
    if source_status is None:
        emit_reports([], ["invalid-source-status"])
        return 70

    reports: List[Tuple[bytes, bytes]] = []
    if scratch is not None:
        collected, collection_errors = collect_reports(scratch)
        reports.extend(collected)
        errors.extend(collection_errors)
    output_ok = emit_reports(reports, errors)

    # The command under test has precedence, but a real sanitizer report must
    # still fail a nominally successful source command.
    if source_status != 0:
        return source_status
    if reports:
        return SANITIZER_FAILURE_STATUS
    if errors or not output_ok:
        return COLLECTION_FAILURE_STATUS
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
