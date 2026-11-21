#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""The quantum stake return address readies itself under the existing key policy.

With -qqallowautokeycreation=1 a fully unlocked wallet that has no quantum address makes one
(label "PoS - Quantum Stake Address") as soon as its staker runs, saves it as the quantum stake
return address, and keeps it across a restart. Without that policy it never creates a key (see
wallet_legacy_stake_cutoff.py). An existing quantum address of the wallet is reused instead of a
new key when the policy is off. Regtest: Migration ends at M=91, the window starts at 81.
"""
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal
from transition_t_final_util import LIFECYCLE_ARGS, TransitionTFinalTestBase


class LegacyStakeAutoReturnTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 2
        self.setup_clean_chain = True
        no_auto = [a for a in LIFECYCLE_ARGS if not a.startswith("-qqallowautokeycreation")]
        self.extra_args = [LIFECYCLE_ARGS, no_auto]

    def run_test(self):
        auto_node, reuse_node = self.nodes
        auto = auto_node.get_wallet_rpc(self.default_wallet_name)
        reuse = reuse_node.get_wallet_rpc(self.default_wallet_name)
        for wallet in (auto, reuse):
            wallet.staking(False)
        self.set_initial_mt()

        self.log.info("Policy on: the staker makes and saves a quantum stake address")
        assert_equal(auto.getstakinginfo()["legacy_stake_return_ready"], False)
        auto.staking(True)
        self.wait_until(lambda: auto.getstakinginfo()["legacy_stake_return_ready"], timeout=60)
        auto.staking(False)
        address = auto.getstakinginfo()["legacy_stake_return_address"]
        assert address in auto.getaddressesbylabel("PoS - Quantum Stake Address")
        self.restart_node(0, extra_args=self.extra_args[0])
        auto = auto_node.get_wallet_rpc(self.default_wallet_name)
        assert_equal(auto.getstakinginfo()["legacy_stake_return_address"], address)

        self.log.info("Policy off: no key is made; an existing quantum address is reused, and only when fully unlocked")
        reuse.staking(True)
        self.bump(32)
        reuse.staking(False)
        assert_equal(reuse.getstakinginfo()["legacy_stake_return_ready"], False)
        owned = reuse.getnewquantumaddress()["address"]
        reuse.staking(True)
        self.wait_until(lambda: reuse.getstakinginfo()["legacy_stake_return_ready"], timeout=60)
        reuse.staking(False)
        assert_equal(reuse.getstakinginfo()["legacy_stake_return_address"], owned)


if __name__ == '__main__':
    LegacyStakeAutoReturnTest().main()
