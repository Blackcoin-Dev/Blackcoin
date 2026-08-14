#!/usr/bin/env python3
"""Fail-closed rotation for the installed normal-unlock helper.

The audit command is filesystem-only.  The install command requires a fresh,
root-owned authority that binds the deterministic audit plan.  No command in
this file creates keys, changes PoW policy, repairs claims, broadcasts a
transaction, rewinds chain data, or deploys Core bytes.
"""

import argparse
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import time
from pathlib import Path


SCHEMA = 1
TOOLING_PARENT_COMMIT = "af73ef239641639ca087639869c5a1c145aec6b6"
PREDECESSOR_HELPER_SHA256 = "acf28446e842fd0fa92b06c2ebc182e9da38fcde7bac06dd920d50a33e4e3dd1"
SUCCESSOR_HELPER_SHA256 = "aa924baf0a9d384759019d50e3815e03e264b906c7b51ecc76023c854b91a3e7"
PREDECESSOR_SUPERVISOR_SHA256 = "112ffbaa2702f9e4a9568948ef383cd22ae70876376c29602629e4c3d15d7341"
SUCCESSOR_SUPERVISOR_SHA256 = "b879bb3833bc5786aa34918741550119cde4ddf71ca00f06b73cfe1863aaa8c0"
SUPERVISOR_BASENAME = "pos_unlock_renewal_supervisor.sh"
STATE_ROOT = Path("/boot/config/plugins/blackcoin-quantum-nodes")
HELPER_PATH = STATE_ROOT / "blackcoin_node_normal_unlock.sh"
ACTIVE_POW_CYCLE_BASENAME = "blackcoin_pow_quarantine_cycle.sh"
ACTIVE_POW_CYCLE_PATH = STATE_ROOT / ACTIVE_POW_CYCLE_BASENAME
ACTIVE_POW_CYCLE_PREDECESSOR_SHA256 = "1dbb72bd0e400806a8b1cdf9337cd28672f9242c5d18feb65dd6c64ce27b6f1c"
ACTIVE_POW_CYCLE_SUCCESSOR_SHA256 = "9936417a89bc34ae9dbe7a22346ed0dd78d79fcee401a10481e6b5ccdcb54b67"
DISABLED_POW_CYCLE_BASENAME = "blackcoin_pow_quarantine_cycle.v30.1.3-fee-capable.disabled"
DISABLED_POW_CYCLE_PATH = STATE_ROOT / DISABLED_POW_CYCLE_BASENAME
DISABLED_POW_CYCLE_SHA256 = "156acca0ed86fbeba008d9f87eb862aa2f93fc32f57ed2995d7dc05dcdb7312d"
UNRAID_DISK_ROOT = Path("/mnt/disk1")
UNRAID_SHARE_ROOT = UNRAID_DISK_ROOT / "blackcoin-wallet-safety"
RUNTIME_AUDITS_ROOT = UNRAID_SHARE_ROOT / "runtime-audits"
RUNS_ROOT = RUNTIME_AUDITS_ROOT / "normal-unlock-helper-rotation"
PACKAGE_DIR = Path(__file__).resolve().parent
PAYLOAD_HELPER = PACKAGE_DIR / "blackcoin_node_normal_unlock.sh"
PACKAGE_MANIFEST = PACKAGE_DIR / "SHA256SUMS"
PACKAGE_PAYLOADS = (
    "AUTHORITY.schema.json",
    "README.md",
    "VALIDATION.txt",
    "blackcoin_node_normal_unlock.sh",
    "helper_rotation.py",
    "tests/run.py",
)
HISTORICAL_JOB10_KIND = "historical-emergency-pos-renewal-one-shot"
FAILED_JOB10_RECEIPT_KIND = "failed-emergency-pos-renewal-job10-log"
FAILED_JOB10_RECEIPT_PATH = (
    RUNTIME_AUDITS_ROOT / "emergency-pos-renewal-20260814T034100Z.log"
)
FAILED_JOB10_RECEIPT_SHA256 = "23030a65f9b182534d82f6d67709b9cd088cbe6907bae56647d9780f9b9cf3cb"
AUTHORITY_KIND = "blackcoin-normal-unlock-helper-rotation-authority"
PLAN_KIND = "blackcoin-normal-unlock-helper-rotation-plan"
RESULT_KIND = "blackcoin-normal-unlock-helper-rotation-result"
BACKUP_KIND = "blackcoin-normal-unlock-helper-rotation-backup-manifest"
CONSUMPTION_KIND = "blackcoin-normal-unlock-helper-rotation-authority-consumption"
EXPECTED_NETWORK_VERSION = 300104
EXPECTED_SUBVERSION = "/Blackcoin:30.1.4/"
SHARED_LOCKS = (
    Path("/run/blackcoin-v3015-rollout.lock"),
    Path("/run/blackcoin-endpoint-guard.lock"),
    Path("/run/blackcoin-node-cutover.lock"),
    Path("/run/blackcoin-pow-quarantine-cycle.lock"),
    Path("/run/blackcoin-wallet-runtime-guard.lock"),
    Path("/run/blackcoin-normal-unlock-helper-rotation.lock"),
)
RUNTIME_LOCKS = tuple(Path(f"/run/blackcoin-node-{node:02d}-runtime.lock") for node in range(1, 33))
HELPER_ORDER = (30,) + tuple(range(1, 30)) + (31, 32)
VERIFICATION_ORDER = tuple(range(1, 33))
SKIPPED_STATE_DIRECTORIES = {
    "incident-journals",
    "runtime-wallet-manifests",
    "runtime-identity-manifests",
    "pow-wallet-manifests",
    "authority-history",
    "activation-staging",
}
HEX64 = re.compile(r"^[0-9a-f]{64}$")
HEX32 = re.compile(r"^[0-9a-f]{32}$")

