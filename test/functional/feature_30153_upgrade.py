#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php.
"""Exercise 30.1.5.2 -> 30.1.5.3 -> 30.1.5.2 on synthetic regtest wallets.

Requires --baseline-bitcoind or BLACKCOIN_30152_BITCOIND pointing to an
independently built 30.1.5.2 daemon. Both revisions share numeric RPC version
300105, so the public subversion is checked as well. No historical wallet,
production datadir, RPC endpoint or secret is accepted as input. This is a
bounded compatibility fixture, not a guarantee of arbitrary downgrade safety.
"""

from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import re

from test_framework.authproxy import JSONRPCException
from test_framework.blocktools import COINBASE_MATURITY
from test_framework.test_framework import BitcoinTestFramework, SkipTest
from test_framework.util import assert_equal


class Upgrade30153Test(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser, descriptors=True, legacy=False)
        parser.add_argument("--baseline-bitcoind", default=os.getenv("BLACKCOIN_30152_BITCOIND"),
                            help="Explicit independently built 30.1.5.2 daemon")
        parser.add_argument("--require-bdb", action="store_true",
                            help="Fail unless both builds exercise a legacy BDB wallet too")

    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.wallet_names = []
        self.extra_args = [["-staking=0", "-autostartstaking=0", "-powmining=0",
                            "-deprecatedrpc=create_bdb", "-connect=0", "-dnsseed=0",
                            "-discover=0"]]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()
        if not self.options.baseline_bitcoind:
            raise SkipTest("explicit 30.1.5.2 --baseline-bitcoind is required")
        baseline = Path(self.options.baseline_bitcoind).resolve(strict=True)
        candidate = Path(self.options.bitcoind).resolve(strict=True)
        assert baseline != candidate, "baseline and candidate must be distinct binaries"
        assert os.access(baseline, os.X_OK), "baseline must be executable"
        self.baseline_binary = str(baseline)
        self.candidate_binary = str(candidate)
        if self.options.require_bdb:
            assert self.is_bdb_compiled(), "candidate must include BDB for --require-bdb"

    def setup_nodes(self):
        self.add_nodes(1, extra_args=self.extra_args, binary=[self.baseline_binary])
        self.start_nodes()

    def _assert_version(self, revision):
        info = self.nodes[0].getnetworkinfo()
        assert_equal(info["version"], 300105)
        assert re.fullmatch(rf"/Blackcoin:30\.1\.5\.{revision}(?:\([^/]*\))?/", info["subversion"]), info
        assert_equal(self.nodes[0].getblockchaininfo()["chain"], "regtest")
        return {key: info[key] for key in ("version", "subversion")}

    def _switch(self, binary, revision):
        node = self.nodes[0]
        self.stop_node(0)
        node.binary = binary
        node.args[0] = binary
        self.start_node(0)
        self._assert_version(revision)
        # Every tested wallet explicitly requested loading on startup. Check
        # persistence across revisions before any wallet-specific operation.
        assert set(self.wallets).issubset(node.listwallets())

    def _snapshot(self, name):
        node = self.nodes[0]
        wallet = node.get_wallet_rpc(name)
        info = wallet.getwalletinfo()
        addresses = self.wallets[name]["addresses"]
        owned = {}
        for address in addresses:
            address_info = wallet.getaddressinfo(address)
            assert address_info["ismine"]
            owned[address] = {key: address_info[key] for key in
                              ("ismine", "solvable", "scriptPubKey", "pubkey", "hdkeypath", "labels")
                              if key in address_info}
            # A fresh signature proves retained private key ownership without
            # exporting key material. Addresses here are ordinary legacy P2PKH.
            message = "isolated 30.1.5.3 compatibility fixture"
            assert node.verifymessage(address, wallet.signmessage(address, message), message)
        quantum = wallet.getquantumkeyinventory()
        assert_equal(quantum["total"], 1)
        assert quantum["all_durably_stored"]
        # Backup verification timestamps and markers may change upon backup.
        # Compare the complete key identities separately from those markers.
        quantum_keys = [{key: item[key] for key in ("address", "public_key", "stored_in_wallet")}
                        for item in quantum["keys"]]
        return {
            "format": info["format"], "descriptors": info["descriptors"],
            "private_keys_enabled": info["private_keys_enabled"],
            "balances": wallet.getbalances(), "addresses": owned,
            "transactions": wallet.listtransactions("*", 1000, 0, True),
            "utxos": sorted(wallet.listunspent(), key=lambda item: (item["txid"], item["vout"])),
            "quantum_keys": quantum_keys,
            "quantum_addresses": [{key: value for key, value in item.items() if key != "backup_verified"}
                                  for item in wallet.listquantumaddresses()],
            "raw_transactions": {txid: wallet.gettransaction(txid)["hex"]
                                 for txid in self.wallets[name]["txids"]},
        }

    def _assert_wallet(self, name, expected):
        assert_equal(self._snapshot(name), expected)

    def run_test(self):
        node = self.nodes[0]
        baseline_info = self._assert_version(2)
        self.wallets = {}
        skipped = []
        node.createwallet(wallet_name="funding", descriptors=True)
        funding = node.get_wallet_rpc("funding")
        mining_address = funding.getnewaddress("synthetic mining", "legacy")
        # Prepare baseline wallets before funding them. The published GUI can
        # deadlock when a load callback overlaps a transaction notification;
        # that sequence has separate candidate regression coverage.
        formats = [("sqlite", True)]
        if self.is_bdb_compiled():
            formats.append(("bdb", False))
        else:
            skipped.append("BDB: candidate compiled without BDB")
        for format_name, descriptors in formats:
            name = f"upgrade_{format_name}"
            try:
                node.createwallet(wallet_name=name, descriptors=descriptors, load_on_startup=True)
            except JSONRPCException as error:
                if not descriptors and "Compiled without bdb support" in error.error["message"] and not self.options.require_bdb:
                    skipped.append("BDB: baseline compiled without BDB")
                    continue
                raise
            wallet = node.get_wallet_rpc(name)
            assert_equal(wallet.getwalletinfo()["format"], format_name)
            address = wallet.getnewaddress("baseline retained address", "legacy")
            quantum = wallet.getnewquantumaddress("baseline non-HD quantum key")
            assert quantum["stored_in_wallet"]
            self.wallets[name] = {"addresses": [address], "txids": []}
        self.generatetoaddress(node, COINBASE_MATURITY + 2, mining_address, sync_fun=self.no_op)
        for records in self.wallets.values():
            records["txids"].append(funding.sendtoaddress(records["addresses"][0], Decimal("10")))
        self.generatetoaddress(node, 1, mining_address, sync_fun=self.no_op)
        expected = {name: self._snapshot(name) for name in self.wallets}
        for snapshot in expected.values():
            assert_equal(snapshot["balances"]["mine"]["trusted"], Decimal("10"))
        self._switch(self.candidate_binary, 3)
        for name in self.wallets:
            self._assert_wallet(name, expected[name])
        self.restart_node(0)
        self._assert_version(3)
        for name in self.wallets:
            self._assert_wallet(name, expected[name])

        # Candidate-created addresses and actual confirmed spends exercise
        # database writes as well as a read-only opening of an old wallet.
        for name, records in self.wallets.items():
            wallet = node.get_wallet_rpc(name)
            records["addresses"].append(wallet.getnewaddress("candidate retained address", "legacy"))
            records["txids"].append(wallet.sendtoaddress(mining_address, Decimal("1")))
        self.generatetoaddress(node, 1, mining_address, sync_fun=self.no_op)
        expected = {name: self._snapshot(name) for name in self.wallets}
        backups = {}
        originals = list(self.wallets)
        for name in originals:
            backup = Path(self.options.tmpdir) / f"{name}-candidate-backup.dat"
            node.get_wallet_rpc(name).backupwallet(str(backup))
            assert backup.is_file() and backup.stat().st_size > 0
            restored = f"{name}_restored"
            node.restorewallet(restored, str(backup), load_on_startup=True)
            self.wallets[restored] = self.wallets[name]
            self._assert_wallet(restored, expected[name])
            expected[restored] = expected[name]
            backups[name] = hashlib.sha256(backup.read_bytes()).hexdigest()
        self.restart_node(0)
        self._assert_version(3)
        for name in self.wallets:
            self._assert_wallet(name, expected[name])
        self._switch(self.baseline_binary, 2)
        for name in self.wallets:
            self._assert_wallet(name, expected[name])
        self.restart_node(0)
        self._assert_version(2)
        for name in self.wallets:
            self._assert_wallet(name, expected[name])
            # backupwallet reopens the written database and challenges its
            # non-HD quantum key. Exercise this under the rolled-back binary,
            # without enabling any private-key export RPC.
            rollback_backup = Path(self.options.tmpdir) / f"{name}-rollback-backup.dat"
            node.get_wallet_rpc(name).backupwallet(str(rollback_backup))
            assert rollback_backup.is_file() and rollback_backup.stat().st_size > 0
            assert node.get_wallet_rpc(name).getquantumkeyinventory()["all_backed_up"]
        report = {
            "baseline": baseline_info,
            "candidate": {"version": 300105, "revision": "30.1.5.3"},
            "binary_sha256": {label: hashlib.sha256(Path(binary).read_bytes()).hexdigest()
                              for label, binary in (("baseline", self.baseline_binary), ("candidate", self.candidate_binary))},
            "wallets": list(self.wallets), "skipped": skipped,
            "candidate_backup_sha256": backups,
            "stages": ["baseline funded", "candidate opened", "candidate restarted",
                       "candidate wrote and spent", "candidate backup restored",
                       "restored candidate restarted", "baseline rollback", "baseline rollback restarted"],
            "scope": "synthetic isolated regtest only; no general downgrade guarantee",
        }
        (Path(self.options.tmpdir) / "compatibility-results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == '__main__':
    Upgrade30153Test().main()
