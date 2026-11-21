#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""getquantumstakereadiness on a mixed wallet.

The report runs the staker's own candidate scan, so what it calls eligible is what the staker
selects. The wallet here holds, at tip 76 (next block 77, first Final block F=92, maturity 10):

 * two legacy coins still to migrate;
 * Q1 an old quantum output (eligible now);
 * Q2 a quantum output made two blocks ago (immature now, eligible by F);
 * Q3 a quantum output that is coin-locked (the change of the payment that made Q4);
 * Q4 a quantum output of 0.05 (below the 0.1 staking minimum);
 * a reserve balance larger than the legacy stake, so part of Q1 is held back.

The report must count each under the right reason, for the next block and for F, agree with the
staker (a block template is built for exactly the outputs the report calls eligible and refused
for the locked one), and show the unlock state: a fully locked wallet has no signer (everything
that would stake is counted as signer_unavailable), a staking-only unlock does.

Regtest: Gold Rush ends at G=61, Migration ends at M=91 (F=92).
"""
from decimal import Decimal

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_raises_rpc_error
from transition_t_final_util import F, G, LIFECYCLE_ARGS, M, TransitionTFinalTestBase

PASSPHRASE = "pw"
RESERVE = Decimal("25000")


class QuantumStakeReadinessTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.extra_args = [LIFECYCLE_ARGS]

    def amount_at(self, wallet, address):
        return sum((Decimal(str(u["amount"])) for u in wallet.listunspent(0, 9999999, [address])), Decimal(0))

    def outpoint_at(self, wallet, address):
        unspent = [u for u in wallet.listunspent(0, 9999999, [address]) if u["amount"] > 0]
        assert_equal(len(unspent), 1)
        return {"txid": unspent[0]["txid"], "vout": unspent[0]["vout"]}

    def run_test(self):
        node = self.nodes[0]
        default = node.get_wallet_rpc(self.default_wallet_name)
        default.staking(False)
        self.set_initial_mt()
        pow_addr = default.getnewaddress("", "legacy")
        quantum_miner = default.getnewquantumaddress()["address"]

        node.createwallet("mix", passphrase=PASSPHRASE)
        mix = node.get_wallet_rpc("mix")
        mix.staking(False)
        mix.walletpassphrase(PASSPHRASE, 100000000)
        legacy_addr = mix.getnewaddress("", "legacy")
        q1, q2, q3, q4 = (mix.getnewquantumaddress()["address"] for _ in range(4))

        self.log.info("Five legacy coinbases; Gold Rush ends; the quantum miner pays after it")
        self.generatetoaddress(node, 5, legacy_addr)
        self.bump()
        self.pow_blocks(node, G - node.getblockcount(), pow_addr)
        self.pow_blocks(node, 64 - node.getblockcount(), quantum_miner)

        self.log.info("Three migration batches (one legacy coin each): Q1 and Q3 now, Q2 later")
        mix.migratetoquantum({"existing_address": q1, "max_inputs": 1})
        mix.migratetoquantum({"existing_address": q3, "max_inputs": 1})
        self.pow_blocks(node, 74 - node.getblockcount(), quantum_miner)
        mix.migratetoquantum({"existing_address": q2, "max_inputs": 1})
        # Q4: a small payment out of Q3's output (the change returns to Q3's address).
        mix.send(outputs=[{q4: Decimal("0.05")}],
                 options={"inputs": [self.outpoint_at(mix, q3)], "add_inputs": False, "change_address": q3})
        self.pow_blocks(node, 76 - node.getblockcount(), quantum_miner)
        assert_equal(node.getblockcount(), 76)

        q1_amount, q2_amount, q3_amount, q4_amount = (self.amount_at(mix, a) for a in (q1, q2, q3, q4))
        assert_equal(q4_amount, Decimal("0.05"))
        legacy_unspent = [u for u in mix.listunspent(0) if u["scriptPubKey"].startswith("76a914")]
        assert_equal(len(legacy_unspent), 2)
        legacy_amount = sum(Decimal(str(u["amount"])) for u in legacy_unspent)
        q3_out = self.outpoint_at(mix, q3)
        mix.lockunspent(False, [q3_out])
        mix.reservebalance(True, RESERVE)

        self.log.info("Next block: Q1 eligible, Q2 immature, Q3 locked, Q4 below the minimum; reserve held back")
        r = mix.getquantumstakereadiness()
        assert_equal(r["next_height"], 77)
        assert_equal(r["final_height"], F)
        assert_equal(r["blocks_to_final"], F - 77)
        assert_equal(r["quantum_outputs"], 4)
        assert_equal(r["quantum_total"], q1_amount + q2_amount + q3_amount + q4_amount)
        nb = r["next_block"]
        assert_equal(nb["height"], 77)
        assert_equal(nb["eligible_outputs"], 1)
        assert_equal(nb["eligible"], q1_amount)
        # The legacy stake (two coins) absorbs part of the reserve; the rest is held back from Q1.
        assert_equal(nb["reserve_withheld"], RESERVE - legacy_amount)
        assert_equal(nb["stakeable"], q1_amount - (RESERVE - legacy_amount))
        assert_equal(nb["excluded"]["immature"], {"count": 1, "amount": q2_amount})
        assert_equal(nb["excluded"]["locked"], {"count": 1, "amount": q3_amount})
        assert_equal(nb["excluded"]["below_minimum"], {"count": 1, "amount": q4_amount})
        assert_equal(nb["excluded"]["signer_unavailable"], {"count": 0, "amount": 0})
        assert_equal(nb["excluded"]["other"], {"count": 0, "amount": 0})
        assert_equal(Decimal(str(nb["eligible"])) + sum(Decimal(str(nb["excluded"][k]["amount"])) for k in nb["excluded"]),
                     r["quantum_total"])

        self.log.info("First Final block: with current maturities Q2 joins Q1")
        fb = r["at_final"]
        assert_equal(fb["height"], F)
        assert_equal(fb["eligible_outputs"], 2)
        assert_equal(fb["eligible"], q1_amount + q2_amount)
        assert_equal(fb["excluded"]["immature"], {"count": 0, "amount": 0})
        assert_equal(fb["excluded"]["locked"], {"count": 1, "amount": q3_amount})
        assert_equal(fb["excluded"]["below_minimum"], {"count": 1, "amount": q4_amount})
        # At Final no legacy stake is left, so the whole reserve comes off the quantum stake.
        assert_equal(fb["reserve_withheld"], min(RESERVE, q1_amount + q2_amount))

        self.log.info("Legacy value still to migrate, as the migration status counts it")
        assert_equal(r["legacy_outputs"], 2)
        assert_equal(r["legacy_to_migrate"], legacy_amount)
        assert_equal(Decimal(str(mix.getmigrationstatus()["eligible_legacy_amount"])), legacy_amount)

        self.log.info("Stake return address: not set, with the reason")
        assert_equal(r["stake_return"]["ready"], False)
        assert "action" in r["stake_return"]
        assert_equal(r["stake_return"]["backup_verified"], False)
        assert_equal(r["wallet_locked"], False)
        assert_equal(r["staking_only_unlock"], False)
        assert_equal(r["reserve_balance"], RESERVE)
        assert_equal(r["minimum_stake_amount"], Decimal("0.1"))

        self.log.info("Unlock state: a locked wallet has no signer")
        mix.walletlock()
        r = mix.getquantumstakereadiness()
        assert_equal(r["wallet_locked"], True)
        nb = r["next_block"]
        assert_equal(nb["eligible_outputs"], 0)
        assert_equal(nb["excluded"]["signer_unavailable"], {"count": 1, "amount": q1_amount})
        assert_equal(r["at_final"]["excluded"]["signer_unavailable"], {"count": 2, "amount": q1_amount + q2_amount})
        self.log.info("...a staking-only unlock has one")
        mix.walletpassphrase(PASSPHRASE, 100000000, True)
        r = mix.getquantumstakereadiness()
        assert_equal(r["wallet_locked"], False)
        assert_equal(r["staking_only_unlock"], True)
        assert_equal(r["next_block"]["eligible_outputs"], 1)
        assert_equal(r["next_block"]["eligible"], q1_amount)
        assert_equal(r["next_block"]["excluded"]["signer_unavailable"], {"count": 0, "amount": 0})

        self.log.info("The staker agrees: a template is built for Q1 and refused for the locked Q3")
        # Ten blocks on, Q3 is old enough for consensus to accept it as a kernel.
        self.pow_blocks(node, 84 - node.getblockcount(), quantum_miner)
        mix.reservebalance(False)
        q1_out = self.outpoint_at(mix, q1)
        self.kernel_slot_for(mix, q1_out)
        assert "blocktemplate" in mix.checkkernel([q1_out], True)
        self.bump()
        self.kernel_slot_for(mix, q3_out)
        assert_raises_rpc_error(-32603, "Couldn't create a valid proof-of-stake block template", mix.checkkernel, [q3_out], True)
        assert node.getblockcount() <= M


if __name__ == '__main__':
    QuantumStakeReadinessTest().main()
