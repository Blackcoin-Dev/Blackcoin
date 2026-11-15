#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Test that the wallet's per-block payout writes change nothing the wallet reports.

A connected block that pays the wallet synthetic Gold Rush payouts is recorded
with its database writes grouped into one commit. Grouping must never change
the wallet's visible state, so every view is compared three ways: live after
each block, after a restart (rebuilt from the database alone), and across a
reorg of the last blocks and back. The in-memory state and the persisted state
must be identical at every point.
"""

import time

from test_framework.blocktools import COINBASE_MATURITY
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal

SHADOW_GOLD_RUSH_BLOCKS = 500
GOLD_RUSH_END_HEIGHT = 1 + SHADOW_GOLD_RUSH_BLOCKS
MIGRATION_END_HEIGHT = GOLD_RUSH_END_HEIGHT + 10
WALLET_NAME = "block_writes"
PAYOUT_BLOCKS = 6
REORG_DEPTH = 3


class WalletGoldRushBlockConnectWritesTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.node_args = [
            "-allowunsafequantumkeyrpc=1",
            "-txindex=1",
            "-staketimio=20",
            "-autostartstaking=0",
            "-qqautoshadowsignal=1",
            "-shadowwhitelistheight=1",
            f"-shadowgoldrushblocks={SHADOW_GOLD_RUSH_BLOCKS}",
            f"-qqgoldrushendheight={GOLD_RUSH_END_HEIGHT}",
            f"-qqmigrationendheight={MIGRATION_END_HEIGHT}",
        ]
        self.extra_args = [self.node_args]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def _set_mocktime(self, timestamp):
        self.mock_time = timestamp
        self.nodes[0].setmocktime(timestamp)

    def _mine_pos_block(self, wallet):
        node = self.nodes[0]
        inputs = [{"txid": utxo["txid"], "vout": utxo["vout"]} for utxo in wallet.listunspent(1, 9999999)]
        start_height = node.getblockcount()
        for _ in range(3000):
            self._set_mocktime(self.mock_time + 16)
            kernel = wallet.checkkernel(inputs)
            if kernel["found"]:
                kernel_time = kernel["kernel"]["time"]
                break
        else:
            raise AssertionError("timed out searching for a deterministic PoS kernel")
        self._set_mocktime(kernel_time - 16)
        wallet.staking(True)
        try:
            self._set_mocktime(kernel_time)
            self.wait_until(lambda: node.getblockcount() > start_height, timeout=30)
        finally:
            wallet.staking(False)
        # Block dispatch to the wallet is asynchronous; compare only at rest.
        node.syncwithvalidationinterfacequeue()

    def _snapshot(self, wallet):
        """Everything a user can see that the per-block writes could influence."""
        self.nodes[0].syncwithvalidationinterfacequeue()
        unspent = sorted(
            wallet.listunspent(0, 9999999, [], True, {"include_immature_coinbase": True}),
            key=lambda utxo: (utxo["txid"], utxo["vout"]))
        transactions = sorted(
            wallet.listtransactions("*", 100000, 0, True),
            key=lambda tx: (tx["txid"], tx["vout"], tx["category"]))
        goldrush = wallet.getgoldrushinfo()
        return {
            "balances": wallet.getbalances(),
            "walletinfo": {k: v for k, v in wallet.getwalletinfo().items() if k != "lastprocessedblock"},
            "unspent": unspent,
            "transactions": transactions,
            "pos_count": goldrush["pos_count"],
            "last_pos_height": goldrush["last_pos_height"],
        }

    @staticmethod
    def _payout_count(snapshot):
        return len([
            tx for tx in snapshot["transactions"]
            if tx.get("comment") == "PoS - Quantum Stake" and tx.get("confirmations", 0) > 0
        ])

    def _reload(self):
        """Restart the node so the wallet is rebuilt from its database only."""
        self.restart_node(0, self.node_args)
        self.nodes[0].loadwallet(WALLET_NAME)
        return self.nodes[0].get_wallet_rpc(WALLET_NAME)

    def run_test(self):
        node = self.nodes[0]
        self._set_mocktime((int(time.time()) & ~0xf) + 16)
        node.get_wallet_rpc(self.default_wallet_name).staking(False)
        node.createwallet(wallet_name=WALLET_NAME)
        wallet = node.get_wallet_rpc(WALLET_NAME)
        wallet.staking(False)
        signal_address = wallet.getnewaddress("", "legacy")

        self.log.info("Creating a whitelisted wallet that stakes into an active Gold Rush signal")
        self.generatetoaddress(node, 1, signal_address, sync_fun=self.no_op)
        self.generatetoaddress(node, COINBASE_MATURITY + 50, signal_address, sync_fun=self.no_op)
        self._set_mocktime((node.getblockheader(node.getbestblockhash())["time"] & ~0xf) + 16)
        wallet.getnewquantumaddress("goldrush-pos")

        self.log.info("Each connected block's payouts are recorded; live state equals the rebuilt state")
        live = []
        for _ in range(PAYOUT_BLOCKS + 1):
            self._mine_pos_block(wallet)
            live.append(self._snapshot(wallet))
        payouts = self._payout_count(live[-1])
        assert payouts >= PAYOUT_BLOCKS - 1, "wallet must hold the synthetic payouts under test"
        assert_equal(self._payout_count(live[-2]) + 1, payouts)
        wallet = self._reload()
        assert_equal(self._snapshot(wallet), live[-1])

        self.log.info("A reorg of the last blocks deactivates their payouts, live and after a restart")
        before_reorg = live[-1]
        first_reorged = node.getblockhash(node.getblockcount() - REORG_DEPTH + 1)
        node.invalidateblock(first_reorged)
        reorged = self._snapshot(wallet)
        assert_equal(self._payout_count(reorged), payouts - REORG_DEPTH)
        assert_equal(reorged["walletinfo"]["txcount"], before_reorg["walletinfo"]["txcount"])
        wallet = self._reload()
        assert_equal(self._snapshot(wallet), reorged)

        self.log.info("Reconnecting the same blocks restores exactly the state seen before the reorg")
        node.reconsiderblock(first_reorged)
        restored = self._snapshot(wallet)
        assert_equal(self._payout_count(restored), payouts)
        assert_equal(restored["balances"], before_reorg["balances"])
        assert_equal(restored["unspent"], before_reorg["unspent"])
        assert_equal(restored["pos_count"], before_reorg["pos_count"])
        wallet = self._reload()
        assert_equal(self._snapshot(wallet), restored)


if __name__ == '__main__':
    WalletGoldRushBlockConnectWritesTest().main()
