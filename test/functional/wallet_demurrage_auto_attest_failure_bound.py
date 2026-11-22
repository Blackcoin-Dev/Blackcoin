#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""The automatic demurrage attestation pass has a fixed bound on failed work, makes progress, and does not
choose an unconfirmed target.

Phase 1, the bound and the progress: four keys are due (three of them and the key that holds the twenty fee
inputs), and the mempool refuses every attestation (data carrier outputs are not relayed), so every attempt fails and is cleaned up.
One pass makes at most 16 failed attempts (not 4 x 20), releases every reservation (no attestation
transaction stays pending, no input stays spent, nothing is left in the mempool), and the next passes visit
the keys the earlier passes did not reach, going round the four keys before the first is tried again.

Phase 2, the realistic trigger: the mempool accepts attestations. The four keys are attested in one pass
(some fee inputs are targets of attestations already pending, which the mempool refuses, and the next fee
input is used), and their change is paid to one more key (F). F has one older confirmed output that has just
become due and, since the pass before, four trusted unconfirmed outputs (the change) that all sort before it.
The pass for F attests the confirmed output with one attempt: no failed attempt, no retry through the fee
inputs. (The confirmed output sorts after the change because its funding transaction is chosen among
candidates for an id that sorts high.)

Every output is created before the demurrage activation, so all of them are due at the same height; F's output
is kept out of the wallet's candidate scan (locked) until the pass that is meant to attest it.