# These are the complete semantic changes between the exact predecessor and
# successor supervisor identities above.  The surrounding full-file SHA256
# checks make each replacement an exact binary transform, not a fuzzy patch.
SUPERVISOR_REWRITES = (
    (
        f"readonly EXPECTED_HELPER_SHA256='{PREDECESSOR_HELPER_SHA256}'\n".encode(),
        (f"readonly EXPECTED_HELPER_SHA256='{SUCCESSOR_HELPER_SHA256}'\n"
         f"readonly HISTORICAL_JOB10_HELPER_SHA256='{PREDECESSOR_HELPER_SHA256}'\n").encode(),
    ),
    (
        b'    jq -e \\\n      --arg helper "$EXPECTED_HELPER_SHA256" \\\n',
        b'    jq -e \\\n      --arg helper "$HISTORICAL_JOB10_HELPER_SHA256" \\\n',
    ),
    (
        b'''renewal_helper_content_is_audited()
{
    local helper=$1 forbidden size lines
    bash -n "$helper" || return 1
    forbidden=$(grep -Eio '\\b(setstaking|setpowmining|getpowmininginfo|sendrawtransaction|createshadowpowclaimresolution|commitshadowpowclaimresolution|resolveshadowpowclaims|setpowclaimrecovery|getnewaddress|getnewquantumaddress|setpowminingaddress|sendtoaddress|sendmany|fundrawtransaction|signrawtransaction[^[:space:]]*|abandontransaction|resendwallettransactions|forcerelay|walletnotify|zmqpub(rawtx|hashtx|sequence)|eval|source)\\b' \\
        "$helper" | tr '[:upper:]' '[:lower:]' | sort -u || true)
    [[ -z "$forbidden" ]] || return 1
    [[ "$(grep -Eio '\\bwalletpassphrase\\b' "$helper" | wc -l | tr -d ' ')" == 1 &&
       "$(grep -Eio '\\blistwallets\\b' "$helper" | wc -l | tr -d ' ')" == 1 &&
       "$(grep -Eio '\\bgetwalletinfo\\b' "$helper" | wc -l | tr -d ' ')" == 2 &&
       "$(grep -Eio '\\bgetstakinginfo\\b' "$helper" | wc -l | tr -d ' ')" == 2 &&
       "$(grep -Eio '\\b(walletpassphrase|listwallets|getwalletinfo|getstakinginfo)\\b' \\
          "$helper" | wc -l | tr -d ' ')" == 6 ]] || return 1
    grep -Eq 'walletpassphrase.*[[:space:]]false([[:space:]]|$)' "$helper" || return 1
    size=$(stat -c '%s' -- "$helper" 2>/dev/null ||
      stat -f '%z' -- "$helper" 2>/dev/null) || return 1
    lines=$(wc -l <"$helper" | tr -d ' ') || return 1
    [[ "$size" == 3206 && "$lines" == 54 ]]
}
''',
        b'''renewal_helper_content_is_audited()
{
    local helper=$1 forbidden size lines
    [[ "$(renewal_sha256_file "$helper")" == "$EXPECTED_HELPER_SHA256" ]] || return 1
    bash -n "$helper" || return 1
    forbidden=$(grep -Eio '\\b(setstaking|setpowmining|getpowmininginfo|sendrawtransaction|createshadowpowclaimresolution|commitshadowpowclaimresolution|resolveshadowpowclaims|setpowclaimrecovery|getnewaddress|getnewquantumaddress|setpowminingaddress|sendtoaddress|sendmany|fundrawtransaction|signrawtransaction[^[:space:]]*|abandontransaction|resendwallettransactions|forcerelay|walletnotify|zmqpub(rawtx|hashtx|sequence)|eval|source)\\b' \\
        "$helper" | tr '[:upper:]' '[:lower:]' | sort -u || true)
    [[ -z "$forbidden" ]] || return 1
    [[ "$(grep -Eio '\\bwalletpassphrase\\b' "$helper" | wc -l | tr -d ' ')" == 1 &&
       "$(grep -Eio '\\blistwallets\\b' "$helper" | wc -l | tr -d ' ')" == 2 &&
       "$(grep -Eio '\\bgetwalletinfo\\b' "$helper" | wc -l | tr -d ' ')" == 1 &&
       "$(grep -Eio '\\bgetstakinginfo\\b' "$helper" | wc -l | tr -d ' ')" == 1 &&
       "$(grep -Eio '\\b(walletpassphrase|listwallets|getwalletinfo|getstakinginfo)\\b' \\
          "$helper" | wc -l | tr -d ' ')" == 5 ]] || return 1
    grep -Eq 'walletpassphrase.*[[:space:]]false([[:space:]]|$)' "$helper" || return 1
    # shellcheck disable=SC2016 # Exact literal source text is the audited contract.
    grep -Fq '[[ -z "$wallet" ]] || rpc_args+=("-rpcwallet=$wallet")' "$helper" || return 1
    # shellcheck disable=SC2016 # Exact literal source text is the audited contract.
    [[ "$(grep -Fc '[[ -z "$wallet" ]] || rpc_args+=("-rpcwallet=$wallet")' "$helper")" == 2 ]] ||
        return 1
    grep -Fq '^([1-9]|[12][0-9]|3[0-2])$' "$helper" || return 1
    size=$(stat -c '%s' -- "$helper" 2>/dev/null ||
      stat -f '%z' -- "$helper" 2>/dev/null) || return 1
    lines=$(wc -l <"$helper" | tr -d ' ') || return 1
    [[ "$size" == 4947 && "$lines" == 122 ]]
}
''',
    ),
)


class RotationError(RuntimeError):
    pass


def canonical_json_bytes(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def sha256_bytes(value):
    return hashlib.sha256(value).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fsync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_write(path, data, mode=0o600, replace=False, uid=None, gid=None):
    path = Path(path)
    temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}.{time.time_ns()}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(temporary, flags, mode)
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.fchmod(descriptor, mode)
        if uid is not None and gid is not None:
            os.fchown(descriptor, uid, gid)
    finally:
        os.close(descriptor)
    try:
        if replace:
            os.replace(temporary, path)
        else:
            os.link(temporary, path)
            os.unlink(temporary)
        fsync_directory(path.parent)
    except Exception:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        raise


def publish_json(path, value, uid=None, gid=None):
    data = canonical_json_bytes(value)
    atomic_write(path, data, 0o600, replace=False, uid=uid, gid=gid)
    sidecar = Path(str(path) + ".sha256")
    atomic_write(sidecar, (sha256_bytes(data) + "\n").encode(), 0o600, uid=uid, gid=gid)
    return sha256_bytes(data)


def secure_regular(path, expected_uid=0, modes=(0o600,), expected_sha=None):
    path = Path(path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise RotationError(f"not a single-linked regular file: {path}")
    if info.st_uid != expected_uid or stat.S_IMODE(info.st_mode) not in modes:
        raise RotationError(f"unsafe owner or mode: {path}")
    if expected_sha is not None and sha256_file(path) != expected_sha:
        raise RotationError(f"SHA256 mismatch: {path}")
    return info


def secure_directory(path, expected_uid=0, mode=0o700):
    info = Path(path).lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != expected_uid or stat.S_IMODE(info.st_mode) != mode:
        raise RotationError(f"unsafe directory: {path}")


def secure_ancestry(path, expected_uid=0):
    current = Path(path).resolve()
    if not current.is_dir():
        current = current.parent
    while True:
        info = current.lstat()
        if info.st_uid != expected_uid or stat.S_IMODE(info.st_mode) & 0o022:
            raise RotationError(f"writable or foreign ancestry: {current}")
        if current.parent == current:
            return
        current = current.parent


def secure_runtime_audit_ancestry(path, expected_uid=0, expected_gid=0,
                                  disk_root=UNRAID_DISK_ROOT, share_root=UNRAID_SHARE_ROOT,
                                  protected_root=RUNTIME_AUDITS_ROOT,
                                  share_uid=99, share_gid=100):
    """Validate the exact Unraid share boundary and root-only receipt subtree."""
    disk_root = Path(disk_root)
    share_root = Path(share_root)
    protected_root = Path(protected_root)
    candidate = Path(path)
    target = candidate if candidate.is_dir() else candidate.parent
    target_absolute = Path(os.path.abspath(target))
    try:
        target_resolved = target.resolve(strict=True)
        disk_resolved = disk_root.resolve(strict=True)
        share_resolved = share_root.resolve(strict=True)
        protected_resolved = protected_root.resolve(strict=True)
    except FileNotFoundError as error:
        raise RotationError(f"runtime-audit ancestry is absent: {error.filename}") from error
    if (disk_resolved != disk_root or share_resolved != share_root or
            protected_resolved != protected_root or target_resolved != target_absolute):
        raise RotationError("runtime-audit ancestry contains a symlink or noncanonical component")
    if share_root.parent != disk_root or protected_root.parent != share_root:
        raise RotationError("runtime-audit fixed roots are not nested exactly")
    if target_resolved != protected_root and protected_root not in target_resolved.parents:
        raise RotationError("runtime-audit path is outside the root-only protected subtree")
    if disk_root == UNRAID_DISK_ROOT:
        secure_ancestry(disk_root.parent, 0)

    records = []

    def exact_directory(directory, uid, gid, mode, role):
        info = directory.lstat()
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != uid or info.st_gid != gid or
                stat.S_IMODE(info.st_mode) != mode):
            raise RotationError(f"runtime-audit ancestry identity mismatch: {directory}")
        records.append({
            "role": role, "path": str(directory), "uid": info.st_uid, "gid": info.st_gid,
            "mode": format(stat.S_IMODE(info.st_mode), "04o"),
        })

    exact_directory(disk_root, share_uid, share_gid, 0o777, "unraid-disk-root")
    exact_directory(share_root, share_uid, share_gid, 0o777, "unraid-share-root")
    exact_directory(protected_root, expected_uid, expected_gid, 0o700, "protected-runtime-audits-root")
    relative = target_resolved.relative_to(protected_root)
    current = protected_root
    for component in relative.parts:
        current /= component
        exact_directory(current, expected_uid, expected_gid, 0o700, "protected-runtime-audit-descendant")
    return records


