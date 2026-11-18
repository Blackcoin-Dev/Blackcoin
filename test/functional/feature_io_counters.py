#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Test the slow-disk measuring tools: getiocounters and the test delay options.

A node on a spinning disk stalls because of how many chainstate lookups and
wallet database syncs it does, not because of what they compute. The hidden
getiocounters RPC reports those counts, the regtest-only -testdbreaddelayus
and -testwalletsyncdelayus options reproduce a slow disk on a fast one, and
-testrecordreadkeys records the keys read so a test can check their order.

This test checks that the counters count exactly, that the options work and
are refused where they must be, and that the node serves its wallet with the
delays on. The gates that use these tools to hold other behaviour to account
are in wallet_io_gates.py.
"""

from test_framework.blocktools import COINBASE_MATURITY
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_raises_rpc_error

COUNTER_NAMES = [
    "chainstate_get_coin",
    "chainstate_have_coin",
    "db_reads",
    "db_exists",
    "wallet_commits",
    "wallet_commits_in_handler",
]


class IoCountersTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.extra_args = [["-testrecordreadkeys=1", "-testdbreaddelayus=50", "-testwalletsyncdelayus=50"]]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def counters(self, *args):
        return self.nodes[0].getiocounters(*args)

    def run_test(self):
        node = self.nodes[0]

        self.log.info("The RPC is hidden, takes no wallet and reports every counter")
        assert "getiocounters" not in node.help()
        first = self.counters()
        for name in COUNTER_NAMES + ["recorded_keys", "recorded_coin_keys", "recorded_coin_key_inversions"]:
            assert name in first, name
        assert_raises_rpc_error(-8, "recorder_start must not be negative", node.getiocounters, -1)

        self.log.info("Counters only grow, wallet commits appear as blocks connect to the wallet")
        self.generate(node, COINBASE_MATURITY + 5)
        node.syncwithvalidationinterfacequeue()
        second = self.counters()
        for name in COUNTER_NAMES:
            assert second[name] >= first[name], name
        assert second["db_reads"] > first["db_reads"]
        assert second["wallet_commits"] > first["wallet_commits"]
        assert second["wallet_commits_in_handler"] > first["wallet_commits_in_handler"]
        assert second["recorded_keys"] > first["recorded_keys"]

        self.log.info("A known sequence of chainstate lookups is counted exactly after a restart")
        utxos = node.listunspent()
        assert len(utxos) >= 5
        self.restart_node(0, self.extra_args[0] + ["-autostartstaking=0"])
        node = self.nodes[0]
        before = self.counters()
        for utxo in utxos[:5]:
            assert node.gettxout(utxo["txid"], utxo["vout"]) is not None
        after = self.counters()
        assert_equal(after["chainstate_get_coin"] - before["chainstate_get_coin"], 5)
        assert_equal(after["chainstate_have_coin"] - before["chainstate_have_coin"], 0)
        # The lookups went through the recorder as coin keys, one each.
        recorded = self.counters(0, True)
        assert_equal(len(set(recorded["recorded_coin_txids"]) & {u["txid"] for u in utxos[:5]}), len({u["txid"] for u in utxos[:5]}))

        self.log.info("The delay options and the recorder can be off")
        self.restart_node(0, ["-autostartstaking=0"])
        before = self.counters()
        assert_equal(before["recorded_keys"], 0)
        node.gettxout(utxos[0]["txid"], utxos[0]["vout"])
        assert_equal(self.counters()["recorded_keys"], 0)
        assert_equal(self.counters()["chainstate_get_coin"] - before["chainstate_get_coin"], 1)

        self.log.info("The options are refused out of range")
        self.stop_node(0)
        node.assert_start_raises_init_error(["-testdbreaddelayus=1000001"], "Error: -testdbreaddelayus must be between 0 and 1000000 microseconds.")
        node.assert_start_raises_init_error(["-testwalletsyncdelayus=-1"], "Error: -testwalletsyncdelayus must be between 0 and 1000000 microseconds.")


if __name__ == "__main__":
    IoCountersTest().main()
