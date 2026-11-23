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
from test_framework.test_framework import BitcoinTestFramework
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
            node.createwallet(name)
        node.createwallet("tmp")
        # wk: only a bech32 descriptor, so it can make no legacy address.
        node.createwallet(wallet_name="wk", blank=True)
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
        self.bump()
        assert LABEL not in w.listlabels(), "the destination was made although the next block is Final"
        tip_hash = node.getbestblockhash()
        node.invalidateblock(tip_hash)
        assert_equal(node.getblockcount(), M - 1)
        # The kernel's slot, found with the staker running: it takes the first slot it can.
        self.arrive_at_slot(w, kernels["w"])
        try:
            self.wait_until(lambda: node.getblockcount() == M, timeout=20)
        except AssertionError:
            self.log.error("DEBUG %s", {k: v for k, v in w.getstakinginfo().items() if k in ("weight", "eligible", "staking_state", "staking_reason")})
            self.log.error("DEBUG readiness %s", w.getquantumstakereadiness()["next_block"])
            w.staking(False)
            self.log.error("DEBUG unspent %s", w.listunspent(0, 9999999))
            self.log.error("DEBUG kernel %s", kernels["w"])
            self.log.error("DEBUG balances %s", w.getbalances())
            self.log.error("DEBUG try plain stake_outpoint")
            self.stake_outpoint(w, node, kernels["w"])
            raise
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
        self.back_to_tip_and_reorg(wi, M)
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
        self.arrive_at_slot(wk, kernels["wk"])
        for _ in range(3):
            self.bump()
        assert_equal(node.getblockcount(), height)
        assert LABEL not in wk.listlabels()
        wk.staking(False)
        self.assert_alive()

    def arrive_at_slot(self, wallet, outpoint):
        """Move the mock clock to the first slot at which this kernel is valid, through the slot before it, so that the
        running worker has searched up to the previous slot when the kernel's slot arrives."""
        slot = self.kernel_slot_for(wallet, outpoint)
        self.set_mt(slot - 16)
        self.wait_until(lambda: wallet.getstakinginfo()["staking_snapshot_current"], timeout=60)
        self.set_mt(slot)

    def back_to_tip_and_reorg(self, wallet, tip, expect_log=None):
        """Bring the chain to `tip` (the block invalidated by the previous step is reconsidered when the chain is a block
        short), start the wallet's worker there (the next block is Final), then reorganise to tip - 1."""
        node = self.nodes[0]
        if node.getblockcount() == tip - 1:
            node.reconsiderblock(self.invalidated)
        assert_equal(node.getblockcount(), tip)
        self.sync_mt_tip()
        wallet.staking(True)
        self.bump()
        self.invalidated = node.getbestblockhash()
        if expect_log:
            with node.assert_debug_log([expect_log], timeout=30):
                node.invalidateblock(self.invalidated)
        else:
            node.invalidateblock(self.invalidated)
        assert_equal(node.getblockcount(), tip - 1)


if __name__ == '__main__':
    FinalReorgStakerDestinationTest().main()
