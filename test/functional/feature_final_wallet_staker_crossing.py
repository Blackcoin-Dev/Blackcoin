#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Wallet stakers alone carry the chain across the whole maturity cycle before and after the first Final block.

Regtest: Gold Rush ends at G=61, Migration ends at M=91 (first Final block F=92), maturity 10. Four producer nodes
each hold wallets with quantum outputs migrated long before. The setup (proof of work, funding, migration) ends at
height F - maturity - 2 = 80. From there to F + maturity + 2 = 104 NO block is generated and no coinstake is built by
hand: every block is made by the staker of one producer wallet, producers taking turns, with the final stake reserve
on (the default). Checks:

 * the guard is on for the candidate heights 82..91 on every producer and each stake there comes from an output that
   is not reserved;
 * one producer is restarted at the tip M and its readiness for F is unchanged;
 * the first Final block F is made by a wallet from an output that was reserved a block earlier;
 * a reorganisation across F: the network splits at M, both sides stake their own F, and the side with fewer
   blocks drops its F for the other side's;
 * half the producers are lost (stopped for good) and the other half carry the chain through F + maturity + 2;
 * every block of the span is proof of stake.

Two populations (the same checks):

 * default: one wallet per node with eight quantum outputs (N = 8, R = 4);
 * --singleton-population: many wallets with ONE quantum output each (N = 1). The singleton rule then decides by
   outpoint whether an output is held back for F ("held") or free to stake before it ("released"). The fixture counts
   its parities and maturities and asserts them: each candidate pre-F block (the heights 81..M, eleven of them) is made
   from a fresh released output, because the return of an output staked at h is not mature before h + maturity, and
   held outputs have to be there at F. No proof of work follows the setup, and no wallet holds a legacy coin.
