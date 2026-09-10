"""Read-only, dual-index confirmation for node30's QQP3 payout receipts."""
from __future__ import annotations

import json
import hashlib
import re
from decimal import Decimal, InvalidOperation

CONTAINERS = ("projectblackcoin-quantum-3013-r1", "projectblackcoin-quantum-3013-r2")
IMAGE = "sha256:bbc2435a034af908dc8c5f0e6976ba89d42347a8e49d5971e4b4d6fb1bbaa391"
CLI = "/usr/local/bin/blackcoin-cli"
DATADIR = "/home/blackcoin/.blackcoin"
COMMAND = [f"-datadir={DATADIR}", "-daemon=0", "-printtoconsole=1", "-networkactive=1", "-staking=0", "-powmining=0", "-qqautoshadowsignal=0", "-qqallowautokeycreation=0", "-prune=0", "-dbcache=4096", "-par=4"]
ALLOWED = {"getblockchaininfo", "getindexinfo", "getblockhash", "getblockheader", "getshadowscript"}
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
PAGE_SIZE = 128
MAX_PAGES = 4


class ObserverError(RuntimeError):
    pass


def require(value, message):
    if not value:
        raise ObserverError(message)


def hex64(value):
    return isinstance(value, str) and HEX64.fullmatch(value) is not None


def run_json(transport, args):
    raw = transport.run(args, timeout=30)
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ObserverError("observer returned malformed JSON") from exc


def rpc(transport, container, method, *args):
    require(container in CONTAINERS and method in ALLOWED, "observer RPC outside read-only surface")
    raw = transport.run(["exec", container, CLI, f"-datadir={DATADIR}", method, *map(str, args)], timeout=30)
    if method == "getblockhash":
        value = raw.strip()
        require(hex64(value), "observer block hash malformed")
        return value
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ObserverError("observer returned malformed RPC JSON") from exc


def runtime(transport, container):
    require(container in CONTAINERS, "observer container not pinned")
    entries = run_json(transport, ["inspect", container])
    require(isinstance(entries, list) and len(entries) == 1, "observer inspect cardinality")
    item = entries[0]
    require(item.get("Name") == "/" + container and item.get("Image") == IMAGE, "observer name/image changed")
    require(item.get("State", {}).get("Running") is True and item["State"].get("Health", {}).get("Status") == "healthy", "observer not healthy")
    config = item.get("Config", {})
    require(config.get("Entrypoint") == ["/usr/local/bin/blackcoind"] and config.get("Cmd") == COMMAND, "observer daemon role changed")
    require(hex64(item.get("Id")), "observer container identity malformed")
    return {"container": container, "id": item["Id"], "image": item["Image"], "started_at": item["State"]["StartedAt"], "network_mode": item["HostConfig"]["NetworkMode"], "mounts": sorted([{k: m.get(k) for k in ("Type", "Source", "Destination", "RW")} for m in item.get("Mounts", [])], key=lambda m: str(m["Destination"]))}


def node_anchor(transport, node):
    chain = transport.rpc(node, "getblockchaininfo")
    require(chain.get("chain") == "main" and chain.get("initialblockdownload") is False and type(chain.get("blocks")) is int and chain["blocks"] == chain.get("headers") and hex64(chain.get("bestblockhash")), "node30 chain is not current")
    return {"height": chain["blocks"], "blockhash": chain["bestblockhash"]}


def ready(transport, container, anchor):
    chain = rpc(transport, container, "getblockchaininfo")
    index = rpc(transport, container, "getindexinfo")
    shadow = index.get("shadowindex", {})
    require(chain.get("chain") == "main" and chain.get("initialblockdownload") is False and type(chain.get("blocks")) is int and chain["blocks"] >= anchor["height"], "observer chain is behind or not main")
    require(shadow.get("synced") is True and type(shadow.get("best_block_height")) is int and shadow["best_block_height"] >= anchor["height"], "observer shadow index is not ready")
    require(rpc(transport, container, "getblockhash", anchor["height"]) == anchor["blockhash"], "observer disagrees with node30 active anchor")
    return {"height": chain["blocks"], "bestblock": chain["bestblockhash"], "shadowindex": shadow}


def audit_observers(transport, node30):
    anchor = node_anchor(transport, node30)
    observers = []
    for container in CONTAINERS:
        identity = runtime(transport, container)
        state = ready(transport, container, anchor)
        require(runtime(transport, container) == identity, "observer runtime changed during audit")
        observers.append({"runtime": identity, "ready": state})
    require(transport.rpc(node30, "getblockhash", anchor["height"]) == anchor["blockhash"], "node30 audit anchor was reorganized")
    stable = [o["runtime"] for o in observers]
    return {"schema": 1, "node30_anchor": anchor, "observers": observers, "runtime_identities": hashlib.sha256(json.dumps(stable, sort_keys=True, separators=(",", ":")).encode()).hexdigest(), "read_only": True}


def payout_identity(record):
    return {k: record.get(k) for k in ("synthetic", "synthetic_txid", "vout", "mode", "nominal_amount", "scriptPubKey", "pow_claim_source", "base_anchor")}


