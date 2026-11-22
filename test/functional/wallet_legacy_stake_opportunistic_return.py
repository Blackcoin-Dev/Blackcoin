#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Legacy self-stakes are paid as one quantum output already in the opportunistic window.

Regtest: Gold Rush ends at G=61, Migration ends at M=91 (first Final block F=92), maturity 10. The mandatory
quantum return window starts at 81 (a legacy coinstake at h could not be spent before Final from there on). The
OPPORTUNISTIC window opens ten maturities before F, but never before the first Migration block: max(62, 92 - 100) = 62.
It runs from 62 through 80. Inside it:

 * with a ready return address a legacy self-stake pays ALL principal, reward and fees into ONE positive quantum
   output (the zero-valued signing carrier stays), even for a kernel above the split threshold and with a
   development donation configured;
 * without a ready address the wallet stakes legacy outputs exactly as before, and its status names the action;
 * a quantum cold-stake kernel keeps its own script and a quantum self-stake keeps its donation output;
 * the block before the window (height 61) still pays a legacy output with the address ready, and the mandatory
   window (81 on) is unchanged.

Node 1 is an UNMODIFIED v30.1.6 node that validates every block (the mock clock is after Protocol V3.1, so the
proof-of-stake kernel, signature and reward checks run): every redirected coinstake is accepted by it.
"""
import os
from decimal import Decimal

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal
from transition_t_final_util import (
    F,
    G,
    LAST_LEGACY_STAKE_HEIGHT,
    LIFECYCLE_ARGS,
    M,
    MATURITY,
    TransitionTFinalTestBase,
)

OPPORTUNISTIC_START = G + 1  # max(first Migration block, F - 10 * maturity)
MANDATORY_START = LAST_LEGACY_STAKE_HEIGHT + 1
SUBSIDY = Decimal("1.5")
SPLIT_KERNEL = Decimal("1500")  # above twice the stake combine threshold (1000)
SMALL_KERNEL = Decimal("900")
COLD_AMOUNT = Decimal("4000")
V30_1_6 = 300106


class LegacyStakeOpportunisticReturnTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 2
        self.setup_clean_chain = True
        # No automatic key creation: a return address is made ready only where the test says so.
        args = [a for a in LIFECYCLE_ARGS if not a.startswith("-qqallowautokeycreation")]
        self.extra_args = [args + ["-donatetodevfund=0"], args + ["-rpcdoccheck=0"]]

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

    def script_of(self, address):
        return bytes.fromhex(self.nodes[0].validateaddress(address)["scriptPubKey"])

    def stake_exact(self, wallet, outpoint):
        """The wallet's own staker makes the next block from exactly this output (every other output is locked for
        the moment); the unmodified node must accept the block."""
        others = [{"txid": u["txid"], "vout": u["vout"]} for u in wallet.listunspent(0, 9999999)
                  if (u["txid"], u["vout"]) != (outpoint["txid"], outpoint["vout"])]
        if others:
            wallet.lockunspent(False, others)
        try:
            block_hash = self.stake_outpoint(wallet, self.nodes[0], outpoint)
        finally:
            if others:
                wallet.lockunspent(True, others)
        self.sync_tips()
        return block_hash

    def coinstake_of(self, block_hash):
        coinstake = self.nodes[0].getblock(block_hash, 2)["tx"][1]
        return coinstake, [o for o in coinstake["vout"] if o["value"] > 0]

    def kernel_value(self, coinstake):
        vin = coinstake["vin"][0]
        spent = self.nodes[0].getrawtransaction(vin["txid"], True)
        return Decimal(str(spent["vout"][vin["vout"]]["value"]))

    def assert_one_quantum_output(self, block_hash, quantum_script, principal, fees=Decimal(0)):
        """All principal, reward and fees in one positive quantum output; the zero-valued legacy signing carrier kept."""
        coinstake, valued = self.coinstake_of(block_hash)
        assert_equal(len(coinstake["vin"]), 1)
        assert_equal(len(valued), 1)
        assert_equal(bytes.fromhex(valued[0]["scriptPubKey"]["hex"]), quantum_script)
        assert_equal(valued[0]["scriptPubKey"]["type"], "witness_unknown")
        assert_equal(Decimal(str(valued[0]["value"])), principal + SUBSIDY + fees)
        assert_equal(self.kernel_value(coinstake), principal)
        assert_equal(coinstake["vout"][0]["value"], 0)
        assert_equal(coinstake["vout"][1]["value"], 0)
        assert_equal(coinstake["vout"][1]["scriptPubKey"]["type"], "pubkey")
        return coinstake["txid"], valued[0]["n"]

    def assert_pays_legacy(self, block_hash):
        coinstake, valued = self.coinstake_of(block_hash)
        # A legacy output: a pubkey for a pay-to-pubkey-hash kernel, the kernel's own script for a bech32 one.
        assert valued and all(o["scriptPubKey"]["type"] in ("pubkey", "witness_v0_keyhash") for o in valued), valued
        return coinstake, valued

    def accepted_by_unmodified_node(self, block_hash):
        n0, n1 = self.nodes
        assert n1.getblockheader(block_hash)["confirmations"] > 0
        assert_equal(n1.getblock(block_hash)["height"], n0.getblock(block_hash)["height"])

    def run_test(self):
        n0, n1 = self.nodes
        default = n0.get_wallet_rpc(self.default_wallet_name)
        default.staking(False)
        self.set_initial_mt()
        assert_equal(n1.getnetworkinfo()["subversion"], "/Blackcoin:30.1.6(testnode1)/")
        pow_addr = default.getnewaddress("", "legacy")
        quantum_miner = default.getnewquantumaddress()["address"]
        for name in ("ready", "plain", "cold_owner", "cold_staker"):
            n0.createwallet(name)
        ready, plain, owner, cold_staker = (n0.get_wallet_rpc(n) for n in ("ready", "plain", "cold_owner", "cold_staker"))
        for wallet in (ready, plain, owner, cold_staker):
            wallet.staking(False)

        big_addr = ready.getnewaddress("", "legacy")
        small_addr = ready.getnewaddress("", "legacy")
        bech32_addr = ready.getnewaddress("", "bech32")
        last_addrs = [ready.getnewaddress("", "legacy"), ready.getnewaddress("", "legacy")]
        plain_addr = plain.getnewaddress("", "legacy")

        self.log.info("Funding: a kernel above the split threshold and ordinary ones for 'ready', one for 'plain'")
        self.generatetoaddress(n0, MATURITY + 14, pow_addr, sync_fun=self.sync_all)
        self.sync_mt_tip()
        big = default.sendtoaddress(big_addr, SPLIT_KERNEL)
        small = default.sendtoaddress(small_addr, SMALL_KERNEL)
        bech32 = default.sendtoaddress(bech32_addr, SMALL_KERNEL)
        last_txids = [default.sendtoaddress(a, SMALL_KERNEL) for a in last_addrs]
        plain_txid = default.sendtoaddress(plain_addr, SMALL_KERNEL)
        self.pow_blocks(n0, MATURITY + 2, pow_addr, sync=True)

        def outpoint(txid, address):
            vouts = n0.getrawtransaction(txid, True)["vout"]
            return {"txid": txid, "vout": [i for i, o in enumerate(vouts) if o["scriptPubKey"].get("address") == address][0]}
        big_out = outpoint(big, big_addr)
        small_out = outpoint(small, small_addr)
        bech32_out = outpoint(bech32, bech32_addr)
        last_outs = [outpoint(t, a) for t, a in zip(last_txids, last_addrs)]
        plain_out = outpoint(plain_txid, plain_addr)

        # 'ready' has a return address (an explicit RPC with key creation authorised), 'plain' has none.
        result = ready.setquantumstakereturn({"allow_new_quantum_key": True})
        assert_equal(result["ready"], True)
        quantum_script = self.script_of(result["address"])
        donation_address = ready.getqqdevelopmentdonationinfo()["recipient"]
        ready.setqqdevelopmentdonation(10, donation_address)
        donation_script = self.script_of(donation_address)

        self.pow_blocks(n0, G - 2 - n0.getblockcount(), pow_addr, sync=True)  # tip 59
        info = ready.getstakinginfo()
        assert_equal(info["legacy_staking_opportunistic_start_height"], OPPORTUNISTIC_START)
        assert_equal(info["legacy_staking_window_start_height"], MANDATORY_START)
        assert_equal(info["legacy_staking_in_opportunistic_window"], False)
        assert_equal(info["legacy_staking_in_window"], False)
        assert_equal(plain.getstakinginfo()["legacy_stake_return_ready"], False)

        self.log.info("Before the window (heights %d and %d, the last Gold Rush block): a ready address still gets a legacy output", G - 1, G)
        block = self.stake_exact(ready, small_out)
        assert_equal(n0.getblock(block)["height"], G - 1)
        legacy_back, _ = self.assert_pays_legacy(block)
        block = self.stake_exact(ready, bech32_out)
        assert_equal(n0.getblock(block)["height"], G)
        self.assert_pays_legacy(block)
        self.accepted_by_unmodified_node(block)
        assert_equal(ready.getstakinginfo()["legacy_staking_in_opportunistic_window"], True)  # the next block is 62

        self.log.info("Window start (height %d): a kernel above the split threshold, donation configured: ONE quantum output", OPPORTUNISTIC_START)
        block = self.stake_exact(ready, big_out)
        assert_equal(n0.getblock(block)["height"], OPPORTUNISTIC_START)
        redirected, redirected_vout = self.assert_one_quantum_output(block, quantum_script, SPLIT_KERNEL)
        self.accepted_by_unmodified_node(block)
        assert donation_script != quantum_script

        self.log.info("A quantum cold-stake delegation is funded now, to stake inside the window")
        staker_quantum = cold_staker.getnewquantumaddress()["address"]
        staker_key = cold_staker.dumpquantumkey(staker_quantum)
        delegation = owner.getnewquantumcoldstakingaddress(staker_key["public_key"], "window-delegated")
        qcs_address = delegation["address"]
        qcs_script = self.script_of(qcs_address)
        cold_staker.importquantumcoldstakingdelegation(delegation["owner_pubkey"], staker_key["public_key"], "window-delegated")
        cold_txid = default.sendtoaddress(qcs_address, COLD_AMOUNT)
        self.pow_blocks(n0, 1, pow_addr, sync=True)
        cold_return = cold_staker.setquantumstakereturn({"allow_new_quantum_key": True})
        cold_return_script = self.script_of(cold_return["address"])
        self.pow_blocks(n0, MATURITY, pow_addr, sync=True)  # everything above is mature now
        assert n0.getblockcount() < MANDATORY_START - 6, n0.getblockcount()

        self.log.info("A block with a fee-paying transaction: principal, reward and the fees in the one quantum output")
        fee_input = [u for u in default.listunspent(1, 9999999, [pow_addr]) if u["spendable"] and u["confirmations"] > MATURITY][0]
        fee_txid = default.send(outputs=[{default.getnewaddress("", "legacy"): Decimal("1")}],
                                options={"inputs": [{"txid": fee_input["txid"], "vout": fee_input["vout"]}],
                                         "add_inputs": False, "fee_rate": 200})["txid"]
        block_fee = Decimal(str(n0.getmempoolentry(fee_txid)["fees"]["base"]))
        assert block_fee > 0
        back_out = {"txid": legacy_back["txid"], "vout": [o["n"] for o in legacy_back["vout"] if o["value"] > 0][0]}
        block = self.stake_exact(ready, back_out)
        assert fee_txid in n0.getblock(block)["tx"], "the fee-paying transaction is in the staked block"
        assert OPPORTUNISTIC_START < n0.getblock(block)["height"] < MANDATORY_START
        back_value = self.kernel_value(n0.getblock(block, 2)["tx"][1])
        self.assert_one_quantum_output(block, quantum_script, back_value, fees=block_fee)
        self.accepted_by_unmodified_node(block)

        self.log.info("A quantum self-stake keeps its donation output; the legacy redirects never carry one")
        block = self.stake_exact(ready, {"txid": redirected, "vout": redirected_vout})
        coinstake, valued = self.coinstake_of(block)
        assert donation_script in [bytes.fromhex(o["scriptPubKey"]["hex"]) for o in valued], "a quantum kernel pays the configured donation"
        self.accepted_by_unmodified_node(block)

        self.log.info("No destination ready: 'plain' stakes a legacy output as before, and its status names the action")
        info = plain.getstakinginfo()
        assert_equal(info["legacy_staking_in_opportunistic_window"], True)
        assert_equal(info["legacy_stake_return_ready"], False)
        assert "setquantumstakereturn" in info["legacy_stake_return_action"]
        assert "Opportunistic return is OFF" in info["legacy_staking_notice"], info["legacy_staking_notice"]
        assert_equal(info["legacy_staking_stopped"], False)  # the window is not mandatory yet
        block = self.stake_exact(plain, plain_out)
        assert OPPORTUNISTIC_START < n0.getblock(block)["height"] < MANDATORY_START
        self.assert_pays_legacy(block)
        self.accepted_by_unmodified_node(block)
        assert "Opportunistic return is ON" in ready.getstakinginfo()["legacy_staking_notice"]

        self.log.info("A quantum cold-stake kernel keeps its own script in the window")
        cold_out = {"txid": cold_txid, "vout": cold_staker.listunspent(1, 9999999, [qcs_address])[0]["vout"]}
        block = self.stake_exact(cold_staker, cold_out)
        assert OPPORTUNISTIC_START < n0.getblock(block)["height"] < MANDATORY_START
        coinstake, valued = self.coinstake_of(block)
        paid = sum((Decimal(str(o["value"])) for o in valued if bytes.fromhex(o["scriptPubKey"]["hex"]) == qcs_script), Decimal(0))
        assert paid >= COLD_AMOUNT
        assert all(bytes.fromhex(o["scriptPubKey"]["hex"]) != cold_return_script for o in valued)
        self.accepted_by_unmodified_node(block)

        self.log.info("Last opportunistic height (%d) and the first mandatory one (%d): both pay one quantum output", MANDATORY_START - 1, MANDATORY_START)
        self.pow_blocks(n0, MANDATORY_START - 2 - n0.getblockcount(), pow_addr, sync=True)
        assert_equal(n0.getblockcount(), MANDATORY_START - 2)
        for expected_height, coin in zip((MANDATORY_START - 1, MANDATORY_START), last_outs):
            block = self.stake_exact(ready, coin)
            assert_equal(n0.getblock(block)["height"], expected_height)
            self.assert_one_quantum_output(block, quantum_script, self.kernel_value(n0.getblock(block, 2)["tx"][1]))
            self.accepted_by_unmodified_node(block)
        assert_equal(plain.getstakinginfo()["legacy_staking_stopped"], True)  # the mandatory window is unchanged

        self.log.info("Up to M and the first Final block: both nodes agree")
        self.pow_blocks(n0, M - n0.getblockcount(), pow_addr, sync=True)
        assert_equal(n0.getblockcount(), M)
        self.sync_tips()
        self.generatetoaddress(n0, 1, quantum_miner, sync_fun=self.sync_all)
        assert_equal(n0.getblockcount(), F)
        self.sync_tips()
        assert_equal(n1.getquantumquasarinfo()["phase"], "final_lockout")


if __name__ == '__main__':
    LegacyStakeOpportunisticReturnTest().main()
