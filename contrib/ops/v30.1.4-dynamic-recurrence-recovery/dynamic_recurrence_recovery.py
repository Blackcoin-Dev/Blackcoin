#!/usr/bin/python3
"""Fail-closed dynamic-subset recovery for recurring v30.1.4 PoW quarantine.

The signed fleet31 recovery module supplies the receipt, transport, fee-proof,
exact-byte, acknowledgement, reconciliation, and monitoring primitives.  This
controller adds one deliberately narrow capability: a fresh read-only census
of all 31 ordinary-PoW wallets selects only the nodes that are *currently*
blocked by exactly one actionable quarantined claim.  Every authority and
receipt binds that selected set and its complement.  Node30 is absent.
"""

from __future__ import annotations

import argparse
import dataclasses
import importlib.util
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import time
from decimal import Decimal
from typing import Any, Sequence


FULL_NODE_SET = tuple([*range(1, 30), 31, 32])
BASE_TOOL_SHA256 = "eb529eb87ad1abc740345ddf5e06e0bbb8ae60b264b0d257fc95bad248a72680"
TEST_TRANSPORT_SHA256 = "40b23c7849a8cc70dd7b5a6e65500248286b00031a4f92056763107b70c60db0"
RECURRENCE_CONTRACT = "installed-v30.1.4-dynamic-shadowpow-recurrence/v1"
RECURRENCE_AUDIT_KIND = "dynamic-shadowpow-recurrence-audit"
RECURRENCE_PHASE_A_RESULT = "SIGNED_EXACT_AUDITED_SUBSET_WITHOUT_RELAY_AUTHORITY"
ALLOWED_CLEAR_STATES = {"ready", "claim_in_flight", "hashing"}
PASSIVE_CLEAR_REFUSAL_CLASSIFICATIONS = {
    "anchor-spent": {"resolved_on_active_chain"},
    "claim-not-terminal": {"live", "transient", "indeterminate"},
    "claim-live": {"indeterminate"},
}


