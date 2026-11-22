#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""In the last blocks of Migration a legacy stake is paid out as one quantum output.

Regtest: Gold Rush ends at G=61, Migration ends at M=91 (first Final block F=92),
maturity 10. A legacy coinstake created at height h would return its principal to a
legacy output that matures at h + 10, so from h = 81 it could never be spent before Final
locks every legacy input. From that height the wallet pays the principal and the reward of
a legacy kernel to ONE quantum output of its own (the saved quantum stake return address)
and nothing else of value. The legacy key stays the block signing key (a value-0 output at
index 1), which is what every released node accepts.

Node 1 is an UNMODIFIED v30.1.6 node that validates every block (the mock clock is after
Protocol V3.1, so the proof-of-stake kernel, signature and reward checks run). Checks:

 * outside the window a legacy stake still returns to a legacy output, unchanged;
 * not ready: with no return address the wallet reports exactly what to do and builds no
   legacy-return coinstake in the window (the refusal fallback);
 * ready: every window coinstake of a legacy wallet (a pubkeyhash kernel and a bech32
   kernel) has one valued output, a quantum output of the wallet, worth principal plus the
   scheduled reward (no split although the kernel is large, no donation); a restart in the
   window keeps the return address; a reorganisation that replaces a window block leaves
   both nodes on one chain;
 * same tip on both nodes at M and at F; after F the quantum outputs spend and stake;
 * a window block that carries a fee-paying transaction pays principal + reward + the fees to the one
   quantum output (the checks elsewhere run only on fee-free blocks);
 * exact balances by category: nothing that staked is left in a legacy output; legacy
   coins that never staked are final-locked legacy.
