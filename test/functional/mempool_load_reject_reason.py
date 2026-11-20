#!/usr/bin/env python3
# Copyright (c) 2026 Blackcoin Core Developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Test that a mempool load logs why transactions were rejected.

A mempool.dat holding transactions that the restarted node refuses (here a
higher -minrelaytxfee) must produce a one-line summary of the reasons by count
at the default log level, and one line per transaction under -debug=mempool.
"""

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal
from test_framework.wallet import MiniWallet


class MempoolLoadRejectReasonTest(BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1

    def run_test(self):
        node = self.nodes[0]
        wallet = MiniWallet(node)
        self.generate(wallet, 101)
        for _ in range(3):
            wallet.send_self_transfer(from_node=node)
        assert_equal(len(node.getrawmempool()), 3)

        self.log.info("Restart with a relay fee the transactions do not pay")
        self.restart_node(0)  # dumps the mempool on shutdown
        self.stop_node(0)
        with node.assert_debug_log(expected_msgs=[
            "Mempool load: 3 transactions rejected (min relay fee not met: 3)",
            "Imported mempool transactions from disk: 0 succeeded, 3 failed",
        ]):
            self.start_node(0, extra_args=["-minrelaytxfee=1"])
        assert_equal(len(node.getrawmempool()), 0)


if __name__ == '__main__':
    MempoolLoadRejectReasonTest().main()
