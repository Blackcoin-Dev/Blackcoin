#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Stale automatic attestations are cleaned up, and the automatic path recovers, across a reorganisation and a restart.

One key (the target) is attested by the automatic path (P1) and, while P1 is only in the wallet (the node
restarted without its mempool), by a manual attestation (P2) over the same state. Then:

 * P2 confirms and a reorganisation disconnects it: P2 is back in the mempool and the key's state is the
   one both transactions reference again. P1 is still usable, so it is kept (not abandoned), it is not
   offered while P2 holds the key in the mempool, and nothing new is signed;
 * the node restarts without its mempool: both are only in the wallet and usable; exactly one of them is
   offered again, and still nothing new is signed;
 * the offered one confirms. The other now references a state the key no longer has. Once the key is due
   again the automatic path abandons it if it made it (and keeps it if it is the manual one, which it never
   cleans up), signs one new attestation from the released inputs, and that one confirms.

Regtest with a compressed demurrage month (four blocks), activation at height 27.
"""
from decimal import Decimal
import time

from test_framework.blocktools import COINBASE_MATURITY
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal

GOLD_RUSH_END_TIME = 2_000_000_000
GOLD_RUSH_END_HEIGHT = 11
MIGRATION_END_HEIGHT = 26
DEMURRAGE_ACTIVATION_HEIGHT = 27
AUTO_ATTEST_BLOCKS = 12  # three months of four blocks
COMMENT = "Quantum Quasar demurrage auto-attestation"


class DemurrageAutoAttestStaleCleanupTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.base_args = [
            "-allowunsafequantumkeyrpc=1",
            "-txindex=1",
            "-staketimio=50",
            "-donatetodevfund=0",
            "-qqallowautokeycreation=1",
            "-shadowwhitelistheight=1",
            "-shadowgoldrushblocks=10",
            f"-qqgoldrushendheight={GOLD_RUSH_END_HEIGHT}",
            f"-qqmigrationendheight={MIGRATION_END_HEIGHT}",
            "-qqstaketierheight=1",
            "-qqstakesplitheight=1",
            f"-qqdemurrageheight={DEMURRAGE_ACTIVATION_HEIGHT}",
            "-qqdemurrageblockspermonth=4",
            "-rpcserialversion=1",  # raw transaction hex keeps the quantum witness
        ]
        self.extra_args = [self.base_args + ["-qqautodemurrageattest=1"]]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def set_mt(self, t):
        self.mt = t
        self.nodes[0].setmocktime(t)

    def generate(self, count, address):
        for _ in range(count):
            self.generatetoaddress(self.nodes[0], 1, address, sync_fun=self.no_op)
            self.set_mt(self.mt + 16)

    def log_count(self, text):
        with open(self.nodes[0].debug_log_path, encoding="utf8", errors="replace") as f:
            return sum(1 for line in f if text in line)

    def automatic(self, wallet, live_only=True):
        """Wallet transactions made by the automatic path (abandoned ones included unless live_only)."""
        txids = set()
        for entry in wallet.listtransactions("*", 1000, 0, True):
            if entry.get("comment") == COMMENT and not (live_only and entry.get("abandoned")):
                txids.add(entry["txid"])
        return txids

    def run_test(self):
        node = self.nodes[0]
        self.set_mt((int(time.time()) & ~0xf) + 16)
        node.get_wallet_rpc(self.default_wallet_name).staking(False)
        node.createwallet(wallet_name="fund", load_on_startup=True)
        node.createwallet(wallet_name="auto", load_on_startup=True)
        fund = node.get_wallet_rpc("fund")
        auto = node.get_wallet_rpc("auto")
        fund.staking(False)
        auto.staking(False)
        funder = fund.getnewaddress("", "legacy")
        mining = fund.getnewquantumaddress()["address"]
        target = auto.getnewquantumaddress()["address"]

        self.set_mt(GOLD_RUSH_END_TIME + 16)
        self.generate(COINBASE_MATURITY + 2, funder)
        for amount in (Decimal("9"), Decimal("1"), Decimal("1"), Decimal("1"), Decimal("1")):  # the target and fee inputs
            fund.sendtoaddress(target, amount)
        self.generate(1, funder)
        while node.getblockcount() < DEMURRAGE_ACTIVATION_HEIGHT + AUTO_ATTEST_BLOCKS + 1:
            self.generate(1, mining)
        assert_equal(auto.getdemurragewalletinfo()["demurrage_active"], True)

        self.last_stderr = ""

        def restart(extra, drop_mempool=False):
            self.stop_node(0, expected_stderr=self.last_stderr)
            if drop_mempool:
                (node.chain_path / "mempool.dat").unlink(missing_ok=True)  # the dump the stopped node wrote
            self.start_node(0, extra_args=self.base_args + [f"-mocktime={self.mt}"] + extra)
            self.set_mt(self.mt)
            node.get_wallet_rpc(self.default_wallet_name).staking(False)
            node.get_wallet_rpc("fund").staking(False)
            return node.get_wallet_rpc("auto")

        def run_auto(wallet, done, timeout=60):
            """Let the automatic path run until `done()` holds (it runs while staking is on)."""
            wallet.staking(True)
            try:
                self.wait_until(done, timeout=timeout)
            finally:
                wallet.staking(False)

        def abandoned(wallet, txid):
            # The flag is on the per-output entries of gettransaction, not on the transaction itself.
            details = wallet.gettransaction(txid)["details"]
            assert details, "the wallet lists no entry for the transaction"
            assert all("abandoned" in d for d in details), details
            return any(d["abandoned"] for d in details)

        self.log.info("The automatic path signs one attestation (P1) for the one due key")
        before = set(node.getrawmempool())
        run_auto(auto, lambda: len(self.automatic(auto)) >= 1 and len(set(node.getrawmempool()) - before) >= 1)
        (p1,) = self.automatic(auto)
        assert p1 in node.getrawmempool()

        self.log.info("The node restarts with wallet broadcasting off: P1 is only in the wallet, not in the mempool")
        auto = restart(["-walletbroadcast=0", "-qqautodemurrageattest=0"], drop_mempool=True)
        assert p1 not in node.getrawmempool()
        assert_equal(auto.gettransaction(p1)["confirmations"], 0)

        self.log.info("A manual attestation (P2) for the same key confirms")
        p2 = auto.senddemurrageattestation(target)["txid"]
        assert p2 != p1 and p2 not in node.getrawmempool()  # not broadcast by the wallet
        assert p2 not in self.automatic(auto)
        node.sendrawtransaction(auto.gettransaction(p2)["hex"])
        assert p2 in node.getrawmempool()
        self.generate(1, mining)
        assert_equal(auto.gettransaction(p2)["confirmations"], 1)
        p2_block = auto.gettransaction(p2)["blockhash"]

        self.log.info("A reorganisation disconnects P2: P1 is still usable, kept, and nothing new is signed")
        node.invalidateblock(p2_block)
        assert p2 in node.getrawmempool()
        auto = restart(["-walletbroadcast=0", "-qqautodemurrageattest=1"])
        assert p2 in node.getrawmempool(), "the mempool was persisted"
        assert p1 not in node.getrawmempool()
        seen = self.log_count("Demurrage auto-attest suppressed for key")
        run_auto(auto, lambda: self.log_count("Demurrage auto-attest suppressed for key") > seen)
        assert not abandoned(auto, p1)
        assert p1 not in node.getrawmempool()
        assert_equal(self.automatic(auto), {p1})
        assert_equal(auto.gettransaction(p2)["confirmations"], 0)

        self.log.info("Restart without the mempool, broadcasting on: both are in the wallet; exactly one is in the mempool, nothing new is signed")
        auto = restart(["-persistmempool=0", "-qqautodemurrageattest=1"])
        run_auto(auto, lambda: len({p1, p2} & set(node.getrawmempool())) == 1)
        winner = ({p1, p2} & set(node.getrawmempool())).pop()
        loser = p1 if winner == p2 else p2
        assert_equal(len({p1, p2} & set(node.getrawmempool())), 1)
        assert not abandoned(auto, p1) and not abandoned(auto, p2)
        assert_equal(self.automatic(auto), {p1})
        self.log.info("The one in the mempool is %s; the other will go stale", "P1 (automatic)" if winner == p1 else "P2 (manual)")

        self.log.info("The offered one confirms; the other references a state the key no longer has")
        self.generate(1, mining)
        assert_equal(auto.gettransaction(winner)["confirmations"], 1)
        assert_equal(auto.gettransaction(loser)["confirmations"], 0)
        # Not due yet: nothing is cleaned up or signed.
        self.generate(AUTO_ATTEST_BLOCKS, mining)

        self.log.info("The key is due again: a stale automatic attestation is abandoned, a manual one kept, and one new one confirms")
        auto = restart(["-persistmempool=0", "-qqautodemurrageattest=1"])
        run_auto(auto, lambda: len(self.automatic(auto) - {p1}) >= 1 and len(set(node.getrawmempool()) & (self.automatic(auto) - {p1})) >= 1)
        new_automatic = self.automatic(auto) - {p1}
        assert_equal(len(new_automatic), 1)
        (p3,) = new_automatic
        assert p3 in node.getrawmempool()
        if loser == p1:
            assert abandoned(auto, p1), "the stale automatic attestation is abandoned"
        else:
            assert not abandoned(auto, p2), "a manual attestation is never cleaned up automatically"
            assert_equal(auto.gettransaction(p2)["confirmations"], 0)
        self.generate(1, mining)
        assert_equal(auto.gettransaction(p3)["confirmations"], 1)
        # And nothing more is signed for the key now.
        assert_equal(len(self.automatic(auto, live_only=False) - {p1, p3}), 0)

        self.log.info("Second round (the fee inputs are the change of the first round, still inside their grace period): an automatic attestation that is only in the wallet is made stale by a manual one")
        self.generate(AUTO_ATTEST_BLOCKS, mining)  # the key is due again
        auto = restart(["-walletbroadcast=0", "-qqautodemurrageattest=1"])
        run_auto(auto, lambda: len(self.automatic(auto) - {p1, p3}) >= 1)
        (p4,) = self.automatic(auto) - {p1, p3}
        assert p4 not in node.getrawmempool(), "broadcasting is off"
        auto = restart(["-walletbroadcast=0", "-qqautodemurrageattest=0"])
        p5 = auto.senddemurrageattestation(target)["txid"]
        assert p5 not in (p1, p2, p3, p4)
        node.sendrawtransaction(auto.gettransaction(p5)["hex"])
        self.generate(1, mining)
        assert_equal(auto.gettransaction(p5)["confirmations"], 1)
        assert_equal(auto.gettransaction(p4)["confirmations"], 0)
        assert not abandoned(auto, p4)
        self.generate(AUTO_ATTEST_BLOCKS, mining)  # due again, and P4 now references a state the key no longer has
        auto = restart(["-persistmempool=0", "-qqautodemurrageattest=1"])
        run_auto(auto, lambda: abandoned(auto, p4) and len(self.automatic(auto) - {p1, p3, p4}) >= 1)
        assert abandoned(auto, p4), "the stale automatic attestation is abandoned"
        (p6,) = self.automatic(auto) - {p1, p3}
        assert p6 != p4
        self.wait_until(lambda: p6 in node.getrawmempool(), timeout=30)
        self.generate(1, mining)
        assert_equal(auto.gettransaction(p6)["confirmations"], 1)
        # The manual attestation that went stale in the first round was never cleaned up.
        if loser == p2:
            assert not abandoned(auto, p2)


if __name__ == '__main__':
    DemurrageAutoAttestStaleCleanupTest().main()