def verify_sidecar(path, expected_uid=0):
    sidecar = Path(str(path) + ".sha256")
    secure_regular(path, expected_uid)
    secure_regular(sidecar, expected_uid)
    expected = sidecar.read_text(encoding="ascii").strip()
    if not HEX64.fullmatch(expected) or expected != sha256_file(path):
        raise RotationError(f"invalid hash sidecar: {path}")
    return expected


def verify_package(package_dir=PACKAGE_DIR):
    package_dir = Path(package_dir).resolve()
    manifest = package_dir / "SHA256SUMS"
    listed = {}
    for line in manifest.read_text(encoding="ascii").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  [.]\/([^\s]+)", line)
        if not match or match.group(2) in listed:
            raise RotationError("malformed package manifest")
        listed[match.group(2)] = match.group(1)
    if tuple(sorted(listed)) != tuple(sorted(PACKAGE_PAYLOADS)):
        raise RotationError("package payload inventory mismatch")
    actual = tuple(sorted(str(path.relative_to(package_dir)) for path in package_dir.rglob("*")
                          if path.is_file() and path.name != "SHA256SUMS"))
    if actual != tuple(sorted(PACKAGE_PAYLOADS)):
        raise RotationError("package contains an unsealed file")
    for relative, expected in listed.items():
        path = package_dir / relative
        if path.is_symlink() or sha256_file(path) != expected:
            raise RotationError(f"package payload mismatch: {relative}")
    if sha256_file(package_dir / "blackcoin_node_normal_unlock.sh") != SUCCESSOR_HELPER_SHA256:
        raise RotationError("successor helper payload identity mismatch")
    return {
        "manifest_sha256": sha256_file(manifest),
        "tool_sha256": sha256_file(package_dir / "helper_rotation.py"),
        "helper_sha256": SUCCESSOR_HELPER_SHA256,
    }


def is_historical_job10(data):
    try:
        value = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return False
    return (
        isinstance(value, dict)
        and value.get("schema") == 1
        and value.get("kind") == HISTORICAL_JOB10_KIND
        and value.get("installed_or_executed_by_this_package") is False
        and value.get("historical_receipt_is_read_only") is True
        and value.get("preflight", {}).get("normal_unlock_helper_sha256") == PREDECESSOR_HELPER_SHA256
    )


def rotate_supervisor_bytes(data):
    if sha256_bytes(data) != PREDECESSOR_SUPERVISOR_SHA256:
        raise RotationError("supervisor predecessor identity mismatch")
    transformed = data
    for before, after in SUPERVISOR_REWRITES:
        if transformed.count(before) != 1:
            raise RotationError("supervisor semantic rewrite anchor is not unique")
        transformed = transformed.replace(before, after, 1)
    if sha256_bytes(transformed) != SUCCESSOR_SUPERVISOR_SHA256:
        raise RotationError("supervisor successor identity mismatch")
    return transformed


def rotate_active_pow_cycle_bytes(data):
    old = PREDECESSOR_HELPER_SHA256.encode()
    new = SUCCESSOR_HELPER_SHA256.encode()
    if sha256_bytes(data) != ACTIVE_POW_CYCLE_PREDECESSOR_SHA256:
        raise RotationError("active PoW-cycle predecessor identity mismatch")
    if data.count(old) != 1 or data.count(new) != 0:
        raise RotationError("active PoW-cycle helper pin is not the exact predecessor singleton")
    transformed = data.replace(old, new, 1)
    if sha256_bytes(transformed) != ACTIVE_POW_CYCLE_SUCCESSOR_SHA256:
        raise RotationError("active PoW-cycle successor identity mismatch")
    return transformed


def file_record(path, info):
    return {
        "path": str(path),
        "sha256": sha256_file(path),
        "uid": info.st_uid,
        "gid": info.st_gid,
        "mode": format(stat.S_IMODE(info.st_mode), "04o"),
        "nlink": info.st_nlink,
    }


