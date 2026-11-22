#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""A wallet backup made BEFORE the return address was configured still recovers the legacy stake payout.

Quantum keys are random, so a backup recovers only the keys that existed when it was made. The
wallet therefore prefers a key every old backup already holds: the Gold Rush claim payout key.
This test makes that permanent, on regtest (Gold Rush ends at 61, Migration at 91, the legacy
stake window starts at 81, maturity 10), for an unencrypted and an encrypted wallet of the wallet
type the run uses (--descriptors or --legacy-wallet):

 * the wallet holds a claim payout key (the one its claim miner is bound to, configured with
   -qqpowpayoutaddress) when the OLD backup is made; after the backup a second key labelled as the
   PoS stake address is made, which the old label ranking would have chosen;
 * the wallet chooses the destination itself: it must reuse the claim key and create no key;
 * a legacy self-stake inside the mandatory window is paid to it as one quantum output;
 * the chain runs to Final and past maturity; ONLY the old backup is restored into an isolated
   wallet of a fresh node, which finds the payout, signs a spend of it and has it accepted by the
   node and confirmed.
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

POS_LABEL = "PoS - Quantum Stake Address"
CLAIM_LABEL = "PoW - Quantum Claim Address"
VARIANTS = [("plain", None), ("encrypted", "open sesame")]


class OldBackupRecoveryTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 2
        self.setup_clean_chain = True
        # Key creation is never automatic: the wallet must choose among the keys it has.
        args = [a for a in LIFECYCLE_ARGS if not a.startswith("-qqallowautokeycreation")]
        self.base_args = args
        self.extra_args = [args, args]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def setup_nodes(self):
        self.add_nodes(self.num_nodes, extra_args=self.extra_args)
        self.start_nodes()
        self.import_deterministic_coinbase_privkeys()
        self.connect_nodes(0, 1)

    def sync_tips(self):
        n0, n1 = self.nodes
        self.wait_until(lambda: n0.getbestblockhash() == n1.getbestblockhash(), timeout=90)

    def unlock(self, wallet, passphrase):
        if passphrase:
            wallet.walletpassphrase(passphrase, 1000000)

    def run_test(self):
        n0, n1 = self.nodes
        default = n0.get_wallet_rpc(self.default_wallet_name)
        default.staking(False)
        self.set_initial_mt()
        pow_addr = default.getnewaddress("", "legacy")
        quantum_miner = default.getnewquantumaddress()["address"]
        backup_dir = os.path.join(self.options.tmpdir, "old-backups")
        os.makedirs(backup_dir, exist_ok=True)

        variants = VARIANTS
        records = []  # one dict per variant
        self.log.info("Two wallets, each with one legacy coinbase to stake in the window")
        for index, (kind, passphrase) in enumerate(variants):
            name = "ret-" + kind
            if passphrase:
                n0.createwallet(name, passphrase=passphrase, load_on_startup=True)
            else:
                n0.createwallet(name, load_on_startup=True)
            wallet = n0.get_wallet_rpc(name)
            self.unlock(wallet, passphrase)
            wallet.staking(False)
            legacy_addr = wallet.getnewaddress("", "legacy")
            self.generatetoaddress(n0, 1, legacy_addr, sync_fun=self.sync_all)
            self.bump()
            # No restart and no rescan: the block that pays an initial-keypool key of an encrypted legacy wallet
            # is recognised by the wallet as soon as it connects.
            n0.syncwithvalidationinterfacequeue()
            assert_equal(wallet.getwalletinfo()["txcount"], 1)
            coinbase = n0.getblock(n0.getblockhash(index + 1), 2)["tx"][0]
            records.append({"name": name, "kind": kind, "passphrase": passphrase,
                            "kernel": {"txid": coinbase["txid"], "vout": 0}, "coinbase_value": coinbase["vout"][0]["value"]})
        self.pow_blocks(n0, 40 - n0.getblockcount(), pow_addr, sync=True)

        for record in records:
            wallet = n0.get_wallet_rpc(record["name"])
            self.unlock(wallet, record["passphrase"])
            claim = wallet.getnewquantumaddress(CLAIM_LABEL)["address"]
            record["claim"] = claim
            record["old_backup"] = os.path.join(backup_dir, "old-%s.dat" % record["kind"])
            self.log.info("%s: the OLD backup is made when only the claim key exists (%s)", record["kind"], claim)
            wallet.backupwallet(record["old_backup"])
            # The node's claim miner would be bound to this payout key (or restored with it at start).
            self.restart_node(0, extra_args=self.base_args + ["-qqpowpayoutaddress=" + claim, "-mocktime=%d" % self.mt])
            self.connect_nodes(0, 1)
            self.set_mt(self.mt)
            wallet = n0.get_wallet_rpc(record["name"])
            self.unlock(wallet, record["passphrase"])
            wallet.staking(False)
            # After the old backup: a key the old label ranking would have chosen, and that no old backup holds.
            distractor = wallet.getnewquantumaddress(POS_LABEL)["address"]
            keys_before = set(wallet.getaddressesbylabel(POS_LABEL))
            assert_equal(keys_before, {distractor})
            chosen = wallet.setquantumstakereturn()
            self.log.info("%s: setquantumstakereturn() chose %s, created=%s", record["kind"], chosen["address"], chosen["created"])
            assert_equal(chosen["address"], claim)
            assert_equal(chosen["created"], False)
            assert_equal(chosen["ready"], True)
            assert_equal(set(wallet.getaddressesbylabel(POS_LABEL)), keys_before)  # no key was created
            assert_equal(set(wallet.getaddressesbylabel(CLAIM_LABEL)), {claim})
            info = wallet.getstakinginfo()
            assert_equal(info["legacy_stake_return_ready"], True)
            assert_equal(info["legacy_stake_return_address"], claim)
            assert_equal(info["legacy_stake_return_pending"], False)

        self.pow_blocks(n0, LAST_LEGACY_STAKE_HEIGHT - n0.getblockcount(), pow_addr, sync=True)
        assert_equal(n0.getblockcount(), LAST_LEGACY_STAKE_HEIGHT)

        for index, record in enumerate(records):
            wallet = n0.get_wallet_rpc(record["name"])
            self.unlock(wallet, record["passphrase"])
            self.log.info("%s: a legacy stake in the mandatory window is paid to the claim key", record["kind"])
            block_hash = self.stake_outpoint(wallet, n0, record["kernel"])
            self.sync_tips()
            assert_equal(n0.getblock(block_hash)["height"], LAST_LEGACY_STAKE_HEIGHT + 1 + index)
            coinstake = n0.getblock(block_hash, 2)["tx"][1]
            valued = [o for o in coinstake["vout"] if o["value"] > 0]
            assert_equal(len(valued), 1)
            assert_equal(valued[0]["scriptPubKey"]["address"], record["claim"])
            assert valued[0]["value"] > record["coinbase_value"]
            record["payout"] = {"txid": coinstake["txid"], "vout": valued[0]["n"]}
            record["payout_value"] = valued[0]["value"]
            wallet.staking(False)

        self.log.info("Up to Final, then past maturity")
        self.pow_blocks(n0, M - n0.getblockcount(), pow_addr, sync=True)
        self.generatetoaddress(n0, MATURITY + 2, quantum_miner, sync_fun=self.sync_all)
        self.sync_tips()
        assert n0.getblockcount() > F + MATURITY
        assert_equal(n0.getquantumquasarinfo()["phase"], "final_lockout")

        default = n0.get_wallet_rpc(self.default_wallet_name)  # the node restarted since the handle was made
        destination = default.getnewquantumaddress()["address"]
        for record in records:
            self.log.info("%s: restore ONLY the old backup into an isolated wallet of a fresh node", record["kind"])
            n1.restorewallet("restored-" + record["kind"], record["old_backup"])
            restored = n1.get_wallet_rpc("restored-" + record["kind"])
            if record["passphrase"]:
                assert "unlocked_until" in restored.getwalletinfo(), "the backup of an encrypted wallet must be encrypted"
                restored.walletpassphrase(record["passphrase"], 1000)
            info = restored.getaddressinfo(record["claim"])
            assert_equal(info["ismine"], True)
            payout = record["payout"]
            assert payout["txid"] in [tx["txid"] for tx in restored.listtransactions("*", 1000)]
            unspent = [u for u in restored.listunspent(0) if (u["txid"], u["vout"]) == (payout["txid"], payout["vout"])]
            assert_equal(len(unspent), 1)
            assert unspent[0]["confirmations"] > MATURITY
            spend = restored.send(outputs=[{destination: record["payout_value"] - Decimal("0.02")}],
                                  options={"inputs": [payout], "add_inputs": False, "change_address": record["claim"],
                                           "add_to_wallet": False})
            assert_equal(spend["complete"], True)
            accepted = n1.testmempoolaccept([spend["hex"]])[0]
            assert accepted["allowed"], accepted
            txid = n1.sendrawtransaction(spend["hex"])
            # n1 holds the transaction; it mines the block itself, so nothing waits on the trickle of its relay
            # (the mock clock stands still, and a relay timer is only reached when it moves)
            self.generatetoaddress(n1, 1, quantum_miner, sync_fun=self.sync_blocks)
            assert n1.getrawtransaction(txid, True)["confirmations"] >= 1
            self.log.info("%s: the old backup recovered, signed and had accepted the spend of the payout", record["kind"])


if __name__ == '__main__':
    OldBackupRecoveryTest().main()
