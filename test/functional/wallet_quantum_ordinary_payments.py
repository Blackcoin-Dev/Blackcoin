#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Ordinary quantum payments after Final need no legacy anchor.

A wallet that holds NO legacy coins at all after Final, only

 (a) funds moved with migratetoquantum during Migration, and
 (b) authenticated Gold Rush payouts (claims included by a real PoS block),

makes repeated ordinary payments to quantum recipients with sendtoaddress, sendmany and send:

 * 12 payments in a row inside one block interval from a single funding coin, so that every payment
   after the first spends the unconfirmed change of the one before it (checked on the inputs);
 * 24 more across four further blocks, with all of the wallet's coins available;
 * all are accepted and confirmed. Nothing in the wallet is a legacy output and none is a quantum
   coinbase.

A separate, clearly labelled case (designed behaviour, the same as 30.1.6) uses a wallet that holds
only arbitrary quantum coinbases mined to it. Such a coin has no protected lineage (its address alone
does not establish provenance), so `send` is refused with the lineage error, once during Migration and
once after Final (during Migration sendtoaddress and sendmany report insufficient funds for the same
wallet, after Final they report the lineage error too). After Final the message must not tell the user to add a legacy anchor, since
legacy spending is no longer permitted.

BLACKCOIN_ORDINARY_PAYMENTS_BASELINE=1 runs the same test against an unmodified 30.1.6 binary: it is a
characterisation test there, and only the wording of the Final-phase message differs.

