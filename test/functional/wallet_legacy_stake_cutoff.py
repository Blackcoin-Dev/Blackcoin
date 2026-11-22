#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""The wallet never creates a legacy-return coinstake that cannot be spent before Final.

Regtest: Gold Rush ends at G=61, Migration ends at M=91 (first Final block F=92),
maturity 10. A legacy coinstake created at height h can be spent from h + 10 and
Final rejects every legacy input, so one created after M - 10 loses principal and
reward for good. The last legacy-return height is M - 11 = 80, leaving that coinstake a
full block of migration time. From 81 a legacy kernel is paid to a quantum output (see
wallet_legacy_stake_quantum_return.py); THIS test keeps the refusal fallback: with no
quantum stake return address the wallet builds no legacy coinstake in that window.

Also checks that migratetoquantum includes an output that matures exactly in the
last Migration block (it used to be one block more conservative than consensus),
and that getstakinginfo and getmigrationstatus say plainly when legacy staking stops.
"""
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal
from transition_t_final_util import (
    F,
    G,
    LAST_LEGACY_STAKE_HEIGHT,
    LIFECYCLE_ARGS,
    M,
    MATURITY,
    TransitionTFinalTestBase,
)


class LegacyStakeCutoffTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        # Automatic key creation is off, so the wallet cannot ready a quantum stake return
        # address by itself and the refusal fallback is what is tested.
        self.extra_args = [[a for a in LIFECYCLE_ARGS if not a.startswith("-qqallowautokeycreation")]]

    def check_notice_fields(self, wallet, next_height):
        info = wallet.getstakinginfo()
        assert_equal(info["legacy_staking_scheduled"], True)
        assert_equal(info["legacy_staking_last_height"], LAST_LEGACY_STAKE_HEIGHT)
        assert_equal(info["legacy_migration_end_height"], M)
        remaining = max(0, LAST_LEGACY_STAKE_HEIGHT - next_height + 1)
        assert_equal(info["legacy_staking_blocks_remaining"], remaining)
        assert_equal(info["legacy_staking_window_start_height"], LAST_LEGACY_STAKE_HEIGHT + 1)
        assert_equal(info["legacy_stake_return_ready"], False)
        # Legacy staking is stopped only while it is in the window with no ready return address.
        assert_equal(info["legacy_staking_stopped"], next_height > LAST_LEGACY_STAKE_HEIGHT)
        notice = info["legacy_staking_notice"]
        assert f"height {LAST_LEGACY_STAKE_HEIGHT + 1}" in notice, notice
        assert "NOT READY" in notice, notice
        assert f"height {F}" in notice, notice
        assert "igrate" in notice, notice
        status = wallet.getmigrationstatus()
        assert_equal(status["legacy_staking_last_height"], LAST_LEGACY_STAKE_HEIGHT)
        assert_equal(status["legacy_staking_notice"], notice)
        return info

    def run_test(self):
        node = self.nodes[0]
        wallet = node.get_wallet_rpc(self.default_wallet_name)
        wallet.staking(False)
        self.set_initial_mt()

        stake_addr = wallet.getnewaddress("", "legacy")
        pow_addr = wallet.getnewaddress("", "legacy")
        boundary_addr = wallet.getnewaddress("", "legacy")

        self.log.info("Boundary heights: G=%d M=%d F=%d, last legacy stake height %d", G, M, F, LAST_LEGACY_STAKE_HEIGHT)
        assert_equal(LAST_LEGACY_STAKE_HEIGHT, 80)

        self.generatetoaddress(node, MATURITY + 14, stake_addr)
        self.sync_mt_tip()
        self.pow_blocks(node, 70 - node.getblockcount(), pow_addr)
        assert_equal(node.getblockcount(), 70)
        assert_equal(node.getquantumquasarinfo()["phase"], "migration")

        self.log.info("Well before the cutoff the status already names the stop height and the migration need")
        self.check_notice_fields(wallet, next_height=71)

        self.log.info("Legacy staking works up to and including the last allowed height")
        self.pow_blocks(node, 78 - node.getblockcount(), pow_addr)
        for expected_height in (LAST_LEGACY_STAKE_HEIGHT - 1, LAST_LEGACY_STAKE_HEIGHT):
            block_hash = self.stake_one(wallet, node, [stake_addr])
            block = node.getblock(block_hash, 2)
            assert_equal(block["height"], expected_height)
            outputs = [o for o in block["tx"][1]["vout"] if o["value"] > 0]
            assert outputs and all(o["scriptPubKey"]["type"] == "pubkey" for o in outputs)
        assert_equal(node.getblockcount(), LAST_LEGACY_STAKE_HEIGHT)
        info = self.check_notice_fields(wallet, next_height=LAST_LEGACY_STAKE_HEIGHT + 1)
        assert_equal(info["legacy_staking_stopped"], True)
        assert "NOT READY" in info["legacy_staking_notice"]
        assert "will not stake legacy coins" in info["legacy_staking_notice"]

        self.log.info("From the next height the wallet offers no legacy stake weight and creates no legacy coinstake")
        # Mature legacy kernels exist (the wallet simply refuses to use them).
        assert len(self.stake_inputs(wallet, [stake_addr])) > 0
        wallet.staking(True)
        # The worker sets "searching" at the top of every iteration and "no_eligible_coins" only while a search
        # slot of that iteration runs, so with a mock clock that does not move the second state is visible for
        # one short moment: do not poll for it. The snapshot being current at this tip is the stable sign that
        # the worker has looked at the wallet.
        self.wait_until(lambda: wallet.getstakinginfo()["staking_snapshot_current"], timeout=60)
        info = wallet.getstakinginfo()
        assert info["staking_state"] in ("searching", "no_eligible_coins"), info["staking_state"]
        assert_equal(info["eligible"], False)
        assert_equal(info["weight"], 0)
        for _ in range(12):
            self.bump()
        # Give the staker time to run its slots, then confirm nothing was created.
        self.wait_until(lambda: wallet.getstakinginfo()["staking_snapshot_current"], timeout=60)
        assert_equal(node.getblockcount(), LAST_LEGACY_STAKE_HEIGHT)
        wallet.staking(False)

        self.log.info("An output that matures exactly in the last Migration block is migrated in it")
        boundary_hash = self.generatetoaddress(node, 1, boundary_addr)[0]
        self.bump()
        boundary_height = node.getblockcount()
        assert_equal(boundary_height, M - MATURITY)
        boundary_txid = node.getblock(boundary_hash)["tx"][0]
        self.pow_blocks(node, M - 1 - node.getblockcount(), pow_addr)
        assert_equal(node.getblockcount(), M - 1)
        # Consensus accepts the spend in block M (depth equals the maturity).
        quantum_address = wallet.getnewquantumaddress()["address"]
        dry = wallet.migratetoquantum({"dry_run": True, "existing_address": quantum_address})
        migrated = wallet.migratetoquantum({"existing_address": quantum_address})
        assert_equal(migrated["more_batches"], False)
        migration_tx = node.getrawtransaction(migrated["txid"], True)
        spent = {(vin["txid"], vin["vout"]) for vin in migration_tx["vin"]}
        assert (boundary_txid, 0) in spent, "the output maturing in block M was left out of the migration"
        assert_equal(dry["eligible_inputs"], migrated["eligible_inputs"])
        self.pow_blocks(node, 1, pow_addr)
        assert_equal(node.getblockcount(), M)
        assert node.getrawtransaction(migrated["txid"], True, node.getbestblockhash())["confirmations"] == 1
        assert_equal(node.gettxout(boundary_txid, 0), None)

        self.log.info("In Final the notice is gone and legacy coins are locked")
        self.generatetoaddress(node, 1, quantum_address)
        info = wallet.getstakinginfo()
        assert "legacy_staking_notice" not in info
        assert_equal(info["legacy_staking_stopped"], True)
        assert_equal(node.getquantumquasarinfo()["phase"], "final_lockout")

        self.log.info("Final with a ready return address: legacy staking is still reported as stopped, outside the window")
        # (The old status said "not stopped" for a wallet with a ready return address, though Final rejects
        # every legacy kernel.)
        assert_equal(wallet.setquantumstakereturn({"allow_new_quantum_key": True})["ready"], True)
        for status in (wallet.getstakinginfo(), wallet.getmigrationstatus()):
            assert_equal(status["legacy_stake_return_ready"], True)
            assert_equal(status["legacy_staking_in_window"], False)
            assert_equal(status["legacy_staking_stopped"], True)


if __name__ == '__main__':
    LegacyStakeCutoffTest().main()