def _load_base():
    path = (pathlib.Path(__file__).resolve(strict=True).parent.parent /
            "v30.1.4-fleet31-recovery" / "fleet31_recovery.py")
    try:
        st = path.lstat()
    except FileNotFoundError as exc:
        raise RuntimeError(f"signed fleet31 primitive is absent: {path}") from exc
    if (not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or
            st.st_uid != os.geteuid() or st.st_mode & 0o022 or path.resolve(strict=True) != path):
        raise RuntimeError("signed fleet31 primitive has unsafe path/type/owner/mode")
    digest = __import__("hashlib").sha256(path.read_bytes()).hexdigest()
    if digest != BASE_TOOL_SHA256:
        raise RuntimeError(f"signed fleet31 primitive SHA256 mismatch: {digest}")
    spec = importlib.util.spec_from_file_location("fleet31_signed_primitive", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load signed fleet31 primitive")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


b = _load_base()
ORIGINAL_VALIDATE_RUNTIME = b.validate_runtime_manifest
ORIGINAL_PHASE_A_VALIDATOR = b.validate_phase_a_receipt_chain
ORIGINAL_PHASE_B_AUTHORITY_VALIDATOR = b.validate_phase_b_authority
ORIGINAL_PUBLISH_JSON = b.publish_json
b.TEST_TRANSPORT_SHA256 = TEST_TRANSPORT_SHA256


def tool_identity() -> tuple[pathlib.Path, str]:
    path = pathlib.Path(__file__).resolve(strict=True)
    return path, b.sha256_file(path)


def selected_nodes(value: Any, label: str = "selected node set") -> tuple[int, ...]:
    if (not isinstance(value, list) or not value or
            any(isinstance(n, bool) or not isinstance(n, int) for n in value)):
        b.die(f"{label} must be a nonempty integer array")
    nodes = tuple(value)
    if nodes != tuple(sorted(set(nodes))) or any(n not in FULL_NODE_SET for n in nodes):
        b.die(f"{label} must be the exact sorted unique regular-node subset")
    return nodes


def filter_runtime(runtime: Any, nodes: tuple[int, ...]):
    selected = tuple(item for item in runtime.nodes if item.node in nodes)
    if tuple(item.node for item in selected) != nodes:
        b.die("runtime contract does not contain the selected recurrence subset")
    return dataclasses.replace(runtime, nodes=selected)


def configure_dynamic(nodes: tuple[int, ...], clear: tuple[int, ...]) -> None:
    """Bind the signed primitive to this immutable cycle's exact subset."""
    _, self_sha = tool_identity()
    expected_clear = tuple(n for n in FULL_NODE_SET if n not in nodes)
    if clear != expected_clear:
        b.die("audit selected/clear sets do not exactly partition the regular fleet")
    b.NODE_SET = nodes
    b.WAVE_PLAN = tuple((node,) for node in nodes)
    b.DEFERRED_NODE = nodes[-1]
    b.AGGREGATE_CAP = b.PER_NODE_CAP * Decimal(len(nodes))
    b.PHASE_A_TOOL_SHA256 = self_sha
    b.TEST_TRANSPORT_SHA256 = TEST_TRANSPORT_SHA256
    b.tool_identity = tool_identity

    def validate_runtime(path: pathlib.Path, expected_hash: str | None = None):
        current = b.NODE_SET
        try:
            b.NODE_SET = FULL_NODE_SET
            full = ORIGINAL_VALIDATE_RUNTIME(path, expected_hash)
        finally:
            b.NODE_SET = current
        return filter_runtime(full, nodes)

    b.validate_runtime_manifest = validate_runtime

    def validate_phase_a(run_dir, phase_a, phase_a_sha, runtime, current_tool_sha):
        if (not isinstance(phase_a, dict) or
                phase_a.get("result") != RECURRENCE_PHASE_A_RESULT or
                phase_a.get("audited_blocked_node_set") != list(nodes) or
                phase_a.get("audited_clear_node_set") != list(clear)):
            b.die("dynamic Phase-A completion does not bind the audited subset")
        surrogate = dict(phase_a)
        surrogate["result"] = "SIGNED_ALL_31_WITHOUT_RELAY_AUTHORITY"
        surrogate["mutation_performed"] = True
        return ORIGINAL_PHASE_A_VALIDATOR(
            run_dir, surrogate, phase_a_sha, runtime, current_tool_sha)

    b.validate_phase_a_receipt_chain = validate_phase_a

    def validate_phase_b_authority(authority, runtime, tool_sha, phase_a_sha,
                                   preview_sha, preview_receipt):
        result = ORIGINAL_PHASE_B_AUTHORITY_VALIDATOR(
            authority, runtime, tool_sha, phase_a_sha, preview_sha, preview_receipt)
        if (authority.get("recurrence_contract") != RECURRENCE_CONTRACT or
                authority.get("all_regular_node_set") != list(FULL_NODE_SET) or
                authority.get("audited_blocked_node_set") != list(nodes) or
                authority.get("audited_clear_node_set") != list(clear) or
                preview_receipt.get("recurrence_contract") != RECURRENCE_CONTRACT or
                preview_receipt.get("all_regular_node_set") != list(FULL_NODE_SET) or
                preview_receipt.get("audited_blocked_node_set") != list(nodes) or
                preview_receipt.get("audited_clear_node_set") != list(clear)):
            b.die("Phase-B authority does not bind the exact dynamic census partition")
        return result

    b.validate_phase_b_authority = validate_phase_b_authority

    def publish_dynamic(path: pathlib.Path, value: Any) -> str:
        if isinstance(value, dict):
            kind = value.get("kind")
            if kind in {
                    "fleet31-shadowpow-recovery-phase-b-wave",
                    "fleet31-shadowpow-recovery-phase-b-complete",
                    "fleet31-shadowpow-recovery-operational-monitor"}:
                value["recurrence_contract"] = RECURRENCE_CONTRACT
                value["audited_blocked_node_set"] = list(nodes)
                value["audited_clear_node_set"] = list(clear)
            if kind == "fleet31-shadowpow-recovery-phase-b-complete":
                value["result"] = "AUTHORIZED_RECOVERY_COMPLETE_EXACT_AUDITED_SUBSET"
            if kind == "fleet31-shadowpow-recovery-operational-monitor":
                value["result"] = (
                    "EXACT_AUDITED_SUBSET_POW_OPERATIONAL"
                    if value.get("operational_nodes") == len(nodes) and
                    value.get("fleet_fresh_claims_submitted", 0) > 0
                    else "EXACT_AUDITED_SUBSET_NOT_YET_OPERATIONAL")
        return ORIGINAL_PUBLISH_JSON(path, value)

    b.publish_json = publish_dynamic

    def validate_phase_b_complete(run_dir, runtime, tool_sha, phase_a_sha,
                                  preview_sha, authority_sha, expected_rows):
        receipt, digest = b.load_run_receipt(run_dir, "phase-b.json")
        b.validate_bound_receipt(
            receipt, "fleet31-shadowpow-recovery-phase-b-complete",
            runtime, tool_sha, "Phase-B aggregate completion receipt")
        required = {
            "result": "AUTHORIZED_RECOVERY_COMPLETE_EXACT_AUDITED_SUBSET",
            "phase_a_receipt_sha256": phase_a_sha,
            "signed_byte_preview_sha256": preview_sha,
            "phase_b_authority_sha256": authority_sha,
            "wave_plan": [list(wave) for wave in b.WAVE_PLAN],
            "confirmation_or_pow_success_claimed": False,
            "recurrence_contract": RECURRENCE_CONTRACT,
            "audited_blocked_node_set": list(nodes),
            "audited_clear_node_set": list(clear),
        }
        if any(receipt.get(key) != value for key, value in required.items()):
            b.die("dynamic Phase-B aggregate completion is stale or cross-authority")
        expected_results = []
        for node in nodes:
            wave = next(index for index, members in enumerate(b.WAVE_PLAN, 1)
                        if node in members)
            row, row_sha = b.validate_phase_b_final(
                run_dir, node, wave, runtime, tool_sha, phase_a_sha,
                preview_sha, authority_sha, expected_rows[node])
            expected_results.append({
                "node": node, "receipt_sha256": row_sha,
                "resolution_txid": row["signed_evidence"]["identity"]["resolution_txid"],
                "outcome": row["status"],
            })
        if receipt.get("node_results") != expected_results:
            b.die("dynamic Phase-B aggregate node-result binding differs")
        locks = receipt.get("lock_identities")
        if (not isinstance(locks, list) or
                len(locks) != len(runtime.lock_paths) + len(nodes)):
            b.die("dynamic Phase-B aggregate lock identity count differs")
        return receipt, digest

    b.validate_phase_b_complete = validate_phase_b_complete


def load_cycle(run_dir: pathlib.Path) -> tuple[dict[str, Any], str, tuple[int, ...], tuple[int, ...]]:
    audit, audit_sha = b.load_run_receipt(run_dir, "audit.json")
    if (not isinstance(audit, dict) or audit.get("schema") != 1 or
            audit.get("recurrence_contract") != RECURRENCE_CONTRACT or
            audit.get("recurrence_kind") != RECURRENCE_AUDIT_KIND or
            audit.get("kind") != "fleet31-shadowpow-recovery-audit" or
            audit.get("node30_excluded") is not True or
            audit.get("all_regular_node_set") != list(FULL_NODE_SET)):
        b.die("audit is not an exact dynamic recurrence census")
    nodes = selected_nodes(audit.get("audited_blocked_node_set"))
    clear = tuple(audit.get("audited_clear_node_set", []))
    configure_dynamic(nodes, clear)
    return audit, audit_sha, nodes, clear


def full_runtime(path: pathlib.Path, expected_hash: str | None = None):
    current = b.NODE_SET
    try:
        b.NODE_SET = FULL_NODE_SET
        return ORIGINAL_VALIDATE_RUNTIME(path, expected_hash)
    finally:
        b.NODE_SET = current


def validate_clear_refusals(mining: dict[str, Any], preview: dict[str, Any],
                            node_number: int) -> list[dict[str, Any]]:
    """Validate informational refusals for an already-operational PoW node.

    Installed v30.1.4 can report a mempool-live claim as an indeterminate
    ``claim-live`` refusal while its public mining state is coherently
    ``claim_in_flight`` with positive hashrate and no hot blocker.  That is not
    a recovery candidate.  Admit only that exact state (plus the previously
    supported passive families); every authority-bearing or unknown refusal
    remains fatal.
    """
    refused = preview.get("refused")
    if (not isinstance(refused, list) or
            isinstance(preview.get("refused_components"), bool) or
            not isinstance(preview.get("refused_components"), int) or
            preview.get("refused_components") != len(refused)):
        b.die(f"node{node_number} clear preview refusal count changed")

    families: dict[tuple[str, str], int] = {}
    for item in refused:
        if not isinstance(item, dict):
            b.die(f"node{node_number} clear preview refusal shape changed")
        reason_code = item.get("reason_code")
        classification = item.get("classification")
        if (not isinstance(reason_code, str) or
                not isinstance(classification, str) or
                reason_code not in PASSIVE_CLEAR_REFUSAL_CLASSIFICATIONS or
                classification not in
                PASSIVE_CLEAR_REFUSAL_CLASSIFICATIONS[reason_code] or
                item.get("status") != "refused"):
            b.die(f"node{node_number} clear preview refusal family changed")
        if (reason_code in {"claim-live", "claim-not-terminal"} and
                (mining.get("state") != "claim_in_flight" or
                 b.decimal_amount(mining.get("hashrate", 0), "PoW hashrate") <= 0 or
                 mining.get("blocking_quarantined_claims") != 0 or
                 mining.get("indeterminate_quarantined_claims") != 0 or
                 mining.get("claim_recovery_database_outcome_ambiguous") is not False)):
            b.die(f"node{node_number} live refusal is not a coherent claim-in-flight state")
        anchor = item.get("anchor")
        if (not isinstance(anchor, dict) or
                isinstance(anchor.get("vout"), bool) or
                not isinstance(anchor.get("vout"), int) or anchor.get("vout") < 0):
            b.die(f"node{node_number} clear preview refusal anchor changed")
        b.require_hex64(anchor.get("txid"), "clear refusal anchor txid")
        b.require_hex64(item.get("generation_fingerprint"),
                        "clear refusal generation fingerprint")
        b.require_hex64(item.get("component_fingerprint"),
                        "clear refusal component fingerprint")
        claims = item.get("claim_txids")
        if (not isinstance(claims, list) or not claims or
                isinstance(item.get("descendant_claims"), bool) or
                not isinstance(item.get("descendant_claims"), int) or
                item.get("descendant_claims") < 0):
            b.die(f"node{node_number} clear preview refusal claim identity changed")
        for txid in claims:
            b.require_hex64(txid, "clear refusal claim txid")
        b.exact_amount(item.get("fee"), Decimal("0"),
                       f"node{node_number} clear refusal fee")
        if (item.get("persisted") is not False or
                item.get("relay_authorized") is not False or
                item.get("in_mempool") is not False or
                any(key in item for key in (
                    "hex", "resolution_txid", "unsigned_template_hash")) or
                not isinstance(item.get("reason"), str) or not item.get("reason")):
            b.die(f"node{node_number} clear preview refusal carries mutation state")
        key = (reason_code, classification)
        families[key] = families.get(key, 0) + 1
    return [
        {"reason_code": reason_code, "classification": classification,
         "count": count}
        for (reason_code, classification), count in sorted(families.items())
    ]


def clear_node_cut(transport: Any, node: Any) -> dict[str, Any]:
    """Prove one coherent currently-unblocked ordinary-PoW cut."""
    for _ in range(5):
        runtime_before = transport.runtime_snapshot(node)
        exact = b.pinned_node(node, runtime_before)
        before = b.validate_chain(transport.rpc(exact, "getblockchaininfo"), node.node)
        network = transport.rpc(exact, "getnetworkinfo")
        peers = transport.rpc(exact, "getconnectioncount")
        wallet = b.require_normal_unlock(transport, exact)
        staking = transport.rpc(exact, "getstakinginfo")
        mining = transport.rpc(exact, "getpowmininginfo")
        recovery = transport.rpc(exact, "getpowclaimrecoveryinfo", True)
        preview = transport.rpc(exact, "resolveallshadowpowclaims", b.preview_options("ready"))
        after = b.validate_chain(transport.rpc(exact, "getblockchaininfo"), node.node)
        runtime_after = transport.runtime_snapshot(node)
        if runtime_before != runtime_after:
            b.die(f"node{node.node} runtime changed across clear-node census")
        if b.chain_identity(before) != b.chain_identity(after):
            continue
        break
    else:
        b.die(f"node{node.node} could not produce a stable clear-node census")
    if (not isinstance(network, dict) or network.get("version") != b.NETWORK_VERSION or
            network.get("subversion") != b.SUBVERSION or
            not isinstance(peers, int) or peers < 1):
        b.die(f"node{node.node} network/peer preflight changed")
    if (not isinstance(staking, dict) or staking.get("enabled") is not True or
            staking.get("staking") is not True or
            b.decimal_amount(staking.get("weight", 0), "staking weight") <= 0):
        b.die(f"node{node.node} PoS is not coherent during recurrence census")
    if (not isinstance(mining, dict) or mining.get("enabled") is not True or
            mining.get("state") not in ALLOWED_CLEAR_STATES or
            b.decimal_amount(mining.get("hashrate", 0), "PoW hashrate") <= 0 or
            mining.get("blocking_quarantined_claims") != 0 or
            mining.get("indeterminate_quarantined_claims") != 0 or
            mining.get("claim_recovery_database_outcome_ambiguous") is not False):
        b.die(f"node{node.node} is neither exact-clear nor exact-one-claim-quarantined")
    if (not isinstance(recovery, dict) or recovery.get("chain_ready") is not True or
            recovery.get("wallet_tip_matches") is not True or
            recovery.get("database_outcome_ambiguous") is not False or
            recovery.get("active_tip") != after["bestblockhash"] or
            recovery.get("active_height") != after["blocks"]):
        b.die(f"node{node.node} recovery inventory is incoherent at clear cut")
    common = {"action": "preview", "plan_reusable": True, "complete": True,
              "wallet_tip_matches": True, "success": True, "stale_plan": False,
              "durable_state_changed": False, "durable_state_ambiguous": False,
              "actionable_components": 0}
    if (not isinstance(preview, dict) or any(preview.get(k) != v for k, v in common.items()) or
            preview.get("actions") != [] or
            preview.get("active_tip") != after["bestblockhash"] or
            preview.get("active_height") != after["blocks"]):
        b.die(f"node{node.node} clear node has an actionable recovery component")
    b.exact_amount(preview.get("total_fee"), Decimal("0"),
                   f"node{node.node} clear preview fee")
    refusal_families = validate_clear_refusals(mining, preview, node.node)
    return {
        "node": node.node, "classification": "CLEAR_POSITIVE_HASHRATE",
        "runtime": runtime_after,
        "chain": {"height": after["blocks"], "tip": after["bestblockhash"],
                  "chainwork": after["chainwork"]},
        "peers": peers, "wallet": wallet,
        "staking": {"enabled": True, "staking": True, "weight": staking.get("weight")},
        "pow": {"enabled": True, "state": mining.get("state"),
                "hashrate": mining.get("hashrate"),
                "claims_submitted": mining.get("claims_submitted"),
                "blocking_quarantined_claims": 0},
        "preview_plan_id": preview.get("plan_id"),
        "preview_tip": preview.get("active_tip"),
        "preview_height": preview.get("active_height"),
        "preview_refusal_families": refusal_families,
        "mutation_performed": False,
    }


def census(transport: Any, runtime: Any) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    blocked: list[dict[str, Any]] = []
    clear: list[dict[str, Any]] = []
    for node in runtime.nodes:
        # This first read only routes to a fully bracketed, independently
        # validated blocked or clear envelope. It is never authority itself.
        mining = transport.rpc(node, "getpowmininginfo")
        exact_blocked = (
            isinstance(mining, dict) and mining.get("enabled") is True and
            mining.get("state") == "claim_quarantined" and
            b.decimal_amount(mining.get("hashrate", 0), "PoW hashrate") == 0 and
            mining.get("blocking_quarantined_claims") == 1 and
            mining.get("actionable_quarantined_claims") == 1 and
            mining.get("indeterminate_quarantined_claims") == 0 and
            mining.get("claim_recovery_database_outcome_ambiguous") is False)
        if exact_blocked:
            row = b.audit_node(transport, runtime, node)
            row["classification"] = "EXACT_ONE_CLAIM_QUARANTINED"
            blocked.append(row)
        else:
            clear.append(clear_node_cut(transport, node))
    return blocked, clear


def audit_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    b.ensure_secure_dir(run_dir, create=True)
    runtime_path = pathlib.Path(args.runtime_manifest)
    runtime = full_runtime(runtime_path)
    transport = b.Transport(runtime)
    b.publish_bytes(run_dir / "runtime-manifest.json",
                    b.owned_secure_file(runtime_path, "runtime manifest", runtime.sha256))
    blocked_rows, clear_rows = census(transport, runtime)
    nodes = tuple(row["node"] for row in blocked_rows)
    clear = tuple(row["node"] for row in clear_rows)
    if not nodes:
        b.die("no currently blocked regular-PoW nodes; no fee authority is needed")
    configure_dynamic(nodes, clear)
    subset_runtime = filter_runtime(runtime, nodes)
    _, self_sha = tool_identity()
    aggregate = b.PER_NODE_CAP * Decimal(len(nodes))
    receipt = b.base_receipt("fleet31-shadowpow-recovery-audit", subset_runtime, self_sha)
    receipt.update({
        "recurrence_contract": RECURRENCE_CONTRACT,
        "recurrence_kind": RECURRENCE_AUDIT_KIND,
        "result": "READY_FOR_PHASE_A_AUTHORITY",
        "recurrence_result": "READY_FOR_EXACT_DYNAMIC_SUBSET_PHASE_A_AUTHORITY",
        "mutation_performed": False,
        "all_regular_node_set": list(FULL_NODE_SET),
        "audited_blocked_node_set": list(nodes),
        "audited_clear_node_set": list(clear),
        "fleet_census": [*blocked_rows, *clear_rows],
        "nodes": blocked_rows,
        "transport": {"path": str(transport.path), "sha256": b.sha256_file(transport.path)},
        "required_phase_a_authority": {
            "schema": 1, "kind": "fleet31-shadowpow-recovery-phase-a-authority",
            "decision": "authorize", "action": "sign_only",
            "recurrence_contract": RECURRENCE_CONTRACT,
            "node_set": list(nodes), "node30_excluded": True,
            "audit_receipt_sha256": "REPLACE_WITH_AUDIT_SHA256",
            "runtime_manifest_sha256": runtime.sha256, "tool_sha256": self_sha,
            "source_commit": b.SOURCE_COMMIT, "source_tree": b.SOURCE_TREE,
            "per_node_fee_cap_blk": f"{b.PER_NODE_CAP:.8f}",
            "aggregate_fee_cap_blk": f"{aggregate:.8f}",
            "fee_rate_atoms_per_vb": str(b.FEE_RATE_ATOMS_PER_VB),
            "all_regular_node_set": list(FULL_NODE_SET),
            "audited_blocked_node_set": list(nodes),
            "audited_clear_node_set": list(clear),
            "maximum_cycle_fee_blk": f"{aggregate:.8f}",
            "user_order_text": b.USER_ORDER_TEXT,
            "user_order_sha256": b.USER_ORDER_SHA256,
            "allow_fresh_plan_rebind_for_unchanged_component_and_fee": True,
            "acknowledgements": {
                "fee_and_conflict_risk": True,
                "durable_signed_draft_has_no_clean_public_cancellation": True,
                "confirmation_may_permanently_forfeit_revalidating_qqp2_quantum_payout": True,
                "no_relay_or_broadcast_authority_in_phase_a": True,
                "no_generic_transaction_rpc": True,
                "self_cleared_nodes_are_excluded_from_fee_and_mutation_authority": True,
                "new_recurrences_require_a_new_audit_and_authority": True,
            },
        },
    })
    digest = b.publish_json(run_dir / "audit.json", receipt)
    print(json.dumps({"result": receipt["recurrence_result"], "audit_sha256": digest,
                      "blocked_node_set": list(nodes), "clear_node_set": list(clear),
                      "maximum_cycle_fee_blk": f"{aggregate:.8f}",
                      "run_dir": str(run_dir)}, sort_keys=True))


def validate_phase_a_authority(authority: Any, runtime: Any, tool_sha: str,
                               audit_sha: str, audit: dict[str, Any],
                               nodes: tuple[int, ...], clear: tuple[int, ...]) -> None:
    b.validate_phase_a_authority(authority, runtime, tool_sha, audit_sha)
    expected = {
        "recurrence_contract": RECURRENCE_CONTRACT,
        "all_regular_node_set": list(FULL_NODE_SET),
        "audited_blocked_node_set": list(nodes),
        "audited_clear_node_set": list(clear),
        "maximum_cycle_fee_blk": f"{b.AGGREGATE_CAP:.8f}",
        "user_order_text": b.USER_ORDER_TEXT,
        "user_order_sha256": b.USER_ORDER_SHA256,
    }
    if any(authority.get(k) != v for k, v in expected.items()):
        b.die("Phase-A authority does not bind the exact dynamic census/user order")
    acks = authority.get("acknowledgements", {})
    for key in ("self_cleared_nodes_are_excluded_from_fee_and_mutation_authority",
                "new_recurrences_require_a_new_audit_and_authority"):
        b.require_bool(acks.get(key), True, f"Phase-A recurrence acknowledgement {key}")


def phase_a_cut(transport: Any, runtime: Any, node: Any,
                audit_row: dict[str, Any]) -> dict[str, Any]:
    for _ in range(5):
        runtime_before = transport.runtime_snapshot(node)
        if runtime_before != audit_row.get("runtime"):
            b.die(f"node{node.node} runtime changed since the authority-bound audit")
        exact = b.pinned_node(node, runtime_before)
        wallet = b.require_normal_unlock(transport, exact)
        status_hint = "ready" if audit_row.get("status") == "ready" else "reuse_managed"
        chain, preview, action = b.stable_preview(
            transport, exact, status_hint, {"ready", "reuse_managed"})
        b.same_authorized_component(audit_row, action, node.node)
        preflight = b.phase_b_operational_preflight(transport, exact, chain, False)
        runtime_after = transport.runtime_snapshot(node)
        chain_after = b.validate_chain(transport.rpc(exact, "getblockchaininfo"), node.node)
        if runtime_before != runtime_after:
            b.die(f"node{node.node} runtime changed across Phase-A envelope")
        # The verbose recovery inventory is populated against a chain cut of
        # its own.  A normal block can make it lag the otherwise stable
        # preview bracket; phase_b_operational_preflight reports that exact
        # condition as None.  Retry the whole read-only envelope and never
        # publish an intent from a mixed cut.
        if (preflight is None or
                b.chain_identity(chain) != b.chain_identity(chain_after)):
            continue
        return {"runtime": runtime_before, "node": exact, "wallet": wallet,
                "chain": chain, "preview": preview, "action": action,
                "operational_preflight": preflight}
    b.die(f"node{node.node} could not produce a coherent Phase-A envelope")


def finalize_phase_a(run_dir: pathlib.Path, runtime: Any, tool_sha: str,
                     audit_sha: str, authority_sha: str, lock_ids: list[dict[str, Any]],
                     nodes: tuple[int, ...], clear: tuple[int, ...]) -> str:
    rows = [b.load_run_receipt(run_dir, f"phase-a-node{node:02d}.json")[0]
            for node in nodes]
    if any(row.get("status") not in {"SIGNED_AND_PERSISTED", "ALREADY_SIGNED_NONRELAY"}
           for row in rows):
        b.die("dynamic Phase-A has an inconclusive selected-node result")
    if sum(b.decimal_amount(row.get("fee_blk"), "Phase-A fee") for row in rows) != b.AGGREGATE_CAP:
        b.die("dynamic Phase-A fee sum differs from the exact selected-node cap")
    receipt = b.base_receipt("fleet31-shadowpow-recovery-phase-a-complete", runtime, tool_sha)
    receipt.update({
        "recurrence_contract": RECURRENCE_CONTRACT,
        "result": RECURRENCE_PHASE_A_RESULT,
        "audit_receipt_sha256": audit_sha,
        "phase_a_authority_sha256": authority_sha,
        "mutation_performed": any(row.get("mutation_performed") is True for row in rows),
        "relay_or_broadcast_authorized": False,
        "all_regular_node_set": list(FULL_NODE_SET),
        "audited_blocked_node_set": list(nodes),
        "audited_clear_node_set": list(clear),
        "lock_identities": lock_ids, "nodes": rows,
    })
    return b.publish_json(run_dir / "phase-a.json", receipt)


def phase_a_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    b.ensure_secure_dir(run_dir)
    audit, audit_sha, nodes, clear = load_cycle(run_dir)
    runtime = b.load_runtime_from_run(run_dir)
    _, self_sha = tool_identity()
    authority, authority_sha = b.parse_secure_json(
        pathlib.Path(args.authority), "Phase-A authority", args.authority_sha256)
    validate_phase_a_authority(authority, runtime, self_sha, audit_sha,
                               audit, nodes, clear)
    transport = b.Transport(runtime)
    audit_rows = {row["node"]: row for row in audit["nodes"]}
    if set(audit_rows) != set(nodes):
        b.die("audit selected rows differ from the exact dynamic subset")
    # Locks are acquired before the final all-fleet set reproof. A newly
    # blocked former-clear node stops this cycle before the first sign_only.
    with b.mutation_locks(runtime) as lock_ids:
        full = full_runtime(run_dir / "runtime-manifest.json", runtime.sha256)
        check_transport = b.Transport(full)
        current_blocked, current_clear = census(check_transport, full)
        if ([row["node"] for row in current_blocked] != list(nodes) or
                [row["node"] for row in current_clear] != list(clear)):
            b.die("dynamic blocked/clear subset changed after audit; require a new run and authority")
        current_rows = {row["node"]: row for row in current_blocked}
        for node_id in nodes:
            b.same_authorized_component(audit_rows[node_id],
                                        {**current_rows[node_id]["component"],
                                         "status": current_rows[node_id]["status"]}, node_id)
            if current_rows[node_id]["runtime"] != audit_rows[node_id]["runtime"]:
                b.die(f"node{node_id} runtime changed between audit and Phase A")
        for node in runtime.nodes:
            result_path = run_dir / f"phase-a-node{node.node:02d}.json"
            if result_path.exists():
                b.load_run_receipt(run_dir, result_path.name)
                continue
            intent_path = run_dir / f"phase-a-intent-node{node.node:02d}.json"
            if intent_path.exists():
                b.die(f"node{node.node} has an unmatched Phase-A intent; run reconcile-a")
            cut = phase_a_cut(transport, runtime, node, audit_rows[node.node])
            fresh, action, exact = cut["preview"], cut["action"], cut["node"]
            intent = {
                "schema": 1, "contract": b.CONTRACT,
                "kind": "fleet31-phase-a-node-intent", "node": node.node,
                "action": "sign_only", "audit_sha256": audit_sha,
                "authority_sha256": authority_sha, "tool_sha256": self_sha,
                "runtime_manifest_sha256": runtime.sha256,
                "runtime": cut["runtime"], "wallet": cut["wallet"],
                "operational_preflight": cut["operational_preflight"],
                "plan_id": fresh["plan_id"], "active_tip": fresh["active_tip"],
                "active_height": fresh["active_height"],
                "wallet_generation": fresh["wallet_generation"],
                "audit_component_fingerprint": audit_rows[node.node]["component"]["component_fingerprint"],
                "fresh_component_fingerprint": action["component_fingerprint"],
                "component": b.component_identity(action), "created_at": b.utc_now(),
            }
            intent_sha = b.publish_json(intent_path, intent)
            if action["status"] == "reuse_managed":
                signed = b.signed_transaction(transport, exact, action)
                tx = transport.rpc(exact, "gettransaction", signed["resolution_txid"], False, True)
                if tx.get("qq_shadow_pow_resolution_relay_authorized") != "0":
                    b.die(f"node{node.node} existing signed draft already has relay authority")
                row = {
                    "schema": 1, "contract": b.CONTRACT,
                    "kind": "fleet31-phase-a-node-result", "node": node.node,
                    "status": "ALREADY_SIGNED_NONRELAY", "intent_sha256": intent_sha,
                    "fresh_plan": {"plan_id": fresh["plan_id"], "tip": fresh["active_tip"],
                                   "height": fresh["active_height"],
                                   "wallet_generation": fresh["wallet_generation"]},
                    "audit_component_fingerprint": audit_rows[node.node]["component"]["component_fingerprint"],
                    "fresh_component_fingerprint": action["component_fingerprint"],
                    "fee_blk": action["fee"], "component": b.component_identity(action),
                    "signed_transaction": signed, "runtime": cut["runtime"],
                    "relay_authority_granted": 0, "broadcast": 0,
                    "mutation_performed": False, "durable_state_ambiguous": False,
                    "created_at": b.utc_now(),
                }
                b.publish_json(result_path, row)
                continue
            options = {
                "action": "sign_only", "expected_plan_id": fresh["plan_id"],
                "acknowledge_fee_and_conflict_risk": True,
                "fee_rate": str(b.FEE_RATE_ATOMS_PER_VB),
                "max_fee_per_resolution": f"{b.PER_NODE_CAP:.8f}",
                "max_total_fee": f"{b.PER_NODE_CAP:.8f}",
            }
            try:
                execution = transport.rpc(exact, "resolveallshadowpowclaims", options)
            except b.RpcError:
                b.die(f"node{node.node} Phase-A result is unknown after durable intent; run reconcile-a")
            if isinstance(execution, dict) and execution.get("durable_state_ambiguous") is True:
                ambiguous = {
                    "schema": 1, "contract": b.CONTRACT,
                    "kind": "fleet31-phase-a-node-result", "node": node.node,
                    "status": "DURABLE_STATE_AMBIGUOUS", "intent_sha256": intent_sha,
                    "mutation_performed": "unknown", "durable_state_ambiguous": True,
                    "execution_sha256": b.sha256_bytes(b.canonical_json(execution)),
                    "created_at": b.utc_now(),
                }
                b.publish_json(result_path, ambiguous)
                b.die(f"node{node.node} reported ambiguous durable state")
            row = b.phase_a_result_from_execution(
                exact, audit_rows[node.node], fresh, action, execution,
                transport, cut["runtime"], intent_sha)
            b.publish_json(result_path, row)
        digest = finalize_phase_a(run_dir, runtime, self_sha, audit_sha,
                                  authority_sha, lock_ids, nodes, clear)
    print(json.dumps({"result": RECURRENCE_PHASE_A_RESULT,
                      "phase_a_sha256": digest, "selected_node_set": list(nodes),
                      "relay_or_broadcast_authorized": False}, sort_keys=True))


def reconcile_a_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    b.ensure_secure_dir(run_dir)
    audit, audit_sha, nodes, clear = load_cycle(run_dir)
    runtime = b.load_runtime_from_run(run_dir)
    _, self_sha = tool_identity()
    authority, authority_sha = b.parse_secure_json(
        pathlib.Path(args.authority), "Phase-A authority", args.authority_sha256)
    validate_phase_a_authority(authority, runtime, self_sha, audit_sha,
                               audit, nodes, clear)
    audit_rows = {row["node"]: row for row in audit["nodes"]}
    transport = b.Transport(runtime)
    observations: list[dict[str, Any]] = []
    all_signed = True
    with b.mutation_locks(runtime) as lock_ids:
        for node in runtime.nodes:
            result_path = run_dir / f"phase-a-node{node.node:02d}.json"
            if result_path.exists():
                row, _ = b.load_run_receipt(run_dir, result_path.name)
                observations.append({"node": node.node, "status": row.get("status")})
                all_signed &= row.get("status") in {"SIGNED_AND_PERSISTED", "ALREADY_SIGNED_NONRELAY"}
                continue
            intent_path = run_dir / f"phase-a-intent-node{node.node:02d}.json"
            if not intent_path.exists():
                observations.append({"node": node.node, "status": "NO_PHASE_A_INTENT"})
                all_signed = False
                continue
            intent, intent_sha = b.load_run_receipt(run_dir, intent_path.name)
            b.validate_phase_a_intent_record(intent, intent_sha, node.node,
                                             audit_sha, authority_sha, runtime,
                                             self_sha, audit_rows[node.node])
            runtime_before = transport.runtime_snapshot(node)
            if runtime_before != intent.get("runtime"):
                b.die(f"node{node.node} runtime differs from unmatched Phase-A intent")
            exact = b.pinned_node(node, runtime_before)
            chain, fresh, action = b.stable_preview(
                transport, exact, "reuse_managed", {"ready", "reuse_managed"})
            b.same_authorized_component(audit_rows[node.node], action, node.node)
            if action["status"] != "reuse_managed":
                observations.append({"node": node.node, "status": "NO_MUTATION_OBSERVED"})
                all_signed = False
                continue
            b.same_reconciled_phase_a_component(intent["component"],
                                                b.component_identity(action), node.node)
            signed = b.signed_transaction(transport, exact, action)
            tx = transport.rpc(exact, "gettransaction", signed["resolution_txid"], False, True)
            if tx.get("qq_shadow_pow_resolution_relay_authorized") != "0":
                b.die(f"node{node.node} unmatched Phase-A intent now has relay authority")
            reconciliation_plan = {
                "plan_id": fresh["plan_id"], "tip": fresh["active_tip"],
                "height": fresh["active_height"],
                "wallet_generation": fresh["wallet_generation"],
            }
            row = {
                "schema": 1, "contract": b.CONTRACT,
                "kind": "fleet31-phase-a-node-result", "node": node.node,
                "status": "SIGNED_AND_PERSISTED", "intent_sha256": intent_sha,
                "reconciled_after_missing_rpc_result": True,
                "attribution": "exact_persisted_bytes_observed_after_durable_intent",
                "acknowledged_plan_claimed": False,
                "original_intent_plan": {"plan_id": intent["plan_id"],
                                         "tip": intent["active_tip"],
                                         "height": intent["active_height"],
                                         "wallet_generation": intent["wallet_generation"]},
                "reconciliation_plan": reconciliation_plan,
                "fresh_plan": reconciliation_plan,
                "intent_component": intent["component"],
                "audit_component_fingerprint": audit_rows[node.node]["component"]["component_fingerprint"],
                "fresh_component_fingerprint": action["component_fingerprint"],
                "fee_blk": action["fee"], "component": b.component_identity(action),
                "signed_transaction": signed, "runtime": runtime_before,
                "relay_authority_granted": 0, "broadcast": 0,
                "mutation_performed": "unknown", "durable_state_ambiguous": False,
                "created_at": b.utc_now(),
            }
            b.publish_json(result_path, row)
            observations.append({"node": node.node, "status": row["status"]})
        reconcile = b.base_receipt(
            "fleet31-shadowpow-recovery-phase-a-reconcile", runtime, self_sha)
        reconcile.update({
            "recurrence_contract": RECURRENCE_CONTRACT,
            "audit_receipt_sha256": audit_sha,
            "phase_a_authority_sha256": authority_sha,
            "result": "ALL_SIGNED" if all_signed else "PARTIAL_REQUIRES_NEW_AUDIT_AND_AUTHORITY",
            "mutation_performed": False,
            "audited_blocked_node_set": list(nodes),
            "audited_clear_node_set": list(clear),
            "observations": observations,
        })
        reconcile_sha = b.publish_json(run_dir / "phase-a-reconcile.json", reconcile)
        phase_a_sha = None
        if all_signed and not (run_dir / "phase-a.json").exists():
            phase_a_sha = finalize_phase_a(run_dir, runtime, self_sha, audit_sha,
                                           authority_sha, lock_ids, nodes, clear)
    print(json.dumps({"result": reconcile["result"],
                      "reconcile_sha256": reconcile_sha,
                      "phase_a_sha256": phase_a_sha}, sort_keys=True))


def phase_b_preview_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    b.ensure_secure_dir(run_dir)
    _, _, nodes, clear = load_cycle(run_dir)
    runtime = b.load_runtime_from_run(run_dir)
    _, self_sha = tool_identity()
    phase_a, phase_a_sha = b.load_run_receipt(run_dir, "phase-a.json")
    phase_a_rows = b.validate_phase_a_receipt_chain(
        run_dir, phase_a, phase_a_sha, runtime, self_sha)
    transport = b.Transport(runtime)
    rows: list[dict[str, Any]] = []
    for node in runtime.nodes:
        cut = b.phase_b_envelope(transport, runtime, node,
                                 phase_a_row=phase_a_rows[node.node],
                                 accept_deferred=True, wait_attempts=5)
        preview, action = cut["preview"], cut["action"]
        if action is not None:
            b.phase_a_signed_match(phase_a_rows[node.node], action,
                                   cut["signed_evidence"], node.node)
        rows.append({
            "node": node.node, "runtime": cut["runtime"],
            "runtime_transition": cut["runtime_transition"], "wallet": cut["wallet"],
            "plan_id": preview["plan_id"], "active_tip": preview["active_tip"],
            "active_height": preview["active_height"],
            "wallet_generation": preview["wallet_generation"],
            "eligibility": cut["eligibility"],
            "component": b.component_identity(cut["authorized_component"]),
            "signed_evidence": cut["signed_evidence"],
            "operational_preflight": cut["operational_preflight"],
            "terminal_observation": cut.get("terminal_observation"),
        })
    terminal = [row["node"] for row in rows
                if row["eligibility"] == "ALREADY_RESOLVED_ON_ACTIVE_CHAIN"]
    recovery = [node for node in nodes if node not in terminal]
    maximum = b.PER_NODE_CAP * Decimal(len(recovery))
    receipt = b.base_receipt(
        "fleet31-shadowpow-recovery-phase-b-signed-byte-preview", runtime, self_sha)
    receipt.update({
        "recurrence_contract": RECURRENCE_CONTRACT,
        "phase_a_receipt_sha256": phase_a_sha, "mutation_performed": False,
        "result": "READY_FOR_SEPARATE_PHASE_B_AUTHORITY", "nodes": rows,
        "wave_plan": [list(wave) for wave in b.WAVE_PLAN],
        "deferred_node": b.DEFERRED_NODE,
        "deferred_semantics": "final-wave wait only; no mutation until exact reuse_managed/resolution_pending returns",
        "terminal_node_set": terminal, "recovery_relay_node_set": recovery,
        "maximum_recovery_fee_blk": f"{maximum:.8f}",
        "all_regular_node_set": list(FULL_NODE_SET),
        "audited_blocked_node_set": list(nodes),
        "audited_clear_node_set": list(clear),
        "required_phase_b_authority": {
            "schema": 1, "kind": "fleet31-shadowpow-recovery-phase-b-authority",
            "decision": "authorize", "action": "commit_and_broadcast",
            "recurrence_contract": RECURRENCE_CONTRACT,
            "node_set": list(nodes), "node30_excluded": True,
            "phase_a_receipt_sha256": phase_a_sha,
            "signed_byte_preview_sha256": "REPLACE_WITH_PHASE_B_PREVIEW_SHA256",
            "runtime_manifest_sha256": runtime.sha256, "tool_sha256": self_sha,
            "source_commit": b.SOURCE_COMMIT, "source_tree": b.SOURCE_TREE,
            "per_node_fee_cap_blk": f"{b.PER_NODE_CAP:.8f}",
            "aggregate_fee_cap_blk": f"{b.AGGREGATE_CAP:.8f}",
            "user_order_text": b.USER_ORDER_TEXT,
            "user_order_sha256": b.USER_ORDER_SHA256,
            "wave_plan": [list(wave) for wave in b.WAVE_PLAN],
            "deferred_node": b.DEFERRED_NODE,
            "deferred_semantics": "final-wave wait only; no mutation until exact reuse_managed/resolution_pending returns",
            "terminal_node_set": terminal, "recovery_relay_node_set": recovery,
            "maximum_recovery_fee_blk": f"{maximum:.8f}",
            "all_regular_node_set": list(FULL_NODE_SET),
            "audited_blocked_node_set": list(nodes),
            "audited_clear_node_set": list(clear),
            "allow_fresh_plan_rebind_for_exact_signed_bytes": True,
            "acknowledgements": {
                "fee_and_conflict_risk": True,
                "independent_signed_fee_and_script_proof_reviewed": True,
                "broadcast_is_irreversible": True,
                "durable_exact_byte_relay_authority_survives_restart_or_rpc_response_loss": True,
                "confirmation_may_permanently_forfeit_revalidating_qqp2_quantum_payout": True,
                "missing_rpc_result_cannot_reconstruct_original_acknowledged_plan_on_v30_1_4": True,
                "no_generic_transaction_rpc": True,
            },
        },
    })
    digest = b.publish_json(run_dir / "phase-b-preview.json", receipt)
    print(json.dumps({"result": receipt["result"],
                      "phase_b_preview_sha256": digest,
                      "recovery_relay_node_set": recovery,
                      "maximum_recovery_fee_blk": f"{maximum:.8f}"}, sort_keys=True))


def delegate(command: str, args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    b.ensure_secure_dir(run_dir)
    load_cycle(run_dir)
    mapping = {
        "phase-b": b.phase_b_command,
        "reconcile-b": b.reconcile_b_command,
        "monitor": b.monitor_command,
    }
    mapping[command](args)


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    audit = sub.add_parser("audit")
    audit.add_argument("--runtime-manifest", required=True)
    audit.add_argument("--run-dir", required=True)
    audit.set_defaults(func=audit_command)
    for name, func in (("phase-a", phase_a_command),
                       ("reconcile-a", reconcile_a_command)):
        item = sub.add_parser(name)
        item.add_argument("--run-dir", required=True)
        item.add_argument("--authority", required=True)
        item.add_argument("--authority-sha256", required=True)
        item.set_defaults(func=func)
    preview = sub.add_parser("phase-b-preview")
    preview.add_argument("--run-dir", required=True)
    preview.set_defaults(func=phase_b_preview_command)
    for name in ("phase-b", "reconcile-b"):
        item = sub.add_parser(name)
        item.add_argument("--run-dir", required=True)
        item.add_argument("--authority", required=True)
        item.add_argument("--authority-sha256", required=True)
        if name == "phase-b":
            item.add_argument("--wave", type=int, required=True)
            item.add_argument("--wait-attempts", type=int, default=12)
            item.add_argument("--wait-interval", type=int, default=5)
        item.set_defaults(func=lambda a, n=name: delegate(n, a))
    monitor = sub.add_parser("monitor")
    monitor.add_argument("--run-dir", required=True)
    monitor.add_argument("--samples", type=int, default=1)
    monitor.add_argument("--interval", type=int, default=5)
    monitor.set_defaults(func=lambda a: delegate("monitor", a))
    return p


def main(argv: Sequence[str] | None = None) -> int:
    os.umask(0o077)
    for name in ("PYTHONPATH", "PYTHONHOME", "BASH_ENV", "ENV", "CDPATH"):
        os.environ.pop(name, None)
    args = parser().parse_args(argv)
    try:
        args.func(args)
    except (b.GateError, RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
