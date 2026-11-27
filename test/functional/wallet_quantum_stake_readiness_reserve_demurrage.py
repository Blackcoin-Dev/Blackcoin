#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""getquantumstakereadiness: whole-kernel reserve feasibility, and effective versus nominal value.

 1. A wallet whose only stake is one quantum output Q and a reserve balance of one coin. A kernel is
    one whole output and the constructor refuses a kernel whose principal exceeds the selected set
    less the reserve, so Q cannot stake. The old report subtracted the reserve from Q and called
    Q minus one coin "stakeable". The new one says stakeable_outputs 0, and the staker agrees: a
    block template is refused with the reserve on and built with it off.
 2. After Final starts and demurrage has decayed Q, the report shows the nominal and effective
    amounts apart, and the reserve test uses the principal the constructor uses (effective) against
    the allowed balance taken from the nominal total. A reserve just below the decay lets Q stake,
    one just above does not, and the staker agrees in both cases.

Regtest: Gold Rush ends at G=61, Migration ends at M=91, Final from F=92; four demurrage "months"
of four blocks make the 24 block grace window short enough to cross.
"""
from decimal import Decimal, ROUND_DOWN, ROUND_UP

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_raises_rpc_error
from transition_t_final_util import F, G, LIFECYCLE_ARGS, TransitionTFinalTestBase

CENT = Decimal("0.01")


class QuantumStakeReadinessReserveDemurrageTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.extra_args = [LIFECYCLE_ARGS + ["-qqdemurrageblockspermonth=4"]]

    def staker_agrees(self, wallet, outpoint, expect_template):
        self.bump()
        self.kernel_slot_for(wallet, outpoint)
        if expect_template:
            assert "blocktemplate" in wallet.checkkernel([outpoint], True)
        else:
            assert_raises_rpc_error(-32603, "Couldn't create a valid proof-of-stake block template", wallet.checkkernel, [outpoint], True)

    def run_test(self):
        node = self.nodes[0]
        default = node.get_wallet_rpc(self.default_wallet_name)
        default.staking(False)
        self.set_initial_mt()
        pow_addr = default.getnewaddress("", "legacy")
        quantum_miner = default.getnewquantumaddress()["address"]
        node.createwallet("ker")
        ker = node.get_wallet_rpc("ker")
        ker.staking(False)
        legacy_addr = ker.getnewaddress("", "legacy")
        q_addr = ker.getnewquantumaddress()["address"]

        self.log.info("One legacy coin, migrated to one quantum output Q; it is the wallet's only stake")
        self.generatetoaddress(node, 1, legacy_addr)
        self.bump()
        self.pow_blocks(node, 12, pow_addr)
        self.pow_blocks(node, G - node.getblockcount(), pow_addr)
        self.pow_blocks(node, 3, quantum_miner)
        ker.migratetoquantum({"existing_address": q_addr, "max_inputs": 1})
        self.pow_blocks(node, 76 - node.getblockcount(), quantum_miner)
        q_unspent = [u for u in ker.listunspent(0, 9999999, [q_addr]) if u["amount"] > 0]
        assert_equal(len(q_unspent), 1)
        q_out = {"txid": q_unspent[0]["txid"], "vout": q_unspent[0]["vout"]}
        q = Decimal(str(q_unspent[0]["amount"]))

        self.log.info("Reserve of one coin: the only kernel is Q, which does not fit in Q less one coin")
        ker.reservebalance(True, Decimal("1"))
        nb = ker.getquantumstakereadiness()["next_block"]
        assert_equal(nb["eligible_outputs"], 1)
        assert_equal(nb["eligible_nominal"], q)
        assert_equal(nb["candidate_total"], q)
        assert_equal(nb["allowed_balance"], q - 1)
        assert_equal(nb["stakeable_outputs"], 0)
        assert_equal(nb["stakeable_effective"], 0)
        assert_equal(nb["largest_kernel"], 0)
        self.staker_agrees(ker, q_out, expect_template=False)
        ker.reservebalance(False)
        nb = ker.getquantumstakereadiness()["next_block"]
        assert_equal(nb["allowed_balance"], q)
        assert_equal(nb["stakeable_outputs"], 1)
        assert_equal(nb["largest_kernel"], q)
        self.staker_agrees(ker, q_out, expect_template=True)

        self.log.info("Final, past the demurrage grace window: nominal and effective apart")
        self.pow_blocks(node, F + 40 - node.getblockcount(), quantum_miner)
        r = ker.getquantumstakereadiness()
        assert_equal(r["final_height_known"], True)
        assert_equal(r["blocks_to_final"], 0)
        nb = r["next_block"]
        assert_equal(r["at_final"]["height"], nb["height"])  # Final has started: the same view
        nominal = Decimal(str(nb["eligible_nominal"]))
        effective = Decimal(str(nb["eligible_effective"]))
        assert_equal(nominal, q)
        assert effective < nominal, "demurrage should have decayed Q by now"
        assert effective > 0
        decay = nominal - effective
        assert decay > 10 * CENT
        assert_equal(nb["candidate_total"], q)

        self.log.info("A reserve just below the decay leaves room for the principal; just above does not")
        fits = (decay - 5 * CENT).quantize(CENT, rounding=ROUND_DOWN)
        ker.reservebalance(True, fits)
        nb = ker.getquantumstakereadiness()["next_block"]
        assert_equal(nb["allowed_balance"], q - fits)
        assert_equal(nb["stakeable_outputs"], 1)
        assert_equal(nb["stakeable_effective"], effective)
        self.staker_agrees(ker, q_out, expect_template=True)
        no_fit = (decay + 5 * CENT).quantize(CENT, rounding=ROUND_UP)
        ker.reservebalance(True, no_fit)
        nb = ker.getquantumstakereadiness()["next_block"]
        assert_equal(nb["stakeable_outputs"], 0)
        assert_equal(nb["eligible_effective"], effective)
        self.staker_agrees(ker, q_out, expect_template=False)


if __name__ == '__main__':
    QuantumStakeReadinessReserveDemurrageTest().main()
