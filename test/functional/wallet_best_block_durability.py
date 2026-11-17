#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Test that a wallet's best block is durable per connected block.

The best block used to be written only when the chainstate was flushed, so a
process that died without a flush left every wallet up to a day behind and
restarted with a rescan of that whole span. The best block is now written in
the commit of every connected block. This test kills the node without any
flush while a wallet holds many own transactions and Gold Rush payouts, and
then checks that

- the wallet restarts with no rescan (or one of a handful of blocks),
- the wallet's balances, transactions and payout records equal what a full
  rescan of the same chain produces,
- the persisted position keeps working when the node's chain is shorter than
  the wallet's own best block (the node lost unflushed blocks),
- after new blocks replace the lost ones, the wallet puts its own transactions
  of the lost blocks back into the mempool by itself, on its one-minute tick
  and without a reload, and the live wallet, the same wallet after an unload
  and reload, the same wallet after a clean restart and a full rescan all
  agree,
- the periodic 12 to 36 hour resend fires on a transaction that sat
  unconfirmed in the mempool.
"""

import re
import time
from contextlib import nullcontext

from test_framework.blocktools import COINBASE_MATURITY
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal

SHADOW_GOLD_RUSH_BLOCKS = 500
GOLD_RUSH_END_HEIGHT = 1 + SHADOW_GOLD_RUSH_BLOCKS
MIGRATION_END_HEIGHT = GOLD_RUSH_END_HEIGHT + 10
WALLET_NAME = "durable"
PAYOUT_BLOCKS = 6
OWN_OUTPUT_TXS = 12
OUTPUTS_PER_TX = 20
MAX_RESTART_RESCAN_BLOCKS = 20


class WalletBestBlockDurabilityTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.node_args = [
            "-allowunsafequantumkeyrpc=1",
            "-txindex=1",
            # gettransaction must return the signed transaction with its witness data,
            # so that the test can put the wallet's transactions back into the mempool.
            "-rpcserialversion=1",
            "-staketimio=20",
            "-autostartstaking=0",
            "-qqautoshadowsignal=1",
            "-shadowwhitelistheight=1",
            f"-shadowgoldrushblocks={SHADOW_GOLD_RUSH_BLOCKS}",
            f"-qqgoldrushendheight={GOLD_RUSH_END_HEIGHT}",
            f"-qqmigrationendheight={MIGRATION_END_HEIGHT}",
        ]
        self.extra_args = [self.node_args]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def _set_mocktime(self, timestamp):
        self.mock_time = timestamp
        self.nodes[0].setmocktime(timestamp)

    def _mine_pos_block(self, wallet):
        node = self.nodes[0]
        inputs = [{"txid": utxo["txid"], "vout": utxo["vout"]} for utxo in wallet.listunspent(1, 9999999)]
        start_height = node.getblockcount()
        for _ in range(3000):
            self._set_mocktime(self.mock_time + 16)
            kernel = wallet.checkkernel(inputs)
            if kernel["found"]:
                kernel_time = kernel["kernel"]["time"]
                break
        else:
            raise AssertionError("timed out searching for a deterministic PoS kernel")
        self._set_mocktime(kernel_time - 16)
        wallet.staking(True)
        try:
            self._set_mocktime(kernel_time)
            self.wait_until(lambda: node.getblockcount() > start_height, timeout=30)
        finally:
            wallet.staking(False)
        node.syncwithvalidationinterfacequeue()

    def _snapshot(self, wallet):
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
            "walletinfo": {k: v for k, v in wallet.getwalletinfo().items() if k != "lastprocessedblock"},
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
                if key == "balances":
                    pick = lambda b: {k: b["mine"][k] for k in ("trusted", "untrusted_pending", "immature", "stake")}
                    raise AssertionError(f"balances differ: {pick(left[key])} != {pick(right[key])}")
                raise AssertionError(f"{key} differs: {left[key]} != {right[key]}")

    def _own_sends(self, wallet):
        """Txids of the wallet's own unconfirmed, not abandoned sends."""
        return sorted({entry["txid"] for entry in wallet.listtransactions("*", 100000, 0, True)
                       if entry["category"] == "send" and entry["confirmations"] == 0 and not entry.get("abandoned")})

    def _acceptable_but_absent(self, wallet):
        """Own unconfirmed sends the node would take now but does not hold.

        The transactions of the blocks the node lost are inactive in the wallet
        and not in the node's mempool (the restart emptied it). A transaction
        that is not final at the restart height (its lock time is the height it
        was made at) is refused until the chain passes that height. Whatever the
        chain allows must be back in the mempool without any help.
        """
        node = self.nodes[0]
        mempool = set(node.getrawmempool())
        absent = []
        for txid in self._own_sends(wallet):
            if txid in mempool:
                continue
            if node.testmempoolaccept([wallet.gettransaction(txid)["hex"]])[0]["allowed"]:
                absent.append(txid)
        return absent

    def _resend_tick(self, wallet):
        """Run the scheduler's one-minute wallet tick and wait for it to finish."""
        node = self.nodes[0]
        node.mockscheduler(60)
        node.syncwithvalidationinterfacequeue()

    def _wait_for_wallet_to_resubmit(self, wallet, max_ticks=3):
        """Tick until the wallet holds every own transaction the chain allows. Returns the ticks used."""
        node = self.nodes[0]
        for tick in range(1, max_ticks + 1):
            with node.assert_debug_log(["own transactions back into the mempool"], timeout=30) if tick == 1 else nullcontext():
                self._resend_tick(wallet)
            try:
                self.wait_until(lambda: not self._acceptable_but_absent(wallet), timeout=10)
                return tick
            except AssertionError:
                continue
        raise AssertionError(f"the wallet left {self._acceptable_but_absent(wallet)} out of the mempool after {max_ticks} ticks")

    def _check_live_reload_rescan(self, wallet, reload):
        """The live wallet equals the same wallet after `reload` and after a full rescan."""
        live = self._snapshot(wallet)
        wallet = reload(wallet)
        reloaded = self._snapshot(wallet)
        self._assert_same(live, reloaded)
        wallet.rescanblockchain(0)
        self._assert_same(live, self._snapshot(wallet))
        return wallet, live

    def _unload_and_load(self, wallet):
        wallet.unloadwallet()
        node = self.nodes[0]
        node.loadwallet(WALLET_NAME)
        return node.get_wallet_rpc(WALLET_NAME)

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

    def _start_and_load(self, extra=()):
        """Start the node, load the wallet and return it with the blocks its attach rescanned."""
        log_size_before = self.nodes[0].debug_log_path.stat().st_size if self.nodes[0].debug_log_path.exists() else 0
        self.start_node(0, self.node_args + list(extra))
        node = self.nodes[0]
        node.loadwallet(WALLET_NAME)
        with open(node.debug_log_path, encoding="utf-8", errors="replace") as log:
            log.seek(log_size_before)
            text = log.read()
        rescans = [int(n) for n in re.findall(r"Rescanning last (\d+) blocks", text)]
        return node.get_wallet_rpc(WALLET_NAME), (rescans[-1] if rescans else 0), text

    def run_test(self):
        node = self.nodes[0]
        self._set_mocktime((int(time.time()) & ~0xf) + 16)
        node.get_wallet_rpc(self.default_wallet_name).staking(False)
        node.createwallet(wallet_name=WALLET_NAME)
        wallet = node.get_wallet_rpc(WALLET_NAME)
        wallet.staking(False)
        signal_address = wallet.getnewaddress("", "legacy")

        self.log.info("Fund the wallet and let it stake into an active Gold Rush signal")
        self.generatetoaddress(node, 1, signal_address, sync_fun=self.no_op)
        self.generatetoaddress(node, COINBASE_MATURITY + 50, signal_address, sync_fun=self.no_op)
        self._set_mocktime((node.getblockheader(node.getbestblockhash())["time"] & ~0xf) + 16)
        wallet.getnewquantumaddress("goldrush-pos")
        for _ in range(PAYOUT_BLOCKS + 1):
            self._mine_pos_block(wallet)
            self._snapshot(wallet)

        self.log.info("A clean restart flushes the chainstate; everything after it is unflushed")
        self.stop_node(0)
        wallet, _, _ = self._start_and_load()
        node = self.nodes[0]
        self._set_mocktime((node.getblockheader(node.getbestblockhash())["time"] & ~0xf) + 16)
        flushed_height = node.getblockcount()

        self.log.info("Give the wallet many own transactions, one block each")
        for _ in range(OWN_OUTPUT_TXS):
            outputs = {wallet.getnewaddress("", "bech32"): 0.01 for _ in range(OUTPUTS_PER_TX)}
            wallet.sendmany("", outputs)
            self._mine_pos_block(wallet)
        node.syncwithvalidationinterfacequeue()
        height_before_kill = node.getblockcount()
        txcount_before_kill = wallet.getwalletinfo()["txcount"]
        assert txcount_before_kill > OWN_OUTPUT_TXS * 2

        self.log.info("Kill the node with no chainstate flush")
        self._kill_node()

        self.log.info("Restart: the wallet position is the last connected block, not the last flush")
        wallet, rescanned, log_text = self._start_and_load()
        node = self.nodes[0]
        height_after_kill = node.getblockcount()
        self.log.info(f"height before kill {height_before_kill}, after restart {height_after_kill}, "
                      f"blocks rescanned on attach {rescanned}")
        assert_equal(height_after_kill, flushed_height)
        assert height_after_kill < height_before_kill, "the kill must lose unflushed blocks for this test to mean anything"
        assert rescanned <= MAX_RESTART_RESCAN_BLOCKS, f"wallet rescanned {rescanned} blocks after the kill"
        crashed = self._snapshot(wallet)
        assert_equal(wallet.getwalletinfo()["lastprocessedblock"]["hash"], node.getbestblockhash())

        self.log.info("The wallet equals a full rescan of the same chain")
        wallet.rescanblockchain(0)
        self._assert_same(crashed, self._snapshot(wallet))

        self.log.info("New blocks replace the lost ones: live wallet, reloaded wallet and full rescan agree")
        for _ in range(3):
            self._mine_pos_block(wallet)
        waiting = self._acceptable_but_absent(wallet)
        self.log.info(f"{len(waiting)} wallet transactions of the lost blocks are acceptable but not in the mempool")
        assert len(waiting) > 0, "the lost blocks must have taken wallet transactions out of the mempool"
        ticks = self._wait_for_wallet_to_resubmit(wallet)
        self.log.info(f"the wallet put them back by itself within {ticks} one-minute tick(s), no reload, no sendrawtransaction")
        wallet, replaced = self._check_live_reload_rescan(wallet, self._unload_and_load)

        self.log.info("A clean restart keeps the state and needs no rescan")
        self.stop_node(0)
        wallet, rescanned, _ = self._start_and_load()
        assert_equal(rescanned, 0)
        self._assert_same(replaced, self._snapshot(wallet))

        self.log.info("After a clean restart too, more blocks keep live, reloaded and rescanned wallets equal")
        node = self.nodes[0]
        self._set_mocktime((node.getblockheader(node.getbestblockhash())["time"] & ~0xf) + 16)
        for _ in range(2):
            self._mine_pos_block(wallet)
        self._resend_tick(wallet)
        self.wait_until(lambda: not self._acceptable_but_absent(wallet), timeout=10)

        def restart(_wallet):
            self.stop_node(0)
            reloaded, restart_rescanned, _ = self._start_and_load()
            assert_equal(restart_rescanned, 0)
            return reloaded

        wallet, _ = self._check_live_reload_rescan(wallet, restart)
        self._check_periodic_resend(wallet)

    def _check_periodic_resend(self, wallet):
        """The 12 to 36 hour resend fires for a transaction that stays unconfirmed in the mempool.

        Three things have to hold at once, and a test that misses one sees no
        resend: the next resend time is 12 hours plus up to 24 hours of jitter
        after the wallet was created or last resent (the mock clock has to pass
        it), the scheduler moves only a bounded step per mockscheduler call
        (the tick itself is every minute, so one call is enough once the clock
        has moved), and the resend takes only transactions received more than
        five minutes before the best block, which is stamped when a block
        connects after the time jump.
        """
        # A block template skips transactions below -blockmintxfee, so a restart with a
        # high floor keeps the next send in the mempool while blocks keep coming.
        self.stop_node(0)
        wallet, _, _ = self._start_and_load(extra=["-blockmintxfee=0.5"])
        node = self.nodes[0]
        self._set_mocktime((node.getblockheader(node.getbestblockhash())["time"] & ~0xf) + 16)
        self.log.info("Periodic resend: a transaction kept out of blocks is resubmitted after 36 hours")
        address = wallet.getnewaddress("", "bech32")
        txid = wallet.send(outputs=[{address: 0.01}])["txid"]
        self._mine_pos_block(wallet)
        assert_equal(wallet.gettransaction(txid)["confirmations"], 0)
        assert txid in node.getrawmempool()

        # Before the jump the tick must leave it alone.
        with node.assert_debug_log([], unexpected_msgs=[f"Submitting wtx {txid} to mempool for relay"]):
            node.mockscheduler(60)
            node.syncwithvalidationinterfacequeue()

        self._set_mocktime(self.mock_time + 37 * 60 * 60)
        # A block after the jump stamps the best block time that the resend compares against.
        self._mine_pos_block(wallet)
        node.syncwithvalidationinterfacequeue()
        assert_equal(wallet.gettransaction(txid)["confirmations"], 0)
        # Older sends that no block took may be resent in the same pass, so look for this
        # transaction's own submission and the pass summary rather than an exact count.
        with node.assert_debug_log([f"Submitting wtx {txid} to mempool for relay", "unconfirmed transactions"], timeout=30):
            node.mockscheduler(60)


if __name__ == '__main__':
    WalletBestBlockDurabilityTest().main()
