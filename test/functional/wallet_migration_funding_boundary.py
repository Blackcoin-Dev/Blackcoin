#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""A partial migration batch is authorised only when every later batch can be paid for.

One legacy anchor and three small witness-only outputs, one input per call (max_inputs=1). The
first batch spends the anchor alone; each of the three later batches spends the quantum output of
the one before it (the anchor and fee source, about 1,000 vbytes of ML-DSA witness) together with
one witness input worth less than its own fee. The old check compared the remainder with ONE fee for
the legacy inputs alone, so it let through an anchor that could not pay for the later batches and left
the wallet holding legacy coins no call could move. The wallet now simulates every later batch with
the actual auxiliary input, the selected max_inputs, the fee rate and the dust limit.

A ladder of anchors, from far too small to ample, is tried one at a time with a dry run:

 * the small ones are refused before anything is built or broadcast;
 * the ample ones are accepted and report the batches still to come, their fees and the fewest
   blocks they need (each later batch waits for the output it spends to confirm);
 * the first accepted rung is within a few thousandths of the amount the plan needs (the sum of
   later fees less the witness value, plus dust), so the boundary is the plan's and not a guess;
 * a real migration from that rung finishes all four batches; a real call from the rung below it
   is refused with nothing in the mempool and the anchor untouched.

