#!/usr/bin/python3
"""Terminalize one deterministic node30 rejection and authorize requeue only.

This fleet-only companion never calls ``sendshadowpowclaim`` or any other
wallet-mutating RPC.  It hash-pins the original one-shot tool so that it can
validate the consumed audit/authority/intent chain which produced the exact
installed-v30.1.4 ``shadow-proof-mempool-limit`` rejection.  A rejected item
may return to the ingress queue only after a fresh, separate requeue authority,
an exact no-transaction reconciliation, and a stable empty shadow-proof
mempool slot.  The eventual financial call still requires a new one-shot audit
and a different authority; the consumed authority is never retried.
"""

from __future__ import annotations

import argparse
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
from typing import Any, NoReturn, Sequence


CONTRACT = "installed-v30.1.4-node30-free-claim-rejection-requeue/v1"
RECEIPT_SCHEMA = 1
LEGACY_TOOL_RELATIVE = pathlib.Path("node30_free_claim_one_shot.py")
LEGACY_TOOL_SHA256 = "26e38fbd46cd427642f73daedfbbc08dfffcb1e4a166db7c3e0abb6006e832b2"
STAKING_RPC_SOURCE_SHA256 = "611e7acb2b6d90edf2df988adae33b17a67e398e189de1427a0bbb40fbbd70df"
VALIDATION_SOURCE_SHA256 = "1fa0a9d2777d680d2230a9201e89ed8fda4c73b9bccdf5db3d9d6df6d30b5270"
SHADOW_SOURCE_SHA256 = "03960e32f9edc34c1ab34849cd799956f6ddd1a70e23363c195c271ea4af1ceb"
DEFINITIVE_REJECTION = (
    "node30 sendshadowpowclaim: error code: -26\n"
    "error message:\n"
    "Shadow PoW claim rejected: shadow-proof-mempool-limit"
)
RECONCILE_NAME = re.compile(r"^reconcile-[1-9][0-9]*[.]json$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
SNAPSHOT_ATTEMPTS = 3
TEST_TRANSPORT_SHA256 = "a41bc2ee67eb00c6849a9cb2fad9f5c5eb7d476b85c0c540d7a330522cfa804a"
MOVE_PROTOCOL = "hard-link-fsync-unlink-fsync-noreplace/v1"


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


def load_legacy_tool() -> Any:
    path = (pathlib.Path(__file__).resolve(strict=True).parent /
            LEGACY_TOOL_RELATIVE).resolve(strict=True)
    if sha256_file(path) != LEGACY_TOOL_SHA256:
        raise RuntimeError("hash-pinned node30 one-shot tool changed")
    spec = importlib.util.spec_from_file_location("node30_rejection_legacy_tool", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load hash-pinned node30 one-shot tool")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


try:
    legacy = load_legacy_tool()
except (OSError, RuntimeError) as exc:
    print(f"FATAL: {exc}", file=sys.stderr)
    raise SystemExit(1)


class GateError(legacy.GateError):
    pass


def die(message: str) -> NoReturn:
    raise GateError(message)


def require_hex64(value: Any, label: str) -> str:
    if not isinstance(value, str) or not HEX64.fullmatch(value):
        die(f"{label} is not a lowercase 32-byte hex identity")
    return value


class Transport(legacy.Transport):
    """Add only the two read-only mempool RPCs needed for slot clearance."""

    READ_ONLY_EXTRA = {"getrawmempool", "getrawtransaction"}

    def rpc(self, node: Any, method: str, *params: Any) -> Any:
        if method not in self.READ_ONLY_EXTRA:
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
            return json.loads(self.run(cli_args, timeout=90))
        except (legacy.node30.base.GateError, json.JSONDecodeError) as exc:
            raise legacy.node30.base.RpcError(node.node, method, str(exc)) from exc


def tool_sha() -> str:
    return sha256_file(pathlib.Path(__file__).resolve(strict=True))


def base_receipt(kind: str, contract: Any) -> dict[str, Any]:
    storage = legacy.current_free_claim_storage(contract)
    return {
        "schema": RECEIPT_SCHEMA,
        "contract": CONTRACT,
        "kind": kind,
        "tool_sha256": tool_sha(),
        "legacy_one_shot_tool_sha256": LEGACY_TOOL_SHA256,
        "node30_primitive_sha256": legacy.NODE30_PRIMITIVE_SHA256,
        "installed_staking_rpc_source_sha256": STAKING_RPC_SOURCE_SHA256,
        "installed_validation_source_sha256": VALIDATION_SOURCE_SHA256,
        "installed_shadow_source_sha256": SHADOW_SOURCE_SHA256,
        "controller_runtime_sha256": sha256_json(legacy.controller_runtime_identity()),
        "controller_runtime": legacy.controller_runtime_identity(),
        "free_claim_storage_sha256": sha256_json(storage),
        "free_claim_storage": storage,
        "runtime_manifest_sha256": contract.sha256,
        "installed_source": {
            "commit": legacy.SOURCE_COMMIT,
            "tree": legacy.SOURCE_TREE,
            "signer_fingerprint": legacy.SOURCE_SIGNER,
        },
        "node": legacy.NODE,
        "role": "free_claim",
        "ordinary_pow_must_remain_disabled": True,
        "pos_must_remain_active": True,
        "pause_marker_must_remain_present": True,
        "recurring_worker_authorized": False,
        "fee_rate_atoms_per_vbyte": legacy.FEE_RATE_ATOMS_PER_VBYTE,
        "maximum_fee_blk": f"{legacy.FEE_CAP:.8f}",
        "maximum_tries": legacy.MAX_TRIES,
        "user_orders": legacy.USER_ORDERS,
        "user_order_sha256": legacy.USER_ORDER_SHA256,
    }


def validate_common(receipt: Any, kind: str, contract: Any) -> dict[str, Any]:
    expected = base_receipt(kind, contract)
    if not isinstance(receipt, dict):
        die(f"{kind} receipt is not an object")
    for key, value in expected.items():
        if receipt.get(key) != value:
            die(f"{kind} receipt field {key} differs from the exact contract")
    return receipt


def rejected_name(audit: dict[str, Any]) -> str:
    basename = audit["snapshot"]["queue"]["item"]["basename"]
    if not legacy.QUEUE_NAME.fullmatch(basename):
        die("legacy queue basename is not canonical")
    return basename[:-5] + ".rejected.json"


def directory_expected(contract: Any, audit: dict[str, Any], path: pathlib.Path
                       ) -> tuple[dict[str, Any], str, int]:
    queue = audit["snapshot"]["queue"]
    if path == contract.queue_dir:
        return queue["queue_directory"], "Free-Claim queue", 0o770
    if path == contract.done_dir:
        return queue["done_directory"], "Free-Claim done directory", 0o750
    die("lifecycle move parent is outside the exact queue/done directories")


def pinned_directory(contract: Any, audit: dict[str, Any], path: pathlib.Path
                     ) -> tuple[int, dict[str, Any], str]:
    expected, label, mode = directory_expected(contract, audit, path)
    current = legacy.secure_dir(path, label, mode, contract.pool_group_gid)
    projection = {
        "path": str(path), "device": current.st_dev, "inode": current.st_ino,
        "uid": current.st_uid, "gid": current.st_gid,
        "mode": format(stat.S_IMODE(current.st_mode), "04o"),
    }
    if projection != expected:
        die(f"{label} differs from the exact audited directory identity")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    fd = os.open(path, flags)
    opened = os.fstat(fd)
    if (not stat.S_ISDIR(opened.st_mode) or opened.st_dev != current.st_dev or
            opened.st_ino != current.st_ino or opened.st_uid != current.st_uid or
            opened.st_gid != current.st_gid or
            stat.S_IMODE(opened.st_mode) != stat.S_IMODE(current.st_mode)):
        os.close(fd)
        die(f"{label} changed while its directory descriptor was pinned")
    return fd, projection, label


def revalidate_pinned_directory(path: pathlib.Path, fd: int,
                                expected: dict[str, Any], label: str) -> None:
    opened = os.fstat(fd)
    current = path.lstat()
    projection = {
        "path": str(path), "device": current.st_dev, "inode": current.st_ino,
        "uid": current.st_uid, "gid": current.st_gid,
        "mode": format(stat.S_IMODE(current.st_mode), "04o"),
    }
    if (projection != expected or not stat.S_ISDIR(current.st_mode) or
            stat.S_ISLNK(current.st_mode) or path.resolve(strict=True) != path or
            opened.st_dev != current.st_dev or opened.st_ino != current.st_ino or
            opened.st_uid != current.st_uid or opened.st_gid != current.st_gid or
            stat.S_IMODE(opened.st_mode) != stat.S_IMODE(current.st_mode)):
        die(f"{label} path or inode changed during lifecycle movement")


def item_at(directory_fd: int, name: str, expected: dict[str, Any],
            allowed_nlinks: set[int], label: str) -> os.stat_result | None:
    try:
        observed = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    if (not stat.S_ISREG(observed.st_mode) or stat.S_ISLNK(observed.st_mode) or
            observed.st_dev != expected["device"] or
            observed.st_ino != expected["inode"] or
            observed.st_uid != expected["uid"] or
            observed.st_gid != expected["gid"] or
            stat.S_IMODE(observed.st_mode) != int(expected["mode"], 8) or
            observed.st_size != expected["size"] or
            observed.st_nlink not in allowed_nlinks):
        die(f"{label} does not have the exact audited inode identity")
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
    fd = os.open(name, flags, dir_fd=directory_fd)
    try:
        opened = os.fstat(fd)
        if (opened.st_dev != observed.st_dev or opened.st_ino != observed.st_ino or
                opened.st_nlink != observed.st_nlink):
            die(f"{label} changed while its inode was opened")
        digest = hashlib.sha256()
        size = 0
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
        if size != expected["size"] or digest.hexdigest() != expected["sha256"]:
            die(f"{label} bytes differ from the exact audited item")
    finally:
        os.close(fd)
    return observed


def lifecycle_move_state(contract: Any, audit: dict[str, Any],
                         source: pathlib.Path, target: pathlib.Path,
                         label: str) -> tuple[str, bool]:
    """Return source/target/both without following or trusting pathnames."""
    if (source.parent not in {contract.queue_dir, contract.done_dir} or
            target.parent not in {contract.queue_dir, contract.done_dir} or
            source.name in {"", ".", ".."} or target.name in {"", ".", ".."} or
            "/" in source.name or "/" in target.name or source == target):
        die(f"{label} paths are not exact lifecycle children")
    source_fd = target_fd = -1
    try:
        source_fd, _, _ = pinned_directory(contract, audit, source.parent)
        target_fd, _, _ = pinned_directory(contract, audit, target.parent)
        expected = audit["snapshot"]["queue"]["item"]
        source_st = item_at(source_fd, source.name, expected, {1, 2},
                            f"{label} source")
        target_st = item_at(target_fd, target.name, expected, {1, 2},
                            f"{label} target")
        if source_st is not None and target_st is not None:
            if (source_st.st_dev != target_st.st_dev or
                    source_st.st_ino != target_st.st_ino or
                    source_st.st_nlink != 2 or target_st.st_nlink != 2):
                die(f"{label} destination collision is not the exact crash link")
            return "both", True
        if source_st is not None:
            if source_st.st_nlink != 1:
                die(f"{label} source has an unrecognized external hard link")
            return "source", False
        if target_st is not None:
            if target_st.st_nlink != 1:
                die(f"{label} target has an unrecognized external hard link")
            return "target", False
        die(f"{label} has neither exact source nor target")
    finally:
        if target_fd >= 0:
            os.close(target_fd)
        if source_fd >= 0:
            os.close(source_fd)


def no_clobber_lifecycle_move(contract: Any, audit: dict[str, Any],
                              source: pathlib.Path, target: pathlib.Path,
                              label: str) -> tuple[dict[str, Any], dict[str, Any]]:
    """Move one exact inode without replacement and heal the sole crash pair."""
    source_fd = target_fd = -1
    try:
        source_fd, source_parent, source_label = pinned_directory(
            contract, audit, source.parent)
        target_fd, target_parent, target_label = pinned_directory(
            contract, audit, target.parent)
        expected = audit["snapshot"]["queue"]["item"]
        source_st = item_at(source_fd, source.name, expected, {1, 2},
                            f"{label} source")
        target_st = item_at(target_fd, target.name, expected, {1, 2},
                            f"{label} target")
        already_complete = source_st is None and target_st is not None
        crash_reconciled = False
        if source_st is not None and target_st is not None:
            if (source_st.st_dev != target_st.st_dev or
                    source_st.st_ino != target_st.st_ino or
                    source_st.st_nlink != 2 or target_st.st_nlink != 2):
                die(f"{label} destination collision will not be overwritten")
            crash_reconciled = True
        elif source_st is not None:
            if source_st.st_nlink != 1:
                die(f"{label} source has an unrecognized external hard link")
            try:
                os.link(source.name, target.name, src_dir_fd=source_fd,
                        dst_dir_fd=target_fd, follow_symlinks=False)
            except FileExistsError:
                die(f"{label} destination appeared and will not be overwritten")
            os.fsync(target_fd)
            linked_source = item_at(source_fd, source.name, expected, {2},
                                    f"{label} linked source")
            linked_target = item_at(target_fd, target.name, expected, {2},
                                    f"{label} linked target")
            if (linked_source is None or linked_target is None or
                    linked_source.st_dev != linked_target.st_dev or
                    linked_source.st_ino != linked_target.st_ino):
                die(f"{label} no-clobber link did not preserve one exact inode")
        elif target_st is not None:
            if target_st.st_nlink != 1:
                die(f"{label} target has an unrecognized external hard link")
        else:
            die(f"{label} has neither exact source nor target")
        if source_st is not None:
            os.unlink(source.name, dir_fd=source_fd)
            os.fsync(source_fd)
        final_st = item_at(target_fd, target.name, expected, {1},
                           f"{label} final target")
        if final_st is None:
            die(f"{label} final target is absent")
        revalidate_pinned_directory(
            source.parent, source_fd, source_parent, source_label)
        revalidate_pinned_directory(
            target.parent, target_fd, target_parent, target_label)
    finally:
        if target_fd >= 0:
            os.close(target_fd)
        if source_fd >= 0:
            os.close(source_fd)
    final, _ = legacy.queue_file_snapshot(
        target, contract, f"{label} final item", expected["sha256"], expected)
    return final, {
        "move_protocol": MOVE_PROTOCOL,
        "no_clobber": True,
        "same_inode": True,
        "already_complete": already_complete,
        "crash_link_reconciled": crash_reconciled,
        "atomic_rename": False,
    }


def source_chain(args: argparse.Namespace) -> tuple[Any, dict[str, Any], str,
                                                    dict[str, Any], str,
                                                    dict[str, Any], str,
                                                    dict[str, Any], str,
                                                    dict[str, Any], str]:
    run_dir = pathlib.Path(args.source_run if hasattr(args, "source_run") else args.run_dir)
    legacy.node30.base.ensure_secure_dir(run_dir)
    contract = legacy.load_contract(run_dir)
    audit, audit_sha = legacy.load_audit(run_dir, contract)
    source_authority = getattr(args, "source_authority", None) or args.authority
    source_authority_sha = (getattr(args, "source_authority_sha256", None) or
                            args.authority_sha256)
    if pathlib.Path(source_authority) != run_dir / "AUTHORITY.json":
        die("legacy authority must be the canonical source-run AUTHORITY.json")
    authority_args = argparse.Namespace(authority=source_authority,
                                        authority_sha256=source_authority_sha)
    _, authority_sha = legacy.load_authority(authority_args, contract, audit, audit_sha)
    intent, intent_sha = legacy.load_intent(
        run_dir, contract, audit, audit_sha, authority_sha)
    unknown, unknown_sha = legacy.node30.load_run_receipt(run_dir, "rpc-unknown.json")
    legacy.validate_common(
        unknown, "node30-free-claim-one-shot-rpc-unknown", contract)
    unknown_fields = set(legacy.base_receipt(
        "node30-free-claim-one-shot-rpc-unknown", contract)) | {
            "state", "intent_sha256", "error", "queue_outcome",
            "retry_authorized", "sendshadowpowclaim_call_count",
        }
    expected_uncertain = contract.done_dir / audit["snapshot"]["queue"]["outcome_names"]["uncertain"]
    queue_outcome = unknown.get("queue_outcome")
    if (set(unknown) != unknown_fields or
            unknown.get("state") != "UNKNOWN_AUTHORITY_CONSUMED_NEVER_RETRY" or
            unknown.get("intent_sha256") != intent_sha or
            unknown.get("error") != DEFINITIVE_REJECTION or
            unknown.get("retry_authorized") is not False or
            unknown.get("sendshadowpowclaim_call_count") != 1 or
            not isinstance(queue_outcome, dict) or
            queue_outcome.get("state") != "uncertain" or
            queue_outcome.get("path") != str(expected_uncertain) or
            queue_outcome.get("sha256") != audit["snapshot"]["queue"]["item"]["sha256"] or
            queue_outcome.get("device") != audit["snapshot"]["queue"]["item"]["device"] or
            queue_outcome.get("inode") != audit["snapshot"]["queue"]["item"]["inode"] or
            queue_outcome.get("atomic_rename") is not True):
        die("legacy RPC rejection receipt is not the exact deterministic mempool-limit result")
    reconcile_path = pathlib.Path(args.reconcile_receipt)
    if (reconcile_path.parent != run_dir or not RECONCILE_NAME.fullmatch(reconcile_path.name)):
        die("reconcile receipt is not a canonical source-run child")
    reconcile, reconcile_sha = legacy.node30.load_run_receipt(run_dir, reconcile_path.name)
    if reconcile_sha != require_hex64(args.reconcile_sha256, "reconcile receipt SHA256"):
        die("reconcile receipt SHA256 differs")
    legacy.validate_common(
        reconcile, "node30-free-claim-one-shot-reconcile-observation", contract)
    reconcile_fields = set(legacy.base_receipt(
        "node30-free-claim-one-shot-reconcile-observation", contract)) | {
            "result", "audit_receipt_sha256", "authority_sha256",
            "intent_sha256", "queue_state", "queue_path", "retry_authorized",
            "candidate_count", "lock_identities",
        }
    if (set(reconcile) != reconcile_fields or
            reconcile.get("result") != "NO_EXACT_TRANSACTION_YET_AUTHORITY_CONSUMED" or
            reconcile.get("audit_receipt_sha256") != audit_sha or
            reconcile.get("authority_sha256") != authority_sha or
            reconcile.get("intent_sha256") != intent_sha or
            reconcile.get("queue_state") != "uncertain" or
            reconcile.get("queue_path") != str(expected_uncertain) or
            reconcile.get("retry_authorized") is not False or
            reconcile.get("candidate_count") != 0):
        die("legacy reconciliation does not prove exact no-transaction state")
    return (contract, audit, audit_sha, intent, intent_sha, unknown, unknown_sha,
            reconcile, reconcile_sha, {"authority_sha256": authority_sha,
                                       "source_run": str(run_dir),
                                       "source_authority": str(pathlib.Path(source_authority))})


def stable_role(transport: Any, node: Any) -> dict[str, Any]:
    """Retry only the primitive's exact cross-RPC recovery/tip race."""
    for attempt in range(1, SNAPSHOT_ATTEMPTS + 1):
        try:
            return legacy.node30.role_snapshot(transport, node, False)
        except legacy.node30.GateError as exc:
            if (str(exc) != "node30 recovery inventory is incoherent" or
                    attempt == SNAPSHOT_ATTEMPTS):
                raise
    die("node30 role snapshot attempts exhausted")


def live_no_transaction(transport: Any, node: Any, audit: dict[str, Any],
                        intent: dict[str, Any]) -> dict[str, Any]:
    role = stable_role(transport, node)
    legacy.node30.same_wallet_inventory(
        audit["snapshot"]["role"]["wallet_inventory"], role["wallet_inventory"],
        "definitive-rejection reconciliation")
    candidates = legacy.reconcile_candidates(transport, node, intent)
    if candidates:
        die("an exact transaction exists; deterministic rejection cannot be terminalized")
    txids = legacy.wallet_txids(transport, node)
    return {"candidate_count": 0, "wallet_txids": txids,
            "wallet_txids_sha256": sha256_json(txids), "role": role}


def current_rejection_item(contract: Any, audit: dict[str, Any],
                           allow_uncertain: bool) -> tuple[str, pathlib.Path, dict[str, Any]]:
    for parent in [contract.queue_dir, contract.done_dir]:
        fd, _, _ = pinned_directory(contract, audit, parent)
        os.close(fd)
    item = audit["snapshot"]["queue"]["item"]
    names = audit["snapshot"]["queue"]["outcome_names"]
    paths = {
        "queued": contract.queue_dir / names["queued"],
        "broadcast": contract.done_dir / names["broadcast"],
        "uncertain": contract.done_dir / names["uncertain"],
        "confirmed": contract.done_dir / names["confirmed"],
        "rejected": contract.done_dir / rejected_name(audit),
    }
    present = [state for state, path in paths.items() if path.exists() or path.is_symlink()]
    allowed = {"rejected", "uncertain"} if allow_uncertain else {"rejected"}
    if len(present) != 1 or present[0] not in allowed:
        die("Free-Claim item is not in the exact rejection lifecycle state")
    state = present[0]
    snapshot, _ = legacy.queue_file_snapshot(
        paths[state], contract, f"Free-Claim {state} item", item["sha256"], item)
    if any(contract.queue_dir.iterdir()):
        die("Free-Claim ingress queue is not otherwise empty")
    return state, paths[state], snapshot


def rejection_receipt_path(run_dir: pathlib.Path) -> pathlib.Path:
    return run_dir / "definitive-rejection.json"


def load_definitive_rejection(run_dir: pathlib.Path, contract: Any,
                              audit: dict[str, Any], audit_sha: str,
                              intent_sha: str, unknown_sha: str,
                              reconcile_sha: str, authority_sha: str
                              ) -> tuple[dict[str, Any], str]:
    receipt, digest = legacy.node30.load_run_receipt(run_dir, "definitive-rejection.json")
    validate_common(receipt, "node30-free-claim-definitive-rejection", contract)
    exact_fields = set(base_receipt(
        "node30-free-claim-definitive-rejection", contract)) | {
            "result", "audit_receipt_sha256", "authority_sha256",
            "intent_sha256", "rpc_unknown_sha256", "reconcile_receipt_sha256",
            "rpc_error", "installed_call_order", "candidate_count",
            "wallet_txids_sha256", "queue_outcome", "old_authority_consumed",
            "old_authority_retry_authorized", "new_attempt_authorized",
            "lock_identities",
        }
    outcome = receipt.get("queue_outcome")
    outcome_fields = {
        "state", "path", "sha256", "device", "inode", "move_protocol",
        "no_clobber", "same_inode", "already_complete",
        "crash_link_reconciled", "atomic_rename",
    }
    if (set(receipt) != exact_fields or
            receipt.get("result") != "DEFINITIVE_PRECOMMIT_MEMPOOL_LIMIT_REJECTION" or
            receipt.get("audit_receipt_sha256") != audit_sha or
            receipt.get("authority_sha256") != authority_sha or
            receipt.get("intent_sha256") != intent_sha or
            receipt.get("rpc_unknown_sha256") != unknown_sha or
            receipt.get("reconcile_receipt_sha256") != reconcile_sha or
            receipt.get("rpc_error") != DEFINITIVE_REJECTION or
            receipt.get("installed_call_order") !=
            "test_accept_before_wallet_persistence_and_relay" or
            receipt.get("candidate_count") != 0 or
            not isinstance(receipt.get("wallet_txids_sha256"), str) or
            not HEX64.fullmatch(receipt["wallet_txids_sha256"]) or
            receipt.get("old_authority_consumed") is not True or
            receipt.get("old_authority_retry_authorized") is not False or
            receipt.get("new_attempt_authorized") is not False or
            not isinstance(outcome, dict) or set(outcome) != outcome_fields or
            outcome.get("state") != "rejected" or
            outcome.get("path") != str(contract.done_dir / rejected_name(audit)) or
            outcome.get("sha256") != audit["snapshot"]["queue"]["item"]["sha256"] or
            outcome.get("device") != audit["snapshot"]["queue"]["item"]["device"] or
            outcome.get("inode") != audit["snapshot"]["queue"]["item"]["inode"] or
            outcome.get("move_protocol") != MOVE_PROTOCOL or
            outcome.get("no_clobber") is not True or
            outcome.get("same_inode") is not True or
            type(outcome.get("already_complete")) is not bool or
            type(outcome.get("crash_link_reconciled")) is not bool or
            outcome.get("atomic_rename") is not False):
        die("definitive rejection receipt is not exact")
    return receipt, digest


def terminalize_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    (contract, audit, audit_sha, intent, intent_sha, _unknown, unknown_sha,
     _reconcile, reconcile_sha, source) = source_chain(args)
    terminal_path = rejection_receipt_path(run_dir)
    if terminal_path.exists() or terminal_path.is_symlink():
        receipt, digest = load_definitive_rejection(
            run_dir, contract, audit, audit_sha, intent_sha, unknown_sha,
            reconcile_sha, source["authority_sha256"])
        current_rejection_item(contract, audit, False)
        print(json.dumps({"result": receipt["result"],
                          "definitive_rejection_sha256": digest,
                          "already_complete": True}, sort_keys=True))
        return
    transport = Transport(contract.retained.runtime)
    node = contract.retained.runtime.nodes[0]
    with legacy.node30.mutation_locks(contract.retained) as lock_ids:
        pause_before = legacy.node30.free_claim_snapshot(contract.retained)
        exact_node, runtime_before = legacy.node30.pin_node(transport, node)
        proof = live_no_transaction(transport, exact_node, audit, intent)
        names = audit["snapshot"]["queue"]["outcome_names"]
        source_path = contract.done_dir / names["uncertain"]
        target = contract.done_dir / rejected_name(audit)
        forbidden = [contract.queue_dir / names["queued"],
                     contract.done_dir / names["broadcast"],
                     contract.done_dir / names["confirmed"]]
        if (any(path.exists() or path.is_symlink() for path in forbidden) or
                any(contract.queue_dir.iterdir())):
            die("Free-Claim item has a conflicting terminalization lifecycle state")
        lifecycle_move_state(
            contract, audit, source_path, target, "rejection terminalization")
        item, move = no_clobber_lifecycle_move(
            contract, audit, source_path, target, "rejection terminalization")
        if any(contract.queue_dir.iterdir()):
            die("Free-Claim ingress queue changed during rejection terminalization")
        if (legacy.node30.free_claim_snapshot(contract.retained) != pause_before or
                transport.runtime_snapshot(node) != runtime_before):
            die("node30 pause or runtime changed during rejection terminalization")
        receipt = base_receipt("node30-free-claim-definitive-rejection", contract)
        receipt.update({
            "result": "DEFINITIVE_PRECOMMIT_MEMPOOL_LIMIT_REJECTION",
            "audit_receipt_sha256": audit_sha,
            "authority_sha256": source["authority_sha256"],
            "intent_sha256": intent_sha,
            "rpc_unknown_sha256": unknown_sha,
            "reconcile_receipt_sha256": reconcile_sha,
            "rpc_error": DEFINITIVE_REJECTION,
            "installed_call_order": "test_accept_before_wallet_persistence_and_relay",
            "candidate_count": 0,
            "wallet_txids_sha256": proof["wallet_txids_sha256"],
            "queue_outcome": {"state": "rejected", "path": str(target),
                              "sha256": item["sha256"], "device": item["device"],
                              "inode": item["inode"], **move},
            "old_authority_consumed": True,
            "old_authority_retry_authorized": False,
            "new_attempt_authorized": False,
            "lock_identities": lock_ids,
        })
        digest = legacy.node30.publish_json(terminal_path, receipt)
    print(json.dumps({"result": receipt["result"],
                      "definitive_rejection_sha256": digest}, sort_keys=True))


def mempool_shadow_inventory(transport: Any, node: Any) -> dict[str, Any]:
    prefix_hex = legacy.QQ_PREFIX.hex()
    for attempt in range(1, SNAPSHOT_ATTEMPTS + 1):
        chain_before = legacy.node30.base.validate_chain(
            transport.rpc(node, "getblockchaininfo"), legacy.NODE)
        goldrush = transport.rpc(node, "getgoldrushinfo")
        if (not isinstance(goldrush, dict) or goldrush.get("active") is not True or
                goldrush.get("competing_claim_rule_active_next_block") is not False or
                goldrush.get("qqp4_active_next_block") is not False):
            die("node30 is not in the exact one-slot QQP2 mempool regime")
        txids_before = transport.rpc(node, "getrawmempool", False)
        if (not isinstance(txids_before, list) or
                any(not isinstance(txid, str) or not HEX64.fullmatch(txid)
                    for txid in txids_before) or
                len(txids_before) != len(set(txids_before))):
            die("node30 raw mempool inventory is malformed")
        proof_txids: list[str] = []
        for txid in sorted(txids_before):
            decoded = transport.rpc(node, "getrawtransaction", txid, True)
            if (not isinstance(decoded, dict) or decoded.get("txid") != txid or
                    not isinstance(decoded.get("vout"), list)):
                die("node30 mempool transaction projection is malformed")
            found = False
            for output in decoded["vout"]:
                script = output.get("scriptPubKey") if isinstance(output, dict) else None
                asm = script.get("asm") if isinstance(script, dict) else None
                if not isinstance(asm, str) or not asm.startswith("OP_RETURN "):
                    continue
                proof_hex = asm[len("OP_RETURN "):]
                if not proof_hex.startswith(prefix_hex):
                    continue
                if (script.get("type") != "nulldata" or
                        not re.fullmatch(r"[0-9a-f]+", proof_hex) or len(proof_hex) % 2 or
                        script.get("hex") != legacy.op_return_script(proof_hex)):
                    die("node30 mempool QQSPROOF output is not canonical")
                found = True
            if found:
                proof_txids.append(txid)
        txids_after = transport.rpc(node, "getrawmempool", False)
        chain_after = legacy.node30.base.validate_chain(
            transport.rpc(node, "getblockchaininfo"), legacy.NODE)
        if (txids_after != txids_before or
                legacy.node30.base.chain_identity(chain_after) !=
                legacy.node30.base.chain_identity(chain_before)):
            if attempt == SNAPSHOT_ATTEMPTS:
                die("node30 mempool or active tip moved throughout clearance sampling")
            continue
        return {
            "chain": {"height": chain_after["blocks"],
                      "tip": chain_after["bestblockhash"]},
            "mempool_txids": sorted(txids_after),
            "mempool_txids_sha256": sha256_json(sorted(txids_after)),
            "mempool_transaction_count": len(txids_after),
            "shadow_proof_txids": proof_txids,
            "shadow_proof_txids_sha256": sha256_json(proof_txids),
            "shadow_proof_count": len(proof_txids),
            "shadow_proof_limit": 1,
            "slot_clear": len(proof_txids) == 0,
            "snapshot_attempts": attempt,
        }
    die("node30 mempool clearance attempts exhausted")


def readiness_snapshot(transport: Any, node: Any, contract: Any,
                       audit: dict[str, Any], intent: dict[str, Any]) -> dict[str, Any]:
    role = stable_role(transport, node)
    legacy.node30.same_wallet_inventory(
        audit["snapshot"]["role"]["wallet_inventory"], role["wallet_inventory"],
        "requeue readiness")
    state, path, item = current_rejection_item(contract, audit, False)
    del state
    payout = legacy.validate_payout_address(
        transport, node, item["record"]["quantum_address"])
    if payout != audit["snapshot"]["payout"]:
        die("rejected queue payout differs from the consumed one-shot")
    if payout["address"] in legacy.awarded_snapshot(contract)["records"]:
        die("rejected queue payout is already awarded")
    candidates = legacy.reconcile_candidates(transport, node, intent)
    if candidates:
        die("an exact old-authority transaction appeared; requeue is forbidden")
    fee_input = legacy.fee_input_inventory(transport, node)
    mempool = mempool_shadow_inventory(transport, node)
    if mempool["slot_clear"] is not True or mempool["shadow_proof_count"] != 0:
        die("node30 shadow-proof mempool slot is not clear")
    return {
        "role": role,
        "queue": {"state": "rejected", "path": str(path), "item": item},
        "payout": payout,
        "fee_input": fee_input,
        "mempool": mempool,
        "candidate_count": 0,
    }


def requeue_audit_command(args: argparse.Namespace) -> None:
    requeue_run = pathlib.Path(args.run_dir)
    legacy.node30.base.ensure_secure_dir(requeue_run, create=True)
    (contract, audit, audit_sha, intent, intent_sha, _unknown, unknown_sha,
     _reconcile, reconcile_sha, source) = source_chain(args)
    definitive, definitive_sha = load_definitive_rejection(
        pathlib.Path(source["source_run"]), contract, audit, audit_sha, intent_sha,
        unknown_sha, reconcile_sha, source["authority_sha256"])
    del definitive
    legacy.node30.publish_bytes(
        requeue_run / "runtime-manifest.json",
        legacy.node30.base.owned_secure_file(contract.path, "runtime manifest",
                                             contract.sha256))
    transport = Transport(contract.retained.runtime)
    node = contract.retained.runtime.nodes[0]
    with legacy.node30.mutation_locks(contract.retained) as lock_ids:
        pause_before = legacy.node30.free_claim_snapshot(contract.retained)
        exact_node, runtime_before = legacy.node30.pin_node(transport, node)
        snapshot = readiness_snapshot(transport, exact_node, contract, audit, intent)
        if (legacy.node30.free_claim_snapshot(contract.retained) != pause_before or
                transport.runtime_snapshot(node) != runtime_before):
            die("node30 pause or runtime changed during requeue audit")
        receipt = base_receipt("node30-free-claim-requeue-audit", contract)
        receipt.update({
            "result": "READY_FOR_SEPARATE_REQUEUE_ONLY_AUTHORITY",
            "mutation_performed": False,
            "source_run": source["source_run"],
            "source_authority": source["source_authority"],
            "source_authority_sha256": source["authority_sha256"],
            "source_audit_sha256": audit_sha,
            "source_intent_sha256": intent_sha,
            "source_rpc_unknown_sha256": unknown_sha,
            "source_reconcile_receipt": pathlib.Path(args.reconcile_receipt).name,
            "source_reconcile_sha256": reconcile_sha,
            "source_definitive_rejection_sha256": definitive_sha,
            "snapshot": snapshot,
            "lock_identities": lock_ids,
        })
        receipt["required_authority"] = {
            "schema": RECEIPT_SCHEMA,
            "kind": "node30-free-claim-requeue-authority",
            "decision": "REPLACE_WITH_authorize_AFTER_REVIEW",
            "action": "requeue_definitively_rejected_item_only",
            "node": legacy.NODE,
            "role": "free_claim",
            "audit_receipt_sha256": "REPLACE_WITH_REQUEUE_AUDIT_SHA256",
            "runtime_manifest_sha256": contract.sha256,
            "tool_sha256": tool_sha(),
            "legacy_one_shot_tool_sha256": LEGACY_TOOL_SHA256,
            "source_authority_sha256": source["authority_sha256"],
            "source_intent_sha256": intent_sha,
            "source_definitive_rejection_sha256": definitive_sha,
            "queue_item_identity_sha256": sha256_json(
                legacy.immutable_queue_item_identity(snapshot["queue"]["item"])),
            "queue_item_sha256": snapshot["queue"]["item"]["sha256"],
            "quantum_address": snapshot["payout"]["address"],
            "mempool_shadow_proof_count": 0,
            "mempool_shadow_proof_limit": 1,
            "mempool_inventory_sha256": snapshot["mempool"]["mempool_txids_sha256"],
            "old_authority_retry_authorized": False,
            "sendshadowpowclaim_authorized": False,
            "new_one_shot_audit_required": True,
            "new_one_shot_authority_required": True,
            "ordinary_pow_authorized": False,
            "pause_removal_authorized": False,
            "recurring_worker_authorized": False,
            "repair_authorized": False,
            "reindex_authorized": False,
            "rewind_authorized": False,
            "user_orders": legacy.USER_ORDERS,
            "user_order_sha256": legacy.USER_ORDER_SHA256,
            "acknowledgements": {
                "old_financial_authority_is_permanently_consumed": True,
                "requeue_is_not_a_send_or_broadcast_authority": True,
                "mempool_clearance_may_expire_after_requeue": True,
                "fresh_one_shot_audit_and_authority_are_mandatory": True,
                "ordinary_pow_remains_disabled": True,
                "free_claim_pause_remains_present": True,
                "pos_remains_active": True,
            },
        }
        digest = legacy.node30.publish_json(requeue_run / "requeue-audit.json", receipt)
    print(json.dumps({"result": receipt["result"],
                      "requeue_audit_sha256": digest}, sort_keys=True))


def load_requeue_audit(run_dir: pathlib.Path, contract: Any) -> tuple[dict[str, Any], str]:
    receipt, digest = legacy.node30.load_run_receipt(run_dir, "requeue-audit.json")
    validate_common(receipt, "node30-free-claim-requeue-audit", contract)
    exact_fields = set(base_receipt(
        "node30-free-claim-requeue-audit", contract)) | {
            "result", "mutation_performed", "source_run", "source_authority",
            "source_authority_sha256", "source_audit_sha256",
            "source_intent_sha256", "source_rpc_unknown_sha256",
            "source_reconcile_receipt", "source_reconcile_sha256",
            "source_definitive_rejection_sha256", "snapshot", "lock_identities",
            "required_authority",
        }
    snapshot = receipt.get("snapshot")
    required = receipt.get("required_authority")
    if (set(receipt) != exact_fields or
            receipt.get("result") != "READY_FOR_SEPARATE_REQUEUE_ONLY_AUTHORITY" or
            receipt.get("mutation_performed") is not False or
            not isinstance(snapshot, dict) or set(snapshot) !=
            {"role", "queue", "payout", "fee_input", "mempool", "candidate_count"} or
            snapshot.get("candidate_count") != 0 or
            snapshot.get("queue", {}).get("state") != "rejected" or
            snapshot.get("mempool", {}).get("shadow_proof_count") != 0 or
            snapshot.get("mempool", {}).get("shadow_proof_limit") != 1 or
            snapshot.get("mempool", {}).get("slot_clear") is not True or
            not isinstance(required, dict) or
            required.get("source_authority_sha256") !=
            receipt.get("source_authority_sha256") or
            required.get("source_intent_sha256") != receipt.get("source_intent_sha256") or
            required.get("source_definitive_rejection_sha256") !=
            receipt.get("source_definitive_rejection_sha256") or
            required.get("queue_item_identity_sha256") != sha256_json(
                legacy.immutable_queue_item_identity(snapshot.get("queue", {}).get("item"))) or
            required.get("mempool_shadow_proof_count") != 0 or
            required.get("mempool_shadow_proof_limit") != 1 or
            required.get("old_authority_retry_authorized") is not False or
            required.get("sendshadowpowclaim_authorized") is not False or
            required.get("new_one_shot_audit_required") is not True or
            required.get("new_one_shot_authority_required") is not True):
        die("requeue audit is not exact")
    return receipt, digest


def load_requeue_authority(args: argparse.Namespace, contract: Any,
                           audit: dict[str, Any], audit_sha: str) -> tuple[dict[str, Any], str]:
    authority, digest = legacy.node30.base.parse_secure_json(
        pathlib.Path(args.authority), "requeue authority", args.authority_sha256)
    exact = json.loads(json.dumps(audit["required_authority"]))
    exact["decision"] = "authorize"
    exact["audit_receipt_sha256"] = audit_sha
    if authority != exact:
        die("requeue authority differs from the exact reviewed template")
    return authority, digest


def source_args_from_requeue(audit: dict[str, Any]) -> argparse.Namespace:
    source_run = pathlib.Path(audit["source_run"])
    return argparse.Namespace(
        source_run=str(source_run),
        source_authority=audit["source_authority"],
        source_authority_sha256=audit["source_authority_sha256"],
        reconcile_receipt=str(source_run / audit["source_reconcile_receipt"]),
        reconcile_sha256=audit["source_reconcile_sha256"],
    )


def requeue_intent_expected(audit: dict[str, Any], audit_sha: str,
                            authority_sha: str, readiness: dict[str, Any],
                            contract: Any) -> dict[str, Any]:
    receipt = base_receipt("node30-free-claim-requeue-intent", contract)
    receipt.update({
        "state": "REQUEUE_ONLY_AUTHORITY_CONSUMED_FILESYSTEM_RENAME_PENDING_OR_COMPLETE",
        "requeue_audit_sha256": audit_sha,
        "requeue_authority_sha256": authority_sha,
        "source_authority_sha256": audit["source_authority_sha256"],
        "source_intent_sha256": audit["source_intent_sha256"],
        "source_definitive_rejection_sha256":
            audit["source_definitive_rejection_sha256"],
        "queue_item_identity_sha256": sha256_json(
            legacy.immutable_queue_item_identity(readiness["queue"]["item"])),
        "mempool_clearance": readiness["mempool"],
        "candidate_count": 0,
        "sendshadowpowclaim_authorized": False,
        "old_authority_retry_authorized": False,
        "new_one_shot_authority_required": True,
    })
    return receipt


def validate_requeue_intent(receipt: Any, contract: Any, audit: dict[str, Any],
                            audit_sha: str, authority_sha: str) -> dict[str, Any]:
    validate_common(receipt, "node30-free-claim-requeue-intent", contract)
    exact_fields = set(base_receipt(
        "node30-free-claim-requeue-intent", contract)) | {
            "state", "requeue_audit_sha256", "requeue_authority_sha256",
            "source_authority_sha256", "source_intent_sha256",
            "source_definitive_rejection_sha256", "queue_item_identity_sha256",
            "mempool_clearance", "candidate_count",
            "sendshadowpowclaim_authorized", "old_authority_retry_authorized",
            "new_one_shot_authority_required", "lock_identities",
        }
    mempool = receipt.get("mempool_clearance")
    if (not isinstance(receipt, dict) or set(receipt) != exact_fields or
            receipt.get("state") !=
            "REQUEUE_ONLY_AUTHORITY_CONSUMED_FILESYSTEM_RENAME_PENDING_OR_COMPLETE" or
            receipt.get("requeue_audit_sha256") != audit_sha or
            receipt.get("requeue_authority_sha256") != authority_sha or
            receipt.get("source_authority_sha256") != audit["source_authority_sha256"] or
            receipt.get("source_intent_sha256") != audit["source_intent_sha256"] or
            receipt.get("source_definitive_rejection_sha256") !=
            audit["source_definitive_rejection_sha256"] or
            receipt.get("queue_item_identity_sha256") !=
            audit["required_authority"]["queue_item_identity_sha256"] or
            receipt.get("candidate_count") != 0 or
            receipt.get("sendshadowpowclaim_authorized") is not False or
            receipt.get("old_authority_retry_authorized") is not False or
            receipt.get("new_one_shot_authority_required") is not True or
            not isinstance(mempool, dict) or mempool.get("shadow_proof_count") != 0 or
            mempool.get("shadow_proof_limit") != 1 or mempool.get("slot_clear") is not True or
            mempool.get("mempool_txids_sha256") != sha256_json(
                mempool.get("mempool_txids")) or
            mempool.get("shadow_proof_txids_sha256") != sha256_json(
                mempool.get("shadow_proof_txids"))):
        die("stored requeue-only intent is not exact")
    return receipt


def validate_requeue_complete(run_dir: pathlib.Path, receipt: Any, contract: Any,
                              audit: dict[str, Any], audit_sha: str,
                              authority_sha: str) -> dict[str, Any]:
    intent, intent_sha = legacy.node30.load_run_receipt(
        run_dir, "requeue-intent.json")
    validate_requeue_intent(
        intent, contract, audit, audit_sha, authority_sha)
    validate_common(receipt, "node30-free-claim-requeue-complete", contract)
    exact_fields = set(base_receipt(
        "node30-free-claim-requeue-complete", contract)) | {
            "result", "requeue_audit_sha256", "requeue_authority_sha256",
            "requeue_intent_sha256", "source_authority_sha256",
            "source_intent_sha256", "source_definitive_rejection_sha256",
            "queue_outcome", "sendshadowpowclaim_call_count",
            "old_authority_retry_authorized", "new_one_shot_audit_required",
            "new_one_shot_authority_required", "pause_preserved",
            "ordinary_pow_enabled", "recurring_worker_invoked", "lock_identities",
    }
    outcome = receipt.get("queue_outcome")
    outcome_fields = {
        "state", "path", "sha256", "device", "inode", "move_protocol",
        "no_clobber", "same_inode", "already_complete",
        "crash_link_reconciled", "atomic_rename",
    }
    rejected_basename = audit.get("snapshot", {}).get("queue", {}).get(
        "item", {}).get("basename")
    if (not isinstance(rejected_basename, str) or
            not rejected_basename.endswith(".rejected.json")):
        die("requeue audit rejected basename is not canonical")
    queued_basename = rejected_basename[:-len(".rejected.json")] + ".json"
    if not legacy.QUEUE_NAME.fullmatch(queued_basename):
        die("requeue audit queued basename is not canonical")
    if (not isinstance(receipt, dict) or set(receipt) != exact_fields or
            receipt.get("result") != "REQUEUED_FOR_NEW_ONE_SHOT_AUTHORITY" or
            receipt.get("requeue_audit_sha256") != audit_sha or
            receipt.get("requeue_authority_sha256") != authority_sha or
            receipt.get("requeue_intent_sha256") != intent_sha or
            receipt.get("source_authority_sha256") != audit["source_authority_sha256"] or
            receipt.get("source_intent_sha256") != audit["source_intent_sha256"] or
            receipt.get("source_definitive_rejection_sha256") !=
            audit["source_definitive_rejection_sha256"] or
            receipt.get("sendshadowpowclaim_call_count") != 0 or
            receipt.get("old_authority_retry_authorized") is not False or
            receipt.get("new_one_shot_audit_required") is not True or
            receipt.get("new_one_shot_authority_required") is not True or
            receipt.get("pause_preserved") is not True or
            receipt.get("ordinary_pow_enabled") is not False or
            receipt.get("recurring_worker_invoked") is not False or
            not isinstance(outcome, dict) or set(outcome) != outcome_fields or
            outcome.get("state") != "queued" or
            outcome.get("path") != str(contract.queue_dir / queued_basename) or
            outcome.get("sha256") != audit["snapshot"]["queue"]["item"]["sha256"] or
            outcome.get("device") != audit["snapshot"]["queue"]["item"]["device"] or
            outcome.get("inode") != audit["snapshot"]["queue"]["item"]["inode"] or
            outcome.get("move_protocol") != MOVE_PROTOCOL or
            outcome.get("no_clobber") is not True or
            outcome.get("same_inode") is not True or
            type(outcome.get("already_complete")) is not bool or
            type(outcome.get("crash_link_reconciled")) is not bool or
            outcome.get("atomic_rename") is not False):
        die("completed requeue receipt is not exact")
    return receipt


def requeue_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    legacy.node30.base.ensure_secure_dir(run_dir)
    contract = legacy.load_contract(run_dir)
    audit, audit_sha = load_requeue_audit(run_dir, contract)
    _, authority_sha = load_requeue_authority(args, contract, audit, audit_sha)
    source_args = source_args_from_requeue(audit)
    (source_contract, source_audit, source_audit_sha, intent, intent_sha,
     _unknown, unknown_sha, _reconcile, reconcile_sha, source) = source_chain(source_args)
    if source_contract.sha256 != contract.sha256 or source_audit_sha != audit["source_audit_sha256"]:
        die("requeue source runtime or audit identity changed")
    _, definitive_sha = load_definitive_rejection(
        pathlib.Path(source["source_run"]), contract, source_audit,
        source_audit_sha, intent_sha, unknown_sha, reconcile_sha,
        source["authority_sha256"])
    if definitive_sha != audit["source_definitive_rejection_sha256"]:
        die("requeue source definitive rejection identity changed")
    complete_path = run_dir / "requeue-complete.json"
    if complete_path.exists() or complete_path.is_symlink():
        complete, digest = legacy.node30.load_run_receipt(run_dir, "requeue-complete.json")
        validate_requeue_complete(
            run_dir, complete, contract, audit, audit_sha, authority_sha)
        state, _, _ = current_rejection_item_after_requeue(contract, source_audit)
        if complete.get("result") != "REQUEUED_FOR_NEW_ONE_SHOT_AUTHORITY" or state != "queued":
            die("completed requeue receipt has no exact queued item")
        print(json.dumps({"result": complete["result"],
                          "requeue_complete_sha256": digest,
                          "already_complete": True}, sort_keys=True))
        return
    transport = Transport(contract.retained.runtime)
    node = contract.retained.runtime.nodes[0]
    with legacy.node30.mutation_locks(contract.retained) as lock_ids:
        pause_before = legacy.node30.free_claim_snapshot(contract.retained)
        exact_node, runtime_before = legacy.node30.pin_node(transport, node)
        intent_path = run_dir / "requeue-intent.json"
        if intent_path.exists() or intent_path.is_symlink():
            requeue_intent, requeue_intent_sha = legacy.node30.load_run_receipt(
                run_dir, "requeue-intent.json")
            validate_requeue_intent(
                requeue_intent, contract, audit, audit_sha, authority_sha)
        else:
            readiness = readiness_snapshot(
                transport, exact_node, contract, source_audit, intent)
            if (legacy.fee_inventory_non_tip_identity(readiness["fee_input"]) !=
                    legacy.fee_inventory_non_tip_identity(audit["snapshot"]["fee_input"]) or
                    readiness["payout"] != audit["snapshot"]["payout"] or
                    sha256_json(legacy.immutable_queue_item_identity(
                        readiness["queue"]["item"])) !=
                    audit["required_authority"]["queue_item_identity_sha256"]):
                die("requeue readiness differs from the reviewed non-tip state")
            requeue_intent = requeue_intent_expected(
                audit, audit_sha, authority_sha, readiness, contract)
            requeue_intent["lock_identities"] = lock_ids
            requeue_intent_sha = legacy.node30.publish_json(
                intent_path, requeue_intent)
        source_path = contract.done_dir / rejected_name(source_audit)
        queued_path = contract.queue_dir / source_audit["snapshot"]["queue"]["outcome_names"]["queued"]
        state, _ = lifecycle_move_state(
            contract, source_audit, source_path, queued_path, "requeue")
        if state == "source":
            # Revalidate the transient clearance immediately before the only
            # authorized filesystem mutation. A recognized two-link crash pair
            # has already crossed this boundary and is healed without a send.
            resumed = readiness_snapshot(
                transport, exact_node, contract, source_audit, intent)
            if resumed["mempool"]["slot_clear"] is not True:
                die("shadow-proof mempool slot closed before requeue")
        item, move = no_clobber_lifecycle_move(
            contract, source_audit, source_path, queued_path, "requeue")
        current_state, _, _ = current_rejection_item_after_requeue(
            contract, source_audit)
        if current_state != "queued":
            die("requeue no-clobber move did not reach the exact queued state")
        if (legacy.node30.free_claim_snapshot(contract.retained) != pause_before or
                transport.runtime_snapshot(node) != runtime_before):
            die("node30 pause or runtime changed during requeue")
        receipt = base_receipt("node30-free-claim-requeue-complete", contract)
        receipt.update({
            "result": "REQUEUED_FOR_NEW_ONE_SHOT_AUTHORITY",
            "requeue_audit_sha256": audit_sha,
            "requeue_authority_sha256": authority_sha,
            "requeue_intent_sha256": requeue_intent_sha,
            "source_authority_sha256": audit["source_authority_sha256"],
            "source_intent_sha256": audit["source_intent_sha256"],
            "source_definitive_rejection_sha256": definitive_sha,
            "queue_outcome": {"state": "queued", "path": str(queued_path),
                              "sha256": item["sha256"], "device": item["device"],
                              "inode": item["inode"], **move},
            "sendshadowpowclaim_call_count": 0,
            "old_authority_retry_authorized": False,
            "new_one_shot_audit_required": True,
            "new_one_shot_authority_required": True,
            "pause_preserved": True,
            "ordinary_pow_enabled": False,
            "recurring_worker_invoked": False,
            "lock_identities": lock_ids,
        })
        digest = legacy.node30.publish_json(complete_path, receipt)
    print(json.dumps({"result": receipt["result"],
                      "requeue_complete_sha256": digest}, sort_keys=True))


def current_rejection_item_after_requeue(contract: Any, audit: dict[str, Any]
                                         ) -> tuple[str, pathlib.Path, dict[str, Any]]:
    for parent in [contract.queue_dir, contract.done_dir]:
        fd, _, _ = pinned_directory(contract, audit, parent)
        os.close(fd)
    item = audit["snapshot"]["queue"]["item"]
    names = audit["snapshot"]["queue"]["outcome_names"]
    rejected = contract.done_dir / rejected_name(audit)
    queued = contract.queue_dir / names["queued"]
    present = [(state, path) for state, path in
               [("rejected", rejected), ("queued", queued)]
               if path.exists() or path.is_symlink()]
    forbidden = [contract.done_dir / names[name]
                 for name in ["uncertain", "broadcast", "confirmed"]]
    if len(present) != 1 or any(path.exists() or path.is_symlink() for path in forbidden):
        die("Free-Claim item is not in the exact rejected-or-requeued state")
    state, path = present[0]
    snapshot, _ = legacy.queue_file_snapshot(
        path, contract, f"Free-Claim {state} item", item["sha256"], item)
    other_queue = [entry for entry in contract.queue_dir.iterdir() if entry != path]
    if other_queue:
        die("Free-Claim ingress queue contains an unrelated item")
    return state, path, snapshot


def authority_window_command(args: argparse.Namespace) -> None:
    """Prove a clear slot before any new one-shot authority file exists."""
    run_dir = pathlib.Path(args.run_dir)
    legacy.node30.base.ensure_secure_dir(run_dir)
    contract = legacy.load_contract(run_dir)
    requeue_audit, requeue_audit_sha = load_requeue_audit(run_dir, contract)
    _, requeue_authority_sha = load_requeue_authority(
        args, contract, requeue_audit, requeue_audit_sha)
    complete, complete_sha = legacy.node30.load_run_receipt(
        run_dir, "requeue-complete.json")
    validate_requeue_complete(
        run_dir, complete, contract, requeue_audit, requeue_audit_sha,
        requeue_authority_sha)

    one_shot_run = pathlib.Path(args.one_shot_run)
    legacy.node30.base.ensure_secure_dir(one_shot_run)
    one_shot_contract = legacy.load_contract(one_shot_run)
    if one_shot_contract.sha256 != contract.sha256:
        die("new one-shot audit uses a different runtime manifest")
    one_shot_audit, one_shot_audit_sha = legacy.load_audit(
        one_shot_run, one_shot_contract)
    forbidden = ["AUTHORITY.json", "intent.json", "rpc-response.json",
                 "rpc-unknown.json", "broadcast-complete.json"]
    if any((one_shot_run / name).exists() or (one_shot_run / name).is_symlink()
           for name in forbidden):
        die("new one-shot authority or execution state already exists before slot gate")
    if (sha256_json(legacy.immutable_queue_item_identity(
            one_shot_audit["snapshot"]["queue"]["item"])) !=
            requeue_audit["required_authority"]["queue_item_identity_sha256"] or
            complete.get("queue_outcome", {}).get("path") !=
            one_shot_audit["snapshot"]["queue"]["item"]["path"]):
        die("new one-shot audit does not bind the exact requeued item")

    transport = Transport(contract.retained.runtime)
    node = contract.retained.runtime.nodes[0]
    with legacy.node30.mutation_locks(contract.retained) as lock_ids:
        pause_before = legacy.node30.free_claim_snapshot(contract.retained)
        exact_node, runtime_before = legacy.node30.pin_node(transport, node)
        role = stable_role(transport, exact_node)
        legacy.node30.same_wallet_inventory(
            one_shot_audit["snapshot"]["role"]["wallet_inventory"],
            role["wallet_inventory"], "new one-shot authority window")
        mempool = mempool_shadow_inventory(transport, exact_node)
        if mempool["slot_clear"] is not True or mempool["shadow_proof_count"] != 0:
            die("occupying QQSPROOF must clear before a new one-shot authority")
        if any((one_shot_run / name).exists() or (one_shot_run / name).is_symlink()
               for name in forbidden):
            die("new one-shot authority appeared during slot clearance proof")
        expected_authority = json.loads(json.dumps(
            one_shot_audit["required_authority"]))
        expected_authority["decision"] = "authorize"
        expected_authority["audit_receipt_sha256"] = one_shot_audit_sha
        if (legacy.node30.free_claim_snapshot(contract.retained) != pause_before or
                transport.runtime_snapshot(node) != runtime_before):
            die("node30 pause or runtime changed during new-authority slot gate")
        receipt = base_receipt(
            "node30-free-claim-new-authority-window", contract)
        receipt.update({
            "result": "SLOT_CLEAR_BEFORE_NEW_ONE_SHOT_AUTHORITY",
            "requeue_audit_sha256": requeue_audit_sha,
            "requeue_authority_sha256": requeue_authority_sha,
            "requeue_complete_sha256": complete_sha,
            "one_shot_run": str(one_shot_run),
            "one_shot_audit_sha256": one_shot_audit_sha,
            "one_shot_authority_present": False,
            "one_shot_authority_semantic_sha256": sha256_json(expected_authority),
            "mempool_clearance": mempool,
            "old_authority_retry_authorized": False,
            "new_call_budget": 1,
            "automatic_retry_authorized": False,
            "observed_at": legacy.node30.base.utc_now(),
            "lock_identities": lock_ids,
        })
        name = f"new-authority-window-{time.time_ns()}.json"
        digest = legacy.node30.publish_json(run_dir / name, receipt)
    print(json.dumps({"result": receipt["result"], "receipt": name,
                      "sha256": digest,
                      "one_shot_authority_semantic_sha256":
                      receipt["one_shot_authority_semantic_sha256"]}, sort_keys=True))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    terminalize = commands.add_parser("terminalize")
    terminalize.add_argument("--run-dir", required=True)
    terminalize.add_argument("--authority", required=True)
    terminalize.add_argument("--authority-sha256", required=True)
    terminalize.add_argument("--reconcile-receipt", required=True)
    terminalize.add_argument("--reconcile-sha256", required=True)
    terminalize.set_defaults(func=terminalize_command)
    audit = commands.add_parser("audit-requeue")
    audit.add_argument("--source-run", required=True)
    audit.add_argument("--source-authority", required=True)
    audit.add_argument("--source-authority-sha256", required=True)
    audit.add_argument("--reconcile-receipt", required=True)
    audit.add_argument("--reconcile-sha256", required=True)
    audit.add_argument("--run-dir", required=True)
    audit.set_defaults(func=requeue_audit_command)
    requeue = commands.add_parser("requeue")
    requeue.add_argument("--run-dir", required=True)
    requeue.add_argument("--authority", required=True)
    requeue.add_argument("--authority-sha256", required=True)
    requeue.set_defaults(func=requeue_command)
    window = commands.add_parser("audit-new-authority-window")
    window.add_argument("--run-dir", required=True)
    window.add_argument("--authority", required=True)
    window.add_argument("--authority-sha256", required=True)
    window.add_argument("--one-shot-run", required=True)
    window.set_defaults(func=authority_window_command)
    return result


def main(argv: Sequence[str] | None = None) -> int:
    os.umask(0o077)
    try:
        if legacy.test_mode():
            legacy.node30.base.TEST_TRANSPORT_SHA256 = TEST_TRANSPORT_SHA256
        else:
            legacy.CONTROLLER_RUNTIME_IDENTITY = legacy.validate_controller_runtime()
    except (legacy.node30.base.GateError, legacy.node30.GateError,
            legacy.GateError, GateError, OSError) as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1
    for name in ["PYTHONPATH", "PYTHONHOME", "BASH_ENV", "ENV", "CDPATH"]:
        os.environ.pop(name, None)
    args = parser().parse_args(argv)
    try:
        args.func(args)
    except (legacy.node30.base.GateError, legacy.node30.GateError,
            legacy.GateError, GateError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
