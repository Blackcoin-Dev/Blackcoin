#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""getquantumstakereadiness: the first Final block is projected only from a complete height schedule,
and the projection uses the Gold Rush lock as it will be at Final.

 * A Gold Rush payout (a quantum output the wallet owns from a shadow claim) is locked while Gold Rush
   runs and unlocked after it. Before Gold Rush ends the next block excludes it, but the first Final
   block does not: the projection must say eligible there. The old projection read the lock at the
   current tip and called it locked at Final too. The staker agrees once Final is next: a template is
   built from that payout.
 * A time-only schedule (no heights) has no block count for Final: final_height_known is false and
   there is no final_height, blocks_to_final or at_final, instead of a height made of default values.

Regtest: Gold Rush ends at G=61, Migration ends at M=91 (F=92).
"""
from decimal import Decimal

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal
from transition_t_final_util import F, G, LIFECYCLE_ARGS, M, MATURITY, TransitionTFinalTestBase


class QuantumStakeReadinessScheduleTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 2
        self.setup_clean_chain = True
        # Node 1 has only a time schedule: no heights.
        self.extra_args = [LIFECYCLE_ARGS,
                           ["-allowunsafequantumkeyrpc=1", "-qqgoldrushendtime=2000000000",
                            "-qqmigrationdeadlinetime=2000005008"]]

    def run_test(self):
        node, time_node = self.nodes
        self.disconnect_nodes(0, 1)
        w = node.get_wallet_rpc(self.default_wallet_name)
        w.staking(False)
        self.set_initial_mt()
        fee = w.getnewaddress("", "legacy")
        payout_addr = w.getnewquantumaddress()["address"]
        quantum_miner = w.getnewquantumaddress()["address"]

        self.log.info("A time-only schedule has no Final height")
        tw = time_node.get_wallet_rpc(self.default_wallet_name)
        tw.staking(False)
        r = tw.getquantumstakereadiness()
        assert_equal(r["final_height_known"], False)
        for key in ("final_height", "blocks_to_final", "at_final"):
            assert key not in r, (key, r)
        assert "next_block" in r

        self.log.info("A Gold Rush payout from a claim, made well before the end of Gold Rush")
        self.generatetoaddress(node, 3, fee, sync_fun=self.no_op)
        self.bump()
        self.pow_blocks(node, 2 * MATURITY, fee)
        claim = w.sendshadowpowclaim(fee, payout_addr, 500000)
        self.stake_one(w, node)
        assert claim["txid"] not in node.getrawmempool()
        payouts = w.listunspent(0, 9999999, [payout_addr], True, {"include_immature_coinbase": True})
        assert_equal(len(payouts), 1)
        payout = {"txid": payouts[0]["txid"], "vout": payouts[0]["vout"]}
        amount = Decimal(str(payouts[0]["amount"]))
        self.pow_blocks(node, G - 12 - node.getblockcount(), fee)
        assert node.getblockcount() < G

        self.log.info("Before the end of Gold Rush: excluded for the next block, eligible at Final")
        r = w.getquantumstakereadiness()
        assert_equal(r["final_height_known"], True)
        assert_equal(r["final_height"], F)
        nb, fb = r["next_block"], r["at_final"]
        assert_equal(nb["eligible_outputs"], 0)
        assert_equal(fb["height"], F)
        assert_equal(fb["eligible_outputs"], 1)
        assert_equal(fb["eligible_nominal"], amount)
        assert_equal(fb["excluded"]["locked"], {"count": 0, "amount": 0})

        self.log.info("The staker agrees when Final is next: a template is built from the payout")
        self.pow_blocks(node, G - node.getblockcount(), fee)
        self.pow_blocks(node, M - node.getblockcount(), quantum_miner)
        assert_equal(node.getblockcount(), M)
        r = w.getquantumstakereadiness()
        assert_equal(r["next_height"], F)
        assert_equal(r["blocks_to_final"], 0)
        assert_equal(r["next_block"]["eligible_outputs"], 1)
        assert_equal(r["next_block"]["eligible_nominal"], amount)
        self.bump()
        self.kernel_slot_for(w, payout)
        assert "blocktemplate" in w.checkkernel([payout], True)


if __name__ == '__main__':
    QuantumStakeReadinessScheduleTest().main()