Regtest: Gold Rush ends at G=61, Migration ends at M=91.
"""
from decimal import Decimal

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_greater_than, assert_raises_rpc_error
from transition_t_final_util import G, LIFECYCLE_ARGS, M, MATURITY, TransitionTFinalTestBase

WITNESS_VALUE = Decimal("0.0005")
WITNESS_OUTPUTS = 3
LADDER_START = Decimal("0.0016")
LADDER_STEP = Decimal("0.0001")
LADDER_RUNGS = 60


class MigrationFundingBoundaryTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.extra_args = [LIFECYCLE_ARGS + ["-addresstype=bech32", "-changetype=bech32"]]

    def dry(self, wallet, address):
        return wallet.migratetoquantum({"existing_address": address, "max_inputs": 1, "dry_run": True})

    def run_test(self):
        node = self.nodes[0]
        wallet = node.get_wallet_rpc(self.default_wallet_name)
        wallet.staking(False)
        self.set_initial_mt()
        self.w_addr = wallet.getnewaddress("", "bech32")

        self.log.info("Before Gold Rush ends: a ladder of legacy anchors and three small witness outputs")
        self.generatetoaddress(node, 2 * MATURITY + 10, self.w_addr)
        self.bump()
        ladder = [LADDER_START + LADDER_STEP * i for i in range(LADDER_RUNGS)]
        ladder_addrs = {wallet.getnewaddress("", "legacy"): amount for amount in ladder}
        witness_addrs = {wallet.getnewaddress("", "bech32"): WITNESS_VALUE for _ in range(WITNESS_OUTPUTS)}
        wallet.sendmany("", {**ladder_addrs, **witness_addrs})
        self.generatetoaddress(node, 1, self.w_addr)
        self.sync_mt_tip()
        self.pow_blocks(node, G - node.getblockcount(), self.w_addr)
        address = wallet.getnewquantumaddress()["address"]
        self.w_addr = address
        self.pow_blocks(node, 1 + MATURITY, address)
        assert_equal(node.getquantumquasarinfo()["phase"], "migration")
        assert node.getblockcount() <= M - 10

        self.log.info("Lock everything but the ladder and the witness outputs, then try one rung at a time")
        rungs = {}  # amount -> outpoint
        keep = set()
        lock = []
        for u in wallet.listunspent(1):
            outpoint = {"txid": u["txid"], "vout": u["vout"]}
            amount = Decimal(str(u["amount"]))
            if u["address"] in ladder_addrs:
                rungs[amount] = outpoint
            elif u["address"] in witness_addrs:
                keep.add((u["txid"], u["vout"]))
            else:
                lock.append(outpoint)
        assert_equal(len(rungs), LADDER_RUNGS)
        assert_equal(len(keep), WITNESS_OUTPUTS)
        wallet.lockunspent(False, lock)
        wallet.lockunspent(False, list(rungs.values()))

        results = {}
        for amount in ladder:
            wallet.lockunspent(True, [rungs[amount]])
            try:
                results[amount] = self.dry(wallet, address)
            except Exception as e:  # a refusal is a JSON-RPC error carrying the reason
                results[amount] = str(e)
            wallet.lockunspent(False, [rungs[amount]])

        accepted = [a for a in ladder if isinstance(results[a], dict)]
        refused = [a for a in ladder if not isinstance(results[a], dict)]
        self.log.info("sample: %s" % results[ladder[-1]])
        assert refused and accepted, (len(refused), len(accepted))
        # monotone: every rung from the first accepted one up is accepted
        assert_equal(accepted, ladder[len(refused):])
        for a in refused:
            assert "cannot be migrated afterwards" in results[a], results[a]
            assert "no anchor" in results[a] or "pay its fee" in results[a], results[a]
        first_ok = accepted[0]
        last_refused = refused[-1]
        ok = results[first_ok]
        assert_equal(ok["more_batches"], True)
        assert_equal(ok["remaining_inputs"], WITNESS_OUTPUTS)
        assert_equal(ok["continuation_batches"], WITNESS_OUTPUTS)
        assert_equal(ok["minimum_blocks_to_finish"], 1 + WITNESS_OUTPUTS)  # each later batch waits for the output it spends
        for a in accepted:
            assert_equal(results[a]["continuation_batches"], WITNESS_OUTPUTS)
            assert_equal(results[a]["continuation_fees"], ok["continuation_fees"])

        self.log.info("The boundary is the plan's: later fees less the witness value, plus dust and the first fee")
        later_fees = Decimal(str(ok["continuation_fees"]))
        first_fee = Decimal(str(ok["fee"]))
        needed = later_fees - WITNESS_VALUE * WITNESS_OUTPUTS + first_fee  # anchor value that pays everything but dust
        per_batch_fee = later_fees / WITNESS_OUTPUTS
        # The last output must still clear the dust limit (large on this chain), so the boundary sits
        # above `needed` by about that limit and by no more than it plus one rung.
        assert_greater_than(first_ok, needed)
        assert first_ok - needed < Decimal("0.002"), (first_ok, needed)
        # An anchor that pays for one later batch twice over is still refused: the old estimate compared
        # the remainder with one fee for the legacy inputs alone and would have let it through.
        assert_greater_than(first_ok, 2 * (per_batch_fee + first_fee))
        assert_greater_than(Decimal("0.0001") + last_refused, needed - Decimal("0.0001"))

        self.log.info("Refused for real: nothing is built, broadcast or spent")
        wallet.lockunspent(True, [rungs[last_refused]])
        assert_raises_rpc_error(-4, "cannot be migrated afterwards", wallet.migratetoquantum,
                                {"existing_address": address, "max_inputs": 1})
        assert_equal(node.getrawmempool(), [])
        assert node.gettxout(rungs[last_refused]["txid"], rungs[last_refused]["vout"]) is not None
        wallet.lockunspent(False, [rungs[last_refused]])

        self.log.info("Barely funded: all four batches go through, one per block")
        wallet.lockunspent(True, [rungs[first_ok]])
        for step in range(1 + WITNESS_OUTPUTS):
            result = wallet.migratetoquantum({"existing_address": address, "max_inputs": 1})
            assert_equal(result["eligible_inputs"], 1)
            assert_equal(result["auxiliary_inputs"], 0 if step == 0 else 1)
            assert_equal(result["remaining_inputs"], WITNESS_OUTPUTS - step)
            self.generatetoaddress(node, 1, self.w_addr)
            self.bump()
        # nothing of the four outputs in play is left (the other rungs and the coinbases stay locked)
        assert_raises_rpc_error(-6, "No spendable legacy coins", wallet.migratetoquantum, {"existing_address": address, "max_inputs": 1})
        assert node.getblockcount() <= M


if __name__ == '__main__':
    MigrationFundingBoundaryTest().main()
