#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Exercise QQSPROOF single-flight, quarantine, and bounded recovery.

Two concurrent sendshadowpowclaim callers must produce one wallet transaction.
If a claim leaves the mempool or broadcast throws after wallet persistence,
the wallet must quarantine it and keep its input reserved because a peer copy
can still confirm. Generic manual abandonment remains deliberately refused.
An exact fee-paying conflict may be created only through the explicit manual
recovery flow or a wallet-scoped, bounded automatic-recovery policy, and its
durable relay authority must survive restart without changing the signed bytes.
"""

from decimal import Decimal
from threading import Thread
import time
from urllib.parse import quote

from test_framework.blocktools import COIN, COINBASE_MATURITY
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_raises_rpc_error, get_rpc_proxy


GOLD_RUSH_END_TIME = 2_000_000_000
MANUAL_WALLET = "pow_claim_manual"
DESCENDANT_BLOCKER_WALLET = "pow_claim_descendant_blocker"
BUILTIN_WALLET = "pow_claim_builtin"
POLICY_WALLET = "pow_claim_policy"
POLICY_LOCK_WALLET = "pow_claim_policy_lock"
BUILTIN_RACE_WALLET = "pow_claim_builtin_race"
LOCK_BARRIER_WALLET = "pow_claim_lock_barrier"
TIE_WALLET = "pow_claim_tie"
FAULT_WALLET = "pow_claim_fault"
BOUNDARY_WALLET = "pow_claim_boundary"
CROSS_BOUNDARY_WALLET = "pow_claim_cross_boundary"
LIVE_FEE_VALUES = (Decimal("0.991"), Decimal("501.747137"), Decimal("969.818832"))
ZERO_HASH = "0" * 64
QQSPROOF = b"QQSPROOF"


class GoldRushPowClaimSingleFlightTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.base_args = [
            "-allowunsafequantumkeyrpc=1",
            # This fixture exercises PoW-claim wallet serialization. Keep
            # background PoS from advancing the tip while a boundary claim is
            # deliberately paused across restart.
            "-staking=0",
            "-txindex=1",
            "-shadowwhitelistheight=1",
            "-shadowgoldrushblocks=600",
            # Keep this focused on historical QQP2 single-flight behavior.
            # The direct same-anchor continuation below is completed while
            # both the stale proof and refreshed work are still QQP2. QQP4
            # behavior remains covered by the contention and index-boundary
            # tests rather than this wallet-lifecycle fixture.
            "-shadowcompetingclaimsheight=501",
            f"-qqgoldrushendtime={GOLD_RUSH_END_TIME}",
        ]
        self.extra_args = [[
            *self.base_args,
            "-qqshadowpowclaimsubmissiondelaymillis=1500",
            "-qqshadowpowclaimcommitdelaymillis=1500",
        ]]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def _set_mocktime(self, timestamp):
        self.mock_time = timestamp
        self.nodes[0].setmocktime(timestamp)

    def _bump_mocktime(self, seconds):
        self._set_mocktime(self.mock_time + seconds)

    def _advance_past_mempool_entry_time(self, node, txid):
        """Advance monotonically beyond an entry before forcing zero-hour expiry."""
        entry_time = node.getmempoolentry(txid)["time"]
        self._set_mocktime(max(self.mock_time, entry_time) + 2)

    def _load_wallet(self, name):
        node = self.nodes[0]
        if name not in node.listwallets():
            node.loadwallet(name)
        return node.get_wallet_rpc(name)

    @staticmethod
    def _is_abandoned(wallet, txid):
        return any(detail.get("abandoned", False) for detail in wallet.gettransaction(txid)["details"])

    def _claim_txids(self, wallet):
        return {
            entry["txid"]
            for entry in wallet.listtransactions("*", 1000, 0, True)
            if entry.get("comment") == "PoW Claim"
        }

    def _quarantined_claim_txids(self, wallet):
        mempool = set(self.nodes[0].getrawmempool())
        return {
            txid
            for txid in self._claim_txids(wallet)
            if txid not in mempool and not self._is_abandoned(wallet, txid)
        }

    def _claim_input(self, txid):
        decoded = self.nodes[0].decoderawtransaction(self.nodes[0].getrawtransaction(txid))
        assert_equal(len(decoded["vin"]), 1)
        return {"txid": decoded["vin"][0]["txid"], "vout": decoded["vin"][0]["vout"]}

    def _claim_scripts(self, wallet, txid):
        """Return the proof magic plus target and payout scripts for a claim."""
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

    def _fund_live_fee_inputs(self, source_wallet, target_wallet, target_address, funding_address):
        for amount in LIVE_FEE_VALUES:
            source_wallet.sendtoaddress(target_address, amount)
        self.generatetoaddress(self.nodes[0], 1, funding_address, sync_fun=self.no_op)
        utxos = target_wallet.listunspent(1, 9999999, [target_address])
        assert_equal(sorted(Decimal(str(utxo["amount"])) for utxo in utxos), sorted(LIVE_FEE_VALUES))
        return {
            Decimal(str(utxo["amount"])): {"txid": utxo["txid"], "vout": utxo["vout"]}
            for utxo in utxos
        }

    def _wait_for_new_quarantined_claim(self, wallet, before, timeout=180):
        self.wait_until(
            lambda: len(self._quarantined_claim_txids(wallet) - before) > 0,
            timeout=timeout,
        )
        return sorted(self._quarantined_claim_txids(wallet) - before)[0]

    def _assert_generic_abandon_rejected(self, wallet, txid):
        assert_equal(self._is_abandoned(wallet, txid), False)
        assert_raises_rpc_error(
            -5,
            "Transaction not eligible for abandonment",
            wallet.abandontransaction,
            txid,
        )
        assert_equal(self._is_abandoned(wallet, txid), False)

    @staticmethod
    def _assert_claim_inventory(wallet, raw, actionable, resolved, indeterminate, components=None):
        info = wallet.getpowmininginfo()
        assert_equal(info["quarantined_claims"], actionable + indeterminate)
        assert_equal(info["raw_quarantined_claims"], raw)
        assert_equal(info["blocking_quarantined_claims"], actionable + indeterminate)
        assert_equal(info["actionable_quarantined_claims"], actionable)
        assert_equal(info["resolved_on_active_chain_claims"], resolved)
        assert_equal(info["indeterminate_quarantined_claims"], indeterminate)
        if components is not None:
            assert_equal(info["claim_components"], components)
        assert_equal(info["claim_inventory_wallet_tip_matches"], True)
        assert_equal(len(info["claim_inventory_tip"]), 64)
        return info

    @staticmethod
    def _recovery_semantic_snapshot(wallet):
        """Return restart/rescan-stable policy, graph, and accounting state."""
        info = wallet.getpowclaimrecoveryinfo(True)
        component_fields = (
            "anchor",
            "generation_fingerprint",
            "component_fingerprint",
            "classification",
            "claim_txids",
            "root_claim_txids",
            "resolution_txids",
            "ordinary_or_mixed_txids",
            "descendant_claims",
            "anchor_authenticated",
            "anchor_unspent",
            "all_claims_quarantined",
            "all_claims_explicitly_provenanced",
            "has_revalidating_unbound_proof",
        )
        node_fields = (
            "txid",
            "kind",
            "provenance",
            "disposition",
            "proof_may_revalidate_on_descendant",
            "active_chain_confirmed",
            "in_mempool",
            "quarantined",
            "expected_shape",
            "wallet_authored",
            "abandoned",
            "lineage_metadata_present",
            "lineage_metadata_valid",
            "lineage_family_fingerprint",
            "lineage_root_txid",
            "lineage_parent_txid",
            "lineage_ordinal",
            "resolution_metadata_valid",
            "resolution_relay_authorized",
        )
        components = []
        for component in info["component_details"]:
            snapshot = {field: component[field] for field in component_fields}
            snapshot["nodes"] = sorted(
                (
                    {field: node[field] for field in node_fields}
                    for node in component["nodes"]
                ),
                key=lambda node: (node["txid"], node["kind"]),
            )
            components.append(snapshot)
        components.sort(
            key=lambda component: (
                component["anchor"]["txid"],
                component["anchor"]["vout"],
                component["component_fingerprint"],
            )
        )
        metric_fields = (
            "pending_manual_resolutions",
            "pending_automatic_resolutions",
            "confirmed_manual_resolutions",
            "confirmed_automatic_resolutions",
            "confirmed_resolution_fees",
            "automatic_actions_in_window",
            "automatic_fee_exposure_in_window",
            "reconciled_descendant_claims",
            "claims_recycled",
        )
        return {
            "policy": info.get("policy"),
            "policy_authoritative": info["policy_authoritative"],
            "policy_state_status": info["policy_state_status"],
            "database_outcome_ambiguous": info["database_outcome_ambiguous"],
            "active_tip": info["active_tip"],
            "metrics": {field: info[field] for field in metric_fields},
            "components": components,
        }

    @staticmethod
    def _mining_gate_semantic_snapshot(wallet):
        """Return the restart/rescan-stable typed claim-gate decision.

        The candidate-state fingerprint is a transient cache invalidator, so
        validate its shape for this observation without treating its bytes as
        a cross-reconstruction semantic identity.
        """
        info = wallet.getpowmininginfo()
        candidate_fingerprint = info[
            "mining_gate_candidate_state_fingerprint"
        ]
        assert_equal(len(candidate_fingerprint), 64)
        assert candidate_fingerprint != "0" * 64
        assert_equal(
            info["mining_gate_coherent"],
            info["claim_inventory_wallet_tip_matches"]
            and info["claim_inventory_tip"] != "0" * 64,
        )
        fields = (
            "claim_inventory_tip",
            "claim_inventory_wallet_tip_matches",
            "mining_gate_coherent",
            "mining_gate_action",
            "mining_gate_can_submit",
            "mining_gate_database_ambiguous",
            "mining_gate_unresolved_components",
            "mining_gate_live_claims",
            "mining_gate_eligible_claims",
            "mining_gate_family_claims",
            "mining_gate_unsafe_claims",
            "mining_gate_unsafe_components",
            "mining_gate_relay_txid",
            "mining_gate_lineage_head_txid",
        )
        return {field: info[field] for field in fields}

    def run_test(self):
        node = self.nodes[0]
        self._set_mocktime((int(time.time()) & ~0xf) + 16)
        default_wallet = node.get_wallet_rpc(self.default_wallet_name)
        default_wallet.staking(False)

        node.createwallet(wallet_name=MANUAL_WALLET)
        node.createwallet(wallet_name=DESCENDANT_BLOCKER_WALLET)
        node.createwallet(wallet_name=BUILTIN_WALLET)
        node.createwallet(wallet_name=POLICY_WALLET)
        node.createwallet(wallet_name=POLICY_LOCK_WALLET)
        node.createwallet(wallet_name=BUILTIN_RACE_WALLET)
        node.createwallet(wallet_name=LOCK_BARRIER_WALLET)
        node.createwallet(wallet_name=TIE_WALLET)
        node.createwallet(wallet_name=FAULT_WALLET)
        node.createwallet(wallet_name=BOUNDARY_WALLET)
        node.createwallet(wallet_name=CROSS_BOUNDARY_WALLET)
        manual = node.get_wallet_rpc(MANUAL_WALLET)
        builtin = node.get_wallet_rpc(BUILTIN_WALLET)
        policy = node.get_wallet_rpc(POLICY_WALLET)
        policy_lock = node.get_wallet_rpc(POLICY_LOCK_WALLET)
        builtin_race = node.get_wallet_rpc(BUILTIN_RACE_WALLET)
        lock_barrier = node.get_wallet_rpc(LOCK_BARRIER_WALLET)
        tie_wallet = node.get_wallet_rpc(TIE_WALLET)
        fault = node.get_wallet_rpc(FAULT_WALLET)
        boundary = node.get_wallet_rpc(BOUNDARY_WALLET)
        cross_boundary = node.get_wallet_rpc(CROSS_BOUNDARY_WALLET)
        descendant_blocker = node.get_wallet_rpc(DESCENDANT_BLOCKER_WALLET)
        for wallet in (
            manual,
            descendant_blocker,
            builtin,
            policy,
            policy_lock,
            builtin_race,
            lock_barrier,
            tie_wallet,
            fault,
            boundary,
            cross_boundary,
        ):
            wallet.staking(False)
        manual_address = manual.getnewaddress("claim-input", "legacy")
        descendant_blocker_address = descendant_blocker.getnewaddress("claim-input", "legacy")
        builtin_address = builtin.getnewaddress("claim-input", "legacy")
        policy_address = policy.getnewaddress("claim-input", "legacy")
        policy_lock_address = policy_lock.getnewaddress("claim-input", "legacy")
        builtin_race_address = builtin_race.getnewaddress("claim-input", "legacy")
        lock_barrier_address = lock_barrier.getnewaddress(
            "claim-input", "legacy"
        )
        tie_address = tie_wallet.getnewaddress("claim-input", "legacy")
        fault_address = fault.getnewaddress("claim-input", "legacy")
        boundary_address = boundary.getnewaddress("claim-input", "legacy")
        cross_boundary_address = cross_boundary.getnewaddress(
            "claim-input", "legacy"
        )
        funding_address = default_wallet.getnewaddress("claim-test-funding", "legacy")

        self.log.info("Funding independent manual and built-in claim wallets")
        self.generatetoaddress(node, 1, manual_address, sync_fun=self.no_op)
        self.generatetoaddress(node, 1, descendant_blocker_address, sync_fun=self.no_op)
        self.generatetoaddress(node, 1, builtin_address, sync_fun=self.no_op)
        self.generatetoaddress(
            node, 1, lock_barrier_address, sync_fun=self.no_op
        )
        self.generatetoaddress(node, 1, fault_address, sync_fun=self.no_op)
        self.generatetoaddress(node, 1, boundary_address, sync_fun=self.no_op)
        self.generatetoaddress(
            node, 1, cross_boundary_address, sync_fun=self.no_op
        )
        self.generatetoaddress(node, COINBASE_MATURITY + 5, funding_address, sync_fun=self.no_op)
        assert_equal(node.getquantumquasarinfo()["phase"], "gold_rush")
        assert_equal(len(manual.listunspent(1, 9999999, [manual_address])), 1)
        assert_equal(
            len(descendant_blocker.listunspent(1, 9999999, [descendant_blocker_address])),
            1,
        )
        assert_equal(len(builtin.listunspent(1, 9999999, [builtin_address])), 1)
        lock_barrier_inputs = lock_barrier.listunspent(
            1, 9999999, [lock_barrier_address]
        )
        assert_equal(len(lock_barrier_inputs), 1)
        lock_barrier_input = {
            "txid": lock_barrier_inputs[0]["txid"],
            "vout": lock_barrier_inputs[0]["vout"],
        }

        self.log.info("Funding a second confirmed boundary-wallet fee input for quarantine-gate coverage")
        default_wallet.sendtoaddress(boundary_address, Decimal("1.25000000"))
        default_wallet.sendtoaddress(
            cross_boundary_address, Decimal("1.25000000")
        )
        self.generatetoaddress(node, 1, funding_address, sync_fun=self.no_op)

        self.log.info("Funding live-scale same-script fee inputs for deterministic policy coverage")
        policy_inputs = self._fund_live_fee_inputs(default_wallet, policy, policy_address, funding_address)
        policy_lock_inputs = self._fund_live_fee_inputs(default_wallet, policy_lock, policy_lock_address, funding_address)
        builtin_race_inputs = self._fund_live_fee_inputs(default_wallet, builtin_race, builtin_race_address, funding_address)

        policy_payout = policy.getnewquantumaddress("policy-payout")["address"]
        self.log.info("A fresh selected input locked at the test barrier cannot fall back to a larger coin")
        policy_before_race = self._claim_txids(policy)
        assert_equal(policy_before_race, set())
        expected_policy_race_input = policy_inputs[LIVE_FEE_VALUES[0]]
        policy_race_errors = []

        def submit_policy_race():
            wallet_url = f"{node.url}/wallet/{quote(POLICY_WALLET, safe='')}"
            rpc = get_rpc_proxy(wallet_url, 92, timeout=300, coveragedir=node.coverage_dir)
            try:
                rpc.sendshadowpowclaim(policy_address, policy_payout, 500000)
            except Exception as error:
                policy_race_errors.append(str(error))

        policy_race_thread = Thread(target=submit_policy_race, name="policy-input-race", daemon=True)
        with node.wait_for_debug_log([b"Gold Rush PoW claim submission test barrier reached"], timeout=20):
            policy_race_thread.start()
        assert_equal(policy.lockunspent(False, [policy_inputs[LIVE_FEE_VALUES[0]]]), True)
        policy_race_thread.join(timeout=300)
        assert not policy_race_thread.is_alive(), "policy input race caller did not finish"
        assert_equal(len(policy_race_errors), 1)
        assert "Selected Gold Rush PoW claim input" in policy_race_errors[0]
        assert (
            f"COutPoint({expected_policy_race_input['txid'][:10]}, "
            f"{expected_policy_race_input['vout']})" in policy_race_errors[0]
        )
        assert "changed while grinding" in policy_race_errors[0]
        assert_equal(self._claim_txids(policy), policy_before_race)
        assert_equal(policy.lockunspent(True, [policy_inputs[LIVE_FEE_VALUES[0]]]), True)

        self.log.info("Manual claims choose the smallest sufficient same-script input")
        policy_claim = policy.sendshadowpowclaim(policy_address, policy_payout, 500000)
        assert_equal(self._claim_input(policy_claim["txid"]), policy_inputs[LIVE_FEE_VALUES[0]])
        # The live claim creates an unconfirmed same-script change output. It
        # must never become a second fee anchor while the first claim remains
        # live; same-anchor refresh is authorized only after the head leaves
        # the mempool.
        assert any(
            utxo["txid"] == policy_claim["txid"] and utxo["vout"] == 0
            for utxo in policy.listunspent(0, 9999999, [policy_address])
        )

        # Historical QQP2 policy permits one live proof in the global mempool.
        # Clear that slot explicitly before exercising the independent
        # pre-locked-input wallet, and prove the expired policy claim remains
        # quarantined rather than being abandoned or spending its input again.
        self.generateblock(node, output=funding_address, transactions=[])
        self.wait_until(lambda: policy_claim["txid"] not in node.getrawmempool(), timeout=20)
        self.wait_until(lambda: policy_claim["txid"] in self._quarantined_claim_txids(policy), timeout=20)
        self._assert_generic_abandon_rejected(policy, policy_claim["txid"])

        self.log.info("A coin already locked before selection is skipped deterministically")
        policy_lock_payout = policy_lock.getnewquantumaddress("policy-lock-payout")["address"]
        assert_equal(policy_lock.lockunspent(False, [policy_lock_inputs[LIVE_FEE_VALUES[0]]]), True)
        locked_small_claim = policy_lock.sendshadowpowclaim(
            policy_lock_address, policy_lock_payout, 500000
        )
        assert_equal(
            self._claim_input(locked_small_claim["txid"]),
            policy_lock_inputs[LIVE_FEE_VALUES[1]],
        )
        self.generateblock(node, output=funding_address, transactions=[])
        self.wait_until(lambda: locked_small_claim["txid"] not in node.getrawmempool(), timeout=20)
        self._assert_generic_abandon_rejected(policy_lock, locked_small_claim["txid"])
        assert_equal(policy_lock.lockunspent(True, [policy_lock_inputs[LIVE_FEE_VALUES[0]]]), True)

        self.log.info("Automatic claim recovery is wallet-scoped, default-off, bounded, and zero-touch")
        # Establish the branch-relative observation while automatic recovery
        # is still disabled. Slow sanitizer builds can otherwise let the
        # periodic scheduler record this observation before an intervening
        # test block, making a hard-coded zero depth timing-dependent.
        automatic_claim_txids_before = self._claim_txids(policy)
        node.syncwithvalidationinterfacequeue()
        node.mockscheduler(61)
        node.syncwithvalidationinterfacequeue()
        self.wait_until(
            lambda: (
                policy.getpowclaimrecoveryinfo(True)["wallet_tip_matches"]
                and policy.getpowclaimrecoveryinfo(True)["component_details"][0]["stale_depth_known"]
            ),
            timeout=20,
        )
        automatic_baseline_info = policy.getpowclaimrecoveryinfo(True)
        assert_equal(automatic_baseline_info["wallet_tip_matches"], True)
        assert_equal(automatic_baseline_info["active_tip"], node.getbestblockhash())
        assert_equal(
            automatic_baseline_info["wallet_processed_tip"],
            automatic_baseline_info["active_tip"],
        )
        assert_equal(
            automatic_baseline_info["pending_automatic_resolutions"],
            0,
        )
        assert_equal(self._claim_txids(policy), automatic_claim_txids_before)
        policy_initial_info = automatic_baseline_info
        assert_equal(policy_initial_info["policy"]["mode"], "unset")
        assert_equal(policy_initial_info["policy_authoritative"], True)
        assert_equal(policy_initial_info["policy_state_status"], "success")
        assert_equal(policy_lock.getpowclaimrecoveryinfo()["policy"]["mode"], "unset")
        automatic_initial_stale_depth = automatic_baseline_info[
            "component_details"
        ][0]["minimum_stale_depth"]
        automatic_limits = {
            "max_fee_per_resolution": Decimal("0.01"),
            "aggregate_batch_fee_cap": Decimal("0.05"),
            "rolling_fee_budget": Decimal("0.10"),
            "rolling_fee_window_seconds": 86400,
            "max_actions_per_window": 5,
            "minimum_stale_blocks": automatic_initial_stale_depth + 1,
        }
        automatic_policy = policy.setpowclaimrecovery("automatic", automatic_limits)
        assert_equal(automatic_policy["status"], "success")
        assert_equal(automatic_policy["success"], True)
        assert_equal(automatic_policy["durable_state_changed"], True)
        assert_equal(automatic_policy["durable_state_ambiguous"], False)
        assert_equal(automatic_policy["authoritative_state_available"], True)
        assert_equal(automatic_policy["policy"]["mode"], "automatic")
        assert_equal(automatic_policy["policy"]["automatic_authorized"], True)
        assert_equal(policy_lock.getpowclaimrecoveryinfo()["policy"]["mode"], "unset")

        automatic_resolution_txid = None
        automatic_running_state = None
        started = policy.setpowmining(True, 1, 1, True)
        assert_equal(started["enabled"], True)
        try:
            # The first automatic scheduler pass rechecks the typed,
            # branch-relative observation at the same pinned tip. It must not
            # spend before another block satisfies the configured delay.
            node.mockscheduler(61)
            self.wait_until(
                lambda: policy.getpowclaimrecoveryinfo(True)["component_details"][0]["stale_depth_known"],
                timeout=20,
            )
            same_tip_automatic_info = policy.getpowclaimrecoveryinfo(True)
            assert_equal(same_tip_automatic_info["wallet_tip_matches"], True)
            assert_equal(
                same_tip_automatic_info["active_tip"],
                automatic_baseline_info["active_tip"],
            )
            assert_equal(
                same_tip_automatic_info["component_details"][0]["minimum_stale_depth"],
                automatic_initial_stale_depth,
            )
            assert_equal(
                same_tip_automatic_info["pending_automatic_resolutions"],
                0,
            )
            assert_equal(self._claim_txids(policy), automatic_claim_txids_before)

            # Mature the persisted observation by the configured number of
            # active-branch blocks, then let the next scheduler pass create,
            # persist, authorize, and relay the exact resolution bytes.
            self.generateblock(node, output=funding_address, transactions=[])
            self.wait_until(
                lambda: policy.getpowclaimrecoveryinfo(True)["component_details"][0]["minimum_stale_depth"]
                >= automatic_limits["minimum_stale_blocks"],
                timeout=20,
            )
            node.mockscheduler(61)
            self.wait_until(
                lambda: policy.getpowclaimrecoveryinfo()["pending_automatic_resolutions"] == 1,
                timeout=30,
            )

            # Keep the miner enabled while its automatic resolution confirms.
            # The confirmed same-script output must release the quarantine gate
            # and return the miner to an active state without operator action.
            pending_automatic_info = policy.getpowclaimrecoveryinfo(True)
            pending_resolution_nodes = [
                graph_node
                for component in pending_automatic_info["component_details"]
                for graph_node in component["nodes"]
                if graph_node["kind"] == "managed_resolution"
            ]
            assert_equal(len(pending_resolution_nodes), 1)
            automatic_resolution_txid = pending_resolution_nodes[0]["txid"]
            assert_equal(pending_resolution_nodes[0]["resolution_relay_authorized"], True)
            assert automatic_resolution_txid in node.getrawmempool()
            automatic_resolution_block = self.generateblock(
                node,
                output=funding_address,
                transactions=[automatic_resolution_txid],
            )["hash"]
            assert automatic_resolution_txid in node.getblock(automatic_resolution_block)["tx"]
            node.syncwithvalidationinterfacequeue()
            self.wait_until(
                lambda: policy.gettransaction(automatic_resolution_txid)["confirmations"] > 0,
                timeout=20,
            )
            self.wait_until(
                lambda: policy.getpowmininginfo()["state"]
                in {"ready", "hashing", "claim_in_flight"},
                timeout=20,
            )
            automatic_running_state = policy.getpowmininginfo()["state"]
        finally:
            policy.setpowmining(False)
        assert automatic_resolution_txid is not None
        assert automatic_running_state in {"ready", "hashing", "claim_in_flight"}
        # Stop immediately after proving the recovery loop reopened mining so
        # this wallet cannot consume the global QQP2 claim slot used below.
        assert_equal(self._claim_txids(policy), automatic_claim_txids_before)
        automatic_info = policy.getpowclaimrecoveryinfo(True)
        assert_equal(automatic_info["automatic_actions_in_window"], 1)
        assert automatic_info["automatic_fee_exposure_in_window"] > 0
        assert_equal(automatic_info["pending_automatic_resolutions"], 0)
        assert_equal(automatic_info["confirmed_automatic_resolutions"], 1)
        automatic_component = automatic_info["component_details"][0]
        assert_equal(automatic_component["classification"], "resolved_on_active_chain")
        assert_equal(automatic_component["anchor_unspent"], False)
        assert_equal(automatic_component["has_revalidating_unbound_proof"], False)
        assert all(
            graph_node["proof_evaluation_skipped_resolved_anchor"]
            for graph_node in automatic_component["nodes"]
            if graph_node["kind"] == "claim"
        )
        automatic_resolution_nodes = [
            graph_node
            for component in automatic_info["component_details"]
            for graph_node in component["nodes"]
            if graph_node["kind"] == "managed_resolution"
        ]
        assert_equal(len(automatic_resolution_nodes), 1)
        assert_equal(automatic_resolution_nodes[0]["txid"], automatic_resolution_txid)
        assert_equal(automatic_resolution_nodes[0]["resolution_relay_authorized"], True)
        assert policy.gettransaction(automatic_resolution_txid)["confirmations"] > 0

        self.log.info("Equal-value candidates use stable COutPoint ordering")
        tie_value = Decimal("1.25000000")
        default_wallet.sendtoaddress(tie_address, tie_value)
        default_wallet.sendtoaddress(tie_address, tie_value)
        self.generatetoaddress(node, 1, funding_address, sync_fun=self.no_op)
        tie_inputs = tie_wallet.listunspent(1, 9999999, [tie_address])
        assert_equal(len(tie_inputs), 2)
        expected_tie_input = min(
            ({"txid": utxo["txid"], "vout": utxo["vout"]} for utxo in tie_inputs),
            key=lambda outpoint: (bytes.fromhex(outpoint["txid"])[::-1], outpoint["vout"]),
        )
        tie_payout = tie_wallet.getnewquantumaddress("tie-payout")["address"]
        tie_claim = tie_wallet.sendshadowpowclaim(tie_address, tie_payout, 500000)
        assert_equal(self._claim_input(tie_claim["txid"]), expected_tie_input)
        self.generateblock(node, output=funding_address, transactions=[])
        self.wait_until(lambda: tie_claim["txid"] not in node.getrawmempool(), timeout=20)
        self._assert_generic_abandon_rejected(tie_wallet, tie_claim["txid"])

        self.log.info("Wallet lock at the miner submission barrier cancels the pending claim")
        lock_barrier_passphrase = "pow-claim-lock-barrier-passphrase"
        lock_barrier.encryptwallet(lock_barrier_passphrase)
        lock_barrier.walletpassphrase(
            lock_barrier_passphrase, 600, False
        )
        lock_barrier_before = self._claim_txids(lock_barrier)
        with node.wait_for_debug_log(
            [b"Gold Rush PoW claim submission test barrier reached"],
            timeout=180,
        ):
            lock_started = lock_barrier.setpowmining(True, 1, 100, True)
            assert lock_started["created_payout_key"]
        lock_barrier.walletlock()
        locked_info = lock_barrier.getpowmininginfo()
        assert_equal(locked_info["enabled"], True)
        assert_equal(locked_info["state"], "wallet_locked_or_staking_only")
        assert_equal(locked_info["hashrate"], 0)
        time.sleep(2)
        assert_equal(self._claim_txids(lock_barrier), lock_barrier_before)
        assert_equal(lock_barrier.getpowmininginfo()["claims_submitted"], 0)

        try:
            # A second barrier after the normal unlock is direct evidence that
            # the retained worker resumed, ground a fresh proof, and reached
            # the pre-submit authority check again. Lock during that barrier a
            # second time so neither stale proof can enter the commit path.
            with node.wait_for_debug_log(
                [b"Gold Rush PoW claim submission test barrier reached"],
                timeout=180,
            ):
                lock_barrier.walletpassphrase(
                    lock_barrier_passphrase, 600, False
                )
            # Lock is deliberately the first RPC after observing the barrier;
            # extra telemetry calls here would let a slow sanitizer consume the
            # 1.5-second test delay and enter claim persistence first.
            lock_barrier.walletlock()
            second_locked_info = lock_barrier.getpowmininginfo()
            assert_equal(second_locked_info["enabled"], True)
            assert_equal(second_locked_info["threads"], 1)
            assert_equal(second_locked_info["cpu_percent"], 100)
            assert_equal(
                second_locked_info["state"], "wallet_locked_or_staking_only"
            )
            assert_equal(second_locked_info["hashrate"], 0)
            assert_equal(
                lock_barrier.getwalletinfo()["unlocked_staking_only"], False
            )
            time.sleep(2)
            assert_equal(self._claim_txids(lock_barrier), lock_barrier_before)
            assert_equal(lock_barrier.getpowmininginfo()["claims_submitted"], 0)
        finally:
            lock_barrier.setpowmining(False)

        self.log.info(
            "A lock/unlock pulse after signing but before final wallet publication cancels the stale claim"
        )
        lock_barrier.walletpassphrase(
            lock_barrier_passphrase, 600, False
        )
        with node.wait_for_debug_log(
            [b"Gold Rush PoW claim final-commit authority test barrier reached"],
            timeout=180,
        ):
            final_commit_started = lock_barrier.setpowmining(
                True, 1, 100, True
            )
            assert_equal(final_commit_started["created_payout_key"], False)
        # Reserve the selected input without changing wallet unlock scope.
        # The final publication guard must observe this user-authority pulse
        # even after signing and reject the stale candidate atomically.
        assert_equal(
            lock_barrier.lockunspent(False, [lock_barrier_input]), True
        )
        try:
            time.sleep(2)
            assert_equal(self._claim_txids(lock_barrier), lock_barrier_before)
            assert_equal(
                lock_barrier.getpowmininginfo()["claims_submitted"], 0
            )
        finally:
            lock_barrier.setpowmining(False)
            assert_equal(
                lock_barrier.lockunspent(True, [lock_barrier_input]), True
            )

        self.log.info("The complete worker group waits for a new tip after its exact input becomes unavailable")
        builtin_race_before = self._claim_txids(builtin_race)
        with node.wait_for_debug_log([b"Gold Rush PoW claim submission test barrier reached"], timeout=180):
            started = builtin_race.setpowmining(True, 2, 100, True)
            assert started["created_payout_key"]
        with node.wait_for_debug_log([b"is no longer spendable; retry after the next tip"], timeout=20):
            assert_equal(builtin_race.lockunspent(False, [builtin_race_inputs[LIVE_FEE_VALUES[0]]]), True)
        try:
            def worker_group_waits_for_next_tip():
                info = builtin_race.getpowmininginfo()
                return (
                    info["state"] == "claim_in_flight"
                    and info["mining_gate_action"] == "wait_for_next_tip"
                )

            self.wait_until(worker_group_waits_for_next_tip, timeout=10)
            waiting_info = builtin_race.getpowmininginfo()
            assert_equal(waiting_info["threads"], 2)
            assert_equal(waiting_info["hashrate"], 0)
            time.sleep(2)
            assert_equal(self._claim_txids(builtin_race), builtin_race_before)
            assert_equal(builtin_race.getpowmininginfo()["claims_submitted"], 0)
            assert_equal(
                builtin_race.lockunspent(
                    True, [builtin_race_inputs[LIVE_FEE_VALUES[0]]]
                ),
                True,
            )
            # Unlocking the selected fee input on the same tip must not let a
            # sibling worker steal the wallet-wide slot and retry early.
            time.sleep(2)
            assert_equal(self._claim_txids(builtin_race), builtin_race_before)
            assert_equal(builtin_race.getpowmininginfo()["claims_submitted"], 0)
            self.generateblock(node, output=funding_address, transactions=[])
            self.wait_until(
                lambda: len(
                    self._claim_txids(builtin_race) - builtin_race_before
                )
                == 1,
                timeout=180,
            )
            builtin_race_claim = sorted(
                self._claim_txids(builtin_race) - builtin_race_before
            )[0]
        finally:
            builtin_race.setpowmining(False)
        assert_equal(self._claim_input(builtin_race_claim), builtin_race_inputs[LIVE_FEE_VALUES[0]])
        self.generateblock(node, output=funding_address, transactions=[])
        self.wait_until(lambda: builtin_race_claim not in node.getrawmempool(), timeout=20)
        self._assert_generic_abandon_rejected(builtin_race, builtin_race_claim)

        self.log.info("An ordinary descendant remains a blocker after local abandonment")
        descendant_blocker_payout = descendant_blocker.getnewquantumaddress(
            "descendant-blocker-payout"
        )["address"]
        blocker_claim = descendant_blocker.sendshadowpowclaim(
            descendant_blocker_address,
            descendant_blocker_payout,
            500000,
        )
        blocker_claim_txid = blocker_claim["txid"]
        blocker_change = node.getrawtransaction(blocker_claim_txid, True)["vout"][0]["value"]
        blocker_descendant = descendant_blocker.signrawtransactionwithwallet(
            node.createrawtransaction(
                [{"txid": blocker_claim_txid, "vout": 0}],
                {descendant_blocker_address: blocker_change - Decimal("0.01")},
            )
        )
        assert blocker_descendant["complete"]
        blocker_descendant_txid = node.sendrawtransaction(blocker_descendant["hex"])
        assert blocker_descendant_txid in node.getrawmempool()
        self.generateblock(node, output=funding_address, transactions=[])
        self.wait_until(lambda: blocker_claim_txid not in node.getrawmempool(), timeout=20)
        self.wait_until(lambda: blocker_descendant_txid not in node.getrawmempool(), timeout=20)
        assert_raises_rpc_error(
            -4,
            "has an unresolved wallet descendant",
            descendant_blocker.createshadowpowclaimresolution,
            blocker_claim_txid,
        )
        descendant_blocker.abandontransaction(blocker_descendant_txid)
        assert_equal(self._is_abandoned(descendant_blocker, blocker_descendant_txid), True)
        # Local abandonment cannot prove that a peer discarded an ordinary
        # conflicting descendant, so the claim-only resolver remains closed.
        assert_raises_rpc_error(
            -4,
            "has an unresolved wallet descendant",
            descendant_blocker.createshadowpowclaimresolution,
            blocker_claim_txid,
        )

        self.log.info("Two concurrent RPC callers create at most one clean claim")
        manual_payout = manual.getnewquantumaddress("single-flight-payout")["address"]
        first_results = []
        first_errors = []

        def submit_first_claim():
            wallet_url = f"{node.url}/wallet/{quote(MANUAL_WALLET, safe='')}"
            rpc = get_rpc_proxy(wallet_url, 91, timeout=300, coveragedir=node.coverage_dir)
            try:
                first_results.append(rpc.sendshadowpowclaim(manual_address, manual_payout, 500000))
            except Exception as error:
                first_errors.append(str(error))

        first_thread = Thread(target=submit_first_claim, name="first-pow-claim", daemon=True)
        with node.wait_for_debug_log([b"Gold Rush PoW claim submission test barrier reached"], timeout=20):
            first_thread.start()
        assert_raises_rpc_error(
            -4,
            "Another Gold Rush PoW claim submission is already in progress for this wallet",
            manual.sendshadowpowclaim,
            manual_address,
            manual_payout,
            1,
        )
        first_thread.join(timeout=300)
        assert not first_thread.is_alive(), "first sendshadowpowclaim caller did not finish"
        assert_equal(first_errors, [])
        assert_equal(len(first_results), 1)
        first_txid = first_results[0]["txid"]
        first_raw = node.getrawtransaction(first_txid)
        claim_change = node.getrawtransaction(first_txid, True)["vout"][0]["value"]
        assert first_txid in node.getrawmempool()
        assert_equal(self._claim_txids(manual), {first_txid})

        self.log.info("Advancing the clean claim quarantines its historical QQP2 proof")
        quarantine_block = self.generateblock(
            node,
            output=funding_address,
            transactions=[],
        )["hash"]
        self.wait_until(lambda: first_txid not in node.getrawmempool(), timeout=20)
        assert_equal(self._is_abandoned(manual, first_txid), False)
        assert_equal(len(manual.listunspent(1, 9999999, [manual_address])), 0)
        self._assert_generic_abandon_rejected(manual, first_txid)
        assert_equal(len(manual.listunspent(1, 9999999, [manual_address])), 0)
        self.log.info("A quarantined claim has a consent-only on-chain resolution path")
        preview = manual.createshadowpowclaimresolution(first_txid)
        assert_equal(preview["dry_run"], True)
        assert_equal(preview["broadcast"], False)
        assert_equal(preview["claim_txid"], first_txid)
        assert preview["fee"] > 0
        assert preview["output_amount"] > 0
        assert_equal(preview["conflicts_with_revalidating_unbound_proof"], True)
        assert "hex" not in preview
        assert first_txid not in node.getrawmempool()
        reviewed = manual.getpowclaimrecoveryinfo(True)
        reviewed_component = next(
            component
            for component in reviewed["component_details"]
            if first_txid in component["claim_txids"]
        )
        assert_equal(reviewed_component["has_revalidating_unbound_proof"], True)
        already_explicit = manual.adoptshadowpowclaimcomponent(
            first_txid,
            reviewed["active_tip"],
            reviewed_component["component_fingerprint"],
            True,
        )
        assert_equal(already_explicit["status"], "already_explicit")
        assert_equal(already_explicit["success"], True)
        assert_equal(already_explicit["adopted"], False)
        assert_equal(already_explicit["durable_state_changed"], False)
        assert_equal(already_explicit["durable_state_ambiguous"], False)
        assert_equal(already_explicit["claim_txids"], [first_txid])
        assert_equal(
            already_explicit["component_has_revalidating_unbound_proof"], True
        )
        self._assert_claim_inventory(
            manual, raw=1, actionable=1, resolved=0, indeterminate=0, components=1
        )

        assert_raises_rpc_error(
            -8,
            "acknowledge_fee_and_conflict_risk=true is required",
            manual.createshadowpowclaimresolution,
            first_txid,
            False,
            False,
        )
        resolution = manual.createshadowpowclaimresolution(
            first_txid,
            False,
            True,
        )
        assert_equal(resolution["dry_run"], False)
        assert_equal(resolution["broadcast"], False)
        assert_equal(resolution["fee"], preview["fee"])
        assert_equal(resolution["output_amount"], preview["output_amount"])
        assert_equal(
            resolution["conflicts_with_revalidating_unbound_proof"], True
        )
        assert resolution["txid"] not in node.getrawmempool()
        self._assert_claim_inventory(
            manual, raw=1, actionable=1, resolved=0, indeterminate=0, components=1
        )

        resolution_txid = node.sendrawtransaction(resolution["hex"])
        assert_equal(resolution_txid, resolution["txid"])
        self.wait_until(lambda: resolution_txid in node.getrawmempool(), timeout=20)
        # Publishing the conflict does not release the input. Only an active
        # chain confirmation of one side may resolve the reservation.
        self._assert_claim_inventory(
            manual, raw=1, actionable=1, resolved=0, indeterminate=0, components=1
        )
        assert_equal(len(manual.listunspent(1, 9999999, [manual_address])), 0)

        self.log.info("An unconfirmed resolution survives restart without releasing the shared input")
        self.restart_node(0, extra_args=[*self.base_args, f"-mocktime={self.mock_time}"])
        node = self.nodes[0]
        node.setmocktime(self.mock_time)
        manual = self._load_wallet(MANUAL_WALLET)
        policy = self._load_wallet(POLICY_WALLET)
        restarted_automatic_info = policy.getpowclaimrecoveryinfo(True)
        assert_equal(restarted_automatic_info["policy"]["mode"], "automatic")
        assert_equal(restarted_automatic_info["automatic_actions_in_window"], 1)
        assert_equal(restarted_automatic_info["pending_automatic_resolutions"], 0)
        assert_equal(restarted_automatic_info["confirmed_automatic_resolutions"], 1)
        assert policy.gettransaction(automatic_resolution_txid)["confirmations"] > 0
        assert_equal(manual.gettransaction(first_txid)["confirmations"], 0)
        assert_equal(manual.gettransaction(resolution_txid)["confirmations"], 0)
        self._assert_claim_inventory(
            manual, raw=1, actionable=1, resolved=0, indeterminate=0, components=1
        )
        assert_equal(len(manual.listunspent(1, 9999999, [manual_address])), 0)
        # An ordinary wallet resubmission may relay the operator-broadcast
        # resolution after restart. If startup scheduling has not done so yet,
        # relay the already-reviewed bytes again for the conflict-outcome test.
        if resolution_txid not in node.getrawmempool():
            assert_equal(node.sendrawtransaction(resolution["hex"]), resolution_txid)
        self.wait_until(lambda: resolution_txid in node.getrawmempool(), timeout=20)

        self.log.info("A peer-retained original claim can win on an alternate active chain")
        node.invalidateblock(quarantine_block)
        self.wait_until(lambda: node.getbestblockhash() != quarantine_block, timeout=20)
        original_block = self.generateblock(
            node,
            output=funding_address,
            transactions=[first_raw],
        )["hash"]
        assert first_txid in node.getblock(original_block)["tx"]
        node.syncwithvalidationinterfacequeue()
        assert manual.gettransaction(first_txid)["confirmations"] > 0
        assert manual.gettransaction(resolution_txid)["confirmations"] < 0
        original_info = manual.getpowmininginfo()
        assert_equal(original_info["unresolved_claims"], 0)
        self._assert_claim_inventory(
            manual, raw=0, actionable=0, resolved=0, indeterminate=0, components=0
        )
        assert_equal(len(manual.listunspent(1, 9999999, [manual_address])), 1)

        self.log.info("The confirmed claim output becomes eligible for legacy PoS and a fresh PoW claim")
        self.generatetoaddress(
            node,
            COINBASE_MATURITY - 1,
            funding_address,
            sync_fun=self.no_op,
        )
        # This fixture normally sets -staking=0 so PoS cannot move the tip
        # during claim-boundary tests. Permit an explicitly requested scan,
        # while retaining process-wide autostart=off so no other loaded wallet
        # can stake in the background.
        staking_args = [arg for arg in self.base_args if not arg.startswith("-staking=")]
        staking_args.extend([
            "-staking=1",
            "-autostartstaking=0",
            f"-mocktime={self.mock_time}",
        ])
        self.restart_node(0, extra_args=staking_args)
        node = self.nodes[0]
        node.setmocktime(self.mock_time)
        manual = self._load_wallet(MANUAL_WALLET)
        stake_height = node.getblockcount()
        expected_stake_weight = int(claim_change * COIN)
        manual.staking(True)
        try:
            self._bump_mocktime(16)
            self.wait_until(
                lambda: (
                    manual.getstakinginfo()["weight_cache_height"] == stake_height
                    and manual.getstakinginfo()["weight"] == expected_stake_weight
                ),
                timeout=20,
            )
        finally:
            manual.staking(False)
        assert_equal(node.getblockcount(), stake_height)

        self.log.info("The clean confirmed claim can fund an ordinary descendant and a new claim")
        descendant = manual.signrawtransactionwithwallet(node.createrawtransaction(
            [{"txid": first_txid, "vout": 0}],
            {manual_address: claim_change - Decimal("0.01")},
        ))
        assert descendant["complete"]
        descendant_txid = node.sendrawtransaction(descendant["hex"])
        descendant_block = self.generateblock(
            node,
            output=funding_address,
            transactions=[descendant_txid],
        )["hash"]
        assert descendant_txid in node.getblock(descendant_block)["tx"]
        node.syncwithvalidationinterfacequeue()
        assert manual.gettransaction(descendant_txid)["confirmations"] > 0

        second_claim = manual.sendshadowpowclaim(manual_address, manual_payout, 500000)
        second_claim_txid = second_claim["txid"]
        assert_equal(
            self._claim_input(second_claim_txid),
            {"txid": descendant_txid, "vout": 0},
        )
        self.generateblock(
            node,
            output=funding_address,
            transactions=[],
        )
        self.wait_until(lambda: second_claim_txid not in node.getrawmempool(), timeout=20)
        self.wait_until(
            lambda: second_claim_txid in self._quarantined_claim_txids(manual),
            timeout=20,
        )

        second_preview = manual.resolveallshadowpowclaims()
        assert_equal(second_preview["action"], "preview")
        assert_equal(second_preview["plan_reusable"], True)
        assert_equal(second_preview["actionable_components"], 1)
        assert_equal(second_preview["contains_revalidating_unbound_proof"], True)
        assert_equal(second_preview["actions"][0]["claim_txids"], [second_claim_txid])
        assert_equal(
            second_preview["actions"][0]["conflicts_with_revalidating_unbound_proof"],
            True,
        )
        second_signed = manual.resolveallshadowpowclaims({
            "action": "sign_only",
            "expected_plan_id": second_preview["plan_id"],
            "acknowledge_fee_and_conflict_risk": True,
        })
        assert_equal(second_signed["success"], True)
        assert_equal(second_signed["signed_and_persisted"], 1)
        assert_equal(second_signed["durable_state_changed"], True)
        assert_equal(second_signed["plan_consumed"], True)
        assert_equal(second_signed["plan_reusable"], False)
        assert_equal(second_signed["contains_revalidating_unbound_proof"], True)
        assert_equal(second_signed["current_plan"]["plan_reusable"], True)
        second_resolution_txid = second_signed["actions"][0]["resolution_txid"]
        assert second_resolution_txid not in node.getrawmempool()
        second_committed = manual.resolveallshadowpowclaims({
            "action": "commit_and_broadcast",
            "expected_plan_id": second_signed["current_plan"]["plan_id"],
            "acknowledge_fee_and_conflict_risk": True,
        })
        assert_equal(second_committed["success"], True)
        assert_equal(second_committed["durable_state_changed"], True)
        assert_equal(second_committed["relay_authority_granted"], 1)
        assert_equal(second_committed["broadcast"] + second_committed["already_in_mempool"], 1)
        assert second_resolution_txid in node.getrawmempool()
        resolution_block = self.generateblock(
            node,
            output=funding_address,
            transactions=[second_resolution_txid],
        )["hash"]
        assert second_resolution_txid in node.getblock(resolution_block)["tx"]
        node.syncwithvalidationinterfacequeue()
        assert manual.gettransaction(second_claim_txid)["confirmations"] < 0
        assert manual.gettransaction(second_resolution_txid)["confirmations"] > 0
        resolution_info = manual.getpowmininginfo()
        # `unresolved_claims` is the raw count of wallet-authored,
        # non-confirmed QQSPROOF history, including a conflicted claim whose
        # anchor generation is conclusively resolved. It is not the mining
        # blocker count exposed by the typed inventory and gate.
        assert_equal(resolution_info["unresolved_claims"], 1)
        assert_equal(resolution_info["live_claims"], 0)
        assert_equal(resolution_info["mining_gate_action"], "create_new_anchor")
        self._assert_claim_inventory(
            manual, raw=1, actionable=0, resolved=1, indeterminate=0, components=1
        )
        confirmed_recovery_metrics = manual.getpowclaimrecoveryinfo()
        assert_equal(confirmed_recovery_metrics["pending_manual_resolutions"], 0)
        assert_equal(confirmed_recovery_metrics["confirmed_manual_resolutions"], 1)
        assert_equal(
            confirmed_recovery_metrics["confirmed_resolution_fees"],
            second_signed["actions"][0]["fee"],
        )
        assert_equal(len(manual.listunspent(1, 9999999, [manual_address])), 1)

        self.log.info("Reorging the resolution never exposes the shared input twice")
        node.invalidateblock(resolution_block)
        self.wait_until(lambda: second_resolution_txid in node.getrawmempool(), timeout=20)
        node.syncwithvalidationinterfacequeue()
        self._assert_claim_inventory(
            manual, raw=1, actionable=1, resolved=0, indeterminate=0, components=1
        )
        disconnected_recovery_metrics = manual.getpowclaimrecoveryinfo()
        assert_equal(disconnected_recovery_metrics["pending_manual_resolutions"], 1)
        assert_equal(disconnected_recovery_metrics["confirmed_manual_resolutions"], 0)
        assert_equal(
            disconnected_recovery_metrics["confirmed_resolution_fees"],
            Decimal("0"),
        )
        assert_equal(len(manual.listunspent(1, 9999999, [manual_address])), 0)
        node.reconsiderblock(resolution_block)
        self.wait_until(lambda: node.getbestblockhash() == resolution_block, timeout=20)
        node.syncwithvalidationinterfacequeue()
        self._assert_claim_inventory(
            manual, raw=1, actionable=0, resolved=1, indeterminate=0, components=1
        )
        restored_recovery_metrics = manual.getpowclaimrecoveryinfo()
        for field in (
            "pending_manual_resolutions",
            "confirmed_manual_resolutions",
            "confirmed_resolution_fees",
            "reconciled_descendant_claims",
            "claims_recycled",
        ):
            assert_equal(
                restored_recovery_metrics[field],
                confirmed_recovery_metrics[field],
            )
        assert_equal(len(manual.listunspent(1, 9999999, [manual_address])), 1)

        self.log.info("An injected RPC broadcast exception quarantines the persisted claim")
        fault_args = [*self.base_args, "-qqshadowpowbroadcastthrow=1", f"-mocktime={self.mock_time}"]
        self.restart_node(0, extra_args=fault_args)
        node = self.nodes[0]
        node.setmocktime(self.mock_time)
        manual = self._load_wallet(MANUAL_WALLET)
        builtin = self._load_wallet(BUILTIN_WALLET)
        fault = self._load_wallet(FAULT_WALLET)
        assert manual.gettransaction(first_txid)["confirmations"] > 0
        assert manual.gettransaction(resolution_txid)["confirmations"] < 0
        assert manual.gettransaction(second_claim_txid)["confirmations"] < 0
        assert manual.gettransaction(second_resolution_txid)["confirmations"] > 0
        self._assert_claim_inventory(
            manual, raw=1, actionable=0, resolved=1, indeterminate=0, components=1
        )

        fault_payout = fault.getnewquantumaddress("fault-payout")["address"]
        before_fault = self._quarantined_claim_txids(fault)
        assert_raises_rpc_error(
            -4,
            "PoW Claim transaction broadcast raised an exception: injected Gold Rush PoW broadcast exception",
            fault.sendshadowpowclaim,
            fault_address,
            fault_payout,
            500000,
        )
        first_fault_txid = self._wait_for_new_quarantined_claim(fault, before_fault)
        assert first_fault_txid not in node.getrawmempool()
        assert_equal(self._is_abandoned(fault, first_fault_txid), False)
        assert_equal(len(fault.listunspent(1, 9999999, [fault_address])), 0)
        self._assert_generic_abandon_rejected(fault, first_fault_txid)

        self.log.info("The built-in miner exact-relays its persisted claim after a broadcast exception")
        before_builtin_fault = self._claim_txids(builtin)
        started = builtin.setpowmining(True, 1, 100, True)
        assert started["created_payout_key"]
        try:
            self.wait_until(
                lambda: len(self._claim_txids(builtin) - before_builtin_fault) == 1,
                timeout=180,
            )
            builtin_fault_txid = next(
                iter(self._claim_txids(builtin) - before_builtin_fault)
            )
            self.wait_until(
                lambda: builtin_fault_txid in node.getrawmempool(), timeout=20
            )
        finally:
            builtin.setpowmining(False)
        # The first relay throws after the exact bytes are persisted. The
        # worker re-enters the typed gate and relays those same bytes; it must
        # not grind a second proof or consume another fee input.
        assert_equal(builtin.getpowmininginfo()["claims_submitted"], 0)
        assert builtin_fault_txid in node.getrawmempool()
        assert_equal(
            self._claim_txids(builtin) - before_builtin_fault,
            {builtin_fault_txid},
        )
        assert_equal(self._is_abandoned(builtin, builtin_fault_txid), False)
        assert_equal(len(builtin.listunspent(1, 9999999, [builtin_address])), 0)
        self._assert_generic_abandon_rejected(builtin, builtin_fault_txid)
        assert_equal(len(builtin.listunspent(1, 9999999, [builtin_address])), 0)

        self.log.info("Quarantine survives restart and does not reactivate a persisted/reserved exact-input claim")
        self.restart_node(0, extra_args=[
            *self.base_args,
            "-walletbroadcast=0",
            f"-mocktime={self.mock_time}",
        ])
        node = self.nodes[0]
        node.setmocktime(self.mock_time)
        fault = self._load_wallet(FAULT_WALLET)
        self._assert_generic_abandon_rejected(fault, first_fault_txid)
        assert_equal(len(fault.listunspent(1, 9999999, [fault_address])), 0)

        self.log.info("A disabled wallet broadcaster retains exact commit-authorized resolution bytes")
        # Advance beyond the failed QQP2 claim's intended height so its
        # pinned-tip classification is eligible for the explicit conflict
        # resolver. -walletbroadcast=0 is a real, deterministic relay-failure
        # path: persistence and consent succeed, while wallet relay refuses.
        self.generateblock(node, output=funding_address, transactions=[])
        node.syncwithvalidationinterfacequeue()
        failed_relay_preview = fault.resolveallshadowpowclaims()
        assert_equal(failed_relay_preview["actionable_components"], 1)
        assert_equal(failed_relay_preview["refused_components"], 0)
        assert_equal(
            failed_relay_preview["actions"][0]["claim_txids"],
            [first_fault_txid],
        )
        failed_relay = fault.resolveallshadowpowclaims({
            "action": "commit_and_broadcast",
            "expected_plan_id": failed_relay_preview["plan_id"],
            "acknowledge_fee_and_conflict_risk": True,
        })
        assert_equal(failed_relay["success"], False)
        assert_equal(failed_relay["durable_state_changed"], True)
        assert_equal(failed_relay["durable_state_ambiguous"], False)
        assert_equal(failed_relay["signed_and_persisted"], 1)
        assert_equal(failed_relay["relay_authority_granted"], 1)
        assert_equal(failed_relay["broadcast"], 0)
        assert_equal(failed_relay["already_in_mempool"], 0)
        assert "signed resolution was retained but relay failed" in failed_relay["error"]
        failed_relay_action = failed_relay["actions"][0]
        assert_equal(failed_relay_action["status"], "signed_and_persisted")
        failed_resolution_txid = failed_relay_action["resolution_txid"]
        failed_resolution_hex = failed_relay_action["hex"]
        assert_equal(fault.gettransaction(failed_resolution_txid)["hex"], failed_resolution_hex)
        assert failed_resolution_txid not in node.getrawmempool()
        retained = fault.getpowclaimrecoveryinfo(True)
        retained_resolution = next(
            graph_node
            for component in retained["component_details"]
            for graph_node in component["nodes"]
            if graph_node["txid"] == failed_resolution_txid
        )
        assert_equal(retained_resolution["kind"], "managed_resolution")
        assert_equal(retained_resolution["resolution_relay_authorized"], True)
        assert_equal(retained["pending_manual_resolutions"], 1)

        self.log.info("Restart retries the identical commit-authorized resolution bytes")
        self.restart_node(0, extra_args=[*self.base_args, f"-mocktime={self.mock_time}"])
        node = self.nodes[0]
        node.setmocktime(self.mock_time)
        fault = self._load_wallet(FAULT_WALLET)
        assert_equal(fault.gettransaction(failed_resolution_txid)["hex"], failed_resolution_hex)
        restarted_recovery = fault.getpowclaimrecoveryinfo(True)
        restarted_resolution = next(
            graph_node
            for component in restarted_recovery["component_details"]
            for graph_node in component["nodes"]
            if graph_node["txid"] == failed_resolution_txid
        )
        assert_equal(restarted_resolution["kind"], "managed_resolution")
        assert_equal(restarted_resolution["resolution_relay_authorized"], True)
        if failed_resolution_txid not in node.getrawmempool():
            node.mockscheduler(61)
        self.wait_until(
            lambda: failed_resolution_txid in node.getrawmempool(), timeout=30
        )
        assert_equal(node.getrawtransaction(failed_resolution_txid), failed_resolution_hex)
        assert_equal(fault.gettransaction(failed_resolution_txid)["hex"], failed_resolution_hex)
        assert_equal(fault.getpowclaimrecoveryinfo()["pending_manual_resolutions"], 1)

        self.log.info("A stale QQP2 claim refreshes on the same anchor while the next work remains QQP2")
        activation_height = 501
        # Leave enough room for the original proof to become ineligible and
        # for three further worker-observed tip changes before QQP3 activates.
        pre_boundary_tip = activation_height - 40
        assert node.getblockcount() < pre_boundary_tip
        while node.getblockcount() < pre_boundary_tip:
            self.generateblock(node, output=funding_address, transactions=[])
        assert_equal(node.getblockcount(), pre_boundary_tip)
        assert_equal(node.getshadowpowwork()["height"], pre_boundary_tip + 1)
        assert_equal(node.getshadowpowwork()["proof_version"], 2)

        boundary = self._load_wallet(BOUNDARY_WALLET)
        boundary_inputs = [
            {"txid": utxo["txid"], "vout": utxo["vout"]}
            for utxo in boundary.listunspent(1, 9999999, [boundary_address])
        ]
        assert_equal(len(boundary_inputs), 2)
        boundary_payout = boundary.getnewquantumaddress("PoW - Quantum Claim Address")["address"]
        boundary_claim = boundary.sendshadowpowclaim(
            boundary_address, boundary_payout, 500_000
        )
        boundary_claim_txid = boundary_claim["txid"]
        boundary_claim_input = self._claim_input(boundary_claim_txid)
        boundary_raw = node.getrawtransaction(boundary_claim_txid)
        boundary_decoded = node.decoderawtransaction(boundary_raw)
        assert any(
            "51515032" in output["scriptPubKey"]["hex"]
            for output in boundary_decoded["vout"]
        )
        assert boundary_claim_txid in node.getrawmempool()
        node.syncwithvalidationinterfacequeue()
        untouched_boundary_input = next(
            outpoint for outpoint in boundary_inputs if outpoint != boundary_claim_input
        )
        boundary_root_record = next(
            entry
            for entry in boundary.listtransactions("*", 1000, 0, True)
            if entry["txid"] == boundary_claim_txid
        )
        assert_equal(boundary_root_record["qq_shadow_pow_lineage_schema"], "1")
        assert_equal(boundary_root_record["qq_shadow_pow_lineage_root"], boundary_claim_txid)
        assert "qq_shadow_pow_lineage_parent" not in boundary_root_record
        assert_equal(boundary_root_record["qq_shadow_pow_lineage_ordinal"], "0")
        assert_equal(len(boundary_root_record["qq_shadow_pow_lineage_family"]), 64)
        assert "qq_shadow_pow_quarantine" not in boundary_root_record

        # Deliberately omit the QQP2 claim at its intended height and advance
        # only until that proof is ineligible while the next work is also QQP2.
        # This is the direct pre-activation production failure mode rather than
        # a QQP2 carrier being re-evaluated after QQP3 activation.
        rejected = None
        for _ in range(32):
            self.generateblock(node, output=funding_address, transactions=[])
            node.syncwithvalidationinterfacequeue()
            if boundary_claim_txid not in node.getrawmempool():
                candidate = node.testmempoolaccept([boundary_raw])[0]
                if (
                    not candidate["allowed"]
                    and candidate["reject-reason"] == "shadow-proof-invalid"
                ):
                    rejected = candidate
                    break
        assert rejected is not None, "QQP2 proof remained eligible across 32 descendant tips"
        assert node.getblockcount() < activation_height - 1
        assert_equal(node.getshadowpowwork()["proof_version"], 2)
        assert_equal(
            [
                {"txid": utxo["txid"], "vout": utxo["vout"]}
                for utxo in boundary.listunspent(
                    1, 9999999, [boundary_address]
                )
            ],
            [untouched_boundary_input],
        )
        stale_recovery = boundary.getpowclaimrecoveryinfo(True)
        stale_component = next(
            component
            for component in stale_recovery["component_details"]
            if boundary_claim_txid in component["claim_txids"]
        )
        stale_node = next(
            graph_node
            for graph_node in stale_component["nodes"]
            if graph_node["txid"] == boundary_claim_txid
        )
        assert_equal(stale_component["classification"], "current_branch_ineligible")
        assert_equal(
            {
                "txid": stale_component["anchor"]["txid"],
                "vout": stale_component["anchor"]["vout"],
            },
            boundary_claim_input,
        )
        assert_equal(stale_component["anchor_authenticated"], True)
        assert_equal(stale_component["anchor_unspent"], True)
        assert_equal(stale_component["all_claims_quarantined"], True)
        assert_equal(stale_node["disposition"], "unbound_proof_may_revalidate")
        assert_equal(stale_node["proof_version"], 2)
        assert_equal(stale_node["authored_tip_active_branch_bound"], True)
        assert_equal(stale_node["in_mempool"], False)
        assert_equal(stale_node["quarantined"], True)
        boundary_recovery_before = boundary.getpowclaimrecoveryinfo()
        assert_equal(boundary_recovery_before["pending_manual_resolutions"], 0)
        assert_equal(boundary_recovery_before["pending_automatic_resolutions"], 0)
        assert_equal(boundary_recovery_before["confirmed_manual_resolutions"], 0)
        assert_equal(boundary_recovery_before["confirmed_automatic_resolutions"], 0)
        assert_equal(boundary_recovery_before["confirmed_resolution_fees"], Decimal("0"))

        # Startup repair must retain the old proof and exact anchor. The other
        # confirmed UTXO remains visible, but the miner must refresh the proof
        # by conflicting on the same anchor instead of paying from that coin.
        self.restart_node(0, extra_args=[*self.base_args, f"-mocktime={self.mock_time}"])
        node = self.nodes[0]
        node.setmocktime(self.mock_time)
        boundary = self._load_wallet(BOUNDARY_WALLET)
        self._assert_generic_abandon_rejected(boundary, boundary_claim_txid)
        remaining_boundary_inputs = boundary.listunspent(1, 9999999, [boundary_address])
        assert_equal(len(remaining_boundary_inputs), 1)
        assert_equal(
            {"txid": remaining_boundary_inputs[0]["txid"], "vout": remaining_boundary_inputs[0]["vout"]},
            untouched_boundary_input,
        )
        before_refresh = self._claim_txids(boundary)
        assert_equal(before_refresh, {boundary_claim_txid})
        boundary_quantum_inventory = boundary.getquantumkeyinventory()
        boundary_quantum_addresses = boundary.listquantumaddresses()
        boundary_root_magic, boundary_target_script, boundary_payout_script = (
            self._claim_scripts(boundary, boundary_claim_txid)
        )
        assert_equal(boundary_root_magic, b"QQP2")
        assert_equal(
            boundary_target_script,
            node.validateaddress(boundary_address)["scriptPubKey"],
        )
        assert_equal(
            boundary_payout_script,
            node.validateaddress(boundary_payout)["scriptPubKey"],
        )

        started = boundary.setpowmining(True, 1, 100)
        assert_equal(started["created_payout_key"], False)
        assert_equal(started["payout_address"], "")
        try:
            self.wait_until(
                lambda: len(self._claim_txids(boundary) - before_refresh) == 1,
                timeout=180,
            )
            refreshed_claim_txid = next(iter(self._claim_txids(boundary) - before_refresh))
            info = boundary.getpowmininginfo()
            assert_equal(info["claims_submitted"], 1)
            assert_equal(info["mining_gate_action"], "wait_for_live")
            assert_equal(info["mining_gate_family_claims"], 2)
            assert_equal(info["mining_gate_live_claims"], 1)
            assert_equal(len(boundary.listunspent(1, 9999999, [boundary_address])), 1)
        finally:
            boundary.setpowmining(False)
        refreshed_raw = node.getrawtransaction(refreshed_claim_txid)
        refreshed_decoded = node.decoderawtransaction(refreshed_raw)
        assert_equal(self._claim_input(refreshed_claim_txid), boundary_claim_input)
        refreshed_magic, refreshed_target_script, refreshed_payout_script = (
            self._claim_scripts(boundary, refreshed_claim_txid)
        )
        assert_equal(refreshed_magic, b"QQP2")
        assert_equal(refreshed_target_script, boundary_target_script)
        assert_equal(refreshed_payout_script, boundary_payout_script)
        assert_equal(boundary.getquantumkeyinventory(), boundary_quantum_inventory)
        assert_equal(boundary.listquantumaddresses(), boundary_quantum_addresses)
        assert any(
            "51515032" in output["scriptPubKey"]["hex"]
            for output in refreshed_decoded["vout"]
        )
        assert_equal(node.getshadowpowwork()["proof_version"], 2)
        assert refreshed_claim_txid in node.getrawmempool()
        assert boundary_claim_txid not in node.getrawmempool()
        node.syncwithvalidationinterfacequeue()
        assert_equal(
            [
                {"txid": utxo["txid"], "vout": utxo["vout"]}
                for utxo in boundary.listunspent(1, 9999999, [boundary_address])
            ],
            [untouched_boundary_input],
        )

        refresh_record = next(
            entry
            for entry in boundary.listtransactions("*", 1000, 0, True)
            if entry["txid"] == refreshed_claim_txid
        )
        assert_equal(refresh_record["qq_shadow_pow_lineage_schema"], "1")
        assert_equal(refresh_record["qq_shadow_pow_lineage_root"], boundary_claim_txid)
        assert_equal(refresh_record["qq_shadow_pow_lineage_parent"], boundary_claim_txid)
        assert_equal(refresh_record["qq_shadow_pow_lineage_ordinal"], "1")
        assert_equal(len(refresh_record["qq_shadow_pow_lineage_family"]), 64)
        assert "qq_shadow_pow_quarantine" not in refresh_record
        assert_equal(
            refresh_record["qq_shadow_pow_lineage_family"],
            boundary_root_record["qq_shadow_pow_lineage_family"],
        )
        refreshed_recovery = boundary.getpowclaimrecoveryinfo(True)
        refreshed_component = next(
            component
            for component in refreshed_recovery["component_details"]
            if refreshed_claim_txid in component["claim_txids"]
        )
        assert_equal(
            set(refreshed_component["claim_txids"]),
            {boundary_claim_txid, refreshed_claim_txid},
        )
        assert_equal(refreshed_component["descendant_claims"], 0)
        assert_equal(
            {
                "txid": refreshed_component["anchor"]["txid"],
                "vout": refreshed_component["anchor"]["vout"],
            },
            boundary_claim_input,
        )
        assert_equal(refreshed_component["anchor_authenticated"], True)
        assert_equal(refreshed_component["anchor_unspent"], True)
        assert_equal(len(refreshed_component["generation_fingerprint"]), 64)
        assert_equal(refreshed_component["ordinary_or_mixed_txids"], [])
        assert_equal(refreshed_component["resolution_txids"], [])
        assert_equal(
            boundary.getpowclaimrecoveryinfo()["confirmed_resolution_fees"],
            Decimal("0"),
        )
        assert not any(
            entry.get("qq_shadow_pow_cleanup_for")
            in {boundary_claim_txid, refreshed_claim_txid}
            for entry in boundary.listtransactions("*", 1000, 0, True)
        )

        self.log.info("The QQP2 worker remains live across three further tips with retained quarantine history")
        observed_continuation_tips = set()
        boundary.setpowmining(True, 1, 100)
        try:
            for _ in range(3):
                previous_tip = node.getbestblockhash()
                claims_before_tip = self._claim_txids(boundary)
                submitted_before_tip = boundary.getpowmininginfo()["claims_submitted"]
                self.generateblock(node, output=funding_address, transactions=[])
                node.syncwithvalidationinterfacequeue()
                current_tip = node.getbestblockhash()
                assert current_tip != previous_tip
                observed_continuation_tips.add(current_tip)
                assert_equal(node.getshadowpowwork()["proof_version"], 2)

                def coherent_live_family():
                    info = boundary.getpowmininginfo()
                    if (
                        info["claim_inventory_tip"] != current_tip
                        or not info["mining_gate_coherent"]
                        or info["mining_gate_database_ambiguous"]
                        or info["mining_gate_unsafe_claims"] != 0
                        or info["mining_gate_unsafe_components"] != 0
                        or info["state"] == "claim_quarantined"
                    ):
                        return False
                    recovery = boundary.getpowclaimrecoveryinfo(True)
                    component = next(
                        (
                            item
                            for item in recovery["component_details"]
                            if boundary_claim_txid in item["claim_txids"]
                        ),
                        None,
                    )
                    if component is None:
                        return False
                    live = [
                        graph_node
                        for graph_node in component["nodes"]
                        if graph_node["kind"] == "claim" and graph_node["in_mempool"]
                    ]
                    return len(live) == 1

                self.wait_until(coherent_live_family, timeout=180)
                tip_info = boundary.getpowmininginfo()
                assert tip_info["state"] != "claim_quarantined"
                assert_equal(
                    tip_info["mining_gate_action"], "wait_for_live"
                )
                assert tip_info["raw_quarantined_claims"] > 0
                assert_equal(tip_info["mining_gate_coherent"], True)
                assert_equal(tip_info["mining_gate_database_ambiguous"], False)
                assert_equal(tip_info["mining_gate_unsafe_claims"], 0)
                assert_equal(tip_info["mining_gate_unsafe_components"], 0)
                assert_equal(len(tip_info["mining_gate_candidate_state_fingerprint"]), 64)

                tip_recovery = boundary.getpowclaimrecoveryinfo(True)
                tip_component = next(
                    component
                    for component in tip_recovery["component_details"]
                    if boundary_claim_txid in component["claim_txids"]
                )
                assert_equal(
                    {
                        "txid": tip_component["anchor"]["txid"],
                        "vout": tip_component["anchor"]["vout"],
                    },
                    boundary_claim_input,
                )
                assert_equal(tip_component["anchor_authenticated"], True)
                assert_equal(tip_component["anchor_unspent"], True)
                assert_equal(tip_component["ordinary_or_mixed_txids"], [])
                assert_equal(tip_component["resolution_txids"], [])
                live_nodes = [
                    graph_node
                    for graph_node in tip_component["nodes"]
                    if graph_node["kind"] == "claim" and graph_node["in_mempool"]
                ]
                assert_equal(len(live_nodes), 1)
                assert_equal(live_nodes[0]["proof_version"], 2)
                refreshed_claim_txid = live_nodes[0]["txid"]
                refreshed_raw = node.getrawtransaction(refreshed_claim_txid)
                assert_equal(self._claim_input(refreshed_claim_txid), boundary_claim_input)
                assert_equal(
                    [
                        {"txid": utxo["txid"], "vout": utxo["vout"]}
                        for utxo in boundary.listunspent(
                            1, 9999999, [boundary_address]
                        )
                    ],
                    [untouched_boundary_input],
                )

                # Once a coherent live sibling is visible, no second same-tip
                # submission is allowed even though historical quarantine
                # objects remain in the family.
                claims_after_tip = self._claim_txids(boundary)
                assert claims_before_tip <= claims_after_tip
                assert len(claims_after_tip - claims_before_tip) <= 1
                assert_equal(
                    boundary.getpowmininginfo()["claims_submitted"],
                    submitted_before_tip + len(claims_after_tip - claims_before_tip),
                )

            # Stop/join and start a fresh worker on the unchanged tip. The
            # synchronous restart resets its counters and seeds the typed
            # gate; reaching WAIT_FOR_LIVE proves a complete worker pass did
            # not author another same-tip sibling.
            boundary.setpowmining(False)
            assert_equal(self._claim_txids(boundary), claims_after_tip)
            continuation_rows = boundary.listtransactions("*", 1000, 0, True)
            for observed_tip in observed_continuation_tips:
                assert len(
                    {
                        entry["txid"]
                        for entry in continuation_rows
                        if entry.get("qq_shadow_pow_created_tip")
                        == observed_tip
                    }
                ) <= 1
            same_tip_barrier = node.getbestblockhash()
            claims_at_barrier = self._claim_txids(boundary)
            restarted = boundary.setpowmining(True, 1, 100)
            assert_equal(restarted["created_payout_key"], False)
            assert_equal(restarted["payout_address"], "")

            def fresh_worker_waits_for_live():
                info = boundary.getpowmininginfo()
                return (
                    info["enabled"]
                    and info["state"] == "claim_in_flight"
                    and info["mining_gate_action"] == "wait_for_live"
                    and info["claim_inventory_tip"] == same_tip_barrier
                    and info["claims_submitted"] == 0
                )

            self.wait_until(fresh_worker_waits_for_live, timeout=20)
            boundary.setpowmining(False)
            stopped_barrier = boundary.getpowmininginfo()
            assert_equal(stopped_barrier["enabled"], False)
            assert_equal(node.getbestblockhash(), same_tip_barrier)
            assert_equal(self._claim_txids(boundary), claims_at_barrier)
            assert_equal(stopped_barrier["claims_submitted"], 0)
            assert_equal(
                boundary.getquantumkeyinventory(), boundary_quantum_inventory
            )
            assert_equal(
                boundary.listquantumaddresses(), boundary_quantum_addresses
            )
        finally:
            boundary.setpowmining(False)

        continued_recovery = boundary.getpowclaimrecoveryinfo(True)
        continued_component = next(
            component
            for component in continued_recovery["component_details"]
            if boundary_claim_txid in component["claim_txids"]
        )
        assert_equal(
            {
                "txid": continued_component["anchor"]["txid"],
                "vout": continued_component["anchor"]["vout"],
            },
            boundary_claim_input,
        )
        assert_equal(continued_component["resolution_txids"], [])
        assert_equal(continued_recovery["pending_manual_resolutions"], 0)
        assert_equal(continued_recovery["pending_automatic_resolutions"], 0)
        assert_equal(continued_recovery["confirmed_manual_resolutions"], 0)
        assert_equal(continued_recovery["confirmed_automatic_resolutions"], 0)
        assert_equal(continued_recovery["confirmed_resolution_fees"], Decimal("0"))
        lineage_records = sorted(
            (
                entry
                for entry in boundary.listtransactions("*", 1000, 0, True)
                if entry["txid"] in set(continued_component["claim_txids"])
            ),
            key=lambda entry: int(entry["qq_shadow_pow_lineage_ordinal"]),
        )
        assert_equal(
            [int(entry["qq_shadow_pow_lineage_ordinal"]) for entry in lineage_records],
            list(range(len(lineage_records))),
        )
        for ordinal, record in enumerate(lineage_records):
            assert_equal(record["qq_shadow_pow_lineage_schema"], "1")
            assert_equal(record["qq_shadow_pow_lineage_root"], boundary_claim_txid)
            assert_equal(
                record["qq_shadow_pow_lineage_family"],
                boundary_root_record["qq_shadow_pow_lineage_family"],
            )
            if ordinal == 0:
                assert "qq_shadow_pow_lineage_parent" not in record
            else:
                assert_equal(
                    record["qq_shadow_pow_lineage_parent"],
                    lineage_records[ordinal - 1]["txid"],
                )
        assert not any(
            entry.get("qq_shadow_pow_cleanup_for")
            in set(continued_component["claim_txids"])
            for entry in boundary.listtransactions("*", 1000, 0, True)
        )

        self.log.info("The miner promptly relays an eligible absent head on the same tip")
        self.restart_node(
            0,
            extra_args=[
                *self.base_args,
                "-mempoolexpiry=0",
                f"-mocktime={self.mock_time}",
            ],
        )
        node = self.nodes[0]
        node.setmocktime(self.mock_time)
        boundary = self._load_wallet(BOUNDARY_WALLET)
        default_wallet = node.get_wallet_rpc(self.default_wallet_name)
        self.wait_until(lambda: refreshed_claim_txid in node.getrawmempool(), timeout=30)
        assert_equal(node.getrawtransaction(refreshed_claim_txid), refreshed_raw)
        self._advance_past_mempool_entry_time(node, refreshed_claim_txid)
        default_wallet.sendtoaddress(funding_address, Decimal("0.10000000"))
        node.syncwithvalidationinterfacequeue()
        self.wait_until(
            lambda: refreshed_claim_txid not in node.getrawmempool(), timeout=20
        )
        relay_gate = boundary.getpowmininginfo()
        assert_equal(relay_gate["mining_gate_action"], "relay_existing")
        assert_equal(relay_gate["mining_gate_relay_txid"], refreshed_claim_txid)
        assert_equal(relay_gate["mining_gate_unsafe_claims"], 0)
        assert_equal(relay_gate["mining_gate_unsafe_components"], 0)
        absent_recovery = boundary.getpowclaimrecoveryinfo(True)
        absent_head = next(
            graph_node
            for component in absent_recovery["component_details"]
            for graph_node in component["nodes"]
            if graph_node["txid"] == refreshed_claim_txid
        )
        assert_equal(absent_head["in_mempool"], False)
        assert_equal(absent_head["quarantined"], True)

        claims_before_restart_mining = self._claim_txids(boundary)
        boundary.setpowmining(True, 1, 100)
        try:
            self.wait_until(
                lambda: refreshed_claim_txid in node.getrawmempool(), timeout=20
            )
            assert_equal(node.getrawtransaction(refreshed_claim_txid), refreshed_raw)
            self.wait_until(
                lambda: boundary.getpowmininginfo()["state"] == "claim_in_flight",
                timeout=20,
            )
            assert_equal(
                boundary.getpowmininginfo()["mining_gate_action"],
                "wait_for_live",
            )

            # Removing the just-relayed head without changing the chain tip
            # must invalidate the cached WAIT state. The running worker loops
            # back through RELAY_EXISTING and submits the same bytes again.
            same_tip = node.getbestblockhash()
            self._advance_past_mempool_entry_time(node, refreshed_claim_txid)
            with node.wait_for_debug_log(
                [b"Relayed existing eligible Gold Rush PoW claim"], timeout=20
            ):
                default_wallet.sendtoaddress(
                    funding_address, Decimal("0.10000000")
                )
            self.wait_until(
                lambda: refreshed_claim_txid in node.getrawmempool(), timeout=20
            )
            assert_equal(node.getbestblockhash(), same_tip)
            assert_equal(node.getrawtransaction(refreshed_claim_txid), refreshed_raw)
            assert_equal(self._claim_txids(boundary), claims_before_restart_mining)
            assert_equal(boundary.getpowmininginfo()["claims_submitted"], 0)
        finally:
            boundary.setpowmining(False)

        self.log.info("RPC truthfully reports a bounded next-tip relay wait")
        self._advance_past_mempool_entry_time(node, refreshed_claim_txid)
        default_wallet.sendtoaddress(funding_address, Decimal("0.10000000"))
        node.syncwithvalidationinterfacequeue()
        self.wait_until(
            lambda: refreshed_claim_txid not in node.getrawmempool(), timeout=20
        )
        self.restart_node(
            0,
            extra_args=[
                *self.base_args,
                "-mempoolexpiry=0",
                "-walletbroadcast=0",
                f"-mocktime={self.mock_time}",
            ],
        )
        node = self.nodes[0]
        node.setmocktime(self.mock_time)
        boundary = self._load_wallet(BOUNDARY_WALLET)
        assert refreshed_claim_txid not in node.getrawmempool()
        assert_equal(
            boundary.getpowmininginfo()["mining_gate_action"],
            "relay_existing",
        )

        boundary.setpowmining(True, 1, 100)
        try:
            self.wait_until(
                lambda: boundary.getpowmininginfo()["mining_gate_action"]
                == "wait_for_next_tip",
                timeout=20,
            )
            wait_info = boundary.getpowmininginfo()
            assert_equal(
                wait_info["mining_gate_action"], "wait_for_next_tip"
            )
            assert_equal(wait_info["state"], "claim_in_flight")
            assert_equal(wait_info["mining_gate_can_submit"], False)
            assert_equal(wait_info["mining_gate_coherent"], True)
            assert_equal(wait_info["mining_gate_database_ambiguous"], False)
            # Every safety field remains snapshot-derived. Deferring the exact
            # family clears its actionable relay identity for this snapshot;
            # the durable lineage head and recovery inventory remain auditable.
            assert_equal(wait_info["mining_gate_relay_txid"], ZERO_HASH)
            assert_equal(wait_info["mining_gate_unsafe_claims"], 0)
            assert_equal(wait_info["mining_gate_unsafe_components"], 0)
            waiting_tip = node.getbestblockhash()
            assert_equal(wait_info["claim_inventory_tip"], waiting_tip)
            assert_equal(wait_info["claim_inventory_wallet_tip_matches"], True)
            assert_equal(
                wait_info["mining_gate_lineage_head_txid"], refreshed_claim_txid
            )
            assert_equal(
                len(wait_info["mining_gate_candidate_state_fingerprint"]), 64
            )
            claims_at_wait = self._claim_txids(boundary)
            submitted_at_wait = wait_info["claims_submitted"]

            # Advance the tip while the worker remains enabled. A still-visible
            # wait_for_next_tip must be a newly coherent snapshot on the new
            # tip; the cached old-tip wait is not allowed to survive.
            with node.wait_for_debug_log(
                [
                    b"retained a claim after relay failure",
                    b"persisted without relay",
                ],
                timeout=180,
            ):
                self.generateblock(
                    node, output=funding_address, transactions=[]
                )
                node.syncwithvalidationinterfacequeue()
            advanced_tip = node.getbestblockhash()
            assert advanced_tip != waiting_tip

            def next_tip_family_is_rebound():
                info = boundary.getpowmininginfo()
                new_claims = self._claim_txids(boundary) - claims_at_wait
                return (
                    len(new_claims) == 1
                    and info["claim_inventory_tip"] == advanced_tip
                    and info["claim_inventory_wallet_tip_matches"]
                    and info["mining_gate_coherent"]
                    and not info["mining_gate_database_ambiguous"]
                    and info["mining_gate_unsafe_claims"] == 0
                    and info["mining_gate_unsafe_components"] == 0
                    and info["mining_gate_action"]
                    in {"relay_existing", "wait_for_next_tip"}
                    and info["mining_gate_lineage_head_txid"] in new_claims
                )

            self.wait_until(next_tip_family_is_rebound, timeout=180)
            advanced_wait = boundary.getpowmininginfo()
            assert_equal(advanced_wait["claim_inventory_tip"], advanced_tip)
            assert advanced_wait["state"] != "claim_quarantined"
            assert advanced_wait["mining_gate_action"] in {
                "relay_existing",
                "wait_for_next_tip",
            }
            assert_equal(
                advanced_wait["claims_submitted"], submitted_at_wait
            )
            pending_claims = self._claim_txids(boundary) - claims_at_wait
            assert_equal(len(pending_claims), 1)
            refreshed_claim_txid = advanced_wait["mining_gate_lineage_head_txid"]
            assert_equal(pending_claims, {refreshed_claim_txid})
            assert refreshed_claim_txid not in node.getrawmempool()
            refreshed_raw = boundary.gettransaction(refreshed_claim_txid)["hex"]
            advanced_decoded = node.decoderawtransaction(refreshed_raw)
            assert_equal(
                {
                    "txid": advanced_decoded["vin"][0]["txid"],
                    "vout": advanced_decoded["vin"][0]["vout"],
                },
                boundary_claim_input,
            )
            pending_record = next(
                entry
                for entry in boundary.listtransactions("*", 1000, 0, True)
                if entry["txid"] == refreshed_claim_txid
            )
            assert_equal(pending_record["qq_shadow_pow_quarantine"], "1")
            pending_recovery = boundary.getpowclaimrecoveryinfo(True)
            pending_component = next(
                component
                for component in pending_recovery["component_details"]
                if refreshed_claim_txid in component["claim_txids"]
            )
            pending_node = next(
                graph_node
                for graph_node in pending_component["nodes"]
                if graph_node["txid"] == refreshed_claim_txid
            )
            assert_equal(pending_node["in_mempool"], False)
            assert_equal(pending_node["quarantined"], True)
            assert_equal(pending_node["abandoned"], False)
            assert_equal(pending_component["resolution_txids"], [])
            assert_equal(pending_component["ordinary_or_mixed_txids"], [])
            assert_equal(
                pending_recovery["confirmed_resolution_fees"], Decimal("0")
            )
            assert_equal(
                [
                    {"txid": utxo["txid"], "vout": utxo["vout"]}
                    for utxo in boundary.listunspent(
                        1, 9999999, [boundary_address]
                    )
                ],
                [untouched_boundary_input],
            )
            assert not any(
                entry.get("qq_shadow_pow_cleanup_for")
                in self._claim_txids(boundary)
                for entry in boundary.listtransactions("*", 1000, 0, True)
            )
            claims_before_restart_mining = self._claim_txids(boundary)
        finally:
            boundary.setpowmining(False)

        # Disabling removes worker telemetry but does not erase the wallet's
        # exact-snapshot relay defer. Repeated stop/start must not bypass the
        # bounded backoff while tip, wallet generation, and candidate state
        # remain unchanged.
        stopped_wait = boundary.getpowmininginfo()
        assert_equal(stopped_wait["mining_gate_action"], "wait_for_next_tip")
        assert_equal(stopped_wait["mining_gate_relay_txid"], ZERO_HASH)
        assert_equal(stopped_wait["claim_inventory_tip"], advanced_tip)

        self.log.info("Restart retains the exact current family head without creating another sibling")
        self.restart_node(0, extra_args=[*self.base_args, f"-mocktime={self.mock_time}"])
        node = self.nodes[0]
        node.setmocktime(self.mock_time)
        boundary = self._load_wallet(BOUNDARY_WALLET)
        self.wait_until(lambda: refreshed_claim_txid in node.getrawmempool(), timeout=30)
        node.syncwithvalidationinterfacequeue()
        assert_equal(node.getrawtransaction(refreshed_claim_txid), refreshed_raw)
        restarted_head = next(
            graph_node
            for component in boundary.getpowclaimrecoveryinfo(True)[
                "component_details"
            ]
            for graph_node in component["nodes"]
            if graph_node["txid"] == refreshed_claim_txid
        )
        assert_equal(restarted_head["in_mempool"], True)
        assert_equal(restarted_head["quarantined"], False)
        restarted_head_record = next(
            entry
            for entry in boundary.listtransactions("*", 1000, 0, True)
            if entry["txid"] == refreshed_claim_txid
        )
        assert "qq_shadow_pow_quarantine" not in restarted_head_record
        assert_equal(
            boundary.getpowmininginfo()["mining_gate_action"], "wait_for_live"
        )
        boundary.setpowmining(True, 1, 100)
        try:
            self.wait_until(
                lambda: boundary.getpowmininginfo()["state"] == "claim_in_flight",
                timeout=20,
            )
            time.sleep(2)
            assert_equal(self._claim_txids(boundary), claims_before_restart_mining)
        finally:
            boundary.setpowmining(False)

        final_live_recovery = boundary.getpowclaimrecoveryinfo(True)
        final_live_component = next(
            component
            for component in final_live_recovery["component_details"]
            if refreshed_claim_txid in component["claim_txids"]
        )
        final_family_claims = set(final_live_component["claim_txids"])
        assert boundary_claim_txid in final_family_claims
        assert refreshed_claim_txid in final_family_claims
        assert_equal(
            sum(
                graph_node["in_mempool"]
                for graph_node in final_live_component["nodes"]
                if graph_node["kind"] == "claim"
            ),
            1,
        )

        self.log.info("One family-head confirmation resolves its siblings and preserves the other UTXO")
        refreshed_block = self.generateblock(
            node, output=funding_address, transactions=[refreshed_claim_txid]
        )["hash"]
        node.syncwithvalidationinterfacequeue()
        assert_equal(boundary.gettransaction(refreshed_claim_txid)["confirmations"], 1)
        for sibling_txid in final_family_claims - {refreshed_claim_txid}:
            assert boundary.gettransaction(sibling_txid)["confirmations"] < 0
        confirmed_boundary_outpoints = {
            (utxo["txid"], utxo["vout"])
            for utxo in boundary.listunspent(1, 9999999, [boundary_address])
        }
        assert_equal(
            confirmed_boundary_outpoints,
            {
                (untouched_boundary_input["txid"], untouched_boundary_input["vout"]),
                (refreshed_claim_txid, 0),
            },
        )
        self._assert_claim_inventory(
            boundary,
            raw=len(final_family_claims) - 1,
            actionable=0,
            resolved=len(final_family_claims) - 1,
            indeterminate=0,
            components=1,
        )
        boundary_recovery_confirmed = boundary.getpowclaimrecoveryinfo()
        for field in (
            "pending_manual_resolutions",
            "pending_automatic_resolutions",
            "confirmed_manual_resolutions",
            "confirmed_automatic_resolutions",
            "confirmed_resolution_fees",
            "automatic_fee_exposure_in_window",
        ):
            assert_equal(
                boundary_recovery_confirmed[field], boundary_recovery_before[field]
            )

        self.log.info("A one-block reorg reopens only the same-anchor live head across restart")
        node.invalidateblock(refreshed_block)
        self.wait_until(lambda: node.getbestblockhash() != refreshed_block, timeout=20)
        node.syncwithvalidationinterfacequeue()
        self.wait_until(lambda: refreshed_claim_txid in node.getrawmempool(), timeout=30)
        assert_equal(
            [
                {"txid": utxo["txid"], "vout": utxo["vout"]}
                for utxo in boundary.listunspent(1, 9999999, [boundary_address])
            ],
            [untouched_boundary_input],
        )
        claims_before_reorg_restart = self._claim_txids(boundary)
        self.restart_node(0, extra_args=[*self.base_args, f"-mocktime={self.mock_time}"])
        node = self.nodes[0]
        node.setmocktime(self.mock_time)
        boundary = self._load_wallet(BOUNDARY_WALLET)
        self.wait_until(lambda: refreshed_claim_txid in node.getrawmempool(), timeout=30)
        boundary.setpowmining(True, 1, 100)
        try:
            self.wait_until(
                lambda: boundary.getpowmininginfo()["state"] == "claim_in_flight",
                timeout=20,
            )
            time.sleep(2)
            assert_equal(self._claim_txids(boundary), claims_before_reorg_restart)
        finally:
            boundary.setpowmining(False)

        node.reconsiderblock(refreshed_block)
        self.wait_until(lambda: node.getbestblockhash() == refreshed_block, timeout=20)
        node.syncwithvalidationinterfacequeue()
        assert boundary.gettransaction(refreshed_claim_txid)["confirmations"] > 0
        assert boundary.gettransaction(boundary_claim_txid)["confirmations"] < 0
        assert_equal(
            {
                (utxo["txid"], utxo["vout"])
                for utxo in boundary.listunspent(1, 9999999, [boundary_address])
            },
            {
                (untouched_boundary_input["txid"], untouched_boundary_input["vout"]),
                (refreshed_claim_txid, 0),
            },
        )
        assert_equal(
            boundary.getpowclaimrecoveryinfo()["confirmed_resolution_fees"],
            Decimal("0"),
        )

        self.log.info("A separate QQP2 family refreshes on the same anchor across QQP3 activation")
        cross_boundary = self._load_wallet(CROSS_BOUNDARY_WALLET)
        cross_boundary_inputs = [
            {"txid": utxo["txid"], "vout": utxo["vout"]}
            for utxo in cross_boundary.listunspent(
                1, 9999999, [cross_boundary_address]
            )
        ]
        assert_equal(len(cross_boundary_inputs), 2)
        cross_boundary_tip = activation_height - 2
        assert node.getblockcount() < cross_boundary_tip
        while node.getblockcount() < cross_boundary_tip:
            self.generateblock(node, output=funding_address, transactions=[])
        assert_equal(node.getshadowpowwork()["height"], activation_height - 1)
        assert_equal(node.getshadowpowwork()["proof_version"], 2)

        cross_payout = cross_boundary.getnewquantumaddress(
            "PoW - Quantum Claim Address"
        )["address"]
        cross_root = cross_boundary.sendshadowpowclaim(
            cross_boundary_address, cross_payout, 500_000
        )
        cross_root_txid = cross_root["txid"]
        cross_anchor = self._claim_input(cross_root_txid)
        cross_root_raw = node.getrawtransaction(cross_root_txid)
        assert any(
            "51515032" in output["scriptPubKey"]["hex"]
            for output in node.decoderawtransaction(cross_root_raw)["vout"]
        )
        assert cross_root_txid in node.getrawmempool()
        node.syncwithvalidationinterfacequeue()
        untouched_cross_input = next(
            outpoint
            for outpoint in cross_boundary_inputs
            if outpoint != cross_anchor
        )
        cross_root_record = next(
            entry
            for entry in cross_boundary.listtransactions("*", 1000, 0, True)
            if entry["txid"] == cross_root_txid
        )
        assert_equal(cross_root_record["qq_shadow_pow_lineage_schema"], "1")
        assert_equal(
            cross_root_record["qq_shadow_pow_lineage_root"], cross_root_txid
        )
        assert "qq_shadow_pow_lineage_parent" not in cross_root_record
        assert_equal(cross_root_record["qq_shadow_pow_lineage_ordinal"], "0")
        assert "qq_shadow_pow_quarantine" not in cross_root_record

        cross_rejected = None
        for _ in range(32):
            self.generateblock(node, output=funding_address, transactions=[])
            node.syncwithvalidationinterfacequeue()
            if cross_root_txid not in node.getrawmempool():
                candidate = node.testmempoolaccept([cross_root_raw])[0]
                if (
                    not candidate["allowed"]
                    and candidate["reject-reason"] == "shadow-proof-invalid"
                ):
                    cross_rejected = candidate
                    break
        assert cross_rejected is not None, (
            "QQP2 proof remained eligible after QQP3 activation"
        )
        assert node.getblockcount() >= activation_height - 1
        assert_equal(node.getshadowpowwork()["proof_version"], 3)
        assert_equal(
            [
                {"txid": utxo["txid"], "vout": utxo["vout"]}
                for utxo in cross_boundary.listunspent(
                    1, 9999999, [cross_boundary_address]
                )
            ],
            [untouched_cross_input],
        )
        cross_stale = cross_boundary.getpowclaimrecoveryinfo(True)
        cross_component = next(
            component
            for component in cross_stale["component_details"]
            if cross_root_txid in component["claim_txids"]
        )
        cross_root_node = next(
            graph_node
            for graph_node in cross_component["nodes"]
            if graph_node["txid"] == cross_root_txid
        )
        assert_equal(cross_root_node["lineage_metadata_present"], True)
        assert_equal(cross_root_node["lineage_metadata_valid"], True)
        assert_equal(
            cross_component["classification"],
            "current_branch_ineligible",
        )
        assert_equal(cross_root_node["in_mempool"], False)
        assert_equal(cross_root_node["quarantined"], True)
        assert_equal(
            cross_root_node["disposition"],
            "unbound_proof_may_revalidate",
        )
        assert_equal(cross_root_node["lineage_root_txid"], cross_root_txid)
        assert_equal(cross_root_node["lineage_parent_txid"], ZERO_HASH)
        assert_equal(cross_root_node["lineage_ordinal"], 0)
        assert_equal(
            cross_root_node["lineage_family_fingerprint"],
            cross_component["generation_fingerprint"],
        )

        cross_before_refresh = self._claim_txids(cross_boundary)
        cross_quantum_inventory = cross_boundary.getquantumkeyinventory()
        cross_quantum_addresses = cross_boundary.listquantumaddresses()
        cross_root_magic, cross_target_script, cross_payout_script = (
            self._claim_scripts(cross_boundary, cross_root_txid)
        )
        assert_equal(cross_root_magic, b"QQP2")
        assert_equal(
            cross_target_script,
            node.validateaddress(cross_boundary_address)["scriptPubKey"],
        )
        assert_equal(
            cross_payout_script,
            node.validateaddress(cross_payout)["scriptPubKey"],
        )
        started = cross_boundary.setpowmining(True, 1, 100)
        assert_equal(started["created_payout_key"], False)
        assert_equal(started["payout_address"], "")
        try:
            self.wait_until(
                lambda: len(
                    self._claim_txids(cross_boundary) - cross_before_refresh
                )
                == 1,
                timeout=180,
            )
            cross_head_txid = next(
                iter(self._claim_txids(cross_boundary) - cross_before_refresh)
            )
            cross_gate = cross_boundary.getpowmininginfo()
            assert_equal(cross_gate["mining_gate_coherent"], True)
            assert_equal(cross_gate["mining_gate_database_ambiguous"], False)
            assert_equal(cross_gate["mining_gate_unsafe_claims"], 0)
            assert_equal(cross_gate["mining_gate_unsafe_components"], 0)
            assert_equal(cross_gate["mining_gate_action"], "wait_for_live")
            assert_equal(cross_gate["claims_submitted"], 1)
        finally:
            cross_boundary.setpowmining(False)

        assert_equal(self._claim_input(cross_head_txid), cross_anchor)
        cross_head_raw = node.getrawtransaction(cross_head_txid)
        cross_head_magic, cross_head_target_script, cross_head_payout_script = (
            self._claim_scripts(cross_boundary, cross_head_txid)
        )
        assert_equal(cross_head_magic, b"QQP3")
        assert_equal(cross_head_target_script, cross_target_script)
        assert_equal(cross_head_payout_script, cross_payout_script)
        assert_equal(
            cross_boundary.getquantumkeyinventory(), cross_quantum_inventory
        )
        assert_equal(
            cross_boundary.listquantumaddresses(), cross_quantum_addresses
        )
        assert any(
            "51515033" in output["scriptPubKey"]["hex"]
            for output in node.decoderawtransaction(cross_head_raw)["vout"]
        )
        assert cross_head_txid in node.getrawmempool()
        node.syncwithvalidationinterfacequeue()
        cross_head_record = next(
            entry
            for entry in cross_boundary.listtransactions("*", 1000, 0, True)
            if entry["txid"] == cross_head_txid
        )
        assert_equal(cross_head_record["qq_shadow_pow_lineage_schema"], "1")
        assert_equal(
            cross_head_record["qq_shadow_pow_lineage_root"], cross_root_txid
        )
        assert_equal(
            cross_head_record["qq_shadow_pow_lineage_parent"], cross_root_txid
        )
        assert_equal(cross_head_record["qq_shadow_pow_lineage_ordinal"], "1")
        assert_equal(
            cross_head_record["qq_shadow_pow_lineage_family"],
            cross_root_record["qq_shadow_pow_lineage_family"],
        )
        assert "qq_shadow_pow_quarantine" not in cross_head_record
        cross_live = cross_boundary.getpowclaimrecoveryinfo(True)
        cross_component = next(
            component
            for component in cross_live["component_details"]
            if cross_head_txid in component["claim_txids"]
        )
        assert_equal(
            set(cross_component["claim_txids"]),
            {cross_root_txid, cross_head_txid},
        )
        cross_head_node = next(
            graph_node
            for graph_node in cross_component["nodes"]
            if graph_node["txid"] == cross_head_txid
        )
        assert_equal(cross_head_node["lineage_metadata_present"], True)
        assert_equal(cross_head_node["lineage_metadata_valid"], True)
        assert_equal(cross_head_node["lineage_root_txid"], cross_root_txid)
        assert_equal(cross_head_node["lineage_parent_txid"], cross_root_txid)
        assert_equal(cross_head_node["lineage_ordinal"], 1)
        assert_equal(
            cross_head_node["lineage_family_fingerprint"],
            cross_component["generation_fingerprint"],
        )
        assert_equal(cross_component["resolution_txids"], [])
        assert_equal(cross_component["ordinary_or_mixed_txids"], [])
        assert_equal(
            [
                {"txid": utxo["txid"], "vout": utxo["vout"]}
                for utxo in cross_boundary.listunspent(
                    1, 9999999, [cross_boundary_address]
                )
            ],
            [untouched_cross_input],
        )
        assert_equal(
            cross_boundary.getpowclaimrecoveryinfo()[
                "confirmed_resolution_fees"
            ],
            Decimal("0"),
        )
        assert not any(
            entry.get("qq_shadow_pow_cleanup_for")
            in {cross_root_txid, cross_head_txid}
            for entry in cross_boundary.listtransactions("*", 1000, 0, True)
        )

        self.log.info("Recovery policy, exact bytes, graph, and metrics survive rescan and reindex")
        manual = self._load_wallet(MANUAL_WALLET)
        policy = self._load_wallet(POLICY_WALLET)
        fault = self._load_wallet(FAULT_WALLET)
        boundary = self._load_wallet(BOUNDARY_WALLET)
        cross_boundary = self._load_wallet(CROSS_BOUNDARY_WALLET)
        if failed_resolution_txid not in node.getrawmempool():
            node.mockscheduler(61)
            self.wait_until(
                lambda: failed_resolution_txid in node.getrawmempool(),
                timeout=30,
            )
            node.syncwithvalidationinterfacequeue()
        assert_equal(fault.gettransaction(failed_resolution_txid)["hex"], failed_resolution_hex)
        expected_recovery = {
            MANUAL_WALLET: self._recovery_semantic_snapshot(manual),
            POLICY_WALLET: self._recovery_semantic_snapshot(policy),
            FAULT_WALLET: self._recovery_semantic_snapshot(fault),
            BOUNDARY_WALLET: self._recovery_semantic_snapshot(boundary),
            CROSS_BOUNDARY_WALLET: self._recovery_semantic_snapshot(
                cross_boundary
            ),
        }
        expected_boundary_gate = self._mining_gate_semantic_snapshot(boundary)
        expected_cross_boundary_gate = self._mining_gate_semantic_snapshot(
            cross_boundary
        )
        expected_boundary_unspent = sorted(
            (
                {"txid": utxo["txid"], "vout": utxo["vout"]}
                for utxo in boundary.listunspent(1, 9999999, [boundary_address])
            ),
            key=lambda outpoint: (outpoint["txid"], outpoint["vout"]),
        )
        assert_equal(
            boundary.getpowclaimrecoveryinfo()["confirmed_resolution_fees"],
            Decimal("0"),
        )
        expected_cross_boundary_unspent = sorted(
            (
                {"txid": utxo["txid"], "vout": utxo["vout"]}
                for utxo in cross_boundary.listunspent(
                    1, 9999999, [cross_boundary_address]
                )
            ),
            key=lambda outpoint: (outpoint["txid"], outpoint["vout"]),
        )
        assert_equal(
            cross_boundary.getpowclaimrecoveryinfo()[
                "confirmed_resolution_fees"
            ],
            Decimal("0"),
        )

        for wallet in (manual, policy, fault, boundary, cross_boundary):
            wallet.rescanblockchain(0)
        node.syncwithvalidationinterfacequeue()
        assert_equal(self._recovery_semantic_snapshot(manual), expected_recovery[MANUAL_WALLET])
        assert_equal(self._recovery_semantic_snapshot(policy), expected_recovery[POLICY_WALLET])
        assert_equal(self._recovery_semantic_snapshot(fault), expected_recovery[FAULT_WALLET])
        assert_equal(self._recovery_semantic_snapshot(boundary), expected_recovery[BOUNDARY_WALLET])
        assert_equal(
            self._recovery_semantic_snapshot(cross_boundary),
            expected_recovery[CROSS_BOUNDARY_WALLET],
        )
        assert_equal(self._mining_gate_semantic_snapshot(boundary), expected_boundary_gate)
        assert_equal(
            self._mining_gate_semantic_snapshot(cross_boundary),
            expected_cross_boundary_gate,
        )
        assert_equal(
            sorted(
                (
                    {"txid": utxo["txid"], "vout": utxo["vout"]}
                    for utxo in boundary.listunspent(
                        1, 9999999, [boundary_address]
                    )
                ),
                key=lambda outpoint: (outpoint["txid"], outpoint["vout"]),
            ),
            expected_boundary_unspent,
        )
        assert_equal(
            sorted(
                (
                    {"txid": utxo["txid"], "vout": utxo["vout"]}
                    for utxo in cross_boundary.listunspent(
                        1, 9999999, [cross_boundary_address]
                    )
                ),
                key=lambda outpoint: (outpoint["txid"], outpoint["vout"]),
            ),
            expected_cross_boundary_unspent,
        )
        assert_equal(
            boundary.getpowclaimrecoveryinfo()["confirmed_resolution_fees"],
            Decimal("0"),
        )
        assert_equal(
            cross_boundary.getpowclaimrecoveryinfo()[
                "confirmed_resolution_fees"
            ],
            Decimal("0"),
        )
        assert_equal(fault.gettransaction(failed_resolution_txid)["hex"], failed_resolution_hex)

        expected_tip = node.getbestblockhash()
        expected_height = node.getblockcount()
        self.stop_node(0)
        self.run_chainstate_rebuild_first_pass(node, [
            *self.base_args,
            "-reindex-chainstate",
            f"-mocktime={self.mock_time}",
        ])
        self.restart_after_chainstate_rebuild(0, extra_args=[
            *self.base_args,
            f"-mocktime={self.mock_time}",
        ])
        node = self.nodes[0]
        node.setmocktime(self.mock_time)
        self.wait_until(
            lambda: (
                node.getblockcount() == expected_height
                and node.getbestblockhash() == expected_tip
                and not node.getblockchaininfo()["initialblockdownload"]
            ),
            timeout=120,
        )
        manual = self._load_wallet(MANUAL_WALLET)
        policy = self._load_wallet(POLICY_WALLET)
        fault = self._load_wallet(FAULT_WALLET)
        boundary = self._load_wallet(BOUNDARY_WALLET)
        cross_boundary = self._load_wallet(CROSS_BOUNDARY_WALLET)
        node.syncwithvalidationinterfacequeue()
        if failed_resolution_txid not in node.getrawmempool():
            node.mockscheduler(61)
            self.wait_until(
                lambda: failed_resolution_txid in node.getrawmempool(),
                timeout=30,
            )
            node.syncwithvalidationinterfacequeue()
        assert_equal(self._recovery_semantic_snapshot(manual), expected_recovery[MANUAL_WALLET])
        assert_equal(self._recovery_semantic_snapshot(policy), expected_recovery[POLICY_WALLET])
        assert_equal(self._recovery_semantic_snapshot(fault), expected_recovery[FAULT_WALLET])
        assert_equal(self._recovery_semantic_snapshot(boundary), expected_recovery[BOUNDARY_WALLET])
        assert_equal(
            self._recovery_semantic_snapshot(cross_boundary),
            expected_recovery[CROSS_BOUNDARY_WALLET],
        )
        assert_equal(self._mining_gate_semantic_snapshot(boundary), expected_boundary_gate)
        assert_equal(
            self._mining_gate_semantic_snapshot(cross_boundary),
            expected_cross_boundary_gate,
        )
        assert_equal(
            sorted(
                (
                    {"txid": utxo["txid"], "vout": utxo["vout"]}
                    for utxo in boundary.listunspent(
                        1, 9999999, [boundary_address]
                    )
                ),
                key=lambda outpoint: (outpoint["txid"], outpoint["vout"]),
            ),
            expected_boundary_unspent,
        )
        assert_equal(
            sorted(
                (
                    {"txid": utxo["txid"], "vout": utxo["vout"]}
                    for utxo in cross_boundary.listunspent(
                        1, 9999999, [cross_boundary_address]
                    )
                ),
                key=lambda outpoint: (outpoint["txid"], outpoint["vout"]),
            ),
            expected_cross_boundary_unspent,
        )
        assert_equal(
            boundary.getpowclaimrecoveryinfo()["confirmed_resolution_fees"],
            Decimal("0"),
        )
        assert_equal(
            cross_boundary.getpowclaimrecoveryinfo()[
                "confirmed_resolution_fees"
            ],
            Decimal("0"),
        )
        assert_equal(fault.gettransaction(failed_resolution_txid)["hex"], failed_resolution_hex)


if __name__ == "__main__":
    GoldRushPowClaimSingleFlightTest().main()
