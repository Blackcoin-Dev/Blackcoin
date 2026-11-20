#!/usr/bin/env python3
# Copyright (c) 2021 The Bitcoin Core developers
# Copyright (c) 2021 Blackcoin Core Developers
# Copyright (c) 2021 Blackcoin More Developers
# Copyright (c) 2021 Blackcoin Developers
# Copyright (c) 2026 The Blackcoin Core developers
# Distributed under the MIT software license, see COPYING.
"""Persistent DNS discovery respects independent causes and explicit privacy modes.

Regtest's only provider is dummySeed.invalid.; proxy observations use a local
SOCKS server. These tests do not query public seeds or infer resolver packet
behavior from logs alone. The 30-minute steady cooldown is checked for premature
re-entry, not shortened using wall mocktime or mockscheduler.
"""
import itertools
import time

from test_framework.p2p import P2PInterface
from test_framework.socks5 import Socks5Configuration, Socks5Server
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal


class P2PDNSSeeds(BitcoinTestFramework):
    def set_test_params(self):
        self.setup_clean_chain = True
        self.num_nodes = 1
        self.disable_autoconnect = False
        self.extra_args = [["-dnsseed=0", "-fixedseeds=0", "-debug=net"]]

    def restart(self, *args):
        self.restart_node(0, extra_args=["-fixedseeds=0", "-debug=net", *args])

    def run_test(self):
        self.init_arg_tests()
        self.existing_peers_test()
        self.force_dns_test()
        self.network_policy_tests()
        self.wait_time_tests()

    def round_count(self):
        return self.nodes[0].debug_log_path.read_text().count("DNS discovery round:")

    def init_arg_tests(self):
        node = self.nodes[0]
        fakeaddr = "fakenodeaddr.fakedomain.invalid."
        self.stop_node(0)
        with node.assert_debug_log(expected_msgs=["DNS seeding disabled"]):
            self.start_node(0, [f"-connect={fakeaddr}", "-fixedseeds=0", "-debug=net"])
        before = self.round_count()
        # Explicit DNS enable does not override connect-only automation policy.
        self.restart(f"-connect={fakeaddr}", "-dnsseed=1", "-forcednsseed=1")
        time.sleep(3)
        assert_equal(self.round_count(), before)
        for args in (["-forcednsseed=1", "-dnsseed=0"], ["-forcednsseed=1", f"-connect={fakeaddr}"]):
            self.stop_node(0)
            node.assert_start_raises_init_error(
                expected_msg="Error: Cannot set -forcednsseed to true when setting -dnsseed to false.",
                extra_args=args,
            )
        self.start_node(0, ["-dnsseed=0", "-fixedseeds=0", "-debug=net"])

    def add_two_full_peers(self):
        for i in range(2):
            self.nodes[0].add_outbound_p2p_connection(P2PInterface(), p2p_idx=i)

    def existing_peers_test(self):
        node = self.nodes[0]
        node.addpeeraddress("192.0.0.8", 15714)
        self.stop_node(0)
        with node.assert_debug_log(expected_msgs=["P2P peers available. Skipped DNS seeding."], timeout=20):
            self.start_node(0, ["-dnsseed=1", "-fixedseeds=0", "-qqoutboundtarget=0", "-debug=net"])
            self.add_two_full_peers()
        # Healthy legacy peers suppress total-outage discovery but do not
        # suppress the default independent QQ deficit cause.
        self.stop_node(0)
        with node.assert_debug_log(expected_msgs=["DNS discovery round: providers=1 qq_deficit=1 outage=0"], timeout=20):
            self.start_node(0, ["-dnsseed=1", "-fixedseeds=0", "-debug=net"])
            self.add_two_full_peers()
        before = self.round_count()
        # Repeated cause changes and large wall/scheduler jumps do not bypass
        # the elapsed-time provider cooldown.
        node.setnetworkactive(False)
        self.wait_until(lambda: node.getconnectioncount() == 0)
        node.setnetworkactive(True)
        node.setmocktime(int(time.time()) + 24 * 60 * 60)
        node.mockscheduler(3600)  # Maximum accepted advance per RPC call.
        time.sleep(3)
        assert_equal(self.round_count(), before)
        node.setmocktime(0)

    def force_dns_test(self):
        node = self.nodes[0]
        self.stop_node(0)
        # Disable network until both test peer listeners are registered;
        # forced startup must still run after two healthy peers connect.
        self.start_node(0, ["-dnsseed=1", "-forcednsseed=1", "-networkactive=0", "-qqoutboundtarget=0", "-fixedseeds=0", "-debug=net"])
        with node.assert_debug_log(expected_msgs=["DNS discovery round: providers=1 qq_deficit=0 outage=0"], timeout=10):
            # Actual peer setup takes less than the worker's one-second poll.
            node.setnetworkactive(True)
            self.add_two_full_peers()
        # Preserve -dns=0's destination-lookup meaning: explicit DNS seeding
        # is independently enabled and still runs against .invalid.
        self.stop_node(0)
        with node.assert_debug_log(expected_msgs=["DNS discovery round: providers=1"], timeout=10):
            self.start_node(0, ["-dnsseed=1", "-dns=0", "-forcednsseed=1", "-fixedseeds=0", "-debug=net"])

    def network_policy_tests(self):
        node = self.nodes[0]
        before = self.round_count()
        self.restart("-dnsseed=1", "-forcednsseed=1", "-networkactive=0")
        time.sleep(3)
        assert_equal(self.round_count(), before)
        with node.assert_debug_log(expected_msgs=["DNS discovery round: providers=1"], timeout=10):
            node.setnetworkactive(True)
        # Preserve initialization's explicit privacy conflict: DNS seeds are
        # IPv4/IPv6 sources, so onion-only mode rejects an explicit request.
        self.stop_node(0)
        node.assert_start_raises_init_error(
            extra_args=["-dnsseed=1", "-onlynet=onion", "-fixedseeds=0"],
            expected_msg="Error: Incompatible options: -dnsseed=1 was explicitly specified, but -onlynet forbids connections to IPv4/IPv6",
        )
        conf = Socks5Configuration()
        conf.addr, conf.unauth = ("127.0.0.1", 0), True
        proxy = Socks5Server(conf)
        proxy.conf.addr = proxy.s.getsockname()
        proxy.start()
        try:
            self.start_node(0, ["-dnsseed=1", "-forcednsseed=1", "-onlynet=ipv4", "-fixedseeds=0", "-debug=net", f"-proxy=127.0.0.1:{proxy.conf.addr[1]}", "-proxyrandomize=0"])
            deadline = time.monotonic() + 15
            while True:
                command = proxy.queue.get(timeout=max(0.1, deadline - time.monotonic()))
                if isinstance(command, Exception):
                    raise command
                assert not command.addr.startswith(b"x1000001.")
                if command.addr == b"dummySeed.invalid.":
                    break
                assert time.monotonic() < deadline
            assert_equal(command.addr, b"dummySeed.invalid.")
            # Queued V1 fallback is allowed, but no repeated discovery round.
            before = self.round_count()
            time.sleep(3)
            assert_equal(self.round_count(), before)
        finally:
            node.setnetworkactive(False)
            proxy.stop()

    def wait_time_tests(self):
        node = self.nodes[0]
        # Startup diagnostics preserve the original privacy delays. These
        # checks observe scheduling, without waiting through five minutes.
        for i in range(5):
            node.addpeeraddress(f"192.0.0.{i}", 15714)
        self.stop_node(0)
        with node.assert_debug_log(expected_msgs=["Waiting 11 seconds before querying DNS seeds."]):
            self.start_node(0, ["-dnsseed=1", "-networkactive=0", "-fixedseeds=0", "-debug=net"])
        for i in itertools.count():
            node.addpeeraddress(f"{i % 2 + 1}.{i % 256}.{i % 100}.1", 15714)
            if i > 1000 and i % 100 == 0 and len(node.getnodeaddresses(0)) > 1000:
                break
        self.stop_node(0)
        with node.assert_debug_log(expected_msgs=["Waiting 300 seconds before querying DNS seeds."]):
            self.start_node(0, ["-dnsseed=1", "-networkactive=0", "-fixedseeds=0", "-debug=net"])


if __name__ == "__main__":
    P2PDNSSeeds().main()
