#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Upgrade a real v30.1.4 wallet containing two independent PoW claims.

The historical daemon authors two ordinary QQP3 claims from distinct confirmed
wallet anchors and with distinct quantum payouts.  The exact same datadir is
then opened by the current candidate, which expires both saved mempool entries
under its configured policy.  The candidate must treat both authenticated
families as safe, relay both historical byte strings before authoring anything,
and later continue each
expired family on its exact anchor and payout without paying for a recovery
transaction.  A temporarily locked selected anchor must defer only that family:
the independent family progresses on the same tip, and explicitly unlocking
the selected anchor changes the authoritative wallet snapshot so that its
family can then progress without waiting for a block.
"""

from decimal import Decimal
import importlib.util
import os
from pathlib import Path
import tempfile
import time

from test_framework.blocktools import COINBASE_MATURITY
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal


V30_1_4_VERSION = 300104
CANDIDATE_VERSION = 300105
REQUIRED_HISTORICAL_VERSIONS = ["v30.1.4"]
CLAIM_WALLET = "v3014_upgrade_claims"
POW_PAYOUT_LABEL = "PoW - Quantum Claim Address"
QQSPROOF = b"QQSPROOF"
QQP3_LATE_ORIGIN_WINDOW = 64
ZERO_HASH = "0" * 64
GOLD_RUSH_END_TIME = 2_000_000_000


class GoldRushV3014WalletUpgradeTest(BitcoinTestFramework):
    def add_options(self, parser):
        # Use the same ordinary descriptor wallet on both sides of the in-place
        # upgrade. Descriptor wallets can own the legacy P2PKH claim anchors,
        # keeping this test focused on retained-family servicing rather than a
        # separate wallet-database-format migration.
        self.add_wallet_options(parser, descriptors=True, legacy=False)

    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.base_args = [
            "-allowunsafequantumkeyrpc=1",
            "-staking=0",
            "-autostartstaking=0",
            "-powmining=0",
            "-txindex=1",
            "-shadowindex=1",
            "-shadowwhitelistheight=1",
            "-shadowgoldrushblocks=500",
            "-shadowcompetingclaimsheight=2",
            f"-qqgoldrushendtime={GOLD_RUSH_END_TIME}",
        ]
        # v30.1.4 creates and persists the historical wallet in its normal
        # configuration.  Zero-hour expiry is enabled only after the binary
        # switch so both saved entries expire during candidate mempool load.
        # Startup repair may immediately restore an exact eligible root.
        self.extra_args = [[*self.base_args]]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()
        self.skip_if_no_previous_releases()

    def _assert_v3014_provenance(self):
        releases = Path(self.options.previous_releases_path)
        if releases.is_symlink():
            raise AssertionError("mixed-version fixture root must not be a symbolic link")
        expected_host = os.getenv("PREVIOUS_RELEASES_HOST")
        if not expected_host:
            raise AssertionError(
                "PREVIOUS_RELEASES_HOST is required for independent fixture validation"
            )
        repository_root = Path(__file__).resolve().parents[2]
        builder_path = repository_root / "ci/mixed-version/build_previous_releases.py"
        manifest_path = builder_path.with_name("sources.json")
        spec = importlib.util.spec_from_file_location(
            "blackcoin_mixed_version_builder", builder_path
        )
        if spec is None or spec.loader is None:
            raise AssertionError("cannot load mixed-version provenance validator")
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        manifest = builder.load_manifest(manifest_path)
        with tempfile.TemporaryDirectory(
            prefix="v3014-provenance-"
        ) as scratch:
            valid = builder.cached_provenance_is_valid(
                output_dir=releases,
                manifest_digest=builder.file_sha256(manifest_path),
                sources=manifest["sources"],
                required_versions=REQUIRED_HISTORICAL_VERSIONS,
                host=expected_host,
                scratch_root=Path(scratch),
            )
        if not valid:
            raise AssertionError(
                "v30.1.4 binaries do not match the required checked-in provenance contract"
            )

    def setup_nodes(self):
        self._assert_v3014_provenance()
        self.add_nodes(
            self.num_nodes,
            extra_args=self.extra_args,
            versions=[V30_1_4_VERSION],
        )
        self.start_nodes()
        self.import_deterministic_coinbase_privkeys()

    def _set_mocktime(self, timestamp):
        self.mock_time = timestamp
        self.nodes[0].setmocktime(timestamp)

    def _bump_mocktime(self, seconds=16):
        self._set_mocktime(self.mock_time + seconds)

    def _sync_mocktime_to_tip(self):
        node = self.nodes[0]
        tip_time = node.getblockheader(node.getbestblockhash())["time"]
        self._set_mocktime(max(self.mock_time, tip_time) + 16)

    def _load_wallet(self, name):
        node = self.nodes[0]
        if name not in node.listwallets():
            node.loadwallet(name)
        return node.get_wallet_rpc(name)

    @staticmethod
    def _wallet_claim_txids(wallet):
        return {
            entry["txid"]
            for entry in wallet.listtransactions("*", 1000, 0, True)
            if entry.get("comment") == "PoW Claim"
        }

    def _claim_input(self, wallet, txid):
        decoded = self.nodes[0].decoderawtransaction(
            wallet.gettransaction(txid)["hex"]
        )
        assert_equal(len(decoded["vin"]), 1)
        return (decoded["vin"][0]["txid"], decoded["vin"][0]["vout"])

    def _claim_payload(self, wallet, txid):
        decoded = self.nodes[0].decoderawtransaction(
            wallet.gettransaction(txid)["hex"]
        )
        payloads = []
        for output in decoded["vout"]:
            script = bytes.fromhex(output["scriptPubKey"]["hex"])
            offset = script.find(QQSPROOF)
            if offset >= 0:
                payloads.append(script[offset:])
        assert_equal(len(payloads), 1)
        return payloads[0]

    @staticmethod
    def _decode_claim_scripts(payload):
        """Return the target and payout scripts from a QQP2/QQP3/QQP4 payload."""
        assert payload.startswith(QQSPROOF)
        proof = payload[len(QQSPROOF):]
        magic = proof[:4]
        context_size = {
            b"QQP2": 0,
            b"QQP3": 36,
            b"QQP4": 72,
        }.get(magic)
        assert context_size is not None, f"unexpected proof version {magic!r}"
        script_header = 13 + context_size
        assert len(proof) >= script_header + 4
        target_size = int.from_bytes(
            proof[script_header:script_header + 2], "little"
        )
        cursor = script_header + 2
        target = proof[cursor:cursor + target_size]
        cursor += target_size
        assert len(target) == target_size
        payout_size = int.from_bytes(proof[cursor:cursor + 2], "little")
        cursor += 2
        payout = proof[cursor:cursor + payout_size]
        cursor += payout_size
        assert len(payout) == payout_size
        assert_equal(cursor, len(proof))
        return magic, target.hex(), payout.hex()

    @staticmethod
    def _component_for_root(recovery, root_txid):
        matches = [
            component
            for component in recovery["component_details"]
            if root_txid in component["claim_txids"]
        ]
        assert_equal(len(matches), 1)
        return matches[0]

    @staticmethod
    def _node_for_txid(component, txid):
        matches = [
            node for node in component["nodes"] if node["txid"] == txid
        ]
        assert_equal(len(matches), 1)
        return matches[0]

    def _switch_to_candidate(self):
        node = self.nodes[0]
        self.stop_node(0)
        node.binary = self.options.bitcoind
        node.args[0] = self.options.bitcoind
        node.cli.binary = self.options.bitcoincli
        node.version = None
        with node.assert_debug_log([
            "Imported mempool transactions from disk: 0 succeeded, 0 failed, 2 expired",
        ]):
            self.start_node(
                0,
                extra_args=[
                    *self.base_args,
                    "-mempoolexpiry=0",
                    f"-mocktime={self.mock_time}",
                ],
            )
        node.setmocktime(self.mock_time)

    @staticmethod
    def _assert_zero_recovery_spend(wallet):
        recovery = wallet.getpowclaimrecoveryinfo(True)
        assert_equal(recovery["database_outcome_ambiguous"], False)
        assert_equal(recovery["pending_manual_resolutions"], 0)
        assert_equal(recovery["pending_automatic_resolutions"], 0)
        assert_equal(recovery["confirmed_manual_resolutions"], 0)
        assert_equal(recovery["confirmed_automatic_resolutions"], 0)
        assert_equal(recovery["confirmed_resolution_fees"], Decimal("0"))
        assert_equal(recovery["automatic_actions_in_window"], 0)
        assert_equal(
            recovery["automatic_fee_exposure_in_window"], Decimal("0")
        )
        for component in recovery["component_details"]:
            assert_equal(component["resolution_txids"], [])
            assert_equal(component["ordinary_or_mixed_txids"], [])
        assert not any(
            entry.get("qq_shadow_pow_cleanup_for")
            for entry in wallet.listtransactions("*", 1000, 0, True)
        )
        return recovery

    @staticmethod
    def _assert_quantum_inventory_unchanged(
        wallet, expected_inventory, expected_addresses
    ):
        # Compare the complete public inventory, not just the configured PoW
        # payout.  This catches an allocation under another label as well as a
        # partially completed allocation whose binding was never published.
        assert_equal(wallet.getquantumkeyinventory(), expected_inventory)
        assert_equal(wallet.listquantumaddresses(), expected_addresses)

    def run_test(self):
        node = self.nodes[0]
        self._set_mocktime((int(time.time()) & ~0xf) + 16)
        assert_equal(node.getnetworkinfo()["version"], V30_1_4_VERSION)

        funding = node.get_wallet_rpc(self.default_wallet_name)
        funding.staking(False)
        node.createwallet(
            wallet_name=CLAIM_WALLET,
            descriptors=True,
            load_on_startup=True,
        )
        claimant = node.get_wallet_rpc(CLAIM_WALLET)
        claimant.staking(False)

        self.log.info("Funding two independent v30.1.4 claim anchors")
        funding_address = funding.getnewaddress("upgrade funding", "legacy")
        target_addresses = [
            claimant.getnewaddress("historical family A", "legacy"),
            claimant.getnewaddress("historical family B", "legacy"),
        ]
        self.generatetoaddress(
            node,
            COINBASE_MATURITY + 2,
            funding_address,
            sync_fun=self.no_op,
        )
        funding.sendtoaddress(target_addresses[0], Decimal("1.25000000"))
        funding.sendtoaddress(target_addresses[1], Decimal("1.75000000"))
        self.generatetoaddress(node, 1, funding_address, sync_fun=self.no_op)
        self._sync_mocktime_to_tip()
        for address in target_addresses:
            assert_equal(
                len(claimant.listunspent(1, 9999999, [address])), 1
            )
        assert_equal(node.getshadowpowwork()["proof_version"], 3)

        self.log.info("Authoring two distinct wallet-owned QQP3 roots under exact v30.1.4")
        payout_addresses = [
            claimant.getnewquantumaddress("historical payout A")["address"],
            claimant.getnewquantumaddress("historical payout B")["address"],
        ]
        assert payout_addresses[0] != payout_addresses[1]
        historical = []
        for target, payout in zip(target_addresses, payout_addresses):
            result = claimant.sendshadowpowclaim(target, payout, 500_000)
            payload = bytes.fromhex(result["proof"])
            magic, target_script, payout_script = self._decode_claim_scripts(
                payload
            )
            assert_equal(magic, b"QQP3")
            assert_equal(
                target_script, node.validateaddress(target)["scriptPubKey"]
            )
            assert_equal(
                payout_script, node.validateaddress(payout)["scriptPubKey"]
            )
            assert_equal(self._claim_payload(claimant, result["txid"]), payload)
            historical.append(
                {
                    "txid": result["txid"],
                    "hex": result["hex"],
                    "target": target,
                    "target_script": target_script,
                    "payout": payout,
                    "payout_script": payout_script,
                }
            )

        root_txids = {claim["txid"] for claim in historical}
        assert_equal(len(root_txids), 2)
        assert_equal(root_txids, self._wallet_claim_txids(claimant))
        assert_equal(root_txids, set(node.getrawmempool()))
        for claim in historical:
            claim["anchor"] = self._claim_input(claimant, claim["txid"])
            record = claimant.gettransaction(claim["txid"])
            # These omissions are the exact pre-lineage v30.1.4 wallet shape.
            assert "qq_shadow_pow_lineage_schema" not in record
            assert "qq_shadow_pow_lineage_family" not in record
            assert "qq_shadow_pow_lineage_root" not in record
        original_anchors = {claim["anchor"] for claim in historical}
        assert_equal(len(original_anchors), 2)

        self.log.info("Proving both v30.1.4 families are live before upgrade")
        old_inventory = claimant.getpowclaimrecoveryinfo(True)
        assert_equal(old_inventory["database_outcome_ambiguous"], False)
        assert_equal(len(old_inventory["component_details"]), 2)
        assert_equal(
            {
                (component["anchor"]["txid"], component["anchor"]["vout"])
                for component in old_inventory["component_details"]
            },
            original_anchors,
        )
        for claim in historical:
            component = self._component_for_root(
                old_inventory, claim["txid"]
            )
            root = self._node_for_txid(component, claim["txid"])
            assert_equal(component["claim_txids"], [claim["txid"]])
            assert_equal(root["in_mempool"], True)
            assert_equal(root["quarantined"], False)

        historical_quantum_inventory = claimant.getquantumkeyinventory()
        historical_quantum_addresses = claimant.listquantumaddresses()
        assert_equal(historical_quantum_inventory["total"], 2)
        assert_equal(
            {entry["address"] for entry in historical_quantum_addresses},
            set(payout_addresses),
        )
        assert_equal(
            {
                entry["address"]
                for entry in historical_quantum_inventory["keys"]
            },
            set(payout_addresses),
        )

        self.log.info("Opening the unchanged wallet and datadir with the candidate")
        self._switch_to_candidate()
        node = self.nodes[0]
        assert_equal(node.getnetworkinfo()["version"], CANDIDATE_VERSION)
        funding = self._load_wallet(self.default_wallet_name)
        claimant = self._load_wallet(CLAIM_WALLET)
        funding.staking(False)
        claimant.staking(False)
        self._assert_quantum_inventory_unchanged(
            claimant,
            historical_quantum_inventory,
            historical_quantum_addresses,
        )
        node.syncwithvalidationinterfacequeue()

        # The saved entries expired during candidate startup, as asserted by
        # _switch_to_candidate(). Bounded startup/background maintenance may
        # already restore exact eligible bytes without mining enabled. Do not
        # require an all-absent instant that races this permitted servicing.
        assert_equal(self._wallet_claim_txids(claimant), root_txids)
        for claim in historical:
            assert_equal(claimant.gettransaction(claim["txid"])["hex"], claim["hex"])
        relay_gate = claimant.getpowmininginfo()
        assert_equal(relay_gate["mining_gate_coherent"], True)
        assert_equal(relay_gate["mining_gate_database_ambiguous"], False)
        assert_equal(relay_gate["mining_gate_unresolved_components"], 2)
        assert_equal(relay_gate["mining_gate_family_claims"], 2)
        assert 0 <= relay_gate["mining_gate_live_claims"] <= 2
        assert_equal(relay_gate["mining_gate_eligible_claims"], 2)
        assert_equal(relay_gate["mining_gate_unsafe_claims"], 0)
        assert_equal(relay_gate["mining_gate_unsafe_components"], 0)
        if relay_gate["mining_gate_live_claims"] < 2:
            assert_equal(relay_gate["mining_gate_action"], "relay_existing")
            assert relay_gate["mining_gate_relay_txid"] in root_txids
        else:
            assert_equal(relay_gate["mining_gate_action"], "wait_for_live")

        upgraded_inventory = claimant.getpowclaimrecoveryinfo(True)
        for claim in historical:
            component = self._component_for_root(
                upgraded_inventory, claim["txid"]
            )
            root = self._node_for_txid(component, claim["txid"])
            assert_equal(component["claim_txids"], [claim["txid"]])
            assert_equal(component["anchor_authenticated"], True)
            assert_equal(component["anchor_unspent"], True)
            assert_equal(root["wallet_authored"], True)
            assert_equal(root["provenance"], "explicit_authored")
            assert_equal(root["lineage_metadata_present"], False)
            assert_equal(root["proof_version"], 3)
            assert_equal(root["disposition"], "eligible")
            assert_equal(root["quarantined"], not root["in_mempool"])

        self.log.info("Relaying both exact historical byte strings before refresh")
        claims_before_relay = self._wallet_claim_txids(claimant)
        assert_equal(claimant.getpowmininginfo()["payout_address"], "")
        assert POW_PAYOUT_LABEL not in claimant.listlabels()
        relay_start = claimant.setpowmining(True, 1, 100)
        assert_equal(relay_start["created_payout_key"], False)
        assert_equal(relay_start["payout_address"], "")
        assert POW_PAYOUT_LABEL not in claimant.listlabels()
        try:
            self.wait_until(
                lambda: root_txids.issubset(node.getrawmempool()), timeout=60
            )
            self.wait_until(
                lambda: claimant.getpowmininginfo()["mining_gate_action"]
                == "wait_for_live",
                timeout=30,
            )
            relayed = claimant.getpowmininginfo()
            assert_equal(relayed["claims_submitted"], 0)
            assert_equal(relayed["mining_gate_live_claims"], 2)
            assert_equal(relayed["mining_gate_eligible_claims"], 2)
            assert_equal(relayed["mining_gate_unsafe_claims"], 0)
            assert_equal(relayed["mining_gate_unsafe_components"], 0)
            assert_equal(
                self._wallet_claim_txids(claimant), claims_before_relay
            )
            for claim in historical:
                assert_equal(
                    node.getrawtransaction(claim["txid"]), claim["hex"]
                )
        finally:
            claimant.setpowmining(False)
        self._assert_quantum_inventory_unchanged(
            claimant,
            historical_quantum_inventory,
            historical_quantum_addresses,
        )

        self.log.info("Restoring normal mempool residence before origin expiry")
        self.restart_node(
            0,
            extra_args=[*self.base_args, f"-mocktime={self.mock_time}"],
        )
        node = self.nodes[0]
        node.setmocktime(self.mock_time)
        funding = self._load_wallet(self.default_wallet_name)
        claimant = self._load_wallet(CLAIM_WALLET)
        self.wait_until(
            lambda: root_txids.issubset(node.getrawmempool()), timeout=30
        )

        self.log.info("Advancing until both historical QQP3 origins expire")
        expired = False
        for _ in range(QQP3_LATE_ORIGIN_WINDOW + 4):
            self._bump_mocktime(16)
            self.generateblock(
                node, output=funding_address, transactions=[]
            )
            node.syncwithvalidationinterfacequeue()
            recovery = claimant.getpowclaimrecoveryinfo(True)
            roots = [
                self._node_for_txid(
                    self._component_for_root(recovery, claim["txid"]),
                    claim["txid"],
                )
                for claim in historical
            ]
            if all(root["disposition"] == "origin_expired" for root in roots):
                expired = True
                break
        assert expired, "v30.1.4 QQP3 roots did not reach origin_expired"
        assert root_txids.isdisjoint(node.getrawmempool())

        refresh_gate = claimant.getpowmininginfo()
        assert_equal(refresh_gate["mining_gate_coherent"], True)
        assert_equal(refresh_gate["mining_gate_database_ambiguous"], False)
        assert_equal(refresh_gate["mining_gate_unresolved_components"], 2)
        assert_equal(refresh_gate["mining_gate_family_claims"], 2)
        assert_equal(refresh_gate["mining_gate_live_claims"], 0)
        assert_equal(refresh_gate["mining_gate_eligible_claims"], 0)
        assert_equal(refresh_gate["mining_gate_unsafe_claims"], 0)
        assert_equal(refresh_gate["mining_gate_unsafe_components"], 0)
        assert_equal(refresh_gate["mining_gate_action"], "refresh_same_anchor")
        assert_equal(refresh_gate["mining_gate_can_submit"], True)

        selected_refresh_root = refresh_gate["mining_gate_lineage_head_txid"]
        assert selected_refresh_root in root_txids
        selected_family = next(
            claim
            for claim in historical
            if claim["txid"] == selected_refresh_root
        )
        independent_family = next(
            claim
            for claim in historical
            if claim["txid"] != selected_refresh_root
        )
        selected_anchor = {
            "txid": selected_family["anchor"][0],
            "vout": selected_family["anchor"][1],
        }
        assert_equal(
            claimant.lockunspent(False, [selected_anchor]), True
        )
        assert selected_anchor in claimant.listlockunspent()

        self.log.info(
            "Deferring the selected locked family while the independent "
            "family refreshes on the same tip"
        )
        roots_before_refresh = self._wallet_claim_txids(claimant)
        refresh_tip = node.getbestblockhash()
        refresh_start = claimant.setpowmining(True, 1, 100)
        assert_equal(refresh_start["created_payout_key"], False)
        assert_equal(refresh_start["payout_address"], "")
        assert POW_PAYOUT_LABEL not in claimant.listlabels()

        def independent_family_refreshed():
            refresh_count = len(
                self._wallet_claim_txids(claimant) - roots_before_refresh
            )
            assert refresh_count <= 1, (
                "worker bypassed the locked-family defer on the unchanged tip"
            )
            return refresh_count == 1

        anchor_locked = True

        try:
            self.wait_until(
                independent_family_refreshed,
                timeout=360,
            )
            first_refresh_txids = (
                self._wallet_claim_txids(claimant) - roots_before_refresh
            )
            assert_equal(len(first_refresh_txids), 1)
            first_refresh_txid = next(iter(first_refresh_txids))
            assert_equal(node.getbestblockhash(), refresh_tip)
            assert_equal(
                self._claim_input(claimant, first_refresh_txid),
                independent_family["anchor"],
            )
            # The independent family's live member is now the aggregate
            # single-flight barrier. The locked family remains deferred, but
            # its local wait must not hide the other family's live claim.
            self.wait_until(
                lambda: claimant.getpowmininginfo()["mining_gate_action"]
                == "wait_for_live",
                timeout=30,
            )
            deferred_gate = claimant.getpowmininginfo()
            assert_equal(deferred_gate["claims_submitted"], 1)
            assert_equal(deferred_gate["mining_gate_live_claims"], 1)
            assert_equal(deferred_gate["mining_gate_unsafe_claims"], 0)
            assert_equal(deferred_gate["mining_gate_unsafe_components"], 0)
            deferred_generation = claimant.getpowclaimrecoveryinfo(
                True
            )["wallet_generation"]
            self._assert_quantum_inventory_unchanged(
                claimant,
                historical_quantum_inventory,
                historical_quantum_addresses,
            )

            self.log.info(
                "Proving the locked family remains deferred on the same tip"
            )
            locked_deadline = time.monotonic() + 1
            while time.monotonic() < locked_deadline:
                assert_equal(node.getbestblockhash(), refresh_tip)
                assert selected_anchor in claimant.listlockunspent()
                assert_equal(
                    self._wallet_claim_txids(claimant) - roots_before_refresh,
                    {first_refresh_txid},
                )
                locked_gate = claimant.getpowmininginfo()
                assert_equal(
                    locked_gate["mining_gate_action"],
                    "wait_for_live",
                )
                assert_equal(locked_gate["claims_submitted"], 1)
                time.sleep(0.1)

            self.log.info(
                "Unlocking changes the wallet snapshot and re-enables the "
                "deferred family on the same tip"
            )
            assert_equal(
                claimant.lockunspent(True, [selected_anchor]), True
            )
            anchor_locked = False
            assert selected_anchor not in claimant.listlockunspent()
            unlocked_generation = claimant.getpowclaimrecoveryinfo(
                True
            )["wallet_generation"]
            assert unlocked_generation > deferred_generation

            def deferred_family_refreshed():
                refresh_txids = (
                    self._wallet_claim_txids(claimant)
                    - roots_before_refresh
                )
                assert len(refresh_txids) <= 2, (
                    "worker authored more than one refresh per historical "
                    "family"
                )
                return len(refresh_txids) == 2

            self.wait_until(deferred_family_refreshed, timeout=360)
            assert_equal(node.getbestblockhash(), refresh_tip)
            stable_wait_deadline = time.monotonic() + 3
            while time.monotonic() < stable_wait_deadline:
                assert_equal(
                    len(
                        self._wallet_claim_txids(claimant)
                        - roots_before_refresh
                    ),
                    2,
                )
                stable_gate = claimant.getpowmininginfo()
                assert_equal(stable_gate["claims_submitted"], 2)
                assert_equal(
                    stable_gate["mining_gate_action"], "wait_for_live"
                )
                assert_equal(stable_gate["mining_gate_live_claims"], 2)
                assert_equal(stable_gate["mining_gate_unsafe_claims"], 0)
                assert_equal(stable_gate["mining_gate_unsafe_components"], 0)
                time.sleep(0.1)
        finally:
            claimant.setpowmining(False)
            if anchor_locked:
                claimant.lockunspent(True, [selected_anchor])
        self._assert_quantum_inventory_unchanged(
            claimant,
            historical_quantum_inventory,
            historical_quantum_addresses,
        )

        refresh_txids = self._wallet_claim_txids(claimant) - roots_before_refresh
        assert_equal(len(refresh_txids), 2)
        refreshed_by_root = {}
        for refresh_txid in refresh_txids:
            refresh_anchor = self._claim_input(claimant, refresh_txid)
            matching_roots = [
                claim
                for claim in historical
                if claim["anchor"] == refresh_anchor
            ]
            assert_equal(len(matching_roots), 1)
            root = matching_roots[0]
            assert root["txid"] not in refreshed_by_root
            magic, target_script, payout_script = self._decode_claim_scripts(
                self._claim_payload(claimant, refresh_txid)
            )
            assert_equal(magic, b"QQP3")
            assert_equal(target_script, root["target_script"])
            assert_equal(payout_script, root["payout_script"])
            record = claimant.gettransaction(refresh_txid)
            assert_equal(record["qq_shadow_pow_lineage_schema"], "1")
            assert_equal(
                record["qq_shadow_pow_lineage_root"], root["txid"]
            )
            assert_equal(
                record["qq_shadow_pow_lineage_parent"], root["txid"]
            )
            assert_equal(record["qq_shadow_pow_lineage_ordinal"], "1")
            refreshed_by_root[root["txid"]] = refresh_txid
        assert_equal(set(refreshed_by_root), root_txids)

        self.log.info("Proving both families remain safe with no new anchor or recovery fee")
        final_recovery = self._assert_zero_recovery_spend(claimant)
        assert_equal(len(final_recovery["component_details"]), 2)
        assert_equal(
            {
                (component["anchor"]["txid"], component["anchor"]["vout"])
                for component in final_recovery["component_details"]
            },
            original_anchors,
        )
        assert_equal(
            self._wallet_claim_txids(claimant),
            root_txids | set(refreshed_by_root.values()),
        )
        assert_equal(final_recovery["raw_claim_objects"], 4)
        assert_equal(final_recovery["unanchored_claim_txids"], [])
        for claim in historical:
            component = self._component_for_root(
                final_recovery, claim["txid"]
            )
            refresh_txid = refreshed_by_root[claim["txid"]]
            assert_equal(
                set(component["claim_txids"]),
                {claim["txid"], refresh_txid},
            )
            assert_equal(component["anchor_authenticated"], True)
            assert_equal(component["anchor_unspent"], True)
            assert_equal(component["descendant_claims"], 0)
            assert_equal(component["ordinary_or_mixed_txids"], [])
            assert_equal(component["resolution_txids"], [])
            root = self._node_for_txid(component, claim["txid"])
            refresh = self._node_for_txid(component, refresh_txid)
            assert_equal(root["lineage_metadata_present"], False)
            assert_equal(refresh["lineage_metadata_present"], True)
            assert_equal(refresh["lineage_metadata_valid"], True)
            assert_equal(refresh["lineage_root_txid"], claim["txid"])
            assert_equal(refresh["lineage_parent_txid"], claim["txid"])
            assert_equal(refresh["lineage_ordinal"], 1)
            assert_equal(refresh["in_mempool"], True)

        final_gate = claimant.getpowmininginfo()
        self._assert_quantum_inventory_unchanged(
            claimant,
            historical_quantum_inventory,
            historical_quantum_addresses,
        )
        assert_equal(final_gate["payout_address"], "")
        assert POW_PAYOUT_LABEL not in claimant.listlabels()
        assert_equal(final_gate["claims_submitted"], 2)
        assert_equal(final_gate["mining_gate_coherent"], True)
        assert_equal(final_gate["mining_gate_database_ambiguous"], False)
        assert_equal(final_gate["mining_gate_unresolved_components"], 2)
        assert_equal(final_gate["mining_gate_family_claims"], 4)
        assert_equal(final_gate["mining_gate_live_claims"], 2)
        assert_equal(final_gate["mining_gate_eligible_claims"], 2)
        assert_equal(final_gate["mining_gate_unsafe_claims"], 0)
        assert_equal(final_gate["mining_gate_unsafe_components"], 0)
        assert_equal(final_gate["mining_gate_action"], "wait_for_live")
        assert_equal(final_gate["mining_gate_relay_txid"], ZERO_HASH)


if __name__ == "__main__":
    GoldRushV3014WalletUpgradeTest().main()