def scan_plan(state_root=STATE_ROOT, helper_path=HELPER_PATH, expected_uid=0,
              audit_run_dir=None, expected_gid=None, audit_ancestry_kwargs=None,
              failed_job10_receipt_path=None, failed_job10_ancestry_kwargs=None):
    state_root = Path(state_root).resolve()
    helper_path = Path(helper_path).resolve()
    secure_directory(state_root, expected_uid, 0o700)
    helper_info = secure_regular(helper_path, expected_uid, (0o600,))
    helper_sha = sha256_file(helper_path)
    active = []
    current = []
    historical = []
    immutable_historical = []
    unsupported = []
    if expected_gid is not None and helper_info.st_gid != expected_gid:
        unsupported.append({
            "path": str(helper_path), "reason": "helper-GID-mismatch",
            "sha256": helper_sha, "gid": helper_info.st_gid,
        })
    old = PREDECESSOR_HELPER_SHA256.encode()
    new = SUCCESSOR_HELPER_SHA256.encode()
    helper_name = b"blackcoin_node_normal_unlock.sh"

    for root, directories, files in os.walk(state_root, topdown=True, followlinks=False):
        directories[:] = sorted(name for name in directories if name not in SKIPPED_STATE_DIRECTORIES)
        for filename in sorted(files):
            path = Path(root) / filename
            if path == helper_path:
                continue
            try:
                info = path.lstat()
            except FileNotFoundError:
                raise RotationError(f"scan raced with file removal: {path}")
            if not stat.S_ISREG(info.st_mode):
                if path.name in {
                    "blackcoin_node_normal_unlock.sh", SUPERVISOR_BASENAME,
                    ACTIVE_POW_CYCLE_BASENAME, DISABLED_POW_CYCLE_BASENAME,
                }:
                    unsupported.append({"path": str(path), "reason": "relevant-nonregular-path"})
                continue
            with open(path, "rb") as handle:
                data = handle.read()
            old_count = data.count(old)
            new_count = data.count(new)
            file_sha = sha256_bytes(data)
            relevant_named_path = path in {
                state_root / ACTIVE_POW_CYCLE_BASENAME,
                state_root / DISABLED_POW_CYCLE_BASENAME,
            }
            if (old_count == 0 and new_count == 0 and path.name != SUPERVISOR_BASENAME and
                    not relevant_named_path):
                continue
            record = file_record(path, info)
            record.update({"old_pin_occurrences": old_count, "new_pin_occurrences": new_count})
            if path == state_root / DISABLED_POW_CYCLE_BASENAME:
                if (file_sha != DISABLED_POW_CYCLE_SHA256 or old_count != 1 or new_count != 0 or
                        info.st_uid != expected_uid or
                        (expected_gid is not None and info.st_gid != expected_gid) or info.st_nlink != 1 or
                        stat.S_IMODE(info.st_mode) != 0o600):
                    record["reason"] = "disabled-historical-PoW-cycle-identity-mismatch"
                    unsupported.append(record)
                else:
                    record.update({
                        "historical_kind": "disabled-v30.1.3-fee-capable-PoW-cycle",
                        "immutable": True,
                    })
                    immutable_historical.append(record)
            elif path == state_root / ACTIVE_POW_CYCLE_BASENAME:
                if file_sha == ACTIVE_POW_CYCLE_PREDECESSOR_SHA256:
                    if (old_count != 1 or new_count != 0 or helper_name not in data or b"\x00" in data or
                            info.st_uid != expected_uid or
                            (expected_gid is not None and info.st_gid != expected_gid) or info.st_nlink != 1 or
                            stat.S_IMODE(info.st_mode) != 0o600):
                        record["reason"] = "active-PoW-cycle-is-not-the-exact-secure-predecessor"
                        unsupported.append(record)
                        continue
                    replaced = rotate_active_pow_cycle_bytes(data)
                    record.update({
                        "after_sha256": sha256_bytes(replaced),
                        "replacement_kind": "exact-single-helper-pin-substitution",
                        "replacement_occurrences": 1,
                        "preserves_historical_helper_identity": False,
                    })
                    active.append(record)
                elif file_sha == ACTIVE_POW_CYCLE_SUCCESSOR_SHA256:
                    if (old_count != 0 or new_count != 1 or info.st_uid != expected_uid or
                            (expected_gid is not None and info.st_gid != expected_gid) or
                            info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600):
                        record["reason"] = "active-PoW-cycle-successor-identity-mismatch"
                        unsupported.append(record)
                    else:
                        record["state"] = "successor-pinned"
                        record["preserves_historical_helper_identity"] = False
                        current.append(record)
                else:
                    record["reason"] = "active-PoW-cycle-identity-mismatch"
                    unsupported.append(record)
            elif old_count and is_historical_job10(data):
                if (old_count != 1 or info.st_uid != expected_uid or
                        (expected_gid is not None and info.st_gid != expected_gid) or
                        info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600):
                    record["reason"] = "historical-job10-identity-mismatch"
                    unsupported.append(record)
                else:
                    record["historical_kind"] = HISTORICAL_JOB10_KIND
                    historical.append(record)
            elif path.name == SUPERVISOR_BASENAME and file_sha == PREDECESSOR_SUPERVISOR_SHA256:
                if (helper_name not in data or b"\x00" in data or info.st_uid != expected_uid or
                        (expected_gid is not None and info.st_gid != expected_gid)
                        or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) not in (0o600, 0o700)):
                    record["reason"] = "predecessor-supervisor-is-not-a-secure-active-consumer"
                    unsupported.append(record)
                    continue
                replaced = rotate_supervisor_bytes(data)
                record.update({
                    "after_sha256": sha256_bytes(replaced),
                    "replacement_kind": "exact-supervisor-semantic-transform",
                    "replacement_occurrences": len(SUPERVISOR_REWRITES),
                    "preserves_historical_helper_identity": True,
                })
                active.append(record)
            elif path.name == SUPERVISOR_BASENAME and file_sha == SUCCESSOR_SUPERVISOR_SHA256:
                record["state"] = "successor-pinned"
                record["preserves_historical_helper_identity"] = True
                current.append(record)
            else:
                record["reason"] = "unrecognized-helper-pin-reference"
                unsupported.append(record)

    if failed_job10_receipt_path is not None:
        receipt_path = Path(os.path.abspath(failed_job10_receipt_path))
        try:
            receipt_info = receipt_path.lstat()
        except FileNotFoundError:
            receipt_record = {
                "path": str(receipt_path), "reason": "failed-job10-receipt-absent",
            }
            unsupported.append(receipt_record)
        else:
            receipt_gid = os.getgid() if expected_gid is None else expected_gid
            if not stat.S_ISREG(receipt_info.st_mode):
                receipt_record = {
                    "path": str(receipt_path), "uid": receipt_info.st_uid,
                    "gid": receipt_info.st_gid,
                    "mode": format(stat.S_IMODE(receipt_info.st_mode), "04o"),
                    "nlink": receipt_info.st_nlink,
                    "reason": "failed-job10-receipt-identity-mismatch",
                }
                unsupported.append(receipt_record)
                receipt_record = None
            else:
                receipt_record = file_record(receipt_path, receipt_info)
            if receipt_record is None:
                pass
            elif (receipt_path != FAILED_JOB10_RECEIPT_PATH or
                    receipt_record["sha256"] != FAILED_JOB10_RECEIPT_SHA256 or
                    receipt_info.st_uid != expected_uid or
                    receipt_info.st_gid != receipt_gid or receipt_info.st_nlink != 1 or
                    stat.S_IMODE(receipt_info.st_mode) != 0o600):
                receipt_record["reason"] = "failed-job10-receipt-identity-mismatch"
                unsupported.append(receipt_record)
            else:
                try:
                    receipt_ancestry_kwargs = (
                        {} if failed_job10_ancestry_kwargs is None
                        else dict(failed_job10_ancestry_kwargs)
                    )
                    receipt_ancestry = secure_runtime_audit_ancestry(
                        receipt_path, expected_uid, receipt_gid, **receipt_ancestry_kwargs,
                    )
                except RotationError:
                    receipt_record["reason"] = "failed-job10-receipt-ancestry-mismatch"
                    unsupported.append(receipt_record)
                else:
                    receipt_record.update({
                        "historical_kind": FAILED_JOB10_RECEIPT_KIND,
                        "immutable": True,
                        "runtime_audit_ancestry": receipt_ancestry,
                    })
                    historical.append(receipt_record)

    state = "READY" if helper_sha == PREDECESSOR_HELPER_SHA256 and not unsupported else "BLOCKED"
    if helper_sha == SUCCESSOR_HELPER_SHA256 and not active and not unsupported:
        state = "ALREADY_INSTALLED"
    if helper_sha not in (PREDECESSOR_HELPER_SHA256, SUCCESSOR_HELPER_SHA256):
        unsupported.append({"path": str(helper_path), "reason": "unknown-helper-identity", "sha256": helper_sha})
        state = "BLOCKED"
    if helper_sha == SUCCESSOR_HELPER_SHA256 and active:
        unsupported.append({"path": str(helper_path), "reason": "successor-helper-with-predecessor-consumers"})
        state = "BLOCKED"

    plan = {
        "schema": SCHEMA,
        "kind": PLAN_KIND,
        "state": state,
        "tooling_parent_commit": TOOLING_PARENT_COMMIT,
        "state_root": str(state_root),
        "helper": {
            **file_record(helper_path, helper_info),
            "expected_predecessor_sha256": PREDECESSOR_HELPER_SHA256,
            "successor_sha256": SUCCESSOR_HELPER_SHA256,
        },
        "active_consumers": sorted(active, key=lambda row: row["path"]),
        "successor_consumers": sorted(current, key=lambda row: row["path"]),
        "historical_job10_refs": sorted(historical, key=lambda row: row["path"]),
        "immutable_historical_refs": sorted(immutable_historical, key=lambda row: row["path"]),
        "unsupported_refs": sorted(unsupported, key=lambda row: row["path"]),
        "mutation_order": (
            [row["path"] for row in sorted(active, key=lambda row: row["path"])] + [str(helper_path)]
        ),
        "helper_order": list(HELPER_ORDER),
        "verification_order": list(VERIFICATION_ORDER),
        "historical_job10_immutable": True,
        "disabled_pow_cycle_immutable": True,
        "ordinary_pow_mutation_forbidden": True,
        "core_deployment_forbidden": True,
    }
    if audit_run_dir is not None:
        ancestry_kwargs = {} if audit_ancestry_kwargs is None else dict(audit_ancestry_kwargs)
        plan["runtime_audit_ancestry"] = secure_runtime_audit_ancestry(
            audit_run_dir, expected_uid, os.getgid() if expected_gid is None else expected_gid,
            **ancestry_kwargs,
        )
    return plan


