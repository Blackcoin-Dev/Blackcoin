#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Round-trip an exact v30.1.4 wallet containing one pre-QQP3 claim.

The historical daemon authors an ordinary QQP2 claim below the QQP3
activation height. The candidate then opens the unchanged datadir, advances
past activation without mining the claim, and must classify the retained
wallet-authored bytes as an authenticated, chain-unspent proof that may
revalidate. The singleton family must refresh on its original anchor instead
of consuming either of the wallet's other eligible fee coins.

A persistent user lock on that reserved anchor must survive restart and defer
the singleton family. Removing the lock must restore same-anchor refresh on
the unchanged tip. The built-in worker must then grind and publish one
current-policy sibling, and a final restart must reconstruct the same safe
lineage without a recovery transaction or payout-key mutation.  The exact
same datadir then returns to v30.1.4 and to the candidate again.  The older
daemon must open and write the wallet without corrupting the candidate's
lineage or quarantine metadata. The test framework's strict RPC-documentation
check is expected to diagnose the future keys; the same old daemon with that
diagnostic disabled must expose them unchanged, matching release behavior. Its
legacy miner is expected to remain blocked by the quarantined root; only the
candidate interprets the complete family as safe same-anchor continuation
state.

A separate wallet carries an exact v30.1.4-authored managed SIGN_ONLY draft
through the same version switches. Both versions make ordinary wallet writes;
the draft's bytes, anchor generation, and absent relay authority must survive.
The candidate must not invent a historical authorization receipt. The focused
--managed-resolution-only mode exercises this contract without the miner lane.
"""

from decimal import Decimal
import importlib.util
import os
from pathlib import Path
import tempfile
import time

from test_framework.blocktools import COINBASE_MATURITY
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_raises_rpc_error


V30_1_4_VERSION = 300104
CANDIDATE_VERSION = 300105
REQUIRED_HISTORICAL_VERSIONS = ["v30.1.4"]
CLAIM_WALLET = "v3014_qqp2_upgrade"
MANAGED_DRAFT_WALLET = "v3014_managed_draft_upgrade"
QQP3_ACTIVATION_HEIGHT = 120
QQSPROOF = b"QQSPROOF"
ZERO_HASH = "0" * 64
GOLD_RUSH_END_TIME = 2_000_000_000


class GoldRushV3014QQP2UpgradeTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser, descriptors=True, legacy=False)
        parser.add_argument(
            "--managed-resolution-only",
            action="store_true",
            help="Run only the exact-v30.1.4 managed-draft wallet round trip",
        )

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
            f"-shadowcompetingclaimsheight={QQP3_ACTIVATION_HEIGHT}",
            f"-qqgoldrushendtime={GOLD_RUSH_END_TIME}",
        ]
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
        with tempfile.TemporaryDirectory(prefix="v3014-qqp2-provenance-") as scratch:
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
        self.v3014_binary = self.nodes[0].binary
        self.v3014_cli = self.nodes[0].cli.binary
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

    def _load_wallet(self):
        node = self.nodes[0]
        if CLAIM_WALLET not in node.listwallets():
            node.loadwallet(CLAIM_WALLET)
        return node.get_wallet_rpc(CLAIM_WALLET)

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
        return {
            "txid": decoded["vin"][0]["txid"],
            "vout": decoded["vin"][0]["vout"],
        }

    def _claim_scripts(self, wallet, txid):
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

        proof = payloads[0][len(QQSPROOF):]
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
        assert_equal(len(target), target_size)
        payout_size = int.from_bytes(proof[cursor:cursor + 2], "little")
        cursor += 2
        payout = proof[cursor:cursor + payout_size]
        cursor += payout_size
        assert_equal(len(payout), payout_size)
        assert_equal(cursor, len(proof))
        return magic, target.hex(), payout.hex()

    @staticmethod
    def _component_for_claim(recovery, claim_txid):
        matches = [
            component
            for component in recovery["component_details"]
            if claim_txid in component["claim_txids"]
        ]
        assert_equal(len(matches), 1)
        return matches[0]

    @staticmethod
    def _node_for_claim(component, claim_txid):
        matches = [
            node for node in component["nodes"] if node["txid"] == claim_txid
        ]
        assert_equal(len(matches), 1)
        return matches[0]

    @staticmethod
    def _assert_component_anchor(component, expected):
        assert_equal(
            {
                "txid": component["anchor"]["txid"],
                "vout": component["anchor"]["vout"],
            },
            expected,
        )

    @staticmethod
    def _assert_no_recovery_spend(wallet):
        recovery = wallet.getpowclaimrecoveryinfo(True)
        assert_equal(recovery["database_outcome_ambiguous"], False)
        assert_equal(recovery["pending_manual_resolutions"], 0)
        assert_equal(recovery["pending_automatic_resolutions"], 0)
        assert_equal(recovery["confirmed_manual_resolutions"], 0)
        assert_equal(recovery["confirmed_automatic_resolutions"], 0)
        assert_equal(recovery["confirmed_resolution_fees"], Decimal("0"))
        for component in recovery["component_details"]:
            assert_equal(component["resolution_txids"], [])
            assert_equal(component["ordinary_or_mixed_txids"], [])
        assert not any(
            entry.get("qq_shadow_pow_cleanup_for")
            for entry in wallet.listtransactions("*", 1000, 0, True)
        )
        return recovery

    def _switch_to_candidate(self, submission_delay=False):
        node = self.nodes[0]
        self.stop_node(0)
        node.binary = self.options.bitcoind
        node.args[0] = self.options.bitcoind
        node.cli.binary = self.options.bitcoincli
        node.version = None
        candidate_args = [*self.base_args, f"-mocktime={self.mock_time}"]
        if submission_delay:
            candidate_args.append("-qqshadowpowclaimsubmissiondelaymillis=2000")
        self.start_node(0, extra_args=candidate_args)
        node.setmocktime(self.mock_time)

    def _switch_to_v3014(self, extra_args=None):
        node = self.nodes[0]
        self.stop_node(0)
        node.binary = self.v3014_binary
        node.args[0] = self.v3014_binary
        node.cli.binary = self.v3014_cli
        node.version = V30_1_4_VERSION
        args = [*self.base_args, f"-mocktime={self.mock_time}"]
        if extra_args:
            args.extend(extra_args)
        self.start_node(
            0,
            extra_args=args,
        )
        node.setmocktime(self.mock_time)

    def _restart_candidate(self, submission_delay=False):
        args = [*self.base_args, f"-mocktime={self.mock_time}"]
        if submission_delay:
            args.append("-qqshadowpowclaimsubmissiondelaymillis=2000")
        self.restart_node(0, extra_args=args)
        self.nodes[0].setmocktime(self.mock_time)

    def _assert_extra_inputs_unchanged(self, wallet, address, expected):
        actual = {
            (utxo["txid"], utxo["vout"])
            for utxo in wallet.listunspent(1, 9999999, [address])
        }
        assert_equal(actual, expected)
        for txid, vout in expected:
            assert self.nodes[0].gettxout(txid, vout, False) is not None

    @staticmethod
    def _assert_refresh_gate(gate, root_txid):
        assert_equal(gate["mining_gate_coherent"], True)
        assert_equal(gate["mining_gate_database_ambiguous"], False)
        assert_equal(gate["mining_gate_unresolved_components"], 1)
        assert_equal(gate["mining_gate_family_claims"], 1)
        assert_equal(gate["mining_gate_live_claims"], 0)
        assert_equal(gate["mining_gate_eligible_claims"], 0)
        assert_equal(gate["mining_gate_unsafe_claims"], 0)
        assert_equal(gate["mining_gate_unsafe_components"], 0)
        assert_equal(gate["mining_gate_action"], "refresh_same_anchor")
        assert_equal(gate["mining_gate_can_submit"], True)
        assert_equal(gate["mining_gate_lineage_head_txid"], root_txid)
        assert_equal(gate["mining_gate_relay_txid"], ZERO_HASH)

    def _managed_wallet(self):
        node = self.nodes[0]
        if MANAGED_DRAFT_WALLET not in node.listwallets():
            node.loadwallet(MANAGED_DRAFT_WALLET)
        return node.get_wallet_rpc(MANAGED_DRAFT_WALLET)

    def _create_v3014_managed_draft(self, funding_address, claim_address):
        node = self.nodes[0]
        assert_equal(node.getnetworkinfo()["version"], V30_1_4_VERSION)
        wallet = self._managed_wallet()
        payout = wallet.getnewquantumaddress("historical draft payout")["address"]
        claim = wallet.sendshadowpowclaim(claim_address, payout, 500_000)
        assert_equal(self._claim_scripts(wallet, claim["txid"])[0], b"QQP2")
        # The old daemon itself observes the absent/retryable claim; no wallet
        # metadata is synthesized or imported by this compatibility fixture.
        for _ in range(8):
            self._bump_mocktime()
            self.generateblock(node, output=funding_address, transactions=[])
            node.syncwithvalidationinterfacequeue()
            component = self._component_for_claim(
                wallet.getpowclaimrecoveryinfo(True), claim["txid"]
            )
            if (
                claim["txid"] not in node.getrawmempool()
                and component["classification"] == "current_branch_ineligible"
                and component["all_claims_quarantined"]
            ):
                break
        else:
            raise AssertionError("historical QQP2 draft fixture did not become recoverable")
        assert node.getshadowpowwork()["height"] < QQP3_ACTIVATION_HEIGHT
        draft = wallet.createshadowpowclaimresolution(claim["txid"], False, True)
        assert_equal(draft["success"], True)
        assert_equal(draft["persisted"], True)
        assert_equal(draft["broadcast"], False)
        assert_equal(draft["relay_authorized"], False)
        record = wallet.gettransaction(draft["txid"])
        metadata = {
            key: value for key, value in record.items()
            if key.startswith("qq_shadow_pow_resolution_")
        }
        assert_equal(metadata["qq_shadow_pow_resolution_schema"], "1")
        assert_equal(metadata["qq_shadow_pow_resolution_relay_authorized"], "0")
        assert "qq_shadow_pow_resolution_relay_revoked" not in metadata
        assert not any(key.startswith("qq_shadow_pow_resolution_auth_") for key in metadata)
        self.managed_draft = {
            "claim_txid": claim["txid"],
            "txid": draft["txid"],
            "hex": draft["hex"],
            "metadata": metadata,
            "generation": draft["generation_fingerprint"],
            "anchor": {"txid": draft["claim_input_txid"], "vout": draft["claim_input_vout"]},
            "address": claim_address,
            "fee": draft["fee"],
        }
        self._assert_managed_draft(candidate=False)

    def _assert_managed_draft(self, *, candidate):
        node = self.nodes[0]
        wallet = self._managed_wallet()
        draft = self.managed_draft
        record = wallet.gettransaction(draft["txid"])
        assert_equal(record["hex"], draft["hex"])
        for key, value in draft["metadata"].items():
            assert_equal(record[key], value)
        assert not any(key.startswith("qq_shadow_pow_resolution_auth_") for key in record)
        assert_equal(record.get("qq_shadow_pow_resolution_relay_revoked", "0"), "0")
        assert draft["txid"] not in node.getrawmempool()
        assert node.gettxout(draft["anchor"]["txid"], draft["anchor"]["vout"], False)
        inventory = wallet.getpowclaimrecoveryinfo(True)
        assert_equal(inventory["database_outcome_ambiguous"], False)
        assert_equal(inventory["pending_manual_resolutions"], 1)
        assert_equal(inventory["confirmed_resolution_fees"], Decimal("0"))
        component = self._component_for_claim(inventory, draft["claim_txid"])
        assert_equal(component["generation_fingerprint"], draft["generation"])
        assert_equal(component["resolution_txids"], [draft["txid"]])
        resolution = self._node_for_claim(component, draft["txid"])
        assert_equal(resolution["kind"], "managed_resolution")
        assert_equal(resolution["resolution_metadata_valid"], True)
        assert_equal(resolution["resolution_relay_authorized"], False)
        if candidate:
            assert_equal(resolution["resolution_relay_revoked"], False)
            assert_equal(resolution["authorization_receipt"], None)
        # QQP2 eligibility may change across the enclosing test's tips. The
        # metadata contract must hold even when current recovery is refused.
        # Decode the retained bytes rather than requiring a fresh action plan.
        decoded = node.decoderawtransaction(record["hex"])
        assert_equal(len(decoded["vin"]), 1)
        assert_equal(len(decoded["vout"]), 1)
        assert_equal(decoded["vin"][0]["txid"], draft["anchor"]["txid"])
        assert_equal(decoded["vin"][0]["vout"], draft["anchor"]["vout"])
        anchor = node.gettxout(draft["anchor"]["txid"], draft["anchor"]["vout"], False)
        assert_equal(anchor["value"] - decoded["vout"][0]["value"], draft["fee"])

    def _write_managed_draft_label(self, label):
        wallet = self._managed_wallet()
        address = self.managed_draft["address"]
        wallet.setlabel(address, label)
        assert_equal(wallet.getaddressinfo(address)["labels"], [label])

    def _managed_draft_only_round_trip(self):
        self._switch_to_candidate()
        self._assert_managed_draft(candidate=True)
        self._write_managed_draft_label("candidate managed-draft write")
        self._switch_to_v3014(["-rpcdoccheck=0"])
        wallet = self._managed_wallet()
        assert_equal(wallet.getaddressinfo(self.managed_draft["address"])["labels"],
                     ["candidate managed-draft write"])
        self._assert_managed_draft(candidate=False)
        self._write_managed_draft_label("historical managed-draft write")
        self._switch_to_candidate()
        self._assert_managed_draft(candidate=True)
        assert_equal(self._managed_wallet().getaddressinfo(
            self.managed_draft["address"])["labels"], ["historical managed-draft write"])

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
        claimant = self._load_wallet()
        claimant.staking(False)
        node.createwallet(
            wallet_name=MANAGED_DRAFT_WALLET,
            descriptors=True,
            load_on_startup=True,
        )
        managed_wallet = self._managed_wallet()
        managed_wallet.staking(False)
        managed_address = managed_wallet.getnewaddress("historical managed draft", "legacy")

        self.log.info("Funding one historical anchor and two independent fee coins")
        funding_address = funding.getnewaddress("QQP2 upgrade funding", "legacy")
        claim_address = claimant.getnewaddress("historical QQP2 target", "legacy")
        self.generatetoaddress(
            node,
            COINBASE_MATURITY + 2,
            funding_address,
            sync_fun=self.no_op,
        )
        for amount in (
            Decimal("1.25000000"),
            Decimal("1.75000000"),
            Decimal("2.25000000"),
        ):
            funding.sendtoaddress(claim_address, amount)
        funding.sendtoaddress(managed_address, Decimal("1.50000000"))
        self.generatetoaddress(node, 1, funding_address, sync_fun=self.no_op)
        self._sync_mocktime_to_tip()
        historical_inputs = {
            (utxo["txid"], utxo["vout"])
            for utxo in claimant.listunspent(1, 9999999, [claim_address])
        }
        assert_equal(len(historical_inputs), 3)
        work = node.getshadowpowwork()
        assert work["height"] < QQP3_ACTIVATION_HEIGHT
        assert_equal(work["proof_version"], 2)

        self.log.info("Persisting an exact v30.1.4 managed draft in an independent wallet")
        self._create_v3014_managed_draft(funding_address, managed_address)
        if self.options.managed_resolution_only:
            self._managed_draft_only_round_trip()
            return

        self.log.info("Authoring a pre-activation QQP2 root under exact v30.1.4")
        payout_address = claimant.getnewquantumaddress(
            "historical QQP2 payout"
        )["address"]
        root_result = claimant.sendshadowpowclaim(
            claim_address, payout_address, 500_000
        )
        root_txid = root_result["txid"]
        root_raw = root_result["hex"]
        root_anchor = self._claim_input(claimant, root_txid)
        root_outpoint = (root_anchor["txid"], root_anchor["vout"])
        assert root_outpoint in historical_inputs
        untouched_inputs = historical_inputs - {root_outpoint}
        assert_equal(len(untouched_inputs), 2)
        root_magic, target_script, payout_script = self._claim_scripts(
            claimant, root_txid
        )
        assert_equal(root_magic, b"QQP2")
        assert_equal(
            target_script, node.validateaddress(claim_address)["scriptPubKey"]
        )
        assert_equal(
            payout_script, node.validateaddress(payout_address)["scriptPubKey"]
        )
        assert root_txid in node.getrawmempool()
        assert_equal(self._wallet_claim_txids(claimant), {root_txid})
        root_record = claimant.gettransaction(root_txid)
        assert "qq_shadow_pow_lineage_schema" not in root_record
        assert "qq_shadow_pow_lineage_family" not in root_record
        assert "qq_shadow_pow_lineage_root" not in root_record
        self._assert_extra_inputs_unchanged(
            claimant, claim_address, untouched_inputs
        )

        historical_quantum_inventory = claimant.getquantumkeyinventory()
        historical_quantum_addresses = claimant.listquantumaddresses()

        self.log.info("Opening the exact same datadir with the v30.1.5 candidate")
        self._switch_to_candidate()
        node = self.nodes[0]
        assert_equal(node.getnetworkinfo()["version"], CANDIDATE_VERSION)
        claimant = self._load_wallet()
        claimant.staking(False)
        self._assert_managed_draft(candidate=True)
        self._write_managed_draft_label("candidate managed-draft write")
        assert_equal(claimant.gettransaction(root_txid)["hex"], root_raw)
        self.wait_until(lambda: root_txid in node.getrawmempool(), timeout=30)
        assert_equal(claimant.getquantumkeyinventory(), historical_quantum_inventory)
        assert_equal(claimant.listquantumaddresses(), historical_quantum_addresses)

        self.log.info("Crossing QQP3 while deliberately omitting the QQP2 root")
        while node.getblockcount() < QQP3_ACTIVATION_HEIGHT - 1:
            self._bump_mocktime()
            self.generateblock(node, output=funding_address, transactions=[])
            node.syncwithvalidationinterfacequeue()
        assert_equal(node.getshadowpowwork()["proof_version"], 3)

        rejected = None
        for _ in range(32):
            if root_txid not in node.getrawmempool():
                candidate = node.testmempoolaccept([root_raw])[0]
                if (
                    not candidate["allowed"]
                    and candidate["reject-reason"] == "shadow-proof-invalid"
                ):
                    rejected = candidate
                    break
            self._bump_mocktime()
            self.generateblock(node, output=funding_address, transactions=[])
            node.syncwithvalidationinterfacequeue()
        assert rejected is not None, "historical QQP2 root stayed valid at 32 QQP3 tips"
        assert root_txid not in node.getrawmempool()
        node.syncwithvalidationinterfacequeue()
        assert_equal(
            claimant.gettransaction(root_txid)["qq_shadow_pow_quarantine"], "1"
        )

        self.log.info("Proving the legacy singleton is safe and refreshable")
        stale = self._assert_no_recovery_spend(claimant)
        assert_equal(stale["raw_claim_objects"], 1)
        assert_equal(len(stale["component_details"]), 1)
        component = self._component_for_claim(stale, root_txid)
        root = self._node_for_claim(component, root_txid)
        assert_equal(component["classification"], "current_branch_ineligible")
        self._assert_component_anchor(component, root_anchor)
        assert_equal(component["anchor_authenticated"], True)
        assert_equal(component["anchor_unspent"], True)
        assert_equal(component["has_revalidating_unbound_proof"], True)
        assert_equal(component["all_claims_quarantined"], True)
        assert_equal(root["wallet_authored"], True)
        assert_equal(root["provenance"], "explicit_authored")
        assert_equal(root["proof_version"], 2)
        assert_equal(root["lineage_metadata_present"], False)
        assert_equal(root["disposition"], "unbound_proof_may_revalidate")
        assert_equal(root["in_mempool"], False)
        assert_equal(root["quarantined"], True)
        assert node.gettxout(root_anchor["txid"], root_anchor["vout"], False)
        self._assert_refresh_gate(claimant.getpowmininginfo(), root_txid)
        self._assert_extra_inputs_unchanged(
            claimant, claim_address, untouched_inputs
        )

        self.log.info("Persistently locking the singleton anchor defers only that family")
        stale_generation = stale["wallet_generation"]
        assert_equal(claimant.lockunspent(False, [root_anchor], True), True)
        assert root_anchor in claimant.listlockunspent()
        locked = claimant.getpowclaimrecoveryinfo(True)
        assert locked["wallet_generation"] > stale_generation
        locked_component = self._component_for_claim(locked, root_txid)
        assert_equal(locked_component["anchor_user_locked"], True)
        locked_gate = claimant.getpowmininginfo()
        assert_equal(locked_gate["mining_gate_coherent"], True)
        assert_equal(locked_gate["mining_gate_database_ambiguous"], False)
        assert_equal(locked_gate["mining_gate_unsafe_claims"], 0)
        assert_equal(locked_gate["mining_gate_unsafe_components"], 0)
        # A held family does not prohibit independent new-anchor work. This
        # fixture deliberately has no configured payout for that work, and
        # must not silently create or bind a key to bypass the user hold.
        assert_equal(locked_gate["mining_gate_action"], "create_new_anchor")
        assert_equal(locked_gate["mining_gate_can_submit"], True)

        self.log.info("Restarting proves the singleton user hold is durable")
        locked_tip = node.getbestblockhash()
        self._restart_candidate(submission_delay=True)
        node = self.nodes[0]
        claimant = self._load_wallet()
        claimant.staking(False)
        assert_equal(node.getbestblockhash(), locked_tip)
        assert root_anchor in claimant.listlockunspent()
        reloaded_locked = claimant.getpowclaimrecoveryinfo(True)
        assert_equal(
            self._component_for_claim(reloaded_locked, root_txid)[
                "anchor_user_locked"
            ],
            True,
        )
        assert_equal(
            claimant.getpowmininginfo()["mining_gate_action"],
            "create_new_anchor",
        )
        claims_before_worker = self._wallet_claim_txids(claimant)
        assert_equal(claims_before_worker, {root_txid})
        assert_raises_rpc_error(
            -4, "Gold Rush PoW has no existing payout key",
            claimant.setpowmining, True, 1, 100,
        )
        locked_worker = claimant.getpowmininginfo()
        assert_equal(locked_worker["enabled"], False)
        assert_equal(locked_worker["claims_submitted"], 0)
        assert_equal(locked_worker["hashrate"], 0)
        assert_equal(self._wallet_claim_txids(claimant), claims_before_worker)
        assert_equal(claimant.getquantumkeyinventory(), historical_quantum_inventory)
        assert_equal(claimant.listquantumaddresses(), historical_quantum_addresses)
        assert root_anchor in claimant.listlockunspent()
        assert_equal(node.getbestblockhash(), locked_tip)

        self.log.info("Unlocking restores refresh authority on the unchanged tip")
        assert_equal(claimant.lockunspent(True, [root_anchor]), True)
        assert root_anchor not in claimant.listlockunspent()
        assert_equal(node.getbestblockhash(), locked_tip)
        self._assert_refresh_gate(claimant.getpowmininginfo(), root_txid)

        self.log.info("The built-in worker hashes one current-policy sibling")
        with node.wait_for_debug_log(
            [b"Gold Rush PoW claim submission test barrier reached"],
            timeout=180,
        ):
            started = claimant.setpowmining(True, 1, 100)
            assert_equal(started["created_payout_key"], False)
            assert_equal(started["payout_address"], "")
        try:
            self.wait_until(
                lambda: len(
                    self._wallet_claim_txids(claimant) - claims_before_worker
                )
                == 1,
                timeout=180,
            )
            sibling_txid = next(
                iter(self._wallet_claim_txids(claimant) - claims_before_worker)
            )
            self.wait_until(
                lambda: claimant.getpowmininginfo()["mining_gate_action"]
                == "wait_for_live",
                timeout=30,
            )
            worker_info = claimant.getpowmininginfo()
            assert_equal(worker_info["claims_submitted"], 1)
            assert_equal(worker_info["mining_gate_family_claims"], 2)
            assert_equal(worker_info["mining_gate_live_claims"], 1)
            assert_equal(worker_info["mining_gate_unsafe_claims"], 0)
            assert_equal(worker_info["mining_gate_unsafe_components"], 0)
            assert_equal(node.getbestblockhash(), locked_tip)
        finally:
            claimant.setpowmining(False)

        sibling_raw = node.getrawtransaction(sibling_txid)
        assert_equal(self._claim_input(claimant, sibling_txid), root_anchor)
        sibling_magic, sibling_target, sibling_payout = self._claim_scripts(
            claimant, sibling_txid
        )
        assert_equal(sibling_magic, b"QQP3")
        assert_equal(sibling_target, target_script)
        assert_equal(sibling_payout, payout_script)
        assert sibling_txid in node.getrawmempool()
        assert root_txid not in node.getrawmempool()
        sibling_record = claimant.gettransaction(sibling_txid)
        assert_equal(sibling_record["qq_shadow_pow_lineage_schema"], "1")
        assert_equal(sibling_record["qq_shadow_pow_lineage_root"], root_txid)
        assert_equal(sibling_record["qq_shadow_pow_lineage_parent"], root_txid)
        assert_equal(sibling_record["qq_shadow_pow_lineage_ordinal"], "1")
        assert_equal(claimant.getquantumkeyinventory(), historical_quantum_inventory)
        assert_equal(claimant.listquantumaddresses(), historical_quantum_addresses)
        self._assert_extra_inputs_unchanged(
            claimant, claim_address, untouched_inputs
        )

        refreshed = self._assert_no_recovery_spend(claimant)
        refreshed_component = self._component_for_claim(refreshed, root_txid)
        assert_equal(
            set(refreshed_component["claim_txids"]),
            {root_txid, sibling_txid},
        )
        self._assert_component_anchor(refreshed_component, root_anchor)
        assert_equal(refreshed_component["anchor_authenticated"], True)
        assert_equal(refreshed_component["anchor_unspent"], True)
        assert_equal(refreshed_component["anchor_user_locked"], False)
        assert_equal(refreshed_component["descendant_claims"], 0)

        self.log.info("A final restart reconstructs the exact safe lineage")
        final_tip = node.getbestblockhash()
        self._restart_candidate()
        node = self.nodes[0]
        claimant = self._load_wallet()
        claimant.staking(False)
        assert_equal(node.getbestblockhash(), final_tip)
        self.wait_until(lambda: sibling_txid in node.getrawmempool(), timeout=30)
        assert root_txid not in node.getrawmempool()
        assert_equal(claimant.gettransaction(root_txid)["hex"], root_raw)
        assert_equal(node.getrawtransaction(sibling_txid), sibling_raw)
        assert root_anchor not in claimant.listlockunspent()
        final = self._assert_no_recovery_spend(claimant)
        assert_equal(final["raw_claim_objects"], 2)
        final_component = self._component_for_claim(final, root_txid)
        final_root = self._node_for_claim(final_component, root_txid)
        final_sibling = self._node_for_claim(final_component, sibling_txid)
        assert_equal(
            set(final_component["claim_txids"]), {root_txid, sibling_txid}
        )
        self._assert_component_anchor(final_component, root_anchor)
        assert_equal(final_component["anchor_authenticated"], True)
        assert_equal(final_component["anchor_unspent"], True)
        assert_equal(final_component["anchor_user_locked"], False)
        assert_equal(final_component["descendant_claims"], 0)
        assert_equal(final_root["proof_version"], 2)
        assert_equal(final_root["lineage_metadata_present"], False)
        assert_equal(
            final_root["disposition"], "unbound_proof_may_revalidate"
        )
        assert_equal(final_root["in_mempool"], False)
        assert_equal(final_sibling["proof_version"], 3)
        assert_equal(final_sibling["lineage_metadata_present"], True)
        assert_equal(final_sibling["lineage_metadata_valid"], True)
        assert_equal(final_sibling["lineage_root_txid"], root_txid)
        assert_equal(final_sibling["lineage_parent_txid"], root_txid)
        assert_equal(final_sibling["lineage_ordinal"], 1)
        assert_equal(final_sibling["in_mempool"], True)
        final_gate = claimant.getpowmininginfo()
        assert_equal(final_gate["mining_gate_coherent"], True)
        assert_equal(final_gate["mining_gate_database_ambiguous"], False)
        assert_equal(final_gate["mining_gate_family_claims"], 2)
        assert_equal(final_gate["mining_gate_live_claims"], 1)
        assert_equal(final_gate["mining_gate_eligible_claims"], 1)
        assert_equal(final_gate["mining_gate_unsafe_claims"], 0)
        assert_equal(final_gate["mining_gate_unsafe_components"], 0)
        assert_equal(final_gate["mining_gate_action"], "wait_for_live")
        assert_equal(final_gate["mining_gate_relay_txid"], ZERO_HASH)
        assert_equal(claimant.getquantumkeyinventory(), historical_quantum_inventory)
        assert_equal(claimant.listquantumaddresses(), historical_quantum_addresses)
        self._assert_extra_inputs_unchanged(
            claimant, claim_address, untouched_inputs
        )

        self.log.info("Downgrading the candidate-written datadir to exact v30.1.4")
        round_trip_tip = node.getbestblockhash()
        round_trip_label = "v30.1.4 metadata round-trip witness"
        candidate_root_record = claimant.gettransaction(root_txid)
        candidate_sibling_record = claimant.gettransaction(sibling_txid)
        candidate_metadata = {
            "root_quarantine": candidate_root_record["qq_shadow_pow_quarantine"],
            "sibling_authored": candidate_sibling_record["qq_shadow_pow_authored"],
            "sibling_schema": candidate_sibling_record["qq_shadow_pow_lineage_schema"],
            "sibling_family": candidate_sibling_record["qq_shadow_pow_lineage_family"],
            "sibling_root": candidate_sibling_record["qq_shadow_pow_lineage_root"],
            "sibling_parent": candidate_sibling_record["qq_shadow_pow_lineage_parent"],
            "sibling_ordinal": candidate_sibling_record["qq_shadow_pow_lineage_ordinal"],
        }
        candidate_fingerprint = final_component["generation_fingerprint"]

        self._switch_to_v3014(
            [f"-qqpowpayoutaddress={payout_address}"]
        )
        node = self.nodes[0]
        assert_equal(node.getnetworkinfo()["version"], V30_1_4_VERSION)
        assert_equal(node.getbestblockhash(), round_trip_tip)
        claimant = self._load_wallet()
        claimant.staking(False)
        self.wait_until(lambda: sibling_txid in node.getrawmempool(), timeout=30)
        assert root_txid not in node.getrawmempool()
        assert_equal(claimant.gettransaction(root_txid)["hex"], root_raw)
        assert_equal(node.getrawtransaction(sibling_txid), sibling_raw)

        # The functional framework forces runtime RPC documentation checking.
        # v30.1.4 does not document future candidate map-value keys, so that
        # diagnostic must catch the decorated result. It is not a wallet-load
        # or database-corruption result, and release builds default it off.
        old_root_record = claimant.gettransaction(root_txid)
        assert_equal(
            old_root_record["qq_shadow_pow_quarantine"],
            candidate_metadata["root_quarantine"],
        )
        assert_raises_rpc_error(
            -1,
            "key returned that was not in doc",
            claimant.gettransaction,
            sibling_txid,
        )
        metadata_keys = {
            "qq_shadow_pow_authored": "sibling_authored",
            "qq_shadow_pow_lineage_schema": "sibling_schema",
            "qq_shadow_pow_lineage_family": "sibling_family",
            "qq_shadow_pow_lineage_root": "sibling_root",
            "qq_shadow_pow_lineage_parent": "sibling_parent",
            "qq_shadow_pow_lineage_ordinal": "sibling_ordinal",
        }

        self.log.info("Disabling only the old debug RPC schema check")
        self.restart_node(
            0,
            extra_args=[
                *self.base_args,
                f"-mocktime={self.mock_time}",
                f"-qqpowpayoutaddress={payout_address}",
                "-rpcdoccheck=0",
            ],
        )
        node = self.nodes[0]
        node.setmocktime(self.mock_time)
        assert_equal(node.getnetworkinfo()["version"], V30_1_4_VERSION)
        assert_equal(node.getbestblockhash(), round_trip_tip)
        claimant = self._load_wallet()
        claimant.staking(False)
        self.wait_until(lambda: sibling_txid in node.getrawmempool(), timeout=30)
        assert_equal(claimant.gettransaction(root_txid)["hex"], root_raw)
        old_sibling_record = claimant.gettransaction(sibling_txid)
        assert_equal(old_sibling_record["hex"], sibling_raw)
        self._assert_managed_draft(candidate=False)
        assert_equal(self._managed_wallet().getaddressinfo(managed_address)["labels"],
                     ["candidate managed-draft write"])
        self._write_managed_draft_label("historical managed-draft write")
        for record_key, expected_key in metadata_keys.items():
            assert_equal(
                old_sibling_record[record_key],
                candidate_metadata[expected_key],
            )

        # Make a normal release-like historical-version address-book write, so
        # this is stronger than a read-only open-and-close compatibility check.
        claimant.setlabel(claim_address, round_trip_label)
        assert_equal(
            claimant.getaddressinfo(claim_address)["labels"][0],
            round_trip_label,
        )

        old_recovery = claimant.getpowclaimrecoveryinfo(True)
        assert_equal(old_recovery["database_outcome_ambiguous"], False)
        assert_equal(old_recovery["raw_claim_objects"], 2)
        assert old_recovery["blocking_quarantined_claims"] > 0
        old_gate = claimant.getpowmininginfo()
        assert old_gate["blocking_quarantined_claims"] > 0
        old_claim_objects = old_recovery["raw_claim_objects"]
        old_start = claimant.setpowmining(True, 1, 100)
        assert_equal(old_start["enabled"], True)
        assert_equal(old_start["created_payout_key"], False)
        try:
            self.wait_until(
                lambda: claimant.getpowmininginfo()["state"]
                == "claim_quarantined",
                timeout=30,
            )
            old_worker = claimant.getpowmininginfo()
            assert_equal(old_worker["enabled"], True)
            assert_equal(old_worker["hashrate"], 0)
            assert_equal(old_worker["claims_submitted"], 0)
            assert_equal(
                claimant.getpowclaimrecoveryinfo(True)["raw_claim_objects"],
                old_claim_objects,
            )
        finally:
            claimant.setpowmining(False)
        self._assert_extra_inputs_unchanged(
            claimant, claim_address, untouched_inputs
        )
        assert_equal(
            claimant.getquantumkeyinventory(), historical_quantum_inventory
        )
        assert_equal(
            claimant.listquantumaddresses(), historical_quantum_addresses
        )

        self.log.info("Re-upgrading proves v30.1.4 preserved candidate metadata verbatim")
        self._switch_to_candidate()
        node = self.nodes[0]
        assert_equal(node.getnetworkinfo()["version"], CANDIDATE_VERSION)
        assert_equal(node.getbestblockhash(), round_trip_tip)
        claimant = self._load_wallet()
        claimant.staking(False)
        self._assert_managed_draft(candidate=True)
        assert_equal(self._managed_wallet().getaddressinfo(managed_address)["labels"],
                     ["historical managed-draft write"])
        self.wait_until(lambda: sibling_txid in node.getrawmempool(), timeout=30)
        assert root_txid not in node.getrawmempool()
        assert_equal(claimant.gettransaction(root_txid)["hex"], root_raw)
        assert_equal(claimant.gettransaction(sibling_txid)["hex"], sibling_raw)
        assert_equal(
            claimant.getaddressinfo(claim_address)["labels"][0],
            round_trip_label,
        )

        round_trip_root = claimant.gettransaction(root_txid)
        round_trip_sibling = claimant.gettransaction(sibling_txid)
        assert_equal(
            round_trip_root["qq_shadow_pow_quarantine"],
            candidate_metadata["root_quarantine"],
        )
        for record_key, expected_key in metadata_keys.items():
            assert_equal(
                round_trip_sibling[record_key],
                candidate_metadata[expected_key],
            )
        round_trip_recovery = self._assert_no_recovery_spend(claimant)
        round_trip_component = self._component_for_claim(
            round_trip_recovery, root_txid
        )
        assert_equal(
            set(round_trip_component["claim_txids"]),
            {root_txid, sibling_txid},
        )
        assert_equal(
            round_trip_component["generation_fingerprint"],
            candidate_fingerprint,
        )
        self._assert_component_anchor(round_trip_component, root_anchor)
        round_trip_gate = claimant.getpowmininginfo()
        assert_equal(round_trip_gate["mining_gate_coherent"], True)
        assert_equal(round_trip_gate["mining_gate_database_ambiguous"], False)
        assert_equal(round_trip_gate["mining_gate_action"], "wait_for_live")
        assert_equal(round_trip_gate["mining_gate_live_claims"], 1)
        assert_equal(round_trip_gate["mining_gate_unsafe_claims"], 0)
        assert_equal(round_trip_gate["mining_gate_unsafe_components"], 0)
        self._assert_extra_inputs_unchanged(
            claimant, claim_address, untouched_inputs
        )
        assert_equal(
            claimant.getquantumkeyinventory(), historical_quantum_inventory
        )
        assert_equal(
            claimant.listquantumaddresses(), historical_quantum_addresses
        )


if __name__ == "__main__":
    GoldRushV3014QQP2UpgradeTest().main()
