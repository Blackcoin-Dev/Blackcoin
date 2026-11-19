#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Test that a crash does not make a wallet authenticate all its payouts again.

Loading a wallet authenticates every block that paid it a synthetic Gold Rush
payout against the chainstate, unless a stored checkpoint vouches for it. The
wallet's own checkpoint moves with every block the wallet processes. A node
that dies without a shutdown restarts its chain at the last chainstate flush,
which is behind the wallet, so that checkpoint names a block that is not on
the active chain and cannot be used. A second checkpoint, anchored at the last
chainstate flush, covers that case.

The node is killed after the wallet has processed payout blocks past the last
chainstate flush, and the restart must

- authenticate nothing at or below the flushed block,
- read the chainstate far less than a full authentication does,
- end, after the lost blocks are synced again from a peer, with the balances,
  transactions and payout records of before the kill, equal to a full rescan,
- authenticate only the payout blocks above the flush-anchored checkpoint when
  the chain restarts above it,
- still authenticate everything when the flushed block itself left the active
  chain (a reorg across the checkpoint),
- work when no chainstate flush happened since the wallet was loaded (the
  checkpoint written at load is anchored at the block the chainstate holds on
  disk),
- and a clean stop and start still authenticates nothing.
"""

import re
import time

try:
    import sqlite3
except ImportError:
    pass

from test_framework.blocktools import COINBASE_MATURITY
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal

SHADOW_GOLD_RUSH_BLOCKS = 500
GOLD_RUSH_END_HEIGHT = 1 + SHADOW_GOLD_RUSH_BLOCKS
MIGRATION_END_HEIGHT = GOLD_RUSH_END_HEIGHT + 10
WALLET_NAME = "payout_crash"
FLUSHED_PAYOUT_BLOCKS = 12
UNFLUSHED_PAYOUT_BLOCKS = 4
MIDDLE_PAYOUT_BLOCKS = 2
REORG_DEPTH = 3
CHECKPOINT_KEY = b"\x19syntheticpayoutcheckpoint"
FLUSH_CHECKPOINT_KEY = b"\x1esyntheticpayoutflushcheckpoint"
CHECK_LINE = re.compile(
    r"Gold Rush payout check: (\d+) payout blocks authenticated, (\d+) already verified through height (-?\d+)")
# One line per stored checkpoint record at load: accepted, rejected with the reason, or none stored.
VERDICT_LINE = re.compile(
    r"Gold Rush payout checkpoint \((wallet tip|chainstate flush)\): (none stored|height -?\d+, \d+ payout records: (accepted|rejected, .*)) \(chain height -?\d+\)")
VERDICTS = ["none stored", "accepted", "not in the block index", "not on the active chain", "count mismatch", "digest mismatch",
            "unknown schema", "client version", "no height"]
PAYOUT_COMMENT = "PoS - Quantum Stake"


class WalletGoldRushPayoutCrashCheckpointTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.num_nodes = 2
        self.setup_clean_chain = True
        self.node_args = [
            "-allowunsafequantumkeyrpc=1",
            "-txindex=1",
            "-staketimio=20",
            "-autostartstaking=0",
            "-qqautoshadowsignal=1",
            "-shadowwhitelistheight=1",
            f"-shadowgoldrushblocks={SHADOW_GOLD_RUSH_BLOCKS}",
            f"-qqgoldrushendheight={GOLD_RUSH_END_HEIGHT}",
            f"-qqmigrationendheight={MIGRATION_END_HEIGHT}",
        ]
        self.extra_args = [self.node_args, self.node_args]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()
        self.skip_if_no_sqlite()
        self.skip_if_no_py_sqlite3()

    def _set_mocktime(self, timestamp, peer=True):
        self.mock_time = timestamp
        self.nodes[0].setmocktime(timestamp)
        if peer:
            self.nodes[1].setmocktime(timestamp)

    def _mine_pos_block(self, wallet):
        node = self.nodes[0]
        start_height = node.getblockcount()
        # The staker can miss the kernel the search found (it samples the clock on its own
        # schedule), so search again from where the clock stands instead of failing.
        for attempt in range(4):
            inputs = [{"txid": utxo["txid"], "vout": utxo["vout"]} for utxo in wallet.listunspent(1, 9999999)]
            for _ in range(3000):
                self._set_mocktime(self.mock_time + 16, peer=False)
                kernel = wallet.checkkernel(inputs)
                if kernel["found"]:
                    kernel_time = kernel["kernel"]["time"]
                    break
            else:
                raise AssertionError("timed out searching for a deterministic PoS kernel")
            self._set_mocktime(kernel_time - 16, peer=False)
            wallet.staking(True)
            try:
                self._set_mocktime(kernel_time)
                self.wait_until(lambda: node.getblockcount() > start_height, timeout=20)
                break
            except AssertionError:
                if attempt == 3:
                    raise
                self.log.info("the staker did not use the kernel found; searching again")
            finally:
                wallet.staking(False)
        node.syncwithvalidationinterfacequeue()

    def _mine_payout_blocks(self, wallet, count):
        for _ in range(count):
            self._mine_pos_block(wallet)
        self.sync_blocks()

    def _snapshot(self, wallet):
        """Everything a user can see that payout authentication could influence."""
        self.nodes[0].syncwithvalidationinterfacequeue()
        unspent = sorted(
            wallet.listunspent(0, 9999999, [], True, {"include_immature_coinbase": True}),
            key=lambda utxo: (utxo["txid"], utxo["vout"]))
        transactions = sorted(
            wallet.listtransactions("*", 100000, 0, True),
            key=lambda tx: (tx["txid"], tx["vout"], tx["category"]))
        goldrush = wallet.getgoldrushinfo()
        return {
            "balances": wallet.getbalances(),
            "txcount": wallet.getwalletinfo()["txcount"],
            "unspent": unspent,
            "transactions": transactions,
            "pos_count": goldrush["pos_count"],
            "last_pos_height": goldrush["last_pos_height"],
        }

    def _assert_same(self, left, right):
        for key in left:
            if left[key] != right[key]:
                if isinstance(left[key], list):
                    only_left = [x for x in left[key] if x not in right[key]]
                    only_right = [x for x in right[key] if x not in left[key]]
                    raise AssertionError(f"{key} differs: {len(only_left)} only before: {only_left[:2]} / {len(only_right)} only after: {only_right[:2]}")
                raise AssertionError(f"{key} differs: {left[key]} != {right[key]}")

    @staticmethod
    def _payout_heights(snapshot):
        """Heights of the blocks that hold a confirmed payout of the wallet."""
        return sorted({
            tx["blockheight"] for tx in snapshot["transactions"]
            if tx.get("comment") == PAYOUT_COMMENT and tx.get("confirmations", 0) > 0
        })

    @staticmethod
    def _chainstate_reads(counters):
        return counters["chainstate_get_coin"] + counters["chainstate_have_coin"]

    @staticmethod
    def _parse_payout_check(text):
        """From the log of one load of the wallet: (authenticated, already verified, verified through height)
        and what the load said of each checkpoint record, as {"wallet tip": ..., "chainstate flush": ...}."""
        lines = [line for line in text.splitlines() if f"[{WALLET_NAME}]" in line]
        found = [match for match in (CHECK_LINE.search(line) for line in lines) if match]
        assert_equal(len(found), 1)
        verdicts = {}
        for match in (VERDICT_LINE.search(line) for line in lines):
            if match:
                assert match.group(1) not in verdicts
                codes = [code for code in VERDICTS if code in match.group(2)]
                assert_equal(len(codes), 1)
                verdicts[match.group(1)] = codes[0]
        assert_equal(sorted(verdicts), ["chainstate flush", "wallet tip"])
        return tuple(int(group) for group in found[0].groups()), verdicts

    def _load_wallet(self, flush_checkpoint_used):
        """Load the wallet. Returns (authenticated, already verified, verified through height) and the chainstate reads it took.

        flush_checkpoint_used: whether the load must report that the wallet's own checkpoint
        was not accepted and the flush-anchored one was."""
        node = self.nodes[0]
        with open(node.debug_log_path, "rb") as log:
            log.seek(0, 2)
            offset = log.tell()
        reads_before = self._chainstate_reads(node.getiocounters())
        node.loadwallet(WALLET_NAME)
        reads = self._chainstate_reads(node.getiocounters()) - reads_before
        with open(node.debug_log_path, "rb") as log:
            log.seek(offset)
            text = log.read().decode("utf-8", "replace")
        result, verdicts = self._parse_payout_check(text)
        self.last_verdicts = verdicts
        assert_equal(verdicts["wallet tip"] != "accepted" and verdicts["chainstate flush"] == "accepted", flush_checkpoint_used)
        # A record is used exactly when the load says it accepted one.
        assert_equal("accepted" in verdicts.values(), result[2] >= 0)
        return result, reads

    def _kill_node(self):
        """End the node as a power cut would: no shutdown, so no chainstate flush."""
        node = self.nodes[0]
        node.process.kill()
        node.process.wait(timeout=node.rpc_timeout)
        node.stdout.close()
        node.stderr.close()
        node.running = False
        node.process = None
        node.rpc_connected = False
        node.rpc = None

    def _start(self):
        """Start the node without its peer and without the wallet."""
        self.start_node(0, self.node_args)
        self.nodes[0].setmocktime(self.mock_time)

    def _resync(self):
        """Fetch the blocks the kill lost from the peer. Returns the wallet."""
        self.connect_nodes(0, 1)
        self.sync_blocks()
        self.nodes[0].syncwithvalidationinterfacequeue()
        return self.nodes[0].get_wallet_rpc(WALLET_NAME)

    def _edit_records(self, edits):
        """With the node stopped, apply {key: value or None (delete)} to the wallet database."""
        db_path = self.nodes[0].wallets_path / WALLET_NAME / self.wallet_data_filename
        conn = sqlite3.connect(db_path)
        with conn:
            for key, value in edits.items():
                if value is None:
                    conn.execute("DELETE FROM main WHERE key = ?", (key,))
                else:
                    conn.execute("INSERT OR REPLACE INTO main VALUES(?, ?)", (key, value))
        conn.close()

    def _read_record(self, key):
        db_path = self.nodes[0].wallets_path / WALLET_NAME / self.wallet_data_filename
        conn = sqlite3.connect(db_path)
        row = conn.execute("SELECT value FROM main WHERE key = ?", (key,)).fetchone()
        conn.close()
        return None if row is None else bytes(row[0])

    def _flush_chainstate(self):
        """Flush the chainstate where it is, as the periodic flush does, and let the wallet hear of it."""
        node = self.nodes[0]
        node.gettxoutsetinfo()
        node.syncwithvalidationinterfacequeue()
        return node.getblockcount()

    def _kill_behind_wallet(self, wallet):
        """Mine payout blocks past the last chainstate flush and kill the node. Returns the state before the kill."""
        node = self.nodes[0]
        self._mine_payout_blocks(wallet, UNFLUSHED_PAYOUT_BLOCKS)
        before = self._snapshot(wallet)
        height = node.getblockcount()
        assert_equal(wallet.getwalletinfo()["lastprocessedblock"]["height"], height)
        self._kill_node()
        return before, height

    def run_test(self):
        node = self.nodes[0]
        self._set_mocktime((int(time.time()) & ~0xf) + 16)
        node.get_wallet_rpc(self.default_wallet_name).staking(False)
        node.createwallet(wallet_name=WALLET_NAME)
        wallet = node.get_wallet_rpc(WALLET_NAME)
        wallet.staking(False)
        signal_address = wallet.getnewaddress("", "legacy")

        self.log.info("Creating a whitelisted wallet that stakes into an active Gold Rush signal")
        self.generatetoaddress(node, 1, signal_address)
        self.generatetoaddress(node, COINBASE_MATURITY + 50, signal_address)
        self._set_mocktime((node.getblockheader(node.getbestblockhash())["time"] & ~0xf) + 16)
        wallet.getnewquantumaddress("goldrush-pos")
        self._mine_payout_blocks(wallet, FLUSHED_PAYOUT_BLOCKS + 1)

        self.log.info("Kill the node after the wallet processed payout blocks past the last chainstate flush")
        flushed_height = self._flush_chainstate()
        flushed_payouts = len(self._payout_heights(self._snapshot(wallet)))
        assert flushed_payouts >= FLUSHED_PAYOUT_BLOCKS
        before, height_before_kill = self._kill_behind_wallet(wallet)
        total_payouts = len(self._payout_heights(before))
        assert_equal(total_payouts, flushed_payouts + UNFLUSHED_PAYOUT_BLOCKS)

        self._start()
        assert_equal(node.getblockcount(), flushed_height)
        assert flushed_height < height_before_kill, "the kill must lose unflushed blocks for this test to mean anything"
        result, crash_reads = self._load_wallet(flush_checkpoint_used=True)
        self.log.info(f"after the kill: {result[0]} payout blocks authenticated, {result[1]} already verified through height {result[2]} "
                      f"(wallet holds {total_payouts} payout blocks, {flushed_payouts} at or below the flushed height {flushed_height}); "
                      f"{crash_reads} chainstate reads while loading")
        # Every payout block on the restarted chain is at or below the flushed block and is vouched for.
        assert_equal(result, (0, flushed_payouts, flushed_height))
        # The restarted node does not know the block the wallet stands on.
        assert_equal(self.last_verdicts["wallet tip"], "not in the block index")
        wallet = node.get_wallet_rpc(WALLET_NAME)
        # The payouts of the lost blocks are not confirmed (and so not spendable) until their blocks are back.
        assert_equal(len(self._payout_heights(self._snapshot(wallet))), flushed_payouts)

        self.log.info("The lost blocks come back from the peer: same wallet as before the kill, equal to a full rescan")
        wallet = self._resync()
        self._assert_same(before, self._snapshot(wallet))
        wallet.rescanblockchain(0)
        self._assert_same(before, self._snapshot(wallet))

        self.log.info("A clean stop and start authenticates nothing")
        self.stop_node(0)
        self._start()
        result, clean_reads = self._load_wallet(flush_checkpoint_used=False)
        assert_equal(result, (0, total_payouts, height_before_kill))
        wallet = node.get_wallet_rpc(WALLET_NAME)
        self._assert_same(before, self._snapshot(wallet))

        self.log.info("Without any checkpoint the same wallet authenticates every payout block (the cost a crash used to have)")
        self.stop_node(0)
        saved = {key: self._read_record(key) for key in (CHECKPOINT_KEY, FLUSH_CHECKPOINT_KEY)}
        assert saved[CHECKPOINT_KEY] is not None, "wallet did not store a payout checkpoint"
        assert saved[FLUSH_CHECKPOINT_KEY] is not None, "wallet did not store a flush-anchored payout checkpoint"
        self._edit_records({CHECKPOINT_KEY: None, FLUSH_CHECKPOINT_KEY: None})
        self._start()
        result, full_reads = self._load_wallet(flush_checkpoint_used=False)
        assert_equal(result, (total_payouts, 0, -1))
        assert_equal(self.last_verdicts, {"wallet tip": "none stored", "chainstate flush": "none stored"})
        self.log.info(f"chainstate reads while loading: {crash_reads} after the kill, {clean_reads} after a clean stop, "
                      f"{full_reads} for a full authentication of {total_payouts} payout blocks")
        # A full authentication reads the chainstate at least once per payout block. The
        # load after the kill must not: it stays at what a clean start reads.
        assert full_reads >= clean_reads + total_payouts
        assert crash_reads <= clean_reads + UNFLUSHED_PAYOUT_BLOCKS, f"{crash_reads} chainstate reads after the kill, {clean_reads} after a clean stop"
        wallet = node.get_wallet_rpc(WALLET_NAME)
        self._assert_same(before, self._snapshot(wallet))

        self.log.info("The wallet's own checkpoint alone still serves a clean start; a corrupt flush checkpoint is ignored")
        self.stop_node(0)
        flush_record = self._read_record(FLUSH_CHECKPOINT_KEY)
        assert flush_record is not None, "loading the wallet must store the flush-anchored checkpoint again"
        self._edit_records({FLUSH_CHECKPOINT_KEY: flush_record[:-1] + bytes([flush_record[-1] ^ 0xff])})
        self._start()
        result, _ = self._load_wallet(flush_checkpoint_used=False)
        assert_equal(result, (0, total_payouts, height_before_kill))
        assert_equal(self.last_verdicts, {"wallet tip": "accepted", "chainstate flush": "digest mismatch"})

        self.log.info("No chainstate flush since the wallet was loaded: the checkpoint written at load covers the kill")
        # The clean stop flushed the chainstate; remove the record the wallet wrote then, so
        # that only the one written when the wallet is loaded can serve after the kill.
        self.stop_node(0)
        self._edit_records({FLUSH_CHECKPOINT_KEY: None})
        self._start()
        result, _ = self._load_wallet(flush_checkpoint_used=False)
        assert_equal(result, (0, total_payouts, height_before_kill))
        wallet = self._resync()
        flushed_height = node.getblockcount()
        flushed_payouts = total_payouts
        before, height_before_kill = self._kill_behind_wallet(wallet)
        total_payouts = len(self._payout_heights(before))
        self._start()
        assert_equal(node.getblockcount(), flushed_height)
        result, _ = self._load_wallet(flush_checkpoint_used=True)
        assert_equal(result, (0, flushed_payouts, flushed_height))
        wallet = self._resync()
        self._assert_same(before, self._snapshot(wallet))

        self.log.info("A flush-anchored checkpoint below the restarted chain: only the payout blocks above it are authenticated")
        # As when the process dies between a chainstate flush and the wallet hearing of it:
        # the chain restarts at the newer flush and the wallet still has the older record.
        self.stop_node(0)
        older_record = self._read_record(FLUSH_CHECKPOINT_KEY)
        older_height = height_before_kill
        older_payouts = total_payouts
        self._start()
        result, _ = self._load_wallet(flush_checkpoint_used=False)
        assert_equal(result, (0, older_payouts, older_height))
        wallet = self._resync()
        self._mine_payout_blocks(wallet, MIDDLE_PAYOUT_BLOCKS)
        flushed_height = self._flush_chainstate()
        before, height_before_kill = self._kill_behind_wallet(wallet)
        total_payouts = len(self._payout_heights(before))
        assert self._read_record(FLUSH_CHECKPOINT_KEY) != older_record
        self._edit_records({FLUSH_CHECKPOINT_KEY: older_record})
        self._start()
        assert_equal(node.getblockcount(), flushed_height)
        result, _ = self._load_wallet(flush_checkpoint_used=True)
        self.log.info(f"{result[0]} payout blocks authenticated, {result[1]} already verified through height {result[2]}, of {total_payouts}")
        assert_equal(result, (MIDDLE_PAYOUT_BLOCKS, older_payouts, older_height))
        wallet = self._resync()
        self._assert_same(before, self._snapshot(wallet))
        wallet.rescanblockchain(0)
        self._assert_same(before, self._snapshot(wallet))

        self.log.info("A reorg across the flushed block after a kill: both checkpoints are rejected, everything is authenticated")
        flushed_height = self._flush_chainstate()
        before, height_before_kill = self._kill_behind_wallet(wallet)
        total_payouts = len(self._payout_heights(before))
        self._start()
        assert_equal(node.getblockcount(), flushed_height)
        fork_height = flushed_height - REORG_DEPTH
        invalidated = node.getblockhash(fork_height + 1)
        node.invalidateblock(invalidated)
        assert_equal(node.getblockcount(), fork_height)
        remaining_payouts = len([h for h in self._payout_heights(before) if h <= fork_height])
        assert remaining_payouts > 0
        result, _ = self._load_wallet(flush_checkpoint_used=False)
        assert_equal(result, (remaining_payouts, 0, -1))
        # The wallet's block is unknown to the restarted node; the flushed block is known and was reorged out.
        assert_equal(self.last_verdicts, {"wallet tip": "not in the block index", "chainstate flush": "not on the active chain"})
        wallet = node.get_wallet_rpc(WALLET_NAME)
        assert_equal(len(self._payout_heights(self._snapshot(wallet))), remaining_payouts)

        self.log.info("The chain comes back: same wallet as before the kill, equal to a full rescan, and the next start is fast again")
        node.reconsiderblock(invalidated)
        wallet = self._resync()
        self._assert_same(before, self._snapshot(wallet))
        wallet.rescanblockchain(0)
        self._assert_same(before, self._snapshot(wallet))
        self.stop_node(0)
        self._start()
        result, _ = self._load_wallet(flush_checkpoint_used=False)
        assert_equal(result, (0, total_payouts, height_before_kill))
        self._assert_same(before, self._snapshot(node.get_wallet_rpc(WALLET_NAME)))


if __name__ == '__main__':
    WalletGoldRushPayoutCrashCheckpointTest().main()
