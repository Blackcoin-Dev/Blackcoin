#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""The wallet staker uses an output exactly `maturity` blocks deep, as consensus does.

Consensus accepts a kernel when `next block height - output height >= maturity`
(CheckProofOfStake). An output created at height h is therefore a valid kernel for the block
at height h + maturity, which is the block after a tip at which the output is `maturity`
confirmations deep. The wallet used to treat a coinbase or coinstake as immature for one more
block, so a wallet whose only stakable coin was such an output did not stake it, and in
particular did not produce block F (the first Final block) from a quantum coinstake payout
created exactly `maturity` blocks earlier.

Regtest: maturity 10, Migration ends at M=91 (F=92), the legacy stake window starts at 81.
Every wallet here holds exactly one stakable coin, so the only way a block appears is that the
normal wallet staker selects that coin. Node 1 is an UNMODIFIED v30.1.6 node that validates every
block (the mock clock is after Protocol V3.1, so the proof-of-stake kernel checks run).

 * a legacy coinbase exactly `maturity` deep stakes (the same off-by-one for a coinbase);
 * a quantum coinstake payout made at height 81 stakes block 91 (ordinary Migration);
 * the same for the forced-kernel path (checkkernel builds a template for it);
 * status: the readiness report (the staker's own candidate scan) counts it as stakeable at
   that depth, and as excluded (immature) one block earlier;
 * a quantum coinstake payout made at height 82 stakes block F=92 (the first Final block),
   across a restart;
 * a reorganisation replaces that block: the kernel is unspent again and stakes again;
 * one block before the consensus condition nothing is selected (no premature staking).
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
PAYOUT = Decimal("10001.5")  # 10000 coin coinbase kernel plus the 1.5 coin reward


class QuantumStakeMaturityTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 2
        self.setup_clean_chain = True
        self.extra_args = [LIFECYCLE_ARGS, LIFECYCLE_ARGS + ["-rpcdoccheck=0"]]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()
        if not os.environ.get("BLACKCOIN_V30_1_6_BINARY"):
            self.skip_if_no_previous_releases()

    def setup_nodes(self):
        override = os.environ.get("BLACKCOIN_V30_1_6_BINARY")
        if override:
            self.add_nodes(self.num_nodes, extra_args=self.extra_args,
                           binary=[self.options.bitcoind, override],
                           binary_cli=[self.options.bitcoincli] * 2)
        else:
            self.add_nodes(self.num_nodes, extra_args=self.extra_args, versions=[None, V30_1_6])
        self.start_nodes()
        self.import_deterministic_coinbase_privkeys()
        self.connect_nodes(0, 1)

    def sync_tips(self):
        n0, n1 = self.nodes
        self.wait_until(lambda: n0.getbestblockhash() == n1.getbestblockhash(), timeout=60)

    def kernel_slot(self, wallet, outpoint):
        """The mock time of the first slot at which the consensus kernel check passes for this
        output (the proof-of-stake difficulty falls after a long gap, so this can be the very
        next slot)."""
        for _ in range(30000):
            result = wallet.checkkernel([outpoint])
            if result["found"]:
                return result["kernel"]["time"]
            self.bump()
        raise AssertionError("no kernel slot found for %s" % outpoint)

    def stake_by_wallet(self, wallet, outpoint, expect_stakeable=None):
        """Let the wallet's own staker produce the next block; it must be the one that does.
        With expect_stakeable, the readiness report (which runs the staker's own candidate
        scan) must first show that quantum value as stakeable at the next block."""
        node = self.nodes[0]
        before = node.getblockcount()
        if expect_stakeable is not None:
            readiness = wallet.getquantumstakereadiness()
            assert_equal(readiness["next_block"]["height"], before + 1)
            assert_equal(readiness["next_block"]["stakeable"], expect_stakeable)
            assert_equal(readiness["next_block"]["excluded"]["immature"]["count"], 0)
        kernel_time = self.kernel_slot(wallet, outpoint)
        self.set_mt(kernel_time - 16)
        wallet.staking(True)
        try:
            self.set_mt(kernel_time)
            self.wait_until(lambda: node.getblockcount() > before, timeout=60)
        finally:
            wallet.staking(False)
        block_hash = node.getbestblockhash()
        assert_equal(node.getblockcount(), before + 1)
        block = node.getblock(block_hash, 2)
        assert "proof-of-stake" in block["flags"]
        assert_equal(block["tx"][1]["vin"][0]["txid"], outpoint["txid"])
        assert_equal(block["tx"][1]["vin"][0]["vout"], outpoint["vout"])
        self.sync_tips()  # the unmodified node validated the block
        return block_hash

    def selects_nothing(self, wallet):
        """The staker finds no stake at all (so it cannot produce a block)."""
        wallet.staking(True)
        try:
            self.wait_until(lambda: wallet.getstakinginfo()["staking_snapshot_current"], timeout=60)
            info = wallet.getstakinginfo()
            return info["eligible"] is False and info["weight"] == 0
        finally:
            wallet.staking(False)

    def run_test(self):
        n0, n1 = self.nodes
        default = n0.get_wallet_rpc(self.default_wallet_name)
        default.staking(False)
        self.set_initial_mt()
        assert_equal(n1.getnetworkinfo()["subversion"], "/Blackcoin:30.1.6(testnode1)/")
        pow_addr = default.getnewaddress("", "legacy")
        quantum_miner = default.getnewquantumaddress()["address"]

        wallets = {}
        for name in ("w2", "w3", "w4"):
            n0.createwallet(name)
            wallet = n0.get_wallet_rpc(name)
            wallet.staking(False)
            wallets[name] = wallet
            self.generatetoaddress(n0, 1, wallet.getnewaddress("", "legacy"), sync_fun=self.sync_all)
            self.bump()
        # w4's coin is the coinbase of height 3: exactly `maturity` deep at tip 12.
        self.pow_blocks(n0, MATURITY - 1, pow_addr, sync=True)
        assert_equal(n0.getblockcount(), 3 + MATURITY - 1)

        self.log.info("A legacy coinbase exactly maturity deep stakes (before the window)")
        w4 = wallets["w4"]
        coinbase = n0.getblock(n0.getblockhash(3), 2)["tx"][0]
        coin = {"txid": coinbase["txid"], "vout": 0}
        assert_equal(coinbase["vout"][0]["scriptPubKey"]["type"], "pubkeyhash")
        assert_equal(w4.gettransaction(coin["txid"])["confirmations"], MATURITY)
        self.stake_by_wallet(w4, coin)

        self.pow_blocks(n0, LAST_LEGACY_STAKE_HEIGHT - n0.getblockcount(), pow_addr, sync=True)
        assert_equal(n0.getblockcount(), LAST_LEGACY_STAKE_HEIGHT)

        self.log.info("Two quantum coinstake payouts: one made at height 81, one at height 82")
        payouts = {}
        for name in ("w3", "w2"):
            wallet = wallets[name]
            wallet.setquantumstakereturn({"allow_new_quantum_key": True})
            coin = wallet.listunspent(0)[0]
            block_hash = self.stake_by_wallet(wallet, {"txid": coin["txid"], "vout": coin["vout"]})
            coinstake = n0.getblock(block_hash, 2)["tx"][1]
            valued = [o for o in coinstake["vout"] if o["value"] > 0]
            assert_equal(len(valued), 1)
            assert_equal(valued[0]["scriptPubKey"]["type"], "witness_unknown")
            payouts[name] = {"txid": coinstake["txid"], "vout": valued[0]["n"],
                             "height": n0.getblock(block_hash)["height"]}
        assert_equal(payouts["w3"]["height"], LAST_LEGACY_STAKE_HEIGHT + 1)
        assert_equal(payouts["w2"]["height"], LAST_LEGACY_STAKE_HEIGHT + 2)

        # w3: block 91 = M is stakable from tip 90 (depth 10). w2: block F=92 from tip 91 (depth 10).
        self.pow_blocks(n0, M - 2 - n0.getblockcount(), pow_addr, sync=True)
        assert_equal(n0.getblockcount(), M - 2)
        w3 = wallets["w3"]
        w3_out = {"txid": payouts["w3"]["txid"], "vout": payouts["w3"]["vout"]}
        assert_equal(w3.gettransaction(w3_out["txid"])["confirmations"], MATURITY - 1)
        self.log.info("One block before the consensus condition nothing is selected")
        assert self.selects_nothing(w3)
        readiness = w3.getquantumstakereadiness()
        assert_equal(readiness["next_block"]["stakeable"], 0)
        assert_equal(readiness["next_block"]["excluded"]["immature"]["count"], 1)
        assert_equal(readiness["next_block"]["excluded"]["immature"]["amount"], PAYOUT)
        # ...and at the first Final block, given current maturities, it is stakeable.
        assert_equal(readiness["at_final"]["height"], F)
        assert_equal(readiness["at_final"]["stakeable"], PAYOUT)
        assert_equal(readiness["quantum_total"], PAYOUT)
        assert_equal(w3.checkkernel([w3_out])["found"], False)
        self.pow_blocks(n0, 1, pow_addr, sync=True)
        assert_equal(n0.getblockcount(), M - 1)
        assert_equal(w3.gettransaction(w3_out["txid"])["confirmations"], MATURITY)
        assert_equal(n0.getquantumquasarinfo()["phase"], "migration")

        self.log.info("Ordinary Migration: depth == maturity, status shows it, the wallet stakes it")
        self.log.info("...forced kernel: a block template is built for exactly that kernel")
        self.kernel_slot(w3, w3_out)
        template = w3.checkkernel([w3_out], True)
        assert "blocktemplate" in template, template
        assert_equal(template["kernel"]["txid"], w3_out["txid"])
        self.bump()  # the template search used up this slot; the staker takes a later one
        self.stake_by_wallet(w3, w3_out, expect_stakeable=PAYOUT)
        assert_equal(n0.getblockcount(), M)

        self.log.info("Restart, then block F from the payout made %d blocks earlier", MATURITY)
        self.restart_node(0, extra_args=self.extra_args[0] + ["-mocktime=%d" % self.mt])
        self.connect_nodes(0, 1)
        for name in ("w2", "w3", "w4"):
            n0.loadwallet(name)
            wallets[name] = n0.get_wallet_rpc(name)
            wallets[name].staking(False)
        self.set_mt(self.mt)
        w2 = wallets["w2"]
        w2_out = {"txid": payouts["w2"]["txid"], "vout": payouts["w2"]["vout"]}
        assert_equal(w2.gettransaction(w2_out["txid"])["confirmations"], MATURITY)
        assert_equal(n0.getblockcount(), M)
        assert_equal(n0.getquantumquasarinfo()["phase"], "final_lockout")  # the phase of the next block, F
        f_hash = self.stake_by_wallet(w2, w2_out, expect_stakeable=PAYOUT)
        assert_equal(n0.getblockcount(), F)
        assert_equal(n0.getquantumquasarinfo()["phase"], "final_lockout")
        assert_equal(n1.getquantumquasarinfo()["phase"], "final_lockout")
        assert_equal(n1.getbestblockhash(), f_hash)

        self.log.info("A reorganisation replaces block F: the kernel is unspent again and stakes again")
        self.disconnect_nodes(0, 1)
        n1.invalidateblock(f_hash)
        self.generatetoaddress(n1, 2, quantum_miner, sync_fun=self.no_op)
        self.sync_mt_tip()
        assert_equal(n1.getblockcount(), F + 1)
        self.connect_nodes(0, 1)
        self.sync_tips()
        assert_equal(n0.getblockcount(), F + 1)
        assert n0.gettxout(w2_out["txid"], w2_out["vout"]) is not None
        self.bump()
        self.stake_by_wallet(w2, w2_out, expect_stakeable=PAYOUT)
        assert_equal(n0.getblockcount(), F + 2)


if __name__ == '__main__':
    QuantumStakeMaturityTest().main()
