#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""A staker worker started at the first Final block has no legacy destination; a reorganisation back into Migration
must give it one without a restart.

Regtest: Gold Rush ends at G=61, Migration ends at M=91 (first Final block F=92), maturity 10. The worker of a wallet
that is started with the tip at M has no legacy staking destination (the next block is Final, where no legacy kernel
can stake). When the chain is then reorganised back to M - 1 the next block is a Migration block again, and a legacy
witness-v0 (bech32) kernel with a ready quantum return can stake. The worker makes the destination (the address
labelled "Staking Legacy Address") in its own loop, after its waits and before it assembles a block, without a restart.

 * wallet "w": the worker started at M, the tip moved back to M - 1: the label appears, the wallet's staker makes block
   M from the bech32 kernel and pays the quantum return, and the worker was never restarted;
 * wallet "wi": the address labelled "Staking Legacy Address" is not a key-hash address: the staker makes no block (it
   cannot derive a minter key from it), and nothing crashes;
 * wallet "wk": the wallet has no legacy address source (only a bech32 descriptor): making the destination fails, the
   worker reports the fault and retries, and nothing crashes.
"""
from test_framework.descriptors import descsum_create
from test_framework.test_framework import BitcoinTestFramework, SkipTest
from test_framework.util import assert_equal
from transition_t_final_util import (
    G,
    LIFECYCLE_ARGS,
    M,
    TransitionTFinalTestBase,
)

LABEL = "Staking Legacy Address"
STARTED = "PoSMiner started for proof-of-stake"


class FinalReorgStakerDestinationTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.extra_args = [LIFECYCLE_ARGS + ["-donatetodevfund=0", "-debug=coinstake"]]

    def add_options(self, parser):
        self.add_wallet_options(parser)

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()
        # The wallet that can make no legacy address is a blank wallet with one imported bech32 descriptor.
        if not self.options.descriptors:
            raise SkipTest("this test needs descriptor wallets (it imports a descriptor to make a wallet without a legacy address manager)")

    def log_text(self):
        with open(self.nodes[0].debug_log_path, encoding="utf-8", errors="replace") as log:
            return log.read()

    def assert_alive(self):
        assert self.nodes[0].process.poll() is None, "the node exited"
        assert "ThreadStakeMiner restarting" not in self.log_text(), "a staker worker was restarted"

    def run_test(self):
        node = self.nodes[0]
        default = node.get_wallet_rpc(self.default_wallet_name)
        default.staking(False)
        self.set_initial_mt()
        pow_addr = default.getnewaddress("", "legacy")

        self.log.info("Three wallets, each with a mature bech32 (witness v0) coinbase kernel and a ready quantum return")
        for name in ("w", "wi"):
            node.createwallet(name, descriptors=True)
        node.createwallet("tmp", descriptors=True)
        # wk: only a bech32 descriptor, so it can make no legacy address.
        node.createwallet(wallet_name="wk", blank=True, descriptors=True)
        tmp = node.get_wallet_rpc("tmp")
        private = [d for d in tmp.listdescriptors(True)["descriptors"] if d["desc"].startswith("wpkh(") and not d["internal"]][0]["desc"]
        wk = node.get_wallet_rpc("wk")
        imported = wk.importdescriptors([{"desc": descsum_create(private.split("#")[0]), "timestamp": "now", "active": True, "range": [0, 20], "next_index": 0}])
        assert imported[0]["success"], imported
        wallets = {name: node.get_wallet_rpc(name) for name in ("w", "wi", "wk")}
        addresses = {}
        for name, wallet in wallets.items():
            wallet.staking(False)
            addresses[name] = wallet.getnewaddress("", "bech32")
        self.pow_blocks(node, G - node.getblockcount(), pow_addr)
        # After Gold Rush a legacy kernel needs a lineage the wallet can prove: a bech32 coin is one only when it was paid
        # by an ordinary transaction after Gold Rush ended (a bech32 coinbase is not).
        self.pow_blocks(node, 1, pow_addr)
        for name in wallets:
            default.sendtoaddress(addresses[name], 5000)
        self.pow_blocks(node, 1, pow_addr)
        kernels = {}
        for name, wallet in wallets.items():
            unspent = wallet.listunspent(1, 9999999, [addresses[name]])
            assert_equal(len(unspent), 1)
            kernels[name] = {"txid": unspent[0]["txid"], "vout": unspent[0]["vout"]}
        self.pow_blocks(node, M - node.getblockcount(), pow_addr)
        assert_equal(node.getblockcount(), M)
        returns = {}
        for name, wallet in wallets.items():
            returned = wallet.setquantumstakereturn({"allow_new_quantum_key": True})
            assert_equal(returned["ready"], True)
            returns[name] = bytes.fromhex(wallet.validateaddress(returned["address"])["scriptPubKey"])
            assert LABEL not in wallet.listlabels()

        # 1. The worker starts at M (next block Final) and makes its destination after the chain goes back.
        self.log.info("w: the worker is started at the tip M, then the chain is reorganised back to M - 1")
        w = wallets["w"]
        started_before = self.log_text().count(STARTED)
        self.sync_mt_tip()
        w.staking(True)
        self.wait_until(lambda: self.log_text().count(STARTED) == started_before + 1, timeout=30)
        # The worker's "started" line comes before its startup initialisation: wait until it has searched at the tip M
        # (state searching, snapshot current, M blocks), so that the startup is over and nothing is made at M - 1 by it.
        self.wait_worker_at(w, M)
        assert LABEL not in w.listlabels(), "the destination was made although the next block is Final"
        tip_hash = node.getbestblockhash()
        node.invalidateblock(tip_hash)
        assert_equal(node.getblockcount(), M - 1)
        # The kernel's slot, found with the staker running: it takes the first slot it can.
        self.arrive_at_slot(w, kernels["w"])
        self.wait_until(lambda: node.getblockcount() == M, timeout=60)
        w.staking(False)
        coinstake = node.getblock(node.getbestblockhash(), 2)["tx"][1]
        assert_equal((coinstake["vin"][0]["txid"], coinstake["vin"][0]["vout"]), (kernels["w"]["txid"], kernels["w"]["vout"]))
        valued = [o for o in coinstake["vout"] if o["value"] > 0]
        assert_equal(len(valued), 1)
        assert_equal(bytes.fromhex(valued[0]["scriptPubKey"]["hex"]), returns["w"])
        assert LABEL in w.listlabels()
        assert_equal(self.log_text().count(STARTED), started_before + 1)  # one worker, never restarted
        self.assert_alive()

        # 2. A destination with that label that is not a key-hash address: no minter key, no block, no crash.
        self.log.info("wi: the staking destination is labelled but is not a key-hash address")
        wi = wallets["wi"]
        bad = wi.getnewquantumaddress()["address"]
        wi.setlabel(bad, LABEL)
        self.back_to_tip_and_reorg(wi, M, labelled=True)
        with node.assert_debug_log(["the staking destination is not a key-hash address"], timeout=30):
            self.arrive_at_slot(wi, kernels["wi"])
        height = node.getblockcount()
        for _ in range(5):
            self.bump()
            self.wait_until(lambda: wi.getstakinginfo()["staking_snapshot_current"], timeout=60)
        assert_equal(node.getblockcount(), height)
        wi.staking(False)
        self.assert_alive()

        # 3. No legacy address can be made: the worker reports the fault and retries; the node stays up.
        self.log.info("wk: the wallet can make no legacy address")
        wk = wallets["wk"]
        assert LABEL not in wk.listlabels()
        self.back_to_tip_and_reorg(wk, M, expect_log="Keypool ran out")
        height = node.getblockcount()
        started = self.log_text().count(STARTED)
        # The failure is reported as the worker's error state at the current tip, and retried (a growing back-off) without
        # a new worker or a restart.
        self.wait_worker_at(wk, M - 1, states=("error",))
        self.wait_until(lambda: self.log_text().count("PoSMiner: Error: Keypool ran out") >= 3, timeout=30)
        self.arrive_at_slot(wk, kernels["wk"])
        for _ in range(3):
            self.bump()
        assert_equal(node.getblockcount(), height)
        assert_equal(self.log_text().count(STARTED), started)
        assert wk.getstakinginfo()["worker_running"]
        assert LABEL not in wk.listlabels()
        wk.staking(False)
        self.assert_alive()

    def wait_worker_at(self, wallet, height, states=("searching", "no_eligible_coins")):
        """The worker of `wallet` is running and has finished its startup: its telemetry for the current tip, `height`
        blocks, shows a post-startup state."""
        def settled():
            info = wallet.getstakinginfo()
            return (info["worker_running"] and info["staking_state"] in states and info["staking_snapshot_current"]
                    and info["active_blocks"] == height)
        self.wait_until(settled, timeout=30)

    def arrive_at_slot(self, wallet, outpoint):
        """Move the mock clock to the first slot at which this kernel is valid, through the slot before it, so that the
        running worker has searched up to the previous slot when the kernel's slot arrives."""
        slot = self.kernel_slot_for(wallet, outpoint)
        self.set_mt(slot - 16)
        self.wait_until(lambda: wallet.getstakinginfo()["staking_snapshot_current"], timeout=60)
        self.set_mt(slot)

    def back_to_tip_and_reorg(self, wallet, tip, expect_log=None, labelled=False):
        """Bring the chain to `tip` (the block invalidated by the previous step is reconsidered when the chain is a block
        short), start the wallet's worker there (the next block is Final), then reorganise to tip - 1."""
        node = self.nodes[0]
        if node.getblockcount() == tip - 1:
            node.reconsiderblock(self.invalidated)
        assert_equal(node.getblockcount(), tip)
        self.sync_mt_tip()
        wallet.staking(True)
        self.wait_worker_at(wallet, tip)
        assert LABEL not in wallet.listlabels() or labelled, "the destination was made although the next block is Final"
        self.invalidated = node.getbestblockhash()
        if expect_log:
            with node.assert_debug_log([expect_log], timeout=30):
                node.invalidateblock(self.invalidated)
        else:
            node.invalidateblock(self.invalidated)
        assert_equal(node.getblockcount(), tip - 1)


if __name__ == '__main__':
    FinalReorgStakerDestinationTest().main()
