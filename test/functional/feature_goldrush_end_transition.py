#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""The end of Gold Rush must be uneventful for a wallet and its node.

Regtest: G = 61 is the last Gold Rush block (the next block, 62, is past the
reward window). Two nodes. Node 0 holds an encrypted wallet "wm" whose claim
miner is running and a second wallet whose claim is also still unconfirmed
when block G connects.

Asserted, with the boundary heights stated explicitly:
 * both claims are evicted when G connects, and the funding inputs stay
   reserved (balance and listunspent are lower) but never silently: getbalances,
   getwalletinfo, getpowclaimrecoveryinfo and getpowmininginfo name the amount,
   the reason and the command that releases it
 * the claim miner stops after G (workers joined, state gold_rush_ended), does
   not start from -powmining after a restart, and does not log the hourly
   consolidate-outputs advice
 * a reorganisation back below G lets the miner start again and a second
   crossing stops it again
 * with the miner disabled, the standing automatic recovery policy releases
   the closed claim's input (and no policy means no fee-paying action), and the
   manual preview and commit works for the other wallet
 * the resource monitor logic raises no qualification warning after G
"""
from decimal import Decimal
import time

from test_framework.blocktools import COINBASE_MATURITY
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_raises_rpc_error

BLOCKS = 60
G = 1 + BLOCKS      # last Gold Rush block
M = G + 30          # last Migration block
ANCHOR = Decimal("10000")


class GoldRushEndTransitionTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.num_nodes = 2
        self.setup_clean_chain = True
        args = ["-allowunsafequantumkeyrpc=1", "-qqallowautokeycreation=1", "-txindex=1",
                "-staketimio=50", "-shadowwhitelistheight=1", f"-shadowgoldrushblocks={BLOCKS}",
                f"-qqgoldrushendheight={G}", f"-qqmigrationendheight={M}"]
        self.extra_args = [args, args]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    # ---- helpers
    def set_mt(self, t):
        self.mt = t
        for n in reversed(self.nodes):
            n.setmocktime(t)

    def bump(self, seconds=16):
        self.set_mt(self.mt + seconds)

    def mine(self, count, address, node=None):
        node = node or self.nodes[0]
        for _ in range(count):
            self.generatetoaddress(node, 1, address, sync_fun=self.no_op)
            self.bump()

    def log_lines(self, node, text, since=0):
        with open(node.debug_log_path, encoding="utf8", errors="replace") as f:
            f.seek(since)
            return sum(1 for line in f if text in line)

    def log_size(self, node):
        with open(node.debug_log_path, "rb") as f:
            f.seek(0, 2)
            return f.tell()

    def miner_stopped(self, wallet):
        info = wallet.getpowmininginfo()
        return (not info["enabled"] and info["workers_hashing"] == 0 and info["state"] == "gold_rush_ended")

    def run_test(self):
        node, peer = self.nodes
        self.set_mt((int(time.time()) & ~0xf) + 16)
        w0 = node.get_wallet_rpc(self.default_wallet_name)
        w0.staking(False)
        peer.get_wallet_rpc(self.default_wallet_name).staking(False)
        pow_addr = w0.getnewaddress("", "legacy")
        node.createwallet(wallet_name="wm", passphrase="pw")
        wm = node.get_wallet_rpc("wm")
        wm.walletpassphrase("pw", 100000)
        wm.staking(False)
        addr_a = wm.getnewaddress("", "legacy")
        addr_b = w0.getnewaddress("", "legacy")

        self.log.info("Fund wm (4 outputs) and the default wallet (1 output), then mature them")
        for _ in range(4):
            self.mine(1, addr_a)
        self.mine(1, addr_b)
        self.mine(COINBASE_MATURITY + 3, pow_addr)
        while node.getblockcount() < G - 1:
            self.mine(1, pow_addr)
        assert_equal(node.getblockcount(), G - 1)
        # Gold Rush is still open for the next block at tip G - 1.
        assert_equal(wm.getpowmininginfo()["gold_rush_ended"], False)
        assert_equal(wm.getpowmininginfo()["epoch_active"], True)

        pay_a = wm.getnewquantumaddress()["address"]
        pay_b = w0.getnewquantumaddress()["address"]
        claim_a = wm.sendshadowpowclaim(addr_a, pay_a, 500000)
        claim_b = w0.sendshadowpowclaim(addr_b, pay_b, 500000)
        assert claim_a["txid"] in node.getrawmempool() and claim_b["txid"] in node.getrawmempool()
        unspent_a_before = len(wm.listunspent(1, 9999999, [addr_a]))
        assert_equal(unspent_a_before, 3)
        assert "closed_claim_reserved" not in wm.getbalances()
        assert_equal(wm.getpowclaimrecoveryinfo()["closed_claim_reserved"]["amount"], Decimal("0"))

        self.log.info("Start the claim miner while a claim family is live")
        wm.setpowmining(True, 1, 1, True)
        assert wm.getpowmininginfo()["enabled"]
        workers_started = self.log_lines(node, "Gold Rush PoW worker 0 started")
        assert_equal(workers_started, 1)

        self.log.info("Connect block G, the last Gold Rush block, with both claims unconfirmed")
        self.generateblock(node, pow_addr, [], sync_fun=self.no_op)
        self.bump()
        assert_equal(node.getblockcount(), G)
        g_hash = node.getbestblockhash()
        self.sync_blocks()
        for n in (node, peer):
            assert claim_a["txid"] not in n.getrawmempool() and claim_b["txid"] not in n.getrawmempool()
        self.mine(8, pow_addr)

        self.log.info("The reserved amount is visible everywhere a user looks")
        assert_equal(wm.getpowmininginfo()["gold_rush_ended"], True)
        assert_equal(wm.getpowmininginfo()["epoch_active"], False)
        assert_equal(len(wm.listunspent(0, 9999999, [addr_a])), 3)
        assert_equal(len(w0.listunspent(0, 9999999, [addr_b])), 0)
        for wallet, expected_claims in ((wm, 1), (w0, 1)):
            reserved = wallet.getbalances()["closed_claim_reserved"]
            assert_equal(reserved["amount"], ANCHOR)
            assert_equal(reserved["claims"], expected_claims)
            assert "resolveallshadowpowclaims" in reserved["release_command"]
            assert reserved["reason"]
            assert_equal(wallet.getwalletinfo()["closed_claim_reserved"], reserved)
            assert_equal(wallet.getpowclaimrecoveryinfo()["closed_claim_reserved"], reserved)
            assert_equal(wallet.getpowmininginfo()["closed_claim_reserved"], reserved)
        assert_raises_rpc_error(-5, "not eligible for abandonment", wm.abandontransaction, claim_a["txid"])

        self.log.info("The claim miner stops itself after G and says why")
        self.wait_until(lambda: self.miner_stopped(wm))
        assert self.log_lines(node, "Gold Rush has ended at height") >= 1
        assert_equal(self.log_lines(node, "Gold Rush PoW worker 0 started"), workers_started)
        assert_raises_rpc_error(-4, "Gold Rush has ended", wm.setpowmining, True, 1, 1, True)

        self.log.info("The resource monitor logic raises no qualification warning (regtest: not applicable)")
        assert "Quantum Quasar" not in str(node.getblockchaininfo()["warnings"])
        assert "Quantum Quasar" not in str(node.getnetworkinfo()["warnings"])

        self.log.info("Reorganise below G: the miner may start again, then stops again after G returns")
        node.invalidateblock(g_hash)
        assert_equal(node.getblockcount(), G - 1)
        self.wait_until(lambda: wm.getpowmininginfo()["enabled"])
        assert_equal(wm.getpowmininginfo()["gold_rush_ended"], False)
        assert "closed_claim_reserved" not in wm.getbalances()
        node.reconsiderblock(g_hash)
        self.sync_blocks()
        assert_equal(node.getblockcount(), G + 8)
        self.wait_until(lambda: self.miner_stopped(wm))

        self.log.info("A restart after the end neither starts the miner nor repeats the capacity advice")
        mark = self.log_size(node)
        self.restart_node(0, extra_args=self.extra_args[0] + [f"-mocktime={self.mt}", "-powmining=1"])
        self.connect_nodes(0, 1)
        for name in ("wm", self.default_wallet_name):
            if name not in node.listwallets():
                node.loadwallet(name)
        wm = node.get_wallet_rpc("wm")
        w0 = node.get_wallet_rpc(self.default_wallet_name)
        self.wait_until(lambda: self.log_lines(node, "Gold Rush has ended: -powmining is ignored", mark) >= 1)
        assert_equal(self.log_lines(node, "Gold Rush PoW worker 0 started", mark), 0)
        assert_equal(self.log_lines(node, "live legacy claim source outputs", mark), 0)
        assert_equal(self.log_lines(node, "Live legacy claim source outputs", mark), 0)
        assert self.log_lines(node, "Live legacy claim source outputs") >= 1  # printed at the first load, before G
        assert_equal(wm.getpowmininginfo()["enabled"], False)
        assert_equal(wm.getpowmininginfo()["state"], "gold_rush_ended")
        assert_equal(wm.getpowmininginfo()["closed_claim_reserved"]["amount"], ANCHOR)

        self.log.info("Recovery with the miner disabled: no standing policy means no fee-paying action")
        wm.walletpassphrase("pw", 100000)
        declined = "[wm] Gold Rush claim recovery: no standing automatic policy"
        for _ in range(3):
            before = self.log_lines(node, declined)
            self.mine(1, pow_addr)
            # The maintenance pass for this tip has run and declined; only
            # then is an empty mempool evidence of "no action", not of "not yet".
            self.wait_until(lambda: self.log_lines(node, declined) > before)
        assert_equal(node.getrawmempool(), [])
        assert_equal(wm.getbalances()["closed_claim_reserved"]["amount"], ANCHOR)

        self.log.info("Recovery with the miner disabled: standing automatic policy releases the input")
        wm.setpowclaimrecovery("automatic", {"max_fee_per_resolution": "0.01", "aggregate_batch_fee_cap": "0.1",
                                             "rolling_fee_budget": "1", "rolling_fee_window_seconds": 86400,
                                             "max_actions_per_window": 10, "minimum_stale_blocks": 1})
        self.mine(1, pow_addr)
        self.wait_until(lambda: len(node.getrawmempool()) == 1, timeout=60)
        recovery_txid = node.getrawmempool()[0]
        recovery = node.getrawtransaction(recovery_txid, True)
        assert_equal(len(recovery["vin"]), 1)
        assert_equal(len(recovery["vout"]), 1)
        anchor_value = ANCHOR
        assert Decimal("0") < anchor_value - recovery["vout"][0]["value"] < Decimal("0.01")
        self.mine(2, pow_addr)
        assert_equal(len(wm.listunspent(1, 9999999, [addr_a])), 4)
        assert "closed_claim_reserved" not in wm.getbalances()
        assert_equal(wm.gettransaction(claim_a["txid"])["confirmations"] < 0, True)

        self.log.info("Manual preview and commit with the miner disabled releases the other wallet's input")
        preview = w0.resolveallshadowpowclaims()
        assert_equal(preview["actionable_components"], 1)
        w0.resolveallshadowpowclaims({"action": "commit_and_broadcast", "expected_plan_id": preview["plan_id"],
                                      "acknowledge_fee_and_conflict_risk": True})
        self.mine(2, pow_addr)
        assert_equal(len(w0.listunspent(1, 9999999, [addr_b])), 1)
        assert "closed_claim_reserved" not in w0.getbalances()

        self.log.info("Unloading a wallet whose miner the end stopped returns, and the reload leaves the miner stopped")
        node.unloadwallet("wm")
        assert "wm" not in node.listwallets()
        node.loadwallet("wm")
        wm = node.get_wallet_rpc("wm")
        self.wait_until(lambda: self.miner_stopped(wm))
        assert_equal(wm.getpowmininginfo()["gold_rush_ended"], True)


if __name__ == '__main__':
    GoldRushEndTransitionTest().main()
