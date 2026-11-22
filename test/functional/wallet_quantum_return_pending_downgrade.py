#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""A wallet that holds a pending quantum stake return record opens in the unmodified v30.1.6 and again here.

The pending-return record ("quantumreturnpending") is an unknown record type to v30.1.6, which
must skip it without error. This test makes a wallet whose new return key is pending (its backup
directory is unwritable), closes the node, opens the same data directory with the UNMODIFIED
v30.1.6 binary (the wallet loads, works and still has the key), then opens it with this build
again: the pending state is intact (same key, no active address), and the next preparation
retries that key and completes.
"""
import os

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_raises_rpc_error
from transition_t_final_util import LIFECYCLE_ARGS, TransitionTFinalTestBase

LABEL = "PoS - Quantum Stake Address"


class PendingReturnDowngradeTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.old_args = [a for a in LIFECYCLE_ARGS if not a.startswith("-qqallowautokeycreation")] + ["-rpcdoccheck=0"]
        self.new_args = [a for a in LIFECYCLE_ARGS if not a.startswith("-qqallowautokeycreation")] + ["-quantumkeybackupdir=qkbackups"]
        self.extra_args = [self.new_args]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()
        if not os.environ.get("BLACKCOIN_V30_1_6_BINARY"):
            self.skip_if_no_previous_releases()

    def setup_nodes(self):
        override = os.environ.get("BLACKCOIN_V30_1_6_BINARY")
        assert override, "set BLACKCOIN_V30_1_6_BINARY to the unmodified v30.1.6 blackcoind"
        self.v30_1_6 = override
        self.add_nodes(self.num_nodes, extra_args=self.extra_args)
        self.start_nodes()

    def run_test(self):
        node = self.nodes[0]
        backups = os.path.join(node.chain_path, "qkbackups")
        os.makedirs(backups, mode=0o700, exist_ok=True)

        self.log.info("Make a pending return key: the backup directory cannot be written")
        node.createwallet("pd", load_on_startup=True)
        wallet = node.get_wallet_rpc("pd")
        os.chmod(backups, 0o500)
        try:
            assert_raises_rpc_error(-4, "wallet backup failed", wallet.setquantumstakereturn, {"allow_new_quantum_key": True})
        finally:
            os.chmod(backups, 0o700)
        state = wallet.getquantumstakereadiness()["stake_return"]
        assert_equal(state["pending"], True)
        assert_equal(state["ready"], False)
        pending_address = state["pending_address"]
        assert_equal(list(wallet.getaddressesbylabel(LABEL)), [pending_address])
        before = {"balances": wallet.getbalances()["mine"], "txcount": wallet.getwalletinfo()["txcount"]}

        self.log.info("Open the same data directory with the unmodified v30.1.6: it skips the record")
        self.stop_node(0)
        node.args[0] = self.v30_1_6
        self.start_node(0, extra_args=self.old_args)
        assert_equal(node.getnetworkinfo()["subversion"], "/Blackcoin:30.1.6(testnode0)/")
        old = node.get_wallet_rpc("pd")
        assert_equal(old.getbalances()["mine"], before["balances"])
        assert_equal(old.getwalletinfo()["txcount"], before["txcount"])
        assert_equal(old.getaddressinfo(pending_address)["ismine"], True)
        old.getnewaddress("", "legacy")  # the older wallet keeps working
        self.stop_node(0)

        self.log.info("Open it with this build again: the pending state is intact and the same key completes")
        node.args[0] = self.options.bitcoind
        self.start_node(0, extra_args=self.new_args)
        wallet = node.get_wallet_rpc("pd")
        state = wallet.getquantumstakereadiness()["stake_return"]
        assert_equal(state["pending"], True)
        assert_equal(state["ready"], False)
        assert_equal(state["pending_address"], pending_address)
        assert_equal(list(wallet.getaddressesbylabel(LABEL)), [pending_address])
        result = wallet.setquantumstakereturn()
        assert_equal(result["address"], pending_address)
        assert_equal(result["ready"], True)
        state = wallet.getquantumstakereadiness()["stake_return"]
        assert_equal(state["pending"], False)
        assert_equal(state["address"], pending_address)
        assert_equal(list(wallet.getaddressesbylabel(LABEL)), [pending_address])

        self.log.info("The completed wallet (no pending record, saved address) opens in v30.1.6 and here again")
        self.stop_node(0)
        node.args[0] = self.v30_1_6
        self.start_node(0, extra_args=self.old_args)
        assert_equal(node.get_wallet_rpc("pd").getaddressinfo(pending_address)["ismine"], True)
        self.stop_node(0)
        node.args[0] = self.options.bitcoind
        self.start_node(0, extra_args=self.new_args)
        state = node.get_wallet_rpc("pd").getquantumstakereadiness()["stake_return"]
        assert_equal(state["address"], pending_address)
        assert_equal(state["pending"], False)


if __name__ == '__main__':
    PendingReturnDowngradeTest().main()
