#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Shared helpers for the Migration/Final tests of the t-final track.

Regtest lifecycle used by these tests (coinbase and coinstake maturity is 10):
    G = last Gold Rush block, M = last Migration block, F = M + 1 = first Final block.
"""
import hashlib
import struct

BLOCKS = 60
G = 1 + BLOCKS
M = G + 30
F = M + 1
MATURITY = 10
# The wallet stops creating legacy coinstakes this many blocks earlier than the
# last height whose output still matures by M (see LEGACY_STAKE_MIGRATION_MARGIN_BLOCKS).
MARGIN = 1
LAST_LEGACY_STAKE_HEIGHT = M - MATURITY - MARGIN

# Regtest Protocol V3.1 starts at 1713938400 (April 2024). Blocks timed before it
# skip the proof-of-stake kernel and reward checks (ProtocolV3 gates them in
# CheckProofOfStake and ConnectBlock), so every test that stakes starts its mock
# clock after it. A genesis-relative clock (2014) would test nothing there.
MOCK_START_TIME = 1750000000

LIFECYCLE_ARGS = [
    "-allowunsafequantumkeyrpc=1",
    "-qqallowautokeycreation=1",
    "-txindex=1",
    "-staketimio=50",
    "-shadowwhitelistheight=1",
    f"-shadowgoldrushblocks={BLOCKS}",
    f"-qqgoldrushendheight={G}",
    f"-qqmigrationendheight={M}",
]


def single_output_reserve_bit(txid, vout):
    """The final stake reserve's rule for a wallet with exactly one qualifying output: True when that output is held
    back (reserved) for the first Final block, False when it is released. One SHA-256 over the ASCII tag, the 32
    transaction hash bytes in serialization order (the displayed txid reversed) and the output index as four
    little-endian bytes; held when the last digest byte is odd."""
    digest = hashlib.sha256(b"BLK final stake reserve v1" + bytes.fromhex(txid)[::-1] + struct.pack("<I", vout)).digest()
    return bool(digest[31] & 1)


class TransitionTFinalTestBase:
    """Mixin with mock-time and wallet staking helpers (the staker needs 16 second
    slots). Use as `class T(TransitionTFinalTestBase, BitcoinTestFramework)`."""

    def add_options(self, parser):
        self.add_wallet_options(parser)

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def set_initial_mt(self):
        """Start the mock clock after Protocol V3.1 so the PoS and reward checks run."""
        tip_time = self.nodes[0].getblockheader(self.nodes[0].getbestblockhash())["time"]
        self.set_mt((max(tip_time, MOCK_START_TIME) & ~0xf) + 16)

    def set_mt(self, t):
        self.mt = t
        for n in reversed(self.nodes):
            n.setmocktime(t)

    def bump(self, seconds=16):
        self.set_mt(self.mt + seconds)

    def sync_mt_tip(self):
        tip_time = self.nodes[0].getblockheader(self.nodes[0].getbestblockhash())["time"]
        self.set_mt(max(self.mt, (tip_time & ~0xf) + 16))

    def pow_blocks(self, node, count, address, sync=False):
        hashes = []
        for _ in range(count):
            hashes += self.generatetoaddress(node, 1, address, sync_fun=(self.sync_all if sync else self.no_op))
            self.bump()
        return hashes

    def stake_inputs(self, wallet, addresses=None):
        utxos = wallet.listunspent(1, 9999999, addresses) if addresses else wallet.listunspent(1, 9999999)
        return [{"txid": u["txid"], "vout": u["vout"]} for u in utxos
                if u.get("spendable", True) and u.get("confirmations", 0) > MATURITY]

    def kernel_time(self, wallet, addresses=None):
        inputs = self.stake_inputs(wallet, addresses)
        assert inputs, "no mature stake inputs"
        for _ in range(3000):
            self.bump()
            result = wallet.checkkernel(inputs)
            if result["found"]:
                return result["kernel"]["time"]
        raise AssertionError("no kernel found")

    def stake_one(self, wallet, node, addresses=None):
        """Let the wallet stake exactly one block; returns its hash."""
        last = None
        for _ in range(6):
            height_before = node.getblockcount()
            kernel_time = self.kernel_time(wallet, addresses)
            self.set_mt(kernel_time - 16)
            wallet.staking(True)
            try:
                self.set_mt(kernel_time)
                self.wait_until(lambda: node.getblockcount() > height_before, timeout=40)
                block_hash = node.getbestblockhash()
                assert "proof-of-stake" in node.getblock(block_hash, 2)["flags"]
                return block_hash
            except AssertionError as e:
                last = e
            finally:
                wallet.staking(False)
            self.bump()
        raise last

    def kernel_slot_for(self, wallet, outpoint):
        """The mock time of the first slot at which the consensus kernel check passes for this
        output (checkkernel). The difficulty falls after a long gap, so this can be the next slot."""
        for _ in range(30000):
            result = wallet.checkkernel([outpoint])
            if result["found"]:
                return result["kernel"]["time"]
            self.bump()
        raise AssertionError("no kernel slot found for %s" % outpoint)

    def stake_outpoint(self, wallet, node, outpoint):
        """Let the wallet's own staker produce the next block, from exactly this kernel."""
        before = node.getblockcount()
        kernel_time = self.kernel_slot_for(wallet, outpoint)
        self.set_mt(kernel_time - 16)
        wallet.staking(True)
        try:
            self.set_mt(kernel_time)
            self.wait_until(lambda: node.getblockcount() > before, timeout=60)
        finally:
            wallet.staking(False)
        block_hash = node.getbestblockhash()
        block = node.getblock(block_hash, 2)
        assert "proof-of-stake" in block["flags"]
        assert block["tx"][1]["vin"][0]["txid"] == outpoint["txid"]
        assert block["tx"][1]["vin"][0]["vout"] == outpoint["vout"]
        return block_hash

    def migrate_singleton_candidates(self, node, pow_addr, wallets):
        """Migrate the one legacy coin of each wallet into a new quantum address of the same wallet, all in one block.
        Returns [(wallet, address, outpoint)], the outpoint known from the unconfirmed transaction. The final stake
        reserve's singleton rule depends on the outpoint, so a test that needs a wallet of a given parity migrates
        several candidates and keeps the ones that fit (see single_output_reserve_bit)."""
        found = []
        for wallet in wallets:
            address = wallet.getnewquantumaddress()["address"]
            wallet.migratetoquantum({"existing_address": address, "max_inputs": 1})
            outputs = [u for u in wallet.listunspent(0, 9999999, [address]) if u["amount"] > 0]
            assert len(outputs) == 1, outputs
            found.append((wallet, address, {"txid": outputs[0]["txid"], "vout": outputs[0]["vout"]}))
        self.pow_blocks(node, 1, pow_addr)
        return found
