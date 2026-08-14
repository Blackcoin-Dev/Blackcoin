#!/usr/bin/python3
"""Offline stateful Docker/CLI fixture for fleet31_recovery.py."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import sys


FIXTURE = pathlib.Path(os.environ["FLEET31_FIXTURE"])
SCENARIO = os.environ.get("FLEET31_SCENARIO", "happy")
TIP = "f" * 64
CHAINWORK = "e" * 64
HEIGHT = 5_991_550
CLI_SHA = "a" * 64
DAEMON_SHA = "b" * 64
IMAGE_REF = "qqblackcoin/blackcoin-v4-gui@sha256:" + "c" * 64
IMAGE_ID = "sha256:" + "d" * 64


def h(label: str, node: int) -> str:
    return hashlib.sha256(f"{label}:{node}".encode()).hexdigest()


def node_from_container(container: str) -> int:
    if container == "blackcoin-v4-gui":
        return 1
    for candidate in [*range(1, 30), 31, 32]:
        if container in {h("container", candidate), h("container-restarted", candidate)}:
            return candidate
    return int(container.rsplit("-", 1)[1])


def state_path(node: int) -> pathlib.Path:
    return FIXTURE / f"node{node:02d}.json"


def load_state(node: int) -> dict:
    path = state_path(node)
    if path.exists():
        return json.loads(path.read_text())
    return {"status": "ready", "claims_submitted": 4, "confirmed": False}


def save_state(node: int, state: dict) -> None:
    path = state_path(node)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, sort_keys=True) + "\n")
    tmp.replace(path)


def current_chain(state: dict) -> tuple[str, int, str]:
    return (state.get("current_tip", TIP), state.get("current_height", HEIGHT),
            state.get("current_chainwork", CHAINWORK))


def component(node: int, state: dict | None = None) -> dict:
    state = load_state(node) if state is None else state
    tip, _height, _chainwork = current_chain(state)
    drift = state.get("stable_component_drift")
    fee = "0.00019200" if (SCENARIO == "wrong-fee" and node == 5) or drift == "fee" else "0.00019100"
    anchor_label = "anchor-drift" if drift == "anchor" else "anchor"
    generation_label = "generation-drift" if drift == "generation" else "generation"
    claim_label = "claim-drift" if drift == "claim" else "claim"
    input_amount = f"{node + 1}.00000000"
    output_amount = f"{DecimalLike(node + 1) - DecimalLike('0.00019100'):.8f}"
    if drift == "output":
        output_amount = f"{DecimalLike(output_amount) - DecimalLike('0.00000001'):.8f}"
    return {
        "anchor": {"txid": h(anchor_label, node), "vout": 0},
        "generation_fingerprint": h(generation_label, node),
        "component_fingerprint": h("component-" + tip, node),
        "classification": "current_branch_ineligible",
        "claim_txids": [h(claim_label, node)], "descendant_claims": 0,
        "fee": fee, "vsize": 191,
        "input_amount": input_amount, "output_amount": output_amount,
        "frontier_may_advance": True,
        "conflicts_with_revalidating_unbound_proof": True,
        "reason_code": "unbound-proof-may-revalidate",
        "reason": "fixture retained QQP2 may revalidate",
    }


class DecimalLike(float):
    def __new__(cls, value):
        return super().__new__(cls, float(value))


def action(node: int, status: str, state: dict | None = None) -> dict:
    result = component(node, state)
    if status == "ready":
        result.update({"status": "ready", "persisted": False, "relay_authorized": False,
                       "in_mempool": False, "unsigned_template_hash": h("unsigned", node)})
    else:
        result["classification"] = "resolution_pending"
        result.update({"status": "reuse_managed", "persisted": True,
                       "relay_authorized": status == "relayed" or bool(state and state.get("relay_authorized")),
                       "in_mempool": status == "relayed",
                       "resolution_txid": h("resolution", node)})
    return result


def preview(node: int, options: dict, status: str) -> dict:
    state = load_state(node)
    tip, height, chainwork = current_chain(state)
    if state.get("confirmed"):
        terminal = component(node, state)
        terminal.update({"classification": "resolved_on_active_chain", "status": "refused",
                         "reason_code": "anchor-spent", "persisted": False,
                         "relay_authorized": False, "in_mempool": False})
        return {
            "action": "preview", "plan_id": h("plan-terminal-" + tip, node), "plan_reusable": True,
            "active_tip": tip, "active_height": height, "wallet_generation": 1000 + node,
            "wallet_tip_matches": True, "complete": True, "one_call_finality": False,
            "frontier_may_advance": True, "contains_revalidating_unbound_proof": True,
            "max_fee_per_resolution": "0.00019100", "aggregate_batch_fee_cap": "0.00019100",
            "total_fee": "0.00000000", "actionable_components": 0, "refused_components": 1,
            "actions": [], "refused": [terminal],
            "success": True, "stale_plan": False, "signed_and_persisted": 0,
            "durable_state_changed": False, "durable_state_ambiguous": False,
            "relay_authority_granted": 0, "broadcast": 0, "already_in_mempool": 0,
            "relay_deferred": 0, "error": "",
        }
    if SCENARIO == "ambiguous" and node == 7:
        return {"action": "preview", "plan_reusable": False, "actions": [], "refused": [],
                "success": False, "stale_plan": False, "signed_and_persisted": 0,
                "durable_state_changed": False, "durable_state_ambiguous": True,
                "relay_authority_granted": 0, "broadcast": 0, "already_in_mempool": 0,
                "relay_deferred": 0, "error": "fixture ambiguous"}
    if (node == 27 and status != "ready" and
            SCENARIO in {"transient-node27", "transient-once-node27"} and
            (SCENARIO == "transient-node27" or state.get("transient_previews", 0) == 0)):
        state["transient_previews"] = state.get("transient_previews", 0) + 1
        save_state(node, state)
        live = action(node, status, state)
        live.update({"classification": "live", "status": "refused",
                     "reason_code": "claim-not-terminal", "persisted": False,
                     "relay_authorized": False, "in_mempool": False})
        return {
            "action": "preview", "plan_id": h("plan-live-" + tip, node), "plan_reusable": True,
            "active_tip": tip, "active_height": height, "wallet_generation": 1000 + node,
            "wallet_tip_matches": True, "complete": True, "one_call_finality": False,
            "frontier_may_advance": True, "contains_revalidating_unbound_proof": True,
            "max_fee_per_resolution": "0.00019100", "aggregate_batch_fee_cap": "0.00019100",
            "total_fee": "0.00000000", "actionable_components": 0, "refused_components": 50,
            "actions": [], "refused": [{"reason_code": "anchor-spent"} for _ in range(49)] + [live],
            "success": True, "stale_plan": False, "signed_and_persisted": 0,
            "durable_state_changed": False, "durable_state_ambiguous": False,
            "relay_authority_granted": 0, "broadcast": 0, "already_in_mempool": 0,
            "relay_deferred": 0, "error": "",
        }
    current = action(node, status, state)
    if status != "ready" and "fee_rate" in options:
        refused = dict(current)
        refused.update({"status": "refused", "reason_code": "fee-rate-cannot-modify-signed"})
        actions = []
        refusals = [refused]
        total = "0.00000000"
    else:
        actions = [current]
        refusals = [{"reason_code": "anchor-spent"} for _ in range(49)]
        total = "0.00019100"
    result = {
        "action": "preview", "plan_id": h("plan-" + status + "-" + tip, node), "plan_reusable": True,
        "active_tip": tip, "active_height": height, "wallet_generation": 1000 + node,
        "wallet_tip_matches": True, "complete": True, "one_call_finality": False,
        "frontier_may_advance": True, "contains_revalidating_unbound_proof": True,
        "max_fee_per_resolution": "0.00019100", "aggregate_batch_fee_cap": "0.00019100",
        "total_fee": total, "actionable_components": len(actions), "refused_components": len(refusals),
        "actions": actions, "refused": refusals, "success": True, "stale_plan": False,
        "signed_and_persisted": 0, "durable_state_changed": False,
        "durable_state_ambiguous": False, "relay_authority_granted": 0,
        "broadcast": 0, "already_in_mempool": 0, "relay_deferred": 0, "error": "",
    }
    if "fee_rate" in options:
        result["fee_rate_atoms_per_k"] = 100000
    return result


def decoded_tx(node: int) -> dict:
    amount = component(node)["output_amount"]
    return {
        "txid": h("resolution", node), "version": 2, "vsize": 191,
        "vin": [{"txid": h("anchor", node), "vout": 0, "sequence": 4294967295}],
        "vout": [{"n": 0, "value": amount, "scriptPubKey": {"hex": "76a914" + h("script", node)[:40] + "88ac"}}],
    }


def mutation(node: int, options: dict, state: dict) -> dict:
    action_name = options.get("action")
    tip, height, chainwork = current_chain(state)
    expected = h("plan-" + state["status"] + "-" + tip, node)
    if options.get("expected_plan_id") != expected:
        print("stale fixture plan", file=sys.stderr)
        raise SystemExit(1)
    if SCENARIO == "lost-sign-result" and node == 9 and action_name == "sign_only":
        state["status"] = "signed"
        save_state(node, state)
        print("fixture lost response after commit", file=sys.stderr)
        raise SystemExit(1)
    if SCENARIO == "lost-relay-result" and node == 16 and action_name == "commit_and_broadcast":
        state["status"] = "relayed"
        save_state(node, state)
        print("fixture lost response after durable relay grant", file=sys.stderr)
        raise SystemExit(1)
    if SCENARIO == "lost-before-relay-mutation" and node == 16 and action_name == "commit_and_broadcast":
        print("fixture lost response before durable mutation", file=sys.stderr)
        raise SystemExit(1)
    if SCENARIO == "lost-original-claim-winner" and node == 16 and action_name == "commit_and_broadcast":
        state["original_confirmed"] = True
        state["confirmed"] = True
        save_state(node, state)
        print("fixture original claim confirmed while RPC result was lost", file=sys.stderr)
        raise SystemExit(1)
    if SCENARIO in {"ambiguous-relay", "ambiguous-relay-node16"} and \
            node == (16 if SCENARIO.endswith("node16") else 27) and \
            action_name == "commit_and_broadcast":
        result_action = action(node, state["status"])
        return {"action": action_name, "actions": [result_action], "success": False,
                "stale_plan": False, "durable_state_changed": False,
                "durable_state_ambiguous": True, "relay_authority_granted": 0,
                "broadcast": 0, "already_in_mempool": 0, "relay_deferred": 0,
                "error": "fixture ambiguous database outcome"}
    if action_name == "sign_only":
        state["status"] = "signed"
        save_state(node, state)
        status = "signed_and_persisted"
        relay_grant = 0
        broadcast = 0
        already = 0
    elif action_name == "commit_and_broadcast":
        if SCENARIO == "post-persist-stale" and node == 16:
            state["relay_authorized"] = True
            save_state(node, state)
            result_action = action(node, state["status"], state)
            result_action["status"] = "reuse_managed"
            result_action["hex"] = ("02" + h("raw", node)) * 3
            return {
                "action": action_name, "acknowledged_plan_id": expected,
                "acknowledged_active_tip": tip, "acknowledged_active_height": height,
                "acknowledged_wallet_generation": 1000 + node,
                "acknowledged_total_fee": "0.00019100", "plan_consumed": True,
                "plan_reusable": False, "contains_revalidating_unbound_proof": True,
                "actions": [result_action], "refused": [{"reason_code": "anchor-spent"} for _ in range(49)],
                "current_plan": preview(node, {}, state["status"]), "success": False,
                "stale_plan": True, "signed_and_persisted": 0,
                "durable_state_changed": True, "durable_state_ambiguous": False,
                "relay_authority_granted": 1, "broadcast": 0, "already_in_mempool": 0,
                "relay_deferred": 0, "relay_complete": False,
                "error": "active tip changed after persistence; signed bytes remain safely stored",
            }
        state["status"] = "relayed"
        if SCENARIO == "immediate-confirmation" and node == 16:
            state["confirmed"] = True
        save_state(node, state)
        status = "broadcast"
        relay_grant = 1
        broadcast = 1
        already = 0
    else:
        raise SystemExit(2)
    result_action = action(node, state["status"], state)
    if action_name == "sign_only":
        result_action["classification"] = "current_branch_ineligible"
    if SCENARIO == "result-component-mismatch" and node == 1 and action_name == "sign_only":
        result_action["component_fingerprint"] = h("result-component-mismatch", node)
    result_action["status"] = status
    raw = ("02" + h("raw", node)) * 3
    if SCENARIO == "wrong-returned-hex" and node == 16 and action_name == "commit_and_broadcast":
        raw = ("03" + h("wrong-raw", node)) * 3
    result_action["hex"] = raw
    return {
        "action": action_name, "acknowledged_plan_id": expected,
        "acknowledged_active_tip": tip, "acknowledged_active_height": height,
        "acknowledged_wallet_generation": 1000 + node,
        "acknowledged_total_fee": "0.00019100", "plan_consumed": True,
        "plan_reusable": False, "contains_revalidating_unbound_proof": True,
        "actions": [result_action], "refused": [{"reason_code": "anchor-spent"} for _ in range(49)],
        "current_plan": preview(node, {}, state["status"]), "success": True,
        "stale_plan": False, "signed_and_persisted": 1 if action_name == "sign_only" else 0,
        "durable_state_changed": True, "durable_state_ambiguous": False,
        "relay_authority_granted": relay_grant, "broadcast": broadcast,
        "already_in_mempool": already, "relay_deferred": 0, "error": "",
        "relay_complete": action_name == "commit_and_broadcast",
    }


def rpc(node: int, method: str, params: list[str]) -> object:
    state = load_state(node)
    if method == "getblockchaininfo":
        if node == 1 and SCENARIO in {"tip-advance-once", "tip-churn"}:
            calls = state.get("chain_calls", 0) + 1
            state["chain_calls"] = calls
            generation = (0 if calls <= 2 else 1) if SCENARIO == "tip-advance-once" else calls // 3
            state["current_tip"] = h(f"tip-{generation}", node)
            state["current_height"] = HEIGHT + generation
            state["current_chainwork"] = h(f"chainwork-{generation}", node)
            save_state(node, state)
        tip, height, chainwork = current_chain(state)
        return {"chain": "main", "blocks": height, "headers": height, "bestblockhash": tip,
                "chainwork": chainwork, "initialblockdownload": False, "pruned": False, "warnings": ""}
    if method == "getnetworkinfo":
        return {"version": 300104, "subversion": "/Blackcoin:30.1.4/"}
    if method == "getconnectioncount":
        return 8
    if method == "listwallets":
        return ["other"] if state.get("runtime_drift") == "wallet" else [""]
    if method == "getwalletinfo":
        walletname = "other" if state.get("runtime_drift") == "wallet" else ""
        return {"walletname": walletname, "format": "sqlite", "private_keys_enabled": True,
                "external_signer": False, "scanning": False, "unlocked_staking_only": False,
                "unlocked_until": 2_000_000_000, "txcount": 50 + (state["status"] != "ready")}
    if method == "getstakinginfo":
        return {"enabled": True, "staking": True, "weight": 1000 + node}
    if method == "getpowmininginfo":
        operational = state.get("confirmed", False)
        pow_state = state.get("pow_state", "hashing" if operational else "claim_quarantined")
        return {"enabled": True, "state": pow_state,
                "hashrate": 42.5 if operational else 0, "claims_submitted": state["claims_submitted"],
                "threads": 1, "cpu_percent": 1, "payout_address": "blk1s" + h("payout", node),
                "blocking_quarantined_claims": 0 if operational else 1,
                "actionable_quarantined_claims": 0 if operational else 1,
                "indeterminate_quarantined_claims": 0,
                "claim_recovery_database_outcome_ambiguous": False}
    if method == "getpowclaimrecoveryinfo":
        tip, height, chainwork = current_chain(state)
        detail = component(node)
        detail.update({"anchor": {**detail["anchor"], "amount": detail["input_amount"],
                                   "scriptPubKey": "76a914" + h("script", node)[:40] + "88ac"},
                       "anchor_authenticated": True, "anchor_unspent": not state.get("confirmed", False),
                       "has_revalidating_unbound_proof": True})
        return {"chain_ready": True, "wallet_tip_matches": True, "database_outcome_ambiguous": False,
                "active_tip": tip, "active_height": height,
                "blocking_quarantined_claims": state.get(
                    "recovery_inventory_blockers",
                    0 if state.get("confirmed", False) else 1),
                "component_details": [detail]}
    if method == "resolveallshadowpowclaims":
        options = json.loads(params[0]) if params else {}
        if options.get("action", "preview") == "preview":
            return preview(node, options, state["status"])
        return mutation(node, options, state)
    if method == "gettransaction":
        txid = params[0]
        if state.get("original_confirmed"):
            confirmations = 3 if txid == h("claim", node) else -3
        elif state.get("confirmed"):
            confirmations = 3 if txid == h("resolution", node) else -3
        else:
            confirmations = 0
        if txid not in {h("resolution", node), h("claim", node)}:
            print("unknown fixture txid", file=sys.stderr)
            raise SystemExit(1)
        claim_anchor = h("wrong-anchor", node) if SCENARIO == "wrong-terminal-anchor" else h("anchor", node)
        claim_decoded = {"txid": txid, "vin": [{"txid": claim_anchor, "vout": 0,
                                                  "sequence": 4294967295}], "vout": []}
        return {"txid": txid, "hex": ("02" + h("raw", node)) * 3,
                "decoded": decoded_tx(node) if txid == h("resolution", node) else claim_decoded,
                "confirmations": confirmations,
                "qq_shadow_pow_resolution_relay_authorized":
                    "1" if state.get("status") == "relayed" or state.get("relay_authorized") else "0",
                **({"blockhash": h("block", node)} if confirmations else {})}
    if method == "gettxout":
        if state.get("confirmed", False):
            return None
        value = component(node)["input_amount"]
        script = "76a914" + h("script", node)[:40] + "88ac"
        if SCENARIO == "wrong-anchor-value" and node == 1:
            value = f"{DecimalLike(value) + DecimalLike('0.00000100'):.8f}"
        if SCENARIO == "wrong-anchor-script" and node == 1:
            script = "76a914" + h("wrong-script", node)[:40] + "88ac"
        return {"confirmations": 100, "value": value,
                "scriptPubKey": {"hex": script}}
    if method == "getblockheader":
        confirmations = -1 if SCENARIO == "inactive-terminal-header" else 3
        return {"confirmations": confirmations, "hash": params[0]}
    print(f"unsupported mock RPC {method}", file=sys.stderr)
    raise SystemExit(2)


def main() -> None:
    args = sys.argv[1:]
    with (FIXTURE / "transport.log").open("a") as log:
        log.write(json.dumps(args, separators=(",", ":")) + "\n")
    if args[:1] == ["inspect"]:
        container = args[1]
        node = node_from_container(container)
        state = load_state(node)
        if SCENARIO == "restart-mid-cut" and node == 16:
            state["inspect_calls"] = state.get("inspect_calls", 0) + 1
            if state["inspect_calls"] >= 2:
                state["restarted"] = True
            save_state(node, state)
        restarted = bool(state.get("restarted"))
        container_label = "container-restarted" if restarted else "container"
        image_id = ("sha256:" + "9" * 64) if state.get("runtime_drift") == "image" else IMAGE_ID
        service = "node99" if state.get("runtime_drift") == "service" else f"node{node:02d}"
        print(json.dumps([{"Id": h(container_label, node), "Image": image_id,
                           "State": {"Running": True, "Paused": False,
                                     "StartedAt": ("2026-08-14T02:00:00Z" if restarted else
                                                   "2026-08-13T20:00:00Z"),
                                     "Health": {"Status": "healthy"}},
                           "Config": {"Image": IMAGE_REF, "Labels": {
                               "com.docker.compose.project": "blackcoin30",
                               "com.docker.compose.service": service}}}]))
        return
    if args[:1] != ["exec"] or len(args) < 4:
        raise SystemExit(2)
    container = args[1]
    node = node_from_container(container)
    command = args[2]
    if command == "/usr/bin/sha256sum":
        state = load_state(node)
        cli_sha = "8" * 64 if state.get("runtime_drift") == "binary" else CLI_SHA
        print(f"{cli_sha}  {args[3]}")
        print(f"{DAEMON_SHA}  {args[4]}")
        return
    rest = args[3:]
    if "-rpcwallet=" in rest:
        print("fixture rejects an explicit empty wallet selector", file=sys.stderr)
        raise SystemExit(18)
    while rest and rest[0].startswith("-"):
        rest = rest[1:]
    if not rest:
        raise SystemExit(2)
    method = rest[0]
    result = rpc(node, method, rest[1:])
    if method == "gettxout" and result is None:
        if SCENARIO == "empty-gettxout-spent":
            return
        if SCENARIO == "whitespace-gettxout-spent":
            sys.stdout.write(" \n")
            return
        if SCENARIO == "malformed-gettxout-spent":
            sys.stdout.write("{\n")
            return
    if SCENARIO == "empty-non-gettxout" and method == "getnetworkinfo" and node == 1:
        return
    if SCENARIO == "empty-gettransaction" and method == "gettransaction" and node == 1:
        return
    if SCENARIO == "malformed-gettransaction" and method == "gettransaction" and node == 1:
        sys.stdout.write("{\n")
        return
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
