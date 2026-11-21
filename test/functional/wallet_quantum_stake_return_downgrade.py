#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""A wallet used by this build can be opened by the unmodified v30.1.6 and used again.

The wallet gets everything this build adds to a wallet file: the quantum stake return record,
a quantum key made for it, a migration batch, and a quantum-return coinstake (a legacy stake
paid to the quantum address). It is then closed and the same data directory is opened by the
UNMODIFIED v30.1.6 binary. That binary must load it, report the same balances and unspent
outputs and the same transaction list, and keep the unknown record, so that this build, opened
again on the same directory, still has its return address and stakes to it.

Regtest: Gold Rush ends at G=61, Migration ends at M=91, the legacy stake window starts at 81,
maturity 10.
"""
import os
from decimal import Decimal

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal
from transition_t_final_util import (
    G,
    LAST_LEGACY_STAKE_HEIGHT,
    LIFECYCLE_ARGS,
    M,
    MATURITY,
    TransitionTFinalTestBase,
)

V30_1_6 = 300106


class QuantumStakeReturnDowngradeTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 2
        self.setup_clean_chain = True
        args = [a for a in LIFECYCLE_ARGS if not a.startswith("-qqallowautokeycreation")]
        self.args = args + ["-rpcdoccheck=0"]
        self.extra_args = [args, args + ["-rpcdoccheck=0"]]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()
        if not os.environ.get("BLACKCOIN_V30_1_6_BINARY"):
            self.skip_if_no_previous_releases()

    def setup_nodes(self):
        override = os.environ.get("BLACKCOIN_V30_1_6_BINARY")
        assert override, "set BLACKCOIN_V30_1_6_BINARY to the unmodified v30.1.6 blackcoind"
        self.v30_1_6 = override
        self.add_nodes(self.num_nodes, extra_args=self.extra_args,
                       binary=[self.options.bitcoind, override],
                       binary_cli=[self.options.bitcoincli] * 2)
        self.start_nodes()
        self.import_deterministic_coinbase_privkeys()
        self.connect_nodes(0, 1)

    def snapshot(self, wallet):
        """What a user sees: balances, unspent outputs, transactions."""
        balances = wallet.getbalances()["mine"]
        unspent = sorted((u["txid"], u["vout"], str(u["amount"])) for u in wallet.listunspent(0))
        txids = sorted(tx["txid"] + ":" + str(tx["vout"]) + ":" + tx["category"] for tx in wallet.listtransactions("*", 1000))
        return {"balances": {k: str(v) for k, v in balances.items()}, "unspent": unspent, "txs": txids,
                "txcount": wallet.getwalletinfo()["txcount"]}

    def run_test(self):
        n0, n1 = self.nodes
        default = n0.get_wallet_rpc(self.default_wallet_name)
        default.staking(False)
        self.set_initial_mt()
        pow_addr = default.getnewaddress("", "legacy")
        quantum_miner = default.getnewquantumaddress()["address"]

        n0.createwallet("dg")
        wallet = n0.get_wallet_rpc("dg")
        wallet.staking(False)
        legacy_addr = wallet.getnewaddress("", "legacy")
        self.log.info("Four legacy coinbases, then Gold Rush ends")
        self.generatetoaddress(n0, 4, legacy_addr, sync_fun=self.sync_all)
        self.bump()
        self.pow_blocks(n0, G - n0.getblockcount(), pow_addr, sync=True)
        # After Gold Rush every block pays a quantum address.
        self.pow_blocks(n0, 70 - n0.getblockcount(), quantum_miner, sync=True)
        assert_equal(n0.getquantumquasarinfo()["phase"], "migration")

        self.log.info("A migration batch: two of the four legacy coins move to a quantum address")
        destination = wallet.getnewquantumaddress()["address"]
        batch = wallet.migratetoquantum({"existing_address": destination, "max_inputs": 2})
        assert_equal(batch["eligible_inputs"], 2)
        self.pow_blocks(n0, LAST_LEGACY_STAKE_HEIGHT - n0.getblockcount(), quantum_miner, sync=True)
        assert_equal(n0.getblockcount(), LAST_LEGACY_STAKE_HEIGHT)

        self.log.info("The return address (a new quantum key and the new wallet record), then a quantum-return stake")
        result = wallet.setquantumstakereturn({"allow_new_quantum_key": True})
        return_address = result["address"]
        kernels = [u for u in wallet.listunspent(MATURITY + 1) if u["scriptPubKey"].startswith("76a914")]
        assert kernels, "no legacy kernel left"
        block_hash = self.stake_outpoint(wallet, n0, {"txid": kernels[0]["txid"], "vout": kernels[0]["vout"]})
        self.wait_until(lambda: n1.getbestblockhash() == block_hash, timeout=60)
        coinstake = n0.getblock(block_hash, 2)["tx"][1]
        valued = [o for o in coinstake["vout"] if o["value"] > 0]
        assert_equal(len(valued), 1)
        assert_equal(valued[0]["scriptPubKey"]["address"], return_address)
        self.pow_blocks(n0, 2, quantum_miner, sync=True)
        wallet.backupwallet(os.path.join(self.options.tmpdir, "dg-backup.dat"))

        before = self.snapshot(wallet)
        info = wallet.getstakinginfo()
        assert_equal(info["legacy_stake_return_address"], return_address)
        self.log.info("Before: %s", before["balances"])

        self.log.info("Close it and open the same data directory with the unmodified v30.1.6")
        self.stop_node(0)
        n0.args[0] = self.v30_1_6
        self.start_node(0, extra_args=self.args + ["-mocktime=%d" % self.mt])
        self.connect_nodes(0, 1)
        assert_equal(n0.getnetworkinfo()["subversion"], "/Blackcoin:30.1.6(testnode0)/")
        n0.loadwallet("dg")
        old = n0.get_wallet_rpc("dg")
        after_old = self.snapshot(old)
        for key in ("balances", "unspent", "txs", "txcount"):
            if before[key] != after_old[key]:
                self.log.info("DIFFERENCE in %s: before %s; v30.1.6 %s", key, before[key], after_old[key])
        assert_equal(after_old["balances"], before["balances"])
        assert_equal(after_old["unspent"], before["unspent"])
        assert_equal(after_old["txs"], before["txs"])
        assert_equal(after_old["txcount"], before["txcount"])
        # The older wallet can keep working: it creates addresses and tracks new blocks.
        old.getnewaddress("", "legacy")
        self.pow_blocks(n0, 1, quantum_miner, sync=True)
        assert_equal(n0.getbestblockhash(), n1.getbestblockhash())
        self.stop_node(0)

        self.log.info("Open it with this build again: the record, the key and the stake survive")
        n0.args[0] = self.options.bitcoind
        self.start_node(0, extra_args=self.extra_args[0] + ["-mocktime=%d" % self.mt])
        self.connect_nodes(0, 1)
        n0.loadwallet("dg")
        wallet = n0.get_wallet_rpc("dg")
        wallet.staking(False)
        default = n0.get_wallet_rpc(self.default_wallet_name)
        self.set_mt(self.mt)
        info = wallet.getstakinginfo()
        assert_equal(info["legacy_stake_return_ready"], True)
        assert_equal(info["legacy_stake_return_address"], return_address)
        after_new = self.snapshot(wallet)
        assert_equal(after_new["balances"], before["balances"])
        assert_equal(after_new["unspent"], before["unspent"])
        # the older binary's one extra block pays a quantum address of the default wallet only
        assert_equal(Decimal(str(wallet.getbalance())), Decimal(before["balances"]["trusted"]))
        # and the wallet still stakes to it
        kernels = [u for u in wallet.listunspent(MATURITY + 1) if u["scriptPubKey"].startswith("76a914")]
        if kernels:
            block_hash = self.stake_outpoint(wallet, n0, {"txid": kernels[0]["txid"], "vout": kernels[0]["vout"]})
            self.wait_until(lambda: n1.getbestblockhash() == block_hash, timeout=60)
            coinstake = n0.getblock(block_hash, 2)["tx"][1]
            valued = [o for o in coinstake["vout"] if o["value"] > 0]
            assert_equal(valued[0]["scriptPubKey"]["address"], return_address)
        assert n0.getblockcount() <= M


if __name__ == '__main__':
    QuantumStakeReturnDowngradeTest().main()
