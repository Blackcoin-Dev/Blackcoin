#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""The final stake reserve is derived again when a transaction is committed.

Regtest: Gold Rush ends at G=61, Migration ends at M=91 (first Final block F=92), maturity 10, so the reserve is on for
the candidate heights 82..91. A wallet with two quantum outputs (N = 2, R = 1) builds a transaction while the tip is
80, the candidate 81 is outside the guard and nothing is reserved. The commit is paused (a test-chain-only option) and
the chain moves two blocks, into the guard, so the output that is now reserved is an input of a transaction built
before:

 * a transaction whose inputs the wallet chose itself (sendtoaddress, sendall, optimizeutxoset, with and without
   lock_unspents) is refused at the commit and leaves nothing behind: no wallet record, no mempool entry, no lock;
 * the same payment with the reserved output selected explicitly (send with inputs) is accepted.

The chain is taken back to height 80 between the cases (invalidateblock), so each starts the same way.
"""
from decimal import Decimal
from threading import Thread
from urllib.parse import quote

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import (
    assert_equal,
    get_rpc_proxy,
)
from transition_t_final_util import (
    F,
    G,
    LIFECYCLE_ARGS,
    MATURITY,
    TransitionTFinalTestBase,
)

BEFORE_GUARD = F - MATURITY - 2  # 80: the candidate 81 is outside the guard
K_OUTPUTS = 2
REFUSED = "held back as the final stake reserve"


class FinalStakeReserveCommitTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.extra_args = [LIFECYCLE_ARGS + ["-finalstakereservecommitdelaymillis=2000"]]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def key(self, outpoint):
        return (outpoint["txid"], outpoint["vout"])

    def run_test(self):
        node = self.nodes[0]
        default = node.get_wallet_rpc(self.default_wallet_name)
        default.staking(False)
        self.set_initial_mt()
        pow_addr = default.getnewaddress("", "legacy")

        self.log.info("A wallet with two quantum outputs, each migrated from its own coinbase")
        node.createwallet("wc")
        wallet = node.get_wallet_rpc("wc")
        wallet.staking(False)
        for _ in range(K_OUTPUTS):
            self.generatetoaddress(node, 1, wallet.getnewaddress("", "legacy"), sync_fun=self.no_op)
            self.bump()
        self.pow_blocks(node, G - node.getblockcount(), pow_addr)
        for _ in range(K_OUTPUTS):
            address = wallet.getnewquantumaddress()["address"]
            wallet.migratetoquantum({"existing_address": address, "max_inputs": 1})
            self.pow_blocks(node, 1, pow_addr)
        self.pow_blocks(node, BEFORE_GUARD - node.getblockcount(), pow_addr)
        assert_equal(node.getblockcount(), BEFORE_GUARD)
        self.sync_mt_tip()

        info = wallet.getquantumstakereadiness()["final_stake_reserve"]
        assert_equal(info["active"], False)
        assert_equal(info["n"], K_OUTPUTS)
        assert_equal(info["reserved_count"], 1)  # the planned reserve, not yet enforced
        self.reserved = self.key(info["reserved_outpoints"][0])
        outputs = {self.key(u): u for u in wallet.listunspent(1, 9999999) if u["amount"] > 0}
        assert_equal(len(outputs), K_OUTPUTS)
        assert self.reserved in outputs
        self.free = next(k for k in outputs if k != self.reserved)
        self.total = sum(Decimal(str(u["amount"])) for u in outputs.values())
        self.base_hash = node.getbestblockhash()
        self.destination = wallet.getnewquantumaddress()["address"]
        self.wallet_url = f"{node.url}/wallet/{quote('wc', safe='')}"

        records = wallet.getwalletinfo()["txcount"]

        def nothing_left(label):
            assert_equal(node.getrawmempool(), [])
            assert_equal(wallet.listlockunspent(), [])
            assert_equal(wallet.getwalletinfo()["txcount"], records)  # no record of the refused transaction
            assert_equal({self.key(u) for u in wallet.listunspent(0, 9999999) if u["amount"] > 0}, set(outputs))

        self.log.info("sendtoaddress needs both outputs: built before the guard, refused at the commit")
        error = self.send_while_guard_starts(lambda rpc: rpc.sendtoaddress(address=self.destination, amount=self.total - 1, change_address=self.destination))
        assert REFUSED in error, error
        nothing_left("sendtoaddress")
        self.back_to_before_guard()

        self.log.info("sendall (the wallet picks every output), and with lock_unspents: no lock is left behind")
        for options in ({}, {"lock_unspents": True}):
            error = self.send_while_guard_starts(lambda rpc: rpc.sendall(recipients=[self.destination], options=options))
            assert REFUSED in error, error
            nothing_left("sendall")
            self.back_to_before_guard()

        self.log.info("optimizeutxoset with transmit: the optimiser's own inputs are refused at the commit too")
        error = self.send_while_guard_starts(lambda rpc: rpc.optimizeutxoset(self.destination, (self.total / 4).quantize(Decimal("0.00000001")), True))
        assert REFUSED in error, error
        nothing_left("optimizeutxoset")
        self.back_to_before_guard()

        self.log.info("send with lock_unspents: the locks of the operation are released with the refusal, a lock the user put on an input is not")
        wallet.lockunspent(False, [{"txid": self.free[0], "vout": self.free[1]}])  # the user's own lock
        error = self.send_while_guard_starts(
            lambda rpc: rpc.send(outputs=[{self.destination: self.total - 1}],
                                 options={"inputs": [{"txid": self.free[0], "vout": self.free[1]}], "add_inputs": True,
                                          "lock_unspents": True, "change_address": self.destination}))
        assert error is not None and REFUSED in error, error
        assert_equal(node.getrawmempool(), [])
        assert_equal(wallet.getwalletinfo()["txcount"], records)
        assert_equal({(lock["txid"], lock["vout"]) for lock in wallet.listlockunspent()}, {self.free})  # the user's lock only
        wallet.lockunspent(True, [{"txid": self.free[0], "vout": self.free[1]}])
        self.back_to_before_guard()

        self.log.info("Built for the first Final block (the guard released), committed after the chain went back one block: refused")
        self.pow_blocks(node, F - 1 - node.getblockcount(), pow_addr)  # the tip is M, the candidate is F
        assert_equal(node.getblockcount(), F - 1)
        error = self.send_while(
            lambda rpc: rpc.sendtoaddress(address=self.destination, amount=self.total - 1, change_address=self.destination),
            lambda: node.invalidateblock(node.getbestblockhash()))  # the tip is M - 1 again: the candidate is M, in the guard
        assert error is not None and REFUSED in error, error
        nothing_left("first Final block")
        self.back_to_before_guard()

        self.log.info("The same payment with the reserved output selected explicitly is accepted, and the commit reports it")
        reserved_value = Decimal(str(outputs[self.reserved]["amount"]))
        result = {}
        error = self.send_while_guard_starts(
            lambda rpc: rpc.send(outputs=[{self.destination: reserved_value / 2}],
                                 options={"inputs": [{"txid": self.reserved[0], "vout": self.reserved[1]}],
                                          "add_inputs": False, "lock_unspents": True, "change_address": self.destination}),
            result)
        assert error is None, error
        txid = result["value"]["txid"]
        assert_equal(node.getrawmempool(), [txid])
        spent = {(i["txid"], i["vout"]) for i in node.decoderawtransaction(wallet.gettransaction(txid)["hex"])["vin"]}
        assert_equal(spent, {self.reserved})
        # Built before the guard, with its own coin lock on the explicit input: the report still comes out of the commit.
        report = result["value"]["final_stake_reserve_spent"]
        assert_equal({(o["txid"], o["vout"]) for o in report["outpoints"]}, {self.reserved})
        assert_equal(report["reserved_before"], 1)
        assert_equal(report["eligible_before"], K_OUTPUTS)
        assert_equal(report["eligible_after"], K_OUTPUTS - 1)
        assert Decimal(str(report["eligible_weight_after"])) < Decimal(str(report["eligible_weight_before"]))

    def send_while_guard_starts(self, call, result=None):
        """Two blocks are mined while the commit pauses, so the guard is on when the commit continues."""
        def mine():
            self.pow_blocks(self.nodes[0], 2, self.nodes[0].get_wallet_rpc(self.default_wallet_name).getnewaddress("", "legacy"))
            assert_equal(self.nodes[0].getblockcount(), BEFORE_GUARD + 2)
        return self.send_while(call, mine, result)

    def send_while(self, call, during, result=None):
        """Run `call(wallet rpc)` in a thread. Its commit pauses before any lock is taken (a test-chain-only option);
        `during()` runs meanwhile. Returns the error text, or None when the call succeeded."""
        node = self.nodes[0]
        outcome = {}

        def run():
            rpc = get_rpc_proxy(self.wallet_url, 91, timeout=300, coveragedir=node.coverage_dir)
            try:
                outcome["value"] = call(rpc)
            except Exception as e:  # noqa: BLE001
                outcome["error"] = str(e)

        thread = Thread(target=run, name="commit-in-flight", daemon=True)
        try:
            with node.wait_for_debug_log([b"Wallet commit test pause reached"], timeout=30):
                thread.start()
        except AssertionError:
            thread.join(timeout=5)
            raise AssertionError("the commit never paused: %s" % outcome)
        during()
        thread.join(timeout=60)
        assert not thread.is_alive(), "the commit did not finish"
        if result is not None and "value" in outcome:
            result["value"] = outcome["value"]
        return outcome.get("error")

    def back_to_before_guard(self):
        node = self.nodes[0]
        node.invalidateblock(node.getblockhash(BEFORE_GUARD + 1))
        assert_equal(node.getbestblockhash(), self.base_hash)
        self.sync_mt_tip()


if __name__ == '__main__':
    FinalStakeReserveCommitTest().main()
