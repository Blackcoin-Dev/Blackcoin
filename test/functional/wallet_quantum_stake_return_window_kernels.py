#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Specialised quantum kernels keep their own return path inside the quantum return window.

In the last blocks of Migration a LEGACY kernel is paid out as one quantum output of the wallet (the quantum
stake return address). A tiered quantum kernel and a quantum cold-stake kernel are quantum already, with
covenants of their own: they must not be redirected to that return address and must not be refused. Here
both wallets have a ready return address, and each kernel is staked by the wallet's own staker at a window
height (the window starts at 81, regtest maturity 10, Migration ends at M=91):

 * a bonded tiered kernel returns its principal (and its reward) to the very same tier script, and nothing
   goes to the return address;
 * a cold-stake kernel returns the principal to the same cold-stake script (the operator is paid only once
   the reward split is active, from the first Final block), and nothing goes to the return address.
The legacy-kernel redirection itself is in wallet_legacy_stake_quantum_return.py.
"""
from decimal import Decimal

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal
from transition_t_final_util import F, G, LAST_LEGACY_STAKE_HEIGHT, LIFECYCLE_ARGS, TransitionTFinalTestBase

TIER_AMOUNT = Decimal("5000")
COLD_AMOUNT = Decimal("4000")
VAULT_7D_BLOCKS = 9450
WINDOW_START = LAST_LEGACY_STAKE_HEIGHT + 1


class QuantumStakeReturnWindowKernelsTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.extra_args = [LIFECYCLE_ARGS + ["-donatetodevfund=0", f"-qqstaketierheight={G + 1}", f"-qqstakesplitheight={F}"]]

    def script_of(self, address):
        return bytes.fromhex(self.nodes[0].validateaddress(address)["scriptPubKey"])

    @staticmethod
    def paid(coinstake, script):
        return sum((Decimal(str(o["value"])) for o in coinstake["vout"] if bytes.fromhex(o["scriptPubKey"]["hex"]) == script),
                   Decimal(0))

    def run_test(self):
        node = self.nodes[0]
        default = node.get_wallet_rpc(self.default_wallet_name)
        default.staking(False)
        self.set_initial_mt()
        pow_addr = default.getnewaddress("", "legacy")
        for name in ("tier", "cold_owner", "cold_staker"):
            node.createwallet(name)
        tier, owner, cold_staker = (node.get_wallet_rpc(n) for n in ("tier", "cold_owner", "cold_staker"))
        for wallet in (tier, owner, cold_staker):
            wallet.staking(False)

        self.pow_blocks(node, G, pow_addr)
        self.pow_blocks(node, 4, pow_addr)  # tip 65: Migration, tiers active

        self.log.info("A bonded tiered output and a cold-stake delegation, funded in Migration")
        tier_address = tier.getnewquantumstakeaddress("window-tier", VAULT_7D_BLOCKS)["address"]
        tier_script = self.script_of(tier_address)
        staker_quantum = cold_staker.getnewquantumaddress()["address"]
        staker_key = cold_staker.dumpquantumkey(staker_quantum)
        operator_script = self.script_of(staker_quantum)
        delegation = owner.getnewquantumcoldstakingaddress(staker_key["public_key"], "window-delegated")
        qcs_address = delegation["address"]
        qcs_script = self.script_of(qcs_address)
        cold_staker.importquantumcoldstakingdelegation(delegation["owner_pubkey"], staker_key["public_key"], "window-delegated")
        tier_txid = default.sendtoaddress(tier_address, TIER_AMOUNT)
        qcs_txid = default.sendtoaddress(qcs_address, COLD_AMOUNT)
        self.pow_blocks(node, 1, pow_addr)
        assert_equal(len(tier.listunspent(1, 9999999, [tier_address])), 1)
        assert_equal(len(cold_staker.listunspent(1, 9999999, [qcs_address])), 1)

        # Both wallets have a ready return address, so a redirect would be possible if the kernels were legacy.
        tier_return = tier.setquantumstakereturn({"allow_new_quantum_key": True})
        cold_return = cold_staker.setquantumstakereturn({"allow_new_quantum_key": True})
        assert_equal(tier_return["ready"], True)
        assert_equal(cold_return["ready"], True)
        tier_return_script = self.script_of(tier_return["address"])
        cold_return_script = self.script_of(cold_return["address"])
        # (Different wallets need not share an address; neither equals the kernel's own script.)
        assert tier_return_script != tier_script and cold_return_script != qcs_script

        self.pow_blocks(node, LAST_LEGACY_STAKE_HEIGHT - node.getblockcount(), pow_addr)
        assert_equal(node.getblockcount(), LAST_LEGACY_STAKE_HEIGHT)
        assert_equal(tier.getstakinginfo()["legacy_staking_window_start_height"], WINDOW_START)

        self.log.info("Window height %d: the tiered kernel stakes and returns to its own tier script", WINDOW_START)
        tier_out = {"txid": tier_txid, "vout": tier.listunspent(1, 9999999, [tier_address])[0]["vout"]}
        tier_hash = self.stake_outpoint(tier, node, tier_out)
        block = node.getblock(tier_hash, 2)
        assert_equal(block["height"], WINDOW_START)
        coinstake = block["tx"][1]
        assert_equal(coinstake["vin"][0]["txid"], tier_txid)
        assert_equal(self.paid(coinstake, tier_script), TIER_AMOUNT + Decimal("1.5"))
        assert_equal(self.paid(coinstake, tier_return_script), 0)

        self.log.info("Window height %d: the cold-stake kernel stakes and returns to its own script", WINDOW_START + 1)
        self.bump()
        qcs_out = {"txid": qcs_txid, "vout": cold_staker.listunspent(1, 9999999, [qcs_address])[0]["vout"]}
        cold_hash = self.stake_outpoint(cold_staker, node, qcs_out)
        block = node.getblock(cold_hash, 2)
        assert_equal(block["height"], WINDOW_START + 1)
        coinstake = block["tx"][1]
        assert_equal(coinstake["vin"][0]["txid"], qcs_txid)
        assert self.paid(coinstake, qcs_script) >= COLD_AMOUNT  # the principal comes back to the same cold-stake script
        assert_equal(self.paid(coinstake, cold_return_script), 0)
        valued = [o for o in coinstake["vout"] if o["value"] > 0]
        scripts = {bytes.fromhex(o["scriptPubKey"]["hex"]) for o in valued}
        assert scripts <= {qcs_script, operator_script}, "only the cold-stake script (and the operator) is paid"


if __name__ == '__main__':
    QuantumStakeReturnWindowKernelsTest().main()
