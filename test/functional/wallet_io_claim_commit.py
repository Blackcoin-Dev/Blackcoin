#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Slow-disk gate: a Gold Rush PoW claim submission performs one wallet-add commit and one quarantine-clear commit.

Every wallet database commit is a disk sync, and on a spinning disk each one
costs tens of milliseconds while the wallet lock is held. Submitting a claim
adds one transaction to the wallet, so it needs one commit, not one per
record it touches. The hidden getiocounters RPC counts the commits, so the
gate does not depend on how fast the disk is.

The claim is stored with a quarantine mark and the mark is cleared in one more
commit when the mempool accepts it, so the exact shape is two commits: one
wallet-add (the submitting thread) and one quarantine clear (the mempool
handler), and no autocommit.
"""

import time

from test_framework.authproxy import JSONRPCException
from test_framework.blocktools import COINBASE_MATURITY
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal

WALLET_NAME = "claim_commit"


class WalletIoClaimCommitTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.extra_args = [[
            "-allowunsafequantumkeyrpc=1",
            "-txindex=1",
            "-shadowindex=1",
            "-staketimio=50",
            "-autostartstaking=0",
            "-shadowwhitelistheight=1",
            "-shadowgoldrushstartheight=2",
            "-shadowgoldrushblocks=1000",
            "-shadowcompetingclaimsheight=2",
            "-shadowqqp4height=2",
        ]]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def _set_mocktime(self, timestamp):
        self.mock_time = timestamp
        self.nodes[0].setmocktime(timestamp)

    def _sync_mocktime_to_tip(self):
        tip_time = self.nodes[0].getblockheader(self.nodes[0].getbestblockhash())["time"]
        self._set_mocktime((tip_time & ~0xF) + 16)

    def _send_claim(self, wallet, signal_address, payout_address):
        last_error = None
        for _ in range(5):
            try:
                return wallet.sendshadowpowclaim(signal_address, payout_address, 500000)
            except JSONRPCException as e:
                last_error = e
                if e.error["code"] != -26 or "Active chain tip changed while grinding" not in e.error["message"]:
                    raise
        raise last_error

    def run_test(self):
        node = self.nodes[0]
        self._set_mocktime((int(time.time()) & ~0xF) + 16)
        node.get_wallet_rpc(self.default_wallet_name).staking(False)
        node.createwallet(wallet_name=WALLET_NAME)
        wallet = node.get_wallet_rpc(WALLET_NAME)
        wallet.staking(False)
        claim_address = wallet.getnewaddress("", "legacy")
        other_address = node.get_wallet_rpc(self.default_wallet_name).getnewaddress("", "legacy")

        self.generatetoaddress(node, 1, other_address, sync_fun=self.no_op)
        self.generatetoaddress(node, COINBASE_MATURITY + 2, claim_address, sync_fun=self.no_op)
        self._sync_mocktime_to_tip()
        assert_equal(node.getquantumquasarinfo()["phase"], "gold_rush")
        payout_address = wallet.getnewquantumaddress()["address"]
        node.syncwithvalidationinterfacequeue()

        node.syncwithvalidationinterfacequeue()
        before = node.getiocounters()
        claim = self._send_claim(wallet, claim_address, payout_address)
        node.syncwithvalidationinterfacequeue()
        after = node.getiocounters()
        assert claim["txid"] in node.getrawmempool()
        commits = after["wallet_commits"] - before["wallet_commits"]
        in_handler = after["wallet_commits_in_handler"] - before["wallet_commits_in_handler"]
        autocommits = after["wallet_autocommits"] - before["wallet_autocommits"]
        self.log.info("One claim submission: %d wallet commits (%d in the mempool handler, %d autocommits)", commits, in_handler, autocommits)
        # The shape, by design: the wallet-add of the claim is one grouped commit
        # (CommitTransaction). The claim record is stored quarantined, and the
        # mempool-added handler clears that mark in one durable commit once the
        # mempool really holds the claim (transactionAddedToMempool ->
        # UpdateShadowPowClaimRecoveryRecordDurably, quarantine key). Nothing
        # else, and in particular no single-statement autocommit.
        assert_equal(commits, 2)
        assert_equal(in_handler, 1)
        assert_equal(autocommits, 0)
        assert_equal(commits - in_handler, 1)  # exactly one wallet-add commit

if __name__ == "__main__":
    WalletIoClaimCommitTest().main()
