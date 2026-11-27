#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""The automatic demurrage attestation reuses a pending attestation instead of signing another.

The wallet keeps a retry record per key, and a block disconnect erases it. The attestation transaction
that block held is back in the wallet as unconfirmed, and after a restart that does not keep the mempool
it is in the wallet only. Another fee input can pay for another attempt, so without a look at what the
wallet already holds the automatic path would sign (and, the mempool holding one for that key already,
abandon) a second attestation for the same key and state on every such event.

The automatic path now finds the wallet's pending attestation for the same key and the same referenced
state and uses it:

 * across a block disconnect: the attestation is in the mempool again, and no second one is made;
 * across a restart without a persisted mempool: the wallet holds it unconfirmed, it is back in the
   mempool, and no second one is made.

Regtest with a compressed demurrage month (four blocks), activation at height 27.
"""
from decimal import Decimal
import time

from test_framework.blocktools import COINBASE_MATURITY
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal

GOLD_RUSH_END_TIME = 2_000_000_000
GOLD_RUSH_END_HEIGHT = 11
MIGRATION_END_HEIGHT = 26
DEMURRAGE_ACTIVATION_HEIGHT = 27
AUTO_ATTEST_BLOCKS = 12  # three months of four blocks
COMMENT = "Quantum Quasar demurrage auto-attestation"


class DemurrageAutoAttestPendingTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.extra_args = [[
            "-allowunsafequantumkeyrpc=1",
            "-txindex=1",
            "-staketimio=50",
            "-donatetodevfund=0",
            "-qqautodemurrageattest=1",
            "-qqallowautokeycreation=1",
            "-shadowwhitelistheight=1",
            "-shadowgoldrushblocks=10",
            f"-qqgoldrushendheight={GOLD_RUSH_END_HEIGHT}",
            f"-qqmigrationendheight={MIGRATION_END_HEIGHT}",
            "-qqstaketierheight=1",
            "-qqstakesplitheight=1",
            f"-qqdemurrageheight={DEMURRAGE_ACTIVATION_HEIGHT}",
            "-qqdemurrageblockspermonth=4",
        ]]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def set_mt(self, t):
        self.mt = t
        self.nodes[0].setmocktime(t)

    def generate(self, count, address):
        for _ in range(count):
            self.generatetoaddress(self.nodes[0], 1, address, sync_fun=self.no_op)
            self.set_mt(self.mt + 16)

    def attestation_txids(self, wallet, live_only=False):
        """Wallet transactions made by the automatic path (abandoned ones included unless live_only)."""
        txids = set()
        for entry in wallet.listtransactions("*", 1000, 0, True):
            if entry.get("comment") == COMMENT and not (live_only and entry.get("abandoned")):
                txids.add(entry["txid"])
        return txids

    def run_test(self):
        node = self.nodes[0]
        self.set_mt((int(time.time()) & ~0xf) + 16)
        node.get_wallet_rpc(self.default_wallet_name).staking(False)
        node.createwallet(wallet_name="fund", load_on_startup=True)
        node.createwallet(wallet_name="auto", load_on_startup=True)
        fund = node.get_wallet_rpc("fund")
        auto = node.get_wallet_rpc("auto")
        fund.staking(False)
        auto.staking(False)
        funder = fund.getnewaddress("", "legacy")
        mining = fund.getnewquantumaddress()["address"]
        # One key (one address) with three outputs: the attestation's target and two fee sources.
        target = auto.getnewquantumaddress()["address"]

        self.set_mt(GOLD_RUSH_END_TIME + 16)
        self.generate(COINBASE_MATURITY + 2, funder)
        for amount in (Decimal("9"), Decimal("1"), Decimal("1")):
            fund.sendtoaddress(target, amount)
        self.generate(1, funder)
        self.log.info("Mine until the key's attestation is due, while the fee outputs are still young")
        while node.getblockcount() < DEMURRAGE_ACTIVATION_HEIGHT + AUTO_ATTEST_BLOCKS + 1:
            self.generate(1, mining)
        info = auto.getdemurragewalletinfo()
        assert_equal(info["demurrage_active"], True)

        self.log.info("The automatic path signs an attestation for the one due key")
        before = set(node.getrawmempool())
        auto.staking(True)
        try:
            self.wait_until(lambda: len(set(node.getrawmempool()) - before) >= 1, timeout=30)
            self.wait_until(lambda: len(self.attestation_txids(auto)) >= 1, timeout=30)
        finally:
            auto.staking(False)
        signed = self.attestation_txids(auto)  # everything signed so far, abandoned ones included
        first = self.attestation_txids(auto, live_only=True)  # the ones that were accepted
        assert_equal(len(first), 1)
        assert_equal(set(node.getrawmempool()) - before, first)

        self.log.info("Across a block disconnect: the block holding them is invalidated, no further attestation is signed")
        self.generate(1, mining)
        for txid in first:
            assert_equal(auto.gettransaction(txid)["confirmations"], 1)
        node.invalidateblock(node.getbestblockhash())
        # A different block at the same height (without them): a new tip hash, so the staking loop scans
        # again, and the attestations are back in the mempool, unconfirmed.
        self.set_mt(self.mt + 16)
        self.generateblock(node, mining, [], sync_fun=self.no_op)
        self.set_mt(self.mt + 16)
        for txid in first:
            assert_equal(auto.gettransaction(txid)["confirmations"], 0)
            assert txid in node.getrawmempool()
        auto.staking(True)
        try:
            self.wait_until(lambda: self.log_has("Demurrage auto-attest suppressed"), timeout=30)
        finally:
            auto.staking(False)
        assert_equal(self.attestation_txids(auto), signed)  # nothing new was signed
        assert_equal(set(node.getrawmempool()) - before, first)

        self.log.info("Across a restart that does not keep the mempool: no further attestation is signed")
        self.restart_node(0, extra_args=self.extra_args[0] + ["-persistmempool=0", f"-mocktime={self.mt}"])
        self.set_mt(self.mt)
        auto = node.get_wallet_rpc("auto")
        assert_equal(self.attestation_txids(auto), signed)
        # (the wallet itself re-accepts its unconfirmed transactions into the mempool as it loads)
        auto.staking(True)
        try:
            self.wait_until(lambda: first <= set(node.getrawmempool()), timeout=60)
        finally:
            auto.staking(False)
        assert_equal(self.attestation_txids(auto), signed)  # nothing new was signed: the old ones were reused

    def log_has(self, text):
        with open(self.nodes[0].debug_log_path, encoding="utf8", errors="replace") as f:
            return any(text in line for line in f)


if __name__ == '__main__':
    DemurrageAutoAttestPendingTest().main()
