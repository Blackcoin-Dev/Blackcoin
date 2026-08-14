#!/usr/bin/python3
"""Stateful offline Docker/CLI fixture for node30_recovery.py."""

import hashlib
import json
import os
import pathlib
import sys


FIXTURE = pathlib.Path(os.environ["FLEET31_FIXTURE"])
SCENARIO = os.environ.get("FLEET31_SCENARIO", "happy")
TIP = "f" * 64
CHAINWORK = "e" * 64
HEIGHT = 5_991_585
CLI_SHA = "a" * 64
DAEMON_SHA = "b" * 64
IMAGE_REF = "qqblackcoin/blackcoin-v4-gui@sha256:" + "c" * 64
IMAGE_ID = "sha256:" + "d" * 64
NODE = 30


def h(label: str) -> str:
    return hashlib.sha256(f"{label}:{NODE}".encode()).hexdigest()


def state_path() -> pathlib.Path:
    return FIXTURE / "node30.json"


def load_state() -> dict:
    if state_path().exists():
        return json.loads(state_path().read_text())
    return {"status": "ready", "confirmed": False}


def save_state(state: dict) -> None:
    tmp = state_path().with_suffix(".tmp")
    tmp.write_text(json.dumps(state, sort_keys=True) + "\n")
    tmp.replace(state_path())


def component() -> dict:
    fee = "0.00019200" if SCENARIO == "wrong-fee" else "0.00019100"
    return {"anchor": {"txid": h("anchor"), "vout": 0},
            "generation_fingerprint": h("generation"),
            "component_fingerprint": h("component"),
            "classification": "current_branch_ineligible",
            "claim_txids": [h("claim")], "descendant_claims": 0,
            "fee": fee, "vsize": 191, "input_amount": "1.24691810",
            "output_amount": "1.24672710", "frontier_may_advance": True,
            "conflicts_with_revalidating_unbound_proof": True,
            "reason_code": "unbound-proof-may-revalidate",
            "reason": "fixture retained QQP2 may revalidate"}


def action(status: str) -> dict:
    result = component()
    if status == "ready":
        result.update({"status": "ready", "persisted": False,
                       "relay_authorized": False, "in_mempool": False,
                       "unsigned_template_hash": h("unsigned")})
    else:
        result.update({"status": "reuse_managed", "persisted": True,
                       "relay_authorized": status == "relayed",
                       "in_mempool": status == "relayed",
                       "resolution_txid": h("resolution")})
    return result


def preview(options: dict, status: str) -> dict:
    current = action(status)
    if status != "ready" and "fee_rate" in options:
        actions = []
        refused = [{**current, "status": "refused",
                    "reason_code": "fee-rate-cannot-modify-signed"}]
        total = "0.00000000"
    else:
        actions = [current]
        refused = [{"reason_code": "anchor-spent"} for _ in range(46)]
        total = "0.00019100"
    result = {"action": "preview", "plan_id": h("plan-" + status),
              "plan_reusable": True, "active_tip": TIP, "active_height": HEIGHT,
              "wallet_generation": 47 + (status != "ready"), "wallet_tip_matches": True,
              "complete": True, "one_call_finality": False, "frontier_may_advance": True,
              "contains_revalidating_unbound_proof": True,
              "max_fee_per_resolution": "0.00019100",
              "aggregate_batch_fee_cap": "0.00019100", "total_fee": total,
              "actionable_components": len(actions), "refused_components": len(refused),
              "actions": actions, "refused": refused, "success": True,
              "stale_plan": False, "signed_and_persisted": 0,
              "durable_state_changed": False, "durable_state_ambiguous": False,
              "relay_authority_granted": 0, "broadcast": 0,
              "already_in_mempool": 0, "relay_deferred": 0, "error": ""}
    if "fee_rate" in options:
        result["fee_rate_atoms_per_k"] = 100000
    return result


def decoded_tx() -> dict:
    return {"txid": h("resolution"), "version": 2, "vsize": 191,
            "vin": [{"txid": h("anchor"), "vout": 0, "sequence": 4294967295}],
            "vout": [{"n": 0, "value": "1.24672710",
                      "scriptPubKey": {"hex": "76a914" + h("script")[:40] + "88ac"}}]}


def mutation(options: dict, state: dict) -> dict:
    name = options.get("action")
    expected = h("plan-" + state["status"])
    if options.get("expected_plan_id") != expected:
        print("stale fixture plan", file=sys.stderr)
        raise SystemExit(1)
    if name == "sign_only":
        state["status"] = "signed"
        save_state(state)
        if SCENARIO == "lost-sign-result":
            print("fixture lost sign result after durable write", file=sys.stderr)
            raise SystemExit(1)
        status, grant, broadcast = "signed_and_persisted", 0, 0
    elif name == "commit_and_broadcast":
        state["status"] = "relayed"
        save_state(state)
        if SCENARIO == "lost-relay-result":
            print("fixture lost relay result after durable grant", file=sys.stderr)
            raise SystemExit(1)
        status, grant, broadcast = "broadcast", 1, 1
    else:
        raise SystemExit(2)
    result_action = action(state["status"])
    result_action["status"] = status
    return {"action": name, "acknowledged_plan_id": expected,
            "acknowledged_active_tip": TIP, "acknowledged_active_height": HEIGHT,
            "acknowledged_wallet_generation": 47 if name == "sign_only" else 48,
            "acknowledged_total_fee": "0.00019100", "plan_consumed": True,
            "plan_reusable": False, "contains_revalidating_unbound_proof": True,
            "actions": [result_action], "refused": [{"reason_code": "anchor-spent"} for _ in range(46)],
            "current_plan": preview({}, state["status"]), "success": True,
            "stale_plan": False, "signed_and_persisted": 1 if name == "sign_only" else 0,
            "durable_state_changed": True, "durable_state_ambiguous": False,
            "relay_authority_granted": grant, "broadcast": broadcast,
            "already_in_mempool": 0, "relay_deferred": 0, "error": "",
            "relay_complete": name == "commit_and_broadcast"}