"""
import os
from decimal import Decimal

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal
from transition_t_final_util import (
    F,
    LAST_LEGACY_STAKE_HEIGHT,
    LIFECYCLE_ARGS,
    M,
    MATURITY,
    TransitionTFinalTestBase,
)

WINDOW_START = LAST_LEGACY_STAKE_HEIGHT + 1
SUBSIDY = Decimal("1.5")
V30_1_6 = 300106


class LegacyStakeQuantumReturnTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 2
        self.setup_clean_chain = True
        # Key creation is NOT allowed automatically: the return address must be a key the
        # operator made (or an existing one), as in the default policy.
        args = [a for a in LIFECYCLE_ARGS if not a.startswith("-qqallowautokeycreation")]
        self.extra_args = [args, args + ["-rpcdoccheck=0"]]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()
        if not os.environ.get("BLACKCOIN_V30_1_6_BINARY"):
            self.skip_if_no_previous_releases()

    def setup_nodes(self):
        override = os.environ.get("BLACKCOIN_V30_1_6_BINARY")
        if override:
            self.add_nodes(self.num_nodes, extra_args=self.extra_args,
                           binary=[self.options.bitcoind, override],
                           binary_cli=[self.options.bitcoincli] * 2)
        else:
            self.add_nodes(self.num_nodes, extra_args=self.extra_args, versions=[None, V30_1_6])
        self.start_nodes()
        self.import_deterministic_coinbase_privkeys()
        self.connect_nodes(0, 1)

    def sync_tips(self):
        n0, n1 = self.nodes
        self.wait_until(lambda: n0.getbestblockhash() == n1.getbestblockhash(), timeout=60)

    def stake_synced(self, wallet, addresses=None):
        block_hash = self.stake_one(wallet, self.nodes[0], addresses)
        self.sync_tips()
        return block_hash

    def coinstake_of(self, block_hash):
        coinstake = self.nodes[0].getblock(block_hash, 2)["tx"][1]
        valued = [o for o in coinstake["vout"] if o["value"] > 0]
        return coinstake, valued

    def kernel_value(self, coinstake):
        vin = coinstake["vin"][0]
        spent = self.nodes[0].getrawtransaction(vin["txid"], True)
        return spent["vout"][vin["vout"]]["value"]

    def assert_pays_one_quantum_output(self, block_hash, quantum_script_hex, fees=Decimal(0)):
        coinstake, valued = self.coinstake_of(block_hash)
        assert_equal(len(coinstake["vin"]), 1)
        assert_equal(len(valued), 1)
        assert_equal(valued[0]["scriptPubKey"]["hex"], quantum_script_hex)
        assert_equal(valued[0]["scriptPubKey"]["type"], "witness_unknown")
        assert_equal(valued[0]["value"], self.kernel_value(coinstake) + SUBSIDY + fees)
        # vout[0] marks the coinstake; vout[1] is the value-0 legacy block signing key.
        assert_equal(coinstake["vout"][0]["value"], 0)
        assert_equal(coinstake["vout"][1]["value"], 0)
        assert_equal(coinstake["vout"][1]["scriptPubKey"]["type"], "pubkey")
        return coinstake["txid"], valued[0]["value"], self.kernel_value(coinstake)

    def run_test(self):
        n0, n1 = self.nodes
        wallet = n0.get_wallet_rpc(self.default_wallet_name)
        wallet.staking(False)
        self.set_initial_mt()
        assert_equal(n1.getnetworkinfo()["subversion"], "/Blackcoin:30.1.6(testnode1)/")

        stake_addr = wallet.getnewaddress("", "legacy")
        bech32_addr = wallet.getnewaddress("", "bech32")
        pow_addr = wallet.getnewaddress("", "legacy")

        self.log.info("Legacy-only wallet: legacy and bech32 kernels from before Gold Rush ends")
        self.generatetoaddress(n0, 6, stake_addr, sync_fun=self.sync_all)
        self.bump()
        self.generatetoaddress(n0, 4, bech32_addr, sync_fun=self.sync_all)
        self.bump()
        self.generatetoaddress(n0, MATURITY, pow_addr, sync_fun=self.sync_all)
        self.sync_mt_tip()
        self.pow_blocks(n0, LAST_LEGACY_STAKE_HEIGHT - 1 - n0.getblockcount(), pow_addr, sync=True)
        assert_equal(n0.getblockcount(), LAST_LEGACY_STAKE_HEIGHT - 1)
        assert_equal(n0.getquantumquasarinfo()["phase"], "migration")

        self.log.info("Status long before the window names the start height and what to do")
        info = wallet.getstakinginfo()
        assert_equal(info["legacy_staking_window_start_height"], WINDOW_START)
        assert_equal(info["legacy_staking_pays_quantum"], True)
        assert_equal(info["legacy_stake_return_ready"], False)
        assert "setquantumstakereturn" in info["legacy_stake_return_action"]
        assert_equal(info["legacy_staking_in_window"], False)
        assert f"From height {WINDOW_START}" in info["legacy_staking_notice"]
        assert "NOT READY" in info["legacy_staking_notice"]
        status = wallet.getmigrationstatus()
        assert_equal(status["legacy_staking_window_start_height"], WINDOW_START)
        assert_equal(status["legacy_stake_return_ready"], False)
        assert_equal(status["legacy_staking_notice"], info["legacy_staking_notice"])

        self.log.info("Outside the window a legacy stake still returns to a legacy output")
        block = self.stake_synced(wallet, [stake_addr])
        assert_equal(n0.getblock(block)["height"], LAST_LEGACY_STAKE_HEIGHT)
        _, valued = self.coinstake_of(block)
        assert valued and all(o["scriptPubKey"]["type"] == "pubkey" for o in valued)

        self.log.info("In the window with no return address the wallet refuses legacy kernels")
        info = wallet.getstakinginfo()
        assert_equal(info["legacy_staking_in_window"], True)
        assert_equal(info["legacy_staking_stopped"], True)
        assert_equal(info["legacy_stake_return_ready"], False)
        assert "will not stake legacy coins" in info["legacy_staking_notice"]
        assert len(self.stake_inputs(wallet, [stake_addr])) > 0
        wallet.staking(True)
        self.wait_until(lambda: wallet.getstakinginfo()["staking_state"] == "no_eligible_coins", timeout=60)
        info = wallet.getstakinginfo()
        assert_equal(info["eligible"], False)
        assert_equal(info["weight"], 0)
        for _ in range(12):
            self.bump()
        self.wait_until(lambda: wallet.getstakinginfo()["staking_snapshot_current"], timeout=60)
        assert_equal(n0.getblockcount(), LAST_LEGACY_STAKE_HEIGHT)
        wallet.staking(False)

        self.log.info("An address that is not a quantum address of the wallet is refused")
        legacy_addr = wallet.getnewaddress("", "legacy")
        try:
            wallet.setquantumstakereturn({"existing_address": legacy_addr})
            raise AssertionError("a legacy address was accepted")
        except Exception as e:  # JSONRPCException
            assert "not an ordinary quantum address" in str(e), str(e)
        try:
            wallet.setquantumstakereturn()
            raise AssertionError("no quantum address exists, yet one was chosen")
        except Exception as e:
            assert "no quantum address" in str(e), str(e)

        self.log.info("Make the return address (an explicit RPC, key creation authorised) and see it ready")
        result = wallet.setquantumstakereturn({"allow_new_quantum_key": True})
        assert_equal(result["created"], True)
        assert_equal(result["ready"], True)
        quantum_address = result["address"]
        quantum_script = n0.validateaddress(quantum_address)["scriptPubKey"]
        info = wallet.getstakinginfo()
        assert_equal(info["legacy_stake_return_ready"], True)
        assert_equal(info["legacy_stake_return_address"], quantum_address)
        assert_equal(info["legacy_staking_stopped"], False)
        assert "READY" in info["legacy_staking_notice"] and quantum_address in info["legacy_staking_notice"]
        assert_equal(wallet.getmigrationstatus()["legacy_stake_return_address"], quantum_address)

        staked = []  # (txid, value, principal)
        fee_total = Decimal(0)  # fees the staked blocks carried

        self.log.info("Window: every legacy coinstake pays one quantum output (pubkeyhash kernel)")
        for expected_height in (WINDOW_START, WINDOW_START + 1):
            block = self.stake_synced(wallet, [stake_addr])
            assert_equal(n0.getblock(block)["height"], expected_height)
            staked.append(self.assert_pays_one_quantum_output(block, quantum_script))

        self.log.info("Window: a bech32 (witness keyhash) kernel does the same")
        block = self.stake_synced(wallet, [bech32_addr])
        assert_equal(n0.getblock(block)["height"], WINDOW_START + 2)
        staked.append(self.assert_pays_one_quantum_output(block, quantum_script))

        self.log.info("Restart inside the window: the return address survives")
        self.restart_node(0, extra_args=self.extra_args[0] + [f"-mocktime={self.mt}"])
        self.connect_nodes(0, 1)
        wallet = n0.get_wallet_rpc(self.default_wallet_name)
        wallet.staking(False)
        self.set_mt(self.mt)
        info = wallet.getstakinginfo()
        assert_equal(info["legacy_stake_return_ready"], True)
        assert_equal(info["legacy_stake_return_address"], quantum_address)
        block = self.stake_synced(wallet, [stake_addr])
        assert_equal(n0.getblock(block)["height"], WINDOW_START + 3)
        staked.append(self.assert_pays_one_quantum_output(block, quantum_script))

        self.log.info("A reorganisation replaces a window block")
        replaced = n0.getbestblockhash()
        replaced_txid = n0.getblock(replaced)["tx"][1]
        replaced_kernel = n0.getblock(replaced, 2)["tx"][1]["vin"][0]
        self.disconnect_nodes(0, 1)
        n1.invalidateblock(replaced)
        self.pow_blocks(n1, 2, pow_addr)
        assert_equal(n1.getblockcount(), WINDOW_START + 4)
        self.connect_nodes(0, 1)
        self.sync_tips()
        assert replaced not in [n0.getblockhash(h) for h in range(1, n0.getblockcount() + 1)]
        assert_equal(n0.getblockcount(), WINDOW_START + 4)
        assert_equal(n0.gettxout(replaced_txid, 2), None)
        staked.pop()  # that stake is gone with its block
        assert wallet.gettransaction(replaced_txid)["confirmations"] <= 0
        assert n0.gettxout(replaced_kernel["txid"], replaced_kernel["vout"]) is not None  # its kernel is unspent again
        self.log.info("...and the wallet stakes again on the new chain")
        block = self.stake_synced(wallet, [stake_addr])
        assert_equal(n0.getblock(block)["height"], WINDOW_START + 5)
        staked.append(self.assert_pays_one_quantum_output(block, quantum_script))

        self.log.info("A block that carries a fee-paying transaction pays principal + reward + fees to the one quantum output")
        # The coinstake collects the fees of the block's transactions; consensus checks the total of
        # its outputs against principal + reward + fees, and the wallet's single quantum output must
        # carry all of it (the old checks only ever saw a block with no fees).
        pow_coin = [u for u in wallet.listunspent(1, 9999999, [pow_addr]) if u["spendable"] and u["confirmations"] > MATURITY][0]
        fee_txid = wallet.send(outputs=[{wallet.getnewaddress("", "legacy"): Decimal("1")}],
                               options={"inputs": [{"txid": pow_coin["txid"], "vout": pow_coin["vout"]}],
                                        "add_inputs": False, "fee_rate": 200})["txid"]
        block_fee = n0.getmempoolentry(fee_txid)["fees"]["base"]
        assert block_fee > 0, block_fee
        block = self.stake_synced(wallet, [stake_addr])
        assert fee_txid in n0.getblock(block)["tx"], "the fee-paying transaction is in the staked block"
        staked.append(self.assert_pays_one_quantum_output(block, quantum_script, fees=block_fee))
        fee_total += block_fee

        self.log.info("Up to M: both nodes on one tip")
        self.pow_blocks(n0, M - n0.getblockcount(), pow_addr, sync=True)
        assert_equal(n0.getblockcount(), M)
        self.sync_tips()

        self.log.info("Final: first block F is mined on a quantum address and both nodes agree")
        self.generatetoaddress(n0, 1, quantum_address, sync_fun=self.sync_all)
        assert_equal(n0.getblockcount(), F)
        assert_equal(n0.getquantumquasarinfo()["phase"], "final_lockout")
        self.sync_tips()
        assert_equal(n1.getquantumquasarinfo()["phase"], "final_lockout")

        self.log.info("Exact balances by category")
        for _ in range(MATURITY + 2):
            self.bump()
            self.generatetoaddress(n0, 1, quantum_address, sync_fun=self.sync_all)
        self.sync_tips()
        wallet_info = wallet.getmigrationstatus()
        categories = wallet_info["categories"]
        staked_principal = sum(p for _, _, p in staked)
        staked_value = sum(v for _, v, _ in staked)
        assert_equal(staked_value, staked_principal + SUBSIDY * len(staked) + fee_total)
        # Every legacy output that remains is one that never staked.
        remaining_legacy = self.legacy_total(wallet)
        assert_equal(categories["final_locked_legacy"]["nominal_amount"], remaining_legacy)
        for txid, _, _ in staked:
            for entry in wallet.listunspent(0, 9999999):
                if entry["txid"] == txid and entry["amount"] > 0:
                    assert_equal(n0.getrawtransaction(txid, True)["vout"][entry["vout"]]["scriptPubKey"]["type"], "witness_unknown")
        assert_equal(self.window_legacy_outputs(wallet, [t for t, _, _ in staked]), 0)
        window_quantum = sum(Decimal(str(e["amount"])) for e in wallet.listunspent(0, 9999999, [quantum_address])
                             if e["txid"] in {t for t, _, _ in staked})
        assert_equal(window_quantum, staked_value)

        self.log.info("After F the quantum outputs spend and stake, and the unmodified node agrees")
        spend_txid, spend_value, _ = staked[0]
        destination = wallet.getnewquantumaddress()["address"]
        sent = wallet.send(outputs=[{destination: spend_value - Decimal("0.01")}],
                           options={"inputs": [{"txid": spend_txid, "vout": 2}], "add_inputs": False,
                                    "change_address": quantum_address})
        self.generatetoaddress(n0, 1, quantum_address, sync_fun=self.sync_all)
        assert_equal(n1.getrawtransaction(sent["txid"], True, n1.getbestblockhash())["confirmations"], 1)
        stake_txid, stake_value, _ = staked[1]
        quantum_kernel = [{"txid": stake_txid, "vout": 2}]
        # Lock every other output so the wallet's staker has this one kernel only: the block it makes must
        # then be made from exactly the outpoint that was checked.
        others = [{"txid": u["txid"], "vout": u["vout"]} for u in wallet.listunspent(0, 9999999)
                  if (u["txid"], u["vout"]) != (quantum_kernel[0]["txid"], quantum_kernel[0]["vout"])]
        wallet.lockunspent(False, others)
        for _ in range(3000):
            self.bump()
            if wallet.checkkernel(quantum_kernel)["found"]:
                break
        kernel_time = wallet.checkkernel(quantum_kernel)["kernel"]["time"]
        height_before = n0.getblockcount()
        self.set_mt(kernel_time - 16)
        wallet.staking(True)
        self.set_mt(kernel_time)
        self.wait_until(lambda: n0.getblockcount() > height_before, timeout=60)
        wallet.staking(False)
        wallet.lockunspent(True, others)
        self.sync_tips()
        assert_equal(n1.getblockcount(), n0.getblockcount())
        # The block the staker made used exactly the kernel that was checked, not some other coin.
        post_f_coinstake = n0.getblock(n0.getbestblockhash(), 2)["tx"][1]
        assert_equal(post_f_coinstake["vin"][0]["txid"], quantum_kernel[0]["txid"])
        assert_equal(post_f_coinstake["vin"][0]["vout"], quantum_kernel[0]["vout"])

    def legacy_total(self, wallet):
        total = Decimal(0)
        for entry in wallet.listunspent(0, 9999999):
            script_type = self.nodes[0].getrawtransaction(entry["txid"], True)["vout"][entry["vout"]]["scriptPubKey"]["type"]
            if script_type != "witness_unknown" and entry["amount"] > 0:
                total += Decimal(str(entry["amount"]))
        return total

    def quantum_total(self, wallet):
        total = Decimal(0)
        for entry in wallet.listunspent(0, 9999999):
            script_type = self.nodes[0].getrawtransaction(entry["txid"], True)["vout"][entry["vout"]]["scriptPubKey"]["type"]
            if script_type == "witness_unknown":
                total += Decimal(str(entry["amount"]))
        return total

    def window_legacy_outputs(self, wallet, txids):
        count = 0
        for txid in txids:
            tx = self.nodes[0].getrawtransaction(txid, True)
            for out in tx["vout"]:
                if out["value"] > 0 and out["scriptPubKey"]["type"] != "witness_unknown":
                    count += 1
        return count


if __name__ == '__main__':
    LegacyStakeQuantumReturnTest().main()
