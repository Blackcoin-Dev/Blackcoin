#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin Core developers
# Distributed under the MIT software license, see COPYING.
"""A P2P listen bind that hits "address in use" at startup is retried for a bounded time.

A listen port inside the ephemeral range can be held for a moment by another
process's outgoing connection. The node used to give up at once. It must now wait,
bind as soon as the port is free, and still fail with the same error when the port
stays taken past the bound. The blocker below is a plain listening socket without
SO_REUSEADDR, so it blocks the node's bind even though the node sets SO_REUSEADDR.
"""
import re
import socket
import time

from test_framework.test_framework import BitcoinTestFramework
from test_framework.test_node import ErrorMatch
from test_framework.util import assert_equal, assert_greater_than_or_equal, p2p_port

RETRY_LINE = "is in use; retrying for up to"
SUCCESS_LINE = "after retrying for"


class BindRetryTest(BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        # The test passes its own -bind; do not let the framework add one.
        self.bind_to_localhost_only = False

    def setup_network(self):
        # The test starts the node itself, with its own arguments.
        self.add_nodes(self.num_nodes)

    log_start = 0

    def block_port(self, port):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        # Deliberately no SO_REUSEADDR: it must really block the node's bind.
        sock.bind(("127.0.0.1", port))
        sock.listen(1)
        return sock

    def log_text(self, node):
        # Only what the current start wrote: debug.log is appended to across restarts.
        try:
            with open(node.debug_log_path, encoding="utf-8", errors="replace") as f:
                return f.read()[self.log_start:]
        except FileNotFoundError:
            return ""

    def mark_log(self, node):
        self.log_start = len(self.log_text(node)) + self.log_start

    def run_test(self):
        node = self.nodes[0]
        port = p2p_port(0)
        bind_arg = f"-bind=127.0.0.1:{port}"
        listen_args = [bind_arg, "-listen=1"]
        error = f"Error: Unable to bind to 127.0.0.1:{port} on this computer. Blackcoin is probably already running."

        self.log.info("Port released during the wait: the node starts and listens")
        blocker = self.block_port(port)
        try:
            node.start(extra_args=listen_args + ["-bindretryseconds=30"])
            self.wait_until(lambda: RETRY_LINE in self.log_text(node), timeout=30)
            # The node really got EADDRINUSE and is still waiting.
            assert "Bound to 127.0.0.1" not in self.log_text(node)
            assert error[len('Error: '):] not in self.log_text(node)
            time.sleep(2)
            assert node.process.poll() is None
        finally:
            blocker.close()
        node.wait_for_rpc_connection()
        text = self.log_text(node)
        assert f"Listen address 127.0.0.1:{port} is in use; retrying for up to 30 seconds" in text
        assert f"Bound to 127.0.0.1:{port} after retrying for" in text
        assert error[len('Error: '):] not in text
        # Listening: a plain TCP connection to the P2P port is accepted.
        with socket.create_connection(("127.0.0.1", port), timeout=10):
            pass
        self.stop_node(0)

        self.log.info("Port still held past the bound: same error as before")
        self.mark_log(node)
        blocker = self.block_port(port)
        try:
            start = time.time()
            node.assert_start_raises_init_error(
                extra_args=listen_args + ["-bindretryseconds=3"],
                expected_msg=re.escape(error) + "\nError: Failed to listen on any port. Use -listen=0 if you want this.",
                match=ErrorMatch.FULL_REGEX)
            assert_greater_than_or_equal(time.time() - start, 3)
            text = self.log_text(node)
            assert f"Listen address 127.0.0.1:{port} is in use; retrying for up to 3 seconds" in text
            assert SUCCESS_LINE not in text
        finally:
            blocker.close()

        self.log.info("A shutdown request ends the wait promptly")
        self.mark_log(node)
        blocker = self.block_port(port)
        try:
            node.start(extra_args=listen_args + ["-bindretryseconds=600"])
            self.wait_until(lambda: RETRY_LINE in self.log_text(node), timeout=30)
            start = time.time()
            node.process.terminate()
            node.process.wait(timeout=15)
            assert time.time() - start < 10
            node.running = False
            node.process = None
            assert "Shutdown requested while waiting to bind" in self.log_text(node)
        finally:
            blocker.close()

        self.log.info("No retry when the wait is disabled")
        self.mark_log(node)
        blocker = self.block_port(port)
        try:
            start = time.time()
            node.assert_start_raises_init_error(
                extra_args=listen_args + ["-bindretryseconds=0"],
                expected_msg=re.escape(error) + "\nError: Failed to listen on any port. Use -listen=0 if you want this.",
                match=ErrorMatch.FULL_REGEX)
            assert RETRY_LINE not in self.log_text(node)
        finally:
            blocker.close()


if __name__ == '__main__':
    BindRetryTest().main()
