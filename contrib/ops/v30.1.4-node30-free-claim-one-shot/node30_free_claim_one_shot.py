#!/usr/bin/python3
"""Fail-closed one-shot Free-Claim submission for installed node30 v30.1.4.

The recurring worker and ordinary PoW stay disabled.  The only wallet-mutating
RPC in this package is one exact sendshadowpowclaim call after a separately
reviewed owner-only authority.  An unknown response consumes the authority and
is reconciled read-only; it is never retried.
"""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import time
from decimal import Decimal, InvalidOperation
from typing import Any, NoReturn, Sequence


CONTRACT = "installed-v30.1.4-node30-free-claim-one-shot/v1"
RECEIPT_SCHEMA = 1
SOURCE_COMMIT = "13262151077cce3f72d07d17dc7725b2b6a8e1ab"
SOURCE_TREE = "a6f7757c34b70fab841905765462d6769112d049"
SOURCE_SIGNER = "SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70"
NODE = 30
FEE_RATE_ATOMS_PER_VBYTE = 100
MAX_TRIES = 2_000_000
EXPECTED_VSIZE = 287
FEE_CAP = Decimal("0.00028700")
ZERO = Decimal("0.00000000")
SNAPSHOT_ATTEMPTS = 3
USER_ORDERS = [
    "we need to be POW mining as well, and we need to have claims submitted so POW and POS quantum payouts can continue",
    "fix all of the quarantined issues even if you have to pay a small fee to fix it on each node. all issues must be resolved",
    "you need to expedite POW and POS mining online for all nodes NOW. remove safeguards if necessary we must start mining/staking ASAP on my order",
]
PRODUCTION_ROOT = pathlib.Path("/mnt/pulsar/Blackcoin_Blocks/operations/free-claim-pool")
PRODUCTION_STORAGE_PROTECTED_ROOT = pathlib.Path(
    "/mnt/pulsar/Blackcoin_Blocks/operations")
PULSAR_SHARE_DIRECTORIES = [
    (pathlib.Path("/mnt/pulsar"), 99, 100, 0o777),
    (pathlib.Path("/mnt/pulsar/Blackcoin_Blocks"), 99, 100, 0o777),
]
PRODUCTION_PYTHON = pathlib.Path(
    "/mnt/user/appdata/projectblackcoin-ops-runtime/"
    "cpython-3.12.13-20260510/python/bin/python3.12")
PRODUCTION_CONTROLLER_ROOT = pathlib.Path(
    "/mnt/user/appdata/projectblackcoin-ops-runtime")
PRODUCTION_PYTHON_SHA256 = "202c17d1671602a4ef1d43e9b2fdbef0769443f37bf5e51f6b603e0b2c27d9d8"
PRODUCTION_PYTHON_SIZE = 30_846_632
PRODUCTION_ENVIRONMENT = {
    "HOME": "/root", "PATH": "/usr/bin:/bin", "LC_ALL": "C", "TZ": "UTC",
}
UNRAID_SHARE_DIRECTORIES = [
    (pathlib.Path("/mnt/user"), 99, 100, 0o777),
    (pathlib.Path("/mnt/user/appdata"), 99, 100, 0o777),
]
CONTROLLER_RUNTIME_IDENTITY: dict[str, Any] | None = None
HEX64 = re.compile(r"^[0-9a-f]{64}$")
QUEUE_NAME = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}[.]json$")
P2PKH_SCRIPT = re.compile(r"^76a914[0-9a-f]{40}88ac$")
Q16_SCRIPT = re.compile(r"^6020[0-9a-f]{64}$")
QQ_PREFIX = b"QQSPROOF"
QQP2_MAGIC = b"QQP2"

NODE30_PRIMITIVE_RELATIVE = pathlib.Path(
    "../v30.1.4-node30-retained-claim-recovery/node30_recovery.py")
NODE30_PRIMITIVE_SHA256 = "41c4bbc7d0aa6a3e21715937abda13f9ece879cfb34c4517cf87a6dd3835f605"
TEST_TRANSPORT_SHA256 = "35d226faefab894793bbf211d1f8ff9dc15be9730dad21174407c53f82348381"


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb", buffering=0) as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def sha256_json(value: Any) -> str:
    return hashlib.sha256(canonical_json(value)).hexdigest()


USER_ORDER_SHA256 = sha256_json(USER_ORDERS)


def load_node30_primitive() -> Any:
    path = (pathlib.Path(__file__).resolve(strict=True).parent /
            NODE30_PRIMITIVE_RELATIVE).resolve(strict=True)
    if sha256_file(path) != NODE30_PRIMITIVE_SHA256:
        raise RuntimeError("hash-pinned node30 fleet primitive changed")
    spec = importlib.util.spec_from_file_location("node30_free_claim_primitive", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load hash-pinned node30 fleet primitive")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


try:
    node30 = load_node30_primitive()
except (OSError, RuntimeError) as exc:
    print(f"FATAL: {exc}", file=sys.stderr)
    raise SystemExit(1)

# Tests use a separate, hash-pinned transport that models only this package.
# Live execution ignores this constant and remains pinned by the runtime
# manifest's exact /usr/bin/docker digest.
node30.base.TEST_TRANSPORT_SHA256 = TEST_TRANSPORT_SHA256


class GateError(node30.GateError):
    pass


class Transport(node30.Transport):
    """Exact RPC surface for the one-shot; all unlisted methods fail closed."""

    EXTRA_ALLOWED = {
        "validateaddress", "getaddressinfo", "listunspent", "getgoldrushinfo",
        "getshadowpowwork", "listtransactions", "sendshadowpowclaim",
        "decoderawtransaction", "gettxspendingprevout", "getshadowscript",
    }

    def rpc(self, node: Any, method: str, *params: Any) -> Any:
        if method not in self.EXTRA_ALLOWED:
            return super().rpc(node, method, *params)
        cli_args = ["exec", node.container, self.runtime.cli_path,
                    f"-datadir={self.runtime.datadir}"]
        if node.wallet:
            cli_args.append(f"-rpcwallet={node.wallet}")
        cli_args.append(method)
        for param in params:
            if isinstance(param, (dict, list)):
                cli_args.append(json.dumps(param, sort_keys=True, separators=(",", ":")))
            elif isinstance(param, bool):
                cli_args.append("true" if param else "false")
            else:
                cli_args.append(str(param))
        try:
            timeout = 900 if method == "sendshadowpowclaim" else 90
            return json.loads(self.run(cli_args, timeout=timeout))
        except (node30.base.GateError, json.JSONDecodeError) as exc:
            raise node30.base.RpcError(node.node, method, str(exc)) from exc


def die(message: str) -> NoReturn:
    raise GateError(message)


def require_hex64(value: Any, label: str) -> str:
    if not isinstance(value, str) or not HEX64.fullmatch(value):
        die(f"{label} is not a lowercase 32-byte hex identity")
    return value


def decimal_amount(value: Any, label: str) -> Decimal:
    try:
        parsed = Decimal(str(value))
        amount = parsed.quantize(Decimal("0.00000001"))
    except (InvalidOperation, ValueError, TypeError) as exc:
        die(f"{label} is not an exact eight-decimal amount: {exc}")
    if not parsed.is_finite() or parsed != amount:
        die(f"{label} has precision beyond eight decimal places")
    if amount < ZERO:
        die(f"{label} is negative")
    return amount


def test_mode() -> bool:
    return bool(os.environ.get("FLEET31_TEST_TRANSPORT"))


def exact_directory_identity(path: pathlib.Path, label: str, expected_uid: int,
                             expected_gid: int, expected_mode: int,
                             expected_nlink: int | None = None) -> dict[str, Any]:
    """Return one exact canonical directory identity or fail closed."""
    st = path.lstat()
    if (not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode) or
            path.resolve(strict=True) != path or st.st_uid != expected_uid or
            st.st_gid != expected_gid or stat.S_IMODE(st.st_mode) != expected_mode or
            (expected_nlink is not None and st.st_nlink != expected_nlink)):
        die(f"{label} does not have its exact canonical directory identity")
    return {"path": str(path), "device": st.st_dev, "inode": st.st_ino,
            "uid": st.st_uid, "gid": st.st_gid,
            "mode": format(stat.S_IMODE(st.st_mode), "04o"), "nlink": st.st_nlink}


def safe_prefix_identity(path: pathlib.Path, label: str) -> dict[str, Any]:
    st = path.lstat()
    if (not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode) or
            path.resolve(strict=True) != path or st.st_uid != 0 or st.st_mode & 0o022):
        die(f"{label} is not a canonical root-controlled prefix")
    return {"path": str(path), "device": st.st_dev, "inode": st.st_ino,
            "uid": st.st_uid, "gid": st.st_gid,
            "mode": format(stat.S_IMODE(st.st_mode), "04o"), "nlink": st.st_nlink}


def stable_directory_identities(prior: list[dict[str, Any]],
                                current: list[dict[str, Any]], label: str) -> None:
    if prior != current:
        die(f"{label} directory identity changed during validation")


def exact_controller_binary_identity(executable: pathlib.Path) -> dict[str, Any]:
    """Hash the exact opened executable and prove the pathname stayed bound."""
    try:
        before = executable.lstat()
        resolved = executable.resolve(strict=True)
        digest = hashlib.sha256()
        with executable.open("rb", buffering=0) as handle:
            opened = os.fstat(handle.fileno())
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        after = executable.lstat()
    except FileNotFoundError:
        die("audited controller interpreter is absent")
    identity_fields = ("st_dev", "st_ino", "st_uid", "st_gid", "st_mode",
                       "st_nlink", "st_size")
    if (executable != PRODUCTION_PYTHON or resolved != executable or
            not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode) or
            before.st_nlink != 1 or before.st_uid != 0 or before.st_gid != 0 or
            stat.S_IMODE(before.st_mode) != 0o700 or
            before.st_size != PRODUCTION_PYTHON_SIZE or
            digest.hexdigest() != PRODUCTION_PYTHON_SHA256 or
            any(getattr(before, field) != getattr(opened, field) or
                getattr(before, field) != getattr(after, field)
                for field in identity_fields)):
        die("live controller interpreter differs from the exact audited Python binary")
    return {"path": str(executable), "device": after.st_dev, "inode": after.st_ino,
            "uid": after.st_uid, "gid": after.st_gid, "mode": "0700",
            "nlink": after.st_nlink, "size": after.st_size,
            "sha256": PRODUCTION_PYTHON_SHA256, "version": "3.12.13"}


def validate_controller_runtime() -> dict[str, Any]:
    """Bind live execution to the audited Unraid-hosted isolated interpreter."""
    executable = pathlib.Path(sys.executable)
    binary_before = exact_controller_binary_identity(executable)
    protected_paths: list[pathlib.Path] = []
    parent = executable.parent
    while parent != PRODUCTION_CONTROLLER_ROOT:
        if parent == parent.parent:
            die("controller interpreter is outside the exact protected subtree")
        protected_paths.append(parent)
        parent = parent.parent
    protected_paths.append(PRODUCTION_CONTROLLER_ROOT)
    protected_paths.reverse()
    safe_before = [safe_prefix_identity(path, f"controller prefix {path}")
                   for path in [pathlib.Path("/"), pathlib.Path("/mnt")]]
    share_before = [exact_directory_identity(path, f"Unraid share {path}", uid, gid, mode)
                    for path, uid, gid, mode in UNRAID_SHARE_DIRECTORIES]
    protected_before = [exact_directory_identity(
        path, f"protected controller subtree {path}", 0, 0, 0o700, 1)
        for path in protected_paths]
    flags = sys.flags
    if (sys.implementation.name != "cpython" or sys.version_info[:3] != (3, 12, 13) or
            flags.isolated != 1 or flags.ignore_environment != 1 or
            flags.no_user_site != 1 or getattr(flags, "safe_path", False) is not True or
            dict(os.environ) != PRODUCTION_ENVIRONMENT):
        die("live controller is not the exact isolated Python 3.12.13 environment")
    safe_after = [safe_prefix_identity(path, f"controller prefix {path}")
                  for path in [pathlib.Path("/"), pathlib.Path("/mnt")]]
    share_after = [exact_directory_identity(path, f"Unraid share {path}", uid, gid, mode)
                   for path, uid, gid, mode in UNRAID_SHARE_DIRECTORIES]
    protected_after = [exact_directory_identity(
        path, f"protected controller subtree {path}", 0, 0, 0o700, 1)
        for path in protected_paths]
    stable_directory_identities(safe_before, safe_after, "controller prefix")
    stable_directory_identities(share_before, share_after, "Unraid share")
    stable_directory_identities(protected_before, protected_after,
                                "protected controller subtree")
    binary_after = exact_controller_binary_identity(executable)
    if binary_before != binary_after:
        die("controller interpreter identity changed during validation")
    return {
        "contract": "unraid-protected-cpython-controller/v1",
        "safe_prefix": safe_after, "unraid_share_ancestry": share_after,
        "protected_subtree": protected_after,
        "binary": binary_after,
        "isolation": {"isolated": 1, "ignore_environment": 1,
                      "no_user_site": 1, "safe_path": True,
                      "environment": PRODUCTION_ENVIRONMENT},
    }


