"""Installed-132621 QQP3 adapter; historical QQP2 receipt modules stay intact."""
from __future__ import annotations
import hashlib
import re
import types
from decimal import Decimal

PROOF_VERSION = 3
MEMPOOL_LIMIT = 64
EXPECTED_VSIZE = 323
FEE_CAP = Decimal("0.00032300")


def active_regime(value):
    return (isinstance(value, dict) and value.get("active") is True and
            value.get("competing_claim_rule_active_next_block") is True and
            value.get("qqp4_active_next_block") is False)


def build_legacy(original, queue_reader):
    module = types.ModuleType("node30_installed_qqp3_legacy_adapter")
    ns = module.__dict__
    ns.update(vars(original))
    for name, value in list(ns.items()):
        if isinstance(value, types.FunctionType) and value.__globals__ is vars(original):
            adapted = types.FunctionType(value.__code__, ns, value.__name__,
                                         value.__defaults__, value.__closure__)
            adapted.__kwdefaults__ = value.__kwdefaults__
            ns[name] = adapted
    ns.update(EXPECTED_VSIZE=EXPECTED_VSIZE, FEE_CAP=FEE_CAP, audit_queue=queue_reader)
    die = original.die

    def validate_controller_runtime():
        identity = original.validate_controller_runtime()
        # Historical receipt validation and current QQP3 execution share the
        # same actually validated interpreter, without changing either contract.
        original.CONTROLLER_RUNTIME_IDENTITY = identity
        ns["CONTROLLER_RUNTIME_IDENTITY"] = identity
        return identity

    fee_inventory_base = ns["fee_input_inventory"]
    def fee_inventory(transport, node):
        inventory = fee_inventory_base(transport, node)
        address_info = transport.rpc(node, "getaddressinfo", inventory["address"])
        pubkey = address_info.get("pubkey") if isinstance(address_info, dict) else None
        if not isinstance(pubkey, str) or not re.fullmatch(r"0[23][0-9a-f]{64}", pubkey):
            die("QQP3 323-vB fee budget requires the exact compressed wallet pubkey")
        pubhash = hashlib.new("ripemd160", hashlib.sha256(bytes.fromhex(pubkey)).digest()).hexdigest()
        if inventory["scriptPubKey"] != "76a914"+pubhash+"88ac":
            die("QQP3 fee wallet pubkey does not match audited P2PKH target")
        return inventory

    def work_exact(work, selected, payout):
        return (isinstance(work, dict) and work.get("active") is True and
                work.get("proof_mode") == "pow" and work.get("proof_mode_byte") == 0 and
                work.get("proof_version") == 3 and work.get("claim_outpoint_required") is False and
                work.get("qqp4_active_next_block") is False and
                work.get("target_script") == selected["scriptPubKey"] and
                work.get("quantum_address") == payout["address"] and
                work.get("quantum_payout_script") == payout["scriptPubKey"] and
                work.get("claim_txid") in {None, ""} and work.get("claim_vout") in {None, -1} and
                type(work.get("target_bits")) is int and work["target_bits"] > 0)

    def stable_snapshot(transport, contract, node):
        for attempt in range(1, original.SNAPSHOT_ATTEMPTS + 1):
            before = original.node30.base.validate_chain(transport.rpc(node, "getblockchaininfo"), 30)
            role = original.node30.role_snapshot(transport, node, False)
            if (role["recovery"].get("blocking_quarantined_claims") != 0 or
                    role["recovery"].get("database_outcome_ambiguous") is not False):
                die("node30 retained-claim recovery is not clear")
            queue = queue_reader(contract)
            payout = original.validate_payout_address(transport, node, queue["item"]["record"]["quantum_address"])
            selected = ns["fee_input_inventory"](transport, node)
            if not active_regime(transport.rpc(node, "getgoldrushinfo")):
                die("node30 is not in the installed QQP3 reward regime")
            work = transport.rpc(node, "getshadowpowwork", selected["address"], payout["address"])
            selected_after = ns["fee_input_inventory"](transport, node)
            after = original.node30.base.validate_chain(transport.rpc(node, "getblockchaininfo"), 30)
            if not work_exact(work, selected, payout) or not original.work_tip_fields_well_formed(work):
                die("node30 QQP3 work fields are not exact")
            non_tip = ["chain", "initialblockdownload", "pruned", "warnings"]
            if {k:before.get(k) for k in non_tip} != {k:after.get(k) for k in non_tip}:
                die("node30 non-tip chain fields moved")
            if original.node30.base.chain_identity(before) != original.node30.base.chain_identity(after):
                if original.fee_inventory_non_tip_identity(selected) != original.fee_inventory_non_tip_identity(selected_after):
                    die("node30 fee-input identity changed during tip advance")
                continue
            if selected != selected_after:
                die("node30 fee-input set changed on stable tip")
            if work["height"] != after["blocks"]+1 or work["prevhash"] != after["bestblockhash"]:
                continue
            work = ns["validate_work"](work, after, selected, payout)
            txids = original.wallet_txids(transport, node)
            return {"chain": {"height": after["blocks"], "tip": after["bestblockhash"]},
                    "role": role, "queue": queue, "payout": payout, "fee_input": selected,
                    "work": work, "snapshot_attempts": attempt, "wallet_txids_before": txids,
                    "wallet_txids_before_sha256": original.sha256_json(txids)}
        die("QQP3 snapshot tip drift exhausted bounded attempts")

    def parse_proof(proof_hex, expected_target, expected_payout):
        if not isinstance(proof_hex, str) or not re.fullmatch(r"[0-9a-f]+", proof_hex) or len(proof_hex) % 2:
            die("QQP3 proof hex is noncanonical")
        proof = bytes.fromhex(proof_hex)
        if not proof.startswith(b"QQSPROOFQQP3\x00") or len(proof) < 61:
            die("claim proof is not unbound PoW-mode QQP3")
        payload = proof[8:]
        origin = int.from_bytes(payload[13:17], "little")
        parent = payload[17:49][::-1].hex()
        if origin < 5993200 or parent == "00" * 32:
            die("QQP3 origin is not in the installed active era")
        cursor = 49
        def script():
            nonlocal cursor
            if cursor + 2 > len(payload):
                die("QQP3 script length truncated")
            size = int.from_bytes(payload[cursor:cursor+2], "little")
            cursor += 2
            value = payload[cursor:cursor+size]
            cursor += size
            return value.hex()
        target, payout = script(), script()
        if cursor != len(payload) or target != expected_target or payout != expected_payout:
            die("QQP3 exact target or payout binding differs")
        return {"proof_sha256": hashlib.sha256(proof).hexdigest(), "proof_version": 3,
                "proof_mode": "pow", "nonce": int.from_bytes(payload[5:13], "little"),
                "origin_bound": True, "origin_height": origin,
                "origin_previous_block_hash": parent,
                "target_script": target, "quantum_payout_script": payout}

    def require_origin(proof, intent):
        if (proof["origin_height"] != intent["work"]["height"] or
                proof["origin_previous_block_hash"] != intent["work"]["prevhash"]):
            die("QQP3 proof origin differs from the consumed dynamic intent")

    def parse_transaction(txhex, intent):
        if not isinstance(txhex, str) or not re.fullmatch(r"[0-9a-f]+", txhex) or len(txhex) % 2:
            die("claim transaction hex is noncanonical")
        raw = bytes.fromhex(txhex)
        cursor = 0
        def take(size):
            nonlocal cursor
            result = raw[cursor:cursor+size]
            cursor += size
            if len(result) != size:
                die("claim raw transaction is truncated")
            return result
        def compact():
            value = take(1)[0]
            if value >= 253:
                die("claim raw transaction has an unexpected compact-size envelope")
            return value
        if take(4) != b"\x02\x00\x00\x00" or compact() != 1:
            die("claim must be canonical nonwitness version2 with one input")
        prev_txid = take(32)[::-1].hex()
        prev_vout = int.from_bytes(take(4), "little")
        scriptsig = take(compact())
        if len(scriptsig) < 44 or not 9 <= scriptsig[0] <= 71:
            die("claim input lacks a canonical low-R P2PKH signature")
        sig_size = scriptsig[0]
        signature = scriptsig[1:1+sig_size]
        pubkey = scriptsig[2+sig_size:]
        if (len(scriptsig) != 1+sig_size+1+33 or scriptsig[1+sig_size] != 33 or
                len(pubkey) != 33 or pubkey[0] not in {2, 3} or signature[-1] != 1):
            die("claim input signature/pubkey shape is not exact P2PKH SIGHASH_ALL")
        der = signature[:-1]
        if len(der) < 8 or der[0] != 0x30 or der[1] != len(der)-2 or der[2] != 2:
            die("claim signature DER header is invalid")
        rlen = der[3]
        if not 1 <= rlen <= 32 or 4+rlen+2 > len(der) or der[4+rlen] != 2:
            die("claim signature R is not canonical low-R")
        slen = der[5+rlen]
        if not 1 <= slen <= 32 or 6+rlen+slen != len(der):
            die("claim signature S length is invalid")
        for value in [der[4:4+rlen], der[6+rlen:]]:
            if value[0] & 128 or (len(value) > 1 and value[0] == 0 and not value[1] & 128):
                die("claim signature DER integer is nonminimal or negative")
        target = intent["fee_input"]["scriptPubKey"]
        pubhash = hashlib.new("ripemd160", hashlib.sha256(pubkey).digest()).hexdigest()
        if target != "76a914"+pubhash+"88ac":
            die("claim pubkey does not authenticate the audited legacy target")
        if take(4) != b"\xfd\xff\xff\xff" or compact() != 2:
            die("claim sequence or output count differs")
        change_atoms = int.from_bytes(take(8), "little")
        if take(compact()).hex() != target:
            die("claim change script differs from audited target")
        if take(8) != b"\x00"*8:
            die("claim proof output has nonzero value")
        carrier = take(compact())
        if len(carrier) < 3 or carrier[:2] != b"\x6a\x4c" or carrier[2] != len(carrier)-3:
            die("QQP3 carrier is not exact canonical PUSHDATA1")
        proof_hex = carrier[3:].hex()
        proof = parse_proof(proof_hex, target, intent["payout"]["scriptPubKey"])
        require_origin(proof, intent)
        if take(4) != b"\x00"*4 or cursor != len(raw) or not 261 <= len(raw) <= EXPECTED_VSIZE:
            die("claim locktime, trailing bytes, or actual serialized size differs")
        member = ns["audited_fee_member"](intent["fee_input"], prev_txid, prev_vout)
        change = Decimal(change_atoms) / 100_000_000
        if Decimal(member["amount"]) - change != FEE_CAP:
            die("QQP3 raw input/output fee is not exactly 32300 atoms")
        txid = hashlib.sha256(hashlib.sha256(raw).digest()).digest()[::-1].hex()
        return {"txid": txid, "actual_vsize": len(raw), "member": member,
                "change": change, "proof_hex": proof_hex, "proof": proof}

    def signed_evidence(transport, node, raw, intent):
        fields = {"txid", "hex", "proof", "proof_mode", "proof_mode_byte", "external_proof",
                  "fee", "change", "vsize", "address", "quantum_address"}
        if (not isinstance(raw, dict) or set(raw) != fields or raw.get("proof_mode") != "pow" or
                raw.get("proof_mode_byte") != 0 or raw.get("external_proof") is not False or
                raw.get("address") != intent["fee_input"]["address"] or
                raw.get("quantum_address") != intent["payout"]["address"] or
                raw.get("vsize") != EXPECTED_VSIZE):
            die("QQP3 RPC response shape or estimated size differs")
        parsed = parse_transaction(raw["hex"], intent)
        if (raw["txid"] != parsed["txid"] or raw["proof"] != parsed["proof_hex"] or
                original.decimal_amount(raw["fee"], "QQP3 fee") != FEE_CAP or
                original.decimal_amount(raw["change"], "QQP3 change") != parsed["change"]):
            die("QQP3 RPC response differs from independent raw transaction proof")
        decoded = transport.rpc(node, "decoderawtransaction", raw["hex"])
        if decoded.get("txid") != parsed["txid"] or decoded.get("vsize") != parsed["actual_vsize"]:
            die("QQP3 decoder differs from independent serialized identity/size")
        member, change = parsed["member"], parsed["change"]
        return {"identity": {"txid": parsed["txid"], "hex": raw["hex"],
                             "hex_sha256": hashlib.sha256(bytes.fromhex(raw["hex"])).hexdigest()},
                "input": {**{key: member[key] for key in ["txid", "vout", "amount", "scriptPubKey", "address"]},
                          "audited_set_sha256": intent["fee_input"]["members_sha256"]},
                "output": {"n": 0, "amount": f"{change:.8f}", "scriptPubKey": intent["fee_input"]["scriptPubKey"]},
                "proof_output": {"n": 1, "amount": "0.00000000",
                                 "scriptPubKey": original.op_return_script(raw["proof"]),
                                 "script_asm": "OP_RETURN "+raw["proof"]},
                "proof": parsed["proof"],
                "fee": {"input_amount": member["amount"], "signed_output_amount": f"{change:.8f}",
                        "actual_fee_blk": f"{FEE_CAP:.8f}", "maximum_fee_blk": f"{FEE_CAP:.8f}",
                        "fee_rate_atoms_per_vbyte": 100, "vsize": EXPECTED_VSIZE, "independently_computed": True},
                "payout": intent["payout"], "external_proof": False}

    old_validate = ns["validate_transaction_receipt"]
    def validate_evidence(value, intent, label):
        result = old_validate(value, intent, label)
        parsed = parse_transaction(result["identity"]["hex"], intent)
        if parsed["txid"] != result["identity"]["txid"] or parsed["proof"] != result["proof"]:
            die("QQP3 receipt raw identity/proof differs")
        return result

    def candidate_response(tx):
        raw = original.candidate_response_from_gettransaction(tx)
        if raw is None:
            return None
        actual = len(bytes.fromhex(raw["hex"]))
        if raw["vsize"] != actual or not 261 <= actual <= EXPECTED_VSIZE:
            return None
        # This is a reconstructed candidate, not an RPC acknowledgment. Its
        # fee shape uses the independently known maximum estimate; raw bytes
        # and actual decoded size are independently re-proved by signed_evidence.
        raw["vsize"] = EXPECTED_VSIZE
        return raw

    def terminal_payout(history, transaction, blockhash, blockheight, intent):
        if (not isinstance(history, dict) or history.get("schema") != "blackcoin.shadow.script.v1" or
                history.get("scriptPubKey") != transaction["payout"]["scriptPubKey"] or
                history.get("address") != transaction["payout"]["address"] or
                history.get("synthetic") is not True or history.get("merkle_included") is not False or
                not isinstance(history.get("records"), list)):
            die("QQP3 indexed payout history is unavailable or malformed")
        matches = [row for row in history["records"] if isinstance(row, dict) and
                   isinstance(row.get("pow_claim_source"), dict) and
                   row["pow_claim_source"].get("txid") == transaction["identity"]["txid"]]
        if len(matches) != 1:
            die("QQP3 claim does not have one exact indexed synthetic payout")
        row, source = matches[0], matches[0]["pow_claim_source"]
        age = blockheight - intent["work"]["height"]
        disposition = source.get("disposition")
        if (row.get("synthetic") is not True or row.get("merkle_included") is not False or
                row.get("mode") != "pow" or row.get("scriptPubKey") != transaction["payout"]["scriptPubKey"] or
                row.get("address") != transaction["payout"]["address"] or
                row.get("base_anchor", {}).get("blockhash") != blockhash or
                row.get("base_anchor", {}).get("height") != blockheight or
                disposition not in {"winner", "reimbursed_loser", "reimbursed_late"} or
                source.get("vout") != 1 or source.get("base_fee_known") is not True or
                original.decimal_amount(source.get("base_fee"), "indexed QQP3 base fee") != FEE_CAP or
                source.get("proof_version") != 3 or source.get("origin_bound") is not True or
                source.get("origin_height") != intent["work"]["height"] or
                source.get("origin_previous_block_hash") != intent["work"]["prevhash"] or
                source.get("inclusion_height") != blockheight or source.get("origin_age") != age or
                not 0 <= age <= 64 or (disposition == "reimbursed_late") != (age > 0) or
                source.get("input_bound") is not False or source.get("claim_outpoint") is not None):
            die("indexed payout does not prove the exact credited origin-bound QQP3 claim")
        if original.decimal_amount(row.get("nominal_amount"), "QQP3 credited amount") <= 0:
            die("QQP3 indexed payout has no positive credited amount")
        return row

    ns.update(work_non_tip_fields_exact=work_exact, parse_qqp2_proof=parse_proof,
              validate_controller_runtime=validate_controller_runtime,
              fee_input_inventory=fee_inventory,
              signed_transaction_evidence=signed_evidence, validate_transaction_receipt=validate_evidence,
              terminal_payout=terminal_payout, parse_raw_claim=parse_transaction,
              candidate_response_from_gettransaction=candidate_response,
              stable_live_snapshot=stable_snapshot)
    return module


