#!/usr/bin/env python3
# Copyright (c) 2026 Blackcoin Core Developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://opensource.org/license/mit/.
"""Isolated witness pagination measurements and immutable-output checks.

Run unchanged on baseline/candidate builds. Elapsed RPC times are observations,
not pass/fail thresholds. Output is written to the test's temporary directory.
All coins and keys are disposable regtest fixtures.
"""
import json
import time
from pathlib import Path
from threading import Thread

from test_framework.authproxy import JSONRPCException
from test_framework.blocktools import COINBASE_MATURITY
from test_framework.script import CScript, OP_2
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, get_rpc_proxy
from test_framework.wallet import MiniWallet


class WitnessInventoryPerformanceTest(BitcoinTestFramework):
    def add_options(self, parser):
        parser.add_argument("--inventory-counts", default="16,1000",
                            help="Increasing record counts, maximum 12000")
        parser.add_argument("--skip-scan-race", action="store_true",
                            help="Skip new candidate scan barrier on baseline builds")

    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.extra_args = [["-shadowwhitelistheight=1",
                            "-shadowgoldrushstartheight=1000000",
                            "-shadowgoldrushendheight=1000010",
                            "-qqgoldrushendheight=1000010",
                            "-qqmigrationendheight=1000100"]]

    def run_test(self):
        counts = [int(item) for item in self.options.inventory_counts.split(",")]
        assert counts and counts == sorted(set(counts))
        assert 1 <= counts[0] <= counts[-1] <= 12000
        node = self.nodes[0]
        wallet = MiniWallet(node)
        self.generate(wallet, COINBASE_MATURITY + 64)
        created = 0
        measurements = []
        for count in counts:
            transactions = []
            while created < count:
                batch_size = min(200, count - created)
                tx = wallet.create_self_transfer_multi(
                    num_outputs=batch_size, confirmed_only=True)
                for index, output in enumerate(tx["tx"].vout):
                    program = (created + index + 1).to_bytes(32, "little")
                    output.scriptPubKey = CScript([OP_2, program])
                transactions.append(tx["tx"].serialize().hex())
                created += batch_size
            # Unknown witness versions are consensus-valid before activation,
            # while mempool policy deliberately rejects premature outputs.
            block_hash = self.generateblock(node, wallet.get_address(), transactions)["hash"]
            stats = node.gettxoutsetinfo("muhash")
            pages = []
            expected_identity = None
            # Different offsets/counts have identical full-UTXO commitments.
            # The last request repeats an exact request to measure reuse, if
            # future bounded caching is implemented with the same contract.
            for offset, page_size in ((0, 1), (1, 1), (0, 1000), (0, 1)):
                begin = time.perf_counter()
                page = node.getquantumwitnessinventory("utxos", offset, page_size, 1)
                elapsed = time.perf_counter() - begin
                identity = (page["bestblock"], page["utxo_snapshot"]["commitment"],
                            page["utxo_snapshot"]["txouts"])
                if expected_identity is None:
                    expected_identity = identity
                assert_equal(identity, expected_identity)
                assert_equal(page["bestblock"], block_hash)
                assert_equal(page["utxo_snapshot"]["commitment"], stats["muhash"])
                assert_equal(page["utxo_snapshot"]["txouts"], stats["txouts"])
                assert_equal(page["total_records"], count)
                assert_equal(page["count"], min(page_size, max(0, count - offset)))
                assert_equal(page["coverage"]["snapshot_current_utxos_exact"], True)
                assert_equal(page["coverage"]["snapshot_tip_still_active"], True)
                pages.append({"offset": offset, "page_size": page_size,
                              "elapsed_ms": elapsed * 1000,
                              "returned_records": page["count"],
                              "snapshot_txouts": stats["txouts"]})
            measurements.append({"witness_records": count, "pages": pages})
            self.log.info("inventory benchmark: %s", measurements[-1])
            # Reorg away and back: the same RPC must follow current chain
            # state and restore the exact immutable UTXO commitment.
            node.invalidateblock(block_hash)
            rewound = node.getquantumwitnessinventory("utxos", 0, 1, 1)
            assert rewound["bestblock"] != block_hash
            assert_equal(rewound["total_records"], measurements[-2]["witness_records"]
                         if len(measurements) > 1 else 0)
            node.reconsiderblock(block_hash)
            restored = node.getquantumwitnessinventory("utxos", 0, 1, 1)
            assert_equal(restored["bestblock"], block_hash)
            assert_equal(restored["utxo_snapshot"]["commitment"], stats["muhash"])
        if not self.options.skip_scan_race:
            # Use the existing regtest-only race delay at the new pre-scan barrier.
            # The bound counts all UTXO rows, including coinbase outputs.
            # At 1000 witness records this fixture has more than 1024 rows.
            self.restart_node(0, extra_args=self.extra_args[0] + [
                "-shadowrpcsnapshotdelaymillis=1500"])
            log_offset = node.debug_log_size(encoding="utf-8")
            outcome = []

            def obsolete_scan():
                rpc = get_rpc_proxy(node.url, 100, timeout=30)
                try:
                    outcome.append(("result", rpc.getquantumwitnessinventory("utxos", 0, 1, 1)))
                except JSONRPCException as error:
                    outcome.append(("error", error.error))
                except Exception as error:
                    outcome.append(("exception", str(error)))

            caller = Thread(target=obsolete_scan, daemon=True)
            caller.start()

            def barrier_reached():
                with open(node.debug_log_path, encoding="utf-8", errors="replace") as debug_log:
                    debug_log.seek(log_offset)
                    return "rpc=getquantumwitnessinventory/scan " in debug_log.read()

            self.wait_until(barrier_reached)
            self.generate(wallet, 1)
            caller.join(timeout=30)
            assert not caller.is_alive()
            assert_equal(len(outcome), 1)
            assert_equal(outcome[0][0], "error")
            assert_equal(outcome[0][1]["code"], -1)
            assert "Active chain changed" in outcome[0][1]["message"]
            if stats["txouts"] >= 1024:
                with open(node.debug_log_path, encoding="utf-8", errors="replace") as debug_log:
                    debug_log.seek(log_offset)
                    assert "Witness inventory scan stopped at obsolete tip after 1023 coins" in debug_log.read()
        destination = Path(self.options.tmpdir) / "inventory-benchmark.json"
        destination.write_text(json.dumps({"schema": "blackcoin.witness_inventory.benchmark.v1",
                                           "measurements": measurements}, indent=2) + "\n")
        self.log.info("Inventory benchmark artifact: %s", destination)


if __name__ == '__main__':
    WitnessInventoryPerformanceTest().main()