def controller_runtime_identity() -> dict[str, Any]:
    if test_mode():
        return {"contract": "hash-pinned-offline-test-controller/v1",
                "test_transport_sha256": TEST_TRANSPORT_SHA256}
    if CONTROLLER_RUNTIME_IDENTITY is None:
        die("live controller identity was not established")
    return CONTROLLER_RUNTIME_IDENTITY


@dataclasses.dataclass(frozen=True)
class Contract:
    raw: dict[str, Any]
    sha256: str
    path: pathlib.Path
    retained: Any
    root: pathlib.Path
    queue_dir: pathlib.Path
    done_dir: pathlib.Path
    awarded_file: pathlib.Path
    pool_group_gid: int
    storage_identity: dict[str, Any]


def secure_dir(path: pathlib.Path, label: str, expected_mode: int,
               expected_gid: int) -> os.stat_result:
    if not path.is_absolute():
        die(f"{label} path is not absolute")
    try:
        st = path.lstat()
    except FileNotFoundError:
        die(f"{label} is absent")
    expected_uid = os.geteuid() if test_mode() else 0
    if (not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode) or
            path.resolve(strict=True) != path or st.st_uid != expected_uid or
            st.st_gid != expected_gid or stat.S_IMODE(st.st_mode) != expected_mode):
        die(f"{label} is not the exact canonical owner/group/mode directory")
    return st


def validate_free_claim_storage(root: pathlib.Path) -> dict[str, Any]:
    """Bind the exact Unraid share ancestry and protected operations root."""
    if test_mode():
        anchor = exact_directory_identity(
            root.parent, "offline Free-Claim fixture anchor", os.geteuid(), os.getegid(), 0o700)
        # Stateful fixtures add owner-only child directories to their private
        # anchor; bind its path/device/inode/owner/mode, not that test-only
        # directory link count. Production identities retain their live nlink.
        del anchor["nlink"]
        return {"contract": "offline-fixture-free-claim-storage/v1",
                "fixture_anchor": anchor}
    if root != PRODUCTION_ROOT or root.parent != PRODUCTION_STORAGE_PROTECTED_ROOT:
        die("live Free-Claim root is outside the exact protected operations subtree")
    safe_before = [safe_prefix_identity(path, f"Free-Claim storage prefix {path}")
                   for path in [pathlib.Path("/"), pathlib.Path("/mnt")]]
    share_before = [exact_directory_identity(
        path, f"Pulsar share {path}", uid, gid, mode)
        for path, uid, gid, mode in PULSAR_SHARE_DIRECTORIES]
    protected_before = [exact_directory_identity(
        PRODUCTION_STORAGE_PROTECTED_ROOT, "protected Free-Claim operations root",
        0, 0, 0o700)]
    safe_after = [safe_prefix_identity(path, f"Free-Claim storage prefix {path}")
                  for path in [pathlib.Path("/"), pathlib.Path("/mnt")]]
    share_after = [exact_directory_identity(
        path, f"Pulsar share {path}", uid, gid, mode)
        for path, uid, gid, mode in PULSAR_SHARE_DIRECTORIES]
    protected_after = [exact_directory_identity(
        PRODUCTION_STORAGE_PROTECTED_ROOT, "protected Free-Claim operations root",
        0, 0, 0o700)]
    stable_directory_identities(safe_before, safe_after, "Free-Claim storage prefix")
    stable_directory_identities(share_before, share_after, "Pulsar share")
    stable_directory_identities(protected_before, protected_after,
                                "protected Free-Claim operations root")
    return {"contract": "unraid-protected-free-claim-storage/v1",
            "safe_prefix": safe_after, "pulsar_share_ancestry": share_after,
            "protected_operations_root": protected_after[0]}


def current_free_claim_storage(contract: Contract) -> dict[str, Any]:
    current = validate_free_claim_storage(contract.root)
    if current != contract.storage_identity:
        die("Free-Claim storage ancestry changed after manifest validation")
    return current


def secure_state_file(path: pathlib.Path, label: str, modes: set[int]) -> tuple[bytes, os.stat_result]:
    if not path.is_absolute() or path.parent.resolve(strict=True) != path.parent:
        die(f"{label} path is not canonical")
    try:
        st = path.lstat()
    except FileNotFoundError:
        die(f"{label} is absent")
    if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_nlink != 1 or
            st.st_uid != os.geteuid() or stat.S_IMODE(st.st_mode) not in modes or
            path.resolve(strict=True) != path):
        die(f"{label} is not a unique owner-controlled regular file")
    with path.open("rb", buffering=0) as handle:
        data = handle.read()
        opened = os.fstat(handle.fileno())
    if opened.st_dev != st.st_dev or opened.st_ino != st.st_ino:
        die(f"{label} changed while it was read")
    return data, st


def validate_manifest(path: pathlib.Path, expected_hash: str | None = None) -> Contract:
    retained = node30.validate_manifest(path, expected_hash)
    raw = retained.raw
    if raw.get("one_shot_contract") != CONTRACT:
        die("runtime manifest does not opt into this exact one-shot contract")
    required = ["free_claim_root", "queue_dir", "done_dir", "awarded_file"]
    for key in required:
        if not isinstance(raw.get(key), str) or not raw[key].startswith("/"):
            die(f"runtime manifest {key} must be an absolute path")
    gid = raw.get("pool_group_gid")
    if type(gid) is not int or gid < 0:
        die("runtime manifest pool_group_gid is invalid")
    root = pathlib.Path(raw["free_claim_root"])
    queue_dir = pathlib.Path(raw["queue_dir"])
    done_dir = pathlib.Path(raw["done_dir"])
    awarded_file = pathlib.Path(raw["awarded_file"])
    if (queue_dir != root / "queue" or done_dir != root / "done" or
            awarded_file != root / "awarded.txt"):
        die("runtime manifest Free-Claim state paths are not exact children")
    if not test_mode() and root != PRODUCTION_ROOT:
        die("live Free-Claim root differs from the reviewed production path")
    storage_identity = validate_free_claim_storage(root)
    return Contract(raw, retained.sha256, path, retained, root, queue_dir, done_dir,
                    awarded_file, gid, storage_identity)


def tool_sha() -> str:
    return sha256_file(pathlib.Path(__file__).resolve(strict=True))


def base_receipt(kind: str, contract: Contract) -> dict[str, Any]:
    storage = current_free_claim_storage(contract)
    return {
        "schema": RECEIPT_SCHEMA,
        "contract": CONTRACT,
        "kind": kind,
        "tool_sha256": tool_sha(),
        "node30_primitive_sha256": NODE30_PRIMITIVE_SHA256,
        "controller_runtime_sha256": sha256_json(controller_runtime_identity()),
        "controller_runtime": controller_runtime_identity(),
        "free_claim_storage_sha256": sha256_json(storage),
        "free_claim_storage": storage,
        "runtime_manifest_sha256": contract.sha256,
        "installed_source": {"commit": SOURCE_COMMIT, "tree": SOURCE_TREE,
                             "signer_fingerprint": SOURCE_SIGNER},
        "node": NODE,
        "role": "free_claim",
        "ordinary_pow_must_remain_disabled": True,
        "pos_must_remain_active": True,
        "pause_marker_must_remain_present": True,
        "recurring_worker_authorized": False,
        "fee_rate_atoms_per_vbyte": FEE_RATE_ATOMS_PER_VBYTE,
        "maximum_fee_blk": f"{FEE_CAP:.8f}",
        "maximum_tries": MAX_TRIES,
        "user_orders": USER_ORDERS,
        "user_order_sha256": USER_ORDER_SHA256,
    }


def validate_common(receipt: Any, kind: str, contract: Contract) -> dict[str, Any]:
    expected = base_receipt(kind, contract)
    if not isinstance(receipt, dict):
        die(f"{kind} receipt is not an object")
    for key, value in expected.items():
        if receipt.get(key) != value:
            die(f"{kind} receipt field {key} differs from the exact contract")
    return receipt


def load_contract(run_dir: pathlib.Path) -> Contract:
    _, digest = node30.load_run_receipt(run_dir, "runtime-manifest.json")
    return validate_manifest(run_dir / "runtime-manifest.json", digest)


def queue_names(basename: str) -> dict[str, str]:
    if not QUEUE_NAME.fullmatch(basename):
        die("queue item basename is not canonical")
    stem = basename[:-5]
    return {
        "queued": basename,
        "broadcast": stem + ".broadcast",
        "uncertain": stem + ".uncertain.json",
        "confirmed": stem + ".confirmed.json",
    }


def awarded_snapshot(contract: Contract, expected_sha: str | None = None) -> dict[str, Any]:
    data, st = secure_state_file(contract.awarded_file, "awarded ledger", {0o640})
    if st.st_gid != contract.pool_group_gid:
        die("awarded ledger group differs from the runtime contract")
    digest = hashlib.sha256(data).hexdigest()
    if expected_sha is not None and digest != expected_sha:
        die("awarded ledger SHA256 changed")
    try:
        text = data.decode("utf-8", "strict")
    except UnicodeDecodeError as exc:
        die(f"awarded ledger is not UTF-8: {exc}")
    if "\r" in text or "\x00" in text or (text and not text.endswith("\n")):
        die("awarded ledger has a noncanonical line encoding")
    lines = text.splitlines()
    if any(not line or any(ch.isspace() for ch in line) for line in lines):
        die("awarded ledger contains an empty or whitespace-bearing record")
    if len(lines) != len(set(lines)):
        die("awarded ledger contains duplicate payout identities")
    return {"path": str(contract.awarded_file), "sha256": digest, "size": len(data),
            "mode": "0640", "gid": st.st_gid, "record_count": len(lines),
            "records": lines}


def immutable_queue_item_identity(item: Any) -> dict[str, Any]:
    keys = ["sha256", "size", "device", "inode", "uid", "gid", "mode", "nlink",
            "record"]
    if not isinstance(item, dict) or any(key not in item for key in keys):
        die("Free-Claim queue item identity is incomplete")
    return {key: item[key] for key in keys}


