#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin Core developers
# Distributed under the MIT software license, see COPYING.
"""The default-level "Peer lost" and "No peers for" log lines say why.

A lost outbound peer is logged at the default level. The line must carry
reason=<token>: remote_closed when the peer closed the socket, a local token when
the node ended the connection (disconnectnode, setban). When the last peer goes,
lost_together counts the peers lost within ten seconds, and addr= appears only
with -logips.

After a minute without peers the node logs "No peers for"; the line must break the
dial failures down by class and carry handshake_fail and network_active. A closed
local port gives refused dials, an unroutable address gives timeouts or
unreachable dials, and a listener that accepts and hangs up gives handshake_fail.
"""
import re
import socket
import threading
import time

from test_framework.p2p import P2PInterface
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import (
    assert_equal,
    assert_greater_than,
)

REGTEST_PORT = 35714
NO_PEERS_WAIT = 150
BASE_ARGS = ["-dnsseed=0", "-fixedseeds=0", "-listen=1"]


class PeerLostReasonTest(BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.disable_autoconnect = False
        self.extra_args = [BASE_ARGS]
        self.log_start = 0

    def log_text(self):
        """What the node logged since mark_log(); debug.log is appended to across restarts."""
        with open(self.nodes[0].debug_log_path, encoding="utf-8", errors="replace") as f:
            return f.read()[self.log_start:]

    def mark_log(self):
        with open(self.nodes[0].debug_log_path, encoding="utf-8", errors="replace") as f:
            self.log_start = len(f.read())

    def lost_lines(self):
        return [line for line in self.log_text().splitlines() if "Peer lost:" in line]

    def wait_for_lost(self, count):
        self.wait_until(lambda: len(self.lost_lines()) >= count)
        return self.lost_lines()

    def run_test(self):
        node = self.nodes[0]

        self.log.info("Three outbound peers close the socket: reason=remote_closed, lost_together on the last")
        peers = [node.add_outbound_p2p_connection(P2PInterface(), p2p_idx=i) for i in range(3)]
        for peer in peers:
            peer.peer_disconnect()
        lines = self.wait_for_lost(3)
        self.log.info(lines[-1])
        for line in lines:
            assert "direction=outbound" in line, line
            assert re.search(r" reason=remote_closed$", line), line
            assert "addr=" not in line, line
        last = [line for line in lines if "peers_remaining=0" in line]
        assert_equal(len(last), 1)
        assert "lost_together=3 " in last[0], last[0]
        assert all("lost_together" not in line for line in lines if "peers_remaining=0" not in line), lines
        self.wait_until(lambda: len(node.getpeerinfo()) == 0)

        self.log.info("A peer dropped with disconnectnode: a local reason")
        self.mark_log()
        peer = node.add_outbound_p2p_connection(P2PInterface(), p2p_idx=0)
        node_id = node.getpeerinfo()[0]["id"]
        node.disconnectnode(nodeid=node_id)
        line = self.wait_for_lost(1)[-1]
        self.log.info(line)
        assert re.search(r" reason=local_rpc$", line), line
        peer.wait_for_disconnect()
        self.wait_until(lambda: len(node.getpeerinfo()) == 0)

        self.log.info("A peer dropped by setban: a local reason")
        self.mark_log()
        peer = node.add_outbound_p2p_connection(P2PInterface(), p2p_idx=0)
        node.setban("127.0.0.1", "add")
        line = self.wait_for_lost(1)[-1]
        self.log.info(line)
        assert re.search(r" reason=local_banned$", line), line
        peer.wait_for_disconnect()
        node.setban("127.0.0.1", "remove")
        self.wait_until(lambda: len(node.getpeerinfo()) == 0)

        self.log.info("-logips adds addr= to the line")
        self.restart_node(0, extra_args=BASE_ARGS + ["-logips=1"])
        self.mark_log()
        peer = node.add_outbound_p2p_connection(P2PInterface(), p2p_idx=0)
        peer.peer_disconnect()
        line = self.wait_for_lost(1)[-1]
        self.log.info(line)
        assert re.search(r" addr=127\.0\.0\.1:\d+ reason=remote_closed$", line), line

        self.log.info("No peers: dial failures are classified, a hang-up before verack is counted")
        hangups = []
        stop = threading.Event()
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", REGTEST_PORT))
        listener.listen(8)
        listener.settimeout(0.2)

        def hang_up():
            while not stop.is_set():
                try:
                    conn, _ = listener.accept()
                except OSError:
                    continue
                hangups.append(1)
                conn.close()

        thread = threading.Thread(target=hang_up)
        thread.start()
        line = None
        try:
            self.restart_node(0, extra_args=BASE_ARGS + ["-timeout=500"])
            self.mark_log()
            # 127.0.0.1 accepts and hangs up; nothing listens on 127.0.0.2; 192.0.2.1 is unroutable.
            # addrman refuses unroutable addresses, so they are dialed as added nodes.
            for address in ("127.0.0.1", "127.0.0.2", "192.0.2.1"):
                node.addnode(f"{address}:{REGTEST_PORT}", "add")
            deadline = time.time() + NO_PEERS_WAIT * self.options.timeout_factor
            while line is None and time.time() < deadline:
                found = [ln for ln in self.log_text().splitlines() if "No peers for" in ln]
                line = found[0] if found else None
                time.sleep(1)
        finally:
            stop.set()
            thread.join()
            listener.close()
        assert line is not None, "no 'No peers for' line"
        self.log.info(line)
        fields = dict(re.findall(r"(\w+)=(\S+)", line))
        for key in ("addrman", "dial_attempts", "dial_failures", "qq_hints", "qq_dials"):
            assert key in fields, line
        names = ("timeout", "refused", "unreachable", "addrnotavail", "other")
        classes = [int(fields["fail_" + name]) for name in names]
        assert_equal(sum(classes), int(fields["dial_failures"]))
        assert_greater_than(int(fields["dial_failures"]), 0)
        assert_greater_than(int(fields["handshake_fail"]), 0)
        assert_greater_than(len(hangups), 0)
        assert fields["last_fail"] in names, line
        assert_equal(fields["network_active"], "1")


if __name__ == '__main__':
    PeerLostReasonTest().main()