"""
from decimal import Decimal

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal
from transition_t_final_util import (
    F,
    G,
    LIFECYCLE_ARGS,
    M,
    MATURITY,
    TransitionTFinalTestBase,
    single_output_reserve_bit,
)

SETUP_END = F - MATURITY - 2  # 80
CROSSING_END = F + MATURITY + 2  # 104
GUARD_START = F - MATURITY
PRODUCERS = 4
OUTPUTS_PER_PRODUCER = 8
WALLET = "producer"
# The singleton population: wallets per node, and what the fixture must hold. Every candidate block before F (the heights
# SETUP_END + 1 .. M, one per height) needs its own released output, and each side of the split needs a held one at F.
SINGLETON_WALLETS_PER_NODE = 13
RELEASED_PER_NODE = 7
HELD_PER_NODE = 6
PRE_F_BLOCKS = M - SETUP_END  # 11
MIN_HELD_PER_SIDE = 2


def key(outpoint):
    return (outpoint["txid"], outpoint["vout"])


class FinalWalletStakerCrossingTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def add_options(self, parser):
        super().add_options(parser)
        parser.add_argument("--singleton-population", dest="singleton_population", default=False, action="store_true",
                            help="producers are many wallets with one quantum output each (the singleton rule decides which are reserved)")

    def set_test_params(self):
        self.num_nodes = PRODUCERS
        self.setup_clean_chain = True
        self.extra_args = [LIFECYCLE_ARGS] * PRODUCERS

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def set_mt(self, t):
        self.mt = t
        for node in reversed(self.nodes):
            if node.running:
                node.setmocktime(t)

    # A producer is (node index, wallet name).
    def wallet_of(self, producer):
        index, name = producer
        return self.nodes[index].get_wallet_rpc(name)

    def reserve_keys(self, producer):
        info = self.wallet_of(producer).getquantumstakereadiness()["final_stake_reserve"]
        return info, {(o["txid"], o["vout"]) for o in info["reserved_outpoints"]}

    def allowed_outputs(self, producer, only=None):
        """The outputs of `producer` its staker may use now: mature for the next block (the wallet stakes an output from
        the block it matures in, `confirmations >= MATURITY`) and not in the final stake reserve. `only` narrows them."""
        wallet = self.wallet_of(producer)
        _, reserved = self.reserve_keys(producer)
        return reserved, [{"txid": u["txid"], "vout": u["vout"]} for u in wallet.listunspent(1, 9999999)
                          if u["spendable"] and u["amount"] > 0 and u["confirmations"] >= MATURITY and key(u) not in reserved
                          and (only is None or key(u) in only)]

    def producers_in(self, group):
        return [p for p in self.producers if p[0] in group]

    def producer_blocks(self, group, only=None):
        """The producers of `group` take turns by height: one block each time, made by the wallet's own staker. The
        reserve is chosen by transaction hash, so which outputs a producer may use varies from run to run: when the
        producer whose turn it is has no output it may use (all its mature outputs are reserved), the next one in the
        rotation makes the block. Every block is still made by a wallet staker. A singleton population tries the
        wallets whose output is released first, so that the held ones are still there at F."""
        height = self.nodes[group[0]].getblockcount() + 1
        members = self.producers_in(group)
        tiers = [members]
        if self.options.singleton_population:
            tiers = [[p for p in members if not self.held[p]], [p for p in members if self.held[p]]]
        for tier in tiers:
            for offset in range(len(tier)):
                producer = tier[(height + offset) % len(tier)]
                if self.allowed_outputs(producer, only)[1]:
                    return producer
        raise AssertionError("no producer of the group has an output it may stake")

    def stake_next(self, producer, group, only=None):
        """The staker of `producer` makes the next block from an output it is allowed to use now. Returns the block
        hash; the group's nodes are synced."""
        node = self.nodes[producer[0]]
        wallet = self.wallet_of(producer)
        reserved, allowed = self.allowed_outputs(producer, only)
        assert allowed, "producer %s has no output it may stake" % (producer,)
        before = node.getblockcount()
        for _ in range(60000):
            result = wallet.checkkernel(allowed)
            if result["found"]:
                break
            self.bump()
        else:
            raise AssertionError("no kernel for producer %s" % (producer,))
        kernel_time = result["kernel"]["time"]
        self.set_mt(kernel_time - 16)
        wallet.staking(True)
        try:
            self.set_mt(kernel_time)
            self.wait_until(lambda: node.getblockcount() > before, timeout=60)
        finally:
            wallet.staking(False)
        block_hash = node.getbestblockhash()
        block = node.getblock(block_hash, 2)
        assert "proof-of-stake" in block["flags"]
        coinstake = block["tx"][1]
        assert_equal(len(coinstake["vin"]), 1)  # a quantum coinstake consumes exactly one output
        kernel = key(coinstake["vin"][0])
        assert kernel not in reserved, "the staker used a reserved output"
        self.kernels.append((node.getblock(block_hash)["height"], kernel, coinstake["txid"]))
        self.sync_blocks([self.nodes[i] for i in group])
        return block_hash

    def build_producers(self, pow_addr, pow_addr_of):
        if self.options.singleton_population:
            self.build_singleton_producers(pow_addr, pow_addr_of)
            return
        self.log.info("Setup (proof of work is allowed here): %d producers with %d migrated quantum outputs each",
                      PRODUCERS, OUTPUTS_PER_PRODUCER)
        self.producers = [(i, WALLET) for i in range(PRODUCERS)]
        for producer in self.producers:
            self.nodes[producer[0]].createwallet(WALLET, descriptors=self.options.descriptors)
            self.wallet_of(producer).staking(False)
        for _ in range(OUTPUTS_PER_PRODUCER):
            for producer in self.producers:
                self.generatetoaddress(self.nodes[0], 1, self.wallet_of(producer).getnewaddress("", "legacy"), sync_fun=self.sync_blocks)
                self.bump()
        self.pow_blocks(self.nodes[0], G - self.nodes[0].getblockcount(), pow_addr)
        self.sync_blocks()
        # Each producer migrates two coins and mines the block that holds them on its own node.
        for _ in range(OUTPUTS_PER_PRODUCER // 2):
            for producer in self.producers:
                wallet = self.wallet_of(producer)
                for _ in range(2):
                    wallet.migratetoquantum({"existing_address": wallet.getnewquantumaddress()["address"], "max_inputs": 1})
                self.generatetoaddress(self.nodes[producer[0]], 1, pow_addr_of[producer[0]], sync_fun=self.sync_blocks)
                self.bump()
        self.pow_blocks(self.nodes[0], SETUP_END - self.nodes[0].getblockcount(), pow_addr)
        self.sync_blocks()
        assert_equal(self.nodes[0].getblockcount(), SETUP_END)
        for producer in self.producers:
            assert_equal(len([u for u in self.wallet_of(producer).listunspent(1, 9999999) if u["amount"] > 0]), OUTPUTS_PER_PRODUCER)
        self.held = {p: False for p in self.producers}

    def build_singleton_producers(self, pow_addr, pow_addr_of):
        count = PRODUCERS * SINGLETON_WALLETS_PER_NODE
        self.log.info("Setup (proof of work is allowed here): %d wallets with one funded quantum output each, %d released and %d held on every node",
                      count, RELEASED_PER_NODE, HELD_PER_NODE)
        self.producers = [(n, f"s{n}_{j}") for j in range(SINGLETON_WALLETS_PER_NODE) for n in range(PRODUCERS)]
        # Wallet j of every node is released for j < RELEASED_PER_NODE and held otherwise: the fixture is constructed,
        # not drawn (see fund_quantum_output), so every node has seven released and six held outputs.
        self.held = {p: int(p[1].rsplit("_", 1)[1]) >= RELEASED_PER_NODE for p in self.producers}
        for producer in self.producers:
            self.nodes[producer[0]].createwallet(producer[1], descriptors=self.options.descriptors)
            self.wallet_of(producer).staking(False)
        # All setup blocks are made by node 0 (the other nodes' own wallets hold nothing of proof of work).
        self.pow_blocks(self.nodes[0], G + 3 - self.nodes[0].getblockcount(), pow_addr, sync=True)
        default = self.nodes[0].get_wallet_rpc(self.default_wallet_name)
        sources = self.funding_inputs(default, minimum=Decimal(10000))
        assert len(sources) >= count, "%d mature coins to fund %d wallets from" % (len(sources), count)
        self.initial = {}
        for producer in self.producers:
            address = self.wallet_of(producer).getnewquantumaddress()["address"]
            self.initial[producer] = key(self.fund_quantum_output(
                self.nodes[0], default, sources.pop(0), address, Decimal(1000), held=self.held[producer]))
        self.pow_blocks(self.nodes[0], 1, pow_addr, sync=True)
        self.pow_blocks(self.nodes[0], SETUP_END - self.nodes[0].getblockcount(), pow_addr, sync=True)
        assert_equal(self.nodes[0].getblockcount(), SETUP_END)

        # The fixture's counts, asserted on the actual outpoints: parity, maturity, one output per wallet, no legacy coin.
        for node_index in range(PRODUCERS):
            on_node = [p for p in self.producers if p[0] == node_index]
            assert_equal(len([p for p in on_node if not single_output_reserve_bit(*self.initial[p])]), RELEASED_PER_NODE)
            assert_equal(len([p for p in on_node if single_output_reserve_bit(*self.initial[p])]), HELD_PER_NODE)
        for producer in self.producers:
            assert_equal(single_output_reserve_bit(*self.initial[producer]), self.held[producer])
            wallet = self.wallet_of(producer)
            outputs = [u for u in wallet.listunspent(1, 9999999) if u["amount"] > 0]
            assert_equal(len(outputs), 1)  # the wallet's one output, and nothing else: no legacy coin to stake
            assert_equal(key(outputs[0]), self.initial[producer])
            assert outputs[0]["confirmations"] >= MATURITY + 1, outputs[0]  # mature for the first candidate block
            info = wallet.getquantumstakereadiness()["final_stake_reserve"]
            assert_equal(info["n"], 1)
            assert_equal(info["single_output_rule"], "held" if self.held[producer] else "released")
            assert_equal(info["target"], 1 if self.held[producer] else 0)
        # Every node's own default wallet holds only proof-of-work coinbases and change, and does not stake.
        for node in self.nodes:
            assert_equal(node.get_wallet_rpc(self.default_wallet_name).getstakinginfo()["staking"], False)

    def run_test(self):
        default = self.nodes[0].get_wallet_rpc(self.default_wallet_name)
        default.staking(False)
        for node in self.nodes[1:]:
            node.get_wallet_rpc(self.default_wallet_name).staking(False)
        self.set_initial_mt()
        pow_addr = default.getnewaddress("", "legacy")
        pow_addr_of = []
        for node in self.nodes:
            pow_addr_of.append(node.get_wallet_rpc(self.default_wallet_name).getnewaddress("", "legacy"))
        self.kernels = []
        self.build_producers(pow_addr, pow_addr_of)
        singleton = self.options.singleton_population

        everyone = list(range(PRODUCERS))
        self.log.info("From height %d only the wallet stakers make blocks (no generate, no hand-built coinstake)", SETUP_END)
        # 81 is before the guard; 82..91 are the candidate heights of the guard.
        reserved_at_last_migration = set()
        while self.nodes[0].getblockcount() < M:
            height = self.nodes[0].getblockcount() + 1
            if height >= GUARD_START:
                for producer in self.producers:
                    info, reserved = self.reserve_keys(producer)
                    assert_equal(info["active"], True)
                    assert_equal(info["final_height"], F)
                    if singleton:
                        # A wallet that staked earlier has outputs that are not all mature at F: a shortage is accounted.
                        assert_equal(len(reserved), info["target"] - info["shortfall"])
                    else:
                        assert_equal(info["shortfall"], 0)
                        assert_equal(len(reserved), info["target"])
                        assert info["target"] >= 1
            if height == M and singleton:
                # What the wallets hold back at the last Migration block is what may make F.
                for producer in self.producers:
                    reserved_at_last_migration |= self.reserve_keys(producer)[1]
                assert len(reserved_at_last_migration) >= 2 * MIN_HELD_PER_SIDE
            self.stake_next(self.producer_blocks(everyone), everyone)
        assert_equal(self.nodes[0].getblockcount(), M)

        self.log.info("Restart of a producer at the tip M: its readiness for F is unchanged")
        restarted = next(p for p in self.producers_in([1]) if self.wallet_of(p).getquantumstakereadiness()["next_block"]["eligible_outputs"] >= 1)
        before = self.wallet_of(restarted).getquantumstakereadiness()["next_block"]
        assert_equal(before["height"], F)
        assert before["eligible_outputs"] >= 1
        assert_equal(self.reserve_keys(restarted)[0]["active"], False)  # the guard is released for candidate F
        self.restart_node(1, extra_args=LIFECYCLE_ARGS + [f"-mocktime={self.mt}"])
        self.connect_nodes(1, 0)
        self.connect_nodes(1, 2)
        for producer in self.producers_in([1]):
            if producer[1] not in self.nodes[1].listwallets():
                self.nodes[1].loadwallet(producer[1])
            self.wallet_of(producer).staking(False)
        self.set_mt(self.mt)
        after = self.wallet_of(restarted).getquantumstakereadiness()["next_block"]
        for field in ("eligible_outputs", "eligible_nominal", "eligible_effective", "stakeable_outputs", "stakeable_effective"):
            assert_equal(after[field], before[field])
        self.sync_blocks()

        self.log.info("A reorganisation across F: the network splits at M, each side stakes its own block F")
        self.disconnect_nodes(1, 2)
        side_a, side_b = [0, 1], [2, 3]
        # In the singleton population the first Final block comes from a held wallet's one output, which was reserved a block
        # earlier (it is the wallet's only output, so its staker has no other kernel to take).
        only = None
        if singleton:
            only = {self.initial[p] for p in self.producers if self.held[p]}
            assert only <= reserved_at_last_migration, "a held output was not reserved at the last Migration block"
        f_a = self.stake_next(self.producer_blocks(side_a, only), side_a, only)
        f_b = self.stake_next(self.producer_blocks(side_b, only), side_b, only)
        assert f_a != f_b
        assert_equal(self.nodes[0].getblock(f_a)["height"], F)
        assert_equal(self.nodes[2].getblock(f_b)["height"], F)
        if singleton:
            for height, kernel, _ in self.kernels[-2:]:
                assert_equal(height, F)
                assert kernel in only, "block F was not made from a held output: %s" % (kernel,)
        # Side A, ahead by two blocks, the wallets using outputs that were reserved a block ago.
        self.stake_next(self.producer_blocks(side_a), side_a)
        self.stake_next(self.producer_blocks(side_a), side_a)
        assert_equal(self.nodes[0].getblockcount(), F + 2)
        assert_equal(self.nodes[2].getblockcount(), F)
        self.connect_nodes(1, 2)
        self.sync_blocks()
        assert_equal(self.nodes[2].getblockhash(F), f_a)  # the shorter side dropped its F
        assert_equal(self.nodes[3].getblockhash(F), f_a)
        assert_equal(self.nodes[0].getblockhash(F), f_a)

        self.log.info("Half of the producers are lost for good; the other half carry the chain through height %d", CROSSING_END)
        self.stop_node(2)
        self.stop_node(3)
        survivors = [0, 1]
        while self.nodes[0].getblockcount() < CROSSING_END:
            self.stake_next(self.producer_blocks(survivors), survivors)
        assert_equal(self.nodes[0].getblockcount(), CROSSING_END)
        assert_equal(self.nodes[1].getbestblockhash(), self.nodes[0].getbestblockhash())

        self.log.info("Every block from %d to %d is proof of stake and none was made by proof of work", SETUP_END + 1, CROSSING_END)
        for height in range(SETUP_END + 1, CROSSING_END + 1):
            block = self.nodes[0].getblock(self.nodes[0].getblockhash(height))
            assert "proof-of-stake" in block["flags"], height
        assert_equal(self.nodes[0].getquantumquasarinfo()["phase"], "final_lockout")
        if singleton:
            # Every kernel was one of the population's own outputs or the output of one of its earlier coinstakes.
            own_txids = {txid for txid, _ in self.initial.values()} | {txid for _, _, txid in self.kernels}
            for height, kernel, _ in self.kernels:
                assert kernel[0] in own_txids, (height, kernel)


if __name__ == '__main__':
    FinalWalletStakerCrossingTest().main()
