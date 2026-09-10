#!/usr/bin/python3
"""Durably requeue one exact rejected node30 claim without reserving a slot.

This fleet-only stage is deliberately nonfinancial.  It pins the reviewed
v1 rejection/requeue companion so an already-published definitive-rejection
receipt remains verifiable, but it does not inherit v1's transient empty-slot
precondition for the rejected-to-queued filesystem move.  The Free-Claim
worker remains paused and node30 ordinary PoW remains disabled.  A separate
edge one-shot audit and financial authority are still mandatory before any
wallet RPC.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import stat
import subprocess
import sys
import types
from typing import Any, NoReturn, Sequence


CONTRACT = "installed-v30.1.4-node30-free-claim-durable-requeue/v2"
RECEIPT_SCHEMA = 1
PRESERVE_PROTOCOL = "preexisting-queue-preservation/v1"
PINNED_RELATIVE = pathlib.Path("node30_free_claim_rejection_requeue.py")
PINNED_SHA256 = "66a3ec627214ce60bcd3a96bf49d580aa4957a2dc4a2ba35b7032bf5066c15c8"
TEST_TRANSPORT_SHA256S = {
    pinned_hash for pinned_hash in [
        "a41bc2ee67eb00c6849a9cb2fad9f5c5eb7d476b85c0c540d7a330522cfa804a",
        "8775fbec4c4effdebf75e3569228514e67393ccfbbe178dcdc46d8aa53c4c983",
    ]
}
HEX64 = __import__("re").compile(r"^[0-9a-f]{64}$")


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb", buffering=0) as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_pinned() -> Any:
    path = (pathlib.Path(__file__).resolve(strict=True).parent /
            PINNED_RELATIVE).resolve(strict=True)
    if sha256_file(path) != PINNED_SHA256:
        raise RuntimeError("hash-pinned rejection/requeue companion changed")
    spec = importlib.util.spec_from_file_location(
        "node30_durable_requeue_pinned", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load hash-pinned rejection/requeue companion")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


try:
    pinned = load_pinned()
except (OSError, RuntimeError) as exc:
    print(f"FATAL: {exc}", file=sys.stderr)
    raise SystemExit(1)

legacy = pinned.legacy
Transport = pinned.Transport


class GateError(pinned.GateError):
    pass


def die(message: str) -> NoReturn:
    raise GateError(message)


def tool_sha() -> str:
    return sha256_file(pathlib.Path(__file__).resolve(strict=True))


def sha256_json(value: Any) -> str:
    return pinned.sha256_json(value)


def base_receipt(kind: str, contract: Any) -> dict[str, Any]:
    receipt = pinned.base_receipt(kind, contract)
    receipt.update({
        "schema": RECEIPT_SCHEMA,
        "contract": CONTRACT,
        "kind": kind,
        "tool_sha256": tool_sha(),
        "pinned_rejection_requeue_tool_sha256": PINNED_SHA256,
    })
    return receipt


def validate_common(receipt: Any, kind: str, contract: Any) -> dict[str, Any]:
    expected = base_receipt(kind, contract)
    if not isinstance(receipt, dict):
        die(f"{kind} receipt is not an object")
    for key, value in expected.items():
        if receipt.get(key) != value:
            die(f"{kind} receipt field {key} differs from the exact contract")
    return receipt


def source_chain(args: argparse.Namespace) -> tuple[Any, dict[str, Any], str,
                                                    dict[str, Any], str,
                                                    dict[str, Any], str,
                                                    dict[str, Any], str,
                                                    dict[str, Any], str, str]:
    values = pinned.source_chain(args)
    (contract, audit, audit_sha, intent, intent_sha, unknown, unknown_sha,
     reconcile, reconcile_sha, source) = values
    _, definitive_sha = pinned.load_definitive_rejection(
        pathlib.Path(source["source_run"]), contract, audit, audit_sha,
        intent_sha, unknown_sha, reconcile_sha, source["authority_sha256"])
    return (contract, audit, audit_sha, intent, intent_sha, unknown, unknown_sha,
            reconcile, reconcile_sha, source, definitive_sha)


def source_rejection_and_selection(contract: Any, source_audit: dict[str, Any]
                                   ) -> tuple[dict[str, Any], dict[str, Any], str]:
    for parent in [contract.queue_dir, contract.done_dir]:
        fd, _, _ = pinned.pinned_directory(contract, source_audit, parent)
        os.close(fd)
    old_item = source_audit["snapshot"]["queue"]["item"]
    names = source_audit["snapshot"]["queue"]["outcome_names"]
    paths = {
        "queued": contract.queue_dir / names["queued"],
        "broadcast": contract.done_dir / names["broadcast"],
        "uncertain": contract.done_dir / names["uncertain"],
        "confirmed": contract.done_dir / names["confirmed"],
        "rejected": contract.done_dir / pinned.rejected_name(source_audit),
    }
    present = [state for state, path in paths.items()
               if path.exists() or path.is_symlink()]
    if present != ["rejected"]:
        die("consumed source item is not solely in its exact rejected state")
    rejected, _ = legacy.queue_file_snapshot(
        paths["rejected"], contract, "durable source rejected item",
        old_item["sha256"], old_item)
    entries = sorted(contract.queue_dir.iterdir(), key=lambda path: path.name)
    if not entries:
        return ({"state": "rejected", "path": str(paths["rejected"]),
                 "item": rejected},
                {"state": "rejected", "path": str(paths["rejected"]),
                 "item": rejected}, "requeue_rejected_source")
    queued = audit_queue(contract)
    selected = {"state": "queued", "path": str(entries[0]),
                "item": queued["item"], "ingress_items": queued["ingress_items"],
                "preserved_done": queued["preserved_done"]}
    return ({"state": "rejected", "path": str(paths["rejected"]),
             "item": rejected}, selected, "preserve_existing_queued_item")


def ingress_identity(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [{"basename": item["basename"],
             **legacy.immutable_queue_item_identity(item)} for item in items]


def ingress_file(path: pathlib.Path, label: str,
                 modes: set[int]) -> tuple[bytes, os.stat_result]:
    """Bind either historical operator ownership or the exact API producer."""
    if not path.is_absolute() or path.parent.resolve(strict=True) != path.parent:
        die(f"{label} path is not canonical")
    before = path.lstat()
    owners = {(os.geteuid(), os.getegid())} if legacy.test_mode() else {(0, 0), (99, 100)}
    if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode) or
            before.st_nlink != 1 or (before.st_uid, before.st_gid) not in owners or
            stat.S_IMODE(before.st_mode) not in modes or
            path.resolve(strict=True) != path):
        die(f"{label} is not an exact operator/API-owned single-link regular file")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb", buffering=0) as handle:
        opened = os.fstat(handle.fileno())
        data = handle.read()
        closed = os.fstat(handle.fileno())
    after = path.lstat()
    fields = ["st_dev", "st_ino", "st_uid", "st_gid", "st_mode", "st_nlink",
              "st_size", "st_mtime_ns", "st_ctime_ns"]
    if any(getattr(before, key) != getattr(cut, key)
           for cut in [opened, closed, after] for key in fields):
        die(f"{label} changed while read")
    return data, after


def queue_file_snapshot(path: pathlib.Path, contract: Any, label: str,
                        expected_sha: str | None = None,
                        expected_identity: dict[str, Any] | None = None
                        ) -> tuple[dict[str, Any], bytes]:
    data, st = ingress_file(path, label, {0o644})
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
            any(not isinstance(value.get(key), str) or not value[key]
                for key in ["ip", "quantum_address", "submitted"])):
        die(f"{label} has an unexpected schema")
    item = {"path": str(path), "basename": path.name, "sha256": digest,
            "size": len(data), "device": st.st_dev, "inode": st.st_ino,
            "uid": st.st_uid, "gid": st.st_gid, "mode": "0644",
            "nlink": st.st_nlink, "record": value}
    if (expected_identity is not None and
            legacy.immutable_queue_item_identity(item) !=
            legacy.immutable_queue_item_identity(expected_identity)):
        die(f"{label} immutable identity changed")
    return item, data


def audit_queue(contract: Any) -> dict[str, Any]:
    """Validate the entire queue, then bind its canonical oldest entry.

    Filename UTC timestamp, with the canonical suffix as tie breaker, defines
    FIFO. No item is copied, moved, hidden, rewritten, or filtered from checks.
    """
    storage_before = legacy.current_free_claim_storage(contract)
    directories = [(contract.root, "Free-Claim root", 0o750),
                   (contract.queue_dir, "Free-Claim queue", 0o770),
                   (contract.done_dir, "Free-Claim done directory", 0o750)]
    stats = [legacy.secure_dir(path, label, mode, contract.pool_group_gid)
             for path, label, mode in directories]
    if stats[1].st_dev != stats[2].st_dev:
        die("queue and done directories are not on one atomic-rename filesystem")
    entries = sorted(contract.queue_dir.iterdir(), key=lambda item: item.name)
    if not entries or any(not legacy.QUEUE_NAME.fullmatch(p.name) for p in entries):
        die("Free-Claim ingress must contain only canonical JSON items")
    items = [queue_file_snapshot(path, contract, "queued Free-Claim item")[0]
             for path in entries]
    payouts = [item["record"]["quantum_address"] for item in items]
    if len(payouts) != len(set(payouts)):
        die("Free-Claim ingress contains duplicate payout identities")
    done_entries = sorted(contract.done_dir.iterdir(), key=lambda item: item.name)
    preserved_done = []
    for entry in done_entries:
        data, st = ingress_file(
            entry, f"done entry {entry.name}", {0o600, 0o640, 0o644})
        if st.st_gid not in {contract.pool_group_gid, os.getegid()}:
            die(f"done entry {entry.name} has an unexpected group")
        preserved_done.append({"basename": entry.name, "sha256": hashlib.sha256(data).hexdigest(),
                               "device": st.st_dev, "inode": st.st_ino,
                               "uid": st.st_uid, "gid": st.st_gid,
                               "mode": stat.S_IMODE(st.st_mode), "size": st.st_size})
    if any(entry.name.endswith(".broadcast") for entry in done_entries):
        die("Free-Claim done directory already has a broadcast marker")
    for item in items:
        names = legacy.queue_names(item["basename"])
        if any((contract.done_dir / names[state]).exists() for state in
               ["broadcast", "uncertain", "confirmed"]):
            die("queued Free-Claim outcome path already exists")
    awarded = legacy.awarded_snapshot(contract)
    if any(payout in awarded["records"] for payout in payouts):
        die("queued quantum payout is already in the awarded ledger")
    for (path, label, mode), prior in zip(directories, stats):
        current = legacy.secure_dir(path, label, mode, contract.pool_group_gid)
        if (current.st_dev, current.st_ino) != (prior.st_dev, prior.st_ino):
            die(f"{label} changed while its state was audited")
    if sorted(contract.queue_dir.iterdir(), key=lambda p: p.name) != entries:
        die("Free-Claim ingress membership changed while audited")
    for path, item in zip(entries, items):
        queue_file_snapshot(path, contract, "queued Free-Claim item",
                                   item["sha256"], item)
    if legacy.current_free_claim_storage(contract) != storage_before:
        die("Free-Claim storage ancestry changed while its state was audited")
    result = {}
    for key, (path, _, mode), st in zip(
            ["root", "queue_directory", "done_directory"], directories, stats):
        result[key] = {"path": str(path), "device": st.st_dev, "inode": st.st_ino,
                       "uid": st.st_uid, "gid": st.st_gid, "mode": f"{mode:04o}"}
    result.update({"item": items[0], "ingress_items": items,
                   "preserved_done": preserved_done,
                   "outcome_names": legacy.queue_names(items[0]["basename"]),
                   "existing_done_entries": [entry.name for entry in done_entries],
                   "broadcast_marker_count": 0, "awarded": awarded})
    return result


def stable_live_snapshot(transport: Any, contract: Any, node: Any) -> dict[str, Any]:
    # Reuse the hash-pinned snapshot bytecode with one explicit queue-reader
    # dependency. The original module and its historical receipt path are
    # unchanged; there is no global monkey patch or concurrent shared state.
    original = legacy.stable_live_snapshot
    bindings = {**original.__globals__, "audit_queue": audit_queue}
    adapted = types.FunctionType(original.__code__, bindings, original.__name__,
                                 original.__defaults__, original.__closure__)
    return adapted(transport, contract, node)


def current_queue_state(contract: Any, audit: dict[str, Any]) -> tuple[str, pathlib.Path]:
    validate_preserved_ingress(contract, audit["snapshot"]["queue"], allow_new=True)
    original = legacy.current_queue_state
    bindings = {**original.__globals__, "queue_file_snapshot": queue_file_snapshot}
    adapted = types.FunctionType(original.__code__, bindings, original.__name__)
    return adapted(contract, audit)


def transition_queue(contract: Any, audit: dict[str, Any], target: str) -> dict[str, Any]:
    validate_preserved_ingress(contract, audit["snapshot"]["queue"], allow_new=True)
    original = legacy.transition_queue
    bindings = {**original.__globals__, "queue_file_snapshot": queue_file_snapshot,
                "current_queue_state": current_queue_state}
    adapted = types.FunctionType(original.__code__, bindings, original.__name__)
    result = adapted(contract, audit, target)
    validate_preserved_ingress(contract, audit["snapshot"]["queue"], allow_new=True)
    return result


def validate_preserved_ingress(contract: Any, queue: dict[str, Any],
                               allow_new: bool = False) -> None:
    selected = queue["item"]["basename"]
    expected = [item for item in queue["ingress_items"] if item["basename"] != selected]
    actual = sorted((p for p in contract.queue_dir.iterdir() if p.name != selected),
                    key=lambda p: p.name)
    expected_by_name = {item["basename"]: item for item in expected}
    actual_by_name = {path.name: path for path in actual}
    if (not set(expected_by_name) <= set(actual_by_name) or
            (not allow_new and set(expected_by_name) != set(actual_by_name))):
        die("unselected Free-Claim ingress membership changed")
    for name, item in expected_by_name.items():
        path = actual_by_name[name]
        queue_file_snapshot(path, contract, "preserved unselected queue item",
                                   item["sha256"], item)
    # A new API arrival after intent does not prevent reconciliation of the
    # consumed financial call. It is never selected or submitted by that run.
    for name in set(actual_by_name) - set(expected_by_name):
        if not legacy.QUEUE_NAME.fullmatch(name):
            die("new ingress arrival is not canonical")
        queue_file_snapshot(actual_by_name[name], contract, "new unselected API arrival")
    for item in queue["preserved_done"]:
        path = contract.done_dir / item["basename"]
        data, st = ingress_file(path, "preserved done item", {item["mode"]})
        current = {"basename": path.name, "sha256": hashlib.sha256(data).hexdigest(),
                   "device": st.st_dev, "inode": st.st_ino, "uid": st.st_uid,
                   "gid": st.st_gid, "mode": stat.S_IMODE(st.st_mode), "size": st.st_size}
        if current != item:
            die("preserved Free-Claim done identity changed")


def durable_snapshot(transport: Any, node: Any, contract: Any,
                     source_audit: dict[str, Any],
                     source_intent: dict[str, Any]) -> dict[str, Any]:
    role = pinned.stable_role(transport, node)
    legacy.node30.same_wallet_inventory(
        source_audit["snapshot"]["role"]["wallet_inventory"],
        role["wallet_inventory"], "durable requeue")
    source_rejected, selected, strategy = source_rejection_and_selection(
        contract, source_audit)
    item = selected["item"]
    payout = legacy.validate_payout_address(
        transport, node, item["record"]["quantum_address"])
    if (strategy == "requeue_rejected_source" and
            payout != source_audit["snapshot"]["payout"]):
        die("rejected queue payout differs from the consumed one-shot")
    if payout["address"] in legacy.awarded_snapshot(contract)["records"]:
        die("rejected queue payout is already awarded")
    if legacy.reconcile_candidates(transport, node, source_intent):
        die("an exact old-authority transaction appeared; requeue is forbidden")
    fee_input = legacy.fee_input_inventory(transport, node)
    mempool = pinned.mempool_shadow_inventory(transport, node)
    count = mempool.get("shadow_proof_count")
    if (type(count) is not int or count not in {0, 1} or
            mempool.get("shadow_proof_limit") != 1 or
            mempool.get("slot_clear") is not (count == 0)):
        die("node30 QQP2 one-slot mempool observation is incoherent")
    return {
        "role": role,
        "source_rejected": source_rejected,
        "queue": selected,
        "queue_strategy": strategy,
        "payout": payout,
        "fee_input": fee_input,
        "mempool_observation": mempool,
        "candidate_count": 0,
    }


def stable_identity(snapshot: dict[str, Any]) -> dict[str, Any]:
    return {
        "wallet_selection": legacy.node30.wallet_inventory_identity(
            snapshot["role"]["wallet_inventory"],
            "durable requeue wallet selection"),
        "queue_item": legacy.immutable_queue_item_identity(
            snapshot["queue"]["item"]),
        "queue_strategy": snapshot["queue_strategy"],
        "ingress_items": ingress_identity(snapshot["queue"].get("ingress_items", [])),
        "preserved_done": snapshot["queue"].get("preserved_done", []),
        "source_rejected_item": legacy.immutable_queue_item_identity(
            snapshot["source_rejected"]["item"]),
        "payout": snapshot["payout"],
        "fee_input_non_tip": legacy.fee_inventory_non_tip_identity(
            snapshot["fee_input"]),
        "candidate_count": snapshot["candidate_count"],
    }


def audit_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    legacy.node30.base.ensure_secure_dir(run_dir, create=True)
    (contract, source_audit, source_audit_sha, source_intent,
     source_intent_sha, _unknown, unknown_sha, _reconcile, reconcile_sha,
     source, definitive_sha) = source_chain(args)
    legacy.node30.publish_bytes(
        run_dir / "runtime-manifest.json",
        legacy.node30.base.owned_secure_file(
            contract.path, "runtime manifest", contract.sha256))
    transport = Transport(contract.retained.runtime)
    node = contract.retained.runtime.nodes[0]
    with legacy.node30.mutation_locks(contract.retained) as lock_ids:
        pause_before = legacy.node30.free_claim_snapshot(contract.retained)
        exact_node, runtime_before = legacy.node30.pin_node(transport, node)
        snapshot = durable_snapshot(
            transport, exact_node, contract, source_audit, source_intent)
        if (legacy.node30.free_claim_snapshot(contract.retained) != pause_before or
                transport.runtime_snapshot(node) != runtime_before):
            die("node30 pause or runtime changed during durable requeue audit")
        receipt = base_receipt("node30-free-claim-durable-requeue-audit", contract)
        receipt.update({
            "result": "READY_FOR_SEPARATE_DURABLE_QUEUE_AUTHORITY",
            "mutation_performed": False,
            "source_run": source["source_run"],
            "source_authority": source["source_authority"],
            "source_authority_sha256": source["authority_sha256"],
            "source_audit_sha256": source_audit_sha,
            "source_intent_sha256": source_intent_sha,
            "source_rpc_unknown_sha256": unknown_sha,
            "source_reconcile_receipt": pathlib.Path(args.reconcile_receipt).name,
            "source_reconcile_sha256": reconcile_sha,
            "source_definitive_rejection_sha256": definitive_sha,
            "snapshot": snapshot,
            "stable_identity_sha256": sha256_json(stable_identity(snapshot)),
            "lock_identities": lock_ids,
        })
        receipt["required_authority"] = {
            "schema": RECEIPT_SCHEMA,
            "kind": "node30-free-claim-durable-requeue-authority",
            "decision": "REPLACE_WITH_authorize_AFTER_REVIEW",
            "action": "durably_select_exact_queue_item_without_slot_reservation",
            "node": legacy.NODE,
            "role": "free_claim",
            "audit_receipt_sha256": "REPLACE_WITH_DURABLE_REQUEUE_AUDIT_SHA256",
            "runtime_manifest_sha256": contract.sha256,
            "tool_sha256": tool_sha(),
            "pinned_rejection_requeue_tool_sha256": PINNED_SHA256,
            "source_authority_sha256": source["authority_sha256"],
            "source_intent_sha256": source_intent_sha,
            "source_definitive_rejection_sha256": definitive_sha,
            "stable_identity_sha256": receipt["stable_identity_sha256"],
            "queue_item_identity_sha256": sha256_json(
                legacy.immutable_queue_item_identity(snapshot["queue"]["item"])),
            "queue_strategy": snapshot["queue_strategy"],
            "filesystem_move_required":
                snapshot["queue_strategy"] == "requeue_rejected_source",
            "preexisting_queue_preserved":
                snapshot["queue_strategy"] == "preserve_existing_queued_item",
            "quantum_address": snapshot["payout"]["address"],
            "slot_clear_required_for_requeue": False,
            "observed_shadow_proof_count":
                snapshot["mempool_observation"]["shadow_proof_count"],
            "shadow_proof_limit": 1,
            "sendshadowpowclaim_authorized": False,
            "old_authority_retry_authorized": False,
            "new_edge_one_shot_audit_required": True,
            "new_edge_financial_authority_required": True,
            "ordinary_pow_authorized": False,
            "pause_removal_authorized": False,
            "recurring_worker_authorized": False,
            "repair_authorized": False,
            "reindex_authorized": False,
            "rewind_authorized": False,
            "user_orders": legacy.USER_ORDERS,
            "user_order_sha256": legacy.USER_ORDER_SHA256,
            "acknowledgements": {
                "requeue_is_filesystem_only": True,
                "an_existing_canonical_queue_item_takes_precedence": True,
                "transient_slot_is_not_reserved_by_requeue": True,
                "old_financial_authority_is_permanently_consumed": True,
                "fresh_edge_audit_and_financial_authority_are_mandatory": True,
                "free_claim_pause_remains_present": True,
                "ordinary_pow_remains_disabled": True,
                "pos_remains_active": True,
            },
        }
        digest = legacy.node30.publish_json(run_dir / "durable-requeue-audit.json", receipt)
    print(json.dumps({"result": receipt["result"], "audit_sha256": digest},
                     sort_keys=True))


def load_audit(run_dir: pathlib.Path, contract: Any) -> tuple[dict[str, Any], str]:
    receipt, digest = legacy.node30.load_run_receipt(
        run_dir, "durable-requeue-audit.json")
    validate_common(receipt, "node30-free-claim-durable-requeue-audit", contract)
    expected = set(base_receipt(
        "node30-free-claim-durable-requeue-audit", contract)) | {
            "result", "mutation_performed", "source_run", "source_authority",
            "source_authority_sha256", "source_audit_sha256",
            "source_intent_sha256", "source_rpc_unknown_sha256",
            "source_reconcile_receipt", "source_reconcile_sha256",
            "source_definitive_rejection_sha256", "snapshot",
            "stable_identity_sha256", "lock_identities", "required_authority",
        }
    snapshot = receipt.get("snapshot")
    authority = receipt.get("required_authority")
    if (set(receipt) != expected or
            receipt.get("result") !=
            "READY_FOR_SEPARATE_DURABLE_QUEUE_AUTHORITY" or
            receipt.get("mutation_performed") is not False or
            not isinstance(snapshot, dict) or
            snapshot.get("queue_strategy") not in
            {"requeue_rejected_source", "preserve_existing_queued_item"} or
            receipt.get("stable_identity_sha256") !=
            sha256_json(stable_identity(snapshot)) or
            not isinstance(authority, dict) or
            authority.get("stable_identity_sha256") !=
            receipt.get("stable_identity_sha256") or
            authority.get("queue_strategy") != snapshot.get("queue_strategy") or
            authority.get("filesystem_move_required") is not
            (snapshot.get("queue_strategy") == "requeue_rejected_source") or
            authority.get("preexisting_queue_preserved") is not
            (snapshot.get("queue_strategy") == "preserve_existing_queued_item") or
            authority.get("slot_clear_required_for_requeue") is not False or
            authority.get("observed_shadow_proof_count") !=
            snapshot.get("mempool_observation", {}).get("shadow_proof_count") or
            authority.get("shadow_proof_limit") != 1 or
            authority.get("sendshadowpowclaim_authorized") is not False or
            authority.get("old_authority_retry_authorized") is not False or
            authority.get("new_edge_one_shot_audit_required") is not True or
            authority.get("new_edge_financial_authority_required") is not True):
        die("durable requeue audit is not exact")
    return receipt, digest


def load_authority(args: argparse.Namespace, contract: Any,
                   audit: dict[str, Any], audit_sha: str) -> tuple[dict[str, Any], str]:
    authority, digest = legacy.node30.base.parse_secure_json(
        pathlib.Path(args.authority), "durable requeue authority",
        args.authority_sha256)
    expected = json.loads(json.dumps(audit["required_authority"]))
    expected["decision"] = "authorize"
    expected["audit_receipt_sha256"] = audit_sha
    if authority != expected:
        die("durable requeue authority differs from the reviewed template")
    return authority, digest


def source_args(audit: dict[str, Any]) -> argparse.Namespace:
    source = pathlib.Path(audit["source_run"])
    return argparse.Namespace(
        source_run=str(source), source_authority=audit["source_authority"],
        source_authority_sha256=audit["source_authority_sha256"],
        reconcile_receipt=str(source / audit["source_reconcile_receipt"]),
        reconcile_sha256=audit["source_reconcile_sha256"])


def intent_expected(contract: Any, audit: dict[str, Any], audit_sha: str,
                    authority_sha: str, snapshot: dict[str, Any],
                    lock_ids: Any) -> dict[str, Any]:
    receipt = base_receipt("node30-free-claim-durable-requeue-intent", contract)
    receipt.update({
        "state": "DURABLE_QUEUE_AUTHORITY_CONSUMED_SELECTION_PENDING_OR_COMPLETE",
        "durable_requeue_audit_sha256": audit_sha,
        "durable_requeue_authority_sha256": authority_sha,
        "source_authority_sha256": audit["source_authority_sha256"],
        "source_intent_sha256": audit["source_intent_sha256"],
        "source_definitive_rejection_sha256":
            audit["source_definitive_rejection_sha256"],
        "stable_identity_sha256": audit["stable_identity_sha256"],
        "queue_strategy": snapshot["queue_strategy"],
        "filesystem_move_required":
            snapshot["queue_strategy"] == "requeue_rejected_source",
        "preexisting_queue_preserved":
            snapshot["queue_strategy"] == "preserve_existing_queued_item",
        "mempool_observation": snapshot["mempool_observation"],
        "slot_clear_required_for_requeue": False,
        "candidate_count": 0,
        "sendshadowpowclaim_authorized": False,
        "old_authority_retry_authorized": False,
        "new_edge_financial_authority_required": True,
        "lock_identities": lock_ids,
    })
    return receipt


def validate_intent(receipt: Any, contract: Any, audit: dict[str, Any],
                    audit_sha: str, authority_sha: str) -> dict[str, Any]:
    validate_common(receipt, "node30-free-claim-durable-requeue-intent", contract)
    expected = set(base_receipt(
        "node30-free-claim-durable-requeue-intent", contract)) | {
            "state", "durable_requeue_audit_sha256",
            "durable_requeue_authority_sha256", "source_authority_sha256",
            "source_intent_sha256", "source_definitive_rejection_sha256",
            "stable_identity_sha256", "mempool_observation",
            "queue_strategy", "filesystem_move_required",
            "preexisting_queue_preserved",
            "slot_clear_required_for_requeue", "candidate_count",
            "sendshadowpowclaim_authorized", "old_authority_retry_authorized",
            "new_edge_financial_authority_required", "lock_identities",
        }
    observation = receipt.get("mempool_observation")
    count = observation.get("shadow_proof_count") if isinstance(observation, dict) else None
    if (set(receipt) != expected or
            receipt.get("state") !=
            "DURABLE_QUEUE_AUTHORITY_CONSUMED_SELECTION_PENDING_OR_COMPLETE" or
            receipt.get("durable_requeue_audit_sha256") != audit_sha or
            receipt.get("durable_requeue_authority_sha256") != authority_sha or
            receipt.get("source_authority_sha256") !=
            audit["source_authority_sha256"] or
            receipt.get("source_intent_sha256") != audit["source_intent_sha256"] or
            receipt.get("source_definitive_rejection_sha256") !=
            audit["source_definitive_rejection_sha256"] or
            receipt.get("stable_identity_sha256") != audit["stable_identity_sha256"] or
            receipt.get("queue_strategy") not in
            {"requeue_rejected_source", "preserve_existing_queued_item"} or
            receipt.get("queue_strategy") != audit["snapshot"]["queue_strategy"] or
            receipt.get("filesystem_move_required") is not
            (receipt.get("queue_strategy") == "requeue_rejected_source") or
            receipt.get("preexisting_queue_preserved") is not
            (receipt.get("queue_strategy") == "preserve_existing_queued_item") or
            type(count) is not int or count not in {0, 1} or
            observation.get("slot_clear") is not (count == 0) or
            receipt.get("slot_clear_required_for_requeue") is not False or
            receipt.get("candidate_count") != 0 or
            receipt.get("sendshadowpowclaim_authorized") is not False or
            receipt.get("old_authority_retry_authorized") is not False or
            receipt.get("new_edge_financial_authority_required") is not True):
        die("durable requeue intent is not exact")
    return receipt


def validate_complete(run_dir: pathlib.Path, receipt: Any, contract: Any,
                      audit: dict[str, Any], audit_sha: str,
                      authority_sha: str) -> dict[str, Any]:
    intent, intent_sha = legacy.node30.load_run_receipt(
        run_dir, "durable-requeue-intent.json")
    validate_intent(intent, contract, audit, audit_sha, authority_sha)
    validate_common(receipt, "node30-free-claim-durable-requeue-complete", contract)
    expected = set(base_receipt(
        "node30-free-claim-durable-requeue-complete", contract)) | {
            "result", "durable_requeue_audit_sha256",
            "durable_requeue_authority_sha256", "durable_requeue_intent_sha256",
            "source_authority_sha256", "source_intent_sha256",
            "source_definitive_rejection_sha256", "queue_outcome",
            "pre_move_mempool_observation", "slot_clear_required_for_requeue",
            "queue_strategy", "filesystem_move_performed",
            "preexisting_queue_preserved",
            "sendshadowpowclaim_call_count",
            "old_authority_retry_authorized", "new_edge_one_shot_audit_required",
            "new_edge_financial_authority_required", "pause_preserved",
            "ordinary_pow_enabled", "recurring_worker_invoked", "lock_identities",
        }
    outcome = receipt.get("queue_outcome")
    observation = receipt.get("pre_move_mempool_observation")
    strategy = audit["snapshot"]["queue_strategy"]
    count = observation.get("shadow_proof_count") if isinstance(observation, dict) else None
    if (set(receipt) != expected or
            receipt.get("result") !=
            "DURABLE_QUEUE_SELECTION_COMPLETE_INDEPENDENT_OF_TRANSIENT_SLOT" or
            receipt.get("durable_requeue_audit_sha256") != audit_sha or
            receipt.get("durable_requeue_authority_sha256") != authority_sha or
            receipt.get("durable_requeue_intent_sha256") != intent_sha or
            receipt.get("queue_strategy") != strategy or
            receipt.get("filesystem_move_performed") is not
            (strategy == "requeue_rejected_source") or
            receipt.get("preexisting_queue_preserved") is not
            (strategy == "preserve_existing_queued_item") or
            type(count) is not int or count not in {0, 1} or
            observation.get("slot_clear") is not (count == 0) or
            receipt.get("slot_clear_required_for_requeue") is not False or
            receipt.get("sendshadowpowclaim_call_count") != 0 or
            receipt.get("old_authority_retry_authorized") is not False or
            receipt.get("new_edge_one_shot_audit_required") is not True or
            receipt.get("new_edge_financial_authority_required") is not True or
            receipt.get("pause_preserved") is not True or
            receipt.get("ordinary_pow_enabled") is not False or
            receipt.get("recurring_worker_invoked") is not False or
            not isinstance(outcome, dict) or set(outcome) != {
                "state", "path", "sha256", "device", "inode",
                "move_protocol", "no_clobber", "same_inode",
                "already_complete", "crash_link_reconciled", "atomic_rename"} or
            outcome.get("state") != "queued" or
            outcome.get("move_protocol") !=
            (pinned.MOVE_PROTOCOL if strategy == "requeue_rejected_source"
             else PRESERVE_PROTOCOL) or
            outcome.get("no_clobber") is not True or
            outcome.get("same_inode") is not True or
            outcome.get("atomic_rename") is not False):
        die("durable requeue completion is not exact")
    selected = audit["snapshot"]["queue"]["item"]
    if (outcome.get("path") != str(contract.queue_dir / selected["basename"]) or
            outcome.get("sha256") != selected["sha256"] or
            outcome.get("device") != selected["device"] or
            outcome.get("inode") != selected["inode"]):
        die("durable completion does not bind the selected queue item")
    return receipt


def current_selected_queue(contract: Any, audit: dict[str, Any],
                           source_audit: dict[str, Any]) -> dict[str, Any]:
    strategy = audit["snapshot"]["queue_strategy"]
    expected = audit["snapshot"]["queue"]["item"]
    if strategy == "requeue_rejected_source":
        for parent in [contract.queue_dir, contract.done_dir]:
            fd, _, _ = pinned.pinned_directory(contract, source_audit, parent)
            os.close(fd)
        old_names = source_audit["snapshot"]["queue"]["outcome_names"]
        old_rejected = contract.done_dir / pinned.rejected_name(source_audit)
        old_queued = contract.queue_dir / old_names["queued"]
        forbidden = [old_rejected] + [contract.done_dir / old_names[name]
                                     for name in ["uncertain", "broadcast", "confirmed"]]
        if any(path.exists() or path.is_symlink() for path in forbidden):
            die("selected rejected item has not reached the queue")
        item, _ = legacy.queue_file_snapshot(
            old_queued, contract, "selected requeued item",
            expected["sha256"], expected)
        if [entry for entry in contract.queue_dir.iterdir() if entry != old_queued]:
            die("Free-Claim ingress queue contains an unrelated item")
        return {"state": "queued", "path": str(old_queued), "item": item}
    if strategy != "preserve_existing_queued_item":
        die("durable queue strategy is unrecognized")
    validate_preserved_ingress(contract, audit["snapshot"]["queue"])
    source_rejected, selected, current_strategy = source_rejection_and_selection(
        contract, source_audit)
    if (selected["state"] != "queued" or
            current_strategy != strategy or
            legacy.immutable_queue_item_identity(selected["item"]) !=
            legacy.immutable_queue_item_identity(expected) or
            source_rejected["state"] != "rejected"):
        die("preexisting selected queue item changed")
    return selected


def requeue_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    legacy.node30.base.ensure_secure_dir(run_dir)
    contract = legacy.load_contract(run_dir)
    audit, audit_sha = load_audit(run_dir, contract)
    _, authority_sha = load_authority(args, contract, audit, audit_sha)
    values = source_chain(source_args(audit))
    (source_contract, source_audit, source_audit_sha, source_intent,
     source_intent_sha, _unknown, _unknown_sha, _reconcile, _reconcile_sha,
     source, definitive_sha) = values
    if (source_contract.sha256 != contract.sha256 or
            source_audit_sha != audit["source_audit_sha256"] or
            source_intent_sha != audit["source_intent_sha256"] or
            definitive_sha != audit["source_definitive_rejection_sha256"]):
        die("durable requeue source receipt chain changed")
    complete_path = run_dir / "durable-requeue-complete.json"
    if complete_path.exists() or complete_path.is_symlink():
        complete, digest = legacy.node30.load_run_receipt(
            run_dir, "durable-requeue-complete.json")
        validate_complete(
            run_dir, complete, contract, audit, audit_sha, authority_sha)
        current_selected_queue(contract, audit, source_audit)
        print(json.dumps({"result": complete["result"],
                          "complete_sha256": digest,
                          "already_complete": True}, sort_keys=True))
        return
    transport = Transport(contract.retained.runtime)
    node = contract.retained.runtime.nodes[0]
    with legacy.node30.mutation_locks(contract.retained) as lock_ids:
        pause_before = legacy.node30.free_claim_snapshot(contract.retained)
        exact_node, runtime_before = legacy.node30.pin_node(transport, node)
        intent_path = run_dir / "durable-requeue-intent.json"
        if intent_path.exists() or intent_path.is_symlink():
            intent, intent_sha = legacy.node30.load_run_receipt(
                run_dir, "durable-requeue-intent.json")
            validate_intent(intent, contract, audit, audit_sha, authority_sha)
        else:
            snapshot = durable_snapshot(
                transport, exact_node, contract, source_audit, source_intent)
            if sha256_json(stable_identity(snapshot)) != audit["stable_identity_sha256"]:
                die("durable requeue stable identity differs from reviewed audit")
            intent = intent_expected(
                contract, audit, audit_sha, authority_sha, snapshot, lock_ids)
            intent_sha = legacy.node30.publish_json(intent_path, intent)
        move_observation = intent["mempool_observation"]
        strategy = audit["snapshot"]["queue_strategy"]
        if strategy == "requeue_rejected_source":
            source_path = contract.done_dir / pinned.rejected_name(source_audit)
            queued_path = (contract.queue_dir /
                           source_audit["snapshot"]["queue"]["outcome_names"]["queued"])
            state, _ = pinned.lifecycle_move_state(
                contract, source_audit, source_path, queued_path, "durable requeue")
        else:
            source_path = pathlib.Path(audit["snapshot"]["source_rejected"]["path"])
            queued_path = pathlib.Path(audit["snapshot"]["queue"]["path"])
            state = "target"
        if strategy == "requeue_rejected_source" and state == "source":
            resumed = durable_snapshot(
                transport, exact_node, contract, source_audit, source_intent)
            if sha256_json(stable_identity(resumed)) != audit["stable_identity_sha256"]:
                die("durable requeue stable identity changed before move")
            move_observation = resumed["mempool_observation"]
        if strategy == "requeue_rejected_source":
            item, move = pinned.no_clobber_lifecycle_move(
                contract, source_audit, source_path, queued_path, "durable requeue")
        elif strategy == "preserve_existing_queued_item":
            resumed = durable_snapshot(
                transport, exact_node, contract, source_audit, source_intent)
            if sha256_json(stable_identity(resumed)) != audit["stable_identity_sha256"]:
                die("preexisting queue selection changed before completion")
            item = resumed["queue"]["item"]
            move_observation = resumed["mempool_observation"]
            move = {"move_protocol": PRESERVE_PROTOCOL, "no_clobber": True,
                    "same_inode": True, "already_complete": True,
                    "crash_link_reconciled": False, "atomic_rename": False}
        else:
            die("durable queue strategy is unrecognized")
        current_selected_queue(contract, audit, source_audit)
        if (legacy.node30.free_claim_snapshot(contract.retained) != pause_before or
                transport.runtime_snapshot(node) != runtime_before):
            die("node30 pause or runtime changed during durable requeue")
        receipt = base_receipt(
            "node30-free-claim-durable-requeue-complete", contract)
        receipt.update({
            "result": "DURABLE_QUEUE_SELECTION_COMPLETE_INDEPENDENT_OF_TRANSIENT_SLOT",
            "durable_requeue_audit_sha256": audit_sha,
            "durable_requeue_authority_sha256": authority_sha,
            "durable_requeue_intent_sha256": intent_sha,
            "source_authority_sha256": audit["source_authority_sha256"],
            "source_intent_sha256": audit["source_intent_sha256"],
            "source_definitive_rejection_sha256": definitive_sha,
            "queue_strategy": strategy,
            "filesystem_move_performed": strategy == "requeue_rejected_source",
            "preexisting_queue_preserved":
                strategy == "preserve_existing_queued_item",
            "queue_outcome": {"state": "queued", "path": str(queued_path),
                              "sha256": item["sha256"], "device": item["device"],
                              "inode": item["inode"], **move},
            "pre_move_mempool_observation": move_observation,
            "slot_clear_required_for_requeue": False,
            "sendshadowpowclaim_call_count": 0,
            "old_authority_retry_authorized": False,
            "new_edge_one_shot_audit_required": True,
            "new_edge_financial_authority_required": True,
            "pause_preserved": True,
            "ordinary_pow_enabled": False,
            "recurring_worker_invoked": False,
            "lock_identities": lock_ids,
        })
        digest = legacy.node30.publish_json(complete_path, receipt)
    print(json.dumps({"result": receipt["result"],
                      "complete_sha256": digest}, sort_keys=True))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    audit = commands.add_parser("audit")
    audit.add_argument("--source-run", required=True)
    audit.add_argument("--source-authority", required=True)
    audit.add_argument("--source-authority-sha256", required=True)
    audit.add_argument("--reconcile-receipt", required=True)
    audit.add_argument("--reconcile-sha256", required=True)
    audit.add_argument("--run-dir", required=True)
    audit.set_defaults(func=audit_command)
    requeue = commands.add_parser("requeue")
    requeue.add_argument("--run-dir", required=True)
    requeue.add_argument("--authority", required=True)
    requeue.add_argument("--authority-sha256", required=True)
    requeue.set_defaults(func=requeue_command)
    return result


def main(argv: Sequence[str] | None = None) -> int:
    os.umask(0o077)
    try:
        if legacy.test_mode():
            test_transport = pathlib.Path(os.environ["FLEET31_TEST_TRANSPORT"])
            test_transport_sha = sha256_file(test_transport)
            if test_transport_sha not in TEST_TRANSPORT_SHA256S:
                die("offline durable-requeue transport is not hash-pinned")
            legacy.node30.base.TEST_TRANSPORT_SHA256 = test_transport_sha
        else:
            legacy.CONTROLLER_RUNTIME_IDENTITY = legacy.validate_controller_runtime()
    except (legacy.node30.base.GateError, legacy.node30.GateError,
            legacy.GateError, pinned.GateError, GateError, OSError) as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1
    for name in ["PYTHONPATH", "PYTHONHOME", "BASH_ENV", "ENV", "CDPATH"]:
        os.environ.pop(name, None)
    args = parser().parse_args(argv)
    try:
        args.func(args)
    except (legacy.node30.base.GateError, legacy.node30.GateError,
            legacy.GateError, pinned.GateError, GateError, OSError,
            subprocess.TimeoutExpired) as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
