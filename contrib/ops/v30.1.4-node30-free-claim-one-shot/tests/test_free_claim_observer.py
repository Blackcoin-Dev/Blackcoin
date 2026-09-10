import copy
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("observer", Path(__file__).parents[1] / "node30_free_claim_observer.py")
o = importlib.util.module_from_spec(spec)
spec.loader.exec_module(o)
SCRIPT = "6020" + "1" * 64
TXID = "2" * 64
BLOCK = "3" * 64
PARENT = "4" * 64
TIP = "5" * 64
HEIGHT = 6026400


def record():
    return {"synthetic": True, "synthetic_txid": "6" * 64, "vout": 0, "mode": "pow", "nominal_amount": "0.00032300", "scriptPubKey": SCRIPT, "base_anchor": {"height": HEIGHT, "blockhash": BLOCK}, "pow_claim_source": {"txid": TXID, "vout": 1, "base_fee_known": True, "base_fee": "0.00032300", "proof_version": 3, "origin_bound": True, "origin_height": HEIGHT, "origin_previous_block_hash": PARENT, "inclusion_height": HEIGHT, "origin_age": 0, "input_bound": False, "claim_outpoint": None, "disposition": "reimbursed_loser"}}


class Transport:
    def __init__(self):
        self.calls = []
        self.bad_image = False
        self.disabled_index = False
        self.fork = False
        self.mismatch = False
        self.missing = False
        self.paginate = False
        self.stuck_cursor = False

    def rpc(self, node, method, *args):
        return self.data("node30", method, args)

    def data(self, container, method, args):
        if method == "getblockchaininfo":
            return {"chain": "main", "initialblockdownload": False, "blocks": HEIGHT + 5, "headers": HEIGHT + 5, "bestblockhash": TIP}
        if method == "getblockhash":
            height = int(args[0])
            if height == HEIGHT:
                return "7" * 64 if self.fork else BLOCK
            return PARENT if height == HEIGHT - 1 else TIP
        if method == "getindexinfo":
            return {} if self.disabled_index else {"shadowindex": {"synced": True, "best_block_height": HEIGHT + 5}}
        if method == "getshadowscript":
            r = record()
            if self.mismatch and container == o.CONTAINERS[1]:
                r["nominal_amount"] = "0.00032400"
            cursor = (int(args[1]), args[2])
            first = cursor == (HEIGHT - 1, "0" * 64)
            empty = self.missing or (self.paginate and first) or self.stuck_cursor
            next_cursor = None
            if self.paginate and first:
                next_cursor = {"height": HEIGHT - 1, "txid": "8" * 64}
            if self.stuck_cursor:
                next_cursor = {"height": cursor[0], "txid": cursor[1]}
            return {"schema": "blackcoin.shadow.script.v1", "height": HEIGHT + 5, "bestblock": TIP, "scriptPubKey": SCRIPT, "synthetic": True, "merkle_included": False, "records": [] if empty else [r], "count": 0 if empty else 1, "next_cursor": next_cursor}
        raise AssertionError(method)

    def run(self, args, timeout):
        self.calls.append(args)
        if args[0] == "inspect":
            return json.dumps([{"Name": "/" + args[1], "Image": "bad" if self.bad_image else o.IMAGE, "Id": "9" * 64, "State": {"Running": True, "Health": {"Status": "healthy"}, "StartedAt": "2026-09-01T00:00:00Z"}, "Config": {"Entrypoint": ["/usr/local/bin/blackcoind"], "Cmd": o.COMMAND}, "HostConfig": {"NetworkMode": "bridge"}, "Mounts": []}])
        assert args[:1] == ["exec"]
        value = self.data(args[1], args[4], args[5:])
        return value if args[4] == "getblockhash" else json.dumps(value)


class ObserverTests(unittest.TestCase):
    def setUp(self):
        self.transport = Transport()
        self.audit = o.audit_observers(self.transport, None)

    def observe(self):
        return o.observe_payout(self.transport, None, self.audit, SCRIPT, TXID, 1, HEIGHT, BLOCK)

    def test_two_observers_exact_credit(self):
        value = self.observe()
        self.assertEqual(len(value["observers"]), 2)
        self.assertEqual(value["history"]["records"], [record()])
        self.assertEqual(len(self.audit["runtime_identities"]), 64)

    def test_only_readonly_methods(self):
        self.observe()
        for call in self.transport.calls:
            self.assertIn(call[0], {"inspect", "exec"})
            if call[0] == "exec":
                self.assertIn(call[4], o.ALLOWED)

    def test_bounded_pagination_finds_record(self):
        self.transport.paginate = True
        self.assertEqual(len(self.observe()["observers"][0]["pages"]), 2)

    def test_stuck_cursor_rejected(self):
        self.transport.stuck_cursor = True
        with self.assertRaises(o.ObserverError):
            self.observe()

    def test_changed_runtime_rejected(self):
        self.transport.bad_image = True
        with self.assertRaises(o.ObserverError):
            self.observe()

    def test_disabled_index_rejected(self):
        self.transport.disabled_index = True
        with self.assertRaises(o.ObserverError):
            o.audit_observers(self.transport, None)

    def test_fork_rejected(self):
        self.transport.fork = True
        with self.assertRaises(o.ObserverError):
            self.observe()

    def test_disagreement_rejected(self):
        self.transport.mismatch = True
        with self.assertRaises(o.ObserverError):
            self.observe()

    def test_missing_credit_rejected(self):
        self.transport.missing = True
        with self.assertRaises(o.ObserverError):
            self.observe()


if __name__ == "__main__":
    unittest.main()
