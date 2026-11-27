#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""The last legacy coinstake at the cutoff, and a template that crosses it.

Regtest: Gold Rush ends at G=61, Migration ends at M=91, maturity 10, so the last height at which the
wallet still pays a legacy coinstake to a legacy output is 80 (M - maturity - 1) and from 81 a legacy kernel
is paid to the quantum stake return address.

 * Split output at the cutoff: a kernel large enough to be split pays TWO value-bearing legacy outputs at
   height 80. Both mature at 90, and both are migrated in time (the multi-output coinstake is the changed
   wallet boundary, which a coinbase that matures at the boundary does not exercise).
 * Delayed construction across the cutoff: a block template built for height 80 pays legacy outputs. When
   another block takes height 80 first, the template is stale: the node does not take it as the new tip.
   The same kernel, built again for height 81, is built under the new parent's policy: one value-bearing
   quantum output of the wallet and nothing else of value. The cutoff is wallet policy, so nothing here
   asserts that consensus forbids an otherwise valid legacy-return block.
"""
from decimal import Decimal

from test_framework.messages import CBlock, from_hex
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal
from transition_t_final_util import (
    LAST_LEGACY_STAKE_HEIGHT,
    LIFECYCLE_ARGS,
    M,
    MATURITY,
    TransitionTFinalTestBase,
)

SPLIT_THRESHOLD = Decimal("1000")  # twice the stake combine threshold (500 coins)


class LegacyStakeCutoffBoundaryTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        # No automatic key creation: a ready return address would make the wallet pay legacy stakes as quantum outputs
        # from the opportunistic window on, and this test needs legacy outputs up to the cutoff at 80.
        args = [a for a in LIFECYCLE_ARGS if not a.startswith("-qqallowautokeycreation")]
        self.extra_args = [args + ["-donatetodevfund=0", "-qqstaketierheight=1"]]

    def kernel_slot_for(self, wallet, outpoint):
        """The shared search with a larger bound: a kernel is found with a probability of the order of one
        in ten thousand per 16 second slot on this chain, so 30000 slots fail now and then."""
        for _ in range(300000):
            result = wallet.checkkernel([outpoint])
            if result["found"]:
                return result["kernel"]["time"]
            self.bump()
        raise AssertionError("no kernel slot found for %s" % outpoint)

    def script_type(self, node, script):
        return node.decodescript(script.hex())["type"]

    def template_outputs(self, node, template):
        """The value-bearing outputs of the coinstake of a block template, as (type, value)."""
        block = from_hex(CBlock(), template["blocktemplate"])
        return [(self.script_type(node, o.scriptPubKey), Decimal(o.nValue) / 100000000) for o in block.vtx[1].vout if o.nValue > 0]

    def run_test(self):
        node = self.nodes[0]
        wallet = node.get_wallet_rpc(self.default_wallet_name)
        wallet.staking(False)
        self.set_initial_mt()
        assert_equal(LAST_LEGACY_STAKE_HEIGHT, 80)

        stake_addr = wallet.getnewaddress("", "legacy")
        small_addr = wallet.getnewaddress("", "legacy")
        pow_addr = wallet.getnewaddress("", "legacy")
        funder_addr = wallet.getnewaddress("", "legacy")

        self.generatetoaddress(node, MATURITY + 14, funder_addr)
        self.sync_mt_tip()
        # One big and one ordinary mature legacy output, each the only output of its address.
        big = wallet.sendtoaddress(stake_addr, SPLIT_THRESHOLD + Decimal("500"))
        small = wallet.sendtoaddress(small_addr, Decimal("900"))  # below the split threshold: one output
        self.pow_blocks(node, MATURITY + 2, pow_addr)

        def outpoint(txid, address):
            return {"txid": txid, "vout": [i for i, o in enumerate(node.getrawtransaction(txid, True)["vout"])
                                           if o["scriptPubKey"].get("address") == address][0]}
        big_out = outpoint(big, stake_addr)
        small_out = outpoint(small, small_addr)
        self.pow_blocks(node, 78 - node.getblockcount(), pow_addr)
        assert_equal(node.getblockcount(), 78)
        # With a ready return address a legacy kernel is paid to it already in the opportunistic window (from 62), so
        # the address is made ready only after the last legacy coinstake below, at the mandatory cutoff.
        assert_equal(wallet.getstakinginfo()["legacy_stake_return_ready"], False)

        self.log.info("Height 79 from another kernel; the big and the ordinary kernel are kept for 80 and 81")
        self.stake_one(wallet, node, [pow_addr])
        assert_equal(node.getblockcount(), LAST_LEGACY_STAKE_HEIGHT - 1)

        self.log.info("A template for height 80 from the ordinary kernel: one legacy output (it will go stale)")
        self.kernel_slot_for(wallet, small_out)
        stale = wallet.checkkernel([small_out], True)
        assert "blocktemplate" in stale, stale
        assert_equal([t for t, _ in self.template_outputs(node, stale)], ["pubkey"])

        self.log.info("The last legacy coinstake (height %d) from a kernel above the split threshold: two legacy outputs", LAST_LEGACY_STAKE_HEIGHT)
        # The staker takes any eligible kernel: lock the others so that it is the big one.
        others = [{"txid": u["txid"], "vout": u["vout"]} for u in wallet.listunspent(0)
                  if (u["txid"], u["vout"]) != (big_out["txid"], big_out["vout"])]
        wallet.lockunspent(False, others)
        block_hash = self.stake_outpoint(wallet, node, big_out)
        wallet.lockunspent(True, others)
        block = node.getblock(block_hash, 2)
        assert_equal(block["height"], LAST_LEGACY_STAKE_HEIGHT)
        coinstake = block["tx"][1]
        valued = [o for o in coinstake["vout"] if o["value"] > 0]
        assert_equal(len(valued), 2)
        assert all(o["scriptPubKey"]["type"] == "pubkey" for o in valued), valued
        principal = SPLIT_THRESHOLD + Decimal("500")
        assert_equal(sum(o["value"] for o in valued), principal + Decimal("1.5"))  # principal plus the regtest reward, no fee
        split_txid = coinstake["txid"]

        self.log.info("The template built for height 80 is stale now: the node does not take it as the new tip")
        tip = node.getbestblockhash()
        result = node.submitblock(stale["blocktemplate"])
        assert result is not None and result != "duplicate", result  # not accepted as the best block
        assert_equal(node.getbestblockhash(), tip)

        self.log.info("The same kernel built again for height 81 follows the new parent's policy: one quantum output")
        # The wallet's return address becomes ready now: from the cutoff a legacy kernel must be paid to it.
        assert_equal(wallet.setquantumstakereturn({"allow_new_quantum_key": True})["ready"], True)
        return_script = node.validateaddress(wallet.getstakinginfo()["legacy_stake_return_address"])["scriptPubKey"]
        self.bump()
        self.kernel_slot_for(wallet, small_out)
        rebuilt = wallet.checkkernel([small_out], True)
        assert "blocktemplate" in rebuilt, rebuilt
        rebuilt_outputs = self.template_outputs(node, rebuilt)
        assert_equal(len(rebuilt_outputs), 1)
        assert_equal(rebuilt_outputs[0][0], "witness_unknown")
        rebuilt_block = from_hex(CBlock(), rebuilt["blocktemplate"])
        assert_equal([o.scriptPubKey.hex() for o in rebuilt_block.vtx[1].vout if o.nValue > 0], [return_script])

        self.log.info("Both halves of the split coinstake mature at %d and are migrated in time", LAST_LEGACY_STAKE_HEIGHT + MATURITY)
        self.pow_blocks(node, M - 1 - node.getblockcount(), pow_addr)
        assert_equal(node.getblockcount(), M - 1)
        quantum_address = wallet.getnewquantumaddress()["address"]
        migrated = wallet.migratetoquantum({"existing_address": quantum_address})
        assert_equal(migrated["more_batches"], False)
        spent = {(v["txid"], v["vout"]) for v in node.getrawtransaction(migrated["txid"], True)["vin"]}
        for o in valued:
            assert (split_txid, o["n"]) in spent, "a half of the split coinstake was left out of the migration"
        self.pow_blocks(node, 1, pow_addr)
        assert_equal(node.getblockcount(), M)
        for o in valued:
            assert_equal(node.gettxout(split_txid, o["n"]), None)
        assert node.getrawtransaction(migrated["txid"], True, node.getbestblockhash())["confirmations"] == 1


if __name__ == '__main__':
    LegacyStakeCutoffBoundaryTest().main()
