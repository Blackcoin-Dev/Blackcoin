#!/usr/bin/env python3
"""A peer is not punished for a transaction that a lifecycle gate invalidated.

Regtest: Gold Rush ends at G, Migration ends at M, Final starts at F = M + 1.
Peers are real inbound P2P connections without any permission (no NoBan).

Before the fix a transaction that was valid for the last block before a gate and
reached a node whose next block was past the gate was rejected as TX_CONSENSUS,
so the honest relaying peer got 100 misbehavior points and was disconnected.

Checked here, at the exact boundary heights:
 - at tip G (next block G+1) a legacy transaction signed without FORKID is
   rejected, but the peer is neither disconnected nor scored;
 - a forged signature that only sets the FORKID bit, and a corrupted signature,
   still get the peer disconnected;
 - at tip M (next block F) a legacy-to-quantum migration transaction is rejected
   as a lifecycle change without punishing the peer;
 - a block that contains such a transaction stays invalid at both boundaries;
 - the rejection is not remembered across a reorganisation below the gate;
 - sendrawtransaction names the reason and tells the user to sign again.
"""
import time
from decimal import Decimal

from test_framework.blocktools import COINBASE_MATURITY
from test_framework.messages import msg_tx, tx_from_hex
from test_framework.p2p import P2PInterface
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import (
    assert_equal,
    assert_raises_rpc_error,
)

BLOCKS = 60
G = 1 + BLOCKS  # last Gold Rush block
M = G + 30      # last Migration block
FEE = Decimal("0.01")


class TransitionNonPunitiveTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.extra_args = [[
            "-allowunsafequantumkeyrpc=1", "-qqallowautokeycreation=1", "-staketimio=50",
            "-shadowwhitelistheight=1", f"-shadowgoldrushblocks={BLOCKS}",
            f"-qqgoldrushendheight={G}", f"-qqmigrationendheight={M}",
            "-debug=net", "-debug=mempoolrej",
        ]]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def bump(self, seconds=16):
        self.mocktime += seconds
        self.nodes[0].setmocktime(self.mocktime)

    def mine(self, count, address):
        for _ in range(count):
            self.generatetoaddress(self.nodes[0], 1, address, sync_fun=self.no_op)
            self.bump()

    def new_peer(self):
        peer = self.nodes[0].add_p2p_connection(P2PInterface())
        info = [p for p in self.nodes[0].getpeerinfo() if p["id"] == max(x["id"] for x in self.nodes[0].getpeerinfo())][0]
        # An ordinary inbound peer: no permissions, so no NoBan.
        assert info["inbound"]
        assert_equal(info["permissions"], [])
        return peer

    def relay_not_punished(self, hexstr):
        """Relay `hexstr` from a fresh ordinary peer; it must be rejected without punishing the peer."""
        node = self.nodes[0]
        txid = tx_from_hex(hexstr).rehash()
        peer = self.new_peer()
        with node.assert_debug_log(expected_msgs=[f"{txid}"], unexpected_msgs=["Misbehaving", "discourag"]):
            peer.send_message(msg_tx(tx_from_hex(hexstr)))
            peer.sync_with_ping()
        assert peer.is_connected
        assert txid not in node.getrawmempool()
        peer.peer_disconnect()
        peer.wait_for_disconnect()

    def relay_punished(self, hexstr):
        """Relay `hexstr` from a fresh ordinary peer; it must be scored 100 and disconnected."""
        node = self.nodes[0]
        peer = self.new_peer()
        with node.assert_debug_log(expected_msgs=["(0 -> 100) DISCOURAGE THRESHOLD EXCEEDED"]):
            peer.send_message(msg_tx(tx_from_hex(hexstr)))
            peer.wait_for_disconnect()

    def run_test(self):
        node = self.nodes[0]
        wallet = node.get_wallet_rpc(self.default_wallet_name)
        wallet.staking(False)
        self.mocktime = (int(time.time()) & ~0xf) + 16
        node.setmocktime(self.mocktime)

        sources = [wallet.getnewaddress("", "legacy") for _ in range(8)]
        pow_addr = wallet.getnewaddress("", "legacy")
        for address in sources:
            self.mine(1, address)
        self.mine(COINBASE_MATURITY + 2, pow_addr)
        coins = {address: wallet.listunspent(1, 9999999, [address])[0] for address in sources}
        for coin in coins.values():
            wallet.lockunspent(False, [{"txid": coin["txid"], "vout": coin["vout"]}])

        def build(address, destination):
            coin = coins[address]
            raw = node.createrawtransaction(
                [{"txid": coin["txid"], "vout": coin["vout"]}],
                [{destination: Decimal(str(coin["amount"])) - FEE}])
            signed = wallet.signrawtransactionwithwallet(raw)
            assert signed["complete"], signed
            return signed["hex"]

        self.log.info("Build transactions signed without FORKID for the last pre-gate block")
        self.mine(G - 1 - node.getblockcount(), pow_addr)
        assert_equal(node.getblockcount(), G - 1)
        assert_equal(node.getquantumquasarinfo()["next_block_phase"], "gold_rush")
        legacy_destination = wallet.getnewaddress("", "legacy")
        stale = [build(sources[0], legacy_destination), build(sources[1], legacy_destination)]
        for hexstr in stale:
            assert node.testmempoolaccept([hexstr])[0]["allowed"]

        self.log.info("Cross G: the next block is the first Migration block")
        self.mine(1, pow_addr)
        assert_equal(node.getblockcount(), G)
        assert_equal(node.getquantumquasarinfo()["next_block_phase"], "migration")
        g_hash = node.getbestblockhash()
        for hexstr in stale:
            result = node.testmempoolaccept([hexstr])[0]
            assert not result["allowed"]
            assert result["reject-reason"].startswith("mandatory-script-verify-flag-failed")

        self.log.info("Honest relay of a transaction signed before G is not punished")
        self.relay_not_punished(stale[0])

        self.log.info("sendrawtransaction names the reason and says to sign again")
        assert_raises_rpc_error(-26, "sign it again with a current wallet", node.sendrawtransaction, stale[1])

        self.log.info("A block with the stale transaction stays invalid")
        with node.assert_debug_log(expected_msgs=["ConnectBlock: CheckQueue failed"]):
            assert_raises_rpc_error(None, "TestBlockValidity failed", node.generateblock, pow_addr, [stale[1]], invalid_call=False)

        self.log.info("Negative controls: a corrupted signature and a forged FORKID signature are still punished")
        good = build(sources[2], legacy_destination)
        assert node.testmempoolaccept([good])[0]["allowed"]
        corrupted = bytearray(bytes.fromhex(good))
        corrupted[len(corrupted) // 2 + 20] ^= 0x01
        assert not node.testmempoolaccept([bytes(corrupted).hex()])[0]["allowed"]
        self.relay_punished(bytes(corrupted).hex())
        # Same transaction as a pre-G signature but with the FORKID bit set on the
        # hash type byte without re-signing: the signature no longer matches.
        forged = tx_from_hex(stale[1])
        script = bytearray(forged.vin[0].scriptSig)
        sig_len = script[0]
        assert script[sig_len] == 0x01  # SIGHASH_ALL of the old signature
        script[sig_len] = 0x41  # SIGHASH_ALL | SIGHASH_FORKID
        forged.vin[0].scriptSig = bytes(script)
        forged.rehash()
        assert not node.testmempoolaccept([forged.serialize().hex()])[0]["allowed"]
        self.relay_punished(forged.serialize().hex())

        self.log.info("A valid current transaction is accepted and its peer is kept")
        peer = self.new_peer()
        peer.send_message(msg_tx(tx_from_hex(good)))
        peer.sync_with_ping()
        assert tx_from_hex(good).rehash() in node.getrawmempool()
        assert peer.is_connected
        peer.peer_disconnect()
        peer.wait_for_disconnect()

        self.log.info("The rejection is not remembered across a reorganisation below G")
        node.invalidateblock(g_hash)
        assert_equal(node.getblockcount(), G - 1)
        peer = self.new_peer()
        peer.send_message(msg_tx(tx_from_hex(stale[0])))
        peer.sync_with_ping()
        self.wait_until(lambda: tx_from_hex(stale[0]).rehash() in node.getrawmempool())
        assert peer.is_connected
        peer.peer_disconnect()
        peer.wait_for_disconnect()
        node.reconsiderblock(g_hash)
        assert_equal(node.getbestblockhash(), g_hash)
        assert tx_from_hex(stale[0]).rehash() not in node.getrawmempool()

        self.log.info("Cross M: the next block is the first Final block")
        quantum_address = wallet.getnewquantumaddress()["address"]
        self.mine(M - 1 - node.getblockcount(), pow_addr)
        assert_equal(node.getblockcount(), M - 1)
        assert_equal(node.getquantumquasarinfo()["next_block_phase"], "migration")
        migrations = [build(sources[3], quantum_address), build(sources[4], quantum_address)]
        for hexstr in migrations:
            assert node.testmempoolaccept([hexstr])[0]["allowed"]
        self.mine(1, pow_addr)
        assert_equal(node.getblockcount(), M)
        assert_equal(node.getquantumquasarinfo()["next_block_phase"], "final_lockout")
        for hexstr in migrations:
            result = node.testmempoolaccept([hexstr])[0]
            assert not result["allowed"]
            assert_equal(result["reject-reason"], "legacy-spend-disabled")

        self.log.info("Honest relay of a migration transaction built for the last Migration block is not punished")
        self.relay_not_punished(migrations[0])
        assert_raises_rpc_error(-26, "legacy-spend-disabled", node.sendrawtransaction, migrations[1])

        self.log.info("A block with the migration transaction stays invalid at F")
        assert_raises_rpc_error(None, "TestBlockValidity failed", node.generateblock, quantum_address, [migrations[1]], invalid_call=False)
        assert_equal(node.getblockcount(), M)


if __name__ == '__main__':
    TransitionNonPunitiveTest().main()
