#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Maturity-driven claim-reserve selection before Gold Rush ends is exactly what v30.1.6 does.

The wallet's staker now takes a coinbase as a kernel from the block `maturity` above it (the block after
the tip at which it is `maturity` deep), one block earlier than before. The claim miner's stake reserve keeps
the largest of the wallet's stakeable legacy coins out of claim fee-input selection, and it must not change on
a chain that is still in Gold Rush: its list of stakeable coins keeps the wallet's own maturity rule.

The wallet holds A, an ordinary 1-coin output, mature, and B, a 10,000-coin coinbase that is the larger coin.
With one reserved coin the reserve protects the largest stakeable coin. Probed at B's age (confirmations at
the tip) maturity-1, exactly maturity and maturity+1:

 * maturity-1: only A is stakeable and protected; no claim input is left after the reserve;
 * exactly maturity: the staker may already stake B (it is a kernel for the next block) but the claim
   selector cannot spend it (the wallet still calls it immature), so the reserve still protects A and still
   leaves no claim input: nothing is contended and nothing is released one block early;
 * maturity+1: B is stakeable, larger, and protected; A becomes the one claim input after the reserve.

With the kernel rule in the reserve the exactly-maturity probe would protect B and release A one block early.

Regtest (coinbase maturity 10); Gold Rush runs through block 61.
"""
from decimal import Decimal

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal
from transition_t_final_util import G, LIFECYCLE_ARGS, MATURITY, TransitionTFinalTestBase

PASSPHRASE = "pw"


class ClaimReserveMaturityTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.extra_args = [LIFECYCLE_ARGS + ["-powclaimreservestakecoins=1"]]

    def probe(self, wallet):
        info = wallet.getpowmininginfo()
        return (info["mature_stakeable_legacy_coins"], info["reserved_stake_coins"],
                info["claim_coins_after_stake_reserve"])

    def run_test(self):
        node = self.nodes[0]
        default = node.get_wallet_rpc(self.default_wallet_name)
        default.staking(False)
        self.set_initial_mt()
        funder = default.getnewaddress("", "legacy")
        node.createwallet("w", passphrase=PASSPHRASE)
        w = node.get_wallet_rpc("w")
        w.walletpassphrase(PASSPHRASE, 100000000)
        a_addr = w.getnewaddress("", "legacy")
        b_addr = w.getnewaddress("", "legacy")

        self.log.info("A: an ordinary 1-coin output; B: a coinbase, the larger coin")
        self.pow_blocks(node, 2 * MATURITY, funder)
        default.sendtoaddress(a_addr, 1)
        self.pow_blocks(node, 1, funder)
        self.pow_blocks(node, MATURITY + 2, funder)  # A is old enough to be a stake candidate
        self.pow_blocks(node, 1, b_addr)
        b_height = node.getblockcount()
        # Lock the wallet (so the staker cannot act) with staking switched on: the reserve exists only then.
        w.staking(True)
        w.walletlock()
        assert node.getblockcount() < G - 2 * MATURITY

        def tip_at_age(age):
            """Advance the tip until B has `age` confirmations."""
            self.pow_blocks(node, b_height + age - 1 - node.getblockcount(), funder)
            assert_equal(w.gettransaction(node.getblock(node.getblockhash(b_height))["tx"][0])["confirmations"], age)

        self.log.info("B is one block short of the maturity: only A is stakeable and protected")
        tip_at_age(MATURITY - 1)
        assert_equal(self.probe(w), (1, 1, 0))

        self.log.info("B is exactly `maturity` deep: the staker may stake it, the reserve does not move")
        tip_at_age(MATURITY)
        assert_equal(self.probe(w), (1, 1, 0))
        info = w.getpowmininginfo()
        assert_equal(info["reserved_stake_weight"], Decimal("1"))  # the reserved coin is A (1 coin), not B

        self.log.info("B is mature by the wallet's rule: B is protected, A is the claim input")
        tip_at_age(MATURITY + 1)
        assert_equal(self.probe(w), (2, 1, 1))
        info = w.getpowmininginfo()
        assert info["reserved_stake_weight"] > Decimal("1000")  # now the reserved coin is B


if __name__ == '__main__':
    ClaimReserveMaturityTest().main()