def authority_projection(plan):
    return {
        "active_consumers": [
            {
                "path": row["path"],
                "before_sha256": row["sha256"],
                "after_sha256": row["after_sha256"],
                "replacement_occurrences": row["replacement_occurrences"],
                "replacement_kind": row["replacement_kind"],
                "preserves_historical_helper_identity": row["preserves_historical_helper_identity"],
            }
            for row in plan["active_consumers"]
        ],
        "historical_job10_refs": [
            {"path": row["path"], "sha256": row["sha256"],
             "historical_kind": row["historical_kind"]}
            for row in plan["historical_job10_refs"]
        ],
        "immutable_historical_refs": [
            {"path": row["path"], "sha256": row["sha256"],
             "historical_kind": row["historical_kind"]}
            for row in plan["immutable_historical_refs"]
        ],
    }


def authority_template(plan, plan_sha, package):
    projection = authority_projection(plan)
    return {
        "schema": SCHEMA,
        "kind": AUTHORITY_KIND,
        "state": "NOT_AUTHORIZED",
        "authority_nonce": "0" * 32,
        "authorization_context_sha256": "0" * 64,
        "authorization_scope": "install-normal-unlock-helper-and-renew-pos-only",
        "issued_at_epoch": 0,
        "expires_at_epoch": 0,
        "tooling_parent_commit": TOOLING_PARENT_COMMIT,
        "package_manifest_sha256": package["manifest_sha256"],
        "tool_sha256": package["tool_sha256"],
        "plan_sha256": plan_sha,
        "predecessor_helper_sha256": PREDECESSOR_HELPER_SHA256,
        "successor_helper_sha256": SUCCESSOR_HELPER_SHA256,
        "install_path": str(HELPER_PATH),
        "maximum_active_consumers": len(projection["active_consumers"]),
        **projection,
        "live_helper_rotation_authorized": False,
        "active_consumer_rotation_authorized": False,
        "normal_unlock_node30_canary_authorized": False,
        "normal_unlock_fleet_authorized": False,
        "rollback_authorized": False,
        "backup_required": True,
        "atomic_replace_required": True,
        "historical_job10_immutable": True,
        "disabled_pow_cycle_immutable": True,
        "node30_ordinary_pow_must_remain_disabled": True,
        "regular_pow_policy_must_remain_unchanged": True,
        "helper_order": list(HELPER_ORDER),
        "verification_order": list(VERIFICATION_ORDER),
    }


def validate_authority(authority, plan, plan_sha, package, now=None):
    expected_keys = set(authority_template(plan, plan_sha, package))
    if not isinstance(authority, dict) or set(authority) != expected_keys:
        raise RotationError("authority schema keys are not exact")
    now = int(time.time()) if now is None else int(now)
    template = authority_template(plan, plan_sha, package)
    fixed = {
        key: value for key, value in template.items()
        if key not in {
            "state", "authority_nonce", "authorization_context_sha256",
            "issued_at_epoch", "expires_at_epoch", "live_helper_rotation_authorized",
            "active_consumer_rotation_authorized", "normal_unlock_node30_canary_authorized",
            "normal_unlock_fleet_authorized", "rollback_authorized",
        }
    }
    for key, value in fixed.items():
        if authority.get(key) != value:
            raise RotationError(f"authority does not bind {key}")
    if authority["state"] != "authorized":
        raise RotationError("authority is not live-authorized")
    if not HEX32.fullmatch(str(authority["authority_nonce"])) or authority["authority_nonce"] == "0" * 32:
        raise RotationError("authority nonce is invalid")
    context = str(authority["authorization_context_sha256"])
    if not HEX64.fullmatch(context) or context == "0" * 64:
        raise RotationError("authorization context is invalid")
    issued = authority["issued_at_epoch"]
    expires = authority["expires_at_epoch"]
    if (not isinstance(issued, int) or not isinstance(expires, int) or
            issued > now + 300 or now < issued or now >= expires or expires - issued > 3600):
        raise RotationError("authority time window is invalid")
    for key in (
        "live_helper_rotation_authorized", "active_consumer_rotation_authorized",
        "normal_unlock_node30_canary_authorized", "normal_unlock_fleet_authorized",
        "rollback_authorized",
    ):
        if authority[key] is not True:
            raise RotationError(f"authority boolean is false: {key}")
    return True


class LockSet:
    def __init__(self, paths, expected_uid=0):
        self.paths = tuple(Path(path) for path in paths)
        self.expected_uid = expected_uid
        self.handles = []

    def acquire(self):
        for path in self.paths:
            flags = os.O_RDWR | os.O_CREAT
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            descriptor = os.open(path, flags, 0o600)
            info = os.fstat(descriptor)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != self.expected_uid or
                    stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
                os.close(descriptor)
                self.release()
                raise RotationError(f"unsafe lock identity: {path}")
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                os.close(descriptor)
                self.release()
                raise RotationError(f"lock is busy: {path}")
            self.handles.append(descriptor)
        return self

    def release(self):
        for descriptor in reversed(self.handles):
            try:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            finally:
                os.close(descriptor)
        self.handles = []

    def __enter__(self):
        return self.acquire()

    def __exit__(self, _kind, _value, _traceback):
        self.release()


def container_for_node(node):
    if node < 1 or node > 32:
        raise RotationError("node outside fleet")
    return "blackcoin-v4-gui" if node == 1 else f"blackcoin-v4-gui-{node}"


def wallet_rpc_argv(container, wallet, method, *arguments, stdin=False):
    argv = ["/usr/bin/docker", "exec"]
    if stdin:
        argv.append("-i")
    argv.extend([container, "/usr/local/bin/blackcoin-cli", "-datadir=/home/blackcoin/.blackcoin"])
    if wallet:
        argv.append(f"-rpcwallet={wallet}")
    argv.extend([method, *[str(value) for value in arguments]])
    return argv