def locate(transport, container, script, txid, vout, height, blockhash):
    cursor = (height - 1, "0" * 64)
    matches = []
    pages = []
    for _ in range(MAX_PAGES):
        page = rpc(transport, container, "getshadowscript", script, *cursor, PAGE_SIZE)
        require(page.get("schema") == "blackcoin.shadow.script.v1" and page.get("scriptPubKey") == script and page.get("synthetic") is True and page.get("merkle_included") is False, "observer history schema/script mismatch")
        require(type(page.get("height")) is int and page["height"] >= height and hex64(page.get("bestblock")), "observer history anchor malformed")
        require(rpc(transport, container, "getblockhash", page["height"]) == page["bestblock"], "observer page tip was reorganized")
        records = page.get("records")
        require(isinstance(records, list) and page.get("count") == len(records) and len(records) <= PAGE_SIZE, "observer page cardinality mismatch")
        pages.append({"height": page["height"], "bestblock": page["bestblock"], "count": len(records), "after": cursor})
        beyond = False
        previous = cursor
        for record in records:
            anchor = record.get("base_anchor", {})
            key = (anchor.get("height"), record.get("synthetic_txid"))
            require(type(key[0]) is int and hex64(key[1]), "observer payout cursor malformed")
            # uint256 ordering uses little-endian numeric bytes, not textual hex.
            require(key[0] >= previous[0], "observer page is not height ordered")
            previous = key
            if key[0] > height:
                beyond = True
                continue
            source = record.get("pow_claim_source")
            if key[0] == height and isinstance(source, dict) and source.get("txid") == txid and source.get("vout") == vout:
                require(record.get("scriptPubKey") == script and anchor.get("blockhash") == blockhash, "observer exact payout anchor/script mismatch")
                matches.append(record)
        next_cursor = page.get("next_cursor")
        if beyond or next_cursor is None:
            break
        require(isinstance(next_cursor, dict) and type(next_cursor.get("height")) is int and hex64(next_cursor.get("txid")), "observer next cursor malformed")
        next_key = (next_cursor["height"], next_cursor["txid"])
        require(next_key != cursor and next_key[0] >= cursor[0], "observer cursor did not advance")
        cursor = next_key
    else:
        raise ObserverError("bounded payout pagination exhausted")
    require(len(matches) == 1, "exact indexed payout missing or duplicated")
    record = matches[0]
    source = record["pow_claim_source"]
    require(record.get("synthetic") is True and record.get("mode") == "pow" and hex64(record.get("synthetic_txid")), "payout is not synthetic PoW")
    try:
        amount, fee = Decimal(str(record.get("nominal_amount"))), Decimal(str(source.get("base_fee")))
        require(amount.is_finite() and fee.is_finite() and amount > 0 and source.get("base_fee_known") is True and fee > 0, "payout credit/base fee not positive")
    except InvalidOperation as exc:
        raise ObserverError("payout amount malformed") from exc
    require(source.get("proof_version") == 3 and source.get("origin_bound") is True and source.get("input_bound") is False and source.get("claim_outpoint") is None, "payout is not unbound QQP3")
    require(type(source.get("origin_height")) is int and hex64(source.get("origin_previous_block_hash")) and source.get("inclusion_height") == height and type(source.get("origin_age")) is int and source["origin_age"] == height - source["origin_height"] and 0 <= source["origin_age"] <= 64, "payout origin metadata malformed")
    require(source.get("disposition") in ({"winner", "reimbursed_loser"} if source["origin_age"] == 0 else {"reimbursed_late"}), "payout disposition is not credited")
    require(rpc(transport, container, "getblockhash", height) == blockhash, "payout inclusion is not active")
    require(rpc(transport, container, "getblockhash", source["origin_height"] - 1) == source["origin_previous_block_hash"], "payout origin parent is not active")
    return {"record": record, "pages": pages}


def observe_payout(transport, node30, audit_receipt, script, source_txid, proof_vout, inclusion_height, inclusion_blockhash):
    require(isinstance(script, str) and re.fullmatch(r"6020[0-9a-f]{64}", script) is not None and hex64(source_txid) and type(proof_vout) is int and proof_vout >= 0 and type(inclusion_height) is int and inclusion_height > 5993200 and hex64(inclusion_blockhash), "payout observation input malformed")
    require(audit_receipt.get("schema") == 1 and audit_receipt.get("read_only") is True and len(audit_receipt.get("observers", [])) == 2, "observer audit receipt malformed")
    anchor = node_anchor(transport, node30)
    require(anchor["height"] >= inclusion_height and transport.rpc(node30, "getblockhash", inclusion_height) == inclusion_blockhash, "node30 does not confirm payout inclusion")
    outcomes = []
    for container, prior in zip(CONTAINERS, audit_receipt["observers"]):
        identity = runtime(transport, container)
        require(identity == prior.get("runtime"), "observer differs from audited runtime")
        state = ready(transport, container, anchor)
        observation = locate(transport, container, script, source_txid, proof_vout, inclusion_height, inclusion_blockhash)
        require(runtime(transport, container) == identity, "observer runtime changed during payout lookup")
        outcomes.append({"runtime": identity, "ready": state, **observation})
    require(payout_identity(outcomes[0]["record"]) == payout_identity(outcomes[1]["record"]), "independent observers disagree on payout")
    require(transport.rpc(node30, "getblockhash", inclusion_height) == inclusion_blockhash, "node30 inclusion changed during payout observation")
    record = outcomes[0]["record"]
    history = {"schema": "blackcoin.shadow.script.v1", "height": outcomes[0]["ready"]["height"], "bestblock": outcomes[0]["ready"]["bestblock"], "scriptPubKey": script, "address": record.get("address"), "synthetic": True, "merkle_included": False, "count": 1, "records": [record], "next_cursor": None}
    return {"schema": 1, "result": "DUAL_INDEX_ACTIVE_CHAIN_QQP3_PAYOUT", "record": record, "history": history, "observers": outcomes, "node30_anchor": anchor, "read_only": True}