def mempool_inventory(transport, node, legacy):
    for attempt in range(1, 4):
        before = legacy.node30.base.validate_chain(transport.rpc(node, "getblockchaininfo"), 30)
        if not active_regime(transport.rpc(node, "getgoldrushinfo")):
            legacy.die("node30 is not in the QQP3 64-proof mempool regime")
        txids = transport.rpc(node, "getrawmempool", False)
        if (not isinstance(txids, list) or len(txids) != len(set(txids)) or
                any(not isinstance(t, str) or not re.fullmatch(r"[0-9a-f]{64}", t) for t in txids)):
            legacy.die("QQP3 raw mempool identity is malformed")
        proofs = []
        for txid in sorted(txids):
            tx = transport.rpc(node, "getrawtransaction", txid, True)
            if not isinstance(tx, dict) or tx.get("txid") != txid or not isinstance(tx.get("vout"), list):
                legacy.die("QQP3 mempool transaction projection is malformed")
            found = False
            for output in tx["vout"]:
                script = output.get("scriptPubKey", {}) if isinstance(output, dict) else {}
                asm = script.get("asm", "")
                if not isinstance(asm, str) or not asm.startswith("OP_RETURN 51515350524f4f46"):
                    continue
                proof = asm[len("OP_RETURN "):]
                if (not re.fullmatch(r"[0-9a-f]+", proof) or len(proof)%2 or
                        script.get("type") != "nulldata" or script.get("hex") != legacy.op_return_script(proof)):
                    legacy.die("mempool QQSPROOF carrier is not canonical")
                found = True
            if found:
                proofs.append(txid)
        after_ids = transport.rpc(node, "getrawmempool", False)
        after = legacy.node30.base.validate_chain(transport.rpc(node, "getblockchaininfo"), 30)
        if txids != after_ids or legacy.node30.base.chain_identity(before) != legacy.node30.base.chain_identity(after):
            continue
        if len(proofs) > MEMPOOL_LIMIT:
            legacy.die("QQP3 mempool proof count exceeds installed capacity")
        available = len(proofs) < MEMPOOL_LIMIT
        return {"chain": {"height": after["blocks"], "tip": after["bestblockhash"]},
                "mempool_txids": sorted(txids), "mempool_txids_sha256": legacy.sha256_json(sorted(txids)),
                "mempool_transaction_count": len(txids), "shadow_proof_txids": proofs,
                "shadow_proof_txids_sha256": legacy.sha256_json(proofs), "shadow_proof_count": len(proofs),
                "shadow_proof_limit": MEMPOOL_LIMIT, "slot_clear": available,
                "capacity_available": available, "available_proof_slots": MEMPOOL_LIMIT-len(proofs),
                "proof_version": 3, "snapshot_attempts": attempt}
    legacy.die("QQP3 mempool identity moved throughout bounded attempts")
