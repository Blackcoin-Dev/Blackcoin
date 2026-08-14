#!/usr/bin/python3
"""Stateful offline Docker/CLI fixture for node30 Free-Claim one-shot tests."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import signal
import sys


FIXTURE = pathlib.Path(os.environ["FLEET31_FIXTURE"])
SCENARIO = os.environ.get("FLEET31_SCENARIO", "happy")
TIP = "f" * 64
BLOCK = "b" * 64
CHAINWORK = "e" * 64
HEIGHT = 5_991_700
CLI_SHA = "a" * 64
DAEMON_SHA = "b" * 64
IMAGE_REF = "qqblackcoin/blackcoin-v4-gui@sha256:" + "c" * 64
IMAGE_ID = "sha256:" + "d" * 64
LEGACY_ADDRESS = "BfixtureLegacyTarget"
QUANTUM_ADDRESS = "qfixtureWitnessV16"
TARGET_SCRIPT = "76a914" + "1" * 40 + "88ac"
PAYOUT_SCRIPT = "6020" + "2" * 64
INPUT_TXID = hashlib.sha256(b"fee-input").hexdigest()
CLAIM_TXID = hashlib.sha256(b"one-shot-claim").hexdigest()
BASE_TXID = hashlib.sha256(b"preexisting-wallet-tx").hexdigest()
INPUT_AMOUNT = "1.00000000"
CHANGE = "0.99971300"
FEE = "0.00028700"
TX_HEX = ("02" + hashlib.sha256(b"claim-bytes").hexdigest()) * 4


def state_path() -> pathlib.Path:
    return FIXTURE / "state.json"


def load_state() -> dict:
    if state_path().exists():
        return json.loads(state_path().read_text())
    return {"claim": False, "confirmed": False, "send_calls": 0}


def save_state(value: dict) -> None:
    tmp = state_path().with_suffix(".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True) + "\n")
    tmp.replace(state_path())


def proof_hex() -> str:
    target = bytes.fromhex(TARGET_SCRIPT)
    payout = bytes.fromhex(PAYOUT_SCRIPT)
    payload = (b"QQSPROOF" + b"QQP2" + b"\x00" + (7).to_bytes(8, "little") +
               len(target).to_bytes(2, "little") + target +
               len(payout).to_bytes(2, "little") + payout)
    if SCENARIO == "wrong-proof-payout":
        payload = payload[:-1] + bytes([payload[-1] ^ 1])
    return payload.hex()


def decoded() -> dict:
    fee = "0.00028800" if SCENARIO == "over-cap" else FEE
    change = "0.99971200" if SCENARIO == "over-cap" else CHANGE
    vsize = 288 if SCENARIO == "over-cap" else 287
    script = TARGET_SCRIPT if SCENARIO != "wrong-change-script" else "76a914" + "3" * 40 + "88ac"
    proof_script = ("6a4c53" if SCENARIO == "wrong-proof-script-encoding" else
                    "6a4c54") + proof_hex()
    return {"txid": CLAIM_TXID, "version": 2, "vsize": vsize,
            "vin": [{"txid": INPUT_TXID, "vout": 0, "sequence": 4294967293}],
            "vout": [
                {"n": 0, "value": change,
                 "scriptPubKey": {"hex": script, "type": "pubkeyhash"}},
                {"n": 1, "value": "0.00000000",
                 "scriptPubKey": {"hex": proof_script, "type": "nulldata",
                                  "asm": "OP_RETURN " + proof_hex()}},
            ]}


def claim_result() -> dict:
    result = {"txid": CLAIM_TXID, "hex": TX_HEX, "proof": proof_hex(),
              "proof_mode": "pow", "proof_mode_byte": 0, "external_proof": False,
              "fee": "0.00028800" if SCENARIO == "over-cap" else FEE,
              "change": "0.99971200" if SCENARIO == "over-cap" else CHANGE,
              "vsize": 288 if SCENARIO == "over-cap" else 287,
              "address": LEGACY_ADDRESS, "quantum_address": QUANTUM_ADDRESS}
    if SCENARIO == "malformed-response":
        result["unexpected"] = True
    if SCENARIO == "wrong-address-response":
        result["quantum_address"] = "qwrong"
    if SCENARIO == "overprecision-fee":
        result["fee"] = "0.000287001"
    return result


def role_rpc(method: str, state: dict) -> object:
    if method == "getblockchaininfo":
        return {"chain": "main", "blocks": HEIGHT, "headers": HEIGHT,
                "bestblockhash": TIP, "chainwork": CHAINWORK,
                "initialblockdownload": False, "pruned": False, "warnings": ""}
    if method == "getnetworkinfo":
        return {"version": 300104, "subversion": "/Blackcoin:30.1.4/"}
    if method == "getconnectioncount":
        return 32
    if method == "listwallets":
        return [""]
    if method == "getwalletinfo":
        return {"walletname": "", "format": "sqlite", "private_keys_enabled": True,
                "external_signer": False, "scanning": False,
                "unlocked_staking_only": False,
                "unlocked_until": 2_000_000_000,
                "txcount": 1500 + int(state["claim"])}
    if method == "getstakinginfo":
        if SCENARIO == "pos-disabled":
            return {"enabled": True, "staking": False, "weight": 0}
        return {"enabled": True, "staking": True, "state": "searching",
                "worker_running": True, "eligible": True,
                "snapshot_current": True, "weight": 100150000000}
    if method == "getpowmininginfo":
        enabled = SCENARIO == "pow-enabled"
        return {"enabled": enabled, "state": "searching" if enabled else "disabled",
                "hashrate": 10 if enabled else 0, "claims_submitted": int(state["claim"]),
                "threads": 1 if enabled else 0, "cpu_percent": 1 if enabled else 0,
                "blocking_quarantined_claims": 1 if SCENARIO == "blocking" else 0,
                "actionable_quarantined_claims": 1 if SCENARIO == "blocking" else 0,
                "indeterminate_quarantined_claims": 0,
                "claim_recovery_database_outcome_ambiguous": False}
    if method == "getpowclaimrecoveryinfo":
        return {"chain_ready": True, "wallet_tip_matches": True,
                "database_outcome_ambiguous": False, "active_tip": TIP,
                "active_height": HEIGHT,
                "blocking_quarantined_claims": 1 if SCENARIO == "blocking" else 0,
                "component_details": []}
    raise KeyError(method)


def rpc(method: str, params: list[str]) -> object:
    state = load_state()
    try:
        return role_rpc(method, state)
    except KeyError:
        pass
    if method == "listunspent":
        rows = [{"txid": INPUT_TXID, "vout": 0, "address": LEGACY_ADDRESS,
                 "scriptPubKey": TARGET_SCRIPT, "amount": INPUT_AMOUNT,
                 "confirmations": 50, "spendable": True, "safe": True,
                 "spendability_state": "spendable_legacy"}]
        if SCENARIO == "multiple-target-inputs":
            rows.append({**rows[0], "txid": hashlib.sha256(b"fee-input-2").hexdigest()})
        return rows
    if method == "gettxout":
        if state["claim"]:
            return None
        return {"confirmations": 50, "value": INPUT_AMOUNT,
                "scriptPubKey": {"hex": TARGET_SCRIPT}}
    if method == "getgoldrushinfo":
        return {"active": True,
                "competing_claim_rule_active_next_block": SCENARIO == "qqp3",
                "qqp4_active_next_block": False}
    if method == "validateaddress":
        address = params[0]
        if address != QUANTUM_ADDRESS:
            return {"isvalid": False, "address": address}
        witness = 15 if SCENARIO == "wrong-witness" else 16
        return {"isvalid": True, "address": address, "iswitness": True,
                "witness_version": witness, "witness_program": "2" * 64,
                "scriptPubKey": PAYOUT_SCRIPT}
    if method == "getaddressinfo":
        address = params[0]
        if address == QUANTUM_ADDRESS:
            return {"address": address, "scriptPubKey": PAYOUT_SCRIPT,
                    "ismine": False, "iswatchonly": False}
        if address == LEGACY_ADDRESS:
            return {"address": address, "scriptPubKey": TARGET_SCRIPT,
                    "ismine": True, "iswatchonly": False, "solvable": True}
        return {"address": address, "scriptPubKey": "", "ismine": False,
                "iswatchonly": False, "solvable": False}
    if method == "getshadowpowwork":
        return {"active": True, "height": HEIGHT + 1, "prevhash": TIP,
                "target_bits": 12, "prefix": "QQSPROOF", "proof_mode": "pow",
                "proof_mode_byte": 0, "proof_version": 3 if SCENARIO == "qqp3" else 2,
                "claim_outpoint_required": False, "qqp4_active_next_block": False,
                "target_script": TARGET_SCRIPT, "quantum_address": QUANTUM_ADDRESS,
                "quantum_payout_script": PAYOUT_SCRIPT, "claim_txid": None,
                "claim_vout": None}
    if method == "listtransactions":
        rows = [{"txid": BASE_TXID, "category": "receive", "amount": "1.00000000"}]
        if state["claim"]:
            rows.append({"txid": CLAIM_TXID, "category": "send", "amount": "0.00000000",
                         "fee": "-" + FEE})
        return rows
    if method == "sendshadowpowclaim":
        state["send_calls"] += 1
        if state["send_calls"] > 1:
            print("mock refuses a second sendshadowpowclaim", file=sys.stderr)
            raise SystemExit(91)
        if len(params) != 4 or params != [LEGACY_ADDRESS, QUANTUM_ADDRESS, "2000000", "100"]:
            print("mock one-shot parameters changed", file=sys.stderr)
            raise SystemExit(92)
        if SCENARIO == "crash-before-persist":
            save_state(state)
            os.kill(os.getppid(), signal.SIGKILL)
            raise SystemExit(97)
        state["claim"] = True
        save_state(state)
        if SCENARIO == "crash-after-persist":
            os.kill(os.getppid(), signal.SIGKILL)
            raise SystemExit(98)
        if SCENARIO in {"lost-response", "definitive-error"}:
            print("mock response lost after potential persistence", file=sys.stderr)
            raise SystemExit(93)
        return claim_result()
    if method == "decoderawtransaction":
        if SCENARIO == "crash-after-response-receipt":
            os.kill(os.getppid(), signal.SIGKILL)
            raise SystemExit(99)
        if params[0] != TX_HEX:
            print("unknown mock transaction bytes", file=sys.stderr)
            raise SystemExit(94)
        return decoded()
    if method == "gettxspendingprevout":
        return [{"txid": INPUT_TXID, "vout": 0,
                 **({"spendingtxid": CLAIM_TXID}
                    if state["claim"] and not state["confirmed"] else {})}]
    if method == "gettransaction":
        if params[0] != CLAIM_TXID or not state["claim"]:
            print("unknown mock wallet transaction", file=sys.stderr)
            raise SystemExit(95)
        confirmations = 6 if state["confirmed"] else 0
        txhex = ("03" + TX_HEX[2:]) if SCENARIO == "confirmed-bytes-drift" and state["confirmed"] else TX_HEX
        return {"txid": CLAIM_TXID, "hex": txhex, "decoded": decoded(),
                "fee": "-" + FEE, "confirmations": confirmations,
                **({"blockhash": BLOCK} if confirmations else {})}
    if method == "getblockheader":
        return {"hash": BLOCK, "confirmations": -1 if SCENARIO == "inactive-header" else 6,
                "height": HEIGHT + 1}
    if method == "getshadowscript":
        records = []
        if state["confirmed"] and SCENARIO != "missing-payout":
            disposition = "invalid_proof" if SCENARIO == "rejected-payout" else "winner"
            records = [{"synthetic": True, "merkle_included": False,
                        "synthetic_txid": hashlib.sha256(b"synthetic").hexdigest(),
                        "vout": 0, "mode": "pow", "status": "immature",
                        "lifecycle_category": "gold_rush_synthetic_immature",
                        "nominal_amount": "1.00000000", "effective_amount": "1.00000000",
                        "decayed_amount": "0.00000000", "valuation_status": "current",
                        "scriptPubKey": PAYOUT_SCRIPT, "address": QUANTUM_ADDRESS,
                        "pow_claim_source": {"txid": CLAIM_TXID, "vout": 1,
                            "logical_proof_id": hashlib.sha256(b"proof").hexdigest(),
                            "canonical_rank": hashlib.sha256(b"rank").hexdigest(),
                            "disposition": disposition, "base_fee_known": True,
                            "base_fee": FEE, "proof_version": 2, "origin_bound": False,
                            "origin_height": HEIGHT + 1,
                            "origin_previous_block_hash": None,
                            "inclusion_height": HEIGHT + 1, "origin_age": 0,
                            "input_bound": False, "claim_outpoint": None},
                        "base_anchor": {"height": HEIGHT + 1, "blockhash": BLOCK,
                                        "time": 1_786_680_000, "claim_index": 0},
                        "lifecycle": {}, "demurrage": {}, "spend": None}]
            if SCENARIO == "wrong-payout-vout":
                records[0]["pow_claim_source"]["vout"] = 0
        return {"schema": "blackcoin.shadow.script.v1", "scriptPubKey": PAYOUT_SCRIPT,
                "address": QUANTUM_ADDRESS, "height": HEIGHT + int(state["confirmed"]),
                "bestblock": BLOCK if state["confirmed"] else TIP,
                "count": len(records), "next_cursor": None, "synthetic": True,
                "merkle_included": False, "units": {}, "records": records}
    print(f"unsupported mock RPC {method}", file=sys.stderr)
    raise SystemExit(96)


def main() -> None:
    args = sys.argv[1:]
    with (FIXTURE / "transport.log").open("a") as log:
        log.write(json.dumps(args, separators=(",", ":")) + "\n")
    tokens = {"blackcoin-v4-gui-30", hashlib.sha256(b"container").hexdigest()}
    if args[:1] == ["inspect"]:
        if args[1] not in tokens:
            raise SystemExit(2)
        print(json.dumps([{"Id": hashlib.sha256(b"container").hexdigest(),
                           "Image": IMAGE_ID,
                           "State": {"Running": True, "Paused": False,
                                     "StartedAt": "2026-08-14T03:00:00Z",
                                     "Health": {"Status": "healthy"}},
                           "Config": {"Image": IMAGE_REF, "Labels": {
                               "com.docker.compose.project": "blackcoin30",
                               "com.docker.compose.service": "node30"}}}]))
        return
    if args[:1] != ["exec"] or len(args) < 4 or args[1] not in tokens:
        raise SystemExit(2)
    if args[2] == "/usr/bin/sha256sum":
        print(f"{CLI_SHA}  {args[3]}")
        print(f"{DAEMON_SHA}  {args[4]}")
        return
    rest = args[3:]
    if "-rpcwallet=" in rest:
        print("mock rejects explicit empty wallet selector", file=sys.stderr)
        raise SystemExit(18)
    while rest and rest[0].startswith("-"):
        rest = rest[1:]
    if not rest:
        raise SystemExit(2)
    print(json.dumps(rpc(rest[0], rest[1:]), sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
