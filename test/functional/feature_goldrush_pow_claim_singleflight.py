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
TIE_WALLET = "pow_claim_tie"
FAULT_WALLET = "pow_claim_fault"
BOUNDARY_WALLET = "pow_claim_boundary"
LIVE_FEE_VALUES = (Decimal("0.991"), Decimal("501.747137"), Decimal("969.818832"))


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
            "-shadowgoldrushblocks=500",
            # Keep this focused on historical QQP2 single-flight behavior,
            # but use a reachable boundary inside the compressed Gold Rush.
            # Post-boundary QQP4 behavior is exercised by the contention and
            # index-boundary tests.
            "-shadowcompetingclaimsheight=501",
            "-shadowqqp4height=501",
            f"-qqgoldrushendtime={GOLD_RUSH_END_TIME}",
        ]
        self.extra_args = [[
            *self.base_args,
            "-qqshadowpowclaimsubmissiondelaymillis=1500",
        ]]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def _set_mocktime(self, timestamp):
        self.mock_time = timestamp
        self.nodes[0].setmocktime(timestamp)

    def _bump_mocktime(self, seconds):
        self._set_mocktime(self.mock_time + seconds)

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
        assert_equal(info["quarantined_claims"], raw)
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
        node.createwallet(wallet_name=TIE_WALLET)
        node.createwallet(wallet_name=FAULT_WALLET)
        node.createwallet(wallet_name=BOUNDARY_WALLET)
        manual = node.get_wallet_rpc(MANUAL_WALLET)
        builtin = node.get_wallet_rpc(BUILTIN_WALLET)
        policy = node.get_wallet_rpc(POLICY_WALLET)
        policy_lock = node.get_wallet_rpc(POLICY_LOCK_WALLET)
        builtin_race = node.get_wallet_rpc(BUILTIN_RACE_WALLET)
        tie_wallet = node.get_wallet_rpc(TIE_WALLET)
        fault = node.get_wallet_rpc(FAULT_WALLET)
        boundary = node.get_wallet_rpc(BOUNDARY_WALLET)
        descendant_blocker = node.get_wallet_rpc(DESCENDANT_BLOCKER_WALLET)
        for wallet in (
            manual,
            descendant_blocker,
            builtin,
            policy,
            policy_lock,
            builtin_race,
            tie_wallet,
            fault,
            boundary,
        ):
            wallet.staking(False)
        manual_address = manual.getnewaddress("claim-input", "legacy")
        descendant_blocker_address = descendant_blocker.getnewaddress("claim-input", "legacy")
        builtin_address = builtin.getnewaddress("claim-input", "legacy")
        policy_address = policy.getnewaddress("claim-input", "legacy")
        policy_lock_address = policy_lock.getnewaddress("claim-input", "legacy")
        builtin_race_address = builtin_race.getnewaddress("claim-input", "legacy")
        tie_address = tie_wallet.getnewaddress("claim-input", "legacy")
        fault_address = fault.getnewaddress("claim-input", "legacy")
        boundary_address = boundary.getnewaddress("claim-input", "legacy")
        funding_address = default_wallet.getnewaddress("claim-test-funding", "legacy")

        self.log.info("Funding independent manual and built-in claim wallets")
        self.generatetoaddress(node, 1, manual_address, sync_fun=self.no_op)
        self.generatetoaddress(node, 1, descendant_blocker_address, sync_fun=self.no_op)
        self.generatetoaddress(node, 1, builtin_address, sync_fun=self.no_op)
        self.generatetoaddress(node, 1, fault_address, sync_fun=self.no_op)
        self.generatetoaddress(node, 1, boundary_address, sync_fun=self.no_op)
        self.generatetoaddress(node, COINBASE_MATURITY + 5, funding_address, sync_fun=self.no_op)
        assert_equal(node.getquantumquasarinfo()["phase"], "gold_rush")
        assert_equal(len(manual.listunspent(1, 9999999, [manual_address])), 1)
        assert_equal(
            len(descendant_blocker.listunspent(1, 9999999, [descendant_blocker_address])),
            1,
        )
        assert_equal(len(builtin.listunspent(1, 9999999, [builtin_address])), 1)

        self.log.info("Funding a second confirmed boundary-wallet fee input for quarantine-gate coverage")
        default_wallet.sendtoaddress(boundary_address, Decimal("1.25000000"))
        self.generatetoaddress(node, 1, funding_address, sync_fun=self.no_op)

        self.log.info("Funding live-scale same-script fee inputs for deterministic policy coverage")
        policy_inputs = self._fund_live_fee_inputs(default_wallet, policy, policy_address, funding_address)
        policy_lock_inputs = self._fund_live_fee_inputs(default_wallet, policy_lock, policy_lock_address, funding_address)
        builtin_race_inputs = self._fund_live_fee_inputs(default_wallet, builtin_race, builtin_race_address, funding_address)

        self.log.info("Manual claims choose the smallest sufficient same-script input")
        policy_payout = policy.getnewquantumaddress("policy-payout")["address"]
        policy_claim = policy.sendshadowpowclaim(policy_address, policy_payout, 500000)
        assert_equal(self._claim_input(policy_claim["txid"]), policy_inputs[LIVE_FEE_VALUES[0]])
        # The live claim creates an unconfirmed same-script change output. It
        # must never become the next claim's fee input: claim chains can be
        # invalidated with their parent and bypass the confirmed-input rule.
        assert any(
            utxo["txid"] == policy_claim["txid"] and utxo["vout"] == 0
            for utxo in policy.listunspent(0, 9999999, [policy_address])
        )

        self.log.info("A selected input locked at the test barrier cannot fall back to a larger coin")
        policy_before_race = self._claim_txids(policy)
        expected_policy_race_input = policy_inputs[LIVE_FEE_VALUES[1]]
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
        assert_equal(policy.lockunspent(False, [policy_inputs[LIVE_FEE_VALUES[1]]]), True)
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
        assert_equal(policy.lockunspent(True, [policy_inputs[LIVE_FEE_VALUES[1]]]), True)

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
        policy_initial_info = policy.getpowclaimrecoveryinfo()
        assert_equal(policy_initial_info["policy"]["mode"], "unset")
        assert_equal(policy_initial_info["policy_authoritative"], True)
        assert_equal(policy_initial_info["policy_state_status"], "success")
        assert_equal(policy_lock.getpowclaimrecoveryinfo()["policy"]["mode"], "unset")
        automatic_limits = {
            "max_fee_per_resolution": Decimal("0.01"),
            "aggregate_batch_fee_cap": Decimal("0.05"),
            "rolling_fee_budget": Decimal("0.10"),
            "rolling_fee_window_seconds": 86400,
            "max_actions_per_window": 5,
            "minimum_stale_blocks": 1,
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

        automatic_claim_txids_before = self._claim_txids(policy)
        automatic_resolution_txid = None
        automatic_running_state = None
        started = policy.setpowmining(True, 1, 1, True)
        assert_equal(started["enabled"], True)
        try:
            # The first scheduler pass performs a typed, pinned-tip conflict
            # classification and durably records the branch-relative
            # quarantine observation. It must not spend on that same
            # observation.
            node.mockscheduler(61)
            self.wait_until(
                lambda: policy.getpowclaimrecoveryinfo(True)["component_details"][0]["stale_depth_known"],
                timeout=20,
            )
            assert_equal(
                policy.getpowclaimrecoveryinfo(True)["component_details"][0]["minimum_stale_depth"],
                0,
            )

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
        assert_equal(automatic_component["has_revalidating_unbound_proof"], True)
        assert any(
            graph_node["proof_may_revalidate_on_descendant"]
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

        self.log.info("The built-in miner waits for a new tip after its exact input becomes unavailable")
        builtin_race_before = self._claim_txids(builtin_race)
        with node.wait_for_debug_log([b"Gold Rush PoW claim submission test barrier reached"], timeout=180):
            started = builtin_race.setpowmining(True, 1, 100, True)
            assert started["created_payout_key"]
        with node.wait_for_debug_log([b"is no longer spendable; retry after the next tip"], timeout=20):
            assert_equal(builtin_race.lockunspent(False, [builtin_race_inputs[LIVE_FEE_VALUES[0]]]), True)
        try:
            self.wait_until(lambda: builtin_race.getpowmininginfo()["state"] == "ready", timeout=10)
            time.sleep(2)
            assert_equal(self._claim_txids(builtin_race), builtin_race_before)
            assert_equal(builtin_race.getpowmininginfo()["claims_submitted"], 0)
        finally:
            builtin_race.setpowmining(False)
        assert_equal(builtin_race.lockunspent(True, [builtin_race_inputs[LIVE_FEE_VALUES[0]]]), True)

        self.generateblock(node, output=funding_address, transactions=[])
        builtin_race.setpowmining(True, 1, 100)
        try:
            self.wait_until(lambda: len(self._claim_txids(builtin_race) - builtin_race_before) == 1, timeout=180)
            builtin_race_claim = sorted(self._claim_txids(builtin_race) - builtin_race_before)[0]
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
        assert_equal(resolution_info["unresolved_claims"], 0)
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

        self.log.info("The built-in miner uses the same guard and exception cleanup")
        before_builtin_fault = self._quarantined_claim_txids(builtin)
        started = builtin.setpowmining(True, 1, 100, True)
        assert started["created_payout_key"]
        try:
            builtin_fault_txid = self._wait_for_new_quarantined_claim(builtin, before_builtin_fault)
        finally:
            builtin.setpowmining(False)
        assert_equal(builtin.getpowmininginfo()["claims_submitted"], 0)
        assert builtin_fault_txid not in node.getrawmempool()
        assert_equal(self._is_abandoned(builtin, builtin_fault_txid), False)
        assert_equal(len(builtin.listunspent(1, 9999999, [builtin_address])), 0)
        self._assert_generic_abandon_rejected(builtin, builtin_fault_txid)
        assert_equal(len(builtin.listunspent(1, 9999999, [builtin_address])), 0)

        self.log.info("Quarantine survives restart and does not reactivate a peer-visible exact-input claim")
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

        self.log.info("A pre-boundary QQP2 claim crosses into QQP4 policy without releasing its input")
        activation_height = 501
        pre_boundary_tip = activation_height - 2
        assert node.getblockcount() < pre_boundary_tip
        while node.getblockcount() < pre_boundary_tip:
            self.generateblock(node, output=funding_address, transactions=[])
        assert_equal(node.getblockcount(), pre_boundary_tip)
        assert_equal(node.getshadowpowwork()["height"], activation_height - 1)
        assert_equal(node.getshadowpowwork()["proof_version"], 2)

        boundary = self._load_wallet(BOUNDARY_WALLET)
        assert_equal(len(boundary.listunspent(1, 9999999, [boundary_address])), 2)
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

        # Deliberately omit the last QQP2 claim at its intended height. At the
        # resulting tip, the next-block policy is QQP4-only and the old
        # transaction is terminal. Its fee input remains unavailable. The
        # other confirmed UTXO stays visible, but the quarantine gate must
        # prevent it from funding another claim while the old proof resolves.
        self.generateblock(node, output=funding_address, transactions=[])
        assert_equal(node.getblockcount(), activation_height - 1)
        assert_equal(node.getshadowpowwork()["height"], activation_height)
        assert_equal(node.getshadowpowwork()["proof_version"], 4)
        rejected = node.testmempoolaccept([boundary_raw])[0]
        assert_equal(rejected["allowed"], False)
        assert_equal(rejected["reject-reason"], "shadow-proof-version")
        assert_equal(len(boundary.listunspent(1, 9999999, [boundary_address])), 1)

        # Startup repair must retain the obsolete proof and its input. A
        # second confirmed fee UTXO exists, but neither RPC nor the built-in
        # miner may consume it while the first claim remains quarantined.
        self.restart_node(0, extra_args=[*self.base_args, f"-mocktime={self.mock_time}"])
        node = self.nodes[0]
        node.setmocktime(self.mock_time)
        boundary = self._load_wallet(BOUNDARY_WALLET)
        self._assert_generic_abandon_rejected(boundary, boundary_claim_txid)
        remaining_boundary_inputs = boundary.listunspent(1, 9999999, [boundary_address])
        assert_equal(len(remaining_boundary_inputs), 1)
        assert_equal(
            {"txid": remaining_boundary_inputs[0]["txid"], "vout": remaining_boundary_inputs[0]["vout"]}
            != boundary_claim_input,
            True,
        )
        before_second_claim = self._claim_txids(boundary)
        assert_raises_rpc_error(
            -4,
            "wallet will not create a second fee-input claim",
            boundary.sendshadowpowclaim,
            boundary_address,
            boundary_payout,
            500_000,
        )
        assert_equal(self._claim_txids(boundary), before_second_claim)

        started = boundary.setpowmining(True, 1, 100)
        assert_equal(started["created_payout_key"], False)
        assert_equal(started["payout_address"], boundary_payout)
        try:
            self.wait_until(
                lambda: boundary.getpowmininginfo()["state"] == "claim_quarantined",
                timeout=20,
            )
            info = boundary.getpowmininginfo()
            assert_equal(info["claims_submitted"], 0)
            self._assert_claim_inventory(
                boundary, raw=1, actionable=1, resolved=0, indeterminate=0, components=1
            )
            assert_equal(self._claim_txids(boundary), before_second_claim)
            assert_equal(len(boundary.listunspent(1, 9999999, [boundary_address])), 1)
        finally:
            boundary.setpowmining(False)
        assert not any(
            entry.get("qq_shadow_pow_cleanup_for") == boundary_claim_txid
            for entry in boundary.listtransactions("*", 1000, 0, True)
        )

        self.log.info("Recovery policy, exact bytes, graph, and metrics survive rescan and reindex")
        manual = self._load_wallet(MANUAL_WALLET)
        policy = self._load_wallet(POLICY_WALLET)
        fault = self._load_wallet(FAULT_WALLET)
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
        }

        for wallet in (manual, policy, fault):
            wallet.rescanblockchain(0)
        node.syncwithvalidationinterfacequeue()
        assert_equal(self._recovery_semantic_snapshot(manual), expected_recovery[MANUAL_WALLET])
        assert_equal(self._recovery_semantic_snapshot(policy), expected_recovery[POLICY_WALLET])
        assert_equal(self._recovery_semantic_snapshot(fault), expected_recovery[FAULT_WALLET])
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
        assert_equal(fault.gettransaction(failed_resolution_txid)["hex"], failed_resolution_hex)


if __name__ == "__main__":
    GoldRushPowClaimSingleFlightTest().main()
