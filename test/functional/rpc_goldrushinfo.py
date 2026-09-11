#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license

from decimal import Decimal
import time

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_raises_rpc_error

QQSPROOF_HEX = "51515350524f4f46"
GOLD_RUSH_END_HEIGHT = 501
MIGRATION_END_HEIGHT = 700
QQP3_LATE_ORIGIN_WINDOW = 64
QQSPROOF_MEMPOOL_TTL_SECONDS = 60 * 60
POW_WALLET_PASSPHRASE = "goldrush-pow-state-test"
ZERO_HASH = "0" * 64

class GoldRushInfoTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.num_nodes = 2
        self.setup_clean_chain = True
        args = [
            "-shadowwhitelistheight=1",
            "-shadowgoldrushblocks=500",
            f"-qqgoldrushendheight={GOLD_RUSH_END_HEIGHT}",
            f"-qqmigrationendheight={MIGRATION_END_HEIGHT}",
        ]
        self.extra_args = [
            args,
            args,
        ]

    def _sync_mocktime_to_tip(self):
        tip_time = max(
            node.getblockheader(node.getbestblockhash())["time"]
            for node in self.nodes
        )
        for node in self.nodes:
            node.setmocktime((tip_time & ~0xf) + 16)

    def _generate_with_peer_offline(self, node, blocks, address):
        """Generate a large batch without making the idle peer time out."""
        self.disconnect_nodes(0, 1)
        try:
            hashes = self.generatetoaddress(node, blocks, address, sync_fun=self.no_op)
        finally:
            self.connect_nodes(0, 1)
        self.sync_blocks()
        return hashes

    def _restart_wallet_broadcast(self, enabled, *, reconnect_peer):
        """Keep expiry observations independent of prompt exact-byte relay."""
        node = self.nodes[0]
        loaded_wallets = node.listwallets()
        self.restart_node(0, extra_args=[
            *self.extra_args[0],
            f"-walletbroadcast={int(enabled)}",
            f"-mocktime={node.mocktime}",
        ])
        node = self.nodes[0]
        for name in loaded_wallets:
            if name not in node.listwallets():
                node.loadwallet(name, False)
        if reconnect_peer:
            self.connect_nodes(0, 1)
            self.sync_blocks()
        node.syncwithvalidationinterfacequeue()
        return node

    @staticmethod
    def _mempool_pow_claims(node):
        claims = []
        for txid in node.getrawmempool():
            tx = node.getrawtransaction(txid, True)
            if any(QQSPROOF_HEX in output["scriptPubKey"]["hex"] for output in tx["vout"]):
                claims.append(txid)
        return claims

    @staticmethod
    def _wallet_pow_claims(wallet):
        return {
            entry["txid"]
            for entry in wallet.listtransactions("*", 1000, 0, True)
            if entry.get("comment") == "PoW Claim"
        }

    def _assert_qqp3_recovery_age(
        self, wallet, claim_txid, origin_age, *, expect_in_mempool=True
    ):
        """Pin the recovery engine to every still-live QQP3 origin age."""
        node = self.nodes[0]
        assert_equal(claim_txid in node.getrawmempool(), expect_in_mempool)
        info = wallet.getpowclaimrecoveryinfo(True)
        component = next(
            component
            for component in info["component_details"]
            if claim_txid in component["claim_txids"]
        )
        claim_node = next(
            graph_node
            for graph_node in component["nodes"]
            if graph_node["txid"] == claim_txid
        )
        assert_equal(claim_node["kind"], "claim")
        assert_equal(claim_node["in_mempool"], expect_in_mempool)
        assert_equal(claim_node["disposition"], "eligible")
        assert_equal(claim_node["proof_may_revalidate_on_descendant"], False)
        assert_equal(info["live_claim_objects"], int(expect_in_mempool))
        if not expect_in_mempool:
            assert_equal(claim_node["quarantined"], True)
            assert_equal(component["classification"], "live")

        # Recovery planning must revalidate the complete component, not infer
        # terminality merely from age. The inclusive QQP3 late-origin window
        # therefore refuses a conflict at every origin age 0 through 64.
        preview = wallet.resolveallshadowpowclaims()
        assert_equal(preview["actionable_components"], 0)
        assert_equal(preview["refused_components"], 1)
        assert_equal(
            preview["refused"][0]["reason_code"],
            "claim-live" if expect_in_mempool else "claim-not-terminal",
        )
        assert_equal(preview["refused"][0]["claim_txids"], [claim_txid])
        self.log.debug(
            "QQP3 claim %s remains height-live and non-resolvable at origin age %d (in_mempool=%s)",
            claim_txid,
            origin_age,
            expect_in_mempool,
        )

    def _assert_lineaged_origin_expired_family(
        self,
        wallet,
        claim_txid,
        anchor,
        target_address,
        *,
        expected_snapshot=None,
    ):
        """Assert that an expired authored family keeps its exact anchor reserved."""
        node = self.nodes[0]
        recovery = wallet.getpowclaimrecoveryinfo(True)
        component = next(
            item
            for item in recovery["component_details"]
            if claim_txid in item["claim_txids"]
        )
        claim_node = next(
            item for item in component["nodes"] if item["txid"] == claim_txid
        )
        record = wallet.gettransaction(claim_txid)
        transactions = wallet.listtransactions("*", 1000, 0, True)

        assert_equal(component["classification"], "terminal_on_pinned_tip")
        assert_equal(
            {
                "txid": component["anchor"]["txid"],
                "vout": component["anchor"]["vout"],
            },
            anchor,
        )
        assert_equal(component["anchor_authenticated"], True)
        assert_equal(component["anchor_unspent"], True)
        assert_equal(component["claim_txids"], [claim_txid])
        assert_equal(component["root_claim_txids"], [claim_txid])
        assert_equal(component["resolution_txids"], [])
        assert_equal(component["ordinary_or_mixed_txids"], [])
        assert_equal(len(component["generation_fingerprint"]), 64)
        assert component["generation_fingerprint"] != ZERO_HASH

        assert_equal(claim_node["disposition"], "origin_expired")
        assert_equal(claim_node["in_mempool"], False)
        assert_equal(claim_node["quarantined"], True)
        assert_equal(claim_node["abandoned"], False)
        assert_equal(claim_node["lineage_metadata_present"], True)
        assert_equal(claim_node["lineage_metadata_valid"], True)
        assert_equal(claim_node["lineage_root_txid"], claim_txid)
        assert_equal(claim_node["lineage_parent_txid"], ZERO_HASH)
        assert_equal(claim_node["lineage_ordinal"], 0)
        assert_equal(
            claim_node["lineage_family_fingerprint"],
            component["generation_fingerprint"],
        )

        assert_equal(record["qq_shadow_pow_quarantine"], "1")
        assert_equal(record["qq_shadow_pow_lineage_schema"], "1")
        assert_equal(record["qq_shadow_pow_lineage_root"], claim_txid)
        assert "qq_shadow_pow_lineage_parent" not in record
        assert_equal(record["qq_shadow_pow_lineage_ordinal"], "0")
        assert_equal(
            record["qq_shadow_pow_lineage_family"],
            component["generation_fingerprint"],
        )
        assert_equal(recovery["blocking_components"], 1)
        assert_equal(recovery["pending_manual_resolutions"], 0)
        assert_equal(recovery["pending_automatic_resolutions"], 0)
        assert_equal(recovery["confirmed_manual_resolutions"], 0)
        assert_equal(recovery["confirmed_automatic_resolutions"], 0)
        assert_equal(recovery["automatic_fee_exposure_in_window"], Decimal("0"))
        assert_equal(recovery["confirmed_resolution_fees"], Decimal("0"))
        assert_equal(recovery["policy"]["mode"], "unset")
        assert_equal(recovery["policy"]["automatic_authorized"], False)
        assert not any(
            entry.get("qq_shadow_pow_cleanup_for") == claim_txid
            for entry in transactions
        )

        assert node.gettxout(anchor["txid"], anchor["vout"], False) is not None
        assert all(
            {"txid": utxo["txid"], "vout": utxo["vout"]} != anchor
            for utxo in wallet.listunspent(1, 9999999, [target_address])
        )

        gate = wallet.getpowmininginfo()
        assert_equal(gate["claim_inventory_tip"], node.getbestblockhash())
        assert_equal(gate["claim_inventory_wallet_tip_matches"], True)
        assert_equal(gate["mining_gate_coherent"], True)
        assert_equal(gate["mining_gate_database_ambiguous"], False)
        assert_equal(gate["mining_gate_unsafe_claims"], 0)
        assert_equal(gate["mining_gate_unsafe_components"], 0)
        assert_equal(gate["mining_gate_action"], "refresh_same_anchor")
        assert_equal(gate["mining_gate_can_submit"], True)
        assert_equal(gate["mining_gate_family_claims"], 1)
        assert_equal(gate["mining_gate_live_claims"], 0)
        assert_equal(gate["mining_gate_eligible_claims"], 0)
        assert_equal(gate["mining_gate_lineage_head_txid"], claim_txid)
        assert_equal(len(gate["mining_gate_candidate_state_fingerprint"]), 64)
        assert gate["mining_gate_candidate_state_fingerprint"] != ZERO_HASH

        snapshot = {
            "anchor": {
                "txid": component["anchor"]["txid"],
                "vout": component["anchor"]["vout"],
            },
            "generation_fingerprint": component["generation_fingerprint"],
            "lineage_family_fingerprint": claim_node[
                "lineage_family_fingerprint"
            ],
            "claim_txids": component["claim_txids"],
            "wallet_txcount": wallet.getwalletinfo()["txcount"],
            "wallet_claims": self._wallet_pow_claims(wallet),
        }
        if expected_snapshot is not None:
            assert_equal(snapshot, expected_snapshot)
        return snapshot

    def _assert_builtin_pow_miner_lifecycle(self):
        node = self.nodes[0]
        wallet_name = "goldrush_pow_builtin"
        strict_wallet_name = "goldrush_pow_interactive_strict"

        # Interactive starts remain strict for a wallet without a retained
        # worker. The startup lifecycle below separately proves that a rejected
        # reconfiguration preserves an already-enabled waiting worker.
        node.createwallet(wallet_name=strict_wallet_name, load_on_startup=False)
        strict_wallet = node.get_wallet_rpc(strict_wallet_name)
        strict_wallet.getnewquantumaddress("PoW - Quantum Claim Address")
        strict_wallet.encryptwallet(POW_WALLET_PASSPHRASE)
        assert_raises_rpc_error(
            -4,
            "requires an unlocked wallet",
            strict_wallet.setpowmining,
            True,
            1,
            1,
        )
        strict_wallet.walletpassphrase(POW_WALLET_PASSPHRASE, 600, True)
        assert_raises_rpc_error(
            -4,
            "normal wallet unlock",
            strict_wallet.setpowmining,
            True,
            1,
            1,
        )
        strict_wallet.walletlock()
        node.unloadwallet(strict_wallet_name, False)

        node.createwallet(wallet_name=wallet_name, load_on_startup=True)
        wallet = node.get_wallet_rpc(wallet_name)
        target = wallet.getnewaddress()

        self._generate_with_peer_offline(node, 101, target)
        self._sync_mocktime_to_tip()
        payout = wallet.getnewquantumaddress("PoW - Quantum Claim Address")["address"]
        assert_equal(
            wallet.getaddressinfo(payout)["labels"],
            ["PoW - Quantum Claim Address"],
        )
        quantum_addresses_before = {
            entry["address"] for entry in wallet.listquantumaddresses()
        }
        assert_equal(quantum_addresses_before, {payout})
        wallet_txcount_before = wallet.getwalletinfo()["txcount"]
        wallet_claims_before = self._wallet_pow_claims(wallet)
        wallet.encryptwallet(POW_WALLET_PASSPHRASE)

        # The process-wide startup option applies to every loaded private-key
        # wallet. Persist only this target for the restart so an unrelated
        # wallet cannot silently satisfy the worker assertions.
        originally_loaded = [name for name in node.listwallets() if name != wallet_name]
        for name in originally_loaded:
            node.unloadwallet(name, False)
        assert_equal(node.listwallets(), [wallet_name])

        try:
            self.restart_node(
                0,
                extra_args=[
                    *self.extra_args[0],
                    "-powmining=1",
                    "-powminingthreads=1",
                    "-powminingcpu=1",
                    "-autostartstaking=0",
                    f"-qqpowpayoutaddress={payout}",
                ],
            )
            node = self.nodes[0]
            self.connect_nodes(0, 1)
            assert_equal(node.listwallets(), [wallet_name])
            wallet = node.get_wallet_rpc(wallet_name)
            node.setmocktime(0)

            submit_gate_actions = {
                "create_new_anchor",
                "refresh_same_anchor",
            }
            wait_gate_actions = {
                "wait_for_live",
                "wait_for_next_tip",
                "relay_existing",
            }
            null_txid = "0" * 64

            def gate_is_safe(info):
                return (
                    info["mining_gate_coherent"]
                    and not info["mining_gate_database_ambiguous"]
                    and info["mining_gate_unsafe_claims"] == 0
                    and info["mining_gate_unsafe_components"] == 0
                )

            def is_genuine_safe_wait(info):
                action = info["mining_gate_action"]
                if (
                    action not in wait_gate_actions
                    or info["state"] != "claim_in_flight"
                    or info["hashrate"] != 0
                    or info["mining_gate_family_claims"] == 0
                    or info["mining_gate_lineage_head_txid"] == null_txid
                ):
                    return False
                if action == "wait_for_live":
                    return info["mining_gate_live_claims"] > 0
                if action == "relay_existing":
                    return info["mining_gate_relay_txid"] != null_txid
                return True

            def worker_resumed_or_safely_waiting():
                info = wallet.getpowmininginfo()
                if (
                    not info["enabled"]
                    or info["state"] == "wallet_locked_or_staking_only"
                    or not gate_is_safe(info)
                ):
                    return False
                return (
                    info["hashrate"] > 0
                    and info["state"] in ("ready", "hashing", "claim_in_flight")
                    and info["mining_gate_action"] in submit_gate_actions
                    and info["mining_gate_can_submit"]
                ) or is_genuine_safe_wait(info)

            def assert_worker_resumed_or_safely_waiting(info):
                assert_equal(info["enabled"], True)
                assert info["state"] != "wallet_locked_or_staking_only"
                assert_equal(gate_is_safe(info), True)
                if info["hashrate"] == 0:
                    assert_equal(is_genuine_safe_wait(info), True)
                else:
                    assert info["state"] in ("ready", "hashing", "claim_in_flight")
                    assert info["mining_gate_action"] in submit_gate_actions
                    assert_equal(info["mining_gate_can_submit"], True)

            self.wait_until(
                lambda: wallet.getpowmininginfo()["state"]
                == "wallet_locked_or_staking_only",
                timeout=20,
            )
            locked = wallet.getpowmininginfo()
            assert_equal(locked["enabled"], True)
            assert_equal(locked["autostart"], True)
            assert_equal(locked["threads"], 1)
            assert_equal(locked["cpu_percent"], 1)
            assert_equal(locked["state"], "wallet_locked_or_staking_only")
            assert_equal(locked["hashrate"], 0)
            assert locked["payout_address"] in ("", payout)
            assert_equal(wallet.getwalletinfo()["unlocked_until"], 0)
            assert_equal(
                {entry["address"] for entry in wallet.listquantumaddresses()},
                quantum_addresses_before,
            )
            assert_equal(wallet.getwalletinfo()["txcount"], wallet_txcount_before)
            assert_equal(self._wallet_pow_claims(wallet), wallet_claims_before)

            self.log.info(
                "A rejected locked reconfiguration preserves the startup worker"
            )
            assert_raises_rpc_error(
                -4,
                "requires an unlocked wallet",
                wallet.setpowmining,
                True,
                2,
                25,
            )
            locked_after_reject = wallet.getpowmininginfo()
            assert_equal(locked_after_reject["enabled"], True)
            assert_equal(locked_after_reject["threads"], 1)
            assert_equal(locked_after_reject["cpu_percent"], 1)
            assert_equal(
                locked_after_reject["state"],
                "wallet_locked_or_staking_only",
            )
            assert_equal(locked_after_reject["hashrate"], 0)
            assert_equal(
                {entry["address"] for entry in wallet.listquantumaddresses()},
                quantum_addresses_before,
            )
            assert_equal(wallet.getwalletinfo()["txcount"], wallet_txcount_before)
            assert_equal(self._wallet_pow_claims(wallet), wallet_claims_before)

            self.log.info("A staking-only unlock keeps the retained startup worker paused")
            wallet.walletpassphrase(POW_WALLET_PASSPHRASE, 600, True)
            self.wait_until(
                lambda: wallet.getpowmininginfo()["state"] == "wallet_locked_or_staking_only",
                timeout=10,
            )
            staking_only = wallet.getpowmininginfo()
            assert_equal(staking_only["enabled"], True)
            assert_equal(staking_only["threads"], 1)
            assert_equal(staking_only["cpu_percent"], 1)
            assert_equal(staking_only["state"], "wallet_locked_or_staking_only")
            assert_equal(staking_only["hashrate"], 0)
            assert_equal(
                {entry["address"] for entry in wallet.listquantumaddresses()},
                quantum_addresses_before,
            )
            assert_equal(wallet.getwalletinfo()["txcount"], wallet_txcount_before)
            assert_equal(self._wallet_pow_claims(wallet), wallet_claims_before)

            assert_raises_rpc_error(
                -4,
                "normal wallet unlock",
                wallet.setpowmining,
                True,
                2,
                25,
            )
            staking_only_after_reject = wallet.getpowmininginfo()
            assert_equal(
                wallet.getwalletinfo()["unlocked_staking_only"], True
            )
            assert_equal(staking_only_after_reject["enabled"], True)
            assert_equal(staking_only_after_reject["threads"], 1)
            assert_equal(staking_only_after_reject["cpu_percent"], 1)
            assert_equal(
                staking_only_after_reject["state"],
                "wallet_locked_or_staking_only",
            )
            assert_equal(staking_only_after_reject["hashrate"], 0)
            assert_equal(
                {entry["address"] for entry in wallet.listquantumaddresses()},
                quantum_addresses_before,
            )
            assert_equal(wallet.getwalletinfo()["txcount"], wallet_txcount_before)
            assert_equal(self._wallet_pow_claims(wallet), wallet_claims_before)

            self.log.info("A failed RPC scope expansion leaves staking-only authority intact")
            assert_raises_rpc_error(
                -14,
                "passphrase",
                wallet.walletpassphrase,
                "wrong-goldrush-pow-passphrase",
                600,
                False,
            )
            failed_scope_change = wallet.getpowmininginfo()
            assert_equal(
                wallet.getwalletinfo()["unlocked_staking_only"], True
            )
            assert_equal(failed_scope_change["enabled"], True)
            assert_equal(
                failed_scope_change["state"],
                "wallet_locked_or_staking_only",
            )
            assert_equal(failed_scope_change["hashrate"], 0)

            self.log.info(
                "A normal unlock resumes the worker without setpowmining"
            )
            wallet.walletpassphrase(POW_WALLET_PASSPHRASE, 600, False)
            self.wait_until(worker_resumed_or_safely_waiting, timeout=60)
            running = wallet.getpowmininginfo()
            assert_worker_resumed_or_safely_waiting(running)
            assert_equal(running["threads"], 1)
            assert_equal(running["cpu_percent"], 1)
            assert_equal(running["payout_address"], payout)
            assert_equal(
                {entry["address"] for entry in wallet.listquantumaddresses()},
                quantum_addresses_before,
            )

            self.log.info("Relock and a second normal unlock retain one configured worker")
            wallet.walletlock()
            relocked = wallet.getpowmininginfo()
            assert_equal(wallet.getwalletinfo()["unlocked_until"], 0)
            assert_equal(relocked["enabled"], True)
            assert_equal(relocked["threads"], 1)
            assert_equal(relocked["cpu_percent"], 1)
            assert_equal(relocked["state"], "wallet_locked_or_staking_only")
            assert_equal(relocked["hashrate"], 0)
            assert_equal(relocked["payout_address"], payout)
            time.sleep(0.25)
            relocked_stable = wallet.getpowmininginfo()
            assert_equal(relocked_stable["enabled"], True)
            assert_equal(
                relocked_stable["state"], "wallet_locked_or_staking_only"
            )
            assert_equal(relocked_stable["hashrate"], 0)
            assert_equal(relocked_stable["payout_address"], payout)

            wallet.walletpassphrase(POW_WALLET_PASSPHRASE, 600, False)
            self.wait_until(worker_resumed_or_safely_waiting, timeout=60)
            resumed = wallet.getpowmininginfo()
            assert_worker_resumed_or_safely_waiting(resumed)
            assert_equal(resumed["threads"], 1)
            assert_equal(resumed["cpu_percent"], 1)
            assert_equal(resumed["payout_address"], payout)
            assert_equal(
                {entry["address"] for entry in wallet.listquantumaddresses()},
                quantum_addresses_before,
            )

            self.log.info("Timed relock publishes the same synchronous paused state")
            wallet.walletpassphrase(POW_WALLET_PASSPHRASE, 1, False)
            self.wait_until(
                lambda: wallet.getwalletinfo()["unlocked_until"] == 0,
                timeout=10,
            )
            timed_relock = wallet.getpowmininginfo()
            assert_equal(timed_relock["enabled"], True)
            assert_equal(timed_relock["threads"], 1)
            assert_equal(timed_relock["cpu_percent"], 1)
            assert_equal(
                timed_relock["state"], "wallet_locked_or_staking_only"
            )
            assert_equal(timed_relock["hashrate"], 0)
            assert_equal(timed_relock["payout_address"], payout)
            time.sleep(0.25)
            timed_relock_stable = wallet.getpowmininginfo()
            assert_equal(
                timed_relock_stable["state"],
                "wallet_locked_or_staking_only",
            )
            assert_equal(timed_relock_stable["hashrate"], 0)

            wallet.walletpassphrase(POW_WALLET_PASSPHRASE, 600, False)
            self.wait_until(worker_resumed_or_safely_waiting, timeout=60)
            timed_relock_resumed = wallet.getpowmininginfo()
            assert_worker_resumed_or_safely_waiting(timed_relock_resumed)
            assert_equal(timed_relock_resumed["threads"], 1)
            assert_equal(timed_relock_resumed["cpu_percent"], 1)
            assert_equal(timed_relock_resumed["payout_address"], payout)

            self.log.info("An explicit runtime stop remains authoritative after later unlocks")
            stopped_result = wallet.setpowmining(False)
            assert_equal(stopped_result["enabled"], False)
            wallet.walletlock()
            wallet.walletpassphrase(POW_WALLET_PASSPHRASE, 600, False)
            stopped = wallet.getpowmininginfo()
            assert_equal(stopped["enabled"], False)
            assert_equal(stopped["state"], "disabled")
            assert_equal(stopped["hashrate"], 0)
            assert_equal(stopped["payout_address"], payout)
            assert_equal(
                {entry["address"] for entry in wallet.listquantumaddresses()},
                quantum_addresses_before,
            )
        finally:
            try:
                if wallet_name in node.listwallets():
                    wallet = node.get_wallet_rpc(wallet_name)
                    if wallet.getpowmininginfo()["enabled"]:
                        wallet.setpowmining(False)
                    node.unloadwallet(wallet_name, False)
            finally:
                self.restart_node(0, extra_args=self.extra_args[0])
                node = self.nodes[0]
                self.connect_nodes(0, 1)
                for name in originally_loaded:
                    if name not in node.listwallets():
                        node.loadwallet(name, False)
                self._sync_mocktime_to_tip()

    def _assert_pow_claim_from_non_whitelisted_address(self):
        if not self.is_wallet_compiled():
            self.log.info("Skipping PoW claim wallet test: wallet not compiled")
            return

        node = self.nodes[0]
        self.log.info("Activating reachable Shadow Gold Rush window")
        self.generatetoaddress(node, 1, node.get_deterministic_priv_key().address, sync_fun=self.no_op)
        self.sync_blocks()

        wallet_name = "goldrush_pow"
        node.createwallet(wallet_name=wallet_name)
        wallet = node.get_wallet_rpc(wallet_name)
        cli_wallet_name = "goldrush_pow_cli"
        node.createwallet(wallet_name=cli_wallet_name)
        cli_rpc_wallet = node.get_wallet_rpc(cli_wallet_name)

        self.log.info("Optional wallet automation is visible and fail-closed by default")
        staking_info = wallet.getstakinginfo()
        assert_equal(staking_info["autostart_staking"], False)
        assert_equal(staking_info["autostart_staking_source"], "autostartstaking")
        assert_equal(staking_info["automatic_qqsignal"], False)
        assert_equal(staking_info["automatic_demurrage_attestation"], False)
        assert_equal(staking_info["automatic_redelegation"], False)
        assert_equal(staking_info["allow_automatic_quantum_key_creation"], False)
        assert_equal(staking_info["consensus_demurrage_automatic"], True)
        pow_info = wallet.getpowmininginfo()
        assert_equal(pow_info["autostart"], False)
        assert_equal(pow_info["allow_automatic_quantum_key_creation"], False)
        assert_equal(pow_info["current_height"], node.getblockcount())
        assert_equal(pow_info["shadow_reward_next_height"], node.getblockcount() + 1)
        assert pow_info["shadow_reward_start_height"] <= pow_info["shadow_reward_next_height"]
        assert pow_info["shadow_reward_next_height"] <= pow_info["shadow_reward_end_height"]
        pow_help = wallet.help("setpowmining")
        assert "allow_new_payout_key" in pow_help
        assert "Back up the wallet immediately" in pow_help

        rpc_target = wallet.getnewaddress()
        cli_target = cli_rpc_wallet.getnewaddress()
        self._generate_with_peer_offline(node, 101, rpc_target)
        self._generate_with_peer_offline(node, 101, cli_target)
        self._sync_mocktime_to_tip()

        self.log.info("Checking miner work RPC for a non-whitelisted PoW target")
        rpc_quantum = wallet.getnewquantumaddress()["address"]
        work = node.getshadowpowwork(rpc_target, rpc_quantum)
        assert_equal(work["active"], True)
        assert_equal(work["prefix"], "QQSPROOF")
        assert_equal(work["proof_mode"], "pow")
        assert_equal(work["proof_mode_byte"], 0)
        assert "target_whitelisted" not in work
        assert "target_script" in work
        assert_equal(work["quantum_address"], rpc_quantum)
        assert_equal(work["quantum_payout_script"], node.validateaddress(rpc_quantum)["scriptPubKey"])

        legacy_payout = wallet.getnewaddress("", "legacy")
        assert_raises_rpc_error(-5, "quantum_address must be a Blackcoin migration address", node.getshadowpowwork, rpc_target, legacy_payout)
        assert_raises_rpc_error(-5, "quantum_address must be a Blackcoin migration address", wallet.sendshadowpowclaim, rpc_target, legacy_payout, 1)

        help_text = node.help("getshadowpowwork")
        assert "not whitelist-gated" in help_text
        assert "target_whitelisted" not in help_text
        assert "quantum_payout_script" in help_text

        wallet_help = wallet.help("sendshadowpowclaim")
        assert "PoW claims are NOT whitelist-gated" in wallet_help
        assert "Quantum migration address" in wallet_help
        assert "QQP2/QQP3 do not bind an exact fee input" in wallet_help
        assert "Never reuse one externally supplied proof" in wallet_help
        assert "proof" in wallet_help

        self.log.info("Rejecting invalid built-in PoW miner configuration")
        assert_raises_rpc_error(-4, "threads must be between 1 and 256", wallet.setpowmining, True, 0, 10)
        assert_raises_rpc_error(-4, "cpu_percent must be between 1 and 100", wallet.setpowmining, True, 1, 101)
        assert_equal(wallet.getpowmininginfo()["enabled"], False)

        # Exercise the real startup path while the Gold Rush epoch is active.
        # The lifecycle restarts node 0, so reacquire every process-bound RPC
        # proxy before continuing this wallet's claim scenario.
        self._assert_builtin_pow_miner_lifecycle()
        node = self.nodes[0]
        wallet = node.get_wallet_rpc(wallet_name)
        cli_rpc_wallet = node.get_wallet_rpc(cli_wallet_name)

        # A fast test worker may find a claim while lifecycle telemetry is
        # sampled. Move past its inclusive origin window before constructing
        # the independent manual family below.
        if self._mempool_pow_claims(node):
            self.log.info("Advancing the tip past a claim found by the lifecycle worker")
            self._generate_with_peer_offline(
                node,
                QQP3_LATE_ORIGIN_WINDOW + 1,
                node.get_deterministic_priv_key().address,
            )
            self._sync_mocktime_to_tip()
        assert_equal(self._mempool_pow_claims(node), [])

        self.disconnect_nodes(0, 1)

        self.log.info("Broadcasting non-whitelisted PoW claim via RPC")
        claim_origin_height = node.getblockcount() + 1
        stale_claim = wallet.sendshadowpowclaim(rpc_target, rpc_quantum, 200000)
        assert_equal(stale_claim["address"], rpc_target)
        assert_equal(stale_claim["quantum_address"], rpc_quantum)
        assert_equal(stale_claim["external_proof"], False)
        assert_equal(stale_claim["proof_mode"], "pow")
        assert_equal(stale_claim["proof_mode_byte"], 0)
        assert stale_claim["proof"].startswith(QQSPROOF_HEX)
        assert stale_claim["txid"] in node.getrawmempool()
        rpc_decoded = node.decoderawtransaction(stale_claim["hex"])
        assert_equal(len(rpc_decoded["vin"]), 1)
        stale_anchor = {
            "txid": rpc_decoded["vin"][0]["txid"],
            "vout": rpc_decoded["vin"][0]["vout"],
        }
        assert any(QQSPROOF_HEX in vout["scriptPubKey"]["hex"] for vout in rpc_decoded["vout"])
        assert all(vout["scriptPubKey"].get("address") != rpc_quantum for vout in rpc_decoded["vout"] if "scriptPubKey" in vout)
        proof_mismatch_error = "proof does not match the current tip, target address, quantum payout address, and PoW channel"
        # The typed gate correctly refuses any second construction in the
        # wallet that already owns the live claim. Exercise malformed external
        # proofs through the separately funded claim-free CLI wallet so the
        # parser assertions remain independent of that stronger gate.
        validation_quantum = cli_rpc_wallet.getnewquantumaddress()["address"]
        assert_raises_rpc_error(
            -8,
            proof_mismatch_error,
            cli_rpc_wallet.sendshadowpowclaim,
            cli_target,
            validation_quantum,
            1,
            None,
            QQSPROOF_HEX + "00",
        )
        pos_proof = bytearray.fromhex(stale_claim["proof"])
        pos_proof[len(bytes.fromhex(QQSPROOF_HEX)) + 4] = 1
        assert_raises_rpc_error(
            -8,
            "proof encodes PoS mode; fee-paying QQSPROOF claims require PoW mode byte 0",
            cli_rpc_wallet.sendshadowpowclaim,
            cli_target,
            validation_quantum,
            1,
            None,
            pos_proof.hex(),
        )
        unknown_proof = bytearray.fromhex(stale_claim["proof"])
        unknown_proof[len(bytes.fromhex(QQSPROOF_HEX)) + 4] = 0x7f
        assert_raises_rpc_error(
            -8,
            "proof encodes an unknown mode; fee-paying QQSPROOF claims require PoW mode byte 0",
            cli_rpc_wallet.sendshadowpowclaim,
            cli_target,
            validation_quantum,
            1,
            None,
            unknown_proof.hex(),
        )
        stolen_quantum = cli_rpc_wallet.getnewquantumaddress()["address"]
        assert_raises_rpc_error(
            -8,
            proof_mismatch_error,
            cli_rpc_wallet.sendshadowpowclaim,
            cli_target,
            stolen_quantum,
            1,
            None,
            stale_claim["proof"],
        )
        self.log.info("The typed gate rejects a second fee-paying carrier for the live QQP3 family")
        assert_raises_rpc_error(
            -4,
            "waiting for an existing live claim",
            wallet.sendshadowpowclaim,
            rpc_target,
            rpc_quantum,
            1,
            None,
            stale_claim["proof"],
        )
        assert_equal(self._mempool_pow_claims(node), [stale_claim["txid"]])

        self.log.info("Expiring QQP3 relay residence after one hour without releasing its input")
        # Residence expiry does not revoke exact-byte relay authority while
        # the active-chain clock still permits this proof. Hold wallet
        # broadcast explicitly so maintenance cannot re-admit it between the
        # absence and recovery-graph observations below.
        node = self._restart_wallet_broadcast(False, reconnect_peer=False)
        wallet = node.get_wallet_rpc(wallet_name)
        cli_rpc_wallet = node.get_wallet_rpc(cli_wallet_name)
        assert_equal(node.getrawtransaction(stale_claim["txid"]), stale_claim["hex"])
        claim_entry_time = node.getmempoolentry(stale_claim["txid"])["time"]
        node.setmocktime(claim_entry_time + QQSPROOF_MEMPOOL_TTL_SECONDS + 1)
        node.mockscheduler(60)
        self.wait_until(
            lambda: stale_claim["txid"] not in node.getrawmempool(),
            timeout=10,
        )
        node.syncwithvalidationinterfacequeue()
        self._assert_qqp3_recovery_age(
            wallet, stale_claim["txid"], 0, expect_in_mempool=False
        )

        self.log.info("Keeping the timed-out claim reserved through every bounded late-origin height")
        stale_parent = node.getbestblockhash()

        # First advance the claim-aware node with an explicitly empty block,
        # then replace that sibling with a two-block peer branch. This covers
        # ages 1 and 2 while retaining the original reorg assertion.
        self.generateblock(
            node,
            output=node.get_deterministic_priv_key().address,
            transactions=[],
            sync_fun=self.no_op,
        )
        node.syncwithvalidationinterfacequeue()
        self._assert_qqp3_recovery_age(
            wallet, stale_claim["txid"], 1, expect_in_mempool=False
        )
        self.generatetoaddress(
            self.nodes[1],
            2,
            self.nodes[1].get_deterministic_priv_key().address,
            sync_fun=self.no_op,
        )
        self.connect_nodes(0, 1)
        self.sync_blocks()
        assert node.getbestblockhash() != stale_parent
        self._assert_qqp3_recovery_age(
            wallet, stale_claim["txid"], 2, expect_in_mempool=False
        )

        reloaded_after_logical_expiry = False
        for origin_age in range(3, QQP3_LATE_ORIGIN_WINDOW + 1):
            self.generateblock(
                node,
                output=node.get_deterministic_priv_key().address,
                transactions=[],
                sync_fun=self.no_op,
            )
            node.syncwithvalidationinterfacequeue()
            self._assert_qqp3_recovery_age(
                wallet,
                stale_claim["txid"],
                origin_age,
                expect_in_mempool=False,
            )
            if not reloaded_after_logical_expiry:
                recovery = wallet.getpowclaimrecoveryinfo(True)
                component = next(
                    item
                    for item in recovery["component_details"]
                    if stale_claim["txid"] in item["claim_txids"]
                )
                claim_node = next(
                    item
                    for item in component["nodes"]
                    if item["txid"] == stale_claim["txid"]
                )
                if claim_node["relay_ttl_expired"]:
                    self.log.info(
                        "Wallet reload cannot restore relay authority after the active chain clock crosses the schema frontier"
                    )
                    # Restore normal broadcast as part of the reload: the
                    # expired chain-clock authority, not our observation
                    # hold, must now keep these exact bytes absent.
                    node = self._restart_wallet_broadcast(True, reconnect_peer=True)
                    wallet = node.get_wallet_rpc(wallet_name)
                    cli_rpc_wallet = node.get_wallet_rpc(cli_wallet_name)
                    node.syncwithvalidationinterfacequeue()
                    assert stale_claim["txid"] not in node.getrawmempool()
                    self._assert_qqp3_recovery_age(
                        wallet,
                        stale_claim["txid"],
                        origin_age,
                        expect_in_mempool=False,
                    )
                    reloaded_after_logical_expiry = True

        assert_equal(reloaded_after_logical_expiry, True)

        self.log.info("Expiring the lineaged QQP3 origin while preserving its family anchor")
        assert_equal(
            node.getblockcount(),
            claim_origin_height + QQP3_LATE_ORIGIN_WINDOW - 1,
        )
        self.generateblock(
            node,
            output=node.get_deterministic_priv_key().address,
            transactions=[],
            sync_fun=self.no_op,
        )
        node.syncwithvalidationinterfacequeue()
        self.wait_until(lambda: stale_claim["txid"] not in node.getrawmempool(), timeout=10)
        stale_accept = node.testmempoolaccept([stale_claim["hex"]])[0]
        assert_equal(stale_accept["allowed"], False)
        assert_equal(stale_accept["reject-reason"], "shadow-proof-origin-expired")
        expired_info = wallet.getpowclaimrecoveryinfo(True)
        expired_component = next(
            component
            for component in expired_info["component_details"]
            if stale_claim["txid"] in component["claim_txids"]
        )
        expired_node = next(
            graph_node
            for graph_node in expired_component["nodes"]
            if graph_node["txid"] == stale_claim["txid"]
        )
        assert_equal(expired_node["disposition"], "origin_expired")
        assert_equal(expired_node["in_mempool"], False)
        assert_equal(expired_node["quarantined"], True)
        assert_equal(expired_component["classification"], "terminal_on_pinned_tip")
        preserved_snapshot = self._assert_lineaged_origin_expired_family(
            wallet,
            stale_claim["txid"],
            stale_anchor,
            rpc_target,
        )

        self.log.info("The wallet scheduler does not retire an authenticated lineage family")
        node.mockscheduler(60)
        node.syncwithvalidationinterfacequeue()
        self._assert_lineaged_origin_expired_family(
            wallet,
            stale_claim["txid"],
            stale_anchor,
            rpc_target,
            expected_snapshot=preserved_snapshot,
        )

        self.log.info("Same-anchor preservation and the typed refresh decision survive reload")
        node.unloadwallet(wallet_name)
        node.loadwallet(wallet_name)
        wallet = node.get_wallet_rpc(wallet_name)
        node.syncwithvalidationinterfacequeue()
        self._assert_lineaged_origin_expired_family(
            wallet,
            stale_claim["txid"],
            stale_anchor,
            rpc_target,
            expected_snapshot=preserved_snapshot,
        )

        if self.is_cli_compiled():
            self.log.info("Checking miner work and broadcasting non-whitelisted PoW claim via CLI")
            cli_quantum = cli_rpc_wallet.getnewquantumaddress()["address"]
            cli_work = node.cli.getshadowpowwork(cli_target, cli_quantum)
            assert_equal(cli_work["prefix"], "QQSPROOF")
            assert_equal(cli_work["proof_mode"], "pow")
            assert_equal(cli_work["proof_mode_byte"], 0)
            assert "target_whitelisted" not in cli_work
            assert_equal(cli_work["quantum_address"], cli_quantum)
            assert_equal(cli_work["quantum_payout_script"], node.validateaddress(cli_quantum)["scriptPubKey"])

            cli_wallet = node.cli("-rpcwallet={}".format(cli_wallet_name))
            cli_claim = cli_wallet.sendshadowpowclaim(cli_target, cli_quantum, 200000)
            assert_equal(cli_claim["address"], cli_target)
            assert_equal(cli_claim["quantum_address"], cli_quantum)
            assert_equal(cli_claim["external_proof"], False)
            assert_equal(cli_claim["proof_mode"], "pow")
            assert_equal(cli_claim["proof_mode_byte"], 0)
            assert cli_claim["proof"].startswith(QQSPROOF_HEX)
            assert cli_claim["txid"] in node.getrawmempool()

        # The lifecycle wallet can legitimately retain a quarantined claim if
        # its fast test miner found a proof above.  That safety state has
        # higher priority than the epoch state because its fee input remains
        # reserved.  Use a separately funded wallet so this check tests the
        # inactive-epoch state without depending on whether the earlier
        # probabilistic miner happened to find a proof.
        inactive_wallet_name = "goldrush_pow_inactive"
        node.createwallet(wallet_name=inactive_wallet_name)
        inactive_wallet = node.get_wallet_rpc(inactive_wallet_name)
        inactive_target = inactive_wallet.getnewaddress()
        wallet.sendtoaddress(inactive_target, 1)
        self._generate_with_peer_offline(
            node,
            1,
            node.get_deterministic_priv_key().address,
        )
        assert_equal(len(inactive_wallet.listunspent(1, 9999999, [inactive_target])), 1)
        inactive_payout = inactive_wallet.getnewquantumaddress("PoW - Quantum Claim Address")["address"]

        self.log.info("An enabled miner reports epoch_inactive after the Gold Rush height window")
        remaining = GOLD_RUSH_END_HEIGHT - node.getblockcount()
        if remaining > 0:
            self._generate_with_peer_offline(node, remaining, node.get_deterministic_priv_key().address)
        try:
            started = inactive_wallet.setpowmining(True, 1, 100)
            assert_equal(started["created_payout_key"], False)
            assert_equal(started["payout_address"], inactive_payout)
            self.wait_until(
                lambda: inactive_wallet.getpowmininginfo()["state"] == "epoch_inactive",
                timeout=10,
            )
            inactive = inactive_wallet.getpowmininginfo()
            assert_equal(inactive["enabled"], True)
            assert_equal(inactive["state"], "epoch_inactive")
            assert_equal(inactive["epoch_active"], False)
            assert_equal(inactive["quarantined_claims"], 0)
            assert_equal(inactive["hashrate"], 0)
        finally:
            inactive_wallet.setpowmining(False)
        assert_equal(inactive_wallet.getpowmininginfo()["state"], "disabled")

    def run_test(self):
        node = self.nodes[0]
        self.log.info("Testing getgoldrushstate...")

        info = node.getgoldrushstate()
        assert "pow_amount" in info
        assert "pos_amount" in info
        assert "pow_count" in info
        assert "pos_count" in info
        assert "last_pow_height" in info
        assert "last_pos_height" in info
        assert "recent_count" in info
        assert "pow_target_bits" in info
        assert_equal(info["competing_claim_rule_activation_height"], 2)
        assert_equal(info["competing_claim_rule_active"], info["height"] >= 2)
        assert_equal(info["competing_claim_rule_active_next_block"], info["height"] + 1 >= 2)
        assert_equal(info["blocks_until_competing_claim_rule"], max(0, 2 - info["height"]))

        # Verify pow_target_bits is a valid positive integer
        assert isinstance(info["pow_target_bits"], int)
        assert info["pow_target_bits"] >= 0

        if self.is_wallet_compiled():
            self.log.info("Testing wallet getgoldrushinfo...")
            node.createwallet(wallet_name="goldrush")
            wallet_info = node.get_wallet_rpc("goldrush").getgoldrushinfo()
            assert "wallet_recent_solve_qualified" in wallet_info
            assert "wallet_scripts" in wallet_info
            assert "pow_amount" in wallet_info
            assert "pos_amount" in wallet_info
            assert_equal(wallet_info["competing_claim_rule_activation_height"], 2)
            assert_equal(wallet_info["competing_claim_rule_active"], wallet_info["height"] >= 2)
            assert_equal(wallet_info["competing_claim_rule_active_next_block"], wallet_info["height"] + 1 >= 2)
            assert_equal(wallet_info["blocks_until_competing_claim_rule"], max(0, 2 - wallet_info["height"]))

        self._assert_pow_claim_from_non_whitelisted_address()

        self.log.info("Tests successful!")

if __name__ == '__main__':
    GoldRushInfoTest().main()
