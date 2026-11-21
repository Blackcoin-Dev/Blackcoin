#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""The first Final block, shaped like mainnet.

Lifecycle (regtest, maturity 10): Gold Rush ends at G, stake tiers activate at
G + 1, Migration ends at M, and the reward split and demurrage activate at
M + 1 = F, the first Final block. The test drives:

 * a legacy spend that is valid for block M and sits in the mempool when block M
   connects: it is dropped, and legacy spends are rejected from F on;
 * a restart on each side of the boundary;
 * a real self-staked block and a real cold-staked block at height F, each
   paying exactly the reward split (the fixed pie, the operator floor);
 * a competing pair of blocks at F on two disconnected nodes, resolved by a
   longer chain, with the loser's block going stale and both nodes agreeing.
"""
from decimal import Decimal
import time

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal

G = 2
M = 44
F = M + 1
MATURITY = 10
SELF_STAKE_AMOUNT = Decimal("12000")
COLD_STAKE_AMOUNT = Decimal("9000")
BASE_POS_SUBSIDY = Decimal("1.5")
OPERATOR_FLOOR = Decimal("0.075")
VAULT_7D_BLOCKS = 9450


class FirstFinalTransitionTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.setup_clean_chain = True
        self.num_nodes = 2
        args = [
            "-allowunsafequantumkeyrpc=1",
            "-txindex=1",
            "-staketimio=50",
            "-donatetodevfund=0",
            "-shadowwhitelistheight=1",
            "-shadowgoldrushblocks=1",
            f"-qqgoldrushendheight={G}",
            f"-qqmigrationendheight={M}",
            f"-qqstaketierheight={G + 1}",
            f"-qqstakesplitheight={F}",
        ]
        self.extra_args = [args, args]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    # ---- time and block helpers
    def set_mt(self, timestamp):
        self.mock_time = timestamp
        for node in self.nodes:
            node.setmocktime(timestamp)

    def bump(self, seconds=16):
        self.set_mt(self.mock_time + seconds)

    def sync_mt_tip(self):
        tip_time = max(node.getblockheader(node.getbestblockhash())["time"] for node in self.nodes)
        self.set_mt((tip_time & ~0xf) + 16)

    def mine(self, node, count, address, sync=True):
        hashes = []
        for _ in range(count):
            hashes += self.generatetoaddress(node, 1, address, sync_fun=(self.sync_all if sync else self.no_op))
            self.bump()
        return hashes

    def empty_block(self, node, address, sync=True):
        block_hash = self.generateblock(node, address, [], sync_fun=(self.sync_all if sync else self.no_op))["hash"]
        self.bump()
        return block_hash

    def restart_both(self, tag):
        self.log.info("Restart both nodes: %s", tag)
        for i in range(2):
            self.restart_node(i, extra_args=self.extra_args[i] + [f"-mocktime={self.mock_time}"])
        self.connect_nodes(0, 1)
        self.sync_blocks()

    def phase(self, node):
        return node.getquantumquasarinfo()["phase"]

    def script_for(self, node, address):
        return bytes.fromhex(node.validateaddress(address)["scriptPubKey"])

    def stake_one(self, wallet, node, address):
        inputs = [{"txid": u["txid"], "vout": u["vout"]} for u in wallet.listunspent(1, 9999999, [address])]
        assert inputs, "staking wallet must hold mature outputs"
        kernel_time = None
        for _ in range(20000):
            self.bump()
            kernel = wallet.checkkernel(inputs)
            if kernel["found"]:
                kernel_time = kernel["kernel"]["time"]
                break
        assert kernel_time is not None, "no kernel found"
        height_before = node.getblockcount()
        self.set_mt(kernel_time - 16)
        wallet.staking(True)
        try:
            self.set_mt(kernel_time)
            self.wait_until(lambda: node.getblockcount() > height_before, timeout=40)
            block_hash = node.getbestblockhash()
            block = node.getblock(block_hash, 2)
            assert "proof-of-stake" in block["flags"]
            return block_hash, block
        finally:
            wallet.staking(False)

    @staticmethod
    def paid(block_tx, script_bytes):
        return sum(
            (Decimal(str(vout["value"])) for vout in block_tx["vout"]
             if bytes.fromhex(vout["scriptPubKey"]["hex"]) == script_bytes),
            Decimal(0),
        )

    def run_test(self):
        node0, node1 = self.nodes
        self.set_mt((int(time.time()) & ~0xf) + 16)
        for node in self.nodes:
            node.get_wallet_rpc(self.default_wallet_name).staking(False)

        node0.createwallet(wallet_name="funder")
        node0.createwallet(wallet_name="self_staker")
        node1.createwallet(wallet_name="cold_owner")
        node1.createwallet(wallet_name="cold_staker")
        funder = node0.get_wallet_rpc("funder")
        self_staker = node0.get_wallet_rpc("self_staker")
        owner = node1.get_wallet_rpc("cold_owner")
        cold_staker = node1.get_wallet_rpc("cold_staker")
        for wallet in (funder, self_staker, owner, cold_staker):
            wallet.staking(False)

        def reload_wallets():
            # RPC handles do not survive a restart, and the framework does not reload wallets.
            for node, names in ((node0, ("funder", "self_staker")), (node1, ("cold_owner", "cold_staker"))):
                loaded = node.listwallets()
                for name in names:
                    if name not in loaded:
                        node.loadwallet(name)
            return (node0.get_wallet_rpc("funder"), node0.get_wallet_rpc("self_staker"),
                    node1.get_wallet_rpc("cold_owner"), node1.get_wallet_rpc("cold_staker"))

        funder_address = funder.getnewaddress("", "legacy")

        self.log.info("Gold Rush ends at G=%d; tiers activate at G+1; Migration ends at M=%d; Final starts at F=%d", G, M, F)
        self.mine(node0, G, funder_address)
        assert_equal(self.phase(node0), "migration")
        self.mine(node0, MATURITY + 2, funder_address)

        self.log.info("Fund a tiered self-stake output and a cold-stake delegation in Migration")
        self_stake_address = self_staker.getnewquantumstakeaddress("final-self", VAULT_7D_BLOCKS)["address"]
        self_stake_script = self.script_for(node0, self_stake_address)
        self_txid = funder.sendtoaddress(self_stake_address, SELF_STAKE_AMOUNT)

        staker_quantum = cold_staker.getnewquantumaddress()["address"]
        staker_key = cold_staker.dumpquantumkey(staker_quantum)
        operator_script = self.script_for(node1, staker_quantum)
        delegation = owner.getnewquantumcoldstakingaddress(staker_key["public_key"], "final-delegated")
        qcs_address = delegation["address"]
        qcs_script = self.script_for(node1, qcs_address)
        cold_staker.importquantumcoldstakingdelegation(delegation["owner_pubkey"], staker_key["public_key"], "final-delegated")
        qcs_txid = funder.sendtoaddress(qcs_address, COLD_STAKE_AMOUNT)
        self.mine(node0, 1, funder_address)
        self.wait_until(lambda: len(self_staker.listunspent(1, 9999999, [self_stake_address])) == 1, timeout=30)
        self.wait_until(lambda: len(cold_staker.listunspent(1, 9999999, [qcs_address])) == 1, timeout=30)
        assert_equal(self_staker.listunspent(1, 9999999, [self_stake_address])[0]["txid"], self_txid)
        assert_equal(cold_staker.listunspent(1, 9999999, [qcs_address])[0]["txid"], qcs_txid)

        self.log.info("Advance to M - 3; a legacy spend valid for block M waits in the mempool")
        self.mine(node0, M - 3 - node0.getblockcount(), funder_address)
        assert_equal(node0.getblockcount(), M - 3)
        legacy_dest = funder.getnewaddress("", "legacy")
        legacy_txid = funder.sendtoaddress(legacy_dest, 1)
        self.sync_mempools()
        # Only empty blocks from here, so the legacy spend is still pending when M connects.
        self.empty_block(node0, funder_address)
        self.empty_block(node0, funder_address)
        assert_equal(node0.getblockcount(), M - 1)
        for node in self.nodes:
            assert legacy_txid in node.getrawmempool()
        raw_legacy = funder.gettransaction(legacy_txid)["hex"]
        self.restart_both("tip M-1")
        funder, self_staker, owner, cold_staker = reload_wallets()
        for node in self.nodes:
            assert_equal(node.getblockcount(), M - 1)
            assert_equal(self.phase(node), "migration")

        self.log.info("Block M, the last Migration block, is empty; the legacy spend is dropped when it connects")
        self.empty_block(node0, funder_address)
        assert_equal(node0.getblockcount(), M)
        for node in self.nodes:
            assert_equal(self.phase(node), "final_lockout")  # phase of the next block
            assert legacy_txid not in node.getrawmempool()
            result = node.testmempoolaccept([raw_legacy])[0]
            assert_equal(result["allowed"], False)
            assert result["reject-reason"] in ("legacy-spend-disabled", "legacy-output-disabled"), result
        self.restart_both("tip M")
        funder, self_staker, owner, cold_staker = reload_wallets()
        for node in self.nodes:
            assert_equal(node.getblockcount(), M)
            assert legacy_txid not in node.getrawmempool()

        self.log.info("Competing first Final blocks: a self-staked block on node 0, a cold-staked block on node 1")
        self.sync_mt_tip()
        self.disconnect_nodes(0, 1)
        self_hash, self_block = self.stake_one(self_staker, node0, self_stake_address)
        self.sync_mt_tip()
        cold_hash, cold_block = self.stake_one(cold_staker, node1, qcs_address)
        assert_equal(self_block["height"], F)
        assert_equal(cold_block["height"], F)
        assert self_hash != cold_hash

        self_coinstake = self_block["tx"][1]
        assert_equal(self_coinstake["vin"][0]["txid"], self_txid)
        assert_equal(self.paid(self_coinstake, self_stake_script), SELF_STAKE_AMOUNT + BASE_POS_SUBSIDY)
        cold_coinstake = cold_block["tx"][1]
        assert_equal(cold_coinstake["vin"][0]["txid"], qcs_txid)
        assert_equal(self.paid(cold_coinstake, qcs_script), COLD_STAKE_AMOUNT + BASE_POS_SUBSIDY - OPERATOR_FLOOR)
        assert_equal(self.paid(cold_coinstake, operator_script), OPERATOR_FLOOR)

        self.log.info("Legacy spends are rejected and a legacy-staking wallet has nothing to stake with")
        for node in self.nodes:
            result = node.testmempoolaccept([raw_legacy])[0]
            assert_equal(result["allowed"], False)
            # The wallet's transaction pays a legacy output from a legacy input; Final refuses both.
            assert result["reject-reason"] in ("legacy-spend-disabled", "legacy-output-disabled"), result
        assert_equal(funder.getstakinginfo()["legacy_staking_stopped"], True)
        assert "legacy_staking_notice" not in funder.getstakinginfo()

        self.log.info("Node 1 extends its cold-staked block; node 0 reorganises onto it")
        self.mine(node1, 1, staker_quantum, sync=False)
        assert_equal(node1.getblockcount(), F + 1)
        self.connect_nodes(0, 1)
        self.sync_blocks()
        assert_equal(node0.getbestblockhash(), node1.getbestblockhash())
        assert_equal(node0.getblockhash(F), cold_hash)
        tips = {tip["hash"]: tip["status"] for tip in node0.getchaintips()}
        assert_equal(tips.get(self_hash), "valid-fork")
        # The self-staked output is spendable state again on the winning chain.
        assert_equal(len(self_staker.listunspent(1, 9999999, [self_stake_address])), 1)

        self.restart_both("tip F+1")
        funder, self_staker, owner, cold_staker = reload_wallets()
        assert_equal(node0.getbestblockhash(), node1.getbestblockhash())
        assert_equal(node0.getblockhash(F), cold_hash)
        self.log.info("Both nodes agree on the cold-staked first Final block")


if __name__ == '__main__':
    FirstFinalTransitionTest().main()
