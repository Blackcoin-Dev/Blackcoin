#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin Core developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""QQ preference uses accepted handshake, current-chain HEADERS, and matching PONG.

This covers evidence and configuration boundaries on an isolated regtest node.
It does not claim the full-pool automated replacement/topology acceptance matrix.
"""
from test_framework.messages import (
    CBlockHeader, CInv, MSG_BLOCK, NODE_NETWORK, NODE_QUANTUM_QUASAR,
    from_hex, msg_headers, msg_inv, msg_pong,
)
from test_framework.p2p import P2PInterface, p2p_lock
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal


class HoldPong(P2PInterface):
    def on_ping(self, message):
        # Preserve outstanding node nonce; arbitrary pong must not establish proof.
        pass


class QQOutboundTest(BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.extra_args = [["-dnsseed=0", "-fixedseeds=0"]]

    def evaluate(self):
        node = self.nodes[0]
        generation = node.getnetworkinfo()["qqoutbound"]["generation"]
        node.mockscheduler(46)
        self.wait_until(lambda: node.getnetworkinfo()["qqoutbound"]["generation"] > generation)
        return node.getnetworkinfo()["qqoutbound"]

    def run_test(self):
        node = self.nodes[0]
        assert_equal(node.getnetworkinfo()["qqoutbound"]["target"], 8)
        self.generate(node, 1)
        assert_equal(node.getblockchaininfo()["initialblockdownload"], False)
        tip = node.getbestblockhash()
        header = from_hex(CBlockHeader(), node.getblockheader(tip, False))
        services = NODE_NETWORK | NODE_QUANTUM_QUASAR
        peer = node.add_outbound_p2p_connection(HoldPong(), p2p_idx=0, services=services)
        node.add_outbound_p2p_connection(P2PInterface(), p2p_idx=1, services=NODE_NETWORK)
        inbound = node.add_p2p_connection(P2PInterface(), services=services)
        inbound.send_and_ping(msg_headers([header]))
        peer.send_and_ping(msg_headers())
        status = self.evaluate()
        assert_equal(status["confirmed"], 1)  # Inbound capability cannot satisfy target.
        assert_equal(status["eligible"], 0)  # Empty headers prove no chain correspondence.

        peer.send_and_ping(msg_inv([CInv(MSG_BLOCK, int(tip, 16))]))
        peer.send_and_ping(msg_pong(0))
        assert_equal(self.evaluate()["eligible"], 0)  # INV and arbitrary pong are insufficient.
        peer.send_and_ping(msg_headers([header]))
        assert_equal(self.evaluate()["eligible"], 0)  # Valid headers alone are insufficient.
        with p2p_lock:
            peer.last_message.pop("ping", None)
        node.ping()
        peer.wait_until(lambda: "ping" in peer.last_message)
        with p2p_lock:
            nonce = peer.last_message["ping"].nonce
        peer.send_and_ping(msg_pong(nonce))
        status = self.evaluate()
        assert_equal(status["eligible"], 1)  # Known quiet tip qualifies without a new-block race.
        assert_equal(status["deficit"], 7)
        assert_equal(self.evaluate()["eligible"], 1)  # Quiet periods retain valid evidence.

        node.invalidateblock(tip)
        assert_equal(self.evaluate()["eligible"], 0)  # Removed benchmark cannot survive reorg.
        node.reconsiderblock(tip)
        peer.send_and_ping(msg_headers([header]))
        assert_equal(self.evaluate()["eligible"], 1)
        node.setnetworkactive(False)
        self.wait_until(lambda: node.getconnectioncount() == 0)
        assert_equal(self.evaluate()["eligible"], 0)
        self.restart_node(0, extra_args=["-qqoutboundtarget=0", "-dnsseed=0", "-fixedseeds=0"])
        assert_equal(node.getnetworkinfo()["qqoutbound"]["target"], 0)
        self.restart_node(0, extra_args=["-maxconnections=1", "-qqoutboundtarget=100", "-dnsseed=0"])
        assert_equal(node.getnetworkinfo()["qqoutbound"]["target"], 0)
        self.stop_node(0)
        node.assert_start_raises_init_error(extra_args=["-qqoutboundtarget=-1"], expected_msg="Error: -qqoutboundtarget must be nonnegative")
        for option, error in [
            ("-headerspamfiltermaxsize=-1", "-headerspamfiltermaxsize must be between 0 and 2000"),
            ("-headerspamfiltermaxsize=2001", "-headerspamfiltermaxsize must be between 0 and 2000"),
            ("-headerspamfiltermaxavg=-1", "-headerspamfiltermaxavg must be nonnegative"),
        ]:
            node.assert_start_raises_init_error(extra_args=[option], expected_msg=f"Error: {error}")
        # Zero keeps the existing disabled-counting behavior. Valid header
        # processing and ordinary outbound QQ qualification must still work.
        for option in ("-headerspamfiltermaxsize=0", "-headerspamfiltermaxavg=0"):
            self.start_node(0, extra_args=[option, "-qqoutboundtarget=0", "-dnsseed=0", "-fixedseeds=0"])
            peer = node.add_outbound_p2p_connection(P2PInterface(), p2p_idx=0, services=services)
            peer.send_and_ping(msg_headers([header]))
            assert_equal(self.evaluate()["eligible"], 1)
            assert peer.is_connected
            self.stop_node(0)


if __name__ == "__main__":
    QQOutboundTest().main()
