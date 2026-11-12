#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin Core developers
# Distributed under the MIT software license, see COPYING.
"""Test -publicendpointfile: a runtime public address and port from a datadir file.

The node polls a small JSON file. With a valid pair (two identical reads) it
opens an extra listening socket on 0.0.0.0:F, adds A:F to its local addresses,
and advertises exactly that pair. Anything else withdraws: it closes the runtime
socket, removes the local address and advertises nothing. The configured
listener is never touched.

Time is controlled with mocktime (file ages and the future check). The 15 s poll
is shortened with the regtest-only -publicendpointpollinterval option; real
time still drives the poller's sleep.
"""
import json
import os
import socket
import time

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, p2p_port, rpc_port

FILE = "pe.json"
SCHEMA = "blackcoin.public-endpoint/1"
ADDR1 = "8.8.4.4"
ADDR2 = "8.8.8.8"


def port_open(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return True
    except OSError:
        return False


class PublicEndpointTest(BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 2
        self.setup_clean_chain = True
        self.extra_args = [[], []]

    # ---- helpers ----
    @property
    def node0(self):
        return self.nodes[0]

    @property
    def datadir_path(self):
        # the network data directory (datadir/regtest here, the datadir itself on mainnet)
        return os.path.join(self.node0.chain_path, FILE)

    def now(self):
        return self.node0.mocktime

    def write(self, content, name=FILE):
        tmp = os.path.join(self.node0.chain_path, name + ".tmp")
        with open(tmp, "wb") as f:
            f.write(content if isinstance(content, bytes) else content.encode())
        os.replace(tmp, os.path.join(self.node0.chain_path, name))

    def tuple_json(self, address, port, observed_at=None, **override):
        obj = {"schema": SCHEMA, "address": address, "port": port,
               "observed_at": self.now() if observed_at is None else observed_at}
        obj.update(override)
        return json.dumps(obj, separators=(",", ":"))

    def info(self):
        return self.node0.getnetworkinfo()

    def pe(self):
        return self.info().get("publicendpoint")

    def local(self):
        return [(a["address"], a["port"]) for a in self.info()["localaddresses"]]

    def is_active(self, address, port):
        pe = self.pe()
        return bool(pe and pe["active"] and pe["address"] == address and pe["port"] == port and (address, port) in self.local())

    def wait_active(self, address, port, timeout=30):
        self.wait_until(lambda: self.is_active(address, port), timeout=timeout)
        self.wait_until(lambda: port_open(port), timeout=10)

    def assert_withdrawn(self, status_part, closed_ports, timeout=30):
        self.wait_until(lambda: self.pe() is not None and not self.pe()["active"], timeout=timeout)
        pe = self.pe()
        assert status_part in pe["status"], pe
        assert_equal(pe["listening"], False)
        assert "address" not in pe and "port" not in pe
        assert_equal(self.local(), [])
        for port in closed_ports:
            self.wait_until(lambda p=port: not port_open(p), timeout=10)

    def restart0(self, *args):
        now = self.now()
        self.restart_node(0, extra_args=["-debug=net", *args])
        self.node0.setmocktime(now)

    def base_args(self, **kw):
        return [f"-publicendpointfile={FILE}", "-publicendpointpollinterval=1",
                f"-publicendpointmaxage={kw.get('maxage', 600)}"]

    def dlog(self):
        return self.node0.debug_log_path.read_text(encoding="utf8", errors="replace")

    # ---- test ----
    def run_test(self):
        node0, node1 = self.nodes
        p0 = p2p_port(0)
        f1, f2, f3, f4 = (p2p_port(n) for n in (4, 5, 6, 7))
        t0 = int(time.time())
        for n in self.nodes:
            n.setmocktime(t0)
        self.generate(node0, 1, sync_fun=self.no_op)
        assert not node0.getblockchaininfo()["initialblockdownload"]

        self.log.info("Feature off: nothing changes even with a valid file present")
        self.write(self.tuple_json(ADDR1, f1))
        time.sleep(2.5)
        assert "publicendpoint" not in self.info()
        assert_equal(self.local(), [])
        assert not port_open(f1)
        assert port_open(p0)
        assert "Public endpoint" not in self.dlog()

        self.log.info("Rejected option values")
        self.stop_node(0)
        node0.assert_start_raises_init_error(["-publicendpointfile=../x"], "Error: -publicendpointfile must be a plain file name inside the data directory (no path, no '..')")
        node0.assert_start_raises_init_error([f"-publicendpointfile={FILE}", "-publicendpointmaxage=0"], "Error: -publicendpointmaxage must be between 1 and 86400 seconds")
        node0.assert_start_raises_init_error([f"-publicendpointfile={FILE}", "-publicendpointmaxage=86401"], "Error: -publicendpointmaxage must be between 1 and 86400 seconds")
        node0.assert_start_raises_init_error(["-publicendpointpollinterval=0"], "Error: -publicendpointpollinterval must be between 1 and 60 seconds")
        os.remove(self.datadir_path)

        self.log.info("Feature on, no file: inactive, nothing advertised")
        # An -externalip is configured; with the feature on it must not be advertised.
        self.start_node(0, extra_args=["-debug=net", "-externalip=1.2.3.4", *self.base_args()])
        node0.setmocktime(t0)
        self.wait_until(lambda: self.pe() is not None)
        assert_equal(self.pe()["active"], False)
        assert "file not found" in self.pe()["status"]
        assert_equal(self.local(), [])
        assert not port_open(f1)
        assert port_open(p0)

        self.log.info("A valid file is applied after two identical reads; A:F listens and is advertised")
        self.write(self.tuple_json(ADDR1, f1))
        self.wait_active(ADDR1, f1)
        assert_equal(self.local(), [(ADDR1, f1)])
        assert_equal(self.pe()["listening"], True)
        assert_equal(self.pe()["status"], "active")
        assert_equal(self.pe()["age"], 0)
        assert port_open(p0), "configured listener must stay up"
        assert "Public endpoint now 8.8.4.4:%d (listening on 0.0.0.0:%d)" % (f1, f1) in self.dlog()

        self.log.info("A second node connects inbound on 127.0.0.1:F")
        node1.addnode(f"127.0.0.1:{f1}", "onetry")
        self.wait_until(lambda: any(p["inbound"] and p["addrbind"] == f"127.0.0.1:{f1}" for p in node0.getpeerinfo()))
        self.wait_until(lambda: any((a["address"], a["port"]) == (ADDR1, f1) for a in node1.getnodeaddresses(0)), timeout=20)
        announced_at = time.time()

        self.log.info("Changing the port moves the listener and the advertisement")
        # unsolicited addr from one peer is rate limited to one per 10 s: let the bucket refill
        time.sleep(max(0, 12 - (time.time() - announced_at)))
        self.write(self.tuple_json(ADDR1, f2))
        self.wait_active(ADDR1, f2)
        assert_equal(self.local(), [(ADDR1, f2)])
        self.wait_until(lambda: not port_open(f1), timeout=10)
        assert port_open(p0)
        assert port_open(f2)
        # the existing inbound connection (accepted on the old runtime socket) is not dropped
        assert any(p["inbound"] and p["addrbind"] == f"127.0.0.1:{f1}" for p in node0.getpeerinfo())
        # promptly re-announced to the connected peer (no daily timer wait)
        self.wait_until(lambda: any((a["address"], a["port"]) == (ADDR1, f2) for a in node1.getnodeaddresses(0)), timeout=20)
        assert "Public endpoint now 8.8.4.4:%d, was 8.8.4.4:%d (listening on 0.0.0.0:%d)" % (f2, f1, f2) in self.dlog()

        self.log.info("Changing only the address keeps the listener")
        self.write(self.tuple_json(ADDR2, f2))
        self.wait_active(ADDR2, f2)
        assert_equal(self.local(), [(ADDR2, f2)])
        assert port_open(f2)

        self.log.info("Refreshed observed_at keeps the pair and the age follows mocktime")
        node0.bumpmocktime(30)
        self.write(self.tuple_json(ADDR2, f2))
        self.wait_until(lambda: self.pe()["active"] and self.pe()["age"] == 0)
        node0.bumpmocktime(20)
        assert_equal(self.pe()["age"], 20)
        self.write(self.tuple_json(ADDR2, f2))

        self.log.info("Bad files withdraw at once and a good file brings the pair back after two reads")
        big = self.tuple_json(ADDR2, f2)[:-1] + "," + ' ' * 280 + "}"
        cases = [
            ("stale", lambda: self.tuple_json(ADDR2, f2, self.now() - 601), "older than the maximum age"),
            ("future", lambda: self.tuple_json(ADDR2, f2, self.now() + 61), "in the future"),
            ("malformed", lambda: "{not json", "not a JSON object"),
            ("empty", lambda: "", "empty file"),
            ("oversize", lambda: big, "larger than 256 bytes"),
            ("extra key", lambda: self.tuple_json(ADDR2, f2, extra=1), "unexpected keys"),
            ("wrong schema", lambda: self.tuple_json(ADDR2, f2, schema="blackcoin.public-endpoint/2"), "unknown schema"),
            ("string port", lambda: self.tuple_json(ADDR2, str(f2)), "wrong value type"),
            ("private address", lambda: self.tuple_json("10.0.0.1", f2), "canonical public IPv4"),
            ("rpc port", lambda: self.tuple_json(ADDR2, rpc_port(0)), "reserved"),
        ]
        for name, content, expect in cases:
            self.log.info("  withdraw: %s", name)
            self.write(content())
            self.assert_withdrawn(expect, [f2])
            assert port_open(p0)
            self.write(self.tuple_json(ADDR2, f2))
            self.wait_active(ADDR2, f2)
        # clock skew up to 60 s ahead is tolerated
        self.write(self.tuple_json(ADDR2, f2, self.now() + 60))
        time.sleep(3)
        assert self.is_active(ADDR2, f2)
        self.write(self.tuple_json(ADDR2, f2))

        self.log.info("  withdraw: symbolic link")
        real = os.path.join(node0.chain_path, "real.json")
        self.write(self.tuple_json(ADDR2, f2), "real.json")
        os.remove(self.datadir_path)
        os.symlink(real, self.datadir_path)
        self.assert_withdrawn("symbolic link", [f2])
        os.remove(self.datadir_path)
        self.write(self.tuple_json(ADDR2, f2))
        self.wait_active(ADDR2, f2)

        self.log.info("  withdraw: file removed")
        os.remove(self.datadir_path)
        self.assert_withdrawn("file not found", [f2])
        assert "Public endpoint withdrawn: file not found" in self.dlog()
        self.write(self.tuple_json(ADDR2, f2))
        self.wait_active(ADDR2, f2)

        self.log.info("  withdraw: a directory in place of the file")
        os.remove(self.datadir_path)
        os.mkdir(self.datadir_path)
        self.assert_withdrawn("not a regular file", [f2])
        os.rmdir(self.datadir_path)
        self.write(self.tuple_json(ADDR2, f2))
        self.wait_active(ADDR2, f2)

        self.log.info("Withdrawal logs once per withdrawal, not once per poll")
        count_before = self.dlog().count("Public endpoint withdrawn:")
        self.write("{bad")
        self.assert_withdrawn("not a JSON object", [f2])
        time.sleep(3)
        assert_equal(self.dlog().count("Public endpoint withdrawn:"), count_before + 1)

        self.log.info("Bind failure on F withdraws, logs once, and retries until it works")
        blocker = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        blocker.bind(("0.0.0.0", f3))
        blocker.listen(1)
        try:
            self.write(self.tuple_json(ADDR1, f3))
            self.wait_until(lambda: self.pe() is not None and "cannot listen on 0.0.0.0:%d" % f3 in self.pe()["status"], timeout=30)
            assert_equal(self.pe()["active"], False)
            assert_equal(self.pe()["listening"], False)
            assert_equal(self.local(), [])
            time.sleep(4)  # several retries
            assert_equal(self.dlog().count("Public endpoint withdrawn: cannot listen on 0.0.0.0:%d" % f3), 1)
        finally:
            blocker.close()
        self.wait_active(ADDR1, f3, timeout=30)
        assert_equal(self.local(), [(ADDR1, f3)])

        self.log.info("The internal port was never advertised and the configured -externalip never was")
        for line in self.dlog().splitlines():
            if "Advertising address" in line:
                assert ":%d to peer" % p0 not in line, line
                assert "1.2.3.4" not in line, line
        assert "AddLocal(1.2.3.4" not in self.dlog()

        self.log.info("Ages out with the clock")
        self.restart0(*self.base_args(maxage=6))
        self.write(self.tuple_json(ADDR1, f4))
        self.wait_active(ADDR1, f4)
        node0.bumpmocktime(5)
        self.write(self.tuple_json(ADDR1, f4, node0.mocktime - 5))
        time.sleep(2.5)
        assert self.is_active(ADDR1, f4)
        node0.bumpmocktime(3)  # now 8 s past observed_at, maximum 6
        self.assert_withdrawn("older than the maximum age", [f4])

        self.log.info("Shutdown with an active pair is clean")
        self.write(self.tuple_json(ADDR1, f4, node0.mocktime))
        self.wait_active(ADDR1, f4)
        self.stop_node(0)
        assert not port_open(f4)
        assert "Public endpoint" in self.dlog()

        self.log.info("Inert with -listen=0 and with an IPv4 proxy")
        self.start_node(0, extra_args=["-debug=net", "-nobind", "-listen=0", *self.base_args()])
        node0.setmocktime(t0)
        self.write(self.tuple_json(ADDR1, f4, node0.mocktime))
        time.sleep(3)
        assert "publicendpoint" not in self.info()
        assert not port_open(f4)
        assert_equal(self.local(), [])
        self.stop_node(0)
        self.start_node(0, extra_args=["-debug=net", "-proxy=127.0.0.1:9", *self.base_args()])
        node0.setmocktime(t0)
        self.write(self.tuple_json(ADDR1, f4, node0.mocktime))
        time.sleep(3)
        assert "publicendpoint" not in self.info()
        assert not port_open(f4)
        assert_equal(self.local(), [])
        assert "-publicendpointfile ignored" in self.dlog()


if __name__ == '__main__':
    PublicEndpointTest().main()
