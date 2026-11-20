#!/usr/bin/env python3
# Copyright (c) 2026 Quantum Quasar Developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Test the balance RPCs as a polling client uses them.

getwalletinfo, getbalances and getbalance return the last calculated balance
without waiting for the node's locks, say which block it belongs to and
whether it is exact, and wait for an exact balance only when asked to.
"""

from decimal import Decimal
import re

from test_framework.blocktools import COINBASE_MATURITY
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import (
    assert_equal,
    assert_raises_rpc_error,
)

BALANCE_STATE = re.compile(r"^(exact|current-unverified|behind\(\d+\)|none|failed)$")

# What a fleet script reads from getwalletinfo, and the new fields.
WALLETINFO_KEYS = {
    "walletname": str,
    "walletversion": int,
    "format": str,
    "balance": Decimal,
    "stake": Decimal,
    "unconfirmed_balance": Decimal,
    "immature_balance": Decimal,
    "lifecycle": dict,
    "txcount": int,
    "keypoolsize": int,
    "paytxfee": Decimal,
    "private_keys_enabled": bool,
    "avoid_reuse": bool,
    "descriptors": bool,
    "lastprocessedblock": dict,
    "balance_exact": bool,
    "balance_height": int,
    "balance_state": str,
}


class PolledBalanceTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.setup_clean_chain = True
        self.num_nodes = 1
        # The node's own default, not the test framework's: a poll returns
        # the last calculated balance.
        self.extra_args = [["-walletrpcexactbalance=0"]]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def check_poll(self, info):
        """What every answer of a poll guarantees, exact or not."""
        assert BALANCE_STATE.match(info["balance_state"]), info["balance_state"]
        last = info["lastprocessedblock"]
        if info["balance_state"] == "none":
            assert_equal(info["balance_exact"], False)
            assert_equal(info["balance_height"], -1)
            assert "balance_blockhash" not in info
            return
        assert info["balance_height"] <= last["height"]
        if info["balance_exact"]:
            assert_equal(info["balance_state"], "exact")
        if info["balance_state"] == "exact":
            assert_equal(info["balance_height"], last["height"])
            assert_equal(info["balance_blockhash"], last["hash"])
        # A balance is the balance of the block it names.
        known = self.exact_by_block.get(info["balance_blockhash"])
        if known is not None and info["balance_state"] != "current-unverified":
            if "mine" in info:
                assert_equal(info["mine"]["trusted"], known["trusted"])
                assert_equal(info["mine"]["immature"], known["immature"])
            else:
                assert_equal(info["balance"], known["trusted"])
                assert_equal(info["immature_balance"], known["immature"])

    def record_exact(self, node):
        balances = node.getbalances(exact=True)
        assert_equal(balances["balance_exact"], True)
        assert_equal(balances["balance_state"], "exact")
        assert_equal(balances["balance_blockhash"], node.getbestblockhash())
        assert_equal(balances["balance_height"], node.getblockcount())
        assert_equal(balances["lifecycle_evaluation_height"], node.getblockcount() + 1)
        self.exact_by_block[balances["balance_blockhash"]] = balances["mine"]
        return balances

    def wait_exact(self, node):
        self.wait_until(lambda: node.getwalletinfo()["balance_exact"])

    def run_test(self):
        node = self.nodes[0]
        self.exact_by_block = {}

        self.log.info("A poll of a new wallet answers, whatever has been calculated")
        info = node.getwalletinfo()
        self.check_poll(info)
        self.check_poll(node.getbalances())

        self.generate(node, COINBASE_MATURITY + 10)

        self.log.info("Field compatibility: every key and type a polling script reads")
        self.wait_exact(node)
        info = node.getwalletinfo()
        for key, kind in WALLETINFO_KEYS.items():
            assert key in info, key
            assert isinstance(info[key], kind), (key, type(info[key]))
        assert "categories" in info["lifecycle"]
        assert_equal(info["lifecycle"]["evaluation_height"], node.getblockcount() + 1)
        balances = node.getbalances()
        for key in ("trusted", "untrusted_pending", "immature", "stake", "lifecycle"):
            assert key in balances["mine"], key
        for key in ("lifecycle_evaluation_height", "lifecycle_evaluation_mtp", "lastprocessedblock",
                    "balance_exact", "balance_height", "balance_blockhash", "balance_state"):
            assert key in balances, key
        assert isinstance(node.getbalance(), Decimal)

        self.log.info("The polled balance, once exact, is the exact balance")
        exact = self.record_exact(node)
        assert exact["mine"]["trusted"] > 0
        assert exact["mine"]["immature"] > 0
        assert_equal(node.getbalances()["mine"], exact["mine"])
        assert_equal(info["balance"], exact["mine"]["trusted"])
        assert_equal(info["immature_balance"], exact["mine"]["immature"])
        assert_equal(info["stake"], exact["mine"]["stake"])
        assert_equal(node.getbalance(), exact["mine"]["trusted"])
        assert_equal(node.getbalance(exact=True), exact["mine"]["trusted"])
        exact_info = node.getwalletinfo(exact=True)
        assert_equal(exact_info["balance_exact"], True)
        assert_equal(exact_info["balance"], exact["mine"]["trusted"])
        assert_equal(node.getwalletinfo(True)["balance"], exact["mine"]["trusted"])

        self.log.info("Other arguments of getbalance are calculated for the call")
        assert_equal(node.getbalance("*", 0), exact["mine"]["trusted"])
        assert_equal(node.getbalance(minconf=1), exact["mine"]["trusted"])
        assert_equal(node.getbalance(minconf=1000000), 0)
        assert_equal(node.getbalance("*", 0, False, False), exact["mine"]["trusted"])
        assert_raises_rpc_error(-4, "wallet does not have the \"avoid reuse\" feature enabled",
                                node.getbalance, "*", 0, False, True)

        self.log.info("Polling while blocks connect: every answer is right about its block")
        for _ in range(15):
            self.generate(node, 1)
            for _ in range(3):
                self.check_poll(node.getwalletinfo())
                self.check_poll(node.getbalances())
            self.record_exact(node)
            # Exact a moment ago, and nothing has changed since.
            polled = node.getbalances()
            self.check_poll(polled)
            assert_equal(polled["balance_exact"], True)
            assert_equal(polled["mine"], self.exact_by_block[node.getbestblockhash()])

        self.log.info("A wallet transaction: the poll catches up, an exact request waits for it")
        before = node.getbalances(exact=True)["mine"]
        node.sendtoaddress(node.getnewaddress(), 10)
        after = node.getbalances(exact=True)
        assert_equal(after["balance_exact"], True)
        assert after["mine"]["trusted"] < before["trusted"]  # the fee
        assert after["mine"]["trusted"] > before["trusted"] - 1
        self.wait_until(lambda: node.getbalances()["balance_exact"])
        assert_equal(node.getbalances()["mine"], after["mine"])
        assert_equal(node.getbalance(), after["mine"]["trusted"])
        # Unconfirmed change of our own counts at minconf 0, not at minconf 1.
        assert node.getbalance(minconf=1) < node.getbalance(minconf=0)
        self.generate(node, 1)
        assert_equal(node.getbalance(minconf=1), node.getbalance(exact=True))

        self.log.info("An encrypted wallet reports unlocked_until with the polled balance")
        node.encryptwallet("polled")
        info = node.getwalletinfo()
        self.check_poll(info)
        assert_equal(info["unlocked_until"], 0)
        node.walletpassphrase("polled", 600)
        info = node.getwalletinfo()
        assert info["unlocked_until"] > 0
        assert isinstance(info["unlocked_until"], int)
        node.walletlock()

        self.log.info("Restart with the wallet and poll while blocks connect")
        expected = self.record_exact(node)
        self.restart_node(0, ["-walletrpcexactbalance=0"])
        info = node.getwalletinfo()
        self.check_poll(info)
        for _ in range(10):
            self.generate(node, 1)
            self.check_poll(node.getwalletinfo())
            self.check_poll(node.getbalances())
        self.wait_exact(node)
        final = self.record_exact(node)
        assert final["mine"]["trusted"] > expected["mine"]["trusted"]
        info = node.getwalletinfo()
        if info["balance_exact"]:
            assert_equal(info["balance"], final["mine"]["trusted"])

        self.log.info("No balance work starts while the start-up wallets are still loading")
        names = ["startup_a", "startup_b", "startup_c"]
        for name in names:
            node.createwallet(wallet_name=name, load_on_startup=True)
            self.generatetoaddress(node, 3, node.get_wallet_rpc(name).getnewaddress())
        self.generate(node, COINBASE_MATURITY)
        self.stop_node(0)
        log_start = node.debug_log_path.stat().st_size
        self.start_node(0, ["-walletrpcexactbalance=0"])
        for name in names:
            wallet = node.get_wallet_rpc(name)
            self.wait_until(lambda: wallet.getwalletinfo()["balance_exact"])
            assert wallet.getbalance() > 0
        with open(node.debug_log_path, encoding="utf-8", errors="replace") as log:
            log.seek(log_start)
            lines = log.read().splitlines()
        loaded = [i for i, line in enumerate(lines) if "Wallet completed loading" in line]
        balance = [i for i, line in enumerate(lines)
                   if "GUI balance warm-up" in line or "first balance ready" in line]
        assert len(loaded) >= len(names), loaded
        # The worker did its work, and all of it after the last wallet loaded.
        assert len(balance) >= len(names), balance
        assert min(balance) > max(loaded), (min(balance), max(loaded))
        for name in names:
            node.unloadwallet(name, load_on_startup=False)

        self.log.info("-walletrpcexactbalance=1 makes exact the default")
        self.restart_node(0, ["-walletrpcexactbalance=1"])
        for _ in range(5):
            self.generate(node, 1)
            info = node.getwalletinfo()
            assert_equal(info["balance_exact"], True)
            assert_equal(info["balance_state"], "exact")
            assert_equal(info["balance_blockhash"], node.getbestblockhash())
            assert_equal(info["balance"], node.getbalance())
            # The caller's argument wins over the option.
            self.check_poll(node.getwalletinfo(exact=False))


if __name__ == '__main__':
    PolledBalanceTest().main()
