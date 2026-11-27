#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""A new encrypted legacy (BDB) wallet recognises a payment to one of its initial keys.

The initial keypool of an encrypted, non-blank legacy wallet is generated after the wallet object
exists but before the wallet is published and its first-key-time notification is connected. If
that creation time is not recorded as the wallet's birth time, the wallet believes every block is
older than itself and skips it: a payment that confirms in a block the wallet never saw in its
mempool stays invisible until a restart, a rescan or a key top-up.

The wallet node here is disconnected while the payment is made and mined elsewhere, then connected,
so the first the wallet hears of the payment is the block. No restart, rescan, import or top-up
follows; the wallet must show the payment and spend it.
"""
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal
from transition_t_final_util import (
    LIFECYCLE_ARGS,
    MATURITY,
    TransitionTFinalTestBase,
)


class LegacyEncryptedBirthTimeTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser, descriptors=False)

    def set_test_params(self):
        self.num_nodes = 2
        self.setup_clean_chain = True
        self.extra_args = [LIFECYCLE_ARGS, LIFECYCLE_ARGS]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()
        self.skip_if_no_bdb()

    def setup_network(self):
        self.setup_nodes()

    def run_test(self):
        n0, n1 = self.nodes
        self.set_initial_mt()
        funder = n1.get_wallet_rpc(self.default_wallet_name)
        funder_addr = funder.getnewaddress("", "legacy")
        self.pow_blocks(n1, MATURITY + 2, funder_addr)

        self.log.info("An encrypted, non-blank legacy wallet on the other node")
        n0.createwallet("enc", passphrase="open sesame", descriptors=False, load_on_startup=True)
        wallet = n0.get_wallet_rpc("enc")
        assert_equal(wallet.getwalletinfo()["private_keys_enabled"], True)
        wallet.walletpassphrase("open sesame", 1000000)
        address = wallet.getnewaddress("", "legacy")
        wallet.walletlock()

        self.log.info("The payment is made and first confirmed on a node the wallet is not connected to")
        assert_equal(n0.getblockcount(), 0)
        txid = funder.sendtoaddress(address, 1)
        assert txid in n1.getrawmempool()
        self.pow_blocks(n1, 1, funder_addr)
        assert_equal(n1.gettransaction(txid)["confirmations"], 1)
        assert txid not in n0.getrawmempool()

        self.log.info("The wallet node connects and receives the block; no restart, rescan, import or top-up")
        self.connect_nodes(0, 1)
        self.sync_blocks()
        n0.syncwithvalidationinterfacequeue()
        assert_equal(wallet.getwalletinfo()["txcount"], 1)
        assert_equal(wallet.getbalance(), 1)
        assert_equal(wallet.gettransaction(txid)["confirmations"], 1)

        self.log.info("The wallet can spend the payment")
        wallet.walletpassphrase("open sesame", 1000000)
        spend = wallet.sendtoaddress(funder_addr, 0.5)
        self.wait_until(lambda: spend in n0.getrawmempool())


if __name__ == '__main__':
    LegacyEncryptedBirthTimeTest().main()
