#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""migratetoquantum moves a large wallet in bounded batches.

A wallet with well over a thousand legacy outputs could not be migrated: the
command built one transaction for everything and failed with "Transaction too
large". Each call now builds one batch of at most max_inputs inputs (and never
more than fits a standard transaction), the dry run reports the maximum signed
size, and the result says how many outputs remain so the caller can repeat.
"""
from decimal import Decimal

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_greater_than, assert_raises_rpc_error
from transition_t_final_util import (
    G,
    LIFECYCLE_ARGS,
    M,
    MATURITY,
    TransitionTFinalTestBase,
)

MAX_STANDARD_TX_WEIGHT = 400000
OUTPUTS_PER_FAN_OUT = 650
FAN_OUTS = 2
FAN_OUT_AMOUNT = Decimal("1.0")
DEFAULT_LEGACY_BATCH = 400


class MigrationBatchesTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.extra_args = [LIFECYCLE_ARGS]

    def tx_weight(self, node, txid):
        return node.getrawtransaction(txid, True)["weight"]

    def run_test(self):
        node = self.nodes[0]
        wallet = node.get_wallet_rpc(self.default_wallet_name)
        wallet.staking(False)
        self.set_mt((node.getblockheader(node.getbestblockhash())["time"] & ~0xf) + 16)
        pow_addr = wallet.getnewaddress("", "legacy")

        self.log.info("Fan a coinbase out into %d legacy outputs, before Gold Rush ends", OUTPUTS_PER_FAN_OUT * FAN_OUTS)
        self.generatetoaddress(node, 2 * MATURITY, pow_addr)
        for _ in range(FAN_OUTS):
            wallet.sendmany("", {wallet.getnewaddress("", "legacy"): FAN_OUT_AMOUNT for _ in range(OUTPUTS_PER_FAN_OUT)})
            self.generatetoaddress(node, 1, pow_addr)
        self.sync_mt_tip()
        # Post-Gold-Rush coinbases are the fork-unique anchors every batch needs.
        self.pow_blocks(node, G + 1 - node.getblockcount(), pow_addr)
        self.pow_blocks(node, 2 * MATURITY, pow_addr)
        assert node.getblockcount() < M - 1
        assert_equal(node.getquantumquasarinfo()["phase"], "migration")

        quantum_address = wallet.getnewquantumaddress()["address"]
        status = wallet.getmigrationstatus()
        total = status["eligible_legacy_inputs"]
        assert_greater_than(total, OUTPUTS_PER_FAN_OUT * FAN_OUTS)
        self.log.info("Wallet holds %d eligible legacy outputs", total)

        self.log.info("Dry run: bounded batch, accurate (maximum signed) size, fee, and what remains")
        dry = wallet.migratetoquantum({"dry_run": True, "existing_address": quantum_address})
        assert_equal(dry["total_eligible_inputs"], total)
        assert_equal(dry["eligible_inputs"], DEFAULT_LEGACY_BATCH)
        assert_equal(dry["remaining_inputs"], total - DEFAULT_LEGACY_BATCH)
        assert_equal(dry["more_batches"], True)
        assert_equal(dry["max_inputs"], DEFAULT_LEGACY_BATCH)
        assert "txid" not in dry
        # An unsigned legacy transaction is about 41 bytes per input; the signed one about 148.
        assert_greater_than(dry["vsize"], 100 * DEFAULT_LEGACY_BATCH)

        self.log.info("Real batch: the dry run was a safe upper bound of the real transaction")
        first = wallet.migratetoquantum({"existing_address": quantum_address})
        assert_equal(first["eligible_inputs"], DEFAULT_LEGACY_BATCH)
        assert_equal(first["remaining_inputs"], total - DEFAULT_LEGACY_BATCH)
        assert_equal(first["fee"], dry["fee"])
        real = node.getrawtransaction(first["txid"], True)
        assert_equal(len(real["vin"]), DEFAULT_LEGACY_BATCH)
        assert real["vsize"] <= dry["vsize"], (real["vsize"], dry["vsize"])
        assert real["vsize"] >= dry["vsize"] * 0.9, (real["vsize"], dry["vsize"])
        assert real["weight"] < MAX_STANDARD_TX_WEIGHT

        self.log.info("max_inputs smaller than the default is honoured; zero is refused")
        assert_raises_rpc_error(-8, "max_inputs must be at least 1", wallet.migratetoquantum,
                                {"existing_address": quantum_address, "max_inputs": 0})
        second = wallet.migratetoquantum({"existing_address": quantum_address, "max_inputs": 25})
        assert_equal(second["eligible_inputs"], 25)
        assert_equal(second["remaining_inputs"], total - DEFAULT_LEGACY_BATCH - 25)
        assert_equal(second["max_inputs"], 25)

        self.log.info("A huge max_inputs is still cut by the standard size limit")
        third = wallet.migratetoquantum({"existing_address": quantum_address, "max_inputs": 100000})
        assert_greater_than(third["eligible_inputs"], 100)
        weight = self.tx_weight(node, third["txid"])
        assert weight < MAX_STANDARD_TX_WEIGHT, weight
        # The cut keeps a safety margin below the limit.
        assert weight <= 0.95 * MAX_STANDARD_TX_WEIGHT, weight

        self.log.info("Repeat until nothing remains; every legacy output is spent exactly once")
        txids = [first["txid"], second["txid"], third["txid"]]
        spent_total = first["eligible_inputs"] + second["eligible_inputs"] + third["eligible_inputs"]
        batch = third
        guard = 0
        while batch["more_batches"]:
            batch = wallet.migratetoquantum({"existing_address": quantum_address})
            spent_total += batch["eligible_inputs"]
            txids.append(batch["txid"])
            guard += 1
            assert guard < 20, "too many batches"
        assert_equal(spent_total, total)
        assert_equal(batch["remaining_inputs"], 0)
        seen = set()
        for txid in txids:
            for vin in node.getrawtransaction(txid, True)["vin"]:
                key = (vin["txid"], vin["vout"])
                assert key not in seen, "an output was selected by two batches"
                seen.add(key)
        assert_equal(len(seen), total)
        assert_equal(wallet.getmigrationstatus()["eligible_legacy_inputs"], 0)
        assert_raises_rpc_error(-6, "No spendable legacy coins to migrate",
                                wallet.migratetoquantum, {"existing_address": quantum_address})

        self.log.info("All batches confirm")
        self.pow_blocks(node, 1, pow_addr)
        self.generatetoaddress(node, 1, pow_addr)
        for txid in txids:
            assert node.getrawtransaction(txid, True)["confirmations"] > 0

        self.log.info("Help text says what each command is for")
        legacy_help = wallet.help("migratetoquantum")
        assert "can never be spent" in legacy_help
        rewards_help = wallet.help("migrategoldrushrewards")
        assert "nothing is lost by leaving them" in rewards_help
        assert "migratetoquantum" in rewards_help


if __name__ == '__main__':
    MigrationBatchesTest().main()
