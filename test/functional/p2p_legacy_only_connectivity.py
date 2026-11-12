#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin Core developers
# Distributed under the MIT software license, see COPYING.
"""A legacy-only network must connect and stay connected despite many dead QQ hints.

The candidate's address manager holds hundreds of QQ-flagged addresses that
cannot be reached (each dial costs a few seconds, like a dead public host) and a
handful of reachable legacy peers (no QQ service bit). Nothing in the network
ever shows a QQ handshake. The candidate must reach four full-relay outbound
peers within a bounded time and keep them across several minutes of mocktime.

Loopback only: every apparently public address is routed by a local SOCKS relay
to local fixtures, and the relay refuses (after a delay) every other address.
The HTTPS bootstrap source is closed off mainnet, so it contributes no hints,
the same as an empty or failing list; its retry and logging are unit tested.

The IBD rule (deficit treated as zero) is covered by unit tests; this test runs
with a fresh tip.
"""
import time

from p2p_qq_pursuit import QQPursuitTest
from test_framework.messages import CAddress, CBlockHeader, NODE_NETWORK, NODE_QUANTUM_QUASAR, from_hex, msg_addr
from test_framework.util import assert_equal

DEAD_QQ_HINTS = 300
LEGACY_PEERS = 5
FLOOR = 4
# Four peers need three more dials after the publisher. RC5 spends two ~3 s dead
# dials per legacy attempt, so it needs about 25 s; legacy-first needs a few seconds.
CONNECT_BOUND = 12
STAY_STEPS = 10
STAY_STEP_MOCKTIME = 60


class LegacyOnlyConnectivityTest(QQPursuitTest):
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
            # A one-block chain gives the fixtures a header that connects.
            node.setmocktime(int(time.time()))
            self.generate(node, 1)
            assert not node.getblockchaininfo()["initialblockdownload"]
            self.proxy.unknown_route_delay = 3
            header = from_hex(CBlockHeader(), node.getblockheader(node.getbestblockhash(), False))

            # One reachable legacy publisher is the only address at first.
            publisher = self.endpoint("23.100.0.1", header)
            peers.append(publisher)
            assert node.addpeeraddress(publisher.fixture_ip, 15714, True)["success"]
            node.setnetworkactive(True)
            self.wait_until(lambda: publisher.is_connected)
            publisher.wait_for_verack()
            publisher.sync_with_ping()
            self.wait_until(lambda: len(self.outbound()) == 1)

            # It gossips many QQ-flagged addresses that nobody serves.
            announcement = msg_addr()
            for i in range(DEAD_QQ_HINTS):
                hint = CAddress()
                hint.ip, hint.port = f"24.{1 + i // 2}.{1 + i % 2}.1", 15714
                hint.time = node.mocktime
                hint.nServices = NODE_NETWORK | NODE_QUANTUM_QUASAR
                announcement.addrs.append(hint)
            publisher.send_and_ping(announcement)
            self.wait_until(lambda: len(node.getnodeaddresses(0)) >= DEAD_QQ_HINTS // 2)

            # A few reachable legacy peers become known.
            legacy = [self.endpoint(f"23.{i}.0.1", header) for i in range(1, LEGACY_PEERS + 1)]
            peers.extend(legacy)
            started = time.monotonic()
            for peer in legacy:
                assert node.addpeeraddress(peer.fixture_ip, 15714, True)["success"]

            try:
                self.wait_until(lambda: len(self.outbound()) >= FLOOR, timeout=CONNECT_BOUND)
            except AssertionError:
                raise AssertionError(
                    f"only {len(self.outbound())} outbound peers after {time.monotonic() - started:.1f}s "
                    f"(bound {CONNECT_BOUND}s); qq={node.getnetworkinfo()['qqoutbound']}")
            self.log.info("%d outbound peers after %.1fs", len(self.outbound()), time.monotonic() - started)
            assert_equal(node.getnetworkinfo()["qqoutbound"]["eligible"], 0)

            # They stay for several minutes of mocktime.
            held = {p["id"] for p in self.outbound()}
            for _ in range(STAY_STEPS):
                node.bumpmocktime(STAY_STEP_MOCKTIME)
                time.sleep(1)
                current = {p["id"] for p in self.outbound()}
                assert len(current) >= FLOOR, f"peers dropped: {sorted(held)} -> {sorted(current)}"
                assert held <= {p["id"] for p in node.getpeerinfo()}, "an established peer was disconnected"
            assert_equal(node.getnetworkinfo()["qqoutbound"]["eligible"], 0)
            assert "Potential stale tip detected" not in node.debug_log_path.read_text()
        finally:
            for peer in peers:
                peer.retire()
            node.setnetworkactive(False)
            self.proxy.shutdown()
            self.proxy.server_close()
            self.proxy_thread.join(timeout=5)


if __name__ == "__main__":
    LegacyOnlyConnectivityTest().main()
