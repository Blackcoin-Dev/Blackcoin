#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Slow-disk regression gates on a regtest node whose wallet has tens of thousands of outputs.

RC13 passed every test and then stalled on nodes with spinning disks: a status
RPC did about 124,000 random chainstate lookups under cs_main and cs_wallet,
and the wallet database was synced to disk inside the wallet lock on every
block. A fast disk hides both. These gates count the operations instead of
timing them (see the hidden getiocounters RPC), so they do not depend on the
speed of the machine that runs them.

The fixture: one wallet address, many coinbase outputs, and a series of
fan-out transactions that each pay FANOUT_OUTPUTS outputs back to that one
address, as a mining wallet does. The size is FANOUT_TXS * (FANOUT_OUTPUTS + 1) live
non-coinbase outputs: 52 transactions give about 125,000 outputs, the size of
the field wallets, and the build takes seconds on a development machine (the
RPCs that read the whole wallet afterwards take longer). A transaction with
2,400 outputs is about 85 kB, near the 100 kB standardness limit, and one
block holds six of them, so 125,000 outputs is the practical shape on regtest;
set BLACKCOIN_IO_GATE_FANOUT_TXS to build more or fewer.

Part one holds on RC13 and must keep holding. Part two are the gates for the
RC14 behavior, enforced.
"""

import os
import time
from decimal import Decimal

from test_framework.address import ADDRESS_BCRT1_UNSPENDABLE
from test_framework.blocktools import COINBASE_MATURITY
from test_framework.messages import COIN, COutPoint, CTransaction, CTxIn, CTxOut
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal

# The gates are enforced. RC14_ENFORCE_GATES=0 in the environment turns them
# into reports (to look at a build that does not meet them).
RC14_INTEGRATION_ENABLED = True

FANOUT_TXS = int(os.environ.get("BLACKCOIN_IO_GATE_FANOUT_TXS", "52"))
FANOUT_OUTPUTS = 2400
FANOUT_TXS_PER_BLOCK = 6
FANOUT_VALUE = Decimal("1.0")
FANOUT_FEE = Decimal("2.0")
# Coins first, derived records second, and an authenticated Gold Rush payout
# can take more than two sweeps; five leaves room, a random order shows as thousands.
MAX_ASCENDING_RUNS = 5


def gates_enforced():
    return RC14_INTEGRATION_ENABLED and os.environ.get("RC14_ENFORCE_GATES") != "0"


class WalletIoGatesTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.node_args = ["-autostartstaking=0", "-testrecordreadkeys=1", "-whitelist=noban@127.0.0.1"]
        self.extra_args = [self.node_args]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def gate(self, holds, description):
        """Report a gate. It fails the test only when the gates are enforced."""
        if gates_enforced():
            assert holds, description
            self.log.info("gate holds: %s", description)
        else:
            self.log.info("[rc14 gate waits for integration] %s: %s", description, "HOLDS" if holds else "does not hold yet")

    def counters(self, *args):
        return self.nodes[0].getiocounters(*args)

    def chainstate_reads(self, counters):
        return counters["chainstate_get_coin"] + counters["chainstate_have_coin"]

    def build_wallet(self):
        node = self.nodes[0]
        address = node.getnewaddress("", "legacy")
        change_address = node.getnewaddress("", "legacy")
        script = bytes.fromhex(node.getaddressinfo(address)["scriptPubKey"])
        change_script = bytes.fromhex(node.getaddressinfo(change_address)["scriptPubKey"])
        started = time.time()
        # Coinbase outputs: one per fan-out transaction, all mature.
        self.generatetoaddress(node, FANOUT_TXS + COINBASE_MATURITY, address, sync_fun=self.no_op)
        coinbase_utxos = sorted(node.listunspent(), key=lambda u: u["txid"])[:FANOUT_TXS]
        assert_equal(len(coinbase_utxos), FANOUT_TXS)
        fanout_txids = []
        for n, utxo in enumerate(coinbase_utxos):
            change = Decimal(str(utxo["amount"])) - FANOUT_OUTPUTS * FANOUT_VALUE - FANOUT_FEE
            assert change > 0
            tx = CTransaction()
            tx.vin = [CTxIn(COutPoint(int(utxo["txid"], 16), utxo["vout"]))]
            # The same script over and over, as a mining wallet pays.
            tx.vout = [CTxOut(int(FANOUT_VALUE * COIN), script) for _ in range(FANOUT_OUTPUTS)]
            tx.vout.append(CTxOut(int(change * COIN), change_script))
            signed = node.signrawtransactionwithwallet(tx.serialize().hex())
            assert signed["complete"]
            fanout_txids.append(node.sendrawtransaction(signed["hex"]))
            if (n + 1) % FANOUT_TXS_PER_BLOCK == 0:
                self.generatetoaddress(node, 1, address, sync_fun=self.no_op)
        self.generatetoaddress(node, 1, address, sync_fun=self.no_op)
        node.syncwithvalidationinterfacequeue()
        self.log.info("Built %d fan-out outputs in %.0f s", FANOUT_TXS * (FANOUT_OUTPUTS + 1), time.time() - started)
        return address, fanout_txids

    def run_test(self):
        node = self.nodes[0]
        self.log.info("Part one: the fixture and its balance")
        address, fanout_txids = self.build_wallet()
        wallet_info = node.getwalletinfo()
        assert wallet_info["txcount"] >= FANOUT_TXS * 2
        unspent = node.listunspent(1)
        assert len(unspent) >= FANOUT_TXS * FANOUT_OUTPUTS
        total = sum(Decimal(str(u["amount"])) for u in unspent)
        balances = node.getbalances()["mine"]
        assert_equal(Decimal(str(balances["trusted"])), total)
        self.log.info("The wallet has %d unspent outputs, balance equals their sum", len(unspent))

        self.log.info("Counters count what a status poll does")
        before = self.counters()
        node.getwalletinfo()
        node.getbalances()
        mid = self.counters()
        self.log.info("getwalletinfo and getbalances: %d chainstate reads", self.chainstate_reads(mid) - self.chainstate_reads(before))

        self.log.info("Part two: gates for the other tracks")
        # 1. Polling reads nothing from the chainstate.
        node.getbalances()  # warm up
        before = self.counters()
        for _ in range(3):
            node.getwalletinfo()
            node.getbalances()
        polled = self.chainstate_reads(self.counters()) - self.chainstate_reads(before)
        self.gate(polled == 0, "polling getwalletinfo and getbalances performs zero chainstate reads (saw %d)" % polled)

        # 2 and 3. A restart serves the first balance without reading the wallet's
        # ordinary outputs one by one, in both balance modes (the framework
        # writes walletrpcexactbalance=1; the shipped default is 0).
        noncoinbase_outputs = FANOUT_TXS * (FANOUT_OUTPUTS + 1)
        for exact in (0, 1):
            # -checklevel=0: the startup chain verification (level 3 by default)
            # disconnects the last blocks and so reads every output they spend
            # or create; that is the node's, not the wallet's, and is left out.
            self.restart_node(0, self.node_args + ["-walletrpcexactbalance=%d" % exact, "-checklevel=0"])
            node = self.nodes[0]
            wallet = node.get_wallet_rpc(self.default_wallet_name)
            wallet.getbalances()  # the first balance served
            recorded = self.counters(0, True)
            per_txid = recorded["recorded_coin_reads_by_txid"]
            reads = sum(per_txid.get(txid, 0) for txid in fanout_txids)
            self.log.info("walletrpcexactbalance=%d: %d of %d non-coinbase outputs read from the chainstate, %d coin reads, %d ascending runs",
                          exact, reads, noncoinbase_outputs, recorded["recorded_coin_keys"], recorded["recorded_coin_key_inversions"] + 1)
            # The memo verification samples 1 in LIFECYCLE_MEMO_VERIFY_MODULUS (1024)
            # outputs by design; allow twice that share (about 0.2 percent).
            bound = noncoinbase_outputs * 2 // 1024
            self.gate(reads <= bound,
                      "restart reads at most %d (0.2 percent) of the %d non-coinbase wallet outputs from the chainstate before the first balance, exact=%d (saw %d)"
                      % (bound, noncoinbase_outputs, exact, reads))
            # The warm-up reads in ascending sweeps (coins first, then derived
            # records, and a Gold Rush payout may need more than two): a small
            # bounded number of ascending runs, never a random order.
            runs = recorded["recorded_coin_key_inversions"] + 1
            self.gate(runs <= MAX_ASCENDING_RUNS,
                      "chainstate reads of the balance warm-up come in at most %d ascending runs, exact=%d (saw %d reads in %d runs)"
                      % (MAX_ASCENDING_RUNS, exact, recorded["recorded_coin_keys"], runs))

        # 4. Blocks that do nothing for the wallet cost it almost no commits.
        node.syncwithvalidationinterfacequeue()
        before = self.counters()
        self.generatetoaddress(node, 50, ADDRESS_BCRT1_UNSPENDABLE, sync_fun=self.no_op)
        node.syncwithvalidationinterfacequeue()
        commits = self.counters()["wallet_commits"] - before["wallet_commits"]
        self.gate(commits <= 3, "connecting 50 blocks with no wallet activity performs at most 3 wallet DB commits (saw %d)" % commits)


if __name__ == "__main__":
    WalletIoGatesTest().main()
