#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Gold Rush claims reach peers without the trickle or the request delay.

A claim made on one tip must be in the next block. A node announces a claim
it relays at once instead of waiting for the per-peer inventory timer, and a
claim its own miner created is sent to peers as a whole transaction, so the
first hop has no inv and getdata round trip. Ordinary transactions keep the
timer and the inv.

Mock time is frozen on every node, so a trickle timer never fires and a
delayed transaction request never becomes due until the test moves the clock.

  node1 dials node0 and prefers it as a transaction source.
  node0 dials node2: node2 treats node0 as an inbound, non-preferred peer and
      would hold a getdata for two seconds of its own clock. The direct send
      removes that wait.
  Three test peers on node0: one that never requests anything, one that asked
      for no transaction relay, and one with a high fee filter.

The test also covers the relay figures of the miner's timing record and the
miner being woken when the mempool drops its live claim.
"""

from decimal import Decimal
import re
import time

from test_framework.blocktools import COINBASE_MATURITY
from test_framework.messages import MSG_TX, MSG_WTX, msg_feefilter
from test_framework.p2p import P2PInterface
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal


GOLD_RUSH_END_TIME = 2_000_000_000
MIGRATION_DEADLINE_TIME = GOLD_RUSH_END_TIME + 40_000
QQSPROOF_HEX = "51515350524f4f46"


class SilentPeer(P2PInterface):
    """Records transaction invs and transactions; never sends a getdata."""

    def __init__(self, relay=1):
        super().__init__()
        self.version_relay = relay
        self.tx_invs = []
        self.txs = []

    def peer_connect_send_version(self, services):
        super().peer_connect_send_version(services)
        self.on_connection_send_msg.relay = self.version_relay

    def on_inv(self, message):
        for inv in message.inv:
            if inv.type in (MSG_TX, MSG_WTX):
                self.tx_invs.append(f"{inv.hash:064x}")

    def on_tx(self, message):
        message.tx.rehash()
        self.txs.append(message.tx.hash)


class GoldRushClaimFastRelayTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)
        parser.add_argument(
            "--qqp4-inactive",
            action="store_true",
            help="Leave the QQP4 input-bound proof format inactive, as it is on mainnet: "
                 "the claim's proof then names no fee input",
        )

    def set_test_params(self):
        self.num_nodes = 3
        self.setup_clean_chain = True
        common = [
            "-allowunsafequantumkeyrpc=1",
            "-staking=0",
            "-txindex=1",
            "-shadowwhitelistheight=1",
            "-shadowcompetingclaimsheight=2",
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
        # Options are parsed after set_test_params. Regtest leaves QQP4
        # disabled unless a height is given, which is the mainnet shape.
        if not self.options.qqp4_inactive:
            self.extra_args = [[*args, "-shadowqqp4height=2"] for args in self.extra_args]
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
        assert_equal(node0.getgoldrushinfo()["qqp4_activation_disabled"], self.options.qqp4_inactive)
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

        self.log.info("Connecting test peers: silent, no transaction relay, high fee filter")
        silent = node0.add_p2p_connection(SilentPeer())
        no_relay = node0.add_p2p_connection(SilentPeer(relay=0))
        high_fee = node0.add_p2p_connection(SilentPeer())
        high_fee.send_and_ping(msg_feefilter(100_000_000))
        self._settle_inventory_timers()

        self.log.info("An ordinary transaction waits for the trickle timer, which the frozen clock never fires")
        ordinary_txid = staker.sendtoaddress(staker.getnewaddress("", "legacy"), Decimal("0.5"))
        assert ordinary_txid in node0.getrawmempool()

        self.log.info("The miner's claim is sent whole: it arrives with no getdata and no clock movement")
        getdata_before = {peer["id"]: peer["bytesrecv_per_msg"].get("getdata", 0) for peer in node0.getpeerinfo()}
        started = miner.setpowmining(True, 1, 100, True)
        assert_equal(started["enabled"], True)
        self.wait_until(
            lambda: miner.getpowmininginfo()["claims_submitted"] > 0 and len(self._claim_txids(node0)) == 1,
            timeout=180,
        )
        claim_txid = self._claim_txids(node0)[0]
        claim_wtxid = node0.getmempoolentry(claim_txid)["wtxid"]
        self.wait_until(lambda: claim_txid in silent.txs, timeout=60)
        # node2 would have held its request for two seconds of a clock that
        # does not move; it has the claim because no request was needed.
        self.wait_until(lambda: claim_txid in node1.getrawmempool(), timeout=60)
        self.wait_until(lambda: claim_txid in node2.getrawmempool(), timeout=60)
        for peer in node0.getpeerinfo():
            assert_equal(peer["bytesrecv_per_msg"].get("getdata", 0), getdata_before[peer["id"]])
        for peer in (silent, no_relay, high_fee):
            peer.sync_with_ping()
        assert claim_txid not in silent.tx_invs and claim_wtxid not in silent.tx_invs

        self.log.info("A peer that asked for no transactions and a peer with a higher fee filter get nothing")
        for peer in (no_relay, high_fee):
            assert peer.is_connected
            assert_equal(peer.txs, [])
            assert_equal(peer.tx_invs, [])

        self.log.info("The ordinary transaction was neither sent nor, with the clock frozen, announced")
        assert_equal(silent.txs, [claim_txid])
        assert_equal(silent.tx_invs, [])
        assert ordinary_txid not in node1.getrawmempool()
        assert ordinary_txid not in node2.getrawmempool()
        assert ordinary_txid in node0.getrawmempool()

        self.log.info("The timing record reports the three peers the claim was sent to")
        self.wait_until(
            lambda: miner.getpowmininginfo()["last_claim_timing"]["first_inv_ms"] >= 0,
            timeout=30,
        )
        timing = miner.getpowmininginfo()["last_claim_timing"]
        assert_equal(timing["result"], "submitted")
        assert_equal(timing["inv_peers_1s"], 3)
        assert_equal(timing["push_peers_1s"], 3)
        assert_equal(miner.getgoldrushinfo()["qqp4_active"], not self.options.qqp4_inactive)
        assert timing["first_inv_ms"] >= timing["proof_found_ms"]
        # The log line is held until the relay figures are settled, then
        # written once with the new keys appended.
        self.wait_until(
            lambda: any("result=submitted" in line for line in self._timing_lines()),
            timeout=30,
        )
        submitted_lines = [line for line in self._timing_lines() if "result=submitted" in line]
        assert_equal(len(submitted_lines), 1)
        assert re.search(
            rf" mempool_accept_ms={timing['mempool_accept_ms']} hashes=\d+ batches=\d+ "
            rf"duty_sleep_ms=\d+ first_inv_ms={timing['first_inv_ms']} inv_peers_1s=3 push_peers_1s=3$",
            submitted_lines[0],
        ), submitted_lines[0]

        old_entry_time = node0.getmempoolentry(claim_txid)["time"]
        self._set_mocktime(max(self.mock_time, old_entry_time) + 3)

        self.log.info("Dropping the live claim from node0's mempool wakes the miner, which relays it again on the same tip")
        tip = node0.getbestblockhash()
        with node0.wait_for_debug_log([
            f"Waking the Gold Rush PoW miner after expiry mempool removal of claim {claim_txid}".encode(),
        ], timeout=30):
            # Accepting any transaction runs the expiry pass.
            late_txid = staker.sendtoaddress(staker.getnewaddress("", "legacy"), Decimal("0.25"))
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

        self.log.info("The relay after the removal sent nothing whole, and an ordinary transaction is only ever announced by inv")
        late_wtxid = node0.getmempoolentry(late_txid)["wtxid"]
        for _ in range(40):
            if late_txid in silent.tx_invs or late_wtxid in silent.tx_invs:
                break
            self._set_mocktime(self.mock_time + 30)
            self._settle_inventory_timers()
        assert late_txid in silent.tx_invs or late_wtxid in silent.tx_invs
        silent.sync_with_ping()
        assert_equal(silent.txs, [claim_txid])
        assert_equal(no_relay.txs, [])
        assert_equal(high_fee.txs, [])
        assert no_relay.is_connected and high_fee.is_connected


if __name__ == "__main__":
    GoldRushClaimFastRelayTest().main()
