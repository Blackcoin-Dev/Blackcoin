#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""The first Final block, produced by the wallet's own staker, from the kernels that matter.

The continuous Migration-to-Final transition, ended with the actual block F (the first Final block):
no phase RPC at tip M stands in for it. Node 1 is an UNMODIFIED v30.1.6 node that validates every block
(the mock clock is after Protocol V3.1, so the proof-of-stake kernel, signature and reward checks run).

Regtest: Gold Rush ends at G=61, Migration ends at M=91 (F=92), maturity 10, the quantum return window
starts at 81. The chain is mined by proof of work to M; only the staker makes block F.

 * "reserve" holds a quantum output migrated long before (an older quantum reserve): the wallet builds
   block F from exactly that kernel, and the unmodified node accepts it;
 * "early" holds only a legacy coin that stakes at the first window height (81) and so owns the EARLIEST
   window payout: made at 81, it is old enough for block M and every block after it. Block F is replaced
   (both nodes invalidate it) and the wallet builds the new block F from exactly that payout. The block
   pays the whole payout back as principal plus the scheduled reward, to the payout's own script.
"""
import os
from decimal import Decimal

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal
from transition_t_final_util import (
    F,
    G,
    LAST_LEGACY_STAKE_HEIGHT,
    LIFECYCLE_ARGS,
    M,
    MATURITY,
    TransitionTFinalTestBase,
)

V30_1_6 = 300106
SUBSIDY = Decimal("1.5")
WINDOW_START = LAST_LEGACY_STAKE_HEIGHT + 1


class FirstFinalBlockKernelsTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 2
        self.setup_clean_chain = True
        self.extra_args = [LIFECYCLE_ARGS, LIFECYCLE_ARGS + ["-rpcdoccheck=0"]]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()
        if not os.environ.get("BLACKCOIN_V30_1_6_BINARY"):
            self.skip_if_no_previous_releases()

    def setup_nodes(self):
        override = os.environ.get("BLACKCOIN_V30_1_6_BINARY")
        if override:
            self.add_nodes(self.num_nodes, extra_args=self.extra_args,
                           binary=[self.options.bitcoind, override],
                           binary_cli=[self.options.bitcoincli] * 2)
        else:
            self.add_nodes(self.num_nodes, extra_args=self.extra_args, versions=[None, V30_1_6])
        self.start_nodes()
        self.import_deterministic_coinbase_privkeys()
        self.connect_nodes(0, 1)

    def sync_tips(self):
        n0, n1 = self.nodes
        self.wait_until(lambda: n0.getbestblockhash() == n1.getbestblockhash(), timeout=60)

    def stake_from(self, wallet, outpoint):
        block_hash = self.stake_outpoint(wallet, self.nodes[0], outpoint)
        self.sync_tips()  # the unmodified node validated the block
        return block_hash

    def run_test(self):
        n0, n1 = self.nodes
        default = n0.get_wallet_rpc(self.default_wallet_name)
        default.staking(False)
        self.set_initial_mt()
        assert_equal(n1.getnetworkinfo()["subversion"], "/Blackcoin:30.1.6(testnode1)/")
        pow_addr = default.getnewaddress("", "legacy")
        quantum_miner = default.getnewquantumaddress()["address"]
        n0.createwallet("reserve")
        n0.createwallet("early")
        reserve = n0.get_wallet_rpc("reserve")
        early = n0.get_wallet_rpc("early")
        for wallet in (reserve, early):
            wallet.staking(False)
        reserve_legacy = reserve.getnewaddress("", "legacy")
        early_legacy = early.getnewaddress("", "legacy")
        reserve_quantum = reserve.getnewquantumaddress()["address"]

        self.log.info("One legacy coin each; Gold Rush ends")
        self.generatetoaddress(n0, 1, reserve_legacy, sync_fun=self.sync_all)
        self.bump()
        self.generatetoaddress(n0, 1, early_legacy, sync_fun=self.sync_all)
        self.bump()
        self.pow_blocks(n0, G - n0.getblockcount(), pow_addr, sync=True)
        self.pow_blocks(n0, MATURITY + 2, quantum_miner, sync=True)

        self.log.info("The older quantum reserve: the legacy coin of 'reserve' is migrated long before the window")
        reserve.migratetoquantum({"existing_address": reserve_quantum, "max_inputs": 1})
        self.pow_blocks(n0, 1, quantum_miner, sync=True)
        reserve_out = [u for u in reserve.listunspent(1, 9999999, [reserve_quantum]) if u["amount"] > 0]
        assert_equal(len(reserve_out), 1)
        reserve_kernel = {"txid": reserve_out[0]["txid"], "vout": reserve_out[0]["vout"]}
        reserve_value = Decimal(str(reserve_out[0]["amount"]))

        self.log.info("The earliest window payout: 'early' stakes its legacy coin at height %d", WINDOW_START)
        self.pow_blocks(n0, LAST_LEGACY_STAKE_HEIGHT - n0.getblockcount(), quantum_miner, sync=True)
        assert_equal(n0.getblockcount(), LAST_LEGACY_STAKE_HEIGHT)
        early.setquantumstakereturn({"allow_new_quantum_key": True})
        early_coin = early.listunspent(0)[0]
        kernel_hash = self.stake_from(early, {"txid": early_coin["txid"], "vout": early_coin["vout"]})
        coinstake = n0.getblock(kernel_hash, 2)["tx"][1]
        assert_equal(n0.getblock(kernel_hash)["height"], WINDOW_START)
        valued = [o for o in coinstake["vout"] if o["value"] > 0]
        assert_equal(len(valued), 1)
        payout = {"txid": coinstake["txid"], "vout": valued[0]["n"]}
        payout_value = valued[0]["value"]
        payout_script = valued[0]["scriptPubKey"]["hex"]

        self.log.info("Proof of work to M: nothing else stakes, so both kernels reach the first Final block unused")
        self.pow_blocks(n0, M - n0.getblockcount(), quantum_miner, sync=True)
        assert_equal(n0.getblockcount(), M)
        assert_equal(n0.getquantumquasarinfo()["phase"], "final_lockout")  # the phase of the next block, F
        assert_equal(n1.getquantumquasarinfo()["phase"], "final_lockout")

        self.log.info("Block F from the older quantum reserve")
        f_hash = self.stake_from(reserve, reserve_kernel)
        block = n0.getblock(f_hash, 2)
        assert_equal(block["height"], F)
        assert_equal(block["tx"][1]["vin"][0]["txid"], reserve_kernel["txid"])
        assert_equal(block["tx"][1]["vin"][0]["vout"], reserve_kernel["vout"])
        paid = sum(o["value"] for o in block["tx"][1]["vout"])
        assert_equal(paid, reserve_value + SUBSIDY)
        assert_equal(n1.getbestblockhash(), f_hash)

        self.log.info("Block F replaced, from the earliest window payout")
        for node in (n0, n1):
            node.invalidateblock(f_hash)
        assert_equal(n0.getblockcount(), M)
        assert_equal(n1.getblockcount(), M)
        self.bump()
        f2_hash = self.stake_from(early, payout)
        block = n0.getblock(f2_hash, 2)
        assert_equal(block["height"], F)
        assert f2_hash != f_hash
        assert_equal(block["tx"][1]["vin"][0]["txid"], payout["txid"])
        assert_equal(block["tx"][1]["vin"][0]["vout"], payout["vout"])
        outputs = [o for o in block["tx"][1]["vout"] if o["value"] > 0]
        assert_equal(sum(o["value"] for o in outputs), payout_value + SUBSIDY)
        assert all(o["scriptPubKey"]["hex"] == payout_script for o in outputs), outputs
        assert_equal(n1.getbestblockhash(), f2_hash)
        assert_equal(n1.getquantumquasarinfo()["phase"], "final_lockout")


if __name__ == '__main__':
    FirstFinalBlockKernelsTest().main()
