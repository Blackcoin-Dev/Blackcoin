#!/usr/bin/env python3
"""Offline QQP3 public-chain fixture and protocol-boundary regression tests."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

legacy = load("qqp3_fixture_original", "node30_free_claim_one_shot.py")
protocol = load("qqp3_fixture_adapter", "node30_free_claim_qqp3.py")
adapter = protocol.build_legacy(legacy, lambda _: None)
fixture = json.loads(Path(__file__).with_name("qqp3-mainnet-fixture.json").read_text())


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.tx, self.spent = copy.deepcopy(fixture["transaction"]), fixture["spent_output"]
        self.proof = bytes.fromhex(self.tx["vout"][1]["scriptPubKey"]["hex"])[3:]
        payload = self.proof[8:]
        target, address = self.spent["scriptPubKey"]["hex"], self.spent["scriptPubKey"]["address"]
        member = dict(txid=self.tx["vin"][0]["txid"], vout=self.tx["vin"][0]["vout"],
                      amount=f"{self.spent['value']:.8f}", scriptPubKey=target, address=address)
        self.intent = {"fee_input": dict(selection_contract="any-one-of-exact-audited-set/v1",
                                        members=[member], members_sha256=legacy.sha256_json([member]),
                                        address=address, scriptPubKey=target),
                       "payout": dict(scriptPubKey=payload[-34:].hex(), address="fixture-no-financial-authority"),
                       "work": dict(height=int.from_bytes(payload[13:17], "little"),
                                    prevhash=payload[17:49][::-1].hex())}

    def raw_response(self):
        return dict(txid=self.tx["txid"], hex=self.tx["hex"], proof=self.proof.hex(),
                    proof_mode="pow", proof_mode_byte=0, external_proof=False,
                    fee="0.00032300", change="0.07763800", vsize=323,
                    address=self.intent["fee_input"]["address"], quantum_address=self.intent["payout"]["address"])

    def evidence(self, raw=None):
        class Transport:
            def rpc(_, node, method, rawhex):
                self.assertEqual(method, "decoderawtransaction")
                data = bytes.fromhex(rawhex)
                return {"txid": hashlib.sha256(hashlib.sha256(data).digest()).digest()[::-1].hex(),
                        "vsize": len(data)}
        return adapter.signed_transaction_evidence(Transport(), None, raw or self.raw_response(), self.intent)

    def test_public_mainnet_signed_raw(self):
        parsed = adapter.parse_raw_claim(self.tx["hex"], self.intent)
        self.assertEqual((parsed["txid"], parsed["actual_vsize"]), (self.tx["txid"], 323))
        self.assertEqual(parsed["proof"]["origin_height"], 6026400)
        evidence = self.evidence()
        self.assertEqual(adapter.validate_transaction_receipt(evidence, self.intent, "fixture"), evidence)

    def test_origin_height_mismatch(self):
        self.intent["work"]["height"] += 1
        with self.assertRaises(legacy.GateError): adapter.parse_raw_claim(self.tx["hex"], self.intent)

    def test_origin_parent_mismatch(self):
        self.intent["work"]["prevhash"] = "11" * 32
        with self.assertRaises(legacy.GateError): adapter.parse_raw_claim(self.tx["hex"], self.intent)

    def test_fee_member_value_mismatch(self):
        self.intent["fee_input"]["members"][0]["amount"] = "0.07796200"
        self.intent["fee_input"]["members_sha256"] = legacy.sha256_json(self.intent["fee_input"]["members"])
        with self.assertRaises(legacy.GateError): adapter.parse_raw_claim(self.tx["hex"], self.intent)

    def test_trailing_bytes(self):
        with self.assertRaises(legacy.GateError): adapter.parse_raw_claim(self.tx["hex"]+"00", self.intent)

    def test_wrong_version(self):
        with self.assertRaises(legacy.GateError): adapter.parse_raw_claim("03"+self.tx["hex"][2:], self.intent)

    def test_wrong_pubkey(self):
        raw = bytearray.fromhex(self.tx["hex"])
        raw[42+raw[41]-1] ^= 1
        with self.assertRaises(legacy.GateError): adapter.parse_raw_claim(raw.hex(), self.intent)

    def test_short_der_shape_reconciles_and_validates(self):
        # Synthetic shorter DER tests serialization only, not ECDSA validity.
        data = bytes.fromhex(self.tx["hex"])
        script = data[42:42+data[41]]
        old_sig_size = script[0]
        pubpart = script[1+old_sig_size:]
        der = b"\x30\x43\x02\x1f" + b"\x01"*31 + b"\x02\x20" + b"\x01"*32
        signature = der + b"\x01"
        new_script = bytes([len(signature)])+signature+pubpart
        data = data[:41]+bytes([len(new_script)])+new_script+data[42+len(script):]
        self.assertEqual(len(data), 322)
        self.tx["hex"] = data.hex()
        self.tx["txid"] = hashlib.sha256(hashlib.sha256(data).digest()).digest()[::-1].hex()
        self.tx["vsize"] = len(data)
        evidence = self.evidence()
        adapter.validate_transaction_receipt(evidence, self.intent, "short shape")
        wallet = {"txid": self.tx["txid"], "hex": self.tx["hex"], "fee": "-0.00032300", "decoded": self.tx}
        candidate = adapter.candidate_response_from_gettransaction(wallet)
        self.assertEqual(candidate["vsize"], 323)
        candidate.update(address=self.intent["fee_input"]["address"], quantum_address=self.intent["payout"]["address"])
        self.assertEqual(self.evidence(candidate), evidence)

    def test_estimated_fee_not_actual_size_fee(self):
        raw = self.raw_response()
        raw["fee"] = "0.00032200"
        with self.assertRaises(legacy.GateError): self.evidence(raw)

    def history(self, disposition="winner", age=0):
        height = self.intent["work"]["height"] + age
        source = dict(txid=self.tx["txid"], vout=1, disposition=disposition, base_fee_known=True,
                      base_fee="0.00032300", proof_version=3, origin_bound=True,
                      origin_height=self.intent["work"]["height"],
                      origin_previous_block_hash=self.intent["work"]["prevhash"], inclusion_height=height,
                      origin_age=age, input_bound=False, claim_outpoint=None)
        row = dict(synthetic=True, merkle_included=False, mode="pow", **self.intent["payout"],
                   nominal_amount="0.00032300", base_anchor=dict(height=height, blockhash="bb"*32),
                   pow_claim_source=source)
        return dict(schema="blackcoin.shadow.script.v1", synthetic=True, merkle_included=False,
                    **self.intent["payout"], records=[row]), height

    def test_all_positive_dispositions(self):
        for disposition, age in [("winner",0), ("reimbursed_loser",0), ("reimbursed_late",1), ("reimbursed_late",64)]:
            history, height = self.history(disposition, age)
            adapter.terminal_payout(history, self.evidence(), "bb"*32, height, self.intent)

    def test_zero_credit_rejected(self):
        history, height = self.history()
        history["records"][0]["nominal_amount"] = "0"
        with self.assertRaises(legacy.GateError): adapter.terminal_payout(history, self.evidence(), "bb"*32, height, self.intent)

    def test_wrong_disposition_age_rejected(self):
        for disposition, age in [("winner",1), ("reimbursed_late",0), ("reimbursed_late",65), ("duplicate",0)]:
            history, height = self.history(disposition, age)
            with self.assertRaises(legacy.GateError): adapter.terminal_payout(history, self.evidence(), "bb"*32, height, self.intent)

    def test_qqp2_and_qqp4_proof_rejected(self):
        for magic in [b"QQP2", b"QQP4"]:
            proof = self.proof[:8]+magic+self.proof[12:]
            with self.assertRaises(legacy.GateError): adapter.parse_qqp2_proof(proof.hex(), self.intent["fee_input"]["scriptPubKey"], self.intent["payout"]["scriptPubKey"])

    def test_regime_qqp3_only(self):
        self.assertTrue(protocol.active_regime(dict(active=True, competing_claim_rule_active_next_block=True, qqp4_active_next_block=False)))
        self.assertFalse(protocol.active_regime(dict(active=True, competing_claim_rule_active_next_block=False, qqp4_active_next_block=False)))
        self.assertFalse(protocol.active_regime(dict(active=True, competing_claim_rule_active_next_block=True, qqp4_active_next_block=True)))

    def test_historical_adapter_keeps_qqp2_and_old_fee(self):
        self.assertEqual(legacy.EXPECTED_VSIZE, 287)
        self.assertEqual(str(legacy.FEE_CAP), "0.00028700")

    def test_actual_controller_identity_shared_with_historical_reader(self):
        identity = {"actually_validated_fixture": True}
        with mock.patch.object(legacy, "validate_controller_runtime", return_value=identity), \
                mock.patch.object(legacy, "CONTROLLER_RUNTIME_IDENTITY", None), \
                mock.patch.object(legacy, "test_mode", return_value=False):
            local = protocol.build_legacy(legacy, lambda _: None)
            self.assertEqual(local.validate_controller_runtime(), identity)
            self.assertIs(legacy.CONTROLLER_RUNTIME_IDENTITY, identity)
            self.assertIs(local.CONTROLLER_RUNTIME_IDENTITY, identity)
            self.assertEqual(local.controller_runtime_identity(), identity)

    def test_fee_preflight_requires_compressed_matching_pubkey(self):
        raw = bytes.fromhex(self.tx["hex"])
        script = raw[42:42+raw[41]]
        pubkey = script[-33:].hex()
        inventory = self.intent["fee_input"]
        with mock.patch.object(legacy, "fee_input_inventory", return_value=inventory):
            local = protocol.build_legacy(legacy, lambda _: None)
        class Transport:
            def rpc(_, node, method, address):
                self.assertEqual(method, "getaddressinfo")
                return {"pubkey": pubkey}
        self.assertEqual(local.fee_input_inventory(Transport(), None), inventory)
        for value in ["04"+"11"*64, "02"+"11"*32, None]:
            pubkey = value
            with self.assertRaises(legacy.GateError): local.fee_input_inventory(Transport(), None)

    def test_mempool_capacity_boundaries(self):
        for count in [0, 1, 63, 64, 65]:
            class Transport:
                def rpc(_, node, method, *args):
                    if method == "getblockchaininfo": return dict(chain="main",blocks=6026400,headers=6026400,bestblockhash="aa"*32,chainwork="ee"*32,initialblockdownload=False,pruned=False,warnings="")
                    if method == "getgoldrushinfo": return dict(active=True,competing_claim_rule_active_next_block=True,qqp4_active_next_block=False)
                    if method == "getrawmempool": return [f"{n+1:064x}" for n in range(count)]
                    if method == "getrawtransaction": return dict(txid=args[0],vout=[dict(scriptPubKey=self.tx["vout"][1]["scriptPubKey"])])
                    raise AssertionError(method)
            if count > 64:
                with self.assertRaises(legacy.GateError): protocol.mempool_inventory(Transport(), None, adapter)
            else:
                result = protocol.mempool_inventory(Transport(), None, adapter)
                self.assertEqual(result["shadow_proof_limit"], 64)
                self.assertEqual(result["slot_clear"], count < 64)


if __name__ == "__main__":
    unittest.main()
