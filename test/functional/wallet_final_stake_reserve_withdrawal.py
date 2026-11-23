#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""A staking withdrawal that names a reserved output keeps that output as its explicit choice through the commit.

Regtest: Gold Rush ends at G=61, Migration ends at M=91 (first Final block F=92), maturity 10, so the final stake
reserve is on for the candidate heights 82..91. A wallet holds two bonded staking outputs (N = 2, R = 1: the larger is
the reserve) and a small legacy coin for the fee. The withdrawal that names the reserved output is built while the tip is
80 (the candidate 81 is outside the guard) and paused at its commit while two blocks are mined, so it is committed inside
the guard. The named output is the caller's own choice and may be spent; the result says that it was reserved. The
fee input the withdrawal picked itself would not have that right (the unit tests cover the refusal).
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

BEFORE_GUARD = F - MATURITY - 2  # 80
UNBONDING_BLOCKS = 9450


class FinalStakeReserveWithdrawalTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.extra_args = [LIFECYCLE_ARGS + ["-donatetodevfund=0", f"-qqstaketierheight={G + 1}", "-finalstakereservecommitdelaymillis=2000"]]

    def run_test(self):
        node = self.nodes[0]
        default = node.get_wallet_rpc(self.default_wallet_name)
        default.staking(False)
        self.set_initial_mt()
        pow_addr = default.getnewaddress("", "legacy")
        node.createwallet("wb")
        wallet = node.get_wallet_rpc("wb")
        wallet.staking(False)

        self.pow_blocks(node, G + 2, pow_addr)
        big_address = wallet.getnewquantumstakeaddress("bond-big", UNBONDING_BLOCKS)["address"]
        small_address = wallet.getnewquantumstakeaddress("bond-small", UNBONDING_BLOCKS)["address"]
        big_txid = default.sendtoaddress(big_address, 6000)
        default.sendtoaddress(small_address, 3000)
        default.sendtoaddress(wallet.getnewaddress("", "legacy"), 50)  # the fee input
        self.pow_blocks(node, BEFORE_GUARD - node.getblockcount(), pow_addr)
        assert_equal(node.getblockcount(), BEFORE_GUARD)
        self.sync_mt_tip()

        big = next(u for u in wallet.listunspent(1, 9999999, [big_address]) if u["txid"] == big_txid)
        outpoint = {"txid": big["txid"], "vout": big["vout"]}
        info = wallet.getquantumstakereadiness()["final_stake_reserve"]
        assert_equal(info["active"], False)
        assert_equal((info["n"], info["reserved_count"]), (2, 1))
        assert_equal({(o["txid"], o["vout"]) for o in info["reserved_outpoints"]}, {(big["txid"], big["vout"])})

        self.log.info("The withdrawal is built before the guard and committed inside it: the named reserved output is spent")
        url = f"{node.url}/wallet/{quote('wb', safe='')}"
        outcome = {}

        def run():
            rpc = get_rpc_proxy(url, 91, timeout=300 * int(self.options.timeout_factor), coveragedir=node.coverage_dir)
            try:
                outcome["value"] = rpc.withdrawquantumstakeaddress(big_address, outpoint, {"allow_new_quantum_key": True})
            except Exception as e:  # noqa: BLE001
                outcome["error"] = str(e)

        thread = Thread(target=run, name="withdrawal-in-flight", daemon=True)
        with node.wait_for_debug_log([b"Wallet commit test pause reached"], timeout=30):
            thread.start()
        self.pow_blocks(node, 2, pow_addr)
        assert_equal(node.getblockcount(), BEFORE_GUARD + 2)
        thread.join(timeout=60 * self.options.timeout_factor)
        assert not thread.is_alive(), "the withdrawal did not finish"
        assert "error" not in outcome, outcome
        result = outcome["value"]
        assert "final stake reserve" in result["warning"], result["warning"]
        spent = {(i["txid"], i["vout"]) for i in node.decoderawtransaction(wallet.gettransaction(result["txid"])["hex"])["vin"]}
        assert (big["txid"], big["vout"]) in spent
        after = wallet.getquantumstakereadiness()["final_stake_reserve"]
        assert_equal(after["active"], True)
        assert (big["txid"], big["vout"]) not in {(o["txid"], o["vout"]) for o in after["reserved_outpoints"]}


if __name__ == '__main__':
    FinalStakeReserveWithdrawalTest().main()
