#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""The final stake reserve: quantum outputs held back in the last maturity period of Migration.

Regtest: Gold Rush ends at G=61, Migration ends at M=91 (first Final block F=92), maturity 10. A quantum coinstake
made at height h can stake again only from h + 10, so a wallet that stakes all of its quantum outputs at heights
83..91 has nothing mature left at F. The wallet therefore keeps R = min(32, ceil(N / 2)) of its N qualifying outputs
(N >= 2) out of the staker and out of every automatic spend for the candidate heights F - maturity = 82 .. M = 91, and
releases them for F. A wallet with exactly one qualifying output (N = 1) holds it or releases it by a fixed hash of its
outpoint (single_output_rule "held" or "released"): the test makes singleton wallets of both kinds.

Node 1 runs with -finalstakereserve=0 and is the E2 experiment: it stakes every one of its outputs from height 83, and
the test ASSERTS that nothing is left at the tip M and that the wallet's own staker does not produce block F.
Node 0 runs with the default (the reserve on) and the same history:

 * the positive case: block F is produced by the wallet's own staker from a reserved output;
 * N = 1, held: the sole output is withheld for the whole guard and stakes at F + 1; N = 1, released: it stakes at
   F - maturity and at F - maturity + 1 like any unreserved output (and, staked at F - maturity, its return that is
   mature at F makes N = 2 and is itself reserved); the rule is the same after a restart and a reorganisation;
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
    single_output_reserve_bit,
)

