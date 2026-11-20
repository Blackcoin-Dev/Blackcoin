#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Test the payout checkpoint across two crashes with no chainstate flush between them.

The sequence, as a mining node on a slow disk met it:

- the chainstate was last flushed at height F; the wallet and the block files
  are well past F, with payouts in those blocks; the node dies (crash 1);
- it starts again with no peer. The wallet loads while the chain stands at F
  and stores its payout checkpoints. Then the node connects the blocks above F
  that it has on disk and the wallet processes them. Nothing flushes the
  chainstate;
- the node dies again (crash 2) and starts again: the chain stands at F once
  more, the wallet's own checkpoint names a block far above it, and the only
  record that can keep the start from authenticating every payout is the
  flush-anchored one that the first restart stored when it loaded the wallet.

The second restart must authenticate nothing at or below F. This is run from
both forms a crash can leave behind (the blocks above F are in the block index,
because the hourly block index write covered them, or they are only in the
block files), from a wallet that had no flush-anchored checkpoint before the
first restart (as written by an earlier release), with the second crash while
the wallet is still processing the blocks above F, and with a chainstate flush
between the two crashes.
"""

import re
import shutil
import time

from test_framework.blocktools import COINBASE_MATURITY
from test_framework.util import assert_equal
from wallet_goldrush_payout_crash_checkpoint import (
    FLUSH_CHECKPOINT_KEY,
    WALLET_NAME,
    WalletGoldRushPayoutCrashCheckpointTest,
)

FLUSHED_PAYOUT_BLOCKS = 12
# Far enough past the flush that the wallet's best block locator does not hold
# the flushed block, so that a restart that does not know the blocks above it
# rescans at attach, as a node hundreds of blocks behind its wallet does.
UNFLUSHED_PAYOUT_BLOCKS = 13
LATER_PAYOUT_BLOCKS = 3
# Per wallet commit, to give the test time to kill the node between two blocks.
SLOW_WALLET_COMMIT_US = 300000


class WalletGoldRushPayoutDoubleCrashTest(WalletGoldRushPayoutCrashCheckpointTest):
    def set_test_params(self):
        super().set_test_params()
        # The slow wallet commits of one case stretch every wait.
        self.rpc_timeout = 240

    def _alone_args(self, extra):
        # The clock is set from the start: the node connects its blocks before any RPC can set it.
        return [*self.node_args, "-connect=0", f"-wallet={WALLET_NAME}", f"-mocktime={self.mock_time}", *extra]

    def _log_since_start(self):
        with open(self.nodes[0].debug_log_path, "rb") as log:
            log.seek(self.start_log_offset)
            return log.read().decode("utf-8", "replace")

    def _start_alone(self, extra=()):
        """Start the node with no peer and with the wallet loaded during start, as a node
        loads it. Returns what that load said of the payout check."""
        node = self.nodes[0]
        self.start_log_offset = node.debug_log_path.stat().st_size
        self.start_node(0, self._alone_args(extra))
        text = self._log_since_start()
        assert "Gold Rush payout checkpoints stored: " in text, "the load must say which checkpoints it stored"
        return self._parse_payout_check(text)

    def _wallet_height(self):
        return self.nodes[0].get_wallet_rpc(WALLET_NAME).getwalletinfo()["lastprocessedblock"]["height"]

    def _highest_block_recorded(self):
        """The highest block the wallet has recorded a transaction of since the last start, from its log."""
        heights = [int(height) for height in re.findall(
            rf"\[{WALLET_NAME}\] AddToWallet [0-9a-f]+ +update Confirmed \(block=[0-9a-f]+, height=(\d+),", self._log_since_start())]
        return max(heights, default=-1)

    def _crash_behind_wallet(self, blocks_in_index, earlier_release_wallet):
        """Leave the node dead with the chainstate at a flushed height and the wallet and the
        block files UNFLUSHED_PAYOUT_BLOCKS past it. Returns what the restarts are checked against."""
        node = self.nodes[0]
        wallet = node.get_wallet_rpc(WALLET_NAME)
        state = {"start_args": []}
        if blocks_in_index:
            # What a kill leaves when the hourly block index write covered the blocks above
            # the chainstate flush: a clean stop writes the block index, and the chainstate
            # of the flushed height is put back under it.
            self.stop_node(0)
            chainstate = node.chain_path / "chainstate"
            flushed_chainstate = node.chain_path / "chainstate.flushed"
            shutil.rmtree(flushed_chainstate, ignore_errors=True)
            shutil.copytree(chainstate, flushed_chainstate)
            flush_record = self._read_record(FLUSH_CHECKPOINT_KEY)
            self._start()
            node.loadwallet(WALLET_NAME)
            wallet = self._resync()
            state["flushed_height"] = node.getblockcount()
            state["flushed_payouts"] = len(self._payout_heights(self._snapshot(wallet)))
            self._mine_payout_blocks(wallet, UNFLUSHED_PAYOUT_BLOCKS)
            state["before"] = self._snapshot(wallet)
            state["height"] = node.getblockcount()
            self.stop_node(0)
            shutil.rmtree(chainstate)
            shutil.copytree(flushed_chainstate, chainstate)
            self._edit_records({FLUSH_CHECKPOINT_KEY: None if earlier_release_wallet else flush_record})
        else:
            # A kill with the blocks above the flush in the block files only. The node has
            # no peer to fetch them from again, so it is given a copy of its own block file.
            state["flushed_height"] = self._flush_chainstate()
            state["flushed_payouts"] = len(self._payout_heights(self._snapshot(wallet)))
            self._mine_payout_blocks(wallet, UNFLUSHED_PAYOUT_BLOCKS)
            state["before"] = self._snapshot(wallet)
            state["height"] = node.getblockcount()
            self._kill_node()
            own_blocks = node.chain_path / "own-blocks.dat"
            shutil.copyfile(node.chain_path / "blocks" / "blk00000.dat", own_blocks)
            state["start_args"] = [f"-loadblock={own_blocks}"]
            if earlier_release_wallet:
                self._edit_records({FLUSH_CHECKPOINT_KEY: None})
        state["total_payouts"] = len(self._payout_heights(state["before"]))
        assert_equal(state["total_payouts"], state["flushed_payouts"] + UNFLUSHED_PAYOUT_BLOCKS)
        return state

    def _first_restart(self, state, earlier_release_wallet, extra=()):
        """Restart after crash 1 with no peer: the wallet loads at the flushed height."""
        result, verdicts = self._start_alone([*state["start_args"], *extra])
        if earlier_release_wallet:
            # Nothing can vouch yet: this start pays the full authentication, once.
            assert_equal(result, (state["flushed_payouts"], 0, -1))
            assert_equal(verdicts["chainstate flush"], "none stored")
        else:
            assert_equal(result, (0, state["flushed_payouts"], state["flushed_height"]))
            assert_equal(verdicts["chainstate flush"], "accepted")
        assert verdicts["wallet tip"] in ("not in the block index", "not on the active chain"), verdicts
        return verdicts

    def _check_back_in_sync(self, state):
        """With its peer again the wallet shows what it showed before the first crash, and what a full rescan shows."""
        wallet = self._resync()
        assert_equal(self.nodes[0].getblockcount(), state["height"])
        after = self._snapshot(wallet)
        assert_equal(len(self._payout_heights(after)), state["total_payouts"])
        # The wallet may also keep the inactive records of blocks a crash lost for good.
        for key in ("balances", "unspent", "pos_count", "last_pos_height"):
            assert_equal(after[key], state["before"][key])
        wallet.rescanblockchain(0)
        self._assert_same(after, self._snapshot(wallet))
        return wallet

    def _double_crash(self, blocks_in_index, earlier_release_wallet):
        """Crash 2 after the node has connected its own blocks above the flush, with no chainstate flush."""
        node = self.nodes[0]
        state = self._crash_behind_wallet(blocks_in_index, earlier_release_wallet)
        self._first_restart(state, earlier_release_wallet)
        self.wait_until(lambda: node.getblockcount() == state["height"])
        node.syncwithvalidationinterfacequeue()
        assert_equal(self._wallet_height(), state["height"])
        self._kill_node()

        if blocks_in_index:
            result, verdicts = self._start_alone()
            reads = None
        else:
            # Without its block file copy this node connects nothing by itself, so the load
            # can be measured alone.
            self._start()
            result, reads = self._load_wallet(flush_checkpoint_used=True)
            verdicts = self.last_verdicts
            reads = self._settled_reads(reads, result, True, lambda reads: reads >= state["flushed_payouts"])
        self.log.info(f"second restart: {result[0]} payout blocks authenticated, {result[1]} already verified through height {result[2]} "
                      f"(wallet holds {state['total_payouts']}, {state['flushed_payouts']} at or below the flushed height {state['flushed_height']}); "
                      f"wallet tip record: {verdicts['wallet tip']}; flush record: {verdicts['chainstate flush']}"
                      + ("" if reads is None else f"; {reads} chainstate reads while loading"))
        assert_equal(result, (0, state["flushed_payouts"], state["flushed_height"]))
        assert_equal(verdicts["chainstate flush"], "accepted")
        assert_equal(verdicts["wallet tip"], "not on the active chain" if blocks_in_index else "not in the block index")
        if reads is not None:
            # A full authentication reads the chainstate at least once per payout block.
            assert reads < state["flushed_payouts"], f"{reads} chainstate reads for a load that authenticates nothing"
        if blocks_in_index:
            self.wait_until(lambda: node.getblockcount() == state["height"])
        self._check_back_in_sync(state)

    def _crash_during_replay(self):
        """Crash 2 while the wallet is still processing the blocks above the flush."""
        node = self.nodes[0]
        state = self._crash_behind_wallet(blocks_in_index=True, earlier_release_wallet=True)
        # The wallet holds its lock while it works through the blocks, and the node answers
        # no RPC until then, so this restart is watched through the log and never spoken to.
        self.start_log_offset = node.debug_log_path.stat().st_size
        node.start(self._alone_args([*state["start_args"], f"-testwalletsyncdelayus={SLOW_WALLET_COMMIT_US}"]))
        self.wait_until(lambda: state["flushed_height"] + 1 < self._highest_block_recorded())
        self._kill_node()
        killed_at = self._highest_block_recorded()
        assert killed_at < state["height"], "the wallet finished before the kill; nothing was interrupted"
        result, verdicts = self._parse_payout_check(self._log_since_start())
        assert_equal(result, (state["flushed_payouts"], 0, -1))
        assert_equal(verdicts["chainstate flush"], "none stored")
        self.log.info(f"killed with the wallet at {killed_at}, between the flushed height {state['flushed_height']} and {state['height']}")
        result, verdicts = self._start_alone()
        assert_equal(result, (0, state["flushed_payouts"], state["flushed_height"]))
        assert_equal((verdicts["wallet tip"], verdicts["chainstate flush"]), ("not on the active chain", "accepted"))
        self.wait_until(lambda: node.getblockcount() == state["height"])
        self._check_back_in_sync(state)

    def _flush_between_crashes(self):
        """A chainstate flush between the crashes moves the flush-anchored record with it."""
        node = self.nodes[0]
        state = self._crash_behind_wallet(blocks_in_index=False, earlier_release_wallet=False)
        self._first_restart(state, earlier_release_wallet=False)
        self.wait_until(lambda: node.getblockcount() == state["height"])
        node.syncwithvalidationinterfacequeue()
        assert_equal(self._flush_chainstate(), state["height"])
        wallet = node.get_wallet_rpc(WALLET_NAME)
        self._set_mocktime((node.getblockheader(node.getbestblockhash())["time"] & ~0xf) + 16)
        for _ in range(LATER_PAYOUT_BLOCKS):
            self._mine_pos_block(wallet)
        assert_equal(self._wallet_height(), state["height"] + LATER_PAYOUT_BLOCKS)
        self._kill_node()

        self._start()
        assert_equal(node.getblockcount(), state["height"])
        result, reads = self._load_wallet(flush_checkpoint_used=True)
        assert_equal(result, (0, state["total_payouts"], state["height"]))
        reads = self._settled_reads(reads, result, True, lambda reads: reads >= state["total_payouts"])
        assert_equal(self.last_verdicts["wallet tip"], "not in the block index")
        assert reads < state["total_payouts"], f"{reads} chainstate reads for a load that authenticates nothing"
        self._check_back_in_sync(state)

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

        self.log.info("Two crashes, blocks above the flush in the block index, wallet of an earlier release")
        self._double_crash(blocks_in_index=True, earlier_release_wallet=True)
        self.log.info("Two crashes, blocks above the flush only in the block files, wallet of an earlier release")
        self._double_crash(blocks_in_index=False, earlier_release_wallet=True)
        self.log.info("Two crashes, blocks above the flush only in the block files, wallet with a flush-anchored checkpoint")
        self._double_crash(blocks_in_index=False, earlier_release_wallet=False)
        self.log.info("The second crash while the wallet is still processing the blocks above the flush")
        self._crash_during_replay()
        self.log.info("A chainstate flush between the two crashes")
        self._flush_between_crashes()


if __name__ == '__main__':
    WalletGoldRushPayoutDoubleCrashTest().main()