def queue_file_snapshot(path: pathlib.Path, contract: Contract, label: str,
                        expected_sha: str | None = None,
                        expected_identity: dict[str, Any] | None = None
                        ) -> tuple[dict[str, Any], bytes]:
    data, st = secure_state_file(path, label, {0o644})
    expected_gid = os.getegid() if test_mode() else 0
    if st.st_gid != expected_gid:
        die(f"{label} is not owned by the exact queue-entry group")
    digest = hashlib.sha256(data).hexdigest()
    if expected_sha is not None and digest != expected_sha:
        die(f"{label} SHA256 changed")
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        die(f"{label} is not valid JSON: {exc}")
    if (not isinstance(value, dict) or set(value) !=
            {"attempts", "ip", "quantum_address", "submitted"} or
            type(value.get("attempts")) is not int or not 1 <= value["attempts"] < 20 or
            not isinstance(value.get("ip"), str) or not value["ip"] or
            not isinstance(value.get("submitted"), str) or not value["submitted"] or
            not isinstance(value.get("quantum_address"), str) or not value["quantum_address"]):
        die(f"{label} has an unexpected schema")
    snapshot = {"path": str(path), "basename": path.name, "sha256": digest,
                "size": len(data), "device": st.st_dev, "inode": st.st_ino,
                "uid": st.st_uid, "gid": st.st_gid, "mode": "0644",
                "nlink": st.st_nlink, "record": value}
    if (expected_identity is not None and
            immutable_queue_item_identity(snapshot) !=
            immutable_queue_item_identity(expected_identity)):
        die(f"{label} immutable identity changed")
    return snapshot, data


def audit_queue(contract: Contract) -> dict[str, Any]:
    storage_before = current_free_claim_storage(contract)
    root_st = secure_dir(contract.root, "Free-Claim root", 0o750,
                         contract.pool_group_gid)
    queue_st = secure_dir(contract.queue_dir, "Free-Claim queue", 0o770,
                          contract.pool_group_gid)
    done_st = secure_dir(contract.done_dir, "Free-Claim done directory", 0o750,
                         contract.pool_group_gid)
    if queue_st.st_dev != done_st.st_dev:
        die("queue and done directories are not on one atomic-rename filesystem")
    entries = sorted(contract.queue_dir.iterdir(), key=lambda item: item.name)
    if len(entries) != 1 or not QUEUE_NAME.fullmatch(entries[0].name):
        die("Free-Claim queue must contain exactly one canonical JSON item")
    item, _ = queue_file_snapshot(entries[0], contract, "queued Free-Claim item")
    names = queue_names(entries[0].name)
    done_entries = sorted(contract.done_dir.iterdir(), key=lambda item: item.name)
    for entry in done_entries:
        data, st = secure_state_file(entry, f"done entry {entry.name}", {0o600, 0o640, 0o644})
        del data
        if st.st_gid not in {contract.pool_group_gid, os.getegid()}:
            die(f"done entry {entry.name} has an unexpected group")
    if any(entry.name.endswith(".broadcast") for entry in done_entries):
        die("Free-Claim done directory already has a broadcast marker")
    if any((contract.done_dir / names[state]).exists() for state in
           ["broadcast", "uncertain", "confirmed"]):
        die("one-shot queue outcome path already exists")
    awarded = awarded_snapshot(contract)
    qaddr = item["record"]["quantum_address"]
    if qaddr in awarded["records"]:
        die("queued quantum payout is already in the awarded ledger")
    for path, label, mode, prior in [
            (contract.root, "Free-Claim root", 0o750, root_st),
            (contract.queue_dir, "Free-Claim queue", 0o770, queue_st),
            (contract.done_dir, "Free-Claim done directory", 0o750, done_st)]:
        current = secure_dir(path, label, mode, contract.pool_group_gid)
        if (current.st_dev != prior.st_dev or current.st_ino != prior.st_ino):
            die(f"{label} changed while its state was audited")
    queue_file_snapshot(entries[0], contract, "queued Free-Claim item", item["sha256"], item)
    if current_free_claim_storage(contract) != storage_before:
        die("Free-Claim storage ancestry changed while its state was audited")
    return {"root": {"path": str(contract.root), "device": root_st.st_dev,
                     "inode": root_st.st_ino, "uid": root_st.st_uid,
                     "gid": root_st.st_gid, "mode": "0750"},
            "queue_directory": {"path": str(contract.queue_dir), "device": queue_st.st_dev,
                                "inode": queue_st.st_ino, "uid": queue_st.st_uid,
                                "gid": queue_st.st_gid, "mode": "0770"},
            "done_directory": {"path": str(contract.done_dir), "device": done_st.st_dev,
                               "inode": done_st.st_ino, "uid": done_st.st_uid,
                               "gid": done_st.st_gid, "mode": "0750"},
            "item": item, "outcome_names": names,
            "existing_done_entries": [entry.name for entry in done_entries],
            "broadcast_marker_count": 0, "awarded": awarded}


def exact_txids(rows: Any, label: str) -> list[str]:
    if not isinstance(rows, list):
        die(f"{label} is not an array")
    result: set[str] = set()
    for row in rows:
        if not isinstance(row, dict):
            die(f"{label} contains a non-object")
        txid = row.get("txid")
        if not isinstance(txid, str) or not HEX64.fullmatch(txid):
            die(f"{label} contains an invalid txid")
        result.add(txid)
    return sorted(result)


def wallet_txids(transport: Any, node: Any) -> list[str]:
    return exact_txids(transport.rpc(node, "listtransactions", "*", 1_000_000, 0, True),
                       "node30 wallet transaction inventory")


def validate_payout_address(transport: Any, node: Any, address: str) -> dict[str, Any]:
    valid = transport.rpc(node, "validateaddress", address)
    wallet = transport.rpc(node, "getaddressinfo", address)
    if (not isinstance(valid, dict) or valid.get("isvalid") is not True or
            valid.get("address") != address or valid.get("iswitness") is not True or
            valid.get("witness_version") != 16 or
            not isinstance(valid.get("witness_program"), str) or
            not re.fullmatch(r"[0-9a-f]{64}", valid["witness_program"]) or
            not isinstance(valid.get("scriptPubKey"), str) or
            not Q16_SCRIPT.fullmatch(valid["scriptPubKey"]) or
            valid["scriptPubKey"] != "6020" + valid["witness_program"]):
        die("queued payout is not the exact direct witness-v16 shape")
    if (not isinstance(wallet, dict) or wallet.get("address") != address or
            wallet.get("scriptPubKey") != valid["scriptPubKey"] or
            type(wallet.get("ismine")) is not bool or type(wallet.get("iswatchonly")) is not bool):
        die("queued payout wallet/address projection is incoherent")
    return {"address": address, "scriptPubKey": valid["scriptPubKey"],
            "witness_version": 16, "witness_program": valid["witness_program"],
            "ismine": wallet["ismine"], "iswatchonly": wallet["iswatchonly"]}


def fee_input_inventory(transport: Any, node: Any) -> dict[str, Any]:
    """Bind every eligible member at the one exact RPC-selectable address."""
    rows = transport.rpc(node, "listunspent", 1, 9_999_999)
    if not isinstance(rows, list):
        die("listunspent is not an array")
    candidates: list[dict[str, Any]] = []
    for row in rows:
        if (not isinstance(row, dict) or row.get("spendable") is not True or
                row.get("safe") is not True or row.get("spendability_state") != "spendable_legacy" or
                not isinstance(row.get("address"), str) or not row["address"] or
                not isinstance(row.get("scriptPubKey"), str) or
                not P2PKH_SCRIPT.fullmatch(row["scriptPubKey"]) or
                not isinstance(row.get("txid"), str) or not HEX64.fullmatch(row["txid"]) or
                type(row.get("vout")) is not int or row["vout"] < 0 or
                type(row.get("confirmations")) is not int or row["confirmations"] < 1):
            continue
        amount = decimal_amount(row.get("amount"), "legacy fee input amount")
        if amount <= FEE_CAP:
            continue
        candidates.append({"txid": row["txid"], "vout": row["vout"],
                           "address": row["address"], "scriptPubKey": row["scriptPubKey"],
                           "amount": f"{amount:.8f}", "confirmations": row["confirmations"]})
    if not candidates:
        die("node30 has no safe confirmed spendable P2PKH legacy fee UTXO")
    candidates.sort(key=lambda row: (row["txid"], row["vout"]))
    outpoints = [(row["txid"], row["vout"]) for row in candidates]
    if len(outpoints) != len(set(outpoints)):
        die("eligible fee-input inventory contains a duplicate outpoint")
    groups = sorted({(row["address"], row["scriptPubKey"]) for row in candidates})
    if len(groups) != 1:
        die("eligible fee inputs do not share one exact address and script")
    target_address, target_script = groups[0]
    address = transport.rpc(node, "getaddressinfo", target_address)
    if (not isinstance(address, dict) or address.get("address") != target_address or
            address.get("ismine") is not True or address.get("iswatchonly") is not False or
            address.get("solvable") is not True or
            address.get("scriptPubKey") != target_script):
        die("selected legacy fee address is not exact wallet-owned P2PKH")
    members: list[dict[str, Any]] = []
    for candidate in candidates:
        coin = transport.rpc(node, "gettxout", candidate["txid"], candidate["vout"], False)
        if (not isinstance(coin, dict) or
                decimal_amount(coin.get("value"), "active fee input value") !=
                Decimal(candidate["amount"]) or
                coin.get("scriptPubKey", {}).get("hex") != target_script or
                type(coin.get("confirmations")) is not int or coin["confirmations"] < 1):
            die("eligible legacy fee UTXO is not exact on the active UTXO set")
        members.append({**candidate,
                        "coin": {"value": candidate["amount"],
                                 "scriptPubKey": target_script,
                                 "confirmations": coin["confirmations"]}})
    digest = sha256_json(members)
    return {"selection_contract": "any-one-of-exact-audited-set/v1",
            "address": target_address, "scriptPubKey": target_script,
            "members": members, "members_sha256": digest,
            "eligible_wallet_candidate_count": len(members),
            "eligible_address_script_group_count": 1,
            "core_exact_outpoint_prebound": False}


def audited_fee_member(inventory: Any, txid: Any, vout: Any) -> dict[str, Any]:
    if (not isinstance(inventory, dict) or
            inventory.get("selection_contract") != "any-one-of-exact-audited-set/v1" or
            not isinstance(inventory.get("members"), list) or
            inventory.get("members_sha256") != sha256_json(inventory["members"])):
        die("audited fee-input inventory is malformed")
    matches = [member for member in inventory["members"]
               if isinstance(member, dict) and member.get("txid") == txid and
               member.get("vout") == vout]
    if len(matches) != 1:
        die("signed claim input is not exactly one member of the audited set")
    member = matches[0]
    if (member.get("address") != inventory.get("address") or
            member.get("scriptPubKey") != inventory.get("scriptPubKey")):
        die("audited fee-input member differs from the exact address and script")
    return member


def fee_inventory_authority(inventory: dict[str, Any]) -> dict[str, Any]:
    return {"selection_contract": inventory["selection_contract"],
            "address": inventory["address"], "scriptPubKey": inventory["scriptPubKey"],
            "members_sha256": inventory["members_sha256"],
            "member_count": inventory["eligible_wallet_candidate_count"],
            "core_exact_outpoint_prebound": False}


def fee_inventory_non_tip_identity(inventory: dict[str, Any]) -> dict[str, Any]:
    """Separate stable membership/value/script identity from tip-relative confirmations."""
    projection = json.loads(json.dumps(inventory))
    for member in projection["members"]:
        member.pop("confirmations")
        member["coin"].pop("confirmations")
    projection["members_sha256"] = sha256_json(projection["members"])
    return projection


def pre_call_resample(transport: Any, node: Any) -> dict[str, Any]:
    """Bracket the exact mutable inputs immediately before intent publication."""
    chain_before = node30.base.validate_chain(transport.rpc(node, "getblockchaininfo"), NODE)
    role = node30.role_snapshot(transport, node, False)
    inventory = fee_input_inventory(transport, node)
    txids = wallet_txids(transport, node)
    chain_after = node30.base.validate_chain(transport.rpc(node, "getblockchaininfo"), NODE)
    if node30.base.chain_identity(chain_before) != node30.base.chain_identity(chain_after):
        die("node30 tip moved during immediate pre-call resample")
    return {"chain": {"height": chain_after["blocks"],
                      "tip": chain_after["bestblockhash"]},
            "wallet_inventory": role["wallet_inventory"],
            "fee_input": inventory, "wallet_txids": txids,
            "wallet_txids_sha256": sha256_json(txids)}


