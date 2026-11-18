#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Gold Rush claims are announced to peers without the trickle delay.

A claim made on one tip must be in the next block, so the node that creates
or relays it announces it at once instead of waiting for the per-peer
inventory timer. Ordinary transactions keep the timer.

Mock time is frozen on every node, so a trickle timer never fires and a
delayed transaction request never becomes due until the test moves the clock.
Three nodes:

  node1 dials node0: node1 treats node0 as a preferred peer and requests the
      claim the moment it is announced.
  node0 dials node2: node2 treats node0 as an inbound, non-preferred peer and
      holds its request for two seconds of its own clock. That delay is on the
      receiving side and is unchanged here; the test pins it down.

The test also covers the relay figures of the miner's timing record and the
miner being woken when the mempool drops its live claim.
"""

from decimal import Decimal
import re
import time

from test_framework.blocktools import COINBASE_MATURITY
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal


GOLD_RUSH_END_TIME = 2_000_000_000
MIGRATION_DEADLINE_TIME = GOLD_RUSH_END_TIME + 40_000
QQSPROOF_HEX = "51515350524f4f46"


class GoldRushClaimFastRelayTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.num_nodes = 3
        self.setup_clean_chain = True
        common = [
            "-allowunsafequantumkeyrpc=1",
            "-staking=0",
            "-txindex=1",
            "-shadowwhitelistheight=1",
            "-shadowcompetingclaimsheight=2",
            "-shadowqqp4height=2",
            "-shadowgoldrushblocks=500",
            f"-qqgoldrushendtime={GOLD_RUSH_END_TIME}",
            f"-qqmigrationdeadlinetime={MIGRATION_DEADLINE_TIME}",
        ]
        # Zero-hour expiry on node0 lets the test drop the claim from its
        # mempool by moving the clock past the entry time.
        self.extra_args = [[*common, "-mempoolexpiry=0"], common, common]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def setup_network(self):
        self.setup_nodes()
        self.connect_nodes(1, 0)
        self.connect_nodes(0, 2)

    def _set_mocktime(self, timestamp):
        self.mock_time = timestamp
        for node in self.nodes:
            node.setmocktime(timestamp)

    def _sync_mocktime_to_tip(self):
        tip_time = self.nodes[0].getblockheader(self.nodes[0].getbestblockhash())["time"]
        self._set_mocktime((tip_time & ~0xf) + 16)

    def _generate(self, count, address):
        self.generatetoaddress(self.nodes[0], count, address, sync_fun=self.no_op)
        self._sync_mocktime_to_tip()
        self.sync_blocks()

    def _settle_inventory_timers(self):
        """Let node0 run one send pass per peer at the current mock time.

        A pass re-arms a trickle timer that the last clock move left due, so
        nothing sent after this point can ride on a timer that fired because
        of the setup. A pong proves the pass that carried the ping ran."""
        node = self.nodes[0]
        before = {peer["id"]: peer["bytesrecv_per_msg"].get("pong", 0) for peer in node.getpeerinfo()}
        assert_equal(len(before), 2)
        for _ in range(2):
            node.ping()
            self.wait_until(lambda: all(
                peer["bytesrecv_per_msg"].get("pong", 0) > before[peer["id"]]
                for peer in node.getpeerinfo()
            ), timeout=30)
            before = {peer["id"]: peer["bytesrecv_per_msg"].get("pong", 0) for peer in node.getpeerinfo()}

    def _claim_txids(self, node):
        claims = []
        for txid in node.getrawmempool():
            decoded = node.decoderawtransaction(node.getrawtransaction(txid))
            if any(QQSPROOF_HEX in vout["scriptPubKey"]["hex"] for vout in decoded["vout"]):
                claims.append(txid)
        return claims

    def _timing_lines(self):
        with open(self.nodes[0].debug_log_path, encoding="utf-8") as log:
            return re.findall(r"Gold Rush PoW claim timing: .*", log.read())

    def run_test(self):
        node0, node1, node2 = self.nodes
        self._set_mocktime((int(time.time()) & ~0xf) + 16)

        self.log.info("Funding a staker and a miner wallet on node0 and entering the Gold Rush phase")
        node0.createwallet(wallet_name="relay_staker")
        node0.createwallet(wallet_name="relay_miner")
        staker = node0.get_wallet_rpc("relay_staker")
        miner = node0.get_wallet_rpc("relay_miner")
        staker_address = staker.getnewaddress("", "legacy")
        miner_address = miner.getnewaddress("", "legacy")
        self._generate(COINBASE_MATURITY + 2, staker_address)
        self._sync_mocktime_to_tip()
        assert_equal(node0.getquantumquasarinfo()["phase"], "gold_rush")
        staker.sendtoaddress(miner_address, Decimal("1.0"))
        self._generate(COINBASE_MATURITY + 1, staker_address)
        self._sync_mocktime_to_tip()
        self.wait_until(lambda: len(miner.listunspent(1, 9999999, [miner_address])) == 1, timeout=30)
        self.sync_all()
        for node in self.nodes:
            assert_equal(node.getrawmempool(), [])
        self._settle_inventory_timers()

        self.log.info("An ordinary transaction waits for the trickle timer, which the frozen clock never fires")
        ordinary_txid = staker.sendtoaddress(staker.getnewaddress("", "legacy"), Decimal("0.5"))
        assert ordinary_txid in node0.getrawmempool()

        self.log.info("The miner's claim reaches the peer that prefers node0 with no clock movement at all")
        started = miner.setpowmining(True, 1, 100, True)
        assert_equal(started["enabled"], True)
        self.wait_until(
            lambda: miner.getpowmininginfo()["claims_submitted"] > 0 and len(self._claim_txids(node0)) == 1,
            timeout=180,
        )
        claim_txid = self._claim_txids(node0)[0]
        self.wait_until(lambda: claim_txid in node1.getrawmempool(), timeout=60)
        assert ordinary_txid not in node1.getrawmempool()
        assert ordinary_txid not in node2.getrawmempool()
        assert ordinary_txid in node0.getrawmempool()

        self.log.info("The timing record reports the announcement to both peers")
        self.wait_until(
            lambda: miner.getpowmininginfo()["last_claim_timing"]["first_inv_ms"] >= 0,
            timeout=30,
        )
        timing = miner.getpowmininginfo()["last_claim_timing"]
        assert_equal(timing["result"], "submitted")
        assert_equal(timing["inv_peers_1s"], 2)
        assert timing["first_inv_ms"] >= timing["proof_found_ms"]
        # The log line is held until the relay figures are settled, then
        # written once with the two new keys appended.
        self.wait_until(
            lambda: any("result=submitted" in line for line in self._timing_lines()),
            timeout=30,
        )
        submitted_lines = [line for line in self._timing_lines() if "result=submitted" in line]
        assert_equal(len(submitted_lines), 1)
        assert re.search(
            rf" mempool_accept_ms={timing['mempool_accept_ms']} hashes=\d+ batches=\d+ "
            rf"duty_sleep_ms=\d+ first_inv_ms={timing['first_inv_ms']} inv_peers_1s=2$",
            submitted_lines[0],
        ), submitted_lines[0]

        self.log.info("A peer that does not prefer node0 was told at once but requests only after its own two-second delay")
        assert claim_txid not in node2.getrawmempool()
        old_entry_time = node0.getmempoolentry(claim_txid)["time"]
        self._set_mocktime(max(self.mock_time, old_entry_time) + 3)
        self.wait_until(lambda: claim_txid in node2.getrawmempool(), timeout=60)

        self.log.info("Dropping the live claim from node0's mempool wakes the miner, which relays it again on the same tip")
        tip = node0.getbestblockhash()
        with node0.wait_for_debug_log([
            f"Waking the Gold Rush PoW miner after expiry mempool removal of claim {claim_txid}".encode(),
        ], timeout=30):
            # Accepting any transaction runs the expiry pass.
            staker.sendtoaddress(staker.getnewaddress("", "legacy"), Decimal("0.25"))
        node0.syncwithvalidationinterfacequeue()
        self.wait_until(
            lambda: claim_txid in node0.getrawmempool()
            and node0.getmempoolentry(claim_txid)["time"] > old_entry_time,
            timeout=30,
        )
        assert_equal(node0.getbestblockhash(), tip)
        assert_equal(miner.getpowmininginfo()["claims_submitted"], 1)

        miner.setpowmining(False)
        assert_equal(miner.getpowmininginfo()["state"], "disabled")


if __name__ == "__main__":
    GoldRushClaimFastRelayTest().main()
