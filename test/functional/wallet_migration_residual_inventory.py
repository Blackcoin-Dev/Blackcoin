#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""The migration report inventories every owned legacy output, with a reason for each one left.

"No eligible input remains" is not "no legacy output remains". The report used to read the wallet
through the filtered coin-selection view, which drops an RGB seal, an unconfirmed output that is not
from the wallet and a few more, so a wallet could be told it had finished while it still held
legacy coins. The inventory now walks every unspent output the wallet owns and files each one the
sweep did not consider under one reason:

 * protected_asset: a live RGB seal (never spent automatically);
 * locked: locked with lockunspent;
 * immature: a coinbase that cannot be spent yet;
 * unconfirmed: received, not yet in a block;
 * signer_unavailable: owned for watching only, or without a signer here (a unit test).

Regtest: Gold Rush ends at G=61, Migration ends at M=91.
"""
from decimal import Decimal

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_greater_than
from transition_t_final_util import G, LIFECYCLE_ARGS, MATURITY, TransitionTFinalTestBase


class MigrationResidualInventoryTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 2
        self.setup_clean_chain = True
        self.extra_args = [LIFECYCLE_ARGS + ["-addresstype=bech32", "-changetype=bech32"]] * 2

    def reasons(self, result):
        return {k: (v["count"], Decimal(str(v["amount"]))) for k, v in result["excluded_legacy_by_reason"].items()}

    def run_test(self):
        node, other = self.nodes
        wallet = node.get_wallet_rpc(self.default_wallet_name)
        other_wallet = other.get_wallet_rpc(self.default_wallet_name)
        wallet.staking(False)
        other_wallet.staking(False)
        self.set_initial_mt()
        self.w_addr = wallet.getnewaddress("", "bech32")
        anchor_addr = wallet.getnewaddress("", "legacy")

        self.log.info("Before Gold Rush ends: one P2PKH anchor, a coin to lock, a coin that becomes an RGB seal")
        self.generatetoaddress(node, 2 * MATURITY + 10, self.w_addr)
        self.bump()
        locked_addr = wallet.getnewaddress("", "legacy")
        seal_addr = wallet.getnewaddress("", "legacy")
        wallet.sendtoaddress(anchor_addr, Decimal("1"))
        wallet.sendtoaddress(other_wallet.getnewaddress("", "legacy"), Decimal("5"))  # funds the unconfirmed payment later
        locked_txid = wallet.sendtoaddress(locked_addr, Decimal("0.5"))
        seal_txid = wallet.sendtoaddress(seal_addr, Decimal("0.01"))
        self.generatetoaddress(node, 1, self.w_addr)
        self.sync_mt_tip()

        def vout_of(txid, address):
            decoded = wallet.gettransaction(txid=txid, verbose=True)["decoded"]
            return next(v["n"] for v in decoded["vout"] if v["scriptPubKey"].get("address") == address)

        seal = {"txid": seal_txid, "vout": vout_of(seal_txid, seal_addr)}
        wallet.lockunspent(False, [{"txid": locked_txid, "vout": vout_of(locked_txid, locked_addr)}])
        genesis = {"genesis": {"ticker": "SEAL", "name": "Residual inventory", "total_supply": 500,
                               "allocations": [{"txid": seal["txid"], "vout": seal["vout"], "amount": 500}]},
                   "transitions": []}
        assert_equal(wallet.acceptrgbconsignment(genesis)["valid"], True)

        self.generatetoaddress(node, 1, self.w_addr)
        self.sync_mt_tip()
        self.pow_blocks(node, G - node.getblockcount(), self.w_addr)
        address = wallet.getnewquantumaddress()["address"]
        self.w_addr = address
        self.pow_blocks(node, 1 + MATURITY, address)
        assert_equal(node.getquantumquasarinfo()["phase"], "migration")

        self.log.info("An immature legacy coinbase and an unconfirmed legacy payment from another wallet")
        self.generatetoaddress(node, 1, wallet.getnewaddress("", "legacy"))
        self.bump()
        unconfirmed_addr = wallet.getnewaddress("", "legacy")
        payment = other_wallet.sendtoaddress(unconfirmed_addr, Decimal("0.125"))
        # Hand the (legacy, so witness-free) transaction to node 0 directly; the mock clock makes
        # peer relay slow, and the test is about what the wallet does with the output.
        node.sendrawtransaction(other_wallet.gettransaction(payment)["hex"])
        assert_equal(wallet.gettransaction(payment)["confirmations"], 0)

        result = wallet.migratetoquantum({"existing_address": address, "dry_run": True})
        reasons = self.reasons(result)
        assert_equal(reasons["protected_asset"], (1, Decimal("0.01")))
        assert_equal(reasons["locked"], (1, Decimal("0.5")))
        assert_equal(reasons["immature"][0], 1)
        assert_equal(reasons["unconfirmed"], (1, Decimal("0.125")))
        # A wallet without private keys cannot call this RPC, so "no signer here" is covered by the
        # unit test; nothing in this wallet falls under it, or under "other".
        assert_equal(reasons["signer_unavailable"][0], 0)
        assert_equal(reasons["other"][0], 0)
        # the report counts every one of them once
        assert_equal(result["excluded_legacy_outputs"], sum(c for c, _ in reasons.values()))
        assert_equal(Decimal(str(result["excluded_legacy_amount"])), sum(a for _, a in reasons.values()))
        assert_equal(result["excluded_legacy_outputs"], 4)
        assert_greater_than(result["next_maturity_height"], node.getblockcount())

        self.log.info("Spending the real batch changes nothing about what is left behind")
        real = wallet.migratetoquantum({"existing_address": address})
        assert_equal(real["more_batches"], False)
        assert_equal(real["excluded_legacy_outputs"], 4)
        assert_equal(self.reasons(real)["protected_asset"], (1, Decimal("0.01")))
        self.generatetoaddress(node, 1, self.w_addr)
        # The seal was not swept: the asset is intact.
        assert node.gettxout(seal["txid"], seal["vout"]) is not None
        assert_equal(wallet.listrgbassets()[0]["balance"], 500)


if __name__ == '__main__':
    MigrationResidualInventoryTest().main()