def work_non_tip_fields_exact(work: Any, selected: dict[str, Any],
                              payout: dict[str, Any]) -> bool:
    return (isinstance(work, dict) and work.get("active") is True and
            work.get("proof_mode") == "pow" and work.get("proof_mode_byte") == 0 and
            work.get("proof_version") == 2 and
            work.get("claim_outpoint_required") is False and
            work.get("qqp4_active_next_block") is False and
            work.get("target_script") == selected["scriptPubKey"] and
            work.get("quantum_address") == payout["address"] and
            work.get("quantum_payout_script") == payout["scriptPubKey"] and
            work.get("claim_txid") in {None, ""} and
            work.get("claim_vout") in {None, -1} and
            type(work.get("target_bits")) is int and work["target_bits"] > 0)


def work_tip_fields_well_formed(work: dict[str, Any]) -> bool:
    return (type(work.get("height")) is int and work["height"] > 0 and
            isinstance(work.get("prevhash"), str) and
            HEX64.fullmatch(work["prevhash"]) is not None)


def validate_work(work: Any, chain: dict[str, Any], selected: dict[str, Any],
                  payout: dict[str, Any]) -> dict[str, Any]:
    if (not work_non_tip_fields_exact(work, selected, payout) or
            not work_tip_fields_well_formed(work) or
            work.get("height") != chain["blocks"] + 1 or
            work.get("prevhash") != chain["bestblockhash"]):
        die("getshadowpowwork is not exact active QQP2 work for the queued payout")
    return {key: work.get(key) for key in [
        "active", "height", "prevhash", "target_bits", "prefix", "proof_mode",
        "proof_mode_byte", "proof_version", "claim_outpoint_required",
        "qqp4_active_next_block", "target_script", "quantum_address",
        "quantum_payout_script", "claim_txid", "claim_vout"]}


def stable_live_snapshot(transport: Any, contract: Contract, exact_node: Any,
                         require_queue: bool = True) -> dict[str, Any]:
    for attempt in range(1, SNAPSHOT_ATTEMPTS + 1):
        chain_before = node30.base.validate_chain(
            transport.rpc(exact_node, "getblockchaininfo"), NODE)
        role = node30.role_snapshot(transport, exact_node, False)
        if (role["recovery"].get("blocking_quarantined_claims") != 0 or
                role["recovery"].get("database_outcome_ambiguous") is not False):
            die("node30 retained-claim recovery is not clean")
        queue = audit_queue(contract) if require_queue else None
        if queue is None:
            die("internal queue snapshot error")
        payout = validate_payout_address(
            transport, exact_node, queue["item"]["record"]["quantum_address"])
        selected = fee_input_inventory(transport, exact_node)
        goldrush = transport.rpc(exact_node, "getgoldrushinfo")
        if (not isinstance(goldrush, dict) or goldrush.get("active") is not True or
                goldrush.get("competing_claim_rule_active_next_block") is not False or
                goldrush.get("qqp4_active_next_block") is not False):
            die("node30 is not in the exact active QQP2 reward window")
        raw_work = transport.rpc(
            exact_node, "getshadowpowwork", selected["address"], payout["address"])
        selected_after = fee_input_inventory(transport, exact_node)
        chain_after = node30.base.validate_chain(
            transport.rpc(exact_node, "getblockchaininfo"), NODE)
        if not work_non_tip_fields_exact(raw_work, selected, payout):
            die("getshadowpowwork is not exact active QQP2 work for the queued payout")
        if not work_tip_fields_well_formed(raw_work):
            die("getshadowpowwork tip fields are malformed")
        chain_non_tip_fields = ["chain", "initialblockdownload", "pruned", "warnings"]
        if ({key: chain_before.get(key) for key in chain_non_tip_fields} !=
                {key: chain_after.get(key) for key in chain_non_tip_fields}):
            die("node30 non-tip chain identity moved during an audit snapshot")
        chain_tip_fields = ["blocks", "headers", "bestblockhash", "chainwork"]
        chain_moved = ({key: chain_before.get(key) for key in chain_tip_fields} !=
                       {key: chain_after.get(key) for key in chain_tip_fields})
        if chain_moved:
            if (fee_inventory_non_tip_identity(selected_after) !=
                    fee_inventory_non_tip_identity(selected)):
                die("node30 eligible fee-input identity moved during an audit tip advance")
            if attempt == SNAPSHOT_ATTEMPTS:
                die("node30 active tip moved throughout the bounded snapshot attempts")
            continue
        if selected_after != selected:
            die("node30 eligible fee-input inventory moved on a stable audit tip")
        work_tip_drift = (raw_work["height"] != chain_after["blocks"] + 1 or
                          raw_work["prevhash"] != chain_after["bestblockhash"])
        if work_tip_drift:
            if attempt == SNAPSHOT_ATTEMPTS:
                die("node30 QQP2 work tip drifted throughout the bounded snapshot attempts")
            continue
        work = validate_work(raw_work, chain_after, selected, payout)
        txids = wallet_txids(transport, exact_node)
        return {"chain": {"height": chain_after["blocks"],
                          "tip": chain_after["bestblockhash"]},
                "role": role, "queue": queue, "payout": payout,
                "fee_input": selected, "work": work,
                "snapshot_attempts": attempt,
                "wallet_txids_before": txids,
                "wallet_txids_before_sha256": sha256_json(txids)}
    die("node30 bounded snapshot attempts exhausted")


def load_audit(run_dir: pathlib.Path, contract: Contract) -> tuple[dict[str, Any], str]:
    receipt, digest = node30.load_run_receipt(run_dir, "audit.json")
    validate_common(receipt, "node30-free-claim-one-shot-audit", contract)
    if (receipt.get("result") != "READY_FOR_SEPARATE_ONE_SHOT_AUTHORITY" or
            receipt.get("mutation_performed") is not False or
            not isinstance(receipt.get("snapshot"), dict)):
        die("one-shot audit is not the exact nonmutating readiness receipt")
    return receipt, digest


def audit_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    node30.base.ensure_secure_dir(run_dir, create=True)
    contract = validate_manifest(pathlib.Path(args.runtime_manifest))
    node30.publish_bytes(run_dir / "runtime-manifest.json",
                         node30.base.owned_secure_file(contract.path, "runtime manifest",
                                                       contract.sha256))
    pause_before = node30.free_claim_snapshot(contract.retained)
    transport = Transport(contract.retained.runtime)
    node = contract.retained.runtime.nodes[0]
    exact_node, runtime_before = node30.pin_node(transport, node)
    with node30.mutation_locks(contract.retained) as lock_ids:
        snapshot = stable_live_snapshot(transport, contract, exact_node)
    pause_after = node30.free_claim_snapshot(contract.retained)
    if (pause_before != pause_after or transport.runtime_snapshot(node) != runtime_before):
        die("node30 runtime or pause artifacts changed across one-shot audit")
    receipt = base_receipt("node30-free-claim-one-shot-audit", contract)
    receipt.update({"result": "READY_FOR_SEPARATE_ONE_SHOT_AUTHORITY",
                    "mutation_performed": False, "snapshot": snapshot,
                    "free_claim": pause_after, "runtime": runtime_before,
                    "lock_identities": lock_ids})
    receipt["required_authority"] = {
        "schema": RECEIPT_SCHEMA,
        "kind": "node30-free-claim-one-shot-authority",
        "decision": "REPLACE_WITH_authorize_AFTER_REVIEW",
        "action": "send_exactly_one_shadow_pow_claim",
        "node": NODE,
        "role": "free_claim",
        "audit_receipt_sha256": "REPLACE_WITH_AUDIT_SHA256",
        "runtime_manifest_sha256": contract.sha256,
        "tool_sha256": tool_sha(),
        "node30_primitive_sha256": NODE30_PRIMITIVE_SHA256,
        "controller_runtime_sha256": sha256_json(controller_runtime_identity()),
        "free_claim_storage_sha256": sha256_json(current_free_claim_storage(contract)),
        "queue_item_identity_sha256": sha256_json(
            immutable_queue_item_identity(snapshot["queue"]["item"])),
        "queue_item_sha256": snapshot["queue"]["item"]["sha256"],
        "queue_item_basename": snapshot["queue"]["item"]["basename"],
        "quantum_address": snapshot["payout"]["address"],
        "quantum_payout_script": snapshot["payout"]["scriptPubKey"],
        "legacy_fee_input_set": fee_inventory_authority(snapshot["fee_input"]),
        "active_tip": snapshot["chain"]["tip"],
        "active_height": snapshot["chain"]["height"],
        "work_sha256": sha256_json(snapshot["work"]),
        "wallet_txids_before_sha256": snapshot["wallet_txids_before_sha256"],
        "fee_rate_atoms_per_vbyte": FEE_RATE_ATOMS_PER_VBYTE,
        "maximum_fee_blk": f"{FEE_CAP:.8f}",
        "expected_vsize": EXPECTED_VSIZE,
        "maximum_tries": MAX_TRIES,
        "proof_override": None,
        "single_submission_only": True,
        "ordinary_pow_authorized": False,
        "recurring_worker_authorized": False,
        "pause_removal_authorized": False,
        "recovery_authorized": False,
        "repair_authorized": False,
        "reindex_authorized": False,
        "rewind_authorized": False,
        "user_orders": USER_ORDERS,
        "user_order_sha256": USER_ORDER_SHA256,
        "acknowledgements": {
            "fee_sign_and_broadcast_are_irreversible": True,
            "installed_rpc_has_no_idempotency_token": True,
            "installed_rpc_has_no_exact_input_or_max_total_fee_parameter": True,
            "installed_rpc_cannot_prebind_the_exact_selected_outpoint": True,
            "core_may_select_any_one_member_of_the_exact_audited_set": True,
            "signed_transaction_must_spend_exactly_one_audited_member": True,
            "unknown_response_consumes_authority_and_must_never_be_retried": True,
            "actual_fee_must_be_independently_proved_from_exact_signed_bytes": True,
            "free_claim_pause_remains_present": True,
            "ordinary_pow_remains_disabled": True,
            "pos_remains_active": True,
        },
    }
    digest = node30.publish_json(run_dir / "audit.json", receipt)
    print(json.dumps({"result": receipt["result"], "audit_sha256": digest}, sort_keys=True))


