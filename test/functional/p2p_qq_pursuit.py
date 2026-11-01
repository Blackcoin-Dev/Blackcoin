#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin Core developers
# Distributed under the MIT software license, see COPYING.
"""Exercise real automatic QQ probing against a full healthy legacy pool.

All apparently public IPs route through a local SOCKS relay to local P2P peers.
The relay refuses every address outside the fixture; no public nodes are used.
"""
import select
import socket
import socketserver
import threading
import time

from test_framework.messages import CAddress, CBlockHeader, NODE_NETWORK, NODE_QUANTUM_QUASAR, from_hex, msg_addr, msg_headers
from test_framework.p2p import NetworkThread, P2PInterface
from test_framework.socks5 import recvall
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal


class LocalRoute(socketserver.BaseRequestHandler):
    def handle(self):
        upstream = None
        lease_peer = None
        try:
            client = self.request
            ver, count = recvall(client, 2)
            assert ver == 5 and 0 in recvall(client, count)
            client.sendall(b"\x05\x00")
            ver, cmd, _, kind = recvall(client, 4)
            assert ver == 5 and cmd == 1
            if kind == 1:
                destination = socket.inet_ntoa(recvall(client, 4))
            elif kind == 3:
                destination = recvall(client, recvall(client, 1)[0]).decode()
            else:
                raise AssertionError("Fixture permits IPv4 routes only")
            port = int.from_bytes(recvall(client, 2), "big")
            if hasattr(self.server, "requests"):
                self.server.requests.append((destination, port))
            route = self.server.routes.get(destination)
            if route is None:
                available = False
            elif callable(getattr(route[2], "acquire_route", None)):
                available = route[2].acquire_route()
                if available:
                    lease_peer = route[2]
            else:
                # p2p_seed_bootstrap imports this proxy with single-use seeds.
                available = not route[2].used
                if available:
                    route[2].used = True
            if not available:
                client.sendall(b"\x05\x04\x00\x01" + bytes(6))
                return
            upstream = socket.create_connection(route[:2], timeout=5)
            client.sendall(b"\x05\x00\x00\x01" + bytes(6))
            client.settimeout(None)
            upstream.settimeout(None)
            while True:
                ready, _, _ = select.select([client, upstream], [], [], 1)
                for source in ready:
                    data = source.recv(65536)
                    if not data:
                        return
                    (upstream if source is client else client).sendall(data)
        except (OSError, IOError):
            pass
        finally:
            if upstream:
                upstream.close()
            if lease_peer is not None:
                lease_peer.release_route()


