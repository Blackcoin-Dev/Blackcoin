#!/usr/bin/python3
"""Preauthorize one node30 claim, then dynamically bind and send at a clear edge.

The expensive static audit and separate financial authority happen while the
QQP2 slot may be occupied.  One invocation then waits read-only for a natural
vacancy.  Only after acquiring the complete fleet lock set does it rebind the
current tip, QQP2 work, wallet input set and mempool state.  It publishes one
durable intent immediately before the sole sendshadowpowclaim call.  A failed
pre-intent edge never consumes authority inside that invocation; any published
intent permanently consumes authority and permits reconciliation only.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import time
from typing import Any, NoReturn, Sequence


CONTRACT = "installed-v30.1.4-node30-free-claim-edge-one-shot/v2"
RECEIPT_SCHEMA = 1
DURABLE_RELATIVE = pathlib.Path("node30_free_claim_durable_requeue.py")
DURABLE_SHA256 = "afb76f1d8a00d7af0778c934518765c6ba6bfacfa33174a85f1ee237d8a43cc5"
TEST_TRANSPORT_SHA256S = {
    "a41bc2ee67eb00c6849a9cb2fad9f5c5eb7d476b85c0c540d7a330522cfa804a",
    "8775fbec4c4effdebf75e3569228514e67393ccfbbe178dcdc46d8aa53c4c983",
}
MAX_CLEAR_REBINDS = 4
MIN_WAIT_SECONDS = 1
MAX_WAIT_SECONDS = 900
MIN_POLL_MILLISECONDS = 50
MAX_POLL_MILLISECONDS = 5000


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb", buffering=0) as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_durable() -> Any:
    path = (pathlib.Path(__file__).resolve(strict=True).parent /
            DURABLE_RELATIVE).resolve(strict=True)
    if sha256_file(path) != DURABLE_SHA256:
        raise RuntimeError("hash-pinned durable-requeue tool changed")
    spec = importlib.util.spec_from_file_location(
        "node30_edge_durable_tool", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load hash-pinned durable-requeue tool")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


try:
    durable = load_durable()
except (OSError, RuntimeError) as exc:
    print(f"FATAL: {exc}", file=sys.stderr)
    raise SystemExit(1)

pinned = durable.pinned
legacy = durable.legacy
Transport = durable.Transport


class GateError(legacy.GateError):
    pass


class EdgeTransient(Exception):
    pass


def die(message: str) -> NoReturn:
    raise GateError(message)


def tool_sha() -> str:
    return sha256_file(pathlib.Path(__file__).resolve(strict=True))


def sha256_json(value: Any) -> str:
    return pinned.sha256_json(value)


def base_receipt(kind: str, contract: Any) -> dict[str, Any]:
    receipt = durable.base_receipt(kind, contract)
    receipt.update({
        "schema": RECEIPT_SCHEMA,
        "contract": CONTRACT,
        "kind": kind,
        "tool_sha256": tool_sha(),
        "durable_requeue_tool_sha256": DURABLE_SHA256,
        "pinned_rejection_requeue_tool_sha256": durable.PINNED_SHA256,
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


def durable_args_from_audit(audit: dict[str, Any]) -> argparse.Namespace:
    return argparse.Namespace(
        run_dir=audit["durable_requeue_run"],
        authority=audit["durable_requeue_authority"],
        authority_sha256=audit["durable_requeue_authority_sha256"])


def load_durable_context(args: argparse.Namespace, require_selected_queued: bool = True
                         ) -> tuple[Any, dict[str, Any], str, str,
                                    dict[str, Any], dict[str, Any]]:
    run_dir = pathlib.Path(args.durable_run)
    legacy.node30.base.ensure_secure_dir(run_dir)
    contract = legacy.load_contract(run_dir)
    audit, audit_sha = durable.load_audit(run_dir, contract)
    if pathlib.Path(args.durable_authority) != run_dir / "AUTHORITY.json":
        die("durable requeue authority must be its canonical run child")
    authority_args = argparse.Namespace(
        authority=args.durable_authority,
        authority_sha256=args.durable_authority_sha256)
    _, authority_sha = durable.load_authority(
        authority_args, contract, audit, audit_sha)
    complete, complete_sha = legacy.node30.load_run_receipt(
        run_dir, "durable-requeue-complete.json")
    durable.validate_complete(
        run_dir, complete, contract, audit, audit_sha, authority_sha)
    values = durable.source_chain(durable.source_args(audit))
    if require_selected_queued:
        durable.current_selected_queue(contract, audit, values[1])
    return contract, audit, audit_sha, authority_sha, complete, {
        "durable_requeue_complete_sha256": complete_sha,
    }


def static_identity(snapshot: dict[str, Any]) -> dict[str, Any]:
    return {
        "wallet_selection": legacy.node30.wallet_inventory_identity(
            snapshot["role"]["wallet_inventory"], "edge wallet selection"),
        "queue_item": legacy.immutable_queue_item_identity(
            snapshot["queue"]["item"]),
        "ingress_items": durable.ingress_identity(snapshot["queue"]["ingress_items"]),
        "preserved_done": snapshot["queue"]["preserved_done"],
        "queue_directory": snapshot["queue"]["queue_directory"],
        "done_directory": snapshot["queue"]["done_directory"],
        "awarded_sha256": snapshot["queue"]["awarded"]["sha256"],
        "payout": snapshot["payout"],
        "fee_input_non_tip": legacy.fee_inventory_non_tip_identity(
            snapshot["fee_input"]),
    }


def validate_watch_parameters(wait_seconds: Any, poll_milliseconds: Any) -> None:
    if (type(wait_seconds) is not int or
            not MIN_WAIT_SECONDS <= wait_seconds <= MAX_WAIT_SECONDS or
            type(poll_milliseconds) is not int or
            not MIN_POLL_MILLISECONDS <= poll_milliseconds <=
            MAX_POLL_MILLISECONDS):
        die("edge watch parameters are outside the reviewed bounds")


def audit_command(args: argparse.Namespace) -> None:
    validate_watch_parameters(args.max_wait_seconds, args.poll_milliseconds)
    edge_run = pathlib.Path(args.run_dir)
    legacy.node30.base.ensure_secure_dir(edge_run, create=True)
    (contract, durable_audit, durable_audit_sha, durable_authority_sha,
     durable_complete, context) = load_durable_context(args)
    legacy.node30.publish_bytes(
        edge_run / "runtime-manifest.json",
        legacy.node30.base.owned_secure_file(
            contract.path, "runtime manifest", contract.sha256))
    transport = Transport(contract.retained.runtime)
    node = contract.retained.runtime.nodes[0]
    with legacy.node30.mutation_locks(contract.retained) as lock_ids:
        pause_before = legacy.node30.free_claim_snapshot(contract.retained)
        exact_node, runtime_before = legacy.node30.pin_node(transport, node)
        snapshot = durable.stable_live_snapshot(transport, contract, exact_node)
        if (legacy.immutable_queue_item_identity(snapshot["queue"]["item"]) !=
                legacy.immutable_queue_item_identity(durable_audit["snapshot"]["queue"]["item"])):
            die("edge selected queue differs from durable selection")
        if durable_audit["snapshot"]["queue_strategy"] == "preserve_existing_queued_item":
            durable.validate_preserved_ingress(contract, durable_audit["snapshot"]["queue"])
        if (legacy.node30.free_claim_snapshot(contract.retained) != pause_before or
                transport.runtime_snapshot(node) != runtime_before):
            die("node30 pause or runtime changed during edge audit")
        identity = static_identity(snapshot)
        receipt = base_receipt("node30-free-claim-edge-audit", contract)
        receipt.update({
            "result": "READY_FOR_PREAUTHORIZED_DYNAMIC_EDGE",
            "mutation_performed": False,
            "durable_requeue_run": str(pathlib.Path(args.durable_run)),
            "durable_requeue_authority": str(pathlib.Path(args.durable_authority)),
            "durable_requeue_audit_sha256": durable_audit_sha,
            "durable_requeue_authority_sha256": durable_authority_sha,
            "durable_requeue_complete_sha256":
                context["durable_requeue_complete_sha256"],
            "source_authority_sha256": durable_audit["source_authority_sha256"],
            "source_intent_sha256": durable_audit["source_intent_sha256"],
            "snapshot": snapshot,
            "static_identity": identity,
            "static_identity_sha256": sha256_json(identity),
            "dynamic_fields_excluded_from_authority": [
                "active_tip", "active_height", "qqp2_work_tip",
                "tip_relative_confirmations", "wallet_txid_inventory"],
            "watch": {"max_wait_seconds": args.max_wait_seconds,
                      "poll_milliseconds": args.poll_milliseconds,
                      "max_clear_rebinds": MAX_CLEAR_REBINDS},
            "runtime": runtime_before,
            "lock_identities": lock_ids,
        })
        receipt["required_authority"] = {
            "schema": RECEIPT_SCHEMA,
            "kind": "node30-free-claim-edge-authority",
            "decision": "REPLACE_WITH_authorize_AFTER_REVIEW",
            "action": "wait_rebind_and_send_exactly_one_shadow_pow_claim",
            "node": legacy.NODE,
            "role": "free_claim",
            "audit_receipt_sha256": "REPLACE_WITH_EDGE_AUDIT_SHA256",
            "runtime_manifest_sha256": contract.sha256,
            "tool_sha256": tool_sha(),
            "durable_requeue_tool_sha256": DURABLE_SHA256,
            "durable_requeue_complete_sha256":
                context["durable_requeue_complete_sha256"],
            "static_identity_sha256": receipt["static_identity_sha256"],
            "queue_item_identity_sha256": sha256_json(
                legacy.immutable_queue_item_identity(snapshot["queue"]["item"])),
            "quantum_address": snapshot["payout"]["address"],
            "legacy_fee_input_non_tip_sha256": sha256_json(
                identity["fee_input_non_tip"]),
            "dynamic_tip_rebind_authorized": True,
            "dynamic_qqp2_work_rebind_authorized": True,
            "slot_clear_immediately_before_intent_required": True,
            "pre_intent_observation_is_not_authority_consumption": True,
            "single_invocation_only": True,
            "single_submission_only": True,
            "max_clear_rebinds": MAX_CLEAR_REBINDS,
            "max_wait_seconds": args.max_wait_seconds,
            "poll_milliseconds": args.poll_milliseconds,
            "fee_rate_atoms_per_vbyte": legacy.FEE_RATE_ATOMS_PER_VBYTE,
            "maximum_fee_blk": f"{legacy.FEE_CAP:.8f}",
            "expected_vsize": legacy.EXPECTED_VSIZE,
            "maximum_tries": legacy.MAX_TRIES,
            "proof_override": None,
            "ordinary_pow_authorized": False,
            "recurring_worker_authorized": False,
            "pause_removal_authorized": False,
            "recovery_authorized": False,
            "repair_authorized": False,
            "reindex_authorized": False,
            "rewind_authorized": False,
            "user_orders": legacy.USER_ORDERS,
            "user_order_sha256": legacy.USER_ORDER_SHA256,
            "acknowledgements": {
                "fee_sign_and_broadcast_are_irreversible": True,
                "dynamic_tip_and_work_are_bound_only_at_the_clear_edge": True,
                "authority_is_consumed_when_intent_is_published": True,
                "unknown_response_must_never_be_retried": True,
                "slot_can_refill_after_the_final_read_only_check": True,
                "installed_rpc_has_no_idempotency_token": True,
                "core_may_select_any_one_member_of_the_exact_non_tip_set": True,
                "signed_transaction_must_spend_exactly_one_authorized_member": True,
                "actual_fee_must_be_independently_proved": True,
                "free_claim_pause_remains_present": True,
                "ordinary_pow_remains_disabled": True,
                "pos_remains_active": True,
            },
        }
        digest = legacy.node30.publish_json(edge_run / "edge-audit.json", receipt)
    print(json.dumps({"result": receipt["result"], "audit_sha256": digest},
                     sort_keys=True))


def load_audit(run_dir: pathlib.Path, contract: Any) -> tuple[dict[str, Any], str]:
    receipt, digest = legacy.node30.load_run_receipt(run_dir, "edge-audit.json")
    validate_common(receipt, "node30-free-claim-edge-audit", contract)
    expected = set(base_receipt("node30-free-claim-edge-audit", contract)) | {
        "result", "mutation_performed", "durable_requeue_run",
        "durable_requeue_authority", "durable_requeue_audit_sha256",
        "durable_requeue_authority_sha256", "durable_requeue_complete_sha256",
        "source_authority_sha256", "source_intent_sha256", "snapshot",
        "static_identity", "static_identity_sha256",
        "dynamic_fields_excluded_from_authority", "watch", "runtime",
        "lock_identities", "required_authority",
    }
    watch = receipt.get("watch")
    authority = receipt.get("required_authority")
    if (set(receipt) != expected or
            receipt.get("result") != "READY_FOR_PREAUTHORIZED_DYNAMIC_EDGE" or
            receipt.get("mutation_performed") is not False or
            receipt.get("static_identity") != static_identity(receipt["snapshot"]) or
            receipt.get("static_identity_sha256") !=
            sha256_json(receipt["static_identity"]) or
            receipt.get("dynamic_fields_excluded_from_authority") != [
                "active_tip", "active_height", "qqp2_work_tip",
                "tip_relative_confirmations", "wallet_txid_inventory"] or
            not isinstance(watch, dict) or set(watch) !=
            {"max_wait_seconds", "poll_milliseconds", "max_clear_rebinds"} or
            watch.get("max_clear_rebinds") != MAX_CLEAR_REBINDS or
            not isinstance(authority, dict) or
            authority.get("static_identity_sha256") !=
            receipt.get("static_identity_sha256") or
            authority.get("dynamic_tip_rebind_authorized") is not True or
            authority.get("dynamic_qqp2_work_rebind_authorized") is not True or
            authority.get("slot_clear_immediately_before_intent_required") is not True or
            authority.get("single_invocation_only") is not True or
            authority.get("single_submission_only") is not True or
            authority.get("max_wait_seconds") != watch.get("max_wait_seconds") or
            authority.get("poll_milliseconds") != watch.get("poll_milliseconds")):
        die("edge audit is not exact")
    validate_watch_parameters(watch["max_wait_seconds"], watch["poll_milliseconds"])
    return receipt, digest


def load_authority(args: argparse.Namespace, contract: Any,
                   audit: dict[str, Any], audit_sha: str) -> tuple[dict[str, Any], str]:
    authority, digest = legacy.node30.base.parse_secure_json(
        pathlib.Path(args.authority), "edge financial authority",
        args.authority_sha256)
    expected = json.loads(json.dumps(audit["required_authority"]))
    expected["decision"] = "authorize"
    expected["audit_receipt_sha256"] = audit_sha
    if authority != expected:
        die("edge financial authority differs from the reviewed template")
    return authority, digest


def validate_durable_chain(audit: dict[str, Any]) -> None:
    args = argparse.Namespace(
        durable_run=audit["durable_requeue_run"],
        durable_authority=audit["durable_requeue_authority"],
        durable_authority_sha256=audit["durable_requeue_authority_sha256"])
    _, _, durable_audit_sha, durable_authority_sha, _, context = \
        load_durable_context(args, require_selected_queued=False)
    if (durable_audit_sha != audit["durable_requeue_audit_sha256"] or
            durable_authority_sha != audit["durable_requeue_authority_sha256"] or
            context["durable_requeue_complete_sha256"] !=
            audit["durable_requeue_complete_sha256"]):
        die("edge audit durable-requeue chain changed")


def current_static_snapshot(contract: Any, audit: dict[str, Any],
                            immediate: dict[str, Any]) -> dict[str, Any]:
    queue = durable.audit_queue(contract)
    return {
        "wallet_selection": legacy.node30.wallet_inventory_identity(
            immediate["wallet_inventory"], "edge current wallet selection"),
        "queue_item": legacy.immutable_queue_item_identity(queue["item"]),
        "ingress_items": durable.ingress_identity(queue["ingress_items"]),
        "preserved_done": queue["preserved_done"],
        "queue_directory": queue["queue_directory"],
        "done_directory": queue["done_directory"],
        "awarded_sha256": queue["awarded"]["sha256"],
        "payout": audit["snapshot"]["payout"],
        "fee_input_non_tip": legacy.fee_inventory_non_tip_identity(
            immediate["fee_input"]),
    }


def edge_rebind(transport: Any, node: Any, contract: Any,
                audit: dict[str, Any]) -> dict[str, Any]:
    payout = audit["snapshot"]["payout"]
    fee_address = audit["snapshot"]["fee_input"]["address"]
    goldrush = transport.rpc(node, "getgoldrushinfo")
    if (not isinstance(goldrush, dict) or goldrush.get("active") is not True or
            goldrush.get("competing_claim_rule_active_next_block") is not False or
            goldrush.get("qqp4_active_next_block") is not False):
        die("node30 left the exact active QQP2 reward window")
    raw_work = transport.rpc(
        node, "getshadowpowwork", fee_address, payout["address"])
    immediate = legacy.pre_call_resample(transport, node)
    if sha256_json(current_static_snapshot(contract, audit, immediate)) != \
            audit["static_identity_sha256"]:
        die("edge static identity differs from the reviewed authority")
    chain = {"blocks": immediate["chain"]["height"],
             "bestblockhash": immediate["chain"]["tip"]}
    try:
        work = legacy.validate_work(
            raw_work, chain, immediate["fee_input"], payout)
    except legacy.GateError as exc:
        if str(exc) == "getshadowpowwork is not exact active QQP2 work for the queued payout":
            raise EdgeTransient("tip moved before dynamic work rebind") from exc
        raise
    mempool = pinned.mempool_shadow_inventory(transport, node)
    if (mempool["shadow_proof_count"] != 0 or
            mempool["slot_clear"] is not True):
        raise EdgeTransient("shadow-proof slot refilled during dynamic rebind")
    if mempool["chain"] != immediate["chain"]:
        raise EdgeTransient("active tip moved during dynamic edge rebind")
    return {
        "chain": immediate["chain"],
        "fee_input": immediate["fee_input"],
        "wallet_inventory": immediate["wallet_inventory"],
        "wallet_txids_before": immediate["wallet_txids"],
        "wallet_txids_before_sha256": immediate["wallet_txids_sha256"],
        "payout": payout,
        "work": work,
        "mempool_clearance": mempool,
    }


def publish_abort(run_dir: pathlib.Path, contract: Any, audit_sha: str,
                  authority_sha: str, reason: str, observations: int,
                  clear_rebinds: int) -> str:
    receipt = base_receipt("node30-free-claim-edge-aborted", contract)
    receipt.update({
        "result": "NO_INTENT_EDGE_WINDOW_EXHAUSTED_AUTHORITY_DISCARDED",
        "edge_audit_sha256": audit_sha,
        "edge_authority_sha256": authority_sha,
        "reason": reason,
        "mempool_observations": observations,
        "clear_rebind_attempts": clear_rebinds,
        "intent_published": False,
        "sendshadowpowclaim_call_count": 0,
        "authority_consumed": False,
        "authority_reuse_authorized": False,
        "fresh_edge_audit_and_authority_required": True,
    })
    return legacy.node30.publish_json(run_dir / "edge-aborted.json", receipt)


def intent_expected(contract: Any, audit: dict[str, Any], audit_sha: str,
                    authority_sha: str, current: dict[str, Any],
                    observations: int, clear_rebinds: int,
                    lock_ids: Any) -> dict[str, Any]:
    receipt = base_receipt("node30-free-claim-edge-intent", contract)
    receipt.update({
        "state": "EDGE_AUTHORITY_CONSUMED_RPC_PENDING_OR_COMPLETE",
        "edge_audit_sha256": audit_sha,
        "edge_authority_sha256": authority_sha,
        "durable_requeue_complete_sha256":
            audit["durable_requeue_complete_sha256"],
        "static_identity_sha256": audit["static_identity_sha256"],
        "dynamic_rebind": {
            "chain": current["chain"], "work": current["work"],
            "mempool_clearance": current["mempool_clearance"],
            "mempool_observations": observations,
            "clear_rebind_attempts": clear_rebinds,
        },
        "rpc_method": "sendshadowpowclaim",
        "rpc_parameters": {
            "address": current["fee_input"]["address"],
            "quantum_address": current["payout"]["address"],
            "max_tries": legacy.MAX_TRIES,
            "fee_rate": legacy.FEE_RATE_ATOMS_PER_VBYTE,
            "proof": None,
        },
        "fee_input": current["fee_input"],
        "payout": current["payout"],
        "work": current["work"],
        "wallet_txids_before": current["wallet_txids_before"],
        "wallet_txids_before_sha256": current["wallet_txids_before_sha256"],
        "pre_call_resample": {
            "matched_dynamic_rebind": True,
            "chain": current["chain"],
            "fee_input_members_sha256": current["fee_input"]["members_sha256"],
            "wallet_txids_sha256": current["wallet_txids_before_sha256"],
            "wallet_inventory": current["wallet_inventory"],
        },
        "call_budget": 1,
        "calls_completed_before_intent": 0,
        "lock_identities": lock_ids,
        "created_at": legacy.node30.base.utc_now(),
    })
    return receipt


def validate_intent(receipt: Any, contract: Any, audit: dict[str, Any],
                    audit_sha: str, authority_sha: str) -> dict[str, Any]:
    validate_common(receipt, "node30-free-claim-edge-intent", contract)
    expected = set(base_receipt("node30-free-claim-edge-intent", contract)) | {
        "state", "edge_audit_sha256", "edge_authority_sha256",
        "durable_requeue_complete_sha256", "static_identity_sha256",
        "dynamic_rebind", "rpc_method", "rpc_parameters", "fee_input",
        "payout", "work", "wallet_txids_before", "wallet_txids_before_sha256",
        "pre_call_resample", "call_budget", "calls_completed_before_intent",
        "lock_identities", "created_at",
    }
    dynamic = receipt.get("dynamic_rebind")
    mempool = dynamic.get("mempool_clearance") if isinstance(dynamic, dict) else None
    pre_call = receipt.get("pre_call_resample")
    chain = dynamic.get("chain") if isinstance(dynamic, dict) else None
    if (set(receipt) != expected or
            receipt.get("state") != "EDGE_AUTHORITY_CONSUMED_RPC_PENDING_OR_COMPLETE" or
            receipt.get("edge_audit_sha256") != audit_sha or
            receipt.get("edge_authority_sha256") != authority_sha or
            receipt.get("durable_requeue_complete_sha256") !=
            audit["durable_requeue_complete_sha256"] or
            receipt.get("static_identity_sha256") != audit["static_identity_sha256"] or
            not isinstance(dynamic, dict) or
            set(dynamic) != {"chain", "work", "mempool_clearance",
                             "mempool_observations", "clear_rebind_attempts"} or
            not isinstance(mempool, dict) or mempool.get("shadow_proof_count") != 0 or
            mempool.get("slot_clear") is not True or
            mempool.get("chain") != dynamic.get("chain") or
            not isinstance(chain, dict) or set(chain) != {"height", "tip"} or
            type(chain.get("height")) is not int or chain["height"] < 1 or
            not isinstance(chain.get("tip"), str) or
            legacy.HEX64.fullmatch(chain["tip"]) is None or
            type(dynamic.get("mempool_observations")) is not int or
            dynamic["mempool_observations"] < 1 or
            type(dynamic.get("clear_rebind_attempts")) is not int or
            not 1 <= dynamic["clear_rebind_attempts"] <= MAX_CLEAR_REBINDS or
            not isinstance(receipt.get("fee_input"), dict) or
            not isinstance(receipt.get("payout"), dict) or
            receipt.get("rpc_method") != "sendshadowpowclaim" or
            receipt.get("rpc_parameters") != {
                "address": receipt.get("fee_input", {}).get("address"),
                "quantum_address": receipt.get("payout", {}).get("address"),
                "max_tries": legacy.MAX_TRIES,
                "fee_rate": legacy.FEE_RATE_ATOMS_PER_VBYTE,
                "proof": None} or
            receipt.get("work") != dynamic.get("work") or
            legacy.validate_work(
                receipt.get("work"),
                {"blocks": chain.get("height"), "bestblockhash": chain.get("tip")},
                receipt.get("fee_input"), receipt.get("payout")) != receipt.get("work") or
            not isinstance(receipt.get("wallet_txids_before"), list) or
            receipt.get("wallet_txids_before_sha256") !=
            sha256_json(receipt["wallet_txids_before"]) or
            not isinstance(pre_call, dict) or set(pre_call) != {
                "matched_dynamic_rebind", "chain", "fee_input_members_sha256",
                "wallet_txids_sha256", "wallet_inventory"} or
            pre_call.get("matched_dynamic_rebind") is not True or
            pre_call.get("chain") != chain or
            pre_call.get("fee_input_members_sha256") !=
            receipt.get("fee_input", {}).get("members_sha256") or
            pre_call.get("wallet_txids_sha256") !=
            receipt.get("wallet_txids_before_sha256") or
            receipt.get("call_budget") != 1 or
            receipt.get("calls_completed_before_intent") != 0):
        die("edge intent is not exact")
    if sha256_json({
            "wallet_selection": legacy.node30.wallet_inventory_identity(
                receipt["pre_call_resample"]["wallet_inventory"],
                "edge intent wallet selection"),
            "queue_item": audit["static_identity"]["queue_item"],
            "ingress_items": audit["static_identity"]["ingress_items"],
            "preserved_done": audit["static_identity"]["preserved_done"],
            "queue_directory": audit["static_identity"]["queue_directory"],
            "done_directory": audit["static_identity"]["done_directory"],
            "awarded_sha256": audit["static_identity"]["awarded_sha256"],
            "payout": receipt["payout"],
            "fee_input_non_tip": legacy.fee_inventory_non_tip_identity(
                receipt["fee_input"]),
            }) != audit["static_identity_sha256"]:
        die("edge intent static identity differs from authority")
    return receipt


def publish_unknown(run_dir: pathlib.Path, contract: Any, intent_sha: str,
                    message: str, outcome: dict[str, Any]) -> str:
    receipt = base_receipt("node30-free-claim-edge-rpc-unknown", contract)
    receipt.update({
        "state": "UNKNOWN_EDGE_AUTHORITY_CONSUMED_NEVER_RETRY",
        "intent_sha256": intent_sha,
        "error": message,
        "queue_outcome": outcome,
        "retry_authorized": False,
        "sendshadowpowclaim_call_count": 1,
    })
    return legacy.node30.publish_json(run_dir / "rpc-unknown.json", receipt)


def complete_receipt(contract: Any, audit_sha: str, authority_sha: str,
                     intent_sha: str, response_sha: str | None,
                     evidence: dict[str, Any], outcome: dict[str, Any],
                     result: str, lock_ids: Any) -> dict[str, Any]:
    receipt = base_receipt("node30-free-claim-edge-broadcast-complete", contract)
    receipt.update({
        "result": result,
        "edge_audit_sha256": audit_sha,
        "edge_authority_sha256": authority_sha,
        "intent_sha256": intent_sha,
        "rpc_response_sha256": response_sha,
        "transaction": evidence,
        "queue_outcome": outcome,
        "sendshadowpowclaim_call_count": 1,
        "proof_override_used": False,
        "pause_preserved": True,
        "ordinary_pow_enabled": False,
        "recurring_worker_invoked": False,
        "lock_identities": lock_ids,
    })
    return receipt


def execute_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    legacy.node30.base.ensure_secure_dir(run_dir)
    contract = legacy.load_contract(run_dir)
    audit, audit_sha = load_audit(run_dir, contract)
    validate_durable_chain(audit)
    _, authority_sha = load_authority(args, contract, audit, audit_sha)
    forbidden = ["intent.json", "rpc-response.json", "rpc-unknown.json",
                 "broadcast-complete.json", "edge-aborted.json"]
    if any((run_dir / name).exists() or (run_dir / name).is_symlink()
           for name in forbidden):
        die("edge authority was already used; never invoke execute again")
    transport = Transport(contract.retained.runtime)
    node = contract.retained.runtime.nodes[0]
    # Complete the expensive invariant validation before entering the transient
    # vacancy watch.
    with legacy.node30.mutation_locks(contract.retained):
        pause_preflight = legacy.node30.free_claim_snapshot(contract.retained)
        exact_node, runtime_preflight = legacy.node30.pin_node(transport, node)
        preflight = durable.stable_live_snapshot(transport, contract, exact_node)
        if sha256_json(static_identity(preflight)) != audit["static_identity_sha256"]:
            die("edge static identity changed before vacancy watch")
        if (legacy.node30.free_claim_snapshot(contract.retained) != pause_preflight or
                transport.runtime_snapshot(node) != runtime_preflight):
            die("node30 pause or runtime changed during edge preflight")
    deadline = time.monotonic() + audit["watch"]["max_wait_seconds"]
    observations = 0
    clear_rebinds = 0
    while time.monotonic() < deadline:
        observation = pinned.mempool_shadow_inventory(transport, exact_node)
        observations += 1
        if observation["shadow_proof_count"] != 0:
            time.sleep(audit["watch"]["poll_milliseconds"] / 1000)
            continue
        clear_rebinds += 1
        if clear_rebinds > audit["watch"]["max_clear_rebinds"]:
            digest = publish_abort(
                run_dir, contract, audit_sha, authority_sha,
                "clear-slot dynamic rebind budget exhausted",
                observations, clear_rebinds - 1)
            print(json.dumps({"result":
                              "NO_INTENT_EDGE_WINDOW_EXHAUSTED_AUTHORITY_DISCARDED",
                              "abort_sha256": digest}, sort_keys=True))
            return
        try:
            with legacy.node30.mutation_locks(contract.retained) as lock_ids:
                pause_before = legacy.node30.free_claim_snapshot(contract.retained)
                edge_node, runtime_before = legacy.node30.pin_node(transport, node)
                current = edge_rebind(transport, edge_node, contract, audit)
                if (legacy.node30.free_claim_snapshot(contract.retained) != pause_before or
                        transport.runtime_snapshot(node) != runtime_before):
                    die("node30 pause or runtime changed during dynamic edge rebind")
                intent = intent_expected(
                    contract, audit, audit_sha, authority_sha, current,
                    observations, clear_rebinds, lock_ids)
                intent_sha = legacy.node30.publish_json(run_dir / "intent.json", intent)
                try:
                    response = transport.rpc(
                        edge_node, "sendshadowpowclaim",
                        current["fee_input"]["address"],
                        current["payout"]["address"], legacy.MAX_TRIES,
                        legacy.FEE_RATE_ATOMS_PER_VBYTE)
                except (legacy.node30.base.GateError, legacy.node30.GateError,
                        OSError, subprocess.TimeoutExpired) as exc:
                    outcome = durable.transition_queue(contract, audit, "uncertain")
                    publish_unknown(run_dir, contract, intent_sha, str(exc), outcome)
                    raise GateError(
                        "edge response is unknown; authority consumed, never retry") from exc
                response_receipt = base_receipt(
                    "node30-free-claim-edge-rpc-response", contract)
                response_receipt.update({
                    "intent_sha256": intent_sha,
                    "sendshadowpowclaim_call_count": 1,
                    "raw_response": response,
                    "published_before_post_call_rpc_reads": True,
                })
                response_sha = legacy.node30.publish_json(
                    run_dir / "rpc-response.json", response_receipt)
                try:
                    evidence = legacy.signed_transaction_evidence(
                        transport, edge_node, response, intent)
                except (legacy.node30.base.GateError, legacy.node30.GateError,
                        OSError, subprocess.TimeoutExpired) as exc:
                    outcome = durable.transition_queue(contract, audit, "uncertain")
                    invalid = base_receipt(
                        "node30-free-claim-edge-invalid-response", contract)
                    invalid.update({
                        "intent_sha256": intent_sha,
                        "rpc_response_sha256": response_sha,
                        "state": "RESPONSE_PERSISTED_VALIDATION_FAILED_NEVER_RETRY",
                        "error": str(exc), "queue_outcome": outcome,
                        "retry_authorized": False,
                    })
                    legacy.node30.publish_json(
                        run_dir / "invalid-response.json", invalid)
                    raise GateError(
                        "edge RPC returned unprovable bytes; authority consumed") from exc
                outcome = durable.transition_queue(contract, audit, "broadcast")
                role_after = legacy.node30.role_snapshot(transport, edge_node, False)
                if (legacy.node30.free_claim_snapshot(contract.retained) != pause_before or
                        transport.runtime_snapshot(node) != runtime_before or
                        role_after["ordinary_pow"]["enabled"] is not False or
                        role_after["pos"]["staking"] is not True):
                    die("node30 role changed after the edge one-shot")
                complete = complete_receipt(
                    contract, audit_sha, authority_sha, intent_sha, response_sha,
                    evidence, outcome, "EXACT_DYNAMIC_EDGE_BROADCAST", lock_ids)
                complete_sha = legacy.node30.publish_json(
                    run_dir / "broadcast-complete.json", complete)
            print(json.dumps({"result": complete["result"],
                              "txid": evidence["identity"]["txid"],
                              "broadcast_complete_sha256": complete_sha},
                             sort_keys=True))
            return
        except EdgeTransient:
            time.sleep(audit["watch"]["poll_milliseconds"] / 1000)
            continue
    digest = publish_abort(
        run_dir, contract, audit_sha, authority_sha,
        "vacancy watch deadline exhausted", observations, clear_rebinds)
    print(json.dumps({
        "result": "NO_INTENT_EDGE_WINDOW_EXHAUSTED_AUTHORITY_DISCARDED",
        "abort_sha256": digest}, sort_keys=True))


def load_intent(run_dir: pathlib.Path, contract: Any, audit: dict[str, Any],
                audit_sha: str, authority_sha: str) -> tuple[dict[str, Any], str]:
    receipt, digest = legacy.node30.load_run_receipt(run_dir, "intent.json")
    validate_intent(receipt, contract, audit, audit_sha, authority_sha)
    return receipt, digest


def load_response(run_dir: pathlib.Path, contract: Any,
                  intent_sha: str) -> tuple[dict[str, Any], str]:
    receipt, digest = legacy.node30.load_run_receipt(run_dir, "rpc-response.json")
    validate_common(receipt, "node30-free-claim-edge-rpc-response", contract)
    expected = set(base_receipt(
        "node30-free-claim-edge-rpc-response", contract)) | {
            "intent_sha256", "sendshadowpowclaim_call_count", "raw_response",
            "published_before_post_call_rpc_reads",
        }
    if (set(receipt) != expected or receipt.get("intent_sha256") != intent_sha or
            receipt.get("sendshadowpowclaim_call_count") != 1 or
            receipt.get("published_before_post_call_rpc_reads") is not True):
        die("edge RPC response receipt is not exact")
    return receipt, digest


def load_complete(run_dir: pathlib.Path, contract: Any, audit: dict[str, Any],
                  audit_sha: str, authority_sha: str, intent: dict[str, Any],
                  intent_sha: str) -> tuple[dict[str, Any], str]:
    receipt, digest = legacy.node30.load_run_receipt(
        run_dir, "broadcast-complete.json")
    validate_common(receipt, "node30-free-claim-edge-broadcast-complete", contract)
    expected = set(base_receipt(
        "node30-free-claim-edge-broadcast-complete", contract)) | {
            "result", "edge_audit_sha256", "edge_authority_sha256",
            "intent_sha256", "rpc_response_sha256", "transaction",
            "queue_outcome", "sendshadowpowclaim_call_count",
            "proof_override_used", "pause_preserved", "ordinary_pow_enabled",
            "recurring_worker_invoked", "lock_identities",
        }
    if (set(receipt) != expected or receipt.get("result") not in
            {"EXACT_DYNAMIC_EDGE_BROADCAST",
             "EXACT_DYNAMIC_EDGE_RECONCILED_WITHOUT_RETRY"} or
            receipt.get("edge_audit_sha256") != audit_sha or
            receipt.get("edge_authority_sha256") != authority_sha or
            receipt.get("intent_sha256") != intent_sha or
            receipt.get("sendshadowpowclaim_call_count") != 1 or
            receipt.get("proof_override_used") is not False or
            receipt.get("pause_preserved") is not True or
            receipt.get("ordinary_pow_enabled") is not False or
            receipt.get("recurring_worker_invoked") is not False):
        die("edge broadcast completion is not exact")
    transaction = legacy.validate_transaction_receipt(
        receipt.get("transaction"), intent, "edge broadcast completion")
    response_sha = receipt.get("rpc_response_sha256")
    if receipt["result"] == "EXACT_DYNAMIC_EDGE_BROADCAST":
        legacy.require_hex64(response_sha, "edge broadcast RPC response receipt")
        response, loaded_sha = load_response(run_dir, contract, intent_sha)
        if response_sha != loaded_sha:
            die("edge completion response receipt digest changed")
        legacy.response_matches_transaction(response, transaction, intent)
    elif response_sha is not None:
        legacy.require_hex64(response_sha, "edge reconciled RPC response receipt")
        _, loaded_sha = load_response(run_dir, contract, intent_sha)
        if response_sha != loaded_sha:
            die("edge reconciled response receipt digest changed")
    outcome = receipt.get("queue_outcome")
    if not isinstance(outcome, dict) or outcome.get("state") != "broadcast":
        die("edge completion queue outcome is not broadcast")
    return receipt, digest


def load_terminal(run_dir: pathlib.Path, contract: Any, audit: dict[str, Any],
                  intent: dict[str, Any], broadcast: dict[str, Any],
                  broadcast_sha: str) -> tuple[dict[str, Any], str]:
    receipt, digest = legacy.node30.load_run_receipt(run_dir, "terminal.json")
    validate_common(receipt, "node30-free-claim-edge-terminal", contract)
    expected = set(base_receipt(
        "node30-free-claim-edge-terminal", contract)) | {
            "result", "broadcast_complete_sha256", "txid", "confirmations",
            "blockhash", "active_block_header", "synthetic_payout",
            "awarded_ledger", "queue_outcome", "pause_preserved",
            "ordinary_pow_enabled", "pos_active", "recurring_worker_invoked",
            "lock_identities",
        }
    transaction = broadcast["transaction"]
    header = receipt.get("active_block_header")
    blockhash = receipt.get("blockhash")
    confirmations = receipt.get("confirmations")
    if (set(receipt) != expected or
            receipt.get("result") != "CONFIRMED_DYNAMIC_EDGE_QUANTUM_PAYOUT" or
            receipt.get("broadcast_complete_sha256") != broadcast_sha or
            receipt.get("txid") != transaction["identity"]["txid"] or
            type(confirmations) is not int or confirmations < 1 or
            not isinstance(blockhash, str) or legacy.HEX64.fullmatch(blockhash) is None or
            not isinstance(header, dict) or header.get("hash") != blockhash or
            type(header.get("height")) is not int or
            type(header.get("confirmations")) is not int or
            header["confirmations"] < 1 or
            receipt.get("pause_preserved") is not True or
            receipt.get("ordinary_pow_enabled") is not False or
            receipt.get("pos_active") is not True or
            receipt.get("recurring_worker_invoked") is not False):
        die("edge terminal receipt is not exact")
    legacy.terminal_payout({
        "schema": "blackcoin.shadow.script.v1",
        "scriptPubKey": transaction["payout"]["scriptPubKey"],
        "address": transaction["payout"]["address"],
        "synthetic": True, "merkle_included": False,
        "records": [receipt.get("synthetic_payout")],
    }, transaction, blockhash, header["height"], intent)
    _, after_sha = legacy.expected_awarded_after(contract, audit)
    awarded = receipt.get("awarded_ledger")
    outcome = receipt.get("queue_outcome")
    confirmed_path = (contract.done_dir /
                      audit["snapshot"]["queue"]["outcome_names"]["confirmed"])
    if (not isinstance(awarded, dict) or
            awarded.get("before_sha256") !=
            audit["snapshot"]["queue"]["awarded"]["sha256"] or
            awarded.get("after_sha256") != after_sha or
            awarded.get("atomic_replace") is not True or
            not isinstance(outcome, dict) or outcome.get("state") != "confirmed" or
            outcome.get("path") != str(confirmed_path) or
            outcome.get("atomic_rename") is not True):
        die("edge terminal receipt does not bind its durable outcomes")
    return receipt, digest


def reconcile_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    legacy.node30.base.ensure_secure_dir(run_dir)
    contract = legacy.load_contract(run_dir)
    audit, audit_sha = load_audit(run_dir, contract)
    validate_durable_chain(audit)
    _, authority_sha = load_authority(args, contract, audit, audit_sha)
    intent, intent_sha = load_intent(
        run_dir, contract, audit, audit_sha, authority_sha)
    complete_path = run_dir / "broadcast-complete.json"
    if complete_path.exists() or complete_path.is_symlink():
        complete, digest = load_complete(
            run_dir, contract, audit, audit_sha, authority_sha, intent, intent_sha)
        state, _ = durable.current_queue_state(contract, audit)
        if state not in {"broadcast", "confirmed"}:
            die("edge completion has no exact queue outcome")
        print(json.dumps({"result": complete["result"],
                          "txid": complete["transaction"]["identity"]["txid"],
                          "broadcast_complete_sha256": digest,
                          "already_complete": True}, sort_keys=True))
        return
    transport = Transport(contract.retained.runtime)
    node = contract.retained.runtime.nodes[0]
    with legacy.node30.mutation_locks(contract.retained) as lock_ids:
        pause_before = legacy.node30.free_claim_snapshot(contract.retained)
        exact_node, runtime_before = legacy.node30.pin_node(transport, node)
        role = legacy.node30.role_snapshot(transport, exact_node, False)
        legacy.node30.same_wallet_inventory(
            intent["pre_call_resample"]["wallet_inventory"],
            role["wallet_inventory"], "edge reconciliation")
        candidates = legacy.reconcile_candidates(transport, exact_node, intent)
        if not candidates:
            state, path = durable.current_queue_state(contract, audit)
            receipt = base_receipt(
                "node30-free-claim-edge-reconcile-observation", contract)
            receipt.update({
                "result": "NO_EXACT_EDGE_TRANSACTION_YET_AUTHORITY_CONSUMED",
                "edge_audit_sha256": audit_sha,
                "edge_authority_sha256": authority_sha,
                "intent_sha256": intent_sha,
                "queue_state": state, "queue_path": str(path),
                "retry_authorized": False, "candidate_count": 0,
                "lock_identities": lock_ids,
            })
            digest = legacy.node30.publish_json(
                run_dir / f"reconcile-{time.time_ns()}.json", receipt)
            if (legacy.node30.free_claim_snapshot(contract.retained) != pause_before or
                    transport.runtime_snapshot(node) != runtime_before):
                die("node30 changed during edge reconciliation")
            print(json.dumps({"result": receipt["result"], "sha256": digest},
                             sort_keys=True))
            return
        evidence = candidates[0]
        outcome = durable.transition_queue(contract, audit, "broadcast")
        response_sha = None
        if (run_dir / "rpc-response.json").exists():
            _, response_sha = load_response(run_dir, contract, intent_sha)
        if (legacy.node30.free_claim_snapshot(contract.retained) != pause_before or
                transport.runtime_snapshot(node) != runtime_before):
            die("node30 changed during edge transaction reconciliation")
        complete = complete_receipt(
            contract, audit_sha, authority_sha, intent_sha, response_sha,
            evidence, outcome, "EXACT_DYNAMIC_EDGE_RECONCILED_WITHOUT_RETRY",
            lock_ids)
        complete_sha = legacy.node30.publish_json(
            complete_path, complete)
    print(json.dumps({"result": complete["result"],
                      "txid": evidence["identity"]["txid"],
                      "broadcast_complete_sha256": complete_sha}, sort_keys=True))


def monitor_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    legacy.node30.base.ensure_secure_dir(run_dir)
    contract = legacy.load_contract(run_dir)
    audit, audit_sha = load_audit(run_dir, contract)
    validate_durable_chain(audit)
    _, authority_sha = load_authority(args, contract, audit, audit_sha)
    intent, intent_sha = load_intent(
        run_dir, contract, audit, audit_sha, authority_sha)
    broadcast, broadcast_sha = load_complete(
        run_dir, contract, audit, audit_sha, authority_sha, intent, intent_sha)
    terminal_path = run_dir / "terminal.json"
    if terminal_path.exists() or terminal_path.is_symlink():
        terminal, terminal_sha = load_terminal(
            run_dir, contract, audit, intent, broadcast, broadcast_sha)
        if durable.current_queue_state(contract, audit)[0] != "confirmed":
            die("edge terminal receipt has no exact confirmed queue state")
        legacy.awarded_snapshot(contract, terminal["awarded_ledger"]["after_sha256"])
        legacy.node30.free_claim_snapshot(contract.retained)
        print(json.dumps({"result": terminal["result"], "txid": terminal["txid"],
                          "terminal_sha256": terminal_sha,
                          "already_complete": True}, sort_keys=True))
        return
    transport = Transport(contract.retained.runtime)
    node = contract.retained.runtime.nodes[0]
    with legacy.node30.mutation_locks(contract.retained) as lock_ids:
        pause_before = legacy.node30.free_claim_snapshot(contract.retained)
        exact_node, runtime_before = legacy.node30.pin_node(transport, node)
        role = legacy.node30.role_snapshot(transport, exact_node, False)
        legacy.node30.same_wallet_inventory(
            intent["pre_call_resample"]["wallet_inventory"],
            role["wallet_inventory"], "edge monitor")
        transaction = broadcast["transaction"]
        tx = transport.rpc(
            exact_node, "gettransaction", transaction["identity"]["txid"], True, True)
        confirmations = tx.get("confirmations") if isinstance(tx, dict) else None
        if type(confirmations) is not int or confirmations < 1:
            if (legacy.node30.free_claim_snapshot(contract.retained) != pause_before or
                    transport.runtime_snapshot(node) != runtime_before):
                die("node30 changed during edge pending monitor")
            receipt = base_receipt("node30-free-claim-edge-monitor-observation", contract)
            receipt.update({
                "result": "DYNAMIC_EDGE_BROADCAST_PENDING_ACTIVE_CHAIN_CONFIRMATION",
                "broadcast_complete_sha256": broadcast_sha,
                "txid": transaction["identity"]["txid"],
                "confirmations": confirmations if type(confirmations) is int else 0,
                "queue_state": durable.current_queue_state(contract, audit)[0],
                "pause_preserved": True, "retry_authorized": False,
                "lock_identities": lock_ids,
            })
            name = f"monitor-{time.time_ns()}.json"
            digest = legacy.node30.publish_json(run_dir / name, receipt)
            print(json.dumps({"result": receipt["result"], "receipt": name,
                              "sha256": digest}, sort_keys=True))
            return
        raw = legacy.candidate_response_from_gettransaction(tx)
        if raw is None:
            die("confirmed edge transaction lacks exact signed claim bytes")
        raw["address"] = intent["fee_input"]["address"]
        raw["quantum_address"] = intent["payout"]["address"]
        confirmed = legacy.signed_transaction_evidence(
            transport, exact_node, raw, intent)
        if (legacy.validate_transaction_receipt(confirmed, intent, "confirmed edge") !=
                legacy.validate_transaction_receipt(
                    transaction, intent, "authorized edge broadcast")):
            die("confirmed edge transaction differs from authorized signed bytes")
        blockhash = legacy.require_hex64(tx.get("blockhash"), "edge blockhash")
        header = transport.rpc(exact_node, "getblockheader", blockhash)
        if (not isinstance(header, dict) or header.get("hash") != blockhash or
                type(header.get("height")) is not int or
                type(header.get("confirmations")) is not int or
                header["confirmations"] < 1):
            die("edge confirmation block is not active")
        history = transport.rpc(
            exact_node, "getshadowscript", transaction["payout"]["scriptPubKey"])
        payout = legacy.terminal_payout(
            history, transaction, blockhash, header["height"], intent)
        awarded = legacy.install_awarded_after(contract, audit)
        outcome = durable.transition_queue(contract, audit, "confirmed")
        if (legacy.node30.free_claim_snapshot(contract.retained) != pause_before or
                transport.runtime_snapshot(node) != runtime_before):
            die("node30 changed during edge terminal monitor")
        receipt = base_receipt("node30-free-claim-edge-terminal", contract)
        receipt.update({
            "result": "CONFIRMED_DYNAMIC_EDGE_QUANTUM_PAYOUT",
            "broadcast_complete_sha256": broadcast_sha,
            "txid": transaction["identity"]["txid"],
            "confirmations": confirmations, "blockhash": blockhash,
            "active_block_header": header, "synthetic_payout": payout,
            "awarded_ledger": awarded, "queue_outcome": outcome,
            "pause_preserved": True, "ordinary_pow_enabled": False,
            "pos_active": True, "recurring_worker_invoked": False,
            "lock_identities": lock_ids,
        })
        terminal_sha = legacy.node30.publish_json(terminal_path, receipt)
    print(json.dumps({"result": receipt["result"], "txid": receipt["txid"],
                      "terminal_sha256": terminal_sha}, sort_keys=True))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    audit = commands.add_parser("audit")
    audit.add_argument("--durable-run", required=True)
    audit.add_argument("--durable-authority", required=True)
    audit.add_argument("--durable-authority-sha256", required=True)
    audit.add_argument("--run-dir", required=True)
    audit.add_argument("--max-wait-seconds", type=int, default=300)
    audit.add_argument("--poll-milliseconds", type=int, default=250)
    audit.set_defaults(func=audit_command)
    for name, func in [("execute", execute_command),
                       ("reconcile", reconcile_command),
                       ("monitor", monitor_command)]:
        command = commands.add_parser(name)
        command.add_argument("--run-dir", required=True)
        command.add_argument("--authority", required=True)
        command.add_argument("--authority-sha256", required=True)
        command.set_defaults(func=func)
    return result


def main(argv: Sequence[str] | None = None) -> int:
    os.umask(0o077)
    try:
        if legacy.test_mode():
            test_transport = pathlib.Path(os.environ["FLEET31_TEST_TRANSPORT"])
            test_transport_sha = sha256_file(test_transport)
            if test_transport_sha not in TEST_TRANSPORT_SHA256S:
                die("offline edge transport is not hash-pinned")
            legacy.node30.base.TEST_TRANSPORT_SHA256 = test_transport_sha
        else:
            legacy.CONTROLLER_RUNTIME_IDENTITY = legacy.validate_controller_runtime()
    except (legacy.node30.base.GateError, legacy.node30.GateError,
            legacy.GateError, pinned.GateError, durable.GateError,
            GateError, OSError) as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1
    for name in ["PYTHONPATH", "PYTHONHOME", "BASH_ENV", "ENV", "CDPATH"]:
        os.environ.pop(name, None)
    args = parser().parse_args(argv)
    try:
        args.func(args)
    except (legacy.node30.base.GateError, legacy.node30.GateError,
            legacy.GateError, pinned.GateError, durable.GateError,
            GateError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