def validate_authority(authority: Any, contract: Contract, audit: dict[str, Any],
                       audit_sha: str) -> None:
    snapshot = audit["snapshot"]
    exact = {
        "schema": RECEIPT_SCHEMA, "kind": "node30-free-claim-one-shot-authority",
        "decision": "authorize", "action": "send_exactly_one_shadow_pow_claim",
        "node": NODE, "role": "free_claim", "audit_receipt_sha256": audit_sha,
        "runtime_manifest_sha256": contract.sha256, "tool_sha256": tool_sha(),
        "node30_primitive_sha256": NODE30_PRIMITIVE_SHA256,
        "controller_runtime_sha256": sha256_json(controller_runtime_identity()),
        "free_claim_storage_sha256": sha256_json(current_free_claim_storage(contract)),
        "queue_item_identity_sha256": sha256_json(
            immutable_queue_item_identity(snapshot["queue"]["item"])),
        "queue_item_sha256": snapshot["queue"]["item"]["sha256"],
        "queue_item_basename": snapshot["queue"]["item"]["basename"],
        "quantum_address": snapshot["payout"]["address"],
        "quantum_payout_script": snapshot["payout"]["scriptPubKey"],
        "legacy_fee_input_set": fee_inventory_authority(snapshot["fee_input"]),
        "active_tip": snapshot["chain"]["tip"], "active_height": snapshot["chain"]["height"],
        "work_sha256": sha256_json(snapshot["work"]),
        "wallet_txids_before_sha256": snapshot["wallet_txids_before_sha256"],
        "fee_rate_atoms_per_vbyte": FEE_RATE_ATOMS_PER_VBYTE,
        "maximum_fee_blk": f"{FEE_CAP:.8f}", "expected_vsize": EXPECTED_VSIZE,
        "maximum_tries": MAX_TRIES, "proof_override": None,
        "single_submission_only": True, "ordinary_pow_authorized": False,
        "recurring_worker_authorized": False, "pause_removal_authorized": False,
        "recovery_authorized": False, "repair_authorized": False,
        "reindex_authorized": False, "rewind_authorized": False,
        "user_orders": USER_ORDERS, "user_order_sha256": USER_ORDER_SHA256,
        "acknowledgements": {
            "fee_sign_and_broadcast_are_irreversible": True,
            "installed_rpc_has_no_idempotency_token": True,
            "installed_rpc_has_no_exact_input_or_max_total_fee_parameter": True,
            "installed_rpc_cannot_prebind_the_exact_selected_outpoint": True,
            "core_may_select_any_one_member_of_the_exact_audited_set": True,
            "signed_transaction_must_spend_exactly_one_audited_member": True,
            "unknown_response_consumes_authority_and_must_never_be_retried": True,
            "actual_fee_must_be_independently_proved_from_exact_signed_bytes": True,
            "free_claim_pause_remains_present": True,
            "ordinary_pow_remains_disabled": True,
            "pos_remains_active": True,
        },
    }
    if not isinstance(authority, dict) or set(authority) != set(exact):
        die("one-shot authority field set is not exact")
    for key, value in exact.items():
        if authority.get(key) != value:
            die(f"one-shot authority field {key} differs from the audit contract")


def load_authority(args: argparse.Namespace, contract: Contract, audit: dict[str, Any],
                   audit_sha: str) -> tuple[dict[str, Any], str]:
    authority, digest = node30.base.parse_secure_json(
        pathlib.Path(args.authority), "one-shot authority", args.authority_sha256)
    validate_authority(authority, contract, audit, audit_sha)
    return authority, digest


def load_intent(run_dir: pathlib.Path, contract: Contract, audit: dict[str, Any], audit_sha: str,
                authority_sha: str) -> tuple[dict[str, Any], str]:
    intent, digest = node30.load_run_receipt(run_dir, "intent.json")
    validate_common(intent, "node30-free-claim-one-shot-intent", contract)
    expected_pre_call = {
        "matched_audit": True, "chain": audit["snapshot"]["chain"],
        "fee_input_members_sha256": audit["snapshot"]["fee_input"]["members_sha256"],
        "wallet_txids_sha256": audit["snapshot"]["wallet_txids_before_sha256"],
        "wallet_inventory": audit["snapshot"]["role"]["wallet_inventory"],
    }
    if (intent.get("state") != "AUTHORITY_CONSUMED_RPC_PENDING_OR_COMPLETE" or
            intent.get("audit_receipt_sha256") != audit_sha or
            intent.get("authority_sha256") != authority_sha or
            intent.get("rpc_method") != "sendshadowpowclaim" or
            intent.get("rpc_parameters") != {
                "address": intent.get("fee_input", {}).get("address"),
                "quantum_address": intent.get("payout", {}).get("address"),
                "max_tries": MAX_TRIES, "fee_rate": FEE_RATE_ATOMS_PER_VBYTE,
                "proof": None} or
            intent.get("fee_input") != audit["snapshot"]["fee_input"] or
            intent.get("payout") != audit["snapshot"]["payout"] or
            intent.get("work") != audit["snapshot"]["work"] or
            intent.get("wallet_txids_before") != audit["snapshot"]["wallet_txids_before"] or
            intent.get("wallet_txids_before_sha256") !=
            audit["snapshot"]["wallet_txids_before_sha256"] or
            intent.get("pre_call_resample") != expected_pre_call or
            intent.get("call_budget") != 1 or intent.get("calls_completed_before_intent") != 0):
        die("one-shot intent is not the exact consumed authority")
    return intent, digest


def parse_qqp2_proof(proof_hex: Any, expected_target: str,
                     expected_payout: str) -> dict[str, Any]:
    if not isinstance(proof_hex, str) or not re.fullmatch(r"[0-9a-f]+", proof_hex) or len(proof_hex) % 2:
        die("claim proof is not lowercase even-length hex")
    proof = bytes.fromhex(proof_hex)
    if not proof.startswith(QQ_PREFIX + QQP2_MAGIC):
        die("claim proof is not the exact QQSPROOF/QQP2 family")
    payload = proof[len(QQ_PREFIX):]
    if len(payload) < 17 or payload[4] != 0:
        die("claim proof is not PoW-mode QQP2")
    cursor = 13
    target_len = int.from_bytes(payload[cursor:cursor + 2], "little")
    cursor += 2
    target = payload[cursor:cursor + target_len]
    cursor += target_len
    if cursor + 2 > len(payload):
        die("claim proof target length is truncated")
    payout_len = int.from_bytes(payload[cursor:cursor + 2], "little")
    cursor += 2
    payout = payload[cursor:cursor + payout_len]
    cursor += payout_len
    if (cursor != len(payload) or target.hex() != expected_target or
            payout.hex() != expected_payout):
        die("claim proof does not bind the exact audited target and queued payout scripts")
    return {"proof_sha256": hashlib.sha256(proof).hexdigest(), "proof_version": 2,
            "proof_mode": "pow", "nonce": int.from_bytes(payload[5:13], "little"),
            "target_script": target.hex(), "quantum_payout_script": payout.hex()}


def op_return_script(proof_hex: str) -> str:
    """Return the only canonical OP_RETURN push encoding for the exact proof."""
    size = len(bytes.fromhex(proof_hex))
    if size <= 75:
        push = f"{size:02x}"
    elif size <= 255:
        push = "4c" + f"{size:02x}"
    else:
        die("claim proof exceeds the reviewed single-byte pushdata envelope")
    return "6a" + push + proof_hex