GUARD_START = F - MATURITY  # 82, the first candidate height with the reserve on
K_MAIN = 6
K_SINGLE = 1
K_CANDIDATES = 20  # singleton candidates: three released and two held ones are needed, and the parity is by outpoint
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

        self.log.info("Node 0: wallets with %d, %d and %d quantum outputs, and %d candidates for one output each", K_MAIN, K_LOCKED, K_SPEND, K_CANDIDATES)
        wq = self.build_wallet(n0, pow0, "wq", K_MAIN)
        wl = self.build_wallet(n0, pow0, "wl", K_LOCKED)
        ws = self.build_wallet(n0, pow0, "ws", K_SPEND)
        candidate_names = [f"c{i}" for i in range(K_CANDIDATES)]
        candidates = [self.build_wallet(n0, pow0, name, K_SINGLE) for name in candidate_names]
        self.pow_blocks(n0, G - n0.getblockcount(), pow0)
        # The singleton candidates are migrated first: a released one stakes at F - maturity and needs its output to be
        # mature by then.
        singles = self.choose_singletons(n0, pow0, candidates, candidate_names)
        q_main = self.migrate_all(n0, pow0, wq, K_MAIN)
        q_locked = self.migrate_all(n0, pow0, wl, K_LOCKED)
        q_spend = self.migrate_all(n0, pow0, ws, K_SPEND)

        self.log.info("Node 1 (-finalstakereserve=0): one wallet with %d quantum outputs", K_NEGATIVE)
        wn = self.build_wallet(n1, pow1, "wn", K_NEGATIVE)
        self.pow_blocks(n1, G - n1.getblockcount(), pow1)
        q_neg = self.migrate_all(n1, pow1, wn, K_NEGATIVE)

        # The tip is GUARD_START: the next block (candidate 83) has the reserve on and every output made so far is
        # mature at F.
        # Node 0 stops one block earlier: the released singleton wallets stake at F - maturity and at F - maturity + 1.
        for node, pow_addr, tip in ((n0, pow0, GUARD_START - 1), (n1, pow1, GUARD_START)):
            self.pow_blocks(node, tip - node.getblockcount(), pow_addr)
            assert_equal(node.getblockcount(), tip)
            assert_equal(node.getquantumquasarinfo()["phase"], "migration")

        self.test_negative(n1, wn, q_neg, pow1, quantum_miner1)
        self.test_released_singletons(n0, singles["released"][0], singles["released"][1])
        assert_equal(n0.getblockcount(), GUARD_START + 1)
        self.test_readiness_fields(wq, q_main)
        self.test_locked(wl, q_locked)
        self.test_spending(n0, ws, q_spend)
        self.test_held_singleton_spending(n0, singles["held"][1])
        main = self.test_main_window(n0, wq, q_main, singles, pow0)
        self.test_final_block_and_reorgs(n0, quantum_miner0, main)

    def choose_singletons(self, node, pow_addr, wallets, names):
        """Migrate the one coin of each candidate wallet, and keep two wallets whose output the singleton rule holds back
        and three whose output it releases. The rule is by outpoint, so the parity is computed here and checked
        against what the node reports."""
        found = self.migrate_singleton_candidates(node, pow_addr, wallets)
        held, released = [], []
        for name, (wallet, address, outpoint) in zip(names, found):
            is_held = single_output_reserve_bit(outpoint["txid"], outpoint["vout"])
            single = {"name": name, "wallet": wallet, "address": address, "outpoint": outpoint}
            (held if is_held else released).append(single)
            info = self.reserve(wallet)
            assert_equal(info["n"], 1)
            assert_equal(info["single_output_rule"], "held" if is_held else "released")
            assert_equal(info["target"], 1 if is_held else 0)
        self.log.info("Singleton candidates: %d held, %d released", len(held), len(released))
        assert len(held) >= 2 and len(released) >= 3, "the candidates have too few outputs of one parity: %d held, %d released" % (len(held), len(released))
        return {"held": held[:2], "released": released[:3]}

    def test_released_singletons(self, node, first, second):
        """A released singleton stakes like any unreserved output: at F - maturity its return is mature at F and joins N,
        at F - maturity + 1 it is not."""
        self.log.info("N = 1, released: stakes at F - maturity (82); its return, mature at F, makes N = 2 and is reserved")
        assert_equal(node.getblockcount(), GUARD_START - 1)
        wallet, outpoint = first["wallet"], first["outpoint"]
        info = self.reserve(wallet)
        assert_equal((info["active"], info["n"], info["target"], info["reserved_count"], info["shortfall"]), (True, 1, 0, 0, 0))
        assert_equal(info["single_output_rule"], "released")
        now = wallet.getquantumstakereadiness()["next_block"]
        assert_equal((now["height"], now["eligible_outputs"], now["reserve_withheld_outputs"], now["stakeable_outputs"]), (GUARD_START, 1, 0, 1))
        block_hash = self.stake_from(wallet, node, {key(outpoint)})
        assert_equal(node.getblock(block_hash)["height"], GUARD_START)
        coinstake = node.getblock(block_hash, 2)["tx"][1]
        after = self.reserve(wallet)
        # The coinstake's own outputs are mature at F: they are the unspent sources, the consumed output is the other one.
        returned = after["eligible_count"]
        assert returned >= 1
        assert_equal((after["consumed_count"], after["n"], after["shortfall"]), (1, returned + 1, 0))
        assert_equal((after["target"], after["reserved_count"]), ((returned + 2) // 2, (returned + 2) // 2))
        assert "single_output_rule" not in after
        assert_equal({o["txid"] for o in after["reserved_outpoints"]}, {coinstake["txid"]})

        self.log.info("N = 1, released: stakes at F - maturity + 1 (83); its return is too young at F, so N stays 1 and nothing is asked")
        wallet, outpoint = second["wallet"], second["outpoint"]
        info = self.reserve(wallet)
        assert_equal((info["active"], info["n"], info["target"], info["reserved_count"]), (True, 1, 0, 0))
        assert_equal(info["single_output_rule"], "released")
        block_hash = self.stake_from(wallet, node, {key(outpoint)})
        assert_equal(node.getblock(block_hash)["height"], GUARD_START + 1)
        after = self.reserve(wallet)
        assert_equal((after["consumed_count"], after["n"], after["target"], after["reserved_count"], after["eligible_count"], after["shortfall"]), (1, 1, 0, 0, 0, 0))
        assert_equal(after["single_output_rule"], "released")

    def test_held_singleton_spending(self, node, single):
        """A held singleton is left alone by every automatic spend; explicit coin control may take it, and the result says so."""
        self.log.info("N = 1, held: automatic selection leaves it alone, explicit coin control may spend it")
        wallet = single["wallet"]
        info = self.reserve(wallet)
        assert_equal((info["n"], info["target"], info["reserved_count"]), (1, 1, 1))
        assert_equal(info["single_output_rule"], "held")
        outpoint = single["outpoint"]
        value = Decimal(str(self.quantum_outputs(wallet, [single["address"]])[0]["amount"]))
        destination = wallet.getnewquantumaddress()["address"]
        assert_raises_rpc_error(-6, "Insufficient funds", wallet.sendtoaddress, destination, value / 2)
        assert_raises_rpc_error(None, None, wallet.sendall, recipients=[destination], options={"add_to_wallet": False})
        explicit = wallet.send(outputs=[{destination: value / 2}],
                               options={"inputs": [outpoint], "add_inputs": False, "change_address": destination})
        assert explicit["complete"]
        report = explicit["final_stake_reserve_spent"]
        assert_equal([(o["txid"], o["vout"]) for o in report["outpoints"]], [key(outpoint)])
        assert_equal((report["reserved_before"], report["reserved_after"], report["eligible_before"], report["eligible_after"]), (1, 0, 1, 0))
        assert_equal(self.reserve(wallet)["n"], 0)

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
        # Explicit coin control may spend the reserve; the result reports what it consumed and the readiness report
        # then shows the reduction.
        before_explicit = self.reserve(wallet)
        explicit = wallet.send(outputs=[{destination: reserved_value / 2}],
                               options={"inputs": [{"txid": reserved_key[0], "vout": reserved_key[1]}], "add_inputs": False,
                                        "change_address": destination})
        assert explicit["complete"]
        spent = {(i["txid"], i["vout"]) for i in node.decoderawtransaction(wallet.gettransaction(explicit["txid"])["hex"])["vin"]}
        assert_equal(spent, {reserved_key})
        after = self.reserve(wallet)
        # With the other output spent, this one is the wallet's only source: the singleton rule says whether it is still
        # in the reserve, so whether this spend takes from the reserve depends on its outpoint (the held case is also
        # tested with a wallet of its own, test_held_singleton_spending).
        assert_equal(before_explicit["n"], 1)
        still_reserved = single_output_reserve_bit(*reserved_key)
        assert_equal(before_explicit["single_output_rule"], "held" if still_reserved else "released")
        assert_equal(before_explicit["reserved_count"], 1 if still_reserved else 0)
        if still_reserved:
            report = explicit["final_stake_reserve_spent"]
            assert_equal([(o["txid"], o["vout"]) for o in report["outpoints"]], [reserved_key])
            assert_equal(report["outpoints"][0]["effective_value"], report["effective_value"])
            assert report["effective_value"] > 0
            assert_equal(report["reserved_before"], before_explicit["reserved_count"])
            assert_equal(report["reserved_after"], after["reserved_count"])
            assert_equal(report["eligible_before"], before_explicit["eligible_count"])
            assert_equal(report["eligible_after"], after["eligible_count"])
            assert_equal(report["eligible_weight_before"], before_explicit["eligible_weight"])
            assert_equal(report["eligible_weight_after"], after["eligible_weight"])
            assert report["eligible_after"] < report["eligible_before"]
            assert report["eligible_weight_after"] < report["eligible_weight_before"]
        else:
            assert "final_stake_reserve_spent" not in explicit  # a released output is spent like any other
        # A payment that spends no reserved output reports nothing of the kind.
        assert "final_stake_reserve_spent" not in sent
        # Both outputs are now spent by unconfirmed transactions: nothing qualifying is left until they confirm.
        assert_equal(after["reserved_count"], 0)
        assert reserved_key not in self.reserved_keys(wallet)
        assert_equal(after["n"], 0)
        # The two transactions stay in the mempool and go into the next block the chain makes.

    def test_main_window(self, node, wallet, q_main, singles, pow_addr):
        self.log.info("Reserve on: the wallet stakes only what is not reserved")
        base = node.getblockcount()  # the two released singletons staked at 82 and 83
        assert_equal(base, GUARD_START + 1)
        held = singles["held"][0]
        single = held["wallet"]
        outputs = {key(o): o for o in self.quantum_outputs(wallet, q_main)}
        assert_equal(len(outputs), K_MAIN)
        reserved = self.reserved_keys(wallet)
        assert_equal(len(reserved), 3)
        free = [k for k in outputs if k not in reserved]
        assert_equal(len(free), 3)
        before = self.reserve(wallet)
        reserved_list = [(o["txid"], o["vout"]) for o in before["reserved_outpoints"]]

        self.log.info("N = 1, held: the sole output is the reserve")
        single_info = self.reserve(single)
        assert_equal(single_info["n"], K_SINGLE)
        assert_equal(single_info["target"], 1)
        assert_equal(single_info["single_output_rule"], "held")
        assert_equal(single_info["reserved_count"], 1)
        sole = self.quantum_outputs(single, [held["address"]])
        assert_equal(len(sole), 1)
        sole_outpoint = {"txid": sole[0]["txid"], "vout": sole[0]["vout"]}
        assert_equal(sole_outpoint, held["outpoint"])
        assert_equal(self.reserved_keys(single), {key(sole_outpoint)})
        # Readiness applies the reserve to the block the staker makes next: the sole output is an eligible output of the
        # scan (and counted for F), yet it is not stakeable now and takes nothing from the reserve balance.
        readiness = single.getquantumstakereadiness()
        now, at_final = readiness["next_block"], readiness["at_final"]
        assert_equal(now["height"], base + 1)
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
        self.assert_no_wallet_block(node, single, sole_outpoint, base)
        # The staking weight shown is what the constructor can use: nothing, while the only output is withheld.
        self.wait_until(lambda: single.getstakinginfo()["weight"] == 0, timeout=60)

        main_now = wallet.getquantumstakereadiness()["next_block"]
        assert_equal(main_now["eligible_outputs"], K_MAIN)
        assert_equal(main_now["reserve_withheld_outputs"], 3)
        assert_equal(main_now["stakeable_outputs"], 3)
        assert_equal(Decimal(str(main_now["candidate_total"])) + Decimal(str(main_now["reserve_withheld_nominal"])),
                     Decimal(str(main_now["eligible_nominal"])))
        self.log.info("Three stakes from the unreserved outputs, one block each after the singletons' blocks")
        stake_hashes = []
        remaining = set(free)
        for expected_height in (base + 1, base + 2, base + 3):
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
            assert_equal(now["consumed_count"], expected_height - base)
            assert_equal(now["eligible_count"], K_MAIN - (expected_height - base))
        self.log.info("Nothing else can stake: the reserved outputs have kernels but the staker leaves them")
        self.assert_no_wallet_block(node, wallet, {"txid": reserved_list[0][0], "vout": reserved_list[0][1]}, base + 3)

        self.log.info("Restart inside the window: the same reserve")
        self.pow_blocks(node, 3, pow_addr)
        before_restart = self.reserve(wallet)
        # The singleton wallets: the rule gives the same answer for the same outpoint after a restart.
        singleton_names = [held["name"], singles["released"][2]["name"]]
        singleton_before = {name: self.reserve(node.get_wallet_rpc(name)) for name in singleton_names}
        assert_equal(singleton_before[held["name"]]["single_output_rule"], "held")
        assert_equal(singleton_before[singles["released"][2]["name"]]["single_output_rule"], "released")
        self.restart_node(0, extra_args=LIFECYCLE_ARGS + [f"-mocktime={self.mt}"])
        for name in ["wq", "wl", "ws"] + singleton_names:
            if name not in node.listwallets():
                node.loadwallet(name)
        for wallet_name in ["wq"] + singleton_names:
            node.get_wallet_rpc(wallet_name).staking(False)
        wallet = node.get_wallet_rpc("wq")
        single = node.get_wallet_rpc(held["name"])
        self.set_mt(self.mt)
        after_restart = self.reserve(wallet)
        assert_equal(after_restart["reserved_outpoints"], before_restart["reserved_outpoints"])
        assert_equal(after_restart["n"], before_restart["n"])
        assert_equal(after_restart["consumed_count"], 3)
        for name in singleton_names:
            again = self.reserve(node.get_wallet_rpc(name))
            for field in ("single_output_rule", "n", "target", "reserved_count", "reserved_outpoints"):
                assert_equal(again[field], singleton_before[name][field])

        self.pow_blocks(node, M - node.getblockcount(), pow_addr)
        assert_equal(node.getblockcount(), M)
        return {"wallet": wallet, "single": single, "reserved": reserved_list, "stake_hashes": stake_hashes,
                "base": base, "singleton_names": singleton_names, "singleton_before": singleton_before}

    def test_final_block_and_reorgs(self, node, quantum_miner, main):
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
        sole = single.listunspent(1, 9999999)[0]
        f3_hash = self.stake_outpoint(single, node, {"txid": sole["txid"], "vout": sole["vout"]})
        assert_equal(node.getblock(f3_hash)["height"], F + 1)

        self.log.info("A reorganisation into the window recomputes the reserve from the chain")
        coinstake_last = main["stake_hashes"][2]
        node.invalidateblock(coinstake_last)
        assert_equal(node.getblockcount(), main["base"] + 2)
        node.syncwithvalidationinterfacequeue()
        window = self.reserve(wallet)
        assert_equal(window["active"], True)
        assert_equal(window["consumed_count"], 2)  # the stake at 85 is no longer on the chain
        assert_equal(window["eligible_count"], K_MAIN - 2)
        assert_equal(window["n"], K_MAIN)
        assert_equal([(o["txid"], o["vout"]) for o in window["reserved_outpoints"]], reserved)
        # The singleton wallets are not touched by it: the same outpoint gives the same answer.
        for name in main["singleton_names"]:
            again = self.reserve(node.get_wallet_rpc(name))
            for field in ("single_output_rule", "n", "target", "reserved_count", "reserved_outpoints"):
                assert_equal(again[field], main["singleton_before"][name][field])
        node.reconsiderblock(coinstake_last)
        assert_equal(node.getblockcount(), F + 1)
        node.syncwithvalidationinterfacequeue()
        assert_equal(self.reserve(wallet)["consumed_count"], 0)  # the guard is over: the reserve is released
        assert_equal(self.reserve(wallet)["active"], False)


if __name__ == '__main__':
    FinalStakeReserveTest().main()
