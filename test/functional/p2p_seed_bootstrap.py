#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin Core developers
# Distributed under the MIT software license, see COPYING.
"""Empty addrman must bootstrap from queued seed fetches before normal slots fill.

Numeric and absolute-hostname seed destinations use a local SOCKS routing fixture.
Every learned address is routable in Core, but actual sockets remain on localhost.
No addpeeraddress/addconnection call populates addrman or opens the tested peers.
"""
import socket
import threading
import time

from p2p_qq_pursuit import LocalProxy, LocalRoute
from test_framework.messages import CAddress, NODE_NETWORK, msg_addr
from test_framework.p2p import NetworkThread, P2PInterface
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal


class SeedPeer(P2PInterface):
    def __init__(self, learned=None):
        super().__init__()
        self.learned = learned
        self.used = False

    def on_getaddr(self, message):
        response = msg_addr()
        if self.learned:
            response.addrs = [self.learned]
        self.send_message(response)


class SeedBootstrapTest(BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 2
        self.setup_clean_chain = True
        self.disable_autoconnect = False
        self.extra_args = [["-networkactive=0", "-dnsseed=0", "-fixedseeds=0", "-qqoutboundtarget=0", "-v2transport=0", "-onlynet=ipv4", "-debug=net"] for _ in range(2)]

    def register(self, destination, peer):
        peer.peer_connect_helper("0", 0, self.chain, self.options.timeout_factor)
        peer.peer_connect_send_version(NODE_NETWORK)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        ready = threading.Event()
        def registered(address, actual_port):
            self.proxy.routes[destination] = (address, actual_port, peer)
            ready.set()
        NetworkThread.listen(peer, registered, port=port)
        assert ready.wait(5)

    def setup_network(self):
        self.proxy = LocalProxy(("127.0.0.1", 0), LocalRoute)
        self.proxy.routes, self.proxy.requests = {}, []
        self.proxy_thread = threading.Thread(target=self.proxy.serve_forever, daemon=True)
        self.proxy_thread.start()
        self.seeds, self.persistent, self.learned = [], [], []
        self.seed_destinations = ["25.1.0.1", "seed.bootstrap.invalid."]
        for i, destination in enumerate(self.seed_destinations):
            address = CAddress()
            address.ip, address.port = f"26.{i + 1}.0.1", 23802 + i
            address.time, address.nServices = int(time.time()), NODE_NETWORK
            seed, persistent = SeedPeer(address), SeedPeer()
            self.register(destination, seed)
            self.register(address.ip, persistent)
            self.seeds.append(seed)
            self.persistent.append(persistent)
            self.learned.append(address)
            self.extra_args[i] += [f"-proxy=127.0.0.1:{self.proxy.server_address[1]}", "-proxyrandomize=0", f"-seednode={destination}:{23800 + i}"]
        self.setup_nodes()

    def run_test(self):
        try:
            for i, node in enumerate(self.nodes):
                assert_equal(node.getnodeaddresses(0), [])
                assert_equal(node.getconnectioncount(), 0)
                # Pending seed work survives multiple disabled worker passes.
                time.sleep(2)
                assert not self.seeds[i].used
                node.setnetworkactive(True)
                self.seeds[i].wait_until(lambda: self.seeds[i].message_count["verack"] >= 1, check_connected=False)
                self.wait_until(lambda: any(a["address"] == self.learned[i].ip and a["port"] == self.learned[i].port for a in node.getnodeaddresses(0)), timeout=20)
                self.persistent[i].wait_until(lambda: self.persistent[i].message_count["verack"] >= 1, check_connected=False)
                self.wait_until(lambda: any(p["connection_type"] == "outbound-full-relay" and p["addr"] == f"{self.learned[i].ip}:{self.learned[i].port}" for p in node.getpeerinfo()), timeout=20)
                assert (self.seed_destinations[i], 23800 + i) in self.proxy.requests
                assert (self.learned[i].ip, self.learned[i].port) in self.proxy.requests
                # ADDR_FETCH's actual request path, rather than a manual node,
                # obtained the addresses that unlocked ordinary slot recovery.
                self.wait_until(lambda: self.seeds[i].message_count["getaddr"] == 1)
                assert any(p["connection_type"] == "addr-fetch" for p in node.getpeerinfo())
            assert all(destination in self.seed_destinations or destination in {a.ip for a in self.learned} for destination, _ in self.proxy.requests)
        finally:
            for node in self.nodes:
                node.setnetworkactive(False)
            self.proxy.shutdown()
            self.proxy.server_close()
            self.proxy_thread.join(timeout=5)


if __name__ == "__main__":
    SeedBootstrapTest().main()