class DockerRuntime:
    def __init__(self, state_root=STATE_ROOT, helper_path=HELPER_PATH):
        self.state_root = Path(state_root)
        self.helper_path = Path(helper_path)

    @staticmethod
    def call(argv, timeout=35):
        result = subprocess.run(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, timeout=timeout, check=False,
            env={"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                 "LC_ALL": "C", "TZ": "UTC"},
        )
        if result.returncode != 0:
            raise RotationError(f"bounded command failed: {argv[0]} {argv[1] if len(argv) > 1 else ''}")
        return result.stdout

    def rpc(self, node, wallet, method, *arguments):
        return json.loads(self.call(wallet_rpc_argv(container_for_node(node), wallet, method, *arguments)))

    def capture(self, node):
        padded = f"{node:02d}"
        manifest = self.state_root / "runtime-wallet-manifests" / f"node-{padded}.json"
        secure_regular(manifest, 0, (0o600,))
        wallets_expected = json.loads(manifest.read_text(encoding="utf-8"))
        if (not isinstance(wallets_expected, list) or len(wallets_expected) != 1 or
                not isinstance(wallets_expected[0], str)):
            raise RotationError(f"wallet manifest invalid for node {node}")
        wallet = wallets_expected[0]
        container = container_for_node(node)
        inspect = json.loads(self.call(["/usr/bin/docker", "inspect", container]))
        if (not isinstance(inspect, list) or len(inspect) != 1 or
                inspect[0].get("State", {}).get("Running") is not True or
                inspect[0].get("State", {}).get("Health", {}).get("Status") != "healthy"):
            raise RotationError(f"container is not healthy for node {node}")
        chain_before = self.rpc(node, "", "getblockchaininfo")
        network = self.rpc(node, "", "getnetworkinfo")
        wallets_live = self.rpc(node, "", "listwallets")
        wallet_info = self.rpc(node, wallet, "getwalletinfo")
        staking = self.rpc(node, wallet, "getstakinginfo")
        pow_info = self.rpc(node, wallet, "getpowmininginfo")
        quantum = self.rpc(node, wallet, "getquantumkeyinventory")
        chain_after = self.rpc(node, "", "getblockchaininfo")
        chain_keys = ("chain", "blocks", "headers", "bestblockhash", "chainwork", "initialblockdownload")
        before_cut = {key: chain_before.get(key) for key in chain_keys}
        after_cut = {key: chain_after.get(key) for key in chain_keys}
        if before_cut != after_cut:
            raise RotationError(f"mixed chain cut for node {node}")
        if (before_cut["chain"] != "main" or before_cut["initialblockdownload"] is not False or
                before_cut["blocks"] != before_cut["headers"] or network.get("connections", 0) < 1 or
                wallets_live != wallets_expected):
            raise RotationError(f"node preflight failed for node {node}")
        if (network.get("version") != EXPECTED_NETWORK_VERSION or
                network.get("subversion") != EXPECTED_SUBVERSION):
            raise RotationError(f"installed runtime identity changed for node {node}")
        pow_projection = {
            key: pow_info.get(key) for key in (
                "enabled", "autostart", "threads", "cpu_percent", "payout_address",
                "allow_automatic_quantum_key_creation", "state", "claim_quarantined",
                "blocking_quarantined_claims", "pending_manual_resolutions",
            )
        }
        if node == 30:
            if pow_info.get("enabled") is not False or float(pow_info.get("hashrate", 0)) != 0:
                raise RotationError("node30 ordinary PoW role changed")
        elif pow_info.get("enabled") is not True:
            raise RotationError(f"regular PoW intent is disabled for node {node}")
        return {
            "node": node,
            "container": container,
            "wallet_selector_sha256": sha256_bytes(wallet.encode()),
            "wallet_unnamed": wallet == "",
            "chain": before_cut,
            "network_version": network.get("version"),
            "subversion": network.get("subversion"),
            "connections": network.get("connections"),
            "unlocked_until": wallet_info.get("unlocked_until", 0),
            "unlocked_staking_only": wallet_info.get("unlocked_staking_only"),
            "wallet_scanning": wallet_info.get("scanning", False),
            "pos_enabled": staking.get("enabled"),
            "pos_staking": staking.get("staking"),
            "pos_weight": staking.get("weight", 0),
            "pow_policy": pow_projection,
            "pow_hashrate": pow_info.get("hashrate", 0),
            "quantum_inventory_sha256": sha256_bytes(canonical_json_bytes(quantum)),
        }

    def invoke_helper(self, node):
        result = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", str(self.helper_path), str(node)],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=240, check=False,
            env={"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                 "LC_ALL": "C", "TZ": "UTC"},
        )
        if result.returncode != 0:
            raise RotationError(f"normal-unlock helper failed for node {node}")
        return {
            "node": node,
            "exit_code": result.returncode,
            "stdout_sha256": sha256_bytes(result.stdout),
            "stderr_sha256": sha256_bytes(result.stderr),
        }


def verify_after(before, after, now):
    if before["node"] != after["node"]:
        raise RotationError("node identity changed")
    for key in ("container", "wallet_selector_sha256", "wallet_unnamed", "pow_policy", "quantum_inventory_sha256"):
        if before[key] != after[key]:
            raise RotationError(f"protected runtime projection changed for node {before['node']}: {key}")
    if (after["unlocked_staking_only"] is not False or after["unlocked_until"] <= now + 43200 or
            after["wallet_scanning"] is not False or
            after["pos_enabled"] is not True or after["pos_staking"] is not True or
            float(after["pos_weight"]) <= 0):
        raise RotationError(f"normal unlock or PoS did not converge for node {before['node']}")
    if before["node"] == 30 and (after["pow_policy"]["enabled"] is not False or float(after["pow_hashrate"]) != 0):
        raise RotationError("node30 ordinary PoW escaped during canary")


def replacement_bytes(row):
    path = Path(row["path"])
    data = path.read_bytes()
    if sha256_bytes(data) != row["sha256"]:
        raise RotationError(f"consumer changed before replacement: {path}")
    replacement_kind = row.get("replacement_kind")
    if replacement_kind == "exact-supervisor-semantic-transform":
        replaced = rotate_supervisor_bytes(data)
    elif replacement_kind == "exact-single-helper-pin-substitution":
        if path != ACTIVE_POW_CYCLE_PATH:
            # Unit fixtures use a custom state root but retain the exact basename.
            if path.name != ACTIVE_POW_CYCLE_BASENAME:
                raise RotationError(f"active PoW-cycle replacement path is unsupported: {path}")
        replaced = rotate_active_pow_cycle_bytes(data)
    else:
        raise RotationError(f"consumer replacement kind is unsupported: {path}")
    if sha256_bytes(replaced) != row["after_sha256"]:
        raise RotationError(f"consumer replacement plan mismatch: {path}")
    return replaced


def make_backup_manifest(plan, run_dir, expected_uid=0):
    backup_dir = Path(run_dir) / "backups"
    backup_dir.mkdir(mode=0o700)
    paths = [Path(row["path"]) for row in plan["active_consumers"]] + [Path(plan["helper"]["path"])]
    rows = []
    for index, path in enumerate(paths):
        info = secure_regular(path, expected_uid, (0o600, 0o700))
        data = path.read_bytes()
        name = f"{index:03d}-{sha256_bytes(str(path).encode())}.bin"
        output = backup_dir / name
        atomic_write(output, data, 0o600, uid=expected_uid, gid=info.st_gid)
        rows.append({
            "path": str(path), "backup": str(output), "sha256": sha256_bytes(data),
            "mode": format(stat.S_IMODE(info.st_mode), "04o"), "uid": info.st_uid, "gid": info.st_gid,
        })
    manifest = {"schema": SCHEMA, "kind": BACKUP_KIND, "files": rows}
    publish_json(Path(run_dir) / "BACKUP-MANIFEST.json", manifest, expected_uid, os.getgid())
    return manifest


def apply_files(plan, payload_helper, changed, expected_uid=0):
    for row in plan["active_consumers"]:
        path = Path(row["path"])
        info = secure_regular(path, expected_uid, (0o600, 0o700), row["sha256"])
        if info.st_gid != row["gid"] or format(stat.S_IMODE(info.st_mode), "04o") != row["mode"]:
            raise RotationError(f"consumer security identity changed before replacement: {path}")
        atomic_write(path, replacement_bytes(row), stat.S_IMODE(info.st_mode), replace=True,
                     uid=info.st_uid, gid=info.st_gid)
        changed.append(str(path))
        if sha256_file(path) != row["after_sha256"]:
            raise RotationError(f"consumer post-install mismatch: {path}")
    helper_path = Path(plan["helper"]["path"])
    info = secure_regular(helper_path, expected_uid, (0o600,), PREDECESSOR_HELPER_SHA256)
    if info.st_gid != plan["helper"]["gid"]:
        raise RotationError("helper security identity changed before replacement")
    secure_regular(payload_helper, expected_uid, (0o600, 0o644), SUCCESSOR_HELPER_SHA256)
    atomic_write(helper_path, Path(payload_helper).read_bytes(), 0o600, replace=True,
                 uid=info.st_uid, gid=info.st_gid)
    changed.append(str(helper_path))
    if sha256_file(helper_path) != SUCCESSOR_HELPER_SHA256:
        raise RotationError("helper post-install mismatch")
    return None


def verify_historical(plan, expected_uid=0, expected_gid=0,
                      failed_job10_ancestry_kwargs=None):
    for row in plan["historical_job10_refs"]:
        path = Path(row["path"])
        info = secure_regular(path, expected_uid, (0o600,), row["sha256"])
        kind = row.get("historical_kind")
        if kind == HISTORICAL_JOB10_KIND:
            valid_kind = is_historical_job10(path.read_bytes())
        elif kind == FAILED_JOB10_RECEIPT_KIND:
            valid_kind = (
                path == FAILED_JOB10_RECEIPT_PATH and
                row["sha256"] == FAILED_JOB10_RECEIPT_SHA256
            )
            if valid_kind:
                ancestry_kwargs = (
                    {} if failed_job10_ancestry_kwargs is None
                    else dict(failed_job10_ancestry_kwargs)
                )
                secure_runtime_audit_ancestry(
                    path, expected_uid, expected_gid, **ancestry_kwargs,
                )
        else:
            valid_kind = False
        if info.st_gid != expected_gid or not valid_kind:
            raise RotationError(f"historical job10 evidence changed: {path}")
    for row in plan["immutable_historical_refs"]:
        path = Path(row["path"])
        info = secure_regular(path, expected_uid, (0o600,), row["sha256"])
        if (path != Path(plan["state_root"]) / DISABLED_POW_CYCLE_BASENAME or
                info.st_gid != expected_gid or row.get("historical_kind") !=
                "disabled-v30.1.3-fee-capable-PoW-cycle" or
                row["sha256"] != DISABLED_POW_CYCLE_SHA256 or
                path.read_bytes().count(PREDECESSOR_HELPER_SHA256.encode()) != 1):
            raise RotationError(f"immutable disabled PoW-cycle evidence changed: {path}")


def rollback_files(backup_manifest, expected_uid=0):
    restored = []
    for row in reversed(backup_manifest["files"]):
        path = Path(row["path"])
        backup = Path(row["backup"])
        secure_regular(backup, expected_uid, (0o600,), row["sha256"])
        atomic_write(path, backup.read_bytes(), int(row["mode"], 8), replace=True,
                     uid=row["uid"], gid=row["gid"])
        if sha256_file(path) != row["sha256"]:
            raise RotationError(f"rollback verification failed: {path}")
        restored.append(str(path))
    return restored


def execute_transaction(plan, runtime, run_dir, runtime_locks, lock_factory,
                        bindings, payload_helper=PAYLOAD_HELPER, expected_uid=0,
                        now_function=time.time):
    run_dir = Path(run_dir)
    before = {}
    attempts = []
    changed = []
    backup_manifest = None
    try:
        for node in VERIFICATION_ORDER:
            before[node] = runtime.capture(node)
        backup_manifest = make_backup_manifest(plan, run_dir, expected_uid)
        apply_files(plan, payload_helper, changed, expected_uid)
        verify_historical(plan, expected_uid, os.getgid())
        # All files are now coherently replaced while every node runtime lock is
        # held.  Release the fleet locks before invoking the helper because the
        # helper obtains the matching per-node lock itself.
        runtime_locks.release()
        for node in HELPER_ORDER:
            attempt = {"node": node, "status": "STARTED", "started_at_epoch": int(now_function())}
            attempts.append(attempt)
            try:
                helper_result = runtime.invoke_helper(node)
            except Exception:
                attempt["status"] = "FAILED"
                attempt["finished_at_epoch"] = int(now_function())
                raise
            attempt.update(helper_result)
            attempt["status"] = "PASS"
            attempt["finished_at_epoch"] = int(now_function())
            with lock_factory((RUNTIME_LOCKS[node - 1],)):
                after = runtime.capture(node)
                verify_after(before[node], after, int(now_function()))
        # Freeze every runtime again for one coherent terminal fleet cut.
        runtime_locks.acquire()
        final = []
        for node in VERIFICATION_ORDER:
            after = runtime.capture(node)
            verify_after(before[node], after, int(now_function()))
            final.append(after)
        helper_path = Path(plan["helper"]["path"])
        helper_info = secure_regular(helper_path, expected_uid, (0o600,), SUCCESSOR_HELPER_SHA256)
        if helper_info.st_gid != plan["helper"]["gid"]:
            raise RotationError("successor helper drifted before terminal receipt")
        for row in plan["active_consumers"]:
            path = Path(row["path"])
            info = secure_regular(path, expected_uid, (int(row["mode"], 8),), row["after_sha256"])
            if info.st_gid != row["gid"]:
                raise RotationError(f"active consumer drifted before terminal receipt: {row['path']}")
        verify_historical(plan, expected_uid, os.getgid())
        result = {
            "schema": SCHEMA, "kind": RESULT_KIND, "status": "PASS",
            "predecessor_helper_sha256": PREDECESSOR_HELPER_SHA256,
            "successor_helper_sha256": SUCCESSOR_HELPER_SHA256,
            "changed_paths": changed, "helper_attempts": attempts,
            "helper_order": list(HELPER_ORDER), "verification_order": list(VERIFICATION_ORDER),
            "node30_canary_first": True, "all_nodes_normally_unlocked_pos_active": True,
            "node30_ordinary_pow_disabled": True, "regular_pow_policy_unchanged": True,
            "historical_job10_unchanged": True,
            "immutable_historical_refs_unchanged": True,
            "immutable_historical_ref_count": len(plan["immutable_historical_refs"]),
            "preflight_sha256": sha256_bytes(canonical_json_bytes(list(before.values()))),
            "postflight_sha256": sha256_bytes(canonical_json_bytes(final)),
            "rollback_performed": False,
            **bindings,
        }
        publish_json(run_dir / "RESULT.json", result, expected_uid, os.getgid())
        return result
    except Exception as error:
        rollback = {"performed": False, "restored_paths": [], "error": None}
        if backup_manifest is not None and changed:
            try:
                if not runtime_locks.handles:
                    runtime_locks.acquire()
                rollback["restored_paths"] = rollback_files(backup_manifest, expected_uid)
                verify_historical(plan, expected_uid, os.getgid())
                rollback["performed"] = True
            except Exception as rollback_error:
                rollback["error"] = str(rollback_error)
        failure = {
            "schema": SCHEMA, "kind": RESULT_KIND, "status": "ROLLED_BACK" if rollback["performed"] else "FAILED",
            "error": str(error), "changed_paths": changed,
            "helper_attempted_nodes": [row["node"] for row in attempts],
            "rollback": rollback,
            "historical_job10_unchanged": not changed or rollback["performed"],
            "immutable_historical_refs_unchanged": not changed or rollback["performed"],
            **bindings,
        }
        publish_json(run_dir / "FAILURE.json", failure, expected_uid, os.getgid())
        raise RotationError(str(error))


def create_run_dir(run_dir, expected_uid=0):
    run_dir = Path(run_dir)
    if run_dir.exists() or run_dir.is_symlink():
        raise RotationError("run directory already exists")
    if run_dir.parent.resolve() != RUNS_ROOT.resolve():
        raise RotationError("run directory is outside the fixed audit root")
    secure_directory(RUNS_ROOT, expected_uid, 0o700)
    secure_runtime_audit_ancestry(RUNS_ROOT, expected_uid, os.getgid())
    run_dir.mkdir(mode=0o700)
    os.chown(run_dir, expected_uid, os.getgid())
    fsync_directory(run_dir.parent)
    secure_runtime_audit_ancestry(run_dir, expected_uid, os.getgid())
    return run_dir


def command_audit(arguments):
    if os.geteuid() != 0:
        raise RotationError("audit requires root")
    package = verify_package()
    run_dir = create_run_dir(arguments.run_dir)
    plan = scan_plan(
        audit_run_dir=run_dir, expected_gid=os.getgid(),
        failed_job10_receipt_path=FAILED_JOB10_RECEIPT_PATH,
    )
    plan_sha = publish_json(run_dir / "PLAN.json", plan, 0, os.getgid())
    template = authority_template(plan, plan_sha, package)
    publish_json(run_dir / "AUTHORITY.template.json", template, 0, os.getgid())
    audit = {
        "schema": SCHEMA, "kind": "blackcoin-normal-unlock-helper-rotation-audit",
        "status": plan["state"], "captured_at_epoch": int(time.time()),
        "plan_sha256": plan_sha, **package,
        "active_consumer_count": len(plan["active_consumers"]),
        "historical_job10_ref_count": len(plan["historical_job10_refs"]),
        "immutable_historical_ref_count": len(plan["immutable_historical_refs"]),
        "unsupported_ref_count": len(plan["unsupported_refs"]),
        "live_contact": False, "wallet_contact": False, "docker_contact": False,
    }
    audit_sha = publish_json(run_dir / "AUDIT.json", audit, 0, os.getgid())
    print(json.dumps({"result": plan["state"], "audit_sha256": audit_sha, "plan_sha256": plan_sha}, sort_keys=True))
    return 0 if plan["state"] in ("READY", "ALREADY_INSTALLED") else 2


def load_json_file(path, expected_uid=0):
    secure_regular(path, expected_uid, (0o600,))
    return json.loads(Path(path).read_text(encoding="utf-8"))


def command_install(arguments):
    if os.geteuid() != 0:
        raise RotationError("install requires root")
    package = verify_package()
    run_dir = Path(arguments.run_dir).resolve()
    secure_directory(run_dir, 0, 0o700)
    secure_runtime_audit_ancestry(run_dir, 0, os.getgid())
    plan_path = run_dir / "PLAN.json"
    plan_sha = verify_sidecar(plan_path, 0)
    plan = load_json_file(plan_path, 0)
    if plan.get("state") != "READY":
        raise RotationError("saved plan is not mutation-ready")
    authority_path = Path(arguments.authority).resolve()
    if authority_path != run_dir / "AUTHORITY.json":
        raise RotationError("authority must be the fixed run-local AUTHORITY.json")
    secure_runtime_audit_ancestry(authority_path, 0, os.getgid())
    authority_sha = verify_sidecar(authority_path, 0)
    authority = load_json_file(authority_path, 0)
    validate_authority(authority, plan, plan_sha, package)
    for terminal in ("AUTHORITY-CONSUMED.json", "RESULT.json", "FAILURE.json", "TERMINAL.json"):
        if (run_dir / terminal).exists() or (run_dir / f"{terminal}.sha256").exists():
            raise RotationError("run authority is already consumed or terminal")

    shared = LockSet(SHARED_LOCKS, 0).acquire()
    runtime_locks = None
    try:
        runtime_locks = LockSet(RUNTIME_LOCKS, 0).acquire()
        current = scan_plan(
            audit_run_dir=run_dir, expected_gid=os.getgid(),
            failed_job10_receipt_path=FAILED_JOB10_RECEIPT_PATH,
        )
        if canonical_json_bytes(current) != canonical_json_bytes(plan):
            raise RotationError("live consumer/helper plan drifted after authority")
        consumption = {
            "schema": SCHEMA,
            "kind": CONSUMPTION_KIND,
            "consumed_at_epoch": int(time.time()),
            "authority_sha256": authority_sha,
            "authority_nonce": authority["authority_nonce"],
            "authorization_context_sha256": authority["authorization_context_sha256"],
            "plan_sha256": plan_sha,
            "package_manifest_sha256": package["manifest_sha256"],
            "tool_sha256": package["tool_sha256"],
            "predecessor_helper_sha256": PREDECESSOR_HELPER_SHA256,
            "successor_helper_sha256": SUCCESSOR_HELPER_SHA256,
        }
        publish_json(run_dir / "AUTHORITY-CONSUMED.json", consumption, 0, os.getgid())
        bindings = {
            "authority_sha256": authority_sha,
            "authority_consumption_sha256": sha256_file(run_dir / "AUTHORITY-CONSUMED.json"),
            "plan_sha256": plan_sha,
            "package_manifest_sha256": package["manifest_sha256"],
            "tool_sha256": package["tool_sha256"],
        }
        runtime = DockerRuntime()
        result = execute_transaction(
            plan, runtime, run_dir, runtime_locks, lambda paths: LockSet(paths, 0),
            bindings, PAYLOAD_HELPER, 0,
        )
        # Publish a second immutable, authority-bound terminal pointer.  RESULT
        # remains the complete receipt and both objects are hash-sidecar sealed.
        publish_json(run_dir / "TERMINAL.json", result, 0, os.getgid())
        print(json.dumps({"result": "PASS", "terminal_sha256": sha256_file(run_dir / "TERMINAL.json")}, sort_keys=True))
        return 0
    except Exception:
        # If file mutation failed, execute_transaction already attempted byte rollback.
        raise
    finally:
        if runtime_locks is not None:
            runtime_locks.release()
        shared.release()


def command_verify(arguments):
    run_dir = Path(arguments.run_dir).resolve()
    secure_directory(run_dir, os.geteuid(), 0o700)
    secure_runtime_audit_ancestry(run_dir, os.geteuid(), os.getegid())
    for name in ("AUDIT.json", "PLAN.json", "AUTHORITY.template.json"):
        verify_sidecar(run_dir / name, os.geteuid())
    optional = [
        name for name in (
            "AUTHORITY.json", "AUTHORITY-CONSUMED.json", "BACKUP-MANIFEST.json",
            "RESULT.json", "TERMINAL.json", "FAILURE.json",
        )
        if (run_dir / name).exists()
    ]
    for name in optional:
        verify_sidecar(run_dir / name, os.geteuid())
    success = (run_dir / "RESULT.json").exists() or (run_dir / "TERMINAL.json").exists()
    failure = (run_dir / "FAILURE.json").exists()
    if success and failure:
        raise RotationError("run has contradictory terminal receipts")
    if success:
        if not ((run_dir / "RESULT.json").exists() and (run_dir / "TERMINAL.json").exists()):
            raise RotationError("success terminal receipt pair is incomplete")
        if (run_dir / "RESULT.json").read_bytes() != (run_dir / "TERMINAL.json").read_bytes():
            raise RotationError("success terminal receipts disagree")
    if success or failure:
        for required in ("AUTHORITY.json", "AUTHORITY-CONSUMED.json"):
            if not (run_dir / required).exists():
                raise RotationError(f"terminal run is missing {required}")
    if success and not (run_dir / "BACKUP-MANIFEST.json").exists():
        raise RotationError("successful run is missing BACKUP-MANIFEST.json")
    if failure:
        failure_receipt = load_json_file(run_dir / "FAILURE.json", os.geteuid())
        changed_paths = failure_receipt.get("changed_paths")
        if not isinstance(changed_paths, list):
            raise RotationError("failure receipt changed_paths is invalid")
        if changed_paths and not (run_dir / "BACKUP-MANIFEST.json").exists():
            raise RotationError("mutating failure is missing BACKUP-MANIFEST.json")
    if (run_dir / "BACKUP-MANIFEST.json").exists():
        backup = load_json_file(run_dir / "BACKUP-MANIFEST.json", os.geteuid())
        if (backup.get("schema") != SCHEMA or backup.get("kind") != BACKUP_KIND or
                not isinstance(backup.get("files"), list)):
            raise RotationError("backup manifest shape is invalid")
        for row in backup["files"]:
            secure_regular(row["backup"], os.geteuid(), (0o600,), row["sha256"])
    terminal = "TERMINAL.json" if success else "FAILURE.json" if failure else None
    print(json.dumps({"result": "VERIFIED", "terminal": terminal}, sort_keys=True))
    return 0


def parse_arguments():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    audit = commands.add_parser("audit")
    audit.add_argument("--run-dir", required=True)
    install = commands.add_parser("install")
    install.add_argument("--run-dir", required=True)
    install.add_argument("--authority", required=True)
    verify = commands.add_parser("verify")
    verify.add_argument("--run-dir", required=True)
    return parser.parse_args()


def main():
    arguments = parse_arguments()
    if arguments.command == "audit":
        return command_audit(arguments)
    if arguments.command == "install":
        return command_install(arguments)
    return command_verify(arguments)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RotationError, OSError, ValueError, json.JSONDecodeError, subprocess.TimeoutExpired) as error:
        print(f"normal-unlock helper rotation: {error}", file=sys.stderr)
        sys.exit(1)