class LocalProxy(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


class QuietPeer(P2PInterface):
    def __init__(self, header, empty_first=False):
        super().__init__()
        self.header = header
        self.empty_first = empty_first
        self.benchmark_challenges = []
        self._route_lock = threading.Lock()
        self._route_enabled = True
        self._route_active = False
        self._route_ready = False
        self._reconnect = None
        self.connection_count = 0

    def configure_reconnect(self, net, timeout_factor, services, port, registered):
        self._reconnect = (net, timeout_factor, services, port, registered)
        self._prepare_session()

    def _prepare_session(self):
        # P2PInterface and NetworkThread listeners are single-session objects:
        # reset handshake/message state and re-register before admitting a retry.
        P2PInterface.__init__(self)
        self.benchmark_challenges = []
        net, timeout_factor, services, _port, _registered = self._reconnect
        self.peer_connect_helper("0", 0, net, timeout_factor)
        self.peer_connect_send_version(services)

    def route_ready(self):
        with self._route_lock:
            self._route_ready = self._route_enabled

    def acquire_route(self):
        with self._route_lock:
            if not self._route_enabled or self._route_active or not self._route_ready:
                return False
            self._route_active = True
            return True

    def release_route(self):
        with self._route_lock:
            self._route_active = False

    def on_open(self):
        with self._route_lock:
            self._route_ready = False
            self.connection_count += 1
            enabled = self._route_enabled
        if not enabled:
            self._transport.abort()

    def on_close(self):
        with self._route_lock:
            self._route_ready = False
            enabled = self._route_enabled
        if enabled and self._reconnect is not None:
            self._prepare_session()
            _net, _timeout_factor, _services, port, registered = self._reconnect
            NetworkThread.listen(self, registered, port=port)

    def retire(self):
        # An intentional removal stays unavailable; transport failures do not.
        with self._route_lock:
            self._route_enabled = False
            self._route_ready = False
        self.peer_disconnect()

    def on_getheaders(self, message):
        if message.hashstop:
            self.benchmark_challenges.append(time.monotonic())
        # A false first response must not accidentally qualify through a
        # separate ordinary initial-sync request before the bounded retry.
        empty = self.empty_first and len(self.benchmark_challenges) < 2
        self.send_message(msg_headers([] if empty else [self.header]))


class QQPursuitTest(BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.disable_autoconnect = False
        self.extra_args = [["-networkactive=0", "-dnsseed=0", "-fixedseeds=0", "-onlynet=ipv4", "-maxconnections=19", "-v2transport=0", "-debug=net"]]

        self.target = self.options.qq_target
        if self.target != 8:
            self.extra_args[0].append(f"-qqoutboundtarget={self.target}")

    def add_options(self, parser):
        parser.add_argument("--qq-target", type=int, choices=[2, 8], default=8,
                            help="Use the actual default-eight policy, or a shorter explicit target-two run")

    def setup_network(self):
        self.proxy = LocalProxy(("127.0.0.1", 0), LocalRoute)
        self.proxy.routes = {}
        self.proxy_thread = threading.Thread(target=self.proxy.serve_forever, daemon=True)
        self.proxy_thread.start()
        self.extra_args[0].append(f"-proxy=127.0.0.1:{self.proxy.server_address[1]}")
        self.extra_args[0].append("-proxyrandomize=0")
        self.setup_nodes()

    def endpoint(self, ip, header, qq=False, empty_first=False):
        peer = QuietPeer(header, empty_first=empty_first)
        peer.fixture_ip = ip
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        ready = threading.Event()

        def registered(address, actual_port):
            self.proxy.routes[ip] = (address, actual_port, peer)
            peer.route_ready()
            ready.set()
        peer.configure_reconnect(self.chain, self.options.timeout_factor,
                                 NODE_NETWORK | (NODE_QUANTUM_QUASAR if qq else 0),
                                 port, registered)
        NetworkThread.listen(peer, registered, port=port)
        assert ready.wait(5)
        return peer

    def evaluate(self):
        node = self.nodes[0]
        generation = node.getnetworkinfo()["qqoutbound"]["generation"]
        node.mockscheduler(46)
        self.wait_until(lambda: node.getnetworkinfo()["qqoutbound"]["generation"] > generation)

    def wait_qualified(self, count):
        node = self.nodes[0]
        deadline = time.monotonic() + count * 80 + 160
        last_count = node.getnetworkinfo()["qqoutbound"]["eligible"]
        while time.monotonic() < deadline:
            # Advance the existing minimum-age clock only once per new peer,
            # preserving a fresh tip. QQ retries/residence use real steady time.
            new_ids = {p["id"] for p in node.getpeerinfo()} - self.aged_peers
            if new_ids:
                node.bumpmocktime(31)
                self.aged_peers.update(new_ids)
            self.evaluate()
            status = node.getnetworkinfo()["qqoutbound"]
            if status["eligible"] > last_count:
                # Restore the wall mock after an aged candidate is retained.
                # This keeps the same quiet tip fresh during default-eight's
                # several real steady-clock retry intervals. It never advances
                # the independent QQ retry/residence clock.
                self.wait_until(lambda: sum(p["connection_type"] == "outbound-full-relay" for p in node.getpeerinfo()) == 16)
                self.evaluate()
                node.setmocktime(self.age_base)
                last_count = status["eligible"]
            if status["eligible"] == count:
                return
            time.sleep(1)
        raise AssertionError(f"QQ target not reached: {node.getnetworkinfo()['qqoutbound']}")

    def run_test(self):
        node = self.nodes[0]
        peers = []
        qq_peers = []
        try:
            node.setmocktime(int(time.time()))
            self.generate(node, 1)
            self.age_base = node.mocktime
            assert_equal(node.getnetworkinfo()["qqoutbound"]["target"], self.target)
            header = from_hex(CBlockHeader(), node.getblockheader(node.getbestblockhash(), False))
            # Eighteen distinct /16 groups fill sixteen full-relay and two block-relay slots.
            for i in range(18):
                ip = f"23.{i + 1}.0.1"
                peers.append(self.endpoint(ip, header))
                assert node.addpeeraddress(ip, 15714, True)["success"]
            node.setnetworkactive(True)
            self.wait_until(lambda: sum(p["connection_type"] == "outbound-full-relay" for p in node.getpeerinfo()) == 16, timeout=60)
            self.wait_until(lambda: sum(p["connection_type"] == "block-relay-only" for p in node.getpeerinfo()) == 2, timeout=60)
            self.wait_until(lambda: all(p.get("synced_headers", -1) >= 1 for p in node.getpeerinfo()), timeout=30)
            original = {p["id"] for p in node.getpeerinfo() if p["connection_type"] == "outbound-full-relay"}
            node.bumpmocktime(31)
            self.aged_peers = {p["id"] for p in node.getpeerinfo()}
            self.evaluate()
            assert_equal(node.getnetworkinfo()["qqoutbound"]["eligible"], 0)
            assert_equal(node.getnetworkinfo()["qqoutbound"]["deficit"], self.target)
            # Gossip genuine hints through an existing full peer, preserving
            # addrman source/bucket selection instead of injecting a flat list.
            full_ips = {p["addr"].split(":")[0] for p in node.getpeerinfo() if p["connection_type"] == "outbound-full-relay"}
            publisher = next(p for p in peers if p.is_connected and p.fixture_ip in full_ips)
            advertised = []
            for i in range(self.target + 1):
                ip = f"24.{i + 1}.0.1"
                qq_peers.append(self.endpoint(ip, header, qq=True, empty_first=(i == 0)))
                addr = CAddress()
                addr.ip, addr.port = ip, 15714
                addr.time, addr.nServices = node.mocktime, NODE_NETWORK | NODE_QUANTUM_QUASAR
                advertised.append(addr)
            announcement = msg_addr()
            announcement.addrs = advertised[:self.target]
            publisher.send_and_ping(announcement)
            self.wait_qualified(self.target)
            self.wait_until(lambda: sum(p["connection_type"] == "outbound-full-relay" for p in node.getpeerinfo()) == 16)
            self.evaluate()  # Retired victim has now returned its actual grant.
            current = node.getpeerinfo()
            assert_equal(sum(p["connection_type"] == "outbound-full-relay" for p in current), 16)
            assert_equal(len(original - {p["id"] for p in current}), self.target)
            assert node.getnetworkinfo()["qqoutbound"]["connect_attempts"] >= self.target
            challenges = qq_peers[0].benchmark_challenges
            assert_equal(len(challenges), 2)
            assert 25 <= challenges[1] - challenges[0] < 120
            assert "Potential stale tip detected" not in node.debug_log_path.read_text()
            assert not node.getnetworkinfo()["qqoutbound"]["pending"]
            # The four legacy peers protected after accepted headers must survive.
            log = node.debug_log_path.read_text()
            protected = {peer_id for peer_id in original if f"Protecting outbound peer={peer_id} from eviction" in log}
            assert_equal(len(protected), 4)
            assert protected.issubset({p["id"] for p in current})
            qq_peers[0].retire()
            self.wait_until(lambda: not qq_peers[0].is_connected)
            self.evaluate()
            assert_equal(node.getnetworkinfo()["qqoutbound"]["deficit"], 1)
            # Publish a new useful endpoint; healthy legacy peers remain throughout.
            full_ips = {p["addr"].split(":")[0] for p in node.getpeerinfo() if p["connection_type"] == "outbound-full-relay"}
            publisher = next(p for p in peers if p.is_connected and p.fixture_ip in full_ips)
            advertised[self.target].time = node.mocktime
            announcement = msg_addr()
            announcement.addrs = [advertised[self.target]]
            publisher.send_and_ping(announcement)
            self.wait_qualified(self.target)
            assert_equal(sum(p["connection_type"] == "outbound-full-relay" for p in node.getpeerinfo()), 16)
            assert protected.issubset({p["id"] for p in node.getpeerinfo()})
        finally:
            for peer in peers + qq_peers:
                peer.retire()
            node.setnetworkactive(False)
            self.proxy.shutdown()
            self.proxy.server_close()
            self.proxy_thread.join(timeout=5)


if __name__ == "__main__":
    QQPursuitTest().main()
