#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""A partial migration batch always leaves a way to finish.

During Migration every transaction after Gold Rush must descend from protected lineage. Witness
legacy inputs carry none, so a batch needs an anchor: a legacy P2PKH or non-witness P2SH output
signed with FORKID, or a post-Gold-Rush non-coinbase output. A wallet whose coins are all
witness outputs plus ONE P2PKH anchor used to spend that anchor in its first batch and then
fail on the next call (the anchor was gone, and the first batch's own quantum output was never
considered an input). Now the confirmed quantum output of the earlier batch anchors and funds
the next one:

 * one anchor, more than one batch of witness inputs, 2 inputs per call;
 * max_inputs=1 (the first batch is the anchor alone) and then 2 per call;
 * a tail whose fee its own value cannot pay is subsidised by the earlier, larger output, and
   the auxiliary quantum value is reported separately from the legacy value moved;

The refusal of a partial batch whose destination could not anchor the rest, or whose output is too
small to fund the remainder, is in BuildMigrationBatch and is not covered by a functional test.

Regtest: Gold Rush ends at G=61, Migration ends at M=91.
"""
from decimal import Decimal

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_greater_than
from transition_t_final_util import G, LIFECYCLE_ARGS, M, MATURITY, TransitionTFinalTestBase

WITNESS_OUTPUTS = 7
WITNESS_AMOUNT = Decimal("100")
TAIL_AMOUNT = Decimal("0.0001")  # too small to pay for its own migration


class MigrationContinuationTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.extra_args = [LIFECYCLE_ARGS + ["-addresstype=bech32", "-changetype=bech32"]]

    def migrate_all(self, wallet, address, limits, stop_after):
        calls = []
        for i in range(stop_after):
            status = wallet.getmigrationstatus()
            if status["eligible_legacy_inputs"] == 0:
                break
            max_inputs = limits[min(i, len(limits) - 1)]
            result = wallet.migratetoquantum({"existing_address": address, "max_inputs": max_inputs})
            calls.append(result)
            self.generatetoaddress(self.nodes[0], 1, self.w_addr)
            self.bump()
        return calls

    def run_test(self):
        node = self.nodes[0]
        wallet = node.get_wallet_rpc(self.default_wallet_name)
        wallet.staking(False)
        self.set_initial_mt()
        self.w_addr = wallet.getnewaddress("", "bech32")
        anchor_addr = wallet.getnewaddress("", "legacy")

        self.log.info("Before Gold Rush ends: witness coins and exactly one P2PKH anchor")
        self.generatetoaddress(node, 2 * MATURITY + 10, self.w_addr)
        self.bump()
        wallet.sendtoaddress(anchor_addr, Decimal("10"))
        wallet.sendmany("", {wallet.getnewaddress("", "bech32"): WITNESS_AMOUNT for _ in range(WITNESS_OUTPUTS)})
        wallet.sendtoaddress(wallet.getnewaddress("", "bech32"), TAIL_AMOUNT)
        self.generatetoaddress(node, 1, self.w_addr)
        self.sync_mt_tip()
        self.pow_blocks(node, G - node.getblockcount(), self.w_addr)
        # After Gold Rush every block pays a quantum address, so no new legacy coin appears and every
        # pre-Gold-Rush coinbase has matured by the time the batches start.
        address = wallet.getnewquantumaddress()["address"]
        self.w_addr = address
        self.pow_blocks(node, 1 + MATURITY, address)
        assert_equal(node.getquantumquasarinfo()["phase"], "migration")
        assert node.getblockcount() <= M - 15

        legacy = [u for u in wallet.listunspent(1) if u["spendable"]]
        p2pkh = [u for u in legacy if u["scriptPubKey"].startswith("76a914")]
        assert_equal(len(p2pkh), 1)  # the only anchor
        eligible = wallet.getmigrationstatus()["eligible_legacy_inputs"]
        assert_greater_than(eligible, WITNESS_OUTPUTS + 1)

        self.log.info("One anchor: max_inputs=1 first (the anchor alone), then 2 per call")
        calls = self.migrate_all(wallet, address, [1, 1, 1, 2], stop_after=4)
        assert_equal(calls[0]["eligible_inputs"], 1)  # the first batch is the anchor alone
        assert_equal(calls[0]["auxiliary_inputs"], 0)  # a legacy anchor serves the first batch
        assert_equal(calls[1]["eligible_inputs"], 1)  # with max_inputs=1 the continuation still works
        assert_equal(calls[1]["auxiliary_inputs"], 1)  # ...anchored by the first batch's quantum output
        assert Decimal(str(calls[1]["auxiliary_amount"])) > 0
        for c in calls[1:]:
            assert_equal(c["auxiliary_inputs"], 1)
            # the auxiliary value reaches the destination too but is not counted as legacy moved
            assert_greater_than(Decimal(str(c["amount"])), Decimal(str(c["auxiliary_amount"])))

        self.log.info("Everything but the smallest output in one batch, then the tail it cannot pay for alone")
        remaining = wallet.getmigrationstatus()["eligible_legacy_inputs"]
        assert_greater_than(remaining, 3)
        big = wallet.migratetoquantum({"existing_address": address, "max_inputs": remaining - 1})
        assert_equal(big["eligible_inputs"], remaining - 1)
        assert_equal(big["more_batches"], True)
        assert_equal(big["remaining_inputs"], 1)
        self.generatetoaddress(node, 1, self.w_addr)
        self.bump()
        self.log.info("A legacy output that is still immature is reported, not forgotten")
        immature_height = node.getblockcount() + 1
        self.generatetoaddress(node, 1, wallet.getnewaddress("", "legacy"))  # its coinbase is not spendable yet
        self.bump()
        tail = wallet.migratetoquantum({"existing_address": address})
        assert_equal(tail["more_batches"], False)  # no ELIGIBLE input remains ...
        assert_equal(tail["excluded_legacy_outputs"], 1)  # ... but a legacy output does
        assert_greater_than(Decimal(str(tail["excluded_legacy_amount"])), 0)
        assert_equal(tail["next_maturity_height"], immature_height + MATURITY)
        assert_equal(tail["eligible_inputs"], 1)
        assert_equal(Decimal(str(tail["eligible_amount"])), TAIL_AMOUNT)
        assert_equal(tail["auxiliary_inputs"], 1)  # the earlier, large output pays for the tail
        assert_equal(tail["more_batches"], False)
        assert_greater_than(Decimal(str(tail["amount"])), TAIL_AMOUNT)
        self.generatetoaddress(node, 1, self.w_addr)
        assert_equal(wallet.getmigrationstatus()["eligible_legacy_inputs"], 0)
        assert node.getblockcount() <= M


if __name__ == '__main__':
    MigrationContinuationTest().main()
