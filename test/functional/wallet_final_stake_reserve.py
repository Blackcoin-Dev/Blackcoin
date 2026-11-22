#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""The final stake reserve: quantum outputs held back in the last maturity period of Migration.

Regtest: Gold Rush ends at G=61, Migration ends at M=91 (first Final block F=92), maturity 10. A quantum coinstake
made at height h can stake again only from h + 10, so a wallet that stakes all of its quantum outputs at heights
83..91 has nothing mature left at F. The wallet therefore keeps R = min(32, (N + 1) / 2) of its N qualifying outputs
out of the staker and out of every automatic spend for the candidate heights F - maturity = 82 .. M = 91, and releases
them for F.

Node 1 runs with -finalstakereserve=0 and is the E2 experiment: it stakes every one of its outputs from height 83, and
the test ASSERTS that nothing is left at the tip M and that the wallet's own staker does not produce block F.
Node 0 runs with the default (the reserve on) and the same history:

 * the positive case: block F is produced by the wallet's own staker from a reserved output;
 * N = 1: the sole output is withheld for the whole guard and stakes at F + 1;
 * a restart inside the window gives the same reserve; a reorganisation across F and one into the window recompute it;
 * a user-locked output is not a source and is never reserved;
 * ordinary automatic coin selection skips the reserve while explicit coin control may spend it, and the readiness
   report names the affected outpoints;
 * a quantum coinstake consumes exactly one output (so it cannot take a second reserve-eligible one);
 * every readiness field.
