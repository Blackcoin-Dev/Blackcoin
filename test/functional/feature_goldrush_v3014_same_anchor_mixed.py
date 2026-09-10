#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Exercise candidate same-anchor claims with exact v30.1.4 concurrently.

The candidate authors a QQP3 root and, after the root's origin window expires,
one lineaged same-anchor QQP3 sibling.  The exact v30.1.4 daemon independently
accepts the sibling on the same tip, receives the exact bytes over P2P, and
includes them in a wallet-produced PoS block.  Both versions persist the same
base-chain bytes across isolated restart.  A longer candidate branch then
reorganizes both implementations off the claim block, removes the synthetic
payout, and returns the still-valid sibling to both mempools.  Exact v30.1.4
mines that carrier again on the winning branch, and a final restart reproduces
the shared tip and candidate recovery state.

This is a protocol and storage compatibility test.  It does not claim that
v30.1.4 understands the candidate's typed wallet-family mining policy.
"""

from decimal import Decimal
import importlib.util
import os
from pathlib import Path
import tempfile
import time

from test_framework.blocktools import COINBASE_MATURITY
from test_framework.messages import CTransaction, from_hex, msg_tx
from test_framework.p2p import P2PDataStore
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal


V30_1_4_VERSION = 300104
CANDIDATE_VERSION = 300105
REQUIRED_HISTORICAL_VERSIONS = ["v30.1.4"]
V30_1_4 = 0
CANDIDATE = 1
CLAIM_WALLET = "v3014_same_anchor_claimant"
QQP3_LATE_ORIGIN_WINDOW = 64
QQSPROOF = b"QQSPROOF"
GOLD_RUSH_END_TIME = 2_000_000_000


class GoldRushV3014SameAnchorMixedTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser, descriptors=True, legacy=False)

    def set_test_params(self):
        self.num_nodes = 2
        self.setup_clean_chain = True
        self.base_args = [
            "-allowunsafequantumkeyrpc=1",
            "-autostartstaking=0",
            "-powmining=0",
            "-staketimio=50",
            "-txindex=1",
            "-shadowindex=1",
            "-shadowwhitelistheight=1",
            "-shadowgoldrushblocks=1000",
            "-shadowcompetingclaimsheight=2",
            f"-qqgoldrushendtime={GOLD_RUSH_END_TIME}",
        ]
        self.extra_args = [list(self.base_args), list(self.base_args)]

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
        with tempfile.TemporaryDirectory(prefix="v3014-same-anchor-provenance-") as scratch:
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
            versions=[V30_1_4_VERSION, None],
        )
        self.start_nodes()
        self.import_deterministic_coinbase_privkeys()

    def _set_mocktime(self, timestamp):
        self.mock_time = timestamp
        for node in self.nodes:
            node.setmocktime(timestamp)

    def _bump_mocktime(self, seconds=16):
        self._set_mocktime(self.mock_time + seconds)

    def _sync_mocktime_to_tip(self):
        tip_time = max(
            node.getblockheader(node.getbestblockhash())["time"]
            for node in self.nodes
        )
        self._set_mocktime((tip_time & ~0xf) + 16)

    @staticmethod
    def _wallet_claim_txids(wallet):
        return {
            entry["txid"]
            for entry in wallet.listtransactions("*", 1000, 0, True)
            if entry.get("comment") == "PoW Claim"
        }

    @staticmethod
    def _is_abandoned(wallet, txid):
        return any(
            detail.get("abandoned", False)
            for detail in wallet.gettransaction(txid)["details"]
        )

    def _claim_input(self, node, raw_tx):
        decoded = node.decoderawtransaction(raw_tx)
        assert_equal(len(decoded["vin"]), 1)
        return {
            "txid": decoded["vin"][0]["txid"],
            "vout": decoded["vin"][0]["vout"],
        }

    def _claim_scripts(self, node, raw_tx):
        decoded = node.decoderawtransaction(raw_tx)
        payloads = []
        for output in decoded["vout"]:
            script = bytes.fromhex(output["scriptPubKey"]["hex"])
            offset = script.find(QQSPROOF)
            if offset >= 0:
                payloads.append(script[offset:])
        assert_equal(len(payloads), 1)
        proof = payloads[0][len(QQSPROOF):]
        magic = proof[:4]
        context_size = {b"QQP2": 0, b"QQP3": 36, b"QQP4": 72}.get(magic)
        assert context_size is not None, f"unexpected proof version {magic!r}"
        script_header = 13 + context_size
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
    def _component_for_claim(recovery, txid):
        matches = [
            component
            for component in recovery["component_details"]
            if txid in component["claim_txids"]
        ]
        assert_equal(len(matches), 1)
        return matches[0]

    @staticmethod
    def _node_for_claim(component, txid):
        matches = [
            node for node in component["nodes"] if node["txid"] == txid
        ]
        assert_equal(len(matches), 1)
        return matches[0]

    def _wait_shadowindex(self):
        candidate = self.nodes[CANDIDATE]

        def synced():
            status = candidate.getindexinfo().get("shadowindex", {})
            return (
                status.get("synced", False)
                and status.get("best_block_height") == candidate.getblockcount()
            )

        self.wait_until(synced, timeout=60)

    def _staking_inputs(self, wallet):
        return [
            {"txid": utxo["txid"], "vout": utxo["vout"]}
            for utxo in wallet.listunspent(1, 9999999)
        ]

    def _find_next_kernel_time(self, wallet):
        inputs = self._staking_inputs(wallet)
        assert inputs, "exact-version wallet must have mature staking inputs"
        for _ in range(3000):
            self._bump_mocktime(16)
            kernel = wallet.checkkernel(inputs)
            if kernel["found"]:
                return kernel["kernel"]["time"]
        raise AssertionError("timed out searching for an exact v30.1.4 PoS kernel")

    def _mine_pos_block(
        self,
        node_index,
        wallet,
        *,
        expected_txid=None,
        excluded_txid=None,
    ):
        node = self.nodes[node_index]
        last_error = None
        for _ in range(4):
            start_height = node.getblockcount()
            kernel_time = self._find_next_kernel_time(wallet)
            self._set_mocktime(kernel_time - 16)
            wallet.staking(True)
            try:
                self._set_mocktime(kernel_time)
                self.wait_until(
                    lambda: node.getblockcount() > start_height,
                    timeout=30,
                )
                block_hash = node.getbestblockhash()
                block = node.getblock(block_hash, 2)
                assert "proof-of-stake" in block["flags"]
                claim_txids = [tx["txid"] for tx in block["tx"][2:]]
                if expected_txid is not None:
                    assert expected_txid in claim_txids
                if excluded_txid is not None:
                    assert excluded_txid not in claim_txids
                return block_hash
            except AssertionError as error:
                last_error = error
            finally:
                wallet.staking(False)
            self._bump_mocktime(16)
        raise last_error or AssertionError("exact-version PoS mining failed")

    @staticmethod
    def _quantum_utxos(wallet, address):
        return wallet.listunspent(
            0,
            9999999,
            [address],
            True,
            {"include_immature_coinbase": True},
        )

    def _wait_quantum_utxo(self, wallet, address):
        self.wait_until(
            lambda: len(self._quantum_utxos(wallet, address)) == 1,
            timeout=30,
        )
        return self._quantum_utxos(wallet, address)[0]

    def _assert_shared_tip(self, expected_hash):
        assert_equal(
            [node.getbestblockhash() for node in self.nodes],
            [expected_hash, expected_hash],
        )
        raw = self.nodes[V30_1_4].getblock(expected_hash, 0)
        assert_equal(self.nodes[CANDIDATE].getblock(expected_hash, 0), raw)
        return raw

    def _relay_to_node(self, node_index, raw_tx, expected_txid):
        """Deliver candidate-authored bytes through an exact node's P2P path."""
        transaction = from_hex(CTransaction(), raw_tx)
        transaction.rehash()
        assert_equal(transaction.hash, expected_txid)
        node = self.nodes[node_index]
        peer = node.add_p2p_connection(P2PDataStore())
        try:
            peer.send_and_ping(msg_tx(transaction))
            self.wait_until(
                lambda: expected_txid in node.getrawmempool(), timeout=30
            )
        finally:
            node.disconnect_p2ps()

    def run_test(self):
        old = self.nodes[V30_1_4]
        candidate = self.nodes[CANDIDATE]
        self._set_mocktime((int(time.time()) & ~0xf) + 16)
        assert_equal(old.getnetworkinfo()["version"], V30_1_4_VERSION)
        assert_equal(candidate.getnetworkinfo()["version"], CANDIDATE_VERSION)
        for node in self.nodes:
            node.get_wallet_rpc(self.default_wallet_name).staking(False)

        candidate.createwallet(
            wallet_name=CLAIM_WALLET,
            descriptors=True,
            load_on_startup=True,
        )
        claimant = candidate.get_wallet_rpc(CLAIM_WALLET)
        claimant.staking(False)
        old_staker = old.get_wallet_rpc(self.default_wallet_name)
        old_staking_address = old_staker.getnewaddress("v30.1.4 staker", "legacy")
        candidate_staking_address = candidate.get_wallet_rpc(
            self.default_wallet_name
        ).getnewaddress("candidate fork miner", "legacy")

        self.log.info("Building one shared chain with mature inputs on both versions")
        self.generatetoaddress(
            old,
            COINBASE_MATURITY + 2,
            old_staking_address,
            sync_fun=self.no_op,
        )
        self.sync_blocks(self.nodes, timeout=120)
        self.generatetoaddress(
            candidate,
            COINBASE_MATURITY + 2,
            candidate_staking_address,
            sync_fun=self.no_op,
        )
        self.sync_blocks(self.nodes, timeout=120)
        self._sync_mocktime_to_tip()
        assert_equal(candidate.getquantumquasarinfo()["phase"], "gold_rush")

        target_address = claimant.getnewaddress("same-anchor target", "legacy")
        payout_address = claimant.getnewquantumaddress(
            "same-anchor payout"
        )["address"]
        old_staker.sendtoaddress(target_address, Decimal("2.00000000"))
        self._bump_mocktime()
        self.generatetoaddress(
            old, 1, old_staking_address, sync_fun=self.no_op
        )
        self.sync_blocks(self.nodes, timeout=120)
        self._sync_mocktime_to_tip()
        assert_equal(
            len(claimant.listunspent(1, 9999999, [target_address])), 1
        )

        self.log.info("The candidate QQP3 root is independently accepted then relayed to v30.1.4")
        self.disconnect_nodes(CANDIDATE, V30_1_4)
        root = claimant.sendshadowpowclaim(
            target_address, payout_address, 500_000
        )
        root_txid = root["txid"]
        root_raw = root["hex"]
        root_anchor = self._claim_input(candidate, root_raw)
        root_magic, target_script, payout_script = self._claim_scripts(
            candidate, root_raw
        )
        assert_equal(root_magic, b"QQP3")
        assert_equal(
            target_script,
            candidate.validateaddress(target_address)["scriptPubKey"],
        )
        assert_equal(
            payout_script,
            candidate.validateaddress(payout_address)["scriptPubKey"],
        )
        old_accept = old.testmempoolaccept([root_raw])[0]
        assert_equal(old_accept["allowed"], True)
        self._relay_to_node(V30_1_4, root_raw, root_txid)
        assert_equal(old.getrawtransaction(root_txid), root_raw)
        self.connect_nodes(CANDIDATE, V30_1_4)

        self.log.info("Omitting the root until the candidate authorizes same-anchor continuation")
        expired = False
        for _ in range(QQP3_LATE_ORIGIN_WINDOW + 4):
            self._bump_mocktime()
            self.generateblock(
                old,
                output=old_staking_address,
                transactions=[],
                sync_fun=self.no_op,
            )
            self.sync_blocks(self.nodes, timeout=120)
            candidate.syncwithvalidationinterfacequeue()
            recovery = claimant.getpowclaimrecoveryinfo(True)
            component = self._component_for_claim(recovery, root_txid)
            node = self._node_for_claim(component, root_txid)
            if node["disposition"] == "origin_expired":
                expired = True
                break
        assert expired, "candidate QQP3 root did not expire in the bounded origin window"
        self.wait_until(lambda: root_txid not in old.getrawmempool(), timeout=30)
        expired_accept = candidate.testmempoolaccept([root_raw])[0]
        assert_equal(expired_accept["allowed"], False)
        assert_equal(expired_accept["reject-reason"], "shadow-proof-origin-expired")
        self.wait_until(
            lambda: claimant.gettransaction(root_txid).get(
                "qq_shadow_pow_quarantine"
            )
            == "1",
            timeout=30,
        )
        stale = claimant.getpowclaimrecoveryinfo(True)
        stale_component = self._component_for_claim(stale, root_txid)
        assert_equal(stale["database_outcome_ambiguous"], False)
        assert_equal(stale_component["anchor_authenticated"], True)
        assert_equal(stale_component["anchor_unspent"], True)
        assert_equal(stale_component["ordinary_or_mixed_txids"], [])
        stale_gate = claimant.getpowmininginfo()
        assert_equal(stale_gate["mining_gate_action"], "refresh_same_anchor")
        assert_equal(stale_gate["mining_gate_can_submit"], True)

        self.log.info("The candidate creates one lineaged same-anchor carrier while isolated")
        self.disconnect_nodes(CANDIDATE, V30_1_4)
        claims_before = self._wallet_claim_txids(claimant)
        assert_equal(claims_before, {root_txid})
        started = claimant.setpowmining(True, 1, 100)
        assert_equal(started["created_payout_key"], False)
        try:
            self.wait_until(
                lambda: len(self._wallet_claim_txids(claimant) - claims_before)
                == 1,
                timeout=240,
            )
            self.wait_until(
                lambda: claimant.getpowmininginfo()["mining_gate_action"]
                == "wait_for_live",
                timeout=30,
            )
        finally:
            claimant.setpowmining(False)

        sibling_txid = next(
            iter(self._wallet_claim_txids(claimant) - claims_before)
        )
        sibling_raw = candidate.getrawtransaction(sibling_txid)
        sibling_anchor = self._claim_input(candidate, sibling_raw)
        sibling_magic, sibling_target, sibling_payout = self._claim_scripts(
            candidate, sibling_raw
        )
        assert_equal(sibling_anchor, root_anchor)
        assert_equal(sibling_magic, b"QQP3")
        assert_equal(sibling_target, target_script)
        assert_equal(sibling_payout, payout_script)
        sibling_record = claimant.gettransaction(sibling_txid)
        assert_equal(sibling_record["qq_shadow_pow_lineage_schema"], "1")
        assert_equal(sibling_record["qq_shadow_pow_lineage_root"], root_txid)
        assert_equal(sibling_record["qq_shadow_pow_lineage_parent"], root_txid)
        assert_equal(sibling_record["qq_shadow_pow_lineage_ordinal"], "1")

        self.log.info("Exact v30.1.4 independently accepts and then receives those same bytes")
        sibling_accept = old.testmempoolaccept([sibling_raw])[0]
        assert_equal(sibling_accept["allowed"], True)
        self._relay_to_node(V30_1_4, sibling_raw, sibling_txid)
        assert_equal(old.getrawtransaction(sibling_txid), sibling_raw)
        self.connect_nodes(CANDIDATE, V30_1_4)
        assert_equal(
            old.decoderawtransaction(sibling_raw),
            candidate.decoderawtransaction(sibling_raw),
        )

        self.log.info("Exact v30.1.4 mines the candidate carrier in a PoS block")
        claim_block = self._mine_pos_block(
            V30_1_4, old_staker, expected_txid=sibling_txid
        )
        self.sync_blocks(self.nodes, timeout=120)
        claim_block_raw = self._assert_shared_tip(claim_block)
        claim_block_json = old.getblock(claim_block, 2)
        assert "proof-of-stake" in claim_block_json["flags"]
        assert sibling_txid in [tx["txid"] for tx in claim_block_json["tx"][2:]]
        self._wait_shadowindex()
        self.wait_until(
            lambda: claimant.gettransaction(sibling_txid)["confirmations"] > 0,
            timeout=30,
        )
        payout_utxo = self._wait_quantum_utxo(claimant, payout_address)
        assert candidate.gettxout(
            payout_utxo["txid"], payout_utxo["vout"], False
        ) is not None
        for field in (
            "pow_amount",
            "claimed_amount",
            "pow_count",
            "last_pow_height",
        ):
            assert_equal(
                old.getgoldrushstate()[field],
                candidate.getgoldrushstate()[field],
            )

        self.log.info("Both exact versions reload the same claim block in isolation")
        self.disconnect_nodes(CANDIDATE, V30_1_4)
        for index in (V30_1_4, CANDIDATE):
            restart_args = [*self.base_args, f"-mocktime={self.mock_time}"]
            if index == CANDIDATE:
                # Deterministically evict the disconnected carrier before
                # building the competing branch. Disable automatic wallet
                # relay for this isolated fixture phase: mining-disabled
                # retained-byte maintenance otherwise restores the eligible
                # carrier immediately after expiry. The wallet record stays
                # un-abandoned and P2P admission remains enabled.
                restart_args.extend(["-mempoolexpiry=0", "-walletbroadcast=0"])
            self.restart_node(
                index,
                extra_args=restart_args,
            )
            self.nodes[index].setmocktime(self.mock_time)
            assert_equal(self.nodes[index].getbestblockhash(), claim_block)
            assert_equal(self.nodes[index].getblock(claim_block, 0), claim_block_raw)
        candidate = self.nodes[CANDIDATE]
        old = self.nodes[V30_1_4]
        claimant = candidate.get_wallet_rpc(CLAIM_WALLET)
        old_staker = old.get_wallet_rpc(self.default_wallet_name)
        candidate_staker = candidate.get_wallet_rpc(self.default_wallet_name)
        claimant.staking(False)
        old_staker.staking(False)
        candidate_staker.staking(False)
        self.connect_nodes(CANDIDATE, V30_1_4)
        self.sync_blocks(self.nodes, timeout=120)

        self.log.info("A longer candidate branch reorganizes both versions off the claim")
        claim_parent = candidate.getblockheader(claim_block)["previousblockhash"]
        self.disconnect_nodes(CANDIDATE, V30_1_4)
        candidate.invalidateblock(claim_block)
        assert_equal(candidate.getbestblockhash(), claim_parent)
        self.wait_until(
            lambda: sibling_txid in candidate.getrawmempool(), timeout=30
        )
        assert_equal(self._quantum_utxos(claimant, payout_address), [])
        assert candidate.gettxout(
            payout_utxo["txid"], payout_utxo["vout"], False
        ) is None
        entry_time = candidate.getmempoolentry(sibling_txid)["time"]
        self._set_mocktime(max(self.mock_time, entry_time) + 2)
        expiry_trigger = candidate_staker.sendtoaddress(
            candidate_staking_address, Decimal("0.10000000")
        )
        # Wallet broadcasting is disabled only for the competing-branch
        # phase. Explicitly submit this ordinary transaction to trigger expiry
        # without authorizing the claimant to refill the local mempool.
        assert_equal(
            candidate.sendrawtransaction(
                candidate_staker.gettransaction(expiry_trigger)["hex"]
            ),
            expiry_trigger,
        )
        candidate.syncwithvalidationinterfacequeue()
        self.wait_until(
            lambda: sibling_txid not in candidate.getrawmempool(), timeout=30
        )
        assert_equal(self._is_abandoned(claimant, sibling_txid), False)
        competing_blocks = [
            self._mine_pos_block(
                CANDIDATE,
                candidate_staker,
                excluded_txid=sibling_txid,
            )
            for _ in range(2)
        ]
        competing_tip = competing_blocks[-1]
        candidate.reconsiderblock(claim_block)
        assert_equal(candidate.getbestblockhash(), competing_tip)
        candidate_accept = candidate.testmempoolaccept([sibling_raw])[0]
        assert_equal(candidate_accept["allowed"], True)
        self.connect_nodes(CANDIDATE, V30_1_4)
        self.sync_blocks(self.nodes, timeout=120)
        self._assert_shared_tip(competing_tip)
        assert old.getbestblockhash() != claim_block
        self.wait_until(
            lambda: sibling_txid in old.getrawmempool(),
            timeout=30,
        )
        if sibling_txid not in candidate.getrawmempool():
            self._relay_to_node(CANDIDATE, sibling_raw, sibling_txid)
        assert_equal(old.getrawtransaction(sibling_txid), sibling_raw)
        assert_equal(candidate.getrawtransaction(sibling_txid), sibling_raw)
        assert_equal(claimant.gettransaction(sibling_txid)["confirmations"], 0)
        assert_equal(self._is_abandoned(claimant, sibling_txid), False)
        assert_equal(self._quantum_utxos(claimant, payout_address), [])

        self.log.info("v30.1.4 includes the reorged carrier on the winning branch")
        resolved_block = self._mine_pos_block(
            V30_1_4, old_staker, expected_txid=sibling_txid
        )
        self.sync_blocks(self.nodes, timeout=120)
        resolved_raw = self._assert_shared_tip(resolved_block)
        self._wait_shadowindex()
        self.wait_until(
            lambda: claimant.gettransaction(sibling_txid)["confirmations"] > 0,
            timeout=30,
        )
        resolved_payout = self._wait_quantum_utxo(claimant, payout_address)
        assert candidate.gettxout(
            resolved_payout["txid"], resolved_payout["vout"], False
        ) is not None

        self.log.info("Final isolated restarts preserve the reorg winner and safe family")
        self.disconnect_nodes(CANDIDATE, V30_1_4)
        for index in (V30_1_4, CANDIDATE):
            self.restart_node(
                index,
                extra_args=[*self.base_args, f"-mocktime={self.mock_time}"],
            )
            self.nodes[index].setmocktime(self.mock_time)
            assert_equal(self.nodes[index].getbestblockhash(), resolved_block)
            assert_equal(self.nodes[index].getblock(resolved_block, 0), resolved_raw)
        candidate = self.nodes[CANDIDATE]
        claimant = candidate.get_wallet_rpc(CLAIM_WALLET)
        claimant.staking(False)
        self._wait_shadowindex()
        final = claimant.getpowclaimrecoveryinfo(True)
        final_component = self._component_for_claim(final, sibling_txid)
        assert_equal(final["database_outcome_ambiguous"], False)
        assert_equal(
            set(final_component["claim_txids"]),
            {root_txid, sibling_txid},
        )
        assert_equal(final_component["anchor_authenticated"], True)
        assert_equal(final_component["ordinary_or_mixed_txids"], [])
        assert_equal(final_component["resolution_txids"], [])
        assert_equal(
            claimant.gettransaction(sibling_txid)["confirmations"] > 0,
            True,
        )
        final_payout = self._wait_quantum_utxo(claimant, payout_address)
        assert_equal(
            (final_payout["txid"], final_payout["vout"]),
            (resolved_payout["txid"], resolved_payout["vout"]),
        )
        self.connect_nodes(CANDIDATE, V30_1_4)
        self.sync_blocks(self.nodes, timeout=120)
        self._assert_shared_tip(resolved_block)


if __name__ == "__main__":
    GoldRushV3014SameAnchorMixedTest().main()