Regtest lifecycle: Gold Rush ends at G=61, Migration ends at M=91, the first Final block is F=92.
"""
from decimal import Decimal
import os

from test_framework.authproxy import JSONRPCException
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_raises_rpc_error
from transition_t_final_util import F, G, LIFECYCLE_ARGS, M, MATURITY, TransitionTFinalTestBase

BASELINE = os.environ.get("BLACKCOIN_ORDINARY_PAYMENTS_BASELINE") == "1"
LINEAGE_ERROR = "no fork-unique Quantum Quasar lineage"
FINAL_ADVICE = "a quantum input with protected lineage"
ANCHOR_ADVICE = "Add/select a P2PKH or non-witness P2SH anchor input"


class QuantumOrdinaryPaymentsTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.extra_args = [LIFECYCLE_ARGS + ["-qqautodemurrageattest=0"]]

    def utxos(self, wallet, minconf=0):
        return wallet.listunspent(minconf, 9999999, [], True, {"include_immature_coinbase": True})

    def assert_quantum_only(self, wallet):
        """Every unspent output of the wallet is quantum (none legacy) and none is a coinbase."""
        quantum = {k["address"] for k in wallet.listquantumaddresses()}
        unspent = self.utxos(wallet)
        assert unspent
        for u in unspent:
            assert u["address"] in quantum, u
            assert not u.get("coinbase"), u

    def refused_for_lineage(self, wallet, address, change, coin, final):
        """The lineage error, in the wording of the phase. During Migration sendtoaddress and sendmany fall back to
        legacy inputs and then report insufficient funds, as in 30.1.6; `send` and, after Final, all three report
        the lineage error itself. After Final the message must not advise a legacy anchor."""
        def check_lineage(message):
            assert LINEAGE_ERROR in message, message
            if final and not BASELINE:
                assert FINAL_ADVICE in message, message
                assert "Add/select" not in message and "anchor" not in message, message
            else:
                assert ANCHOR_ADVICE in message, message
                assert FINAL_ADVICE not in message, message

        calls = [
            lambda: wallet.sendtoaddress(address=address, amount=1, change_address=change),
            lambda: wallet.sendmany(amounts={address: 1}, change_address=change),
        ]
        for call in calls:
            try:
                call()
            except JSONRPCException as e:
                if final:
                    check_lineage(e.error["message"])
                else:
                    assert_equal(e.error["code"], -6)
                    assert "Insufficient funds" in e.error["message"], e.error["message"]
            else:
                raise AssertionError("a quantum coinbase alone must not fund a payment")
        for options in ({"change_address": change},
                        {"change_address": change, "inputs": [{"txid": coin["txid"], "vout": coin["vout"]}]}):
            try:
                wallet.send(outputs=[{address: 1}], options=options)
            except JSONRPCException as e:
                assert_equal(e.error["code"], -4)
                check_lineage(e.error["message"])
            else:
                raise AssertionError("a quantum coinbase alone must not fund a payment")

    def mine_pos_block_with_claim(self, wallet, node, claim_txid):
        block = node.getblock(self.stake_one(wallet, node), 2)
        assert claim_txid in [tx["txid"] for tx in block["tx"]][2:], "the claim must be in the PoS block"

    def pay(self, kind, wallet, address, amount, change):
        """One ordinary payment; the change goes to an existing wallet-owned quantum address."""
        if kind == 0:
            return wallet.sendtoaddress(address=address, amount=amount, change_address=change)
        if kind == 1:
            return wallet.sendmany(amounts={address: amount}, change_address=change)
        return wallet.send(outputs=[{address: amount}], options={"change_address": change})["txid"]

    def run_test(self):
        node = self.nodes[0]
        default = node.get_wallet_rpc(self.default_wallet_name)
        default.staking(False)
        self.set_initial_mt()
        filler = default.getnewaddress("", "legacy")
        node.createwallet("q")
        node.createwallet("recipient")
        node.createwallet("coinbase_only")
        node.createwallet("miner")  # receives the quantum coinbases of the Final blocks, so none reach wallet q
        q = node.get_wallet_rpc("q")
        recipient = node.get_wallet_rpc("recipient")
        cb = node.get_wallet_rpc("coinbase_only")
        miner = node.get_wallet_rpc("miner")
        for w in (q, recipient, cb, miner):
            w.staking(False)

        self.log.info("Gold Rush: the wallet earns two authenticated payouts through real claims in PoS blocks")
        stake_addr = q.getnewaddress("", "legacy")
        claim_addrs = [q.getnewaddress("", "legacy") for _ in range(2)]
        payout_addrs = [q.getnewquantumaddress()["address"] for _ in range(2)]
        migration_dest = q.getnewquantumaddress()["address"]
        self.pow_blocks(node, 1 + MATURITY + 2, stake_addr)
        for claim_addr in claim_addrs:
            self.pow_blocks(node, MATURITY + 2, claim_addr)
        assert_equal(node.getquantumquasarinfo()["phase"], "gold_rush")
        for claim_addr, payout_addr in zip(claim_addrs, payout_addrs):
            claim = q.sendshadowpowclaim(claim_addr, payout_addr, 500000)
            self.mine_pos_block_with_claim(q, node, claim["txid"])
        self.pow_blocks(node, G - node.getblockcount(), filler)
        self.pow_blocks(node, 1 + MATURITY, filler)
        assert_equal(node.getquantumquasarinfo()["phase"], "migration")
        payouts = [u for u in self.utxos(q) if u["address"] in payout_addrs]
        assert_equal(len(payouts), 2)
        assert all(u["confirmations"] > MATURITY for u in payouts), payouts

        self.log.info("Migration: everything legacy moves to quantum with migratetoquantum")
        for _ in range(12):
            try:
                q.migratetoquantum({"existing_address": migration_dest})
            except Exception as e:
                assert "No spendable legacy coins" in str(e), e
                break
            self.pow_blocks(node, 1, filler)
        else:
            raise AssertionError("migration did not finish")
        self.pow_blocks(node, 1, filler)
        assert_raises_rpc_error(-6, "No spendable legacy coins", q.migratetoquantum, {"existing_address": migration_dest})
        self.assert_quantum_only(q)
        assert node.getblockcount() < M - MATURITY - 2, node.getblockcount()

        self.log.info("Case B (designed, same as 30.1.6), Migration: only quantum coinbases, no legacy: the lineage error with the anchor advice")
        cb_addr = cb.getnewquantumaddress()["address"]
        self.pow_blocks(node, 1, cb_addr)
        self.pow_blocks(node, MATURITY, filler)
        assert node.getblockcount() < M, node.getblockcount()
        assert_equal(node.getquantumquasarinfo()["phase"], "migration")
        cb_coins = [u for u in self.utxos(cb) if u["address"] == cb_addr]
        assert_equal(len(cb_coins), 1)
        assert cb_coins[0]["confirmations"] > MATURITY
        recipient_addr = recipient.getnewquantumaddress()["address"]
        cb_change = cb.getnewquantumaddress()["address"]
        self.refused_for_lineage(cb, recipient_addr, cb_change, cb_coins[0], final=False)

        self.log.info("Advance to Final (legacy outputs are refused from here on, so the blocks pay a quantum address of a separate wallet)")
        miner_addr = miner.getnewquantumaddress()["address"]
        self.pow_blocks(node, F - 1 - node.getblockcount(), filler)
        self.pow_blocks(node, 1, miner_addr)
        assert_equal(node.getquantumquasarinfo()["phase"], "final_lockout")
        self.assert_quantum_only(q)

        self.log.info("Case B, Final: the same wallet; the message no longer advises a legacy anchor")
        self.refused_for_lineage(cb, recipient_addr, cb_change, cb_coins[0], final=True)

        self.log.info("Case A: only migrated funds and Gold Rush payouts, 12 chained payments in one block interval")
        coins = self.utxos(q, 1)
        assert all(u["spendable"] for u in coins)
        migrated = [(u["txid"], u["vout"]) for u in coins if u["address"] == migration_dest]
        assert migrated, "the migrated funds must be in the wallet"
        funding = next(u for u in coins if u["address"] in payout_addrs)  # the chain starts from a Gold Rush payout
        locks = [{"txid": u["txid"], "vout": u["vout"]} for u in coins if (u["txid"], u["vout"]) != (funding["txid"], funding["vout"])]
        q.lockunspent(False, locks)
        change_addr = q.getnewquantumaddress()["address"]
        recipient_addrs = [recipient.getnewquantumaddress()["address"] for _ in range(64)]
        sent = []
        spent_unconfirmed_change = 0
        for i in range(12):
            txid = self.pay(i % 3, q, recipient_addrs[len(sent)], Decimal("3") + i, change_addr)
            sent.append(txid)
            if i:
                inputs = [v["txid"] for v in node.getrawtransaction(txid, True)["vin"]]
                assert inputs and all(parent in sent[:-1] for parent in inputs), (i, inputs)
                spent_unconfirmed_change += 1
        assert_equal(spent_unconfirmed_change, 11)
        assert_equal(len(set(sent)), 12)
        self.pow_blocks(node, 1, miner_addr)
        for txid in sent:
            assert node.getrawtransaction(txid, True)["confirmations"] >= 1, txid
        q.lockunspent(True, locks)

        self.log.info("24 more payments across four blocks, all coins available (including the payouts)")
        for round_number in range(4):
            round_sent = []
            for i in range(6):
                index = len(sent) + len(round_sent)
                round_sent.append(self.pay(index % 3, q, recipient_addrs[index], Decimal("2") + i, change_addr))
            sent += round_sent
            self.pow_blocks(node, 1, miner_addr)
            for txid in round_sent:
                assert node.getrawtransaction(txid, True)["confirmations"] >= 1, txid
        assert_equal(len(sent), 36)
        assert_equal(len(set(sent)), 36)
        assert_equal(node.getrawmempool(), [])
        self.assert_quantum_only(q)
        assert any(node.gettxout(txid, vout) is None for txid, vout in migrated), "migrated funds were spent too"
        assert node.gettxout(funding["txid"], funding["vout"]) is None, "the payout was spent"
        quantum = {k["address"] for k in q.listquantumaddresses()}
        for tx in q.listtransactions("*", 1000):
            assert not (tx.get("generated") and tx.get("address") in quantum and tx.get("address") not in payout_addrs), tx  # no quantum coinbase ever reached q
        assert recipient.getbalances()["mine"]["trusted"] > 0

if __name__ == '__main__':
    QuantumOrdinaryPaymentsTest().main()
