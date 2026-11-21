#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""The quantum stake return key is durable, and a wallet backup recovers what it was paid.

Quantum (ML-DSA) keys are generated at random, one by one, and each is stored as its own wallet
record. They are NOT derived from a seed, so a wallet backup made before a key was created cannot
recover coins paid to that key. This test shows both sides on regtest (Migration ends at M=91,
the legacy stake window starts at 81, maturity 10):

 * setting the return address makes a durably stored key and tells the user, in the log, in
   getstakinginfo and in the staking notice, to make a fresh backup; backupwallet after it clears
   that prompt;
 * the address survives a restart, the wallet stakes to it, and the payout spends after maturity;
 * a backup made after the key was set, restored into a fresh node, finds the payout and spends it;
 * a backup made BEFORE the key was created, restored into a fresh node, does not find it.

Node 1 is an unmodified v30.1.6 node that validates every block; node 2 is a fresh node that
restores the backups.
"""
import os
from decimal import Decimal

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal
from transition_t_final_util import (
    F,
    LAST_LEGACY_STAKE_HEIGHT,
    LIFECYCLE_ARGS,
    M,
    MATURITY,
    TransitionTFinalTestBase,
)

V30_1_6 = 300106
SUBSIDY = Decimal("1.5")


class QuantumStakeReturnDurabilityTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 3
        self.setup_clean_chain = True
        # Key creation is not allowed automatically: the operator's call creates the key.
        args = [a for a in LIFECYCLE_ARGS if not a.startswith("-qqallowautokeycreation")]
        self.extra_args = [args, args + ["-rpcdoccheck=0"], args]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()
        if not os.environ.get("BLACKCOIN_V30_1_6_BINARY"):
            self.skip_if_no_previous_releases()

    def setup_nodes(self):
        override = os.environ.get("BLACKCOIN_V30_1_6_BINARY")
        bitcoind = self.options.bitcoind
        cli = self.options.bitcoincli
        if override:
            self.add_nodes(self.num_nodes, extra_args=self.extra_args,
                           binary=[bitcoind, override, bitcoind], binary_cli=[cli] * 3)
        else:
            self.add_nodes(self.num_nodes, extra_args=self.extra_args, versions=[None, V30_1_6, None])
        self.start_nodes()
        self.import_deterministic_coinbase_privkeys()
        self.connect_nodes(0, 1)

    def sync_tips(self, *nodes):
        n0 = self.nodes[0]
        for node in nodes or (self.nodes[1],):
            self.wait_until(lambda: n0.getbestblockhash() == node.getbestblockhash(), timeout=90)

    def run_test(self):
        n0, n1, n2 = self.nodes
        default = n0.get_wallet_rpc(self.default_wallet_name)
        default.staking(False)
        self.set_initial_mt()
        pow_addr = default.getnewaddress("", "legacy")
        quantum_miner = default.getnewquantumaddress()["address"]

        n0.createwallet("ret")
        ret = n0.get_wallet_rpc("ret")
        ret.staking(False)
        coin_addr = ret.getnewaddress("", "legacy")
        self.generatetoaddress(n0, 1, coin_addr, sync_fun=self.sync_all)
        self.bump()
        kernel_coinbase = n0.getblock(n0.getblockhash(1), 2)["tx"][0]
        kernel = {"txid": kernel_coinbase["txid"], "vout": 0}
        self.pow_blocks(n0, 40 - n0.getblockcount(), pow_addr, sync=True)

        backup_dir = os.path.join(self.options.tmpdir, "backups")
        os.makedirs(backup_dir, exist_ok=True)
        before_key = os.path.join(backup_dir, "before_key.dat")
        after_key = os.path.join(backup_dir, "after_key.dat")

        self.log.info("A backup made BEFORE the quantum key exists")
        ret.backupwallet(before_key)

        self.pow_blocks(n0, LAST_LEGACY_STAKE_HEIGHT - n0.getblockcount(), pow_addr, sync=True)
        assert_equal(n0.getblockcount(), LAST_LEGACY_STAKE_HEIGHT)

        self.log.info("Setting the return address creates a durable key and prompts for a backup")
        with n0.assert_debug_log(["is not in a verified wallet backup yet"]):
            result = ret.setquantumstakereturn({"allow_new_quantum_key": True})
        assert_equal(result["created"], True)
        assert_equal(result["backup_verified"], False)
        assert "fresh wallet backup" in result["backup_action"]
        address = result["address"]
        info = ret.getstakinginfo()
        assert_equal(info["legacy_stake_return_ready"], True)
        assert_equal(info["legacy_stake_return_backup_verified"], False)
        assert "fresh wallet backup" in info["legacy_stake_return_backup_action"]
        assert "fresh wallet backup" in info["legacy_staking_notice"]
        assert_equal(ret.getmigrationstatus()["legacy_stake_return_backup_verified"], False)
        readiness = ret.getquantumstakereadiness()
        assert_equal(readiness["stake_return"]["backup_verified"], False)
        assert "backup_action" in readiness["stake_return"]

        self.log.info("The key and the address survive a restart (they were durably written)")
        self.restart_node(0, extra_args=self.extra_args[0] + ["-mocktime=%d" % self.mt])
        self.connect_nodes(0, 1)
        n0.loadwallet("ret")
        ret = n0.get_wallet_rpc("ret")
        ret.staking(False)
        default = n0.get_wallet_rpc(self.default_wallet_name)
        self.set_mt(self.mt)
        info = ret.getstakinginfo()
        assert_equal(info["legacy_stake_return_ready"], True)
        assert_equal(info["legacy_stake_return_address"], address)
        assert_equal(info["legacy_stake_return_backup_verified"], False)

        self.log.info("backupwallet after the key was set clears the prompt")
        ret.backupwallet(after_key)
        info = ret.getstakinginfo()
        assert_equal(info["legacy_stake_return_backup_verified"], True)
        assert "legacy_stake_return_backup_action" not in info
        assert "fresh wallet backup" not in info["legacy_staking_notice"]
        assert_equal(ret.getquantumstakereadiness()["stake_return"]["backup_verified"], True)

        self.log.info("The wallet stakes its legacy kernel to the return address (block 81)")
        block_hash = self.stake_outpoint(ret, n0, kernel)
        self.sync_tips()
        assert_equal(n0.getblock(block_hash)["height"], LAST_LEGACY_STAKE_HEIGHT + 1)
        coinstake = n0.getblock(block_hash, 2)["tx"][1]
        valued = [o for o in coinstake["vout"] if o["value"] > 0]
        assert_equal(len(valued), 1)
        assert_equal(valued[0]["scriptPubKey"]["type"], "witness_unknown")
        assert_equal(valued[0]["scriptPubKey"]["address"], address)
        payout = {"txid": coinstake["txid"], "vout": valued[0]["n"]}
        payout_value = valued[0]["value"]
        assert_equal(payout_value, Decimal("10000") + SUBSIDY)

        self.log.info("Up to Final, then past maturity")
        self.pow_blocks(n0, M - n0.getblockcount(), pow_addr, sync=True)
        self.generatetoaddress(n0, MATURITY + 2, quantum_miner, sync_fun=self.sync_all)
        self.sync_tips()
        assert n0.getblockcount() > F + MATURITY
        assert_equal(n0.getquantumquasarinfo()["phase"], "final_lockout")

        self.log.info("Backups restored into a fresh node: after-key finds and spends the payout")
        self.connect_nodes(2, 0)
        self.sync_tips(n2)
        n2.restorewallet("after", after_key)
        after = n2.get_wallet_rpc("after")
        assert payout["txid"] in [tx["txid"] for tx in after.listtransactions("*", 1000)]
        assert_equal(after.gettransaction(payout["txid"])["confirmations"] > MATURITY, True)
        destination = default.getnewquantumaddress()["address"]
        # getrawtransaction and gettransaction return this transaction's hex without its witness
        # (rpcserialversion), so take the signed hex from the send itself and give it to the miner.
        spend = after.send(outputs=[{destination: payout_value - Decimal("0.01")}],
                           options={"inputs": [payout], "add_inputs": False, "change_address": address,
                                    "add_to_wallet": False})
        assert_equal(spend["complete"], True)
        txid = n0.sendrawtransaction(spend["hex"])
        self.generatetoaddress(n0, 1, quantum_miner, sync_fun=self.no_op)
        self.sync_tips(n1, n2)
        assert_equal(n1.getrawtransaction(txid, True, n1.getbestblockhash())["confirmations"], 1)

        self.log.info("...and the backup made before the key does not find it (the key cannot be re-derived)")
        n2.restorewallet("before", before_key)
        before = n2.get_wallet_rpc("before")
        # The coinstake spent a coin of this wallet, so the wallet lists the transaction, but the
        # output it paid is not its own: no key, no balance, nothing to spend.
        info = before.getaddressinfo(address)
        assert_equal(info["ismine"], False)
        assert_equal(info.get("hasquantumkey", False), False)
        assert_equal([u for u in before.listunspent(0) if (u["txid"], u["vout"]) == (payout["txid"], payout["vout"])], [])
        assert_equal(before.getbalances()["mine"]["trusted"], 0)
        # (only the coinstake's value-0 block-signing output is left in the wallet)
        assert_equal([u for u in before.listunspent(0) if u["amount"] > 0], [])
        # The live wallet still has the key (it is the only copy that can spend the payout).
        live = n0.get_wallet_rpc("ret")
        assert_equal(live.getstakinginfo()["legacy_stake_return_address"], address)


if __name__ == '__main__':
    QuantumStakeReturnDurabilityTest().main()
