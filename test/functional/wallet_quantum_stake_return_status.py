#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Status and wording of the quantum stake return address.

 * R5: at the first Final block legacy kernels are rejected, so getstakinginfo and getmigrationstatus say
   legacy staking has stopped even when a return address is ready, and the return window ends with the last
   Migration block (legacy_staking_in_window is false at Final).
 * R6: setquantumstakereturn reports created=true when the automatic path made the key, not only when the
   explicit branch did; a second call (the address is set) reports created=false.
 * N1: the first return (made at M - maturity) can stake in the last Migration block and a later one from
   Final. The notice and the RPC help no longer say a return cannot stake inside the window, nor that the
   first window height cannot mature before Final.

Regtest: Gold Rush ends at G=61, Migration ends at M=91 (F=92), maturity 10, window starts at 81.
"""
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal
from transition_t_final_util import F, G, LAST_LEGACY_STAKE_HEIGHT, LIFECYCLE_ARGS, M, MATURITY, TransitionTFinalTestBase


class QuantumStakeReturnStatusTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.extra_args = [LIFECYCLE_ARGS]

    def run_test(self):
        node = self.nodes[0]
        default = node.get_wallet_rpc(self.default_wallet_name)
        default.staking(False)
        self.set_initial_mt()
        pow_addr = default.getnewaddress("", "legacy")
        node.createwallet("w")
        wallet = node.get_wallet_rpc("w")
        wallet.staking(False)

        self.log.info("R6: the automatic path makes the key, and the RPC says so")
        # No quantum address exists and key creation is authorised for the node: the RPC has the automatic
        # path make one. (An explicit allow_new_quantum_key is not needed and not given.)
        result = wallet.setquantumstakereturn()
        assert_equal(result["created"], True)
        assert_equal(result["ready"], True)
        assert "backup_action" in result  # a key that no backup holds yet
        address = result["address"]
        again = wallet.setquantumstakereturn()
        assert_equal(again["address"], address)
        assert_equal(again["created"], False)  # reused, nothing created
        # An existing address is also reported as not created.
        other = wallet.getnewquantumaddress()["address"]
        explicit = wallet.setquantumstakereturn({"existing_address": other})
        assert_equal(explicit["created"], False)
        assert_equal(explicit["address"], other)

        self.log.info("N1: wording")
        helptext = node.help("setquantumstakereturn")
        assert "could not mature before the Final phase" not in helptext
        assert "last Migration block" in helptext
        info = wallet.getstakinginfo()
        notice = info["legacy_staking_notice"]
        assert "so not inside the window" not in notice
        assert f"the first one (made at height {LAST_LEGACY_STAKE_HEIGHT + 1}) in the last Migration block ({M})" in notice, notice
        assert f"any later one from the first Final block ({F}) on" in notice, notice

        self.log.info("R5: in the window legacy staking is not stopped (a return address is ready); at Final it is")
        self.pow_blocks(node, G - node.getblockcount(), pow_addr)
        quantum_miner = wallet.getnewquantumaddress()["address"]
        self.pow_blocks(node, M - 1 - node.getblockcount(), quantum_miner)  # the next block is M
        for status in (wallet.getstakinginfo(), wallet.getmigrationstatus()):
            assert_equal(status["legacy_staking_in_window"], True)
            assert_equal(status["legacy_stake_return_ready"], True)
            assert_equal(status["legacy_staking_stopped"], False)
        self.pow_blocks(node, 1, quantum_miner)
        assert_equal(node.getblockcount(), M)
        for status in (wallet.getstakinginfo(), wallet.getmigrationstatus()):
            assert_equal(status["legacy_stake_return_ready"], True)
            assert_equal(status["legacy_staking_in_window"], False)
            assert_equal(status["legacy_staking_stopped"], True)  # legacy kernels are rejected from F on
        assert_equal(wallet.getstakinginfo()["legacy_staking_blocks_remaining"], 0)


if __name__ == '__main__':
    QuantumStakeReturnStatusTest().main()