Regtest with a compressed demurrage month (four blocks).
"""
from decimal import Decimal
import re
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
PASS_LINE = "Demurrage auto-attest pass:"
KEYS = 3
FEE_INPUTS = 20
MAX_FAILED = 16


def sorts_high(txid):
    """True when an outpoint of this transaction sorts after nearly any other transaction's (the first byte of
    the internal, reversed, id is what the outpoint order compares first)."""
    return int(txid[-2:], 16) >= 0xFC


class DemurrageAutoAttestFailureBoundTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.base_args = [
            "-allowunsafequantumkeyrpc=1",
            "-txindex=1",
            "-staketimio=50",
            "-donatetodevfund=0",
            "-qqallowautokeycreation=1",
            "-shadowwhitelistheight=1",
            "-shadowgoldrushblocks=10",
            f"-qqgoldrushendheight={GOLD_RUSH_END_HEIGHT}",
            f"-qqmigrationendheight={MIGRATION_END_HEIGHT}",
            "-qqstaketierheight=1",
            "-qqstakesplitheight=1",
            f"-qqdemurrageheight={DEMURRAGE_ACTIVATION_HEIGHT}",
            "-qqdemurrageblockspermonth=4",
            "-rpcserialversion=1",
            "-limitancestorcount=100",
            "-limitdescendantcount=100",
        ]
        # Not broadcasting: the funding of F is chosen among transactions the wallet makes and may drop.
        self.extra_args = [self.base_args + ["-qqautodemurrageattest=0", "-walletbroadcast=0"]]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def set_mt(self, t):
        self.mt = t
        self.nodes[0].setmocktime(t)

    def generate(self, count, address):
        for _ in range(count):
            self.generatetoaddress(self.nodes[0], 1, address, sync_fun=self.no_op)
            self.set_mt(self.mt + 16)

    def log_lines(self, text):
        with open(self.nodes[0].debug_log_path, encoding="utf8", errors="replace") as f:
            return [line.rstrip("\n") for line in f if text in line]

    def passes(self):
        out = []
        for line in self.log_lines(PASS_LINE):
            out.append({k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", line.split(PASS_LINE, 1)[1])})
        return out

    def skipped_keys(self):
        return [re.search(r"skipped for key (\w+)", line).group(1) for line in self.log_lines("Demurrage auto-attest skipped for key")]

    def automatic(self, wallet, live_only=True):
        txids = set()
        for entry in wallet.listtransactions("*", 1000, 0, True):
            if entry.get("comment") == COMMENT and not (live_only and entry.get("abandoned")):
                txids.add(entry["txid"])
        return txids

    def run_pass(self, wallet, expected_passes):
        """Staking on until the automatic path has logged `expected_passes` passes in all (it runs once per tip)."""
        wallet.staking(True)
        try:
            self.wait_until(lambda: len(self.passes()) >= expected_passes, timeout=90)
        finally:
            wallet.staking(False)
        assert_equal(len(self.passes()), expected_passes)
        return self.passes()[-1]

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
        keys = [auto.getnewquantumaddress()["address"] for _ in range(KEYS)]
        fee_key = auto.getnewquantumaddress()["address"]  # the fee inputs
        change_key = auto.getnewquantumaddress()["address"]  # F
        due_keys = KEYS + 1

        def pay(address, amount):
            txid = fund.sendtoaddress(address, amount)
            node.sendrawtransaction(fund.gettransaction(txid)["hex"])
            return txid

        self.set_mt(GOLD_RUSH_END_TIME + 16)
        self.generate(COINBASE_MATURITY + 2, funder)
        for address in keys:
            pay(address, Decimal("1"))
        self.log.info("F's older output, from a funding transaction whose id sorts after the ids of its change")
        f_txid = None
        for attempt in range(200):
            txid = fund.sendtoaddress(change_key, Decimal("1") + attempt * Decimal("0.00000001"))
            if sorts_high(txid):
                node.sendrawtransaction(fund.gettransaction(txid)["hex"])
                f_txid = txid
                break
            fund.abandontransaction(txid)  # never broadcast: its input is free again
        assert f_txid is not None, "no funding transaction with a high id"
        for _ in range(FEE_INPUTS):
            pay(fee_key, Decimal("0.05"))
        self.generate(1, funder)
        assert node.getblockcount() < MIGRATION_END_HEIGHT
        # Final starts after the migration end; legacy coinbases are refused from then on.
        while node.getblockcount() < DEMURRAGE_ACTIVATION_HEIGHT + AUTO_ATTEST_BLOCKS - 2:
            self.generate(1, mining)
        f_outpoint = [{"txid": f_txid, "vout": u["vout"]} for u in auto.listunspent(1) if u["txid"] == f_txid]
        assert_equal(len(f_outpoint), 1)
        balances_before = auto.getbalances()["mine"]["trusted"]

        def restart(extra):
            self.stop_node(0, expected_stderr="")
            self.start_node(0, extra_args=self.base_args + [f"-mocktime={self.mt}"] + extra)
            self.set_mt(self.mt)
            node.get_wallet_rpc(self.default_wallet_name).staking(False)
            node.get_wallet_rpc("fund").staking(False)
            wallet = node.get_wallet_rpc("auto")
            wallet.lockunspent(False, f_outpoint)  # F's output is not a candidate yet (the lock is not persistent)
            return wallet

        def due_rows(wallet, addresses):
            return [r for r in wallet.getdemurragewalletinfo()["outputs"] if r["address"] in addresses and r["attestation_due"]]

        self.log.info("Phase 1: the mempool refuses every attestation; four due keys, twenty fee inputs")
        auto = restart(["-qqautodemurrageattest=1", "-acceptnonstdtxn=0", "-datacarrier=0"])
        assert_equal(len(due_rows(auto, keys + [fee_key])), 0)  # the next block makes them due
        order = []
        passes = due_keys + 1
        for n in range(1, passes + 1):
            self.generate(1, mining)
            if n == 1:
                assert_equal(len(due_rows(auto, keys)), KEYS)
                assert_equal(len(due_rows(auto, [fee_key])), FEE_INPUTS)
            stats = self.run_pass(auto, expected_passes=n)
            self.log.info("pass %d: %s", n, stats)
            assert_equal(stats["attempts"], MAX_FAILED)
            assert_equal(stats["failed"], MAX_FAILED)
            assert_equal(stats["submitted"], 0)
            assert_equal(stats["terminal_keys"], 0)
            assert_equal(stats["deferred_keys"], due_keys - 1)
            order = self.skipped_keys()
            assert_equal(len(order), n)
        self.log.info("The passes visited %s", order)
        assert_equal(len(set(order[:due_keys])), due_keys)  # each key once before any is tried again
        assert_equal(order[due_keys], order[0])
        self.log.info("Every failed attempt was cleaned up: nothing pending, nothing reserved, nothing in the mempool")
        assert_equal(node.getrawmempool(), [])
        assert_equal(self.automatic(auto), set())
        # Every attempt that got as far as a transaction was abandoned (an attempt can also fail before one is
        # made: the fee input may be the very output chosen as the target).
        assert passes * MAX_FAILED - passes <= len(self.automatic(auto, live_only=False)) <= passes * MAX_FAILED
        assert_equal(len([u for u in auto.listunspent(0) if u["address"] == fee_key]), FEE_INPUTS)
        assert_equal(auto.getbalances()["mine"]["trusted"], balances_before)

        self.log.info("Phase 2: the mempool accepts attestations; the change of the four keys goes to F")
        auto = restart(["-qqautodemurrageattest=1", f"-qqdemurragechangeaddress={change_key}"])
        self.generate(1, mining)
        stats = self.run_pass(auto, expected_passes=passes + 1)
        self.log.info("pass %d: %s", passes + 1, stats)
        assert_equal(stats["submitted"], due_keys)
        first_round = self.automatic(auto)
        assert_equal(len(first_round), due_keys)
        assert_equal(set(node.getrawmempool()), first_round)
        change = [u for u in auto.listunspent(0, 0) if u["address"] == change_key]
        assert_equal(len(change), due_keys)  # trusted, unconfirmed
        assert all(not sorts_high(u["txid"]) for u in change), "the change must sort before F's older output"

        # A block that does not include them: they stay pending, and F's output is offered to the scan.
        self.set_mt(self.mt + 16)
        self.generateblock(node, mining, [], sync_fun=self.no_op)
        self.set_mt(self.mt + 16)
        assert_equal(set(node.getrawmempool()), first_round)
        auto.lockunspent(True, f_outpoint)
        assert_equal(len(due_rows(auto, [change_key])), 1)  # F's confirmed output; the change is not due
        stats = self.run_pass(auto, expected_passes=passes + 2)
        self.log.info("pass %d: %s", passes + 2, stats)
        assert_equal(stats["attempts"], 1)
        assert_equal(stats["failed"], 0)
        assert_equal(stats["submitted"], 1)
        assert_equal(stats["terminal_keys"], 0)
        (f_attestation,) = self.automatic(auto) - first_round
        assert f_attestation in node.getrawmempool()
        # The pending ones were kept, with their inputs.
        assert_equal(self.automatic(auto) & first_round, first_round)
        assert_equal(set(node.getrawmempool()), first_round | {f_attestation})
        self.generate(1, mining)
        assert_equal(auto.gettransaction(f_attestation)["confirmations"], 1)
        row = [r for r in auto.getdemurragewalletinfo()["outputs"] if r["txid"] == f_txid]
        assert_equal(len(row), 1)
        assert "latest_attestation_height" in row[0], "F's confirmed output is the one attested"


if __name__ == '__main__':
    DemurrageAutoAttestFailureBoundTest().main()
