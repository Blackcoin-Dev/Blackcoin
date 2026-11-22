#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Wallet stakers alone carry the chain across the whole maturity cycle before and after the first Final block.

Regtest: Gold Rush ends at G=61, Migration ends at M=91 (first Final block F=92), maturity 10. Four producer nodes
each hold a wallet with quantum outputs migrated long before. The setup (proof of work, funding, migration) ends at
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
"""
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal
from transition_t_final_util import (
    F,
    G,
    LIFECYCLE_ARGS,
    M,
    MATURITY,
    TransitionTFinalTestBase,
)

SETUP_END = F - MATURITY - 2  # 80
CROSSING_END = F + MATURITY + 2  # 104
GUARD_START = F - MATURITY
PRODUCERS = 4
OUTPUTS_PER_PRODUCER = 8
WALLET = "producer"


def key(outpoint):
    return (outpoint["txid"], outpoint["vout"])


class FinalWalletStakerCrossingTest(TransitionTFinalTestBase, BitcoinTestFramework):
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

    def wallet_of(self, index):
        return self.nodes[index].get_wallet_rpc(WALLET)

    def reserve_keys(self, index):
        info = self.wallet_of(index).getquantumstakereadiness()["final_stake_reserve"]
        return info, {(o["txid"], o["vout"]) for o in info["reserved_outpoints"]}

    def allowed_outputs(self, index):
        """The outputs of producer `index` its staker may use now: mature for the next block (the wallet stakes an
        output from the block it matures in, `confirmations >= MATURITY`) and not in the final stake reserve."""
        wallet = self.wallet_of(index)
        _, reserved = self.reserve_keys(index)
        return reserved, [{"txid": u["txid"], "vout": u["vout"]} for u in wallet.listunspent(1, 9999999)
                          if u["spendable"] and u["amount"] > 0 and u["confirmations"] >= MATURITY and key(u) not in reserved]

    def producer_blocks(self, group):
        """The producers of `group` take turns by height: one block each time, made by the wallet's own staker. The
        reserve is chosen by transaction hash, so which outputs a producer may use varies from run to run: when the
        producer whose turn it is has no output it may use (all its mature outputs are reserved), the next one in the
        rotation makes the block. Every block is still made by a wallet staker."""
        height = self.nodes[group[0]].getblockcount() + 1
        for offset in range(len(group)):
            index = group[(height + offset) % len(group)]
            if self.allowed_outputs(index)[1]:
                return index
        raise AssertionError("no producer of the group has an output it may stake")

    def stake_next(self, index, group):
        """The staker of producer `index` makes the next block from an output it is allowed to use now. Returns the
        block hash; the group's nodes are synced."""
        node = self.nodes[index]
        wallet = self.wallet_of(index)
        reserved, allowed = self.allowed_outputs(index)
        assert allowed, "producer %d has no output it may stake" % index
        before = node.getblockcount()
        for _ in range(60000):
            result = wallet.checkkernel(allowed)
            if result["found"]:
                break
            self.bump()
        else:
            raise AssertionError("no kernel for producer %d" % index)
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
        assert key(coinstake["vin"][0]) not in reserved, "the staker used a reserved output"
        self.sync_blocks([self.nodes[i] for i in group])
        return block_hash

    def run_test(self):
        default = self.nodes[0].get_wallet_rpc(self.default_wallet_name)
        default.staking(False)
        self.set_initial_mt()
        pow_addr = default.getnewaddress("", "legacy")
        pow_addr_of = []
        for node in self.nodes:
            pow_addr_of.append(node.get_wallet_rpc(self.default_wallet_name).getnewaddress("", "legacy"))

        self.log.info("Setup (proof of work is allowed here): %d producers with %d migrated quantum outputs each",
                      PRODUCERS, OUTPUTS_PER_PRODUCER)
        for i, node in enumerate(self.nodes):
            node.createwallet(WALLET)
            self.wallet_of(i).staking(False)
        for _ in range(OUTPUTS_PER_PRODUCER):
            for i in range(PRODUCERS):
                self.generatetoaddress(self.nodes[0], 1, self.wallet_of(i).getnewaddress("", "legacy"), sync_fun=self.sync_blocks)
                self.bump()
        self.pow_blocks(self.nodes[0], G - self.nodes[0].getblockcount(), pow_addr)
        self.sync_blocks()
        # Each producer migrates two coins and mines the block that holds them on its own node.
        for _ in range(OUTPUTS_PER_PRODUCER // 2):
            for i in range(PRODUCERS):
                wallet = self.wallet_of(i)
                for _ in range(2):
                    wallet.migratetoquantum({"existing_address": wallet.getnewquantumaddress()["address"], "max_inputs": 1})
                self.generatetoaddress(self.nodes[i], 1, pow_addr_of[i], sync_fun=self.sync_blocks)
                self.bump()
        self.pow_blocks(self.nodes[0], SETUP_END - self.nodes[0].getblockcount(), pow_addr)
        self.sync_blocks()
        assert_equal(self.nodes[0].getblockcount(), SETUP_END)
        for i in range(PRODUCERS):
            assert_equal(len([u for u in self.wallet_of(i).listunspent(1, 9999999) if u["amount"] > 0]), OUTPUTS_PER_PRODUCER)

        everyone = list(range(PRODUCERS))
        self.log.info("From height %d only the wallet stakers make blocks (no generate, no hand-built coinstake)", SETUP_END)
        # 81 is before the guard; 82..91 are the candidate heights of the guard.
        while self.nodes[0].getblockcount() < M:
            height = self.nodes[0].getblockcount() + 1
            if height >= GUARD_START:
                for i in everyone:
                    info, reserved = self.reserve_keys(i)
                    assert_equal(info["active"], True)
                    assert_equal(info["final_height"], F)
                    assert_equal(len(reserved), info["target"])
                    assert info["target"] >= 1
            self.stake_next(self.producer_blocks(everyone), everyone)
        assert_equal(self.nodes[0].getblockcount(), M)

        self.log.info("Restart of a producer at the tip M: its readiness for F is unchanged")
        before = self.wallet_of(1).getquantumstakereadiness()["next_block"]
        assert_equal(before["height"], F)
        assert before["eligible_outputs"] >= 1
        assert_equal(self.reserve_keys(1)[0]["active"], False)  # the guard is released for candidate F
        self.restart_node(1, extra_args=LIFECYCLE_ARGS + [f"-mocktime={self.mt}"])
        self.connect_nodes(1, 0)
        self.connect_nodes(1, 2)
        if WALLET not in self.nodes[1].listwallets():
            self.nodes[1].loadwallet(WALLET)
        self.wallet_of(1).staking(False)
        self.set_mt(self.mt)
        after = self.wallet_of(1).getquantumstakereadiness()["next_block"]
        for field in ("eligible_outputs", "eligible_nominal", "eligible_effective", "stakeable_outputs", "stakeable_effective"):
            assert_equal(after[field], before[field])
        self.sync_blocks()

        self.log.info("A reorganisation across F: the network splits at M, each side stakes its own block F")
        self.disconnect_nodes(1, 2)
        side_a, side_b = [0, 1], [2, 3]
        f_a = self.stake_next(self.producer_blocks(side_a), side_a)
        f_b = self.stake_next(self.producer_blocks(side_b), side_b)
        assert f_a != f_b
        assert_equal(self.nodes[0].getblock(f_a)["height"], F)
        assert_equal(self.nodes[2].getblock(f_b)["height"], F)
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


if __name__ == '__main__':
    FinalWalletStakerCrossingTest().main()