"""
from decimal import Decimal

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import (
    assert_equal,
    assert_raises_rpc_error,
)
from transition_t_final_util import (
    F,
    G,
    LIFECYCLE_ARGS,
    M,
    MATURITY,
    TransitionTFinalTestBase,
)

GUARD_START = F - MATURITY  # 82, the first candidate height with the reserve on
K_MAIN = 6
K_SINGLE = 1
K_LOCKED = 4
K_SPEND = 2
K_NEGATIVE = 6


def key(outpoint):
    return (outpoint["txid"], outpoint["vout"])


class FinalStakeReserveTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 2
        self.setup_clean_chain = True
        # Two independent chains, never connected: node 0 has the reserve on (the default), node 1 has it off.
        self.extra_args = [LIFECYCLE_ARGS, LIFECYCLE_ARGS + ["-finalstakereserve=0"]]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def setup_network(self):
        # Two independent chains: the nodes are never connected.
        self.setup_nodes()

    def reserve(self, wallet):
        return wallet.getquantumstakereadiness()["final_stake_reserve"]

    def reserved_keys(self, wallet):
        return {(o["txid"], o["vout"]) for o in self.reserve(wallet)["reserved_outpoints"]}

    def build_wallet(self, node, pow_addr, name, count):
        """A wallet with `count` quantum outputs, each migrated from its own legacy coinbase (a quantum coinbase has no
        lineage and is not stakable). Returns (wallet, [quantum addresses])."""
        node.createwallet(name)
        wallet = node.get_wallet_rpc(name)
        wallet.staking(False)
        for _ in range(count):
            self.generatetoaddress(node, 1, wallet.getnewaddress("", "legacy"), sync_fun=self.no_op)
            self.bump()
        return wallet

    def migrate_all(self, node, pow_addr, wallet, count):
        addresses = []
        for _ in range(count):
            address = wallet.getnewquantumaddress()["address"]
            wallet.migratetoquantum({"existing_address": address, "max_inputs": 1})
            self.pow_blocks(node, 1, pow_addr)
            addresses.append(address)
        return addresses

    def quantum_outputs(self, wallet, addresses):
        return [u for u in wallet.listunspent(1, 9999999, addresses) if u["amount"] > 0]

    def settle(self, wallet):
        self.wait_until(lambda: wallet.getstakinginfo()["staking_snapshot_current"], timeout=60)

    def stake_from(self, wallet, node, allowed):
        """Let the wallet's own staker make the next block from one of the allowed (txid, vout) outputs. Returns its hash.
        The block's only kernel must be one of them."""
        before = node.getblockcount()
        inputs = [{"txid": t, "vout": v} for t, v in sorted(allowed)]
        for _ in range(30000):
            result = wallet.checkkernel(inputs)
            if result["found"]:
                break
            self.bump()
        else:
            raise AssertionError("no kernel for any allowed output")
        kernel_time = result["kernel"]["time"]
        self.set_mt(kernel_time - 16)
        wallet.staking(True)
        try:
            self.set_mt(kernel_time)
            self.wait_until(lambda: node.getblockcount() > before, timeout=60)
        finally:
            wallet.staking(False)
        block_hash = node.getbestblockhash()
        coinstake = node.getblock(block_hash, 2)["tx"][1]
        assert_equal(len(coinstake["vin"]), 1)  # a quantum coinstake consumes exactly one output
        assert (coinstake["vin"][0]["txid"], coinstake["vin"][0]["vout"]) in allowed, coinstake["vin"][0]
        return block_hash

    def assert_no_wallet_block(self, node, wallet, outpoint, height):
        """A kernel exists for this output, yet the wallet's own staker makes no block: it is not available."""
        kernel_time = self.kernel_slot_for(wallet, outpoint)
        self.set_mt(kernel_time - 16)
        wallet.staking(True)
        try:
            self.set_mt(kernel_time)
            self.settle(wallet)
            for _ in range(8):
                self.bump()
                self.settle(wallet)
        finally:
            wallet.staking(False)
        assert_equal(node.getblockcount(), height)

    def run_test(self):
        n0, n1 = self.nodes
        default0 = n0.get_wallet_rpc(self.default_wallet_name)
        default1 = n1.get_wallet_rpc(self.default_wallet_name)
        default0.staking(False)
        default1.staking(False)
        self.set_initial_mt()
        pow0 = default0.getnewaddress("", "legacy")
        pow1 = default1.getnewaddress("", "legacy")
        quantum_miner0 = default0.getnewquantumaddress()["address"]
        quantum_miner1 = default1.getnewquantumaddress()["address"]

        self.log.info("Node 0: wallets with %d, %d, %d and %d quantum outputs", K_MAIN, K_SINGLE, K_LOCKED, K_SPEND)
        wq = self.build_wallet(n0, pow0, "wq", K_MAIN)
        w1 = self.build_wallet(n0, pow0, "w1", K_SINGLE)
        wl = self.build_wallet(n0, pow0, "wl", K_LOCKED)
        ws = self.build_wallet(n0, pow0, "ws", K_SPEND)
        self.pow_blocks(n0, G - n0.getblockcount(), pow0)
        q_main = self.migrate_all(n0, pow0, wq, K_MAIN)
        q_single = self.migrate_all(n0, pow0, w1, K_SINGLE)
        q_locked = self.migrate_all(n0, pow0, wl, K_LOCKED)
        q_spend = self.migrate_all(n0, pow0, ws, K_SPEND)

        self.log.info("Node 1 (-finalstakereserve=0): one wallet with %d quantum outputs", K_NEGATIVE)
        wn = self.build_wallet(n1, pow1, "wn", K_NEGATIVE)
        self.pow_blocks(n1, G - n1.getblockcount(), pow1)
        q_neg = self.migrate_all(n1, pow1, wn, K_NEGATIVE)

        # The tip is GUARD_START: the next block (candidate 83) has the reserve on and every output made so far is
        # mature at F.
        for node, pow_addr in ((n0, pow0), (n1, pow1)):
            self.pow_blocks(node, GUARD_START - node.getblockcount(), pow_addr)
            assert_equal(node.getblockcount(), GUARD_START)
            assert_equal(node.getquantumquasarinfo()["phase"], "migration")

        self.test_negative(n1, wn, q_neg, pow1, quantum_miner1)
        self.test_readiness_fields(wq, q_main)
        self.test_locked(wl, q_locked)
        self.test_spending(n0, ws, q_spend)
        main = self.test_main_window(n0, wq, w1, q_main, q_single, pow0)
        self.test_final_block_and_reorgs(n0, q_single, quantum_miner0, main)

    # The E2 experiment, with the reserve off: it exhausts the wallet, asserted.
    def test_negative(self, node, wallet, addresses, pow_addr, quantum_miner):
        self.log.info("Reserve off: the wallet stakes every output at 83..88 and nothing is left for F")
        info = self.reserve(wallet)
        assert_equal(info["enabled"], False)
        assert_equal(info["active"], False)
        assert_equal(info["reserved_count"], 0)
        outputs = self.quantum_outputs(wallet, addresses)
        assert_equal(len(outputs), K_NEGATIVE)
        remaining = {key(o) for o in outputs}
        for expected_height in range(GUARD_START + 1, GUARD_START + 1 + K_NEGATIVE):
            block = self.stake_from(wallet, node, remaining)
            assert_equal(node.getblock(block)["height"], expected_height)
            remaining.discard(key(node.getblock(block, 2)["tx"][1]["vin"][0]))
        assert_equal(len(remaining), 0)
        self.pow_blocks(node, M - node.getblockcount(), pow_addr)
        assert_equal(node.getblockcount(), M)
        readiness = wallet.getquantumstakereadiness()
        assert_equal(readiness["next_block"]["height"], F)
        assert_equal(readiness["next_block"]["eligible_outputs"], 0)  # every output is spent or too young at F
        assert_equal(readiness["next_block"]["stakeable_outputs"], 0)
        assert readiness["next_block"]["excluded"]["immature"]["count"] >= K_NEGATIVE  # the six coinstake outputs
        self.log.info("...and the wallet's own staker does not produce block F")
        wallet.staking(True)
        try:
            for _ in range(24):
                self.bump()
                self.settle(wallet)
        finally:
            wallet.staking(False)
        assert_equal(node.getblockcount(), M)
        assert_equal(wallet.getstakinginfo()["eligible"], False)
        self.pow_blocks(node, 1, quantum_miner)  # proof of work has to make F (a Final block pays a quantum address)
        assert_equal(node.getblockcount(), F)

    def test_readiness_fields(self, wallet, addresses):
        self.log.info("Readiness reports the guard, N, R, the reserve and what it holds")
        wq_info = self.reserve(wallet)
        for field in ("enabled", "active", "schedule_known", "guard_first_height", "final_height", "n", "target",
                      "reserved_count", "reserved_outpoints", "reserved_weight", "eligible_count", "eligible_weight",
                      "consumed_count", "shortfall", "wallet_locked", "exclusions"):
            assert field in wq_info, field
        for reason in ("immature", "locked", "below_minimum", "missing_keys", "no_effective_value", "other"):
            assert_equal(sorted(wq_info["exclusions"][reason].keys()), ["amount", "count"])
        assert_equal(wq_info["enabled"], True)
        assert_equal(wq_info["active"], True)
        assert_equal(wq_info["schedule_known"], True)
        assert_equal(wq_info["guard_first_height"], GUARD_START)
        assert_equal(wq_info["final_height"], F)
        assert_equal(wq_info["n"], K_MAIN)
        assert_equal(wq_info["target"], 3)  # min(32, (6 + 1) / 2)
        assert_equal(wq_info["reserved_count"], 3)
        assert_equal(len(wq_info["reserved_outpoints"]), 3)
        assert_equal(wq_info["eligible_count"], K_MAIN)
        assert_equal(wq_info["consumed_count"], 0)
        assert_equal(wq_info["shortfall"], 0)
        assert_equal(wq_info["wallet_locked"], False)
        reserved_weight = sum(Decimal(str(o["effective_value"])) for o in wq_info["reserved_outpoints"])
        assert_equal(Decimal(str(wq_info["reserved_weight"])), reserved_weight)
        assert Decimal(str(wq_info["eligible_weight"])) >= Decimal(str(wq_info["reserved_weight"])) > 0
        # largest effective value first
        values = [Decimal(str(o["effective_value"])) for o in wq_info["reserved_outpoints"]]
        assert_equal(values, sorted(values, reverse=True))
        # an encrypted or locked wallet is reported apart from a missing key: the wallet is not locked here
        assert_equal(wq_info["exclusions"]["missing_keys"]["count"], 0)

    def test_locked(self, wallet, addresses):
        self.log.info("A user-locked output is not a source and is never reserved")
        outputs = self.quantum_outputs(wallet, addresses)
        assert_equal(len(outputs), K_LOCKED)
        before = self.reserve(wallet)
        assert_equal(before["n"], K_LOCKED)
        assert_equal(before["target"], 2)
        locked = {"txid": outputs[0]["txid"], "vout": outputs[0]["vout"]}
        wallet.lockunspent(False, [locked])
        after = self.reserve(wallet)
        assert_equal(after["n"], K_LOCKED - 1)
        assert_equal(after["target"], 2)  # min(32, (3 + 1) / 2)
        assert_equal(after["eligible_count"], K_LOCKED - 1)
        assert_equal(after["exclusions"]["locked"]["count"], 1)
        assert key(locked) not in self.reserved_keys(wallet)
        wallet.lockunspent(True, [locked])
        assert_equal(self.reserve(wallet)["n"], K_LOCKED)

    def test_spending(self, node, wallet, addresses):
        self.log.info("Automatic coin selection skips the reserve; explicit coin control may spend it")
        outputs = {key(o): o for o in self.quantum_outputs(wallet, addresses)}
        assert_equal(len(outputs), K_SPEND)
        info = self.reserve(wallet)
        assert_equal(info["n"], K_SPEND)
        assert_equal(info["target"], 1)
        reserved = self.reserved_keys(wallet)
        assert_equal(len(reserved), 1)
        reserved_key = next(iter(reserved))
        free_key = next(k for k in outputs if k != reserved_key)
        reserved_value = Decimal(str(outputs[reserved_key]["amount"]))
        free_value = Decimal(str(outputs[free_key]["amount"]))
        destination = wallet.getnewquantumaddress()["address"]

        # Needs both outputs: the reserved one is not available to ordinary selection.
        assert_raises_rpc_error(-6, "Insufficient funds", wallet.sendtoaddress, destination, reserved_value + free_value - 1)
        # sendall sweeps what is available, which is the unreserved output only.
        swept = wallet.sendall(recipients=[destination], options={"add_to_wallet": False})
        spent = {(i["txid"], i["vout"]) for i in node.decoderawtransaction(swept["hex"])["vin"]}
        assert_equal(spent, {free_key})
        # The UTXO optimiser chooses its inputs itself: naming the reserved output's address is no authorization to
        # spend it, and nothing is split from there. The same call for the free output's address, and for the whole
        # wallet, uses the unreserved output only.
        split = free_value / 4
        assert_raises_rpc_error(-6, "No available coins to optimize", wallet.optimizeutxoset, destination, split, False, outputs[reserved_key]["address"])
        for from_address in (outputs[free_key]["address"], None):
            args = [destination, split, False] + ([from_address] if from_address else [])
            optimized = wallet.optimizeutxoset(*args)
            spent = {(i["txid"], i["vout"]) for i in node.decoderawtransaction(optimized["tx"])["vin"]}
            assert_equal(spent, {free_key})
        # A payment that one output covers is funded from the unreserved one.
        sent = wallet.send(outputs=[{destination: free_value / 2}], options={"change_address": destination})
        spent = {(i["txid"], i["vout"]) for i in node.decoderawtransaction(wallet.gettransaction(sent["txid"])["hex"])["vin"]}
        assert_equal(spent, {free_key})
        # Explicit coin control may spend the reserve; the readiness report then shows the reduction.
        explicit = wallet.send(outputs=[{destination: reserved_value / 2}],
                               options={"inputs": [{"txid": reserved_key[0], "vout": reserved_key[1]}], "add_inputs": False,
                                        "change_address": destination})
        assert explicit["complete"]
        spent = {(i["txid"], i["vout"]) for i in node.decoderawtransaction(wallet.gettransaction(explicit["txid"])["hex"])["vin"]}
        assert_equal(spent, {reserved_key})
        after = self.reserve(wallet)
        # Both outputs are now spent by unconfirmed transactions: nothing qualifying is left until they confirm.
        assert_equal(after["reserved_count"], 0)
        assert reserved_key not in self.reserved_keys(wallet)
        assert_equal(after["n"], 0)
        # The two transactions stay in the mempool and go into the next block the chain makes.

    def test_main_window(self, node, wallet, single, q_main, q_single, pow_addr):
        self.log.info("Reserve on: the wallet stakes only what is not reserved")
        outputs = {key(o): o for o in self.quantum_outputs(wallet, q_main)}
        assert_equal(len(outputs), K_MAIN)
        reserved = self.reserved_keys(wallet)
        assert_equal(len(reserved), 3)
        free = [k for k in outputs if k not in reserved]
        assert_equal(len(free), 3)
        before = self.reserve(wallet)
        reserved_list = [(o["txid"], o["vout"]) for o in before["reserved_outpoints"]]

        self.log.info("N = 1: the sole output is the reserve")
        single_info = self.reserve(single)
        assert_equal(single_info["n"], K_SINGLE)
        assert_equal(single_info["target"], 1)
        assert_equal(single_info["reserved_count"], 1)
        sole = self.quantum_outputs(single, q_single)
        assert_equal(len(sole), 1)
        sole_outpoint = {"txid": sole[0]["txid"], "vout": sole[0]["vout"]}
        assert_equal(self.reserved_keys(single), {key(sole_outpoint)})
        # Readiness applies the reserve to the block the staker makes next: the sole output is an eligible output of the
        # scan (and counted for F), yet it is not stakeable now and takes nothing from the reserve balance.
        readiness = single.getquantumstakereadiness()
        now, at_final = readiness["next_block"], readiness["at_final"]
        assert_equal(now["height"], GUARD_START + 1)
        assert_equal(now["eligible_outputs"], 1)
        assert_equal(now["reserve_withheld_outputs"], 1)
        assert_equal(now["reserve_withheld_nominal"], now["eligible_nominal"])
        assert_equal(now["candidate_total"], 0)
        assert_equal(now["allowed_balance"], 0)
        assert_equal(now["stakeable_outputs"], 0)
        assert_equal(now["stakeable_effective"], 0)
        assert_equal(now["largest_kernel"], 0)
        assert_equal(at_final["height"], F)
        assert_equal(at_final["eligible_outputs"], 1)
        assert_equal(at_final["reserve_withheld_outputs"], 0)
        assert_equal(at_final["stakeable_outputs"], 1)
        assert_equal(readiness["final_stake_reserve"]["eligible_count"], 1)
        self.assert_no_wallet_block(node, single, sole_outpoint, GUARD_START)
        # The staking weight shown is what the constructor can use: nothing, while the only output is withheld.
        self.wait_until(lambda: single.getstakinginfo()["weight"] == 0, timeout=60)

        main_now = wallet.getquantumstakereadiness()["next_block"]
        assert_equal(main_now["eligible_outputs"], K_MAIN)
        assert_equal(main_now["reserve_withheld_outputs"], 3)
        assert_equal(main_now["stakeable_outputs"], 3)
        assert_equal(Decimal(str(main_now["candidate_total"])) + Decimal(str(main_now["reserve_withheld_nominal"])),
                     Decimal(str(main_now["eligible_nominal"])))
        self.log.info("Three stakes from the unreserved outputs at 83, 84 and 85")
        stake_hashes = []
        remaining = set(free)
        for expected_height in (83, 84, 85):
            block_hash = self.stake_from(wallet, node, remaining)
            assert_equal(node.getblock(block_hash)["height"], expected_height)
            coinstake = node.getblock(block_hash, 2)["tx"][1]
            # A quantum coinstake consumes exactly one output: it cannot take a second reserve-eligible one.
            assert_equal(len(coinstake["vin"]), 1)
            outpoint_key = key(coinstake["vin"][0])
            assert outpoint_key not in reserved
            remaining.discard(outpoint_key)
            stake_hashes.append(block_hash)
            now = self.reserve(wallet)
            # What the wallet consumed stays in N, so the target and the reserve do not move.
            assert_equal(now["n"], K_MAIN)
            assert_equal(now["target"], 3)
            assert_equal([(o["txid"], o["vout"]) for o in now["reserved_outpoints"]], reserved_list)
            assert_equal(now["consumed_count"], expected_height - 82)
            assert_equal(now["eligible_count"], K_MAIN - (expected_height - 82))
        self.log.info("Nothing else can stake: the reserved outputs have kernels but the staker leaves them")
        self.assert_no_wallet_block(node, wallet, {"txid": reserved_list[0][0], "vout": reserved_list[0][1]}, 85)

        self.log.info("Restart inside the window: the same reserve")
        self.pow_blocks(node, 3, pow_addr)  # 86..88
        before_restart = self.reserve(wallet)
        self.restart_node(0, extra_args=LIFECYCLE_ARGS + [f"-mocktime={self.mt}"])
        for name in ("wq", "w1", "wl", "ws"):
            if name not in node.listwallets():
                node.loadwallet(name)
        for wallet_name in ("wq", "w1"):
            node.get_wallet_rpc(wallet_name).staking(False)
        wallet = node.get_wallet_rpc("wq")
        single = node.get_wallet_rpc("w1")
        self.set_mt(self.mt)
        after_restart = self.reserve(wallet)
        assert_equal(after_restart["reserved_outpoints"], before_restart["reserved_outpoints"])
        assert_equal(after_restart["n"], before_restart["n"])
        assert_equal(after_restart["consumed_count"], 3)

        self.pow_blocks(node, M - node.getblockcount(), pow_addr)
        assert_equal(node.getblockcount(), M)
        return {"wallet": wallet, "single": single, "reserved": reserved_list, "stake_hashes": stake_hashes}

    def test_final_block_and_reorgs(self, node, q_single, quantum_miner, main):
        # The node was restarted: the wallet handles of the restarted node.
        wallet = main["wallet"]
        single = main["single"]
        reserved = main["reserved"]
        self.log.info("At the tip M the guard is released for candidate F")
        released = self.reserve(wallet)
        assert_equal(released["active"], False)
        assert_equal(released["enabled"], True)
        assert_equal(released["reserved_count"], 0)
        assert_equal(wallet.getquantumstakereadiness()["next_block"]["height"], F)
        assert_equal(wallet.getquantumstakereadiness()["next_block"]["eligible_outputs"], 3)  # the reserve, mature at F
        # Released: nothing is held back, yet the eligibility at F is reported accurately rather than zeroed.
        assert_equal(wallet.getquantumstakereadiness()["next_block"]["reserve_withheld_outputs"], 0)
        assert_equal(wallet.getquantumstakereadiness()["next_block"]["stakeable_outputs"], 3)
        assert_equal(released["eligible_count"], 3)
        assert released["eligible_weight"] > 0
        assert_equal(released["consumed_count"], 3)
        assert_equal(released["n"], K_MAIN)
        assert_equal(released["shortfall"], 0)

        self.log.info("Block F is made by the wallet's own staker from a reserved output")
        f_hash = self.stake_from(wallet, node, set(reserved))
        block = node.getblock(f_hash, 2)
        assert_equal(block["height"], F)
        assert_equal(len(block["tx"][1]["vin"]), 1)
        first = key(block["tx"][1]["vin"][0])
        assert first in reserved

        self.log.info("A reorganisation across F: the wallet makes F again from a reserved output")
        node.invalidateblock(f_hash)
        assert_equal(node.getblockcount(), M)
        self.bump()
        f2_hash = self.stake_from(wallet, node, set(reserved))
        assert f2_hash != f_hash
        assert key(node.getblock(f2_hash, 2)["tx"][1]["vin"][0]) in reserved
        assert_equal(self.reserve(wallet)["active"], False)

        self.log.info("N = 1: the withheld output stakes at F + 1")
        sole = self.quantum_outputs(single, q_single)[0]
        f3_hash = self.stake_outpoint(single, node, {"txid": sole["txid"], "vout": sole["vout"]})
        assert_equal(node.getblock(f3_hash)["height"], F + 1)

        self.log.info("A reorganisation into the window recomputes the reserve from the chain")
        coinstake_85 = main["stake_hashes"][2]
        node.invalidateblock(coinstake_85)
        assert_equal(node.getblockcount(), 84)
        node.syncwithvalidationinterfacequeue()
        window = self.reserve(wallet)
        assert_equal(window["active"], True)
        assert_equal(window["consumed_count"], 2)  # the stake at 85 is no longer on the chain
        assert_equal(window["eligible_count"], K_MAIN - 2)
        assert_equal(window["n"], K_MAIN)
        assert_equal([(o["txid"], o["vout"]) for o in window["reserved_outpoints"]], reserved)
        node.reconsiderblock(coinstake_85)
        assert_equal(node.getblockcount(), F + 1)
        node.syncwithvalidationinterfacequeue()
        assert_equal(self.reserve(wallet)["consumed_count"], 0)  # the guard is over: the reserve is released
        assert_equal(self.reserve(wallet)["active"], False)


if __name__ == '__main__':
    FinalStakeReserveTest().main()