def rpc(method: str, params: list[str]) -> object:
    state = load_state()
    if method == "getblockchaininfo":
        return {"chain": "main", "blocks": HEIGHT, "headers": HEIGHT,
                "bestblockhash": TIP, "chainwork": CHAINWORK,
                "initialblockdownload": False, "pruned": False, "warnings": ""}
    if method == "getnetworkinfo":
        return {"version": 300104, "subversion": "/Blackcoin:30.1.4/"}
    if method == "getconnectioncount":
        return 92
    if method == "listwallets":
        return [""]
    if method == "getwalletinfo":
        return {"walletname": "", "format": "sqlite", "private_keys_enabled": True,
                "external_signer": False, "scanning": False,
                "unlocked_staking_only": False, "unlocked_until": 2_000_000_000,
                "txcount": 1519 + (state["status"] != "ready")}
    if method == "getstakinginfo":
        return {"enabled": True, "staking": True, "state": "searching",
                "worker_running": True, "eligible": True,
                "snapshot_current": True, "weight": 100150000000}
    if method == "getpowmininginfo":
        return {"enabled": False, "state": "disabled", "hashrate": 0,
                "claims_submitted": 0, "threads": 0, "cpu_percent": 0,
                "blocking_quarantined_claims": 0 if state.get("confirmed") else 1,
                "actionable_quarantined_claims": 0 if state.get("confirmed") else 1,
                "indeterminate_quarantined_claims": 0,
                "claim_recovery_database_outcome_ambiguous": False}
    if method == "getpowclaimrecoveryinfo":
        detail = component()
        detail.update({"anchor": {**detail["anchor"], "amount": detail["input_amount"],
                                   "scriptPubKey": "76a914" + h("script")[:40] + "88ac"},
                       "anchor_authenticated": True,
                       "anchor_unspent": not state.get("confirmed"),
                       "has_revalidating_unbound_proof": True})
        return {"chain_ready": True, "wallet_tip_matches": True,
                "database_outcome_ambiguous": False, "active_tip": TIP,
                "active_height": HEIGHT,
                "blocking_quarantined_claims": 0 if state.get("confirmed") else 1,
                "component_details": [detail]}
    if method == "resolveallshadowpowclaims":
        options = json.loads(params[0]) if params else {}
        if options.get("action", "preview") == "preview":
            return preview(options, state["status"])
        return mutation(options, state)
    if method == "gettransaction":
        txid = params[0]
        if txid not in {h("resolution"), h("claim")}:
            print("unknown fixture txid", file=sys.stderr)
            raise SystemExit(1)
        confirmations = 3 if state.get("confirmed") else 0
        return {"txid": txid, "hex": ("02" + h("raw")) * 3,
                "decoded": decoded_tx() if txid == h("resolution") else {"txid": txid},
                "confirmations": confirmations,
                **({"blockhash": h("block")} if confirmations else {})}
    if method == "gettxout":
        return None if state.get("confirmed") else {"confirmations": 100, "value": "1.24691810"}
    if method == "getblockheader":
        return {"confirmations": 3, "hash": params[0]}
    print(f"unsupported mock RPC {method}", file=sys.stderr)
    raise SystemExit(2)


def main() -> None:
    args = sys.argv[1:]
    with (FIXTURE / "transport.log").open("a") as log:
        log.write(json.dumps(args, separators=(",", ":")) + "\n")
    container_tokens = {"blackcoin-v4-gui-30", h("container")}
    if args[:1] == ["inspect"]:
        if args[1] not in container_tokens:
            raise SystemExit(2)
        print(json.dumps([{"Id": h("container"), "Image": IMAGE_ID,
                           "State": {"Running": True, "Paused": False,
                                     "StartedAt": "2026-08-13T20:00:00Z",
                                     "Health": {"Status": "healthy"}},
                           "Config": {"Image": IMAGE_REF, "Labels": {
                               "com.docker.compose.project": "blackcoin30",
                               "com.docker.compose.service": "node30"}}}]))
        return
    if args[:1] != ["exec"] or len(args) < 4 or args[1] not in container_tokens:
        raise SystemExit(2)
    if args[2] == "/usr/bin/sha256sum":
        print(f"{CLI_SHA}  {args[3]}")
        print(f"{DAEMON_SHA}  {args[4]}")
        return
    rest = args[3:]
    if "-rpcwallet=" in rest:
        print("fixture rejects explicit empty wallet selector", file=sys.stderr)
        raise SystemExit(18)
    while rest and rest[0].startswith("-"):
        rest = rest[1:]
    if not rest:
        raise SystemExit(2)
    print(json.dumps(rpc(rest[0], rest[1:]), sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
