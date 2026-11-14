#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Test that wallet loading skips payout authentication it already did.

Loading a wallet authenticates every block that paid it a synthetic Gold Rush
payout against the chainstate. A wallet checkpoint remembers which payouts were
authenticated, so a restart only authenticates payouts that are new or changed.
The checkpoint is a hint: it must never change what the wallet reports, and any
mismatch (missing record, edited record, block no longer on the active chain)
must fall back to authenticating everything.
"""

import re
import time

try:
    import sqlite3
except ImportError:
    pass

from test_framework.blocktools import COINBASE_MATURITY
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal

SHADOW_GOLD_RUSH_BLOCKS = 500
GOLD_RUSH_END_HEIGHT = 1 + SHADOW_GOLD_RUSH_BLOCKS
MIGRATION_END_HEIGHT = GOLD_RUSH_END_HEIGHT + 10
WALLET_NAME = "payout_checkpoint"
PAYOUT_BLOCKS = 8
CHECKPOINT_KEY = b"\x19syntheticpayoutcheckpoint"
CHECK_LINE = re.compile(
    r"Gold Rush payout check: (\d+) payout blocks authenticated, (\d+) already verified through height (-?\d+)")


class WalletGoldRushPayoutCheckpointTest(BitcoinTestFramework):
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
        self.skip_if_no_sqlite()
        self.skip_if_no_py_sqlite3()

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

    def _snapshot(self, wallet):
        """Everything a user can see that payout authentication could influence."""
        unspent = sorted(
            wallet.listunspent(0, 9999999, [], True, {"include_immature_coinbase": True}),
            key=lambda utxo: (utxo["txid"], utxo["vout"]))
        transactions = sorted(
            wallet.listtransactions("*", 100000, 0, True),
            key=lambda tx: (tx["txid"], tx["vout"], tx["category"]))
        goldrush = wallet.getgoldrushinfo()
        return {
            "balances": wallet.getbalances(),
            "txcount": wallet.getwalletinfo()["txcount"],
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

    def _load_wallet(self):
        """Load the wallet and return (authenticated, already verified, verified through height)."""
        node = self.nodes[0]
        with open(node.debug_log_path, "rb") as log:
            log.seek(0, 2)
            offset = log.tell()
        node.loadwallet(WALLET_NAME)
        with open(node.debug_log_path, "rb") as log:
            log.seek(offset)
            lines = [CHECK_LINE.search(line) for line in log.read().decode("utf-8", "replace").splitlines()]
        found = [match for match in lines if match]
        assert_equal(len(found), 1)
        return tuple(int(group) for group in found[0].groups())

    def _restart_and_load(self, extra=()):
        self.restart_node(0, [*self.node_args, *extra])
        return self._load_wallet()

    def _edit_checkpoint(self, edit):
        """Stop the node and apply `edit(value) -> value or None (delete)` to the stored checkpoint."""
        self.stop_node(0)
        db_path = self.nodes[0].wallets_path / WALLET_NAME / self.wallet_data_filename
        conn = sqlite3.connect(db_path)
        with conn:
            row = conn.execute("SELECT value FROM main WHERE key = ?", (CHECKPOINT_KEY,)).fetchone()
            assert row is not None, "wallet did not store a payout checkpoint"
            new_value = edit(bytes(row[0]))
            if new_value is None:
                conn.execute("DELETE FROM main WHERE key = ?", (CHECKPOINT_KEY,))
            else:
                conn.execute("UPDATE main SET value = ? WHERE key = ?", (new_value, CHECKPOINT_KEY))
        conn.close()

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
        for _ in range(PAYOUT_BLOCKS + 1):
            self._mine_pos_block(wallet)
        before = self._snapshot(wallet)
        payouts = self._payout_count(before)
        assert payouts >= PAYOUT_BLOCKS - 1, "wallet must hold the synthetic payouts under test"

        self.log.info("A clean restart authenticates nothing: the shutdown flush stored a checkpoint")
        authenticated, verified, through = self._restart_and_load()
        assert_equal((authenticated, verified), (0, payouts))
        assert through > 0
        assert_equal(self._snapshot(node.get_wallet_rpc(WALLET_NAME)), before)

        self.log.info("A corrupted checkpoint is ignored and everything is authenticated, with the same result")
        self._edit_checkpoint(lambda value: value[:-1] + bytes([value[-1] ^ 0xff]))
        self.start_node(0, self.node_args)
        assert_equal(self._load_wallet(), (payouts, 0, -1))
        assert_equal(self._snapshot(node.get_wallet_rpc(WALLET_NAME)), before)

        self.log.info("A checkpoint whose count does not match the wallet's records is ignored")
        self._edit_checkpoint(lambda value: value[:44] + bytes([value[44] ^ 0x01]) + value[45:])
        self.start_node(0, self.node_args)
        assert_equal(self._load_wallet(), (payouts, 0, -1))
        assert_equal(self._snapshot(node.get_wallet_rpc(WALLET_NAME)), before)

        self.log.info("A missing checkpoint is rebuilt and used by the next start")
        self._edit_checkpoint(lambda value: None)
        self.start_node(0, self.node_args)
        assert_equal(self._load_wallet(), (payouts, 0, -1))
        authenticated, verified, through = self._restart_and_load()
        assert_equal((authenticated, verified), (0, payouts))
        assert_equal(self._snapshot(node.get_wallet_rpc(WALLET_NAME)), before)

        self.log.info("Payouts recorded after the checkpoint are authenticated; older ones are not")
        wallet = node.get_wallet_rpc(WALLET_NAME)
        self._set_mocktime((node.getblockheader(node.getbestblockhash())["time"] & ~0xf) + 16)
        self._mine_pos_block(wallet)
        newer = self._snapshot(wallet)
        assert_equal(self._payout_count(newer), payouts + 1)
        node.unloadwallet(WALLET_NAME)
        authenticated, verified, through = self._load_wallet()
        assert_equal((authenticated, verified), (1, payouts))
        assert_equal(self._snapshot(node.get_wallet_rpc(WALLET_NAME)), newer)

        self.log.info("A checkpoint block that left the active chain is ignored; the payouts above the fork are deactivated")
        node.unloadwallet(WALLET_NAME)
        reorg_depth = 3
        node.invalidateblock(node.getblockhash(node.getblockcount() - reorg_depth + 1))
        authenticated, verified, through = self._load_wallet()
        assert_equal((verified, through), (0, -1))
        reorged = self._snapshot(node.get_wallet_rpc(WALLET_NAME))
        assert_equal(self._payout_count(reorged), payouts + 1 - reorg_depth)
        assert_equal(reorged["txcount"], newer["txcount"])


if __name__ == '__main__':
    WalletGoldRushPayoutCheckpointTest().main()