def signed_transaction_evidence(transport: Any, node: Any, raw: Any,
                                intent: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(raw, dict):
        die("sendshadowpowclaim result is not an object")
    required = {"txid", "hex", "proof", "proof_mode", "proof_mode_byte", "external_proof",
                "fee", "change", "vsize", "address", "quantum_address"}
    if set(raw) != required:
        die("sendshadowpowclaim result field set changed")
    txid = require_hex64(raw.get("txid"), "claim txid")
    txhex = raw.get("hex")
    if not isinstance(txhex, str) or not re.fullmatch(r"[0-9a-f]+", txhex) or len(txhex) % 2:
        die("claim transaction bytes are not lowercase even-length hex")
    if (raw.get("proof_mode") != "pow" or raw.get("proof_mode_byte") != 0 or
            raw.get("external_proof") is not False or raw.get("address") !=
            intent["fee_input"]["address"] or raw.get("quantum_address") !=
            intent["payout"]["address"]):
        die("sendshadowpowclaim result role/address fields changed")
    proof = parse_qqp2_proof(raw.get("proof"), intent["fee_input"]["scriptPubKey"],
                             intent["payout"]["scriptPubKey"])
    decoded = transport.rpc(node, "decoderawtransaction", txhex)
    if (not isinstance(decoded, dict) or decoded.get("txid") != txid or
            decoded.get("vsize") != EXPECTED_VSIZE or
            not isinstance(decoded.get("vin"), list) or len(decoded["vin"]) != 1 or
            not isinstance(decoded.get("vout"), list) or len(decoded["vout"]) != 2):
        die("signed claim transaction identity or 287-vB shape changed")
    vin = decoded["vin"][0]
    if not isinstance(vin, dict):
        die("signed claim transaction input is malformed")
    member = audited_fee_member(intent["fee_input"], vin.get("txid"), vin.get("vout"))
    outputs = sorted(decoded["vout"], key=lambda row: row.get("n", -1))
    if [row.get("n") for row in outputs] != [0, 1]:
        die("signed claim transaction output indexes changed")
    change = outputs[0]
    proof_out = outputs[1]
    if (change.get("scriptPubKey", {}).get("hex") != intent["fee_input"]["scriptPubKey"] or
            decimal_amount(proof_out.get("value"), "QQSPROOF output value") != ZERO or
            proof_out.get("scriptPubKey", {}).get("type") != "nulldata" or
            proof_out.get("scriptPubKey", {}).get("hex") != op_return_script(raw["proof"]) or
            proof_out.get("scriptPubKey", {}).get("asm") != "OP_RETURN " + raw["proof"]):
        die("signed claim outputs do not preserve change script and exact QQSPROOF bytes")
    input_amount = Decimal(member["amount"])
    change_amount = decimal_amount(change.get("value"), "signed claim change")
    actual_fee = (input_amount - change_amount).quantize(Decimal("0.00000001"))
    if (actual_fee <= ZERO or actual_fee > FEE_CAP or actual_fee != FEE_CAP or
            decimal_amount(raw.get("fee"), "RPC claim fee") != actual_fee or
            decimal_amount(raw.get("change"), "RPC claim change") != change_amount or
            raw.get("vsize") != EXPECTED_VSIZE):
        die("signed claim actual fee is not exact 287-vB * 100 atoms/vB")
    return {
        "identity": {"txid": txid, "hex": txhex,
                     "hex_sha256": hashlib.sha256(bytes.fromhex(txhex)).hexdigest()},
        "input": {**{key: member[key]
                     for key in ["txid", "vout", "amount", "scriptPubKey", "address"]},
                  "audited_set_sha256": intent["fee_input"]["members_sha256"]},
        "output": {"n": 0, "amount": f"{change_amount:.8f}",
                   "scriptPubKey": intent["fee_input"]["scriptPubKey"]},
        "proof_output": {"n": 1, "amount": "0.00000000",
                         "scriptPubKey": op_return_script(raw["proof"]),
                         "script_asm": "OP_RETURN " + raw["proof"]},
        "proof": proof,
        "fee": {"input_amount": f"{input_amount:.8f}",
                "signed_output_amount": f"{change_amount:.8f}",
                "actual_fee_blk": f"{actual_fee:.8f}", "maximum_fee_blk": f"{FEE_CAP:.8f}",
                "fee_rate_atoms_per_vbyte": FEE_RATE_ATOMS_PER_VBYTE,
                "vsize": EXPECTED_VSIZE, "independently_computed": True},
        "payout": intent["payout"], "external_proof": False,
    }


def validate_transaction_receipt(value: Any, intent: dict[str, Any],
                                 label: str) -> dict[str, Any]:
    """Validate the immutable signed-byte evidence stored in a run receipt."""
    required = {"identity", "input", "output", "proof_output", "proof", "fee",
                "payout", "external_proof"}
    if (not isinstance(value, dict) or frozenset(value) not in
            {frozenset(required), frozenset(required | {"observation"})}):
        die(f"{label} signed evidence field set is not exact")
    identity = value.get("identity")
    if not isinstance(identity, dict) or set(identity) != {"txid", "hex", "hex_sha256"}:
        die(f"{label} transaction identity is malformed")
    require_hex64(identity.get("txid"), f"{label} txid")
    txhex = identity.get("hex")
    if (not isinstance(txhex, str) or not re.fullmatch(r"[0-9a-f]+", txhex) or
            len(txhex) % 2 or identity.get("hex_sha256") !=
            hashlib.sha256(bytes.fromhex(txhex)).hexdigest()):
        die(f"{label} exact transaction bytes are malformed")
    stored_input = value.get("input")
    if not isinstance(stored_input, dict):
        die(f"{label} input projection is malformed")
    member = audited_fee_member(
        intent["fee_input"], stored_input.get("txid"), stored_input.get("vout"))
    expected_input = {**{key: member[key]
                         for key in ["txid", "vout", "amount", "scriptPubKey", "address"]},
                      "audited_set_sha256": intent["fee_input"]["members_sha256"]}
    if stored_input != expected_input or value.get("payout") != intent["payout"]:
        die(f"{label} input or payout differs from the consumed intent")
    output = value.get("output")
    proof_output = value.get("proof_output")
    if (not isinstance(output, dict) or output.get("n") != 0 or
            output.get("scriptPubKey") != intent["fee_input"]["scriptPubKey"] or
            not isinstance(proof_output, dict) or proof_output.get("n") != 1 or
            proof_output.get("amount") != "0.00000000" or
            not isinstance(proof_output.get("scriptPubKey"), str) or
            not isinstance(proof_output.get("script_asm"), str) or
            not proof_output["script_asm"].startswith("OP_RETURN ")):
        die(f"{label} output projection is malformed")
    proof_hex = proof_output["script_asm"][len("OP_RETURN "):]
    if proof_output["scriptPubKey"] != op_return_script(proof_hex):
        die(f"{label} proof script does not use the canonical exact push encoding")
    parsed_proof = parse_qqp2_proof(
        proof_hex, intent["fee_input"]["scriptPubKey"], intent["payout"]["scriptPubKey"])
    if value.get("proof") != parsed_proof or value.get("external_proof") is not False:
        die(f"{label} proof projection differs from the exact QQP2 bytes")
    fee = value.get("fee")
    input_amount = decimal_amount(member["amount"], f"{label} input amount")
    output_amount = decimal_amount(output.get("amount"), f"{label} output amount")
    actual_fee = (input_amount - output_amount).quantize(Decimal("0.00000001"))
    if (not isinstance(fee, dict) or fee != {
            "input_amount": f"{input_amount:.8f}",
            "signed_output_amount": f"{output_amount:.8f}",
            "actual_fee_blk": f"{actual_fee:.8f}",
            "maximum_fee_blk": f"{FEE_CAP:.8f}",
            "fee_rate_atoms_per_vbyte": FEE_RATE_ATOMS_PER_VBYTE,
            "vsize": EXPECTED_VSIZE,
            "independently_computed": True,
            } or actual_fee != FEE_CAP):
        die(f"{label} fee projection is not exact")
    if "observation" in value:
        observation = value["observation"]
        if (not isinstance(observation, dict) or set(observation) !=
                {"confirmations", "blockhash"} or
                type(observation.get("confirmations")) is not int or
                observation["confirmations"] < 0 or
                (observation.get("blockhash") is not None and
                 not HEX64.fullmatch(str(observation["blockhash"])))):
            die(f"{label} mutable observation is malformed")
    return {key: value[key] for key in sorted(required)}


def current_queue_state(contract: Contract, audit: dict[str, Any]) -> tuple[str, pathlib.Path]:
    item = audit["snapshot"]["queue"]["item"]
    names = audit["snapshot"]["queue"]["outcome_names"]
    paths = {
        "queued": contract.queue_dir / names["queued"],
        "broadcast": contract.done_dir / names["broadcast"],
        "uncertain": contract.done_dir / names["uncertain"],
        "confirmed": contract.done_dir / names["confirmed"],
    }
    present = [(state_name, path) for state_name, path in paths.items()
               if path.exists() or path.is_symlink()]
    if len(present) != 1:
        die("exactly one authenticated queue/outcome state must exist")
    state_name, path = present[0]
    queue_file_snapshot(path, contract, f"Free-Claim {state_name} item", item["sha256"], item)
    return state_name, path


def transition_queue(contract: Contract, audit: dict[str, Any], target: str) -> dict[str, Any]:
    if target not in {"broadcast", "uncertain", "confirmed"}:
        die("invalid queue outcome transition")
    state_name, source = current_queue_state(contract, audit)
    allowed = {("queued", "broadcast"), ("queued", "uncertain"),
               ("uncertain", "broadcast"), ("broadcast", "confirmed")}
    if state_name == target:
        return {"state": target, "path": str(source), "already_complete": True,
                "atomic_rename": True}
    if (state_name, target) not in allowed:
        die(f"forbidden queue outcome transition {state_name}->{target}")
    names = audit["snapshot"]["queue"]["outcome_names"]
    destination = contract.done_dir / names[target]
    if destination.exists() or destination.is_symlink():
        die("queue outcome destination already exists")
    source_st = source.lstat()
    if source_st.st_dev != contract.done_dir.lstat().st_dev:
        die("queue outcome transition would cross filesystems")
    os.rename(source, destination)
    node30.base.fsync_dir(source.parent)
    if source.parent != destination.parent:
        node30.base.fsync_dir(destination.parent)
    final, _ = queue_file_snapshot(destination, contract, f"Free-Claim {target} item",
                                   audit["snapshot"]["queue"]["item"]["sha256"],
                                   audit["snapshot"]["queue"]["item"])
    return {"state": target, "path": str(destination), "sha256": final["sha256"],
            "device": final["device"], "inode": final["inode"],
            "already_complete": False, "atomic_rename": True}


def publish_unknown(run_dir: pathlib.Path, contract: Contract, intent_sha: str,
                    message: str, queue_outcome: dict[str, Any]) -> None:
    receipt = base_receipt("node30-free-claim-one-shot-rpc-unknown", contract)
    receipt.update({"state": "UNKNOWN_AUTHORITY_CONSUMED_NEVER_RETRY",
                    "intent_sha256": intent_sha, "error": message,
                    "queue_outcome": queue_outcome, "retry_authorized": False,
                    "sendshadowpowclaim_call_count": 1})
    node30.publish_json(run_dir / "rpc-unknown.json", receipt)


def execute_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    node30.base.ensure_secure_dir(run_dir)
    contract = load_contract(run_dir)
    audit, audit_sha = load_audit(run_dir, contract)
    _, authority_sha = load_authority(args, contract, audit, audit_sha)
    if (run_dir / "intent.json").exists() or (run_dir / "intent.json").is_symlink():
        die("one-shot authority was already consumed; use reconcile, never execute again")
    transport = Transport(contract.retained.runtime)
    node = contract.retained.runtime.nodes[0]
    pause_before = node30.free_claim_snapshot(contract.retained)
    exact_node, runtime_before = node30.pin_node(transport, node)
    with node30.mutation_locks(contract.retained) as lock_ids:
        current = stable_live_snapshot(transport, contract, exact_node)
        expected = audit["snapshot"]
        stable_keys = ["chain", "queue", "payout", "fee_input", "work",
                       "wallet_txids_before_sha256"]
        for key in stable_keys:
            if current.get(key) != expected.get(key):
                die(f"one-shot authority audit is stale at {key}")
        node30.same_runtime_identity(audit["runtime"], runtime_before,
                                     "one-shot audit to execution")
        node30.same_wallet_inventory(expected["role"]["wallet_inventory"],
                                     current["role"]["wallet_inventory"],
                                     "one-shot audit to execution")
        immediate = pre_call_resample(transport, exact_node)
        if (immediate["chain"] != current["chain"] or
                immediate["fee_input"] != current["fee_input"] or
                immediate["wallet_txids"] != current["wallet_txids_before"] or
                immediate["wallet_txids_sha256"] != current["wallet_txids_before_sha256"] or
                immediate["wallet_inventory"] != current["role"]["wallet_inventory"]):
            die("immediate pre-call tip, wallet, or fee-input set differs from the audit")
        node30.same_wallet_inventory(current["role"]["wallet_inventory"],
                                     immediate["wallet_inventory"],
                                     "one-shot immediate pre-call resample")
        intent = base_receipt("node30-free-claim-one-shot-intent", contract)
        intent.update({
            "state": "AUTHORITY_CONSUMED_RPC_PENDING_OR_COMPLETE",
            "audit_receipt_sha256": audit_sha, "authority_sha256": authority_sha,
            "rpc_method": "sendshadowpowclaim",
            "rpc_parameters": {"address": current["fee_input"]["address"],
                               "quantum_address": current["payout"]["address"],
                               "max_tries": MAX_TRIES,
                               "fee_rate": FEE_RATE_ATOMS_PER_VBYTE, "proof": None},
            "fee_input": current["fee_input"], "payout": current["payout"],
            "work": current["work"], "wallet_txids_before": current["wallet_txids_before"],
            "wallet_txids_before_sha256": current["wallet_txids_before_sha256"],
            "pre_call_resample": {
                "matched_audit": True, "chain": immediate["chain"],
                "fee_input_members_sha256": immediate["fee_input"]["members_sha256"],
                "wallet_txids_sha256": immediate["wallet_txids_sha256"],
                "wallet_inventory": immediate["wallet_inventory"],
            },
            "call_budget": 1, "calls_completed_before_intent": 0,
            "lock_identities": lock_ids, "created_at": node30.base.utc_now(),
        })
        intent_sha = node30.publish_json(run_dir / "intent.json", intent)
        try:
            response = transport.rpc(
                exact_node, "sendshadowpowclaim", current["fee_input"]["address"],
                current["payout"]["address"], MAX_TRIES, FEE_RATE_ATOMS_PER_VBYTE)
        except (node30.base.GateError, node30.GateError, OSError,
                subprocess.TimeoutExpired) as exc:
            outcome = transition_queue(contract, audit, "uncertain")
            publish_unknown(run_dir, contract, intent_sha, str(exc), outcome)
            if node30.free_claim_snapshot(contract.retained) != pause_before:
                die("Free-Claim pause changed during unknown RPC response")
            raise GateError("sendshadowpowclaim response is unknown; authority consumed, never retry") from exc
        response_receipt = base_receipt("node30-free-claim-one-shot-rpc-response", contract)
        response_receipt.update({"intent_sha256": intent_sha,
                                 "sendshadowpowclaim_call_count": 1,
                                 "raw_response": response,
                                 "published_before_post_call_rpc_reads": True})
        response_sha = node30.publish_json(run_dir / "rpc-response.json", response_receipt)
        try:
            evidence = signed_transaction_evidence(transport, exact_node, response, intent)
        except (node30.base.GateError, node30.GateError, OSError,
                subprocess.TimeoutExpired) as exc:
            outcome = transition_queue(contract, audit, "uncertain")
            invalid = base_receipt("node30-free-claim-one-shot-invalid-response", contract)
            invalid.update({"intent_sha256": intent_sha, "rpc_response_sha256": response_sha,
                            "state": "RESPONSE_PERSISTED_VALIDATION_FAILED_NEVER_RETRY",
                            "error": str(exc), "queue_outcome": outcome,
                            "retry_authorized": False})
            node30.publish_json(run_dir / "invalid-response.json", invalid)
            raise GateError("sendshadowpowclaim returned unprovable bytes; authority consumed") from exc
        outcome = transition_queue(contract, audit, "broadcast")
        complete = base_receipt("node30-free-claim-one-shot-broadcast-complete", contract)
        complete.update({"result": "EXACT_ONE_SHOT_BROADCAST",
                         "audit_receipt_sha256": audit_sha,
                         "authority_sha256": authority_sha, "intent_sha256": intent_sha,
                         "rpc_response_sha256": response_sha,
                         "transaction": evidence, "queue_outcome": outcome,
                         "sendshadowpowclaim_call_count": 1, "proof_override_used": False,
                         "pause_preserved": True, "ordinary_pow_enabled": False,
                         "recurring_worker_invoked": False})
        complete_sha = node30.publish_json(run_dir / "broadcast-complete.json", complete)
    pause_after = node30.free_claim_snapshot(contract.retained)
    role_after = node30.role_snapshot(transport, exact_node, False)
    if (pause_after != pause_before or transport.runtime_snapshot(node) != runtime_before or
            role_after["ordinary_pow"]["enabled"] is not False or
            role_after["pos"]["staking"] is not True):
        die("node30 pause/runtime/PoS/ordinary-PoW role changed after one-shot")
    print(json.dumps({"result": complete["result"], "txid": evidence["identity"]["txid"],
                      "broadcast_complete_sha256": complete_sha}, sort_keys=True))


def candidate_response_from_gettransaction(tx: Any) -> dict[str, Any] | None:
    if not isinstance(tx, dict) or not isinstance(tx.get("decoded"), dict):
        return None
    decoded = tx["decoded"]
    if not isinstance(tx.get("hex"), str) or not isinstance(decoded.get("vout"), list):
        return None
    proofs = []
    for output in decoded["vout"]:
        script = output.get("scriptPubKey", {}) if isinstance(output, dict) else {}
        asm = script.get("asm") if isinstance(script, dict) else None
        if isinstance(asm, str) and asm.startswith("OP_RETURN "):
            proofs.append(asm[len("OP_RETURN "):])
    if len(proofs) != 1:
        return None
    try:
        wallet_fee = Decimal(str(tx.get("fee"))).quantize(Decimal("0.00000001"))
    except (InvalidOperation, ValueError, TypeError):
        return None
    if wallet_fee >= ZERO:
        return None
    return {"txid": tx.get("txid"), "hex": tx["hex"], "proof": proofs[0],
            "proof_mode": "pow", "proof_mode_byte": 0, "external_proof": False,
            "fee": f"{-wallet_fee:.8f}",
            "change": decoded["vout"][0].get("value"), "vsize": decoded.get("vsize"),
            "address": None, "quantum_address": None}


def reconcile_candidates(transport: Any, node: Any, intent: dict[str, Any]) -> list[dict[str, Any]]:
    current = wallet_txids(transport, node)
    before = set(intent["wallet_txids_before"])
    candidate_ids = set(current) - before
    outpoints = [{"txid": member["txid"], "vout": member["vout"]}
                 for member in intent["fee_input"]["members"]]
    spending = transport.rpc(node, "gettxspendingprevout", outpoints)
    if not isinstance(spending, list) or len(spending) != len(outpoints):
        die("gettxspendingprevout response changed")
    for expected, observed in zip(outpoints, spending):
        if (not isinstance(observed, dict) or observed.get("txid") != expected["txid"] or
                observed.get("vout") != expected["vout"]):
            die("gettxspendingprevout response changed")
        spender = observed.get("spendingtxid")
        if spender:
            require_hex64(spender, "mempool spender txid")
            candidate_ids.add(spender)
    exact: list[dict[str, Any]] = []
    for txid in sorted(candidate_ids):
        try:
            tx = transport.rpc(node, "gettransaction", txid, True, True)
        except node30.base.GateError:
            continue
        raw = candidate_response_from_gettransaction(tx)
        if raw is None:
            continue
        raw["address"] = intent["fee_input"]["address"]
        raw["quantum_address"] = intent["payout"]["address"]
        try:
            evidence = signed_transaction_evidence(transport, node, raw, intent)
        except (node30.base.GateError, node30.GateError):
            continue
        evidence["observation"] = {"confirmations": tx.get("confirmations", 0),
                                   "blockhash": tx.get("blockhash")}
        exact.append(evidence)
    if len(exact) > 1:
        die("more than one exact one-shot transaction exists; invariant violated")
    return exact


def reconcile_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    node30.base.ensure_secure_dir(run_dir)
    contract = load_contract(run_dir)
    audit, audit_sha = load_audit(run_dir, contract)
    _, authority_sha = load_authority(args, contract, audit, audit_sha)
    intent, intent_sha = load_intent(run_dir, contract, audit, audit_sha, authority_sha)
    broadcast_path = run_dir / "broadcast-complete.json"
    if broadcast_path.exists() or broadcast_path.is_symlink():
        existing, existing_sha = load_broadcast(
            run_dir, contract, audit_sha, authority_sha, intent, intent_sha)
        state_name, _ = current_queue_state(contract, audit)
        if state_name not in {"broadcast", "confirmed"}:
            die("completed broadcast receipt has no exact queue outcome state")
        node30.free_claim_snapshot(contract.retained)
        print(json.dumps({"result": existing["result"],
                          "txid": existing["transaction"]["identity"]["txid"],
                          "broadcast_complete_sha256": existing_sha,
                          "already_complete": True}, sort_keys=True))
        return
    transport = Transport(contract.retained.runtime)
    node = contract.retained.runtime.nodes[0]
    pause_before = node30.free_claim_snapshot(contract.retained)
    exact_node, runtime_before = node30.pin_node(transport, node)
    with node30.mutation_locks(contract.retained) as lock_ids:
        role = node30.role_snapshot(transport, exact_node, False)
        node30.same_wallet_inventory(audit["snapshot"]["role"]["wallet_inventory"],
                                     role["wallet_inventory"], "one-shot reconciliation")
        candidates = reconcile_candidates(transport, exact_node, intent)
        if not candidates:
            state_name, state_path = current_queue_state(contract, audit)
            receipt = base_receipt("node30-free-claim-one-shot-reconcile-observation", contract)
            receipt.update({"result": "NO_EXACT_TRANSACTION_YET_AUTHORITY_CONSUMED",
                            "audit_receipt_sha256": audit_sha,
                            "authority_sha256": authority_sha, "intent_sha256": intent_sha,
                            "queue_state": state_name, "queue_path": str(state_path),
                            "retry_authorized": False, "candidate_count": 0,
                            "lock_identities": lock_ids})
            name = f"reconcile-{time.time_ns()}.json"
            digest = node30.publish_json(run_dir / name, receipt)
            print(json.dumps({"result": receipt["result"], "receipt": name,
                              "sha256": digest}, sort_keys=True))
            return
        evidence = candidates[0]
        outcome = transition_queue(contract, audit, "broadcast")
        response_sha: str | None = None
        response_path = run_dir / "rpc-response.json"
        if response_path.exists() or response_path.is_symlink():
            _, response_sha = load_rpc_response(run_dir, contract, intent_sha)
        receipt = base_receipt("node30-free-claim-one-shot-broadcast-complete", contract)
        receipt.update({"result": "EXACT_ONE_SHOT_RECONCILED_WITHOUT_RETRY",
                        "audit_receipt_sha256": audit_sha,
                        "authority_sha256": authority_sha, "intent_sha256": intent_sha,
                        "rpc_response_sha256": response_sha, "transaction": evidence,
                        "queue_outcome": outcome, "sendshadowpowclaim_call_count": 1,
                        "proof_override_used": False, "pause_preserved": True,
                        "ordinary_pow_enabled": False, "recurring_worker_invoked": False,
                        "lock_identities": lock_ids})
        complete_sha = node30.publish_json(run_dir / "broadcast-complete.json", receipt)
    if (node30.free_claim_snapshot(contract.retained) != pause_before or
            transport.runtime_snapshot(node) != runtime_before):
        die("node30 pause or runtime changed during reconciliation")
    print(json.dumps({"result": receipt["result"], "txid": evidence["identity"]["txid"],
                      "broadcast_complete_sha256": complete_sha}, sort_keys=True))


def load_rpc_response(run_dir: pathlib.Path, contract: Contract,
                      intent_sha: str) -> tuple[dict[str, Any], str]:
    response, digest = node30.load_run_receipt(run_dir, "rpc-response.json")
    validate_common(response, "node30-free-claim-one-shot-rpc-response", contract)
    if (response.get("intent_sha256") != intent_sha or
            type(response.get("sendshadowpowclaim_call_count")) is not int or
            response.get("sendshadowpowclaim_call_count") != 1 or
            response.get("published_before_post_call_rpc_reads") is not True or
            "raw_response" not in response):
        die("stored one-shot RPC response acknowledgment is not exact")
    return response, digest


def response_matches_transaction(response: dict[str, Any], transaction: dict[str, Any],
                                 intent: dict[str, Any]) -> None:
    raw = response["raw_response"]
    if (not isinstance(raw, dict) or raw.get("txid") != transaction["identity"]["txid"] or
            raw.get("hex") != transaction["identity"]["hex"] or raw.get("proof") !=
            transaction["proof_output"]["script_asm"][len("OP_RETURN "):] or
            decimal_amount(raw.get("fee"), "stored RPC fee") != FEE_CAP or
            raw.get("vsize") != EXPECTED_VSIZE or
            raw.get("address") != intent["fee_input"]["address"] or
            raw.get("quantum_address") != intent["payout"]["address"]):
        die("broadcast completion does not bind the immediate exact RPC response")


def load_broadcast(run_dir: pathlib.Path, contract: Contract, audit_sha: str,
                   authority_sha: str, intent: dict[str, Any],
                   intent_sha: str) -> tuple[dict[str, Any], str]:
    receipt, digest = node30.load_run_receipt(run_dir, "broadcast-complete.json")
    validate_common(receipt, "node30-free-claim-one-shot-broadcast-complete", contract)
    if (receipt.get("result") not in {"EXACT_ONE_SHOT_BROADCAST",
                                     "EXACT_ONE_SHOT_RECONCILED_WITHOUT_RETRY"} or
            receipt.get("audit_receipt_sha256") != audit_sha or
            receipt.get("authority_sha256") != authority_sha or
            receipt.get("intent_sha256") != intent_sha or
            type(receipt.get("sendshadowpowclaim_call_count")) is not int or
            receipt.get("sendshadowpowclaim_call_count") != 1 or
            receipt.get("proof_override_used") is not False or
            not isinstance(receipt.get("transaction"), dict)):
        die("broadcast completion receipt is not exact")
    transaction = validate_transaction_receipt(
        receipt["transaction"], intent, "broadcast completion")
    response_sha = receipt.get("rpc_response_sha256")
    if receipt["result"] == "EXACT_ONE_SHOT_BROADCAST":
        require_hex64(response_sha, "broadcast RPC response receipt")
        response, loaded_response_sha = load_rpc_response(run_dir, contract, intent_sha)
        if loaded_response_sha != response_sha:
            die("broadcast completion RPC response digest differs")
        response_matches_transaction(response, transaction, intent)
    elif response_sha is not None:
        require_hex64(response_sha, "reconciled RPC response receipt")
        _, loaded_response_sha = load_rpc_response(run_dir, contract, intent_sha)
        if loaded_response_sha != response_sha:
            die("reconciled RPC response digest differs")
    return receipt, digest


def expected_awarded_after(contract: Contract, audit: dict[str, Any]) -> tuple[bytes, str]:
    before_sha = audit["snapshot"]["queue"]["awarded"]["sha256"]
    data, _ = secure_state_file(contract.awarded_file, "awarded ledger", {0o640})
    qaddr = audit["snapshot"]["payout"]["address"]
    original_path = contract.awarded_file
    if hashlib.sha256(data).hexdigest() == before_sha:
        new_data = data + (b"" if not data or data.endswith(b"\n") else b"\n") + qaddr.encode() + b"\n"
    else:
        current = awarded_snapshot(contract)
        if current["records"].count(qaddr) != 1:
            die("awarded ledger differs from both authorized before and exact after states")
        # Reconstruct the only acceptable after bytes from the audit's stored records.
        before_records = audit["snapshot"]["queue"]["awarded"]["records"]
        new_data = ("".join(record + "\n" for record in [*before_records, qaddr])).encode()
        if data != new_data:
            die("awarded ledger has unrelated drift after terminal payout")
    del original_path
    return new_data, hashlib.sha256(new_data).hexdigest()


def install_awarded_after(contract: Contract, audit: dict[str, Any]) -> dict[str, Any]:
    expected_before = audit["snapshot"]["queue"]["awarded"]["sha256"]
    new_data, after_sha = expected_awarded_after(contract, audit)
    current = awarded_snapshot(contract)
    if current["sha256"] == after_sha:
        return {"before_sha256": expected_before, "after_sha256": after_sha,
                "already_complete": True, "atomic_replace": True}
    if current["sha256"] != expected_before:
        die("awarded ledger changed before atomic payout completion")
    old_st = contract.awarded_file.lstat()
    tmp = contract.awarded_file.parent / (
        f".{contract.awarded_file.name}.tmp.{os.getpid()}.{time.time_ns()}")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                 getattr(os, "O_NOFOLLOW", 0), stat.S_IMODE(old_st.st_mode))
    try:
        os.fchown(fd, old_st.st_uid, old_st.st_gid)
        os.fchmod(fd, stat.S_IMODE(old_st.st_mode))
        offset = 0
        while offset < len(new_data):
            offset += os.write(fd, new_data[offset:])
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        latest = contract.awarded_file.lstat()
        if (latest.st_dev != old_st.st_dev or latest.st_ino != old_st.st_ino or
                sha256_file(contract.awarded_file) != expected_before):
            die("awarded ledger changed during atomic payout completion")
        os.replace(tmp, contract.awarded_file)
        node30.base.fsync_dir(contract.awarded_file.parent)
    finally:
        with contextlib.suppress(FileNotFoundError):
            tmp.unlink()
    awarded_snapshot(contract, after_sha)
    return {"before_sha256": expected_before, "after_sha256": after_sha,
            "already_complete": False, "atomic_replace": True}


