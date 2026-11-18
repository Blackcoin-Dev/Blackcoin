#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Slow-disk gate: one Gold Rush PoW claim submission performs one wallet-add commit.

Every wallet database commit is a disk sync, and on a spinning disk each one
costs tens of milliseconds while the wallet lock is held. Submitting a claim
adds one transaction to the wallet, so it needs one commit, not one per
record it touches. The hidden getiocounters RPC counts the commits, so the
gate does not depend on how fast the disk is.

The gate runs only when RC14_INTEGRATION_ENABLED is True (or the environment has
RC14_ENFORCE_GATES=1); until then it reports whether it holds. What always runs
is that the count is read and the claim is submitted and accepted.
"""

import os
import time

from test_framework.authproxy import JSONRPCException
from test_framework.blocktools import COINBASE_MATURITY
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal

# TODO(rc14-integration): set to True once the wallet commit track is merged.
RC14_INTEGRATION_ENABLED = False

WALLET_NAME = "claim_commit"


def gates_enforced():
    return RC14_INTEGRATION_ENABLED or os.environ.get("RC14_ENFORCE_GATES") == "1"


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

        before = node.getiocounters()
        claim = self._send_claim(wallet, claim_address, payout_address)
        after = node.getiocounters()
        assert claim["txid"] in node.getrawmempool()
        commits = after["wallet_commits"] - before["wallet_commits"]
        self.log.info("One claim submission performed %d wallet commits", commits)
        holds = commits == 1
        if gates_enforced():
            assert holds, "one claim submission performs one wallet-add commit (saw %d)" % commits
        else:
            self.log.info("[rc14 gate waits for integration] one claim submission performs one wallet-add commit: %s",
                          "HOLDS" if holds else "does not hold yet")
        assert commits >= 1


if __name__ == "__main__":
    WalletIoClaimCommitTest().main()
