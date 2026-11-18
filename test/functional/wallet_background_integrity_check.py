#!/usr/bin/env python3
# Copyright (c) 2026 Blackcoin Core Developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Test the start-up wallet check and the background full check.

At start the node runs SQLite's quick check: damage it sees still stops the
start. The full check (which also matches index rows to table rows) runs in
the background once the wallet is loaded; damage only it sees is logged as an
error and raised as a warning, and the node keeps running. -walletfullcheck=1
restores the old full check before the wallet loads.
"""

import shutil
import sqlite3

from test_framework.test_framework import BitcoinTestFramework
from test_framework.test_node import ErrorMatch
from test_framework.util import assert_equal

PAGE_INDEX_LEAF = 0x0a


class WalletBackgroundIntegrityCheckTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True

    def setup_nodes(self):
        self.add_nodes(self.num_nodes)
        self.start_nodes()

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()
        self.skip_if_no_sqlite()

    def wallet_file(self):
        return self.nodes[0].chain_path / "wallets" / "w" / "wallet.dat"

    def pages(self, data, page_size):
        for number in range(1, len(data) // page_size + 1):
            start = (number - 1) * page_size
            yield number, start, (100 if number == 1 else 0)

    def corrupt_index_only(self, path):
        """Change the largest key in the index copy only: the key still sorts
        last, so the quick check cannot see it, but the table row has no
        matching index row."""
        con = sqlite3.connect(path)
        largest = max(row[0] for row in con.execute("SELECT key FROM main"))
        con.close()
        assert largest[-1] != 0xff
        patched = largest[:-1] + bytes([largest[-1] + 1])
        data = bytearray(path.read_bytes())
        page_size = int.from_bytes(data[16:18], "big")
        changed = 0
        for _, start, header_skip in self.pages(data, page_size):
            if data[start + header_skip] != PAGE_INDEX_LEAF:
                continue
            at = data.find(largest, start, start + page_size)
            if at >= 0:
                data[at:at + len(largest)] = patched
                changed += 1
        assert_equal(changed, 1)
        path.write_bytes(bytes(data))

    def corrupt_page_type(self, path):
        """Make the table's root page an invalid b-tree page: the quick check sees it."""
        con = sqlite3.connect(path)
        root = con.execute("SELECT rootpage FROM sqlite_master WHERE name = 'main'").fetchone()[0]
        con.close()
        data = bytearray(path.read_bytes())
        page_size = int.from_bytes(data[16:18], "big")
        data[(root - 1) * page_size] = 0x7f
        path.write_bytes(bytes(data))

    def run_test(self):
        node = self.nodes[0]
        node.createwallet(wallet_name="w", descriptors=True, load_on_startup=True)
        self.stop_node(0)
        clean = self.wallet_file().with_name("wallet.clean")
        shutil.copyfile(self.wallet_file(), clean)

        self.log.info("Damage the quick check sees still stops the start")
        self.corrupt_page_type(self.wallet_file())
        node.assert_start_raises_init_error([], "Error: SQLiteDatabase: Failed to execute statement to verify database: database disk image is malformed")

        self.log.info("Damage only the full check sees: the node starts, the background check reports it")
        shutil.copyfile(clean, self.wallet_file())
        self.corrupt_index_only(self.wallet_file())
        with node.assert_debug_log(expected_msgs=["Background wallet integrity check of", "found damage", "missing from index"], timeout=60):
            self.start_node(0)
        self.wait_until(lambda: "integrity check" in node.getblockchaininfo()["warnings"], timeout=60)
        # The wallet stays usable and the node keeps running.
        assert_equal(node.getwalletinfo()["walletname"], "w")
        node.getnewaddress()
        self.stop_node(0)
        assert not self.wallet_file().with_name("wallet.dat.fullcheck").exists()

        self.log.info("-walletfullcheck=1 runs the full check before the wallet loads")
        node.assert_start_raises_init_error(["-walletfullcheck=1"], "Error: Failed to verify database\nrow ", match=ErrorMatch.PARTIAL_REGEX)

        self.log.info("A clean wallet passes the background check and raises no warning")
        shutil.copyfile(clean, self.wallet_file())
        with node.assert_debug_log(expected_msgs=["Background wallet integrity check of", "passed in"], timeout=60):
            self.start_node(0)
        assert "integrity check" not in node.getblockchaininfo()["warnings"]


if __name__ == '__main__':
    WalletBackgroundIntegrityCheckTest().main()