def terminal_payout(history: Any, transaction: dict[str, Any], blockhash: str,
                    blockheight: int, intent: dict[str, Any]) -> dict[str, Any]:
    if (not isinstance(history, dict) or history.get("schema") != "blackcoin.shadow.script.v1" or
            history.get("scriptPubKey") != transaction["payout"]["scriptPubKey"] or
            history.get("address") != transaction["payout"]["address"] or
            history.get("synthetic") is not True or history.get("merkle_included") is not False or
            not isinstance(history.get("records"), list)):
        die("shadow payout history is unavailable or malformed")
    matches = []
    for row in history["records"]:
        source = row.get("pow_claim_source") if isinstance(row, dict) else None
        if isinstance(source, dict) and source.get("txid") == transaction["identity"]["txid"]:
            matches.append(row)
    if len(matches) != 1:
        die("exact claim does not have one indexed synthetic payout")
    row = matches[0]
    source = row["pow_claim_source"]
    if (row.get("synthetic") is not True or row.get("merkle_included") is not False or
            row.get("mode") != "pow" or row.get("scriptPubKey") !=
            transaction["payout"]["scriptPubKey"] or row.get("address") !=
            transaction["payout"]["address"] or
            row.get("base_anchor", {}).get("blockhash") != blockhash or
            row.get("base_anchor", {}).get("height") != blockheight or
            source.get("disposition") not in {"winner", "reimbursed_loser", "reimbursed_late"} or
            source.get("vout") != 1 or
            source.get("base_fee_known") is not True or
            decimal_amount(source.get("base_fee"), "indexed claim base fee") != FEE_CAP or
            source.get("proof_version") != 2 or source.get("origin_bound") is not False or
            source.get("origin_height") != intent["work"]["height"] or
            source.get("origin_previous_block_hash") is not None or
            source.get("inclusion_height") != blockheight or
            source.get("input_bound") is not False or source.get("claim_outpoint") is not None):
        die("indexed payout does not prove the exact credited QQP2 claim")
    return row


