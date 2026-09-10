#!/usr/bin/env python3
"""Offline command roundtrips with real receipts, templates and QQP3 byte proof.

Source/runtime/RPC observations and queue I/O boundary are mocked. No live calls.
Receipt publishers/loaders, authority equality, intent/completion validators,
raw signed-transaction parsing, synthetic payout checks and awarded ledger run.
"""
import argparse
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("qqp3_flow_edge", ROOT / "node30_free_claim_edge_one_shot.py")
edge = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = edge
spec.loader.exec_module(edge)
d, legacy = edge.durable, edge.legacy
spec = importlib.util.spec_from_file_location("qqp3_flow_fixture", ROOT / "tests" / "qqp3_unit.py")
fixture_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture_module)


class Flow(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.root.chmod(0o700)
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
        self.fixture = fixture_module.ProtocolTests()
        self.fixture.setUp()
        self.calls, self.count, self.unknown = 0, 1, False
        self.node = types.SimpleNamespace(index=30)
        self.runtime = {"node": 30}
        self.role = {"wallet_inventory": {"unnamed": True}, "ordinary_pow": {"enabled": False},
                     "pos": {"staking": True}, "recovery": {"blocking_quarantined_claims": 0}}
        self.queue = self.root / "queue"
        self.done = self.root / "done"
        self.queue.mkdir(mode=0o700)
        self.done.mkdir(mode=0o700)
        self.manifest = self.root / "manifest.json"
        self.manifest.write_text("{}\n")
        self.manifest.chmod(0o600)
        self.awarded = self.root / "awarded.txt"
        self.awarded.write_text("")
        self.awarded.chmod(0o640)
        self.contract = types.SimpleNamespace(path=self.manifest, sha256=hashlib.sha256(self.manifest.read_bytes()).hexdigest(),
            queue_dir=self.queue, done_dir=self.done, awarded_file=self.awarded, pool_group_gid=os.getegid(),
            retained=types.SimpleNamespace(runtime=types.SimpleNamespace(nodes=[self.node])))
        self.patch(legacy, "test_mode", return_value=True)
        self.patch(d.pinned.legacy, "test_mode", return_value=True)
        path = self.queue / "20260909T000000Z-12345678.json"
        path.write_text(json.dumps({"attempts":1,"ip":"offline","submitted":"fixture",
                                   "quantum_address":self.fixture.intent["payout"]["address"]}))
        path.chmod(0o644)
        item, _ = d.queue_file_snapshot(path, self.contract, "offline ingress")
        self.state, self.state_path = "queued", path
        names = {"queued":path.name, "broadcast":path.stem+".broadcast.json",
                 "uncertain":path.stem+".uncertain.json", "confirmed":path.stem+".confirmed.json"}
        self.queue_snapshot = {"item":item,"ingress_items":[item],"preserved_done":[],
            "queue_directory":{},"done_directory":{},"awarded":legacy.awarded_snapshot(self.contract),
            "outcome_names":names}
        self.selected = {"state":"queued","path":str(path),"item":item,
                         "ingress_items":[item],"preserved_done":[]}
        self.fee = copy.deepcopy(self.fixture.intent["fee_input"])
        for member in self.fee["members"]:
            member.update(confirmations=100,coin={"confirmations":100,"value":member["amount"],
                                                 "scriptPubKey":member["scriptPubKey"]})
        self.fee["members_sha256"] = legacy.sha256_json(self.fee["members"])
        self.fee.update(eligible_wallet_candidate_count=1,eligible_address_script_group_count=1,core_exact_outpoint_prebound=False)
        self.work = {"active":True,**self.fixture.intent["work"],"target_bits":0x1f00ffff,
            "prefix":"51515350524f4f46","proof_mode":"pow","proof_mode_byte":0,"proof_version":3,
            "claim_outpoint_required":False,"qqp4_active_next_block":False,
            "target_script":self.fee["scriptPubKey"],"quantum_address":self.fixture.intent["payout"]["address"],
            "quantum_payout_script":self.fixture.intent["payout"]["scriptPubKey"],"claim_txid":None,"claim_vout":None}
        self.chain = {"height":self.work["height"]-1,"tip":self.work["prevhash"]}
        self.snapshot = {"chain":self.chain,"role":self.role,"queue":self.queue_snapshot,
            "payout":self.fixture.intent["payout"],"fee_input":self.fee,"work":self.work,
            "snapshot_attempts":1,"wallet_txids_before":[],"wallet_txids_before_sha256":legacy.sha256_json([])}
        self.source_audit = {"snapshot":{"queue":{"item":item,"outcome_names":names},"role":self.role}}
        source = {"source_run":str(self.root / "source"),"source_authority":str(self.root / "source" / "AUTHORITY.json"),
                  "authority_sha256":"a"*64}
        self.source_values = (self.contract,self.source_audit,"1"*64,{},"2"*64,{},"3"*64,{},"4"*64,source,"5"*64)
        self.observers = {"runtime_identities":[{"node":31},{"node":32}],
                          "observers":[{"runtime":{"node":31}},{"runtime":{"node":32}}]}
        self.patch(d.pinned,"base_receipt",side_effect=lambda kind,contract:{"kind":kind,"runtime_manifest_sha256":contract.sha256})
        self.patch(d,"source_chain",return_value=self.source_values)
        self.patch(legacy,"load_contract",return_value=self.contract)
        self.patch(legacy.node30,"wallet_inventory_identity",side_effect=lambda value,*args:value)
        self.patch(legacy.node30,"same_wallet_inventory",side_effect=lambda before,after,*args:self.assertEqual(before,after))
        self.patch(legacy.node30,"mutation_locks",side_effect=lambda *args:contextlib.nullcontext(["offline-lock"]))
        self.patch(legacy.node30,"free_claim_snapshot",return_value={"paused":True})
        self.patch(legacy.node30,"pin_node",return_value=(self.node,self.runtime))
        self.patch(legacy.node30,"role_snapshot",return_value=self.role)
        self.patch(d,"Transport",return_value=self)
        self.patch(edge,"Transport",return_value=self)
        self.patch(d,"durable_snapshot",side_effect=lambda *args:{"role":self.role,"source_rejected":self.selected,
            "queue":self.selected,"queue_strategy":"preserve_existing_queued_item","payout":self.fixture.intent["payout"],
            "fee_input":self.fee,"mempool_observation":self.mempool(),"candidate_count":0})
        self.patch(d,"current_selected_queue",return_value=self.selected)
        self.patch(d,"stable_live_snapshot",return_value=self.snapshot)
        self.patch(d.qqp3,"mempool_inventory",side_effect=lambda *args:self.mempool())
        self.patch(edge,"edge_rebind",side_effect=lambda *args:{**self.snapshot,"mempool_clearance":self.mempool(),
                                                              "wallet_inventory":self.role["wallet_inventory"]})
        self.patch(d,"transition_queue",side_effect=self.transition)
        self.patch(d,"current_queue_state",side_effect=lambda *args:(self.state,self.state_path))
        self.patch(edge.observer,"audit_observers",return_value=self.observers)
        self.patch(edge.observer,"observe_payout",side_effect=self.observe)
        self.patch(legacy,"reconcile_candidates",side_effect=self.candidates)

    def patch(self, target, name, **kwargs):
        return self.stack.enter_context(mock.patch.object(target,name,**kwargs))

    def runtime_snapshot(self,*args):
        return self.runtime

    def mempool(self):
        return {"chain":self.chain,"shadow_proof_count":self.count,"shadow_proof_limit":64,
                "slot_clear":self.count<64,"capacity_available":self.count<64}

    def rpc(self,node,method,*args):
        if method == "sendshadowpowclaim":
            self.calls += 1
            if self.unknown:
                raise edge.GateError("offline lost response after simulated persistence")
            return self.fixture.raw_response()
        if method == "decoderawtransaction":
            data=bytes.fromhex(args[0])
            return {"txid":hashlib.sha256(hashlib.sha256(data).digest()).digest()[::-1].hex(),"vsize":len(data)}
        if method == "gettransaction":
            return {"txid":self.fixture.tx["txid"],"hex":self.fixture.tx["hex"],"fee":"-0.00032300",
                    "decoded":self.fixture.tx,"confirmations":1,"blockhash":"bb"*32}
        if method == "getblockheader":
            return {"hash":"bb"*32,"height":self.work["height"],"confirmations":1}
        raise AssertionError("unexpected offline RPC "+method)

    def candidates(self,transport,node,intent):
        return [legacy.signed_transaction_evidence(self,node,self.fixture.raw_response(),intent)]

    def observe(self,*args):
        history,_=self.fixture.history()
        return {"result":"DUAL_INDEX_ACTIVE_CHAIN_QQP3_PAYOUT","read_only":True,
                "history":history,"record":history["records"][0],"observers":self.observers["observers"]}

    def transition(self,contract,audit,state):
        target=contract.done_dir/audit["snapshot"]["queue"]["outcome_names"][state]
        if target != self.state_path:
            os.rename(self.state_path,target)
        self.state,self.state_path=state,target
        item=self.queue_snapshot["item"]
        return {"state":state,"path":str(target),"sha256":item["sha256"],
                "device":item["device"],"inode":item["inode"],"atomic_rename":True}

    def authorize(self,run,name):
        audit,digest=legacy.node30.load_run_receipt(run,name)
        auth=copy.deepcopy(audit["required_authority"])
        auth.update(decision="authorize",audit_receipt_sha256=digest)
        authsha=legacy.node30.publish_json(run/"AUTHORITY.json",auth)
        return argparse.Namespace(run_dir=str(run),authority=str(run/"AUTHORITY.json"),authority_sha256=authsha)

    def prepare(self):
        self.drun,self.erun=self.root/"durable",self.root/"edge"
        d.audit_command(argparse.Namespace(run_dir=str(self.drun),reconcile_receipt="offline-reconcile.json"))
        audit,_=d.load_audit(self.drun,self.contract)
        self.assertEqual(audit["required_authority"]["shadow_proof_limit"],64)
        da=self.authorize(self.drun,"durable-requeue-audit.json")
        d.requeue_command(da)
        d.requeue_command(da)
        edge.audit_command(argparse.Namespace(durable_run=str(self.drun),durable_authority=da.authority,
            durable_authority_sha256=da.authority_sha256,run_dir=str(self.erun),max_wait_seconds=1,poll_milliseconds=50))
        audit,_=edge.load_audit(self.erun,self.contract)
        self.assertEqual(audit["required_authority"]["maximum_fee_blk"],"0.00032300")
        return self.authorize(self.erun,"edge-audit.json")

    def roundtrip(self):
        args=self.prepare()
        if self.unknown:
            with self.assertRaises(edge.GateError): edge.execute_command(args)
        else:
            edge.execute_command(args)
        edge.reconcile_command(args)
        edge.monitor_command(args)
        edge.monitor_command(args)
        terminal,_=legacy.node30.load_run_receipt(self.erun,"terminal.json")
        self.assertEqual(terminal["result"],"CONFIRMED_DYNAMIC_EDGE_QUANTUM_PAYOUT")
        self.assertEqual(self.calls,1)
        self.assertEqual(self.state,"confirmed")
        with self.assertRaises(edge.GateError): edge.execute_command(args)

    def test_roundtrip_with_one_other_proof(self):
        self.roundtrip()

    def test_roundtrip_at_last_available_capacity(self):
        self.count=63
        self.roundtrip()

    def test_unknown_response_reconciles_without_second_call(self):
        self.unknown=True
        self.roundtrip()

    def test_full_capacity_audits_but_aborts_without_call(self):
        self.count=64
        args=self.prepare()
        edge.execute_command(args)
        self.assertEqual(self.calls,0)
        self.assertFalse((self.erun/"intent.json").exists())
        self.assertTrue((self.erun/"edge-aborted.json").exists())


if __name__=="__main__":
    unittest.main()
