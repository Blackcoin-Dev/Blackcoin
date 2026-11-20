#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin Core developers
# Distributed under the MIT software license, see COPYING.
"""A node with no peers must dial a lone reachable QQ hint among many dead legacy addresses.

Legacy-first selection keeps QQ-flagged addresses behind legacy ones until QQ
peers are proven reachable, and only a QQ handshake proves it. With an address
manager full of dead legacy entries and a few QQ hints, the hints were never
dialed: no handshake, so no evidence, so no dial. The guaranteed QQ turn (one
selection after every two legacy-first dials) breaks the loop.

Loopback only: every apparently public address is routed by a local SOCKS relay
to local fixtures, and the relay refuses (after a delay) every other address.
"""
import time

from p2p_qq_pursuit import QQPursuitTest
from test_framework.messages import CAddress, CBlockHeader, NODE_NETWORK, NODE_QUANTUM_QUASAR, from_hex, msg_addr
from test_framework.util import assert_equal

DEAD_LEGACY = 300
# Each dead dial costs DEAD_DIAL_DELAY seconds. The turn arrives after two legacy
# dials, so a few seconds suffice; a node without it would still be dialing
# dead legacy addresses when the bound expires.
DEAD_DIAL_DELAY = 2
DIAL_BOUND = 45


class QQHintTurnTest(QQPursuitTest):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.disable_autoconnect = False
        self.extra_args = [["-networkactive=0", "-dnsseed=0", "-fixedseeds=0", "-onlynet=ipv4",
                            "-v2transport=0", "-debug=net"]]

    def add_options(self, parser):
        pass

    def outbound(self):
        return [p for p in self.nodes[0].getpeerinfo() if p["connection_type"] == "outbound-full-relay"]

    def run_test(self):
        node = self.nodes[0]
        peers = []
        try:
            node.setmocktime(int(time.time()))
            self.generate(node, 1)
            header = from_hex(CBlockHeader(), node.getblockheader(node.getbestblockhash(), False))
            self.proxy.unknown_route_delay = DEAD_DIAL_DELAY

            # A reachable legacy publisher is the only address at first.
            publisher = self.endpoint("23.100.0.1", header)
            peers.append(publisher)
            assert node.addpeeraddress(publisher.fixture_ip, 15714, True)["success"]
            node.setnetworkactive(True)
            self.wait_until(lambda: publisher.is_connected)
            publisher.wait_for_verack()
            publisher.sync_with_ping()
            self.wait_until(lambda: len(self.outbound()) == 1)

            # It gossips many dead legacy addresses and one reachable QQ-flagged hint.
            hint_peer = self.endpoint("26.1.0.1", header, qq=True)
            peers.append(hint_peer)
            announcement = msg_addr()
            for i in range(DEAD_LEGACY):
                dead = CAddress()
                dead.ip, dead.port = f"24.{1 + i // 2}.{1 + i % 2}.1", 15714
                dead.time = node.mocktime
                dead.nServices = NODE_NETWORK
                announcement.addrs.append(dead)
            hint = CAddress()
            hint.ip, hint.port = hint_peer.fixture_ip, 15714
            hint.time = node.mocktime
            hint.nServices = NODE_NETWORK | NODE_QUANTUM_QUASAR
            announcement.addrs.append(hint)
            publisher.send_and_ping(announcement)
            self.wait_until(lambda: len(node.getnodeaddresses(0)) >= DEAD_LEGACY // 2)

            # Zero peers: the publisher leaves and cannot be redialed.
            publisher.retire()
            self.wait_until(lambda: len(node.getpeerinfo()) == 0)
            assert hint_peer.connection_count <= 1
            started = time.monotonic()
            try:
                self.wait_until(lambda: hint_peer.is_connected and len(self.outbound()) == 1, timeout=DIAL_BOUND)
            except AssertionError:
                raise AssertionError(
                    f"QQ hint not dialed within {DIAL_BOUND}s; peers={len(node.getpeerinfo())} "
                    f"qq={node.getnetworkinfo()['qqoutbound']}")
            self.log.info("QQ hint connected %.1fs after the last peer left", time.monotonic() - started)
            hint_peer.wait_for_verack()

            log = node.debug_log_path.read_text()
            assert "Peer lost: peer=" in log
            assert "subver=/" in log
            # The turn never disturbs an established peer.
            assert_equal(len(self.outbound()), 1)
        finally:
            for peer in peers:
                peer.retire()
            node.setnetworkactive(False)
            self.proxy.shutdown()
            self.proxy.server_close()
            self.proxy_thread.join(timeout=5)


if __name__ == "__main__":
    QQHintTurnTest().main()
