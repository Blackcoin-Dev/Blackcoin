#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""The quantum stake return key that waits for its first verified backup is not adopted as a destination.

While the backup of a new return key has not succeeded (here the backup directory is unwritable) the key is "pending".
It is refused as a destination wherever the wallet adopts one on its own account: the existing_address of
migratetoquantum and of migrategoldrushrewards, and a positive change output. Funds that are already on the key are not
locked: the key signs for them (a spend to a safe destination) and the wallet's staker stakes them, returning the
principal to the key itself. The restriction survives a restart and goes away when the backup succeeds.
"""
import os
from decimal import Decimal

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_raises_rpc_error
from transition_t_final_util import G, LIFECYCLE_ARGS, MATURITY, TransitionTFinalTestBase

WAITING = "waiting for its first verified wallet backup"


class PendingReturnKeyDestinationsTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.args = [a for a in LIFECYCLE_ARGS if not a.startswith("-qqallowautokeycreation")] + ["-quantumkeybackupdir=qkbackups"]
        self.extra_args = [self.args]

    def run_test(self):
        node = self.nodes[0]
        default = node.get_wallet_rpc(self.default_wallet_name)
        default.staking(False)
        self.set_initial_mt()
        pow_addr = default.getnewaddress("", "legacy")
        backups = os.path.join(node.chain_path, "qkbackups")
        os.makedirs(backups, mode=0o700, exist_ok=True)

        node.createwallet("pd", load_on_startup=True, descriptors=self.options.descriptors)
        wallet = node.get_wallet_rpc("pd")
        wallet.staking(False)
        for _ in range(3):
            self.generatetoaddress(node, 1, wallet.getnewaddress("", "legacy"), sync_fun=self.no_op)
            self.bump()
        self.pow_blocks(node, G + 2 - node.getblockcount(), pow_addr)

        self.log.info("A new return key whose backup cannot be written stays pending")
        os.chmod(backups, 0o500)
        try:
            assert_raises_rpc_error(-4, "wallet backup failed", wallet.setquantumstakereturn, {"allow_new_quantum_key": True})
            state = wallet.getquantumstakereadiness()["stake_return"]
            assert_equal((state["pending"], state["ready"]), (True, False))
            pending = state["pending_address"]
            self.log.info("Funds of the wallet and funds already on the pending key")
            ordinary = wallet.getnewquantumaddress()["address"]
            safe = wallet.getnewquantumaddress()["address"]
            wallet.migratetoquantum({"existing_address": ordinary, "max_inputs": 1})
            default.sendtoaddress(pending, 5000)
            default.sendtoaddress(pending, 4000)
            self.pow_blocks(node, MATURITY + 1, pow_addr)
            on_key = sorted(wallet.listunspent(1, 9999999, [pending]), key=lambda u: u["amount"])
            assert_equal(len(on_key), 2)

            self.log.info("Refused as the destination of a migration or a consolidation")
            assert_raises_rpc_error(-4, WAITING, wallet.migratetoquantum, {"existing_address": pending, "max_inputs": 1})
            assert_raises_rpc_error(-4, WAITING, wallet.migrategoldrushrewards, {"existing_address": pending})

            self.log.info("Refused as a positive change destination")
            source = [u for u in wallet.listunspent(1, 9999999, [ordinary]) if u["amount"] > 0][0]
            assert_raises_rpc_error(None, WAITING, wallet.send, outputs=[{safe: Decimal(1)}],
                                    options={"inputs": [{"txid": source["txid"], "vout": source["vout"]}], "add_inputs": False,
                                             "change_address": pending})
            assert_equal(node.getrawmempool(), [])

            self.log.info("Funds already on the key can be spent to a safe destination (the key signs)")
            smaller = on_key[0]
            sent = wallet.send(outputs=[{safe: Decimal(100)}],
                               options={"inputs": [{"txid": smaller["txid"], "vout": smaller["vout"]}], "add_inputs": False,
                                        "change_address": ordinary})
            assert sent["complete"]
            assert sent["txid"] in node.getrawmempool()

            self.log.info("...and staked: the principal comes back to the key itself")
            larger = on_key[1]
            block = self.stake_outpoint(wallet, node, {"txid": larger["txid"], "vout": larger["vout"]})
            coinstake = node.getblock(block, 2)["tx"][1]
            paid_to_key = {o["scriptPubKey"].get("address") for o in coinstake["vout"] if o["value"] > 0}
            assert_equal(paid_to_key, {pending})

            self.log.info("The restriction survives a restart")
            self.restart_node(0, extra_args=self.args + [f"-mocktime={self.mt}"])
            wallet = node.get_wallet_rpc("pd")
            wallet.staking(False)
            self.set_mt(self.mt)
            state = wallet.getquantumstakereadiness()["stake_return"]
            assert_equal((state["pending"], state["pending_address"]), (True, pending))
            assert_raises_rpc_error(-4, WAITING, wallet.migratetoquantum, {"existing_address": pending, "max_inputs": 1})
        finally:
            os.chmod(backups, 0o700)

        self.log.info("When the backup succeeds the key is the return address and the restriction is gone")
        result = wallet.setquantumstakereturn()
        assert_equal((result["address"], result["ready"]), (pending, True))
        assert_equal(wallet.getquantumstakereadiness()["stake_return"]["pending"], False)
        migrated = wallet.migratetoquantum({"existing_address": pending, "max_inputs": 1})
        assert "txid" in migrated, migrated


if __name__ == '__main__':
    PendingReturnKeyDestinationsTest().main()