def load_terminal(run_dir: pathlib.Path, contract: Contract, audit: dict[str, Any],
                  intent: dict[str, Any], broadcast: dict[str, Any],
                  broadcast_sha: str) -> tuple[dict[str, Any], str]:
    receipt, digest = node30.load_run_receipt(run_dir, "terminal.json")
    validate_common(receipt, "node30-free-claim-one-shot-terminal", contract)
    transaction = broadcast["transaction"]
    header = receipt.get("active_block_header")
    blockhash = receipt.get("blockhash")
    confirmations = receipt.get("confirmations")
    if (receipt.get("result") != "CONFIRMED_ACTIVE_CHAIN_QUANTUM_PAYOUT" or
            receipt.get("broadcast_complete_sha256") != broadcast_sha or
            receipt.get("txid") != transaction["identity"]["txid"] or
            type(confirmations) is not int or confirmations < 1 or
            not isinstance(blockhash, str) or not HEX64.fullmatch(blockhash) or
            not isinstance(header, dict) or header.get("hash") != blockhash or
            type(header.get("height")) is not int or
            type(header.get("confirmations")) is not int or
            header["confirmations"] < 1 or receipt.get("pause_preserved") is not True or
            receipt.get("ordinary_pow_enabled") is not False or
            receipt.get("pos_active") is not True or
            receipt.get("recurring_worker_invoked") is not False):
        die("terminal receipt is not the exact active-chain completion")
    payout = receipt.get("synthetic_payout")
    terminal_payout({"schema": "blackcoin.shadow.script.v1",
                     "scriptPubKey": transaction["payout"]["scriptPubKey"],
                     "address": transaction["payout"]["address"],
                     "synthetic": True, "merkle_included": False,
                     "records": [payout]}, transaction, blockhash,
                    header["height"], intent)
    new_data, after_sha = expected_awarded_after(contract, audit)
    del new_data
    awarded = receipt.get("awarded_ledger")
    outcome = receipt.get("queue_outcome")
    if (not isinstance(awarded, dict) or
            awarded.get("before_sha256") != audit["snapshot"]["queue"]["awarded"]["sha256"] or
            awarded.get("after_sha256") != after_sha or
            awarded.get("atomic_replace") is not True or
            not isinstance(outcome, dict) or outcome.get("state") != "confirmed" or
            outcome.get("path") != str(contract.done_dir /
                                        audit["snapshot"]["queue"]["outcome_names"]["confirmed"]) or
            outcome.get("atomic_rename") is not True):
        die("terminal receipt does not bind the exact durable queue/awarded outcome")
    return receipt, digest


def monitor_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    node30.base.ensure_secure_dir(run_dir)
    contract = load_contract(run_dir)
    audit, audit_sha = load_audit(run_dir, contract)
    _, authority_sha = load_authority(args, contract, audit, audit_sha)
    intent, intent_sha = load_intent(run_dir, contract, audit, audit_sha, authority_sha)
    broadcast, broadcast_sha = load_broadcast(run_dir, contract, audit_sha,
                                               authority_sha, intent, intent_sha)
    terminal_path = run_dir / "terminal.json"
    if terminal_path.exists() or terminal_path.is_symlink():
        terminal, terminal_sha = load_terminal(
            run_dir, contract, audit, intent, broadcast, broadcast_sha)
        if current_queue_state(contract, audit)[0] != "confirmed":
            die("terminal receipt exists without the exact confirmed queue state")
        awarded_snapshot(contract, terminal["awarded_ledger"]["after_sha256"])
        node30.free_claim_snapshot(contract.retained)
        print(json.dumps({"result": terminal["result"], "txid": terminal["txid"],
                          "terminal_sha256": terminal_sha,
                          "already_complete": True}, sort_keys=True))
        return
    transport = Transport(contract.retained.runtime)
    node = contract.retained.runtime.nodes[0]
    pause_before = node30.free_claim_snapshot(contract.retained)
    exact_node, runtime_before = node30.pin_node(transport, node)
    with node30.mutation_locks(contract.retained) as lock_ids:
        role = node30.role_snapshot(transport, exact_node, False)
        node30.same_wallet_inventory(audit["snapshot"]["role"]["wallet_inventory"],
                                     role["wallet_inventory"], "one-shot terminal monitor")
        transaction = broadcast["transaction"]
        tx = transport.rpc(exact_node, "gettransaction", transaction["identity"]["txid"],
                           True, True)
        confirmations = tx.get("confirmations") if isinstance(tx, dict) else None
        if type(confirmations) is not int or confirmations < 1:
            receipt = base_receipt("node30-free-claim-one-shot-terminal-observation", contract)
            receipt.update({"result": "BROADCAST_PENDING_ACTIVE_CHAIN_CONFIRMATION",
                            "broadcast_complete_sha256": broadcast_sha,
                            "txid": transaction["identity"]["txid"],
                            "confirmations": confirmations if type(confirmations) is int else 0,
                            "queue_state": current_queue_state(contract, audit)[0],
                            "pause_preserved": True, "retry_authorized": False,
                            "lock_identities": lock_ids})
            name = f"monitor-{time.time_ns()}.json"
            digest = node30.publish_json(run_dir / name, receipt)
            print(json.dumps({"result": receipt["result"], "receipt": name,
                              "sha256": digest}, sort_keys=True))
            return
        raw = candidate_response_from_gettransaction(tx)
        if raw is None:
            die("confirmed wallet transaction does not expose exact signed claim bytes")
        raw["address"] = intent["fee_input"]["address"]
        raw["quantum_address"] = intent["payout"]["address"]
        confirmed_evidence = signed_transaction_evidence(transport, exact_node, raw, intent)
        if (validate_transaction_receipt(confirmed_evidence, intent,
                                         "confirmed wallet transaction") !=
                validate_transaction_receipt(transaction, intent,
                                             "authorized broadcast transaction")):
            die("confirmed wallet transaction differs from the authorized signed bytes")
        blockhash = require_hex64(tx.get("blockhash"), "claim confirmation blockhash")
        header = transport.rpc(exact_node, "getblockheader", blockhash)
        if (not isinstance(header, dict) or header.get("hash") != blockhash or
                type(header.get("height")) is not int or
                type(header.get("confirmations")) is not int or header["confirmations"] < 1):
            die("claim confirmation block is not active")
        history = transport.rpc(exact_node, "getshadowscript",
                                transaction["payout"]["scriptPubKey"])
        payout = terminal_payout(history, transaction, blockhash,
                                 header["height"], intent)
        awarded = install_awarded_after(contract, audit)
        outcome = transition_queue(contract, audit, "confirmed")
        receipt = base_receipt("node30-free-claim-one-shot-terminal", contract)
        receipt.update({"result": "CONFIRMED_ACTIVE_CHAIN_QUANTUM_PAYOUT",
                        "broadcast_complete_sha256": broadcast_sha,
                        "txid": transaction["identity"]["txid"],
                        "confirmations": confirmations, "blockhash": blockhash,
                        "active_block_header": header, "synthetic_payout": payout,
                        "awarded_ledger": awarded, "queue_outcome": outcome,
                        "pause_preserved": True, "ordinary_pow_enabled": False,
                        "pos_active": True, "recurring_worker_invoked": False,
                        "lock_identities": lock_ids})
        terminal_sha = node30.publish_json(run_dir / "terminal.json", receipt)
    if (node30.free_claim_snapshot(contract.retained) != pause_before or
            transport.runtime_snapshot(node) != runtime_before):
        die("node30 pause or runtime changed during terminal payout monitor")
    print(json.dumps({"result": receipt["result"], "txid": receipt["txid"],
                      "terminal_sha256": terminal_sha}, sort_keys=True))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    audit = commands.add_parser("audit")
    audit.add_argument("--runtime-manifest", required=True)
    audit.add_argument("--run-dir", required=True)
    audit.set_defaults(func=audit_command)
    for name, func in [("execute", execute_command), ("reconcile", reconcile_command),
                       ("monitor", monitor_command)]:
        command = commands.add_parser(name)
        command.add_argument("--run-dir", required=True)
        command.add_argument("--authority", required=True)
        command.add_argument("--authority-sha256", required=True)
        command.set_defaults(func=func)
    return result


def main(argv: Sequence[str] | None = None) -> int:
    global CONTROLLER_RUNTIME_IDENTITY
    os.umask(0o077)
    try:
        if not test_mode():
            CONTROLLER_RUNTIME_IDENTITY = validate_controller_runtime()
    except (node30.base.GateError, node30.GateError, GateError, OSError) as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1
    for name in ["PYTHONPATH", "PYTHONHOME", "BASH_ENV", "ENV", "CDPATH"]:
        os.environ.pop(name, None)
    args = parser().parse_args(argv)
    try:
        args.func(args)
    except (node30.base.GateError, node30.GateError, GateError, OSError,
            subprocess.TimeoutExpired) as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
