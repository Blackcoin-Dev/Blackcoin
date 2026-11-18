#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Test that a block which changes nothing in a wallet costs it no disk commit.

Every connected block used to end with a synced commit of the wallet database,
because the wallet's best block was written for each one. A block that writes
no other wallet record now leaves the best block for later: it is written with
the next block that does write a record, after 20 blocks or 10 minutes, on a
chainstate flush, and when the wallet is flushed, unloaded or closed.

- A wallet that sees 50 blocks without any activity of its own makes at most 3
  grouped commits, while a wallet that is paid by every one of those blocks
  still makes one per block.
- A node killed without any shutdown restarts with wallets that hold the same
  balances and transactions once it has caught up with its peer, and a full
  rescan changes nothing.
"""

import re

from test_framework.blocktools import COINBASE_MATURITY
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal

IDLE_WALLET = "idle"
IDLE_BLOCKS = 50
MAX_IDLE_COMMITS = 3
MAX_RESTART_RESCAN_BLOCKS = 20


class WalletIdleBlockCommitsTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.num_nodes = 2
        self.setup_clean_chain = True
        self.node_args = ["-autostartstaking=0"]
        self.extra_args = [self.node_args, self.node_args]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()
        self.skip_if_no_sqlite()

    def _grouped_commits_at_unload(self, node, wallet_name):
        """Unload a wallet and return the grouped commits its database made while loaded."""
        log_size_before = node.debug_log_path.stat().st_size
        node.get_wallet_rpc(wallet_name).unloadwallet()
        pattern = re.compile(
            r"SQLite commits for \S*" + re.escape(wallet_name) + r"\S* over its lifetime: n=(\d+) .*\(grouped write scopes: (\d+)\)")
        found = []

        def closed():
            with open(node.debug_log_path, encoding="utf-8", errors="replace") as log:
                log.seek(log_size_before)
                text = log.read()
            found[:] = pattern.findall(text)
            return bool(found)

        self.wait_until(closed, timeout=60)
        commits, grouped = found[-1]
        return int(commits), int(grouped)

    def _snapshot(self, node, wallet):
        node.syncwithvalidationinterfacequeue()
        unspent = sorted(wallet.listunspent(0, 9999999), key=lambda utxo: (utxo["txid"], utxo["vout"]))
        transactions = sorted(
            wallet.listtransactions("*", 100000, 0, True),
            key=lambda tx: (tx["txid"], tx.get("vout", -1), tx["category"]))
        return {
            "balances": wallet.getbalances(),
            "txcount": wallet.getwalletinfo()["txcount"],
            "unspent": unspent,
            "transactions": transactions,
        }

    def _kill_node(self, node):
        """End the node as a power cut would: no shutdown, no flush of any kind."""
        node.process.kill()
        node.process.wait(timeout=node.rpc_timeout)
        node.stdout.close()
        node.stderr.close()
        node.running = False
        node.process = None
        node.rpc_connected = False
        node.rpc = None

    def run_test(self):
        node, peer = self.nodes
        default = node.get_wallet_rpc(self.default_wallet_name)
        peer_wallet = peer.get_wallet_rpc(self.default_wallet_name)
        node.createwallet(wallet_name=IDLE_WALLET, descriptors=True)
        idle = node.get_wallet_rpc(IDLE_WALLET)
        own_address = default.getnewaddress()
        peer_address = peer_wallet.getnewaddress()

        self.log.info("Fund the node's default wallet and give the idle wallet one payment")
        self.generatetoaddress(node, COINBASE_MATURITY + 10, own_address)
        default.sendtoaddress(idle.getnewaddress(), 1)
        self.generatetoaddress(node, 1, own_address)
        node.syncwithvalidationinterfacequeue()
        assert_equal(idle.getwalletinfo()["txcount"], 1)

        self.log.info("Reload both wallets so that their commit counts start from zero")
        idle.unloadwallet()
        default.unloadwallet()
        node.loadwallet(IDLE_WALLET)
        node.loadwallet(self.default_wallet_name)

        self.log.info(f"{IDLE_BLOCKS} blocks that pay the default wallet and never touch the idle wallet")
        self.generatetoaddress(node, IDLE_BLOCKS, own_address)
        node.syncwithvalidationinterfacequeue()
        idle_commits, idle_grouped = self._grouped_commits_at_unload(node, IDLE_WALLET)
        self.log.info(f"idle wallet: {idle_grouped} grouped commits, {idle_commits} commits of any kind")
        assert idle_grouped <= MAX_IDLE_COMMITS, f"idle wallet made {idle_grouped} grouped commits for {IDLE_BLOCKS} blocks"
        if self.options.descriptors:
            # Control: a wallet that every block pays still commits once per block.
            _, paid_grouped = self._grouped_commits_at_unload(node, self.default_wallet_name)
            self.log.info(f"paid wallet: {paid_grouped} grouped commits")
            assert paid_grouped >= IDLE_BLOCKS, f"paid wallet made only {paid_grouped} grouped commits for {IDLE_BLOCKS} blocks"
        else:
            default.unloadwallet()

        self.log.info("An unload wrote the deferred best block: loading again rescans nothing")
        with node.assert_debug_log([], unexpected_msgs=["Rescanning last"]):
            node.loadwallet(IDLE_WALLET)
            node.loadwallet(self.default_wallet_name)
        idle = node.get_wallet_rpc(IDLE_WALLET)
        default = node.get_wallet_rpc(self.default_wallet_name)

        self.log.info("Blocks from the peer: a few idle ones, one with a payment, more idle ones")
        self.sync_blocks()
        self.generatetoaddress(peer, 12, peer_address)
        payment = default.sendtoaddress(idle.getnewaddress(), 2)
        # Hand the transaction to the peer directly rather than wait for relay.
        peer.sendrawtransaction(default.gettransaction(payment)["hex"])
        self.generatetoaddress(peer, 1, peer_address)
        assert_equal(idle.gettransaction(payment)["confirmations"], 1)
        self.generatetoaddress(peer, 9, peer_address)
        pending = default.sendtoaddress(idle.getnewaddress(), 3)
        before_kill = {name: self._snapshot(node, node.get_wallet_rpc(name)) for name in (IDLE_WALLET, self.default_wallet_name)}
        height_before_kill = node.getblockcount()
        assert_equal(before_kill[IDLE_WALLET]["txcount"], 3)

        self.log.info("Kill the node without any shutdown and start it again")
        self._kill_node(node)
        log_size_before = node.debug_log_path.stat().st_size
        self.start_node(0, self.node_args)
        node = self.nodes[0]
        if IDLE_WALLET not in node.listwallets():
            node.loadwallet(IDLE_WALLET)
        if self.default_wallet_name not in node.listwallets():
            node.loadwallet(self.default_wallet_name)
        with open(node.debug_log_path, encoding="utf-8", errors="replace") as log:
            log.seek(log_size_before)
            rescans = [int(n) for n in re.findall(r"Rescanning last (\d+) blocks", log.read())]
        self.log.info(f"height before the kill {height_before_kill}, after the restart {node.getblockcount()}, attach rescans {rescans}")
        assert all(n <= MAX_RESTART_RESCAN_BLOCKS for n in rescans), f"a wallet rescanned {rescans} blocks after the kill"

        self.log.info("After catching up with the peer the wallets are what they were")
        self.connect_nodes(0, 1)
        self.sync_blocks()
        assert_equal(node.getblockcount(), height_before_kill)
        # The unconfirmed payment was only in the killed node's mempool and wallets.
        if pending not in node.getrawmempool():
            node.sendrawtransaction(node.get_wallet_rpc(self.default_wallet_name).gettransaction(pending)["hex"])
        for name in (IDLE_WALLET, self.default_wallet_name):
            wallet = node.get_wallet_rpc(name)
            assert_equal(self._snapshot(node, wallet), before_kill[name])
            wallet.rescanblockchain(0)
            assert_equal(self._snapshot(node, wallet), before_kill[name])

        self.log.info("A clean restart needs no rescan and keeps the same state")
        self.stop_node(0)
        with self.nodes[0].assert_debug_log([], unexpected_msgs=["Rescanning last"]):
            self.start_node(0, self.node_args)
            node = self.nodes[0]
            if IDLE_WALLET not in node.listwallets():
                node.loadwallet(IDLE_WALLET)
        # The mempool is reloaded from disk in the background.
        self.wait_until(lambda: node.getmempoolinfo()["loaded"])
        for name in (IDLE_WALLET, self.default_wallet_name):
            assert_equal(self._snapshot(node, node.get_wallet_rpc(name))["balances"], before_kill[name]["balances"])


if __name__ == '__main__':
    WalletIdleBlockCommitsTest().main()
