#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""A pending automatic attestation is kept when it cannot be submitted, and only abandoned when it cannot confirm.

A failed submission is not evidence that a pending attestation is unusable. The automatic path used to
abandon the wallet's pending attestation whenever submitting it again returned false, which also happens
when wallet broadcasting is off (before any validation), when the mempool refuses it for now (a raised
minimum relay fee), and on a local error. Abandoning released its inputs and led to another attestation
being signed and paid for. Now:

 * with broadcasting disabled the pending attestation stays, is not abandoned, and no other is signed;
 * when the mempool refuses it for the moment (a relay fee floor above its fee) it stays, is not
   abandoned, and no other is signed; once the floor is back to normal it is accepted again and confirms.

Whether a pending attestation can still confirm (referenced state including its source, target, inputs)
is decided from the wallet and the chain, never from the submission result; the unit tests
(demurrage_pending_attestation_tests) cover that classification, the complete referenced state with its
source, and that only transactions carrying the automatic path's own comment are ever cleaned up.

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


class DemurrageAutoAttestKeepPendingTest(BitcoinTestFramework):
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
        target = auto.getnewquantumaddress()["address"]

        self.set_mt(GOLD_RUSH_END_TIME + 16)
        self.generate(COINBASE_MATURITY + 2, funder)
        for amount in (Decimal("9"), Decimal("1"), Decimal("1")):
            fund.sendtoaddress(target, amount)
        self.generate(1, funder)
        while node.getblockcount() < DEMURRAGE_ACTIVATION_HEIGHT + AUTO_ATTEST_BLOCKS + 1:
            self.generate(1, mining)
        assert_equal(auto.getdemurragewalletinfo()["demurrage_active"], True)

        self.log.info("The automatic path signs one attestation for the one due key")
        before = set(node.getrawmempool())
        auto.staking(True)
        try:
            self.wait_until(lambda: len(set(node.getrawmempool()) - before) >= 1, timeout=30)
            self.wait_until(lambda: len(self.attestation_txids(auto)) >= 1, timeout=30)
        finally:
            auto.staking(False)
        signed = self.attestation_txids(auto)
        assert_equal(len(signed), 1)
        (pending_txid,) = signed

        self.last_stderr = ""

        def restart(extra, expected_stderr=""):
            # A node's stderr is checked when it stops: the previous run's warning is expected there.
            self.stop_node(0, expected_stderr=self.last_stderr)
            self.last_stderr = expected_stderr
            self.start_node(0, extra_args=self.extra_args[0] + ["-persistmempool=0", f"-mocktime={self.mt}"] + extra)
            self.set_mt(self.mt)
            return node.get_wallet_rpc("auto")

        def abandoned(wallet, txid):
            return wallet.gettransaction(txid).get("abandoned", False)

        self.log.info("Broadcasting disabled: the pending attestation is kept and nothing else is signed")
        auto = restart(["-walletbroadcast=0"])
        assert pending_txid not in node.getrawmempool()
        assert_equal(auto.gettransaction(pending_txid)["confirmations"], 0)
        auto.staking(True)
        try:
            self.wait_until(lambda: self.log_has("kept: it cannot be submitted now"), timeout=60)
        finally:
            auto.staking(False)
        assert not abandoned(auto, pending_txid)
        assert_equal(self.attestation_txids(auto), signed)
        assert pending_txid not in node.getrawmempool()

        self.log.info("The mempool refuses it for now (a relay fee floor above its fee): kept, nothing else is signed")
        auto = restart(["-minrelaytxfee=1"],
                       # the warning is printed once for each of the three loaded wallets
                       expected_stderr="\n".join(["Warning: -minrelaytxfee is set very high! The wallet will avoid paying less than the minimum relay fee."] * 3))
        assert pending_txid not in node.getrawmempool()
        auto.staking(True)
        try:
            self.wait_until(lambda: self.log_has("was not accepted again") and self.log_has("keeping it"), timeout=60)
        finally:
            auto.staking(False)
        assert not abandoned(auto, pending_txid)
        assert_equal(self.attestation_txids(auto), signed)
        assert pending_txid not in node.getrawmempool()

        self.log.info("The floor is back to normal: it is accepted again, and confirms")
        auto = restart([])
        auto.staking(True)
        try:
            self.wait_until(lambda: pending_txid in node.getrawmempool(), timeout=60)
        finally:
            auto.staking(False)
        assert not abandoned(auto, pending_txid)
        assert_equal(self.attestation_txids(auto), signed)
        self.generate(1, mining)
        assert_equal(auto.gettransaction(pending_txid)["confirmations"], 1)

    def log_has(self, text):
        with open(self.nodes[0].debug_log_path, encoding="utf8", errors="replace") as f:
            return any(text in line for line in f)


if __name__ == '__main__':
    DemurrageAutoAttestKeepPendingTest().main()
