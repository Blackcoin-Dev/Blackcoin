#!/usr/bin/env python3
# Copyright (c) 2022 The Bitcoin Core developers
# Copyright (c) 2022 Blackcoin Core Developers
# Copyright (c) 2022 Blackcoin More Developers
# Copyright (c) 2022 Blackcoin Developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Test logic for setting -maxtipage on command line.

Nodes don't consider themselves out of "initial block download" as long as
their best known block header time is more than -maxtipage in the past.
"""

import time

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_raises_rpc_error


DEFAULT_MAX_TIP_AGE = 24 * 60 * 60
RECOVERY_IBD_ERROR = (
    "Gold Rush PoW claim recovery is unavailable while the node is "
    "reindexing, importing blocks, or in initial block download"
)
RECOVERY_WALLET = "ibd_recovery"


class MaxTipAgeTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.setup_clean_chain = True
        self.num_nodes = 2

    def assert_recovery_fails_closed_during_ibd(self, node):
        wallet = node.get_wallet_rpc(RECOVERY_WALLET)
        node.syncwithvalidationinterfacequeue()

        transactions_before = wallet.listtransactions("*", 1000, 0, True)
        recovery_before = wallet.getpowclaimrecoveryinfo(True)
        assert_equal(transactions_before, [])
        assert_equal(recovery_before["chain_ready"], False)

        assert_raises_rpc_error(
            -10,
            RECOVERY_IBD_ERROR,
            wallet.resolveallshadowpowclaims,
        )

        assert_equal(wallet.listtransactions("*", 1000, 0, True), transactions_before)
        assert_equal(wallet.getpowclaimrecoveryinfo(True), recovery_before)

    def test_maxtipage(self, maxtipage, set_parameter=True, test_deltas=True):
        node_miner = self.nodes[0]
        node_ibd = self.nodes[1]

        self.restart_node(1, [f'-maxtipage={maxtipage}'] if set_parameter else None)
        self.connect_nodes(0, 1)
        cur_time = int(time.time())

        if test_deltas:
            # tips older than maximum age -> stay in IBD
            node_ibd.setmocktime(cur_time)
            for delta in [5, 4, 3, 2, 1]:
                node_miner.setmocktime(cur_time - maxtipage - delta)
                self.generate(node_miner, 1)
                assert_equal(node_ibd.getblockchaininfo()['initialblockdownload'], True)
                self.assert_recovery_fails_closed_during_ibd(node_ibd)

        # tip within maximum age -> leave IBD
        node_miner.setmocktime(max(cur_time - maxtipage, 0))
        self.generate(node_miner, 1)
        assert_equal(node_ibd.getblockchaininfo()['initialblockdownload'], False)
        node_ibd.syncwithvalidationinterfacequeue()
        recovery_wallet = node_ibd.get_wallet_rpc(RECOVERY_WALLET)
        assert_equal(recovery_wallet.getpowclaimrecoveryinfo()["chain_ready"], True)
        assert_equal(recovery_wallet.listtransactions("*", 1000, 0, True), [])

    def run_test(self):
        self.nodes[1].createwallet(
            wallet_name=RECOVERY_WALLET,
            blank=True,
            load_on_startup=True,
        )

        self.log.info("Test IBD with maximum tip age of 24 hours (default).")
        self.test_maxtipage(DEFAULT_MAX_TIP_AGE, set_parameter=False)

        for hours in [20, 10, 5, 2, 1]:
            maxtipage = hours * 60 * 60
            self.log.info(f"Test IBD with maximum tip age of {hours} hours (-maxtipage={maxtipage}).")
            self.test_maxtipage(maxtipage)

        max_long_val = 9223372036854775807
        self.log.info(f"Test IBD with highest allowable maximum tip age ({max_long_val}).")
        self.test_maxtipage(max_long_val, test_deltas=False)


if __name__ == '__main__':
    MaxTipAgeTest().main()
