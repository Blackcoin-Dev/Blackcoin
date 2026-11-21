#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Relay of demurrage attestations: a stale candidate is turned away cheaply and without punishment.

A demurrage attestation is signed over the key's latest attested state. If another attestation for
the same key confirms while a peer's is in flight, the peer's is validly signed and now stale. That
is an honest race, not misbehaviour, and the node must not pay for the ML-DSA verification before it
notices. The mempool therefore looks at the target, the controlling key, the referenced state and
the lock state first (no signature work) and turns away a stale or locked candidate as a recent
consensus change, which net_processing does not punish. Block validation is untouched.

Two nodes hold the same wallet (a backup restored on the second one). With the nodes apart, each
signs an attestation for the same key from a different fee input; the first goes into a block. The
second, now stale, is then relayed to the first node by a peer:

 * it is rejected with stale-demurrage-attestation-state;
 * the relaying peer stays connected (no punishment);
 * a peer that sends a consensus-invalid transaction (value out above value in) is disconnected,
   so the test would notice if "not punished" were simply "nothing is ever punished".
"""
from decimal import Decimal
import time

from test_framework.blocktools import COINBASE_MATURITY
from test_framework.messages import CTransaction, from_hex, msg_tx
from test_framework.p2p import P2PInterface
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_raises_rpc_error

GOLD_RUSH_END_TIME = 2_000_000_000
GOLD_RUSH_END_HEIGHT = 11
MIGRATION_END_HEIGHT = 26
DEMURRAGE_ACTIVATION_HEIGHT = 27


class DemurrageAttestationRelayTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.num_nodes = 2
        self.setup_clean_chain = True
        args = [
            "-allowunsafequantumkeyrpc=1",
            "-txindex=1",
            "-staketimio=50",
            "-donatetodevfund=0",
            "-qqautodemurrageattest=0",
            "-qqallowautokeycreation=1",
            "-shadowwhitelistheight=1",
            "-shadowgoldrushblocks=10",
            f"-qqgoldrushendheight={GOLD_RUSH_END_HEIGHT}",
            f"-qqmigrationendheight={MIGRATION_END_HEIGHT}",
            "-qqstaketierheight=1",
            "-qqstakesplitheight=1",
            f"-qqdemurrageheight={DEMURRAGE_ACTIVATION_HEIGHT}",
            "-qqdemurrageblockspermonth=4",
            "-rpcserialversion=1",  # raw transaction hex keeps the quantum witness
        ]
        self.extra_args = [args, args]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def set_mt(self, t):
        self.mt = t
        for n in self.nodes:
            n.setmocktime(t)

    def generate(self, count, address, node=None):
        node = node or self.nodes[0]
        for _ in range(count):
            self.generatetoaddress(node, 1, address, sync_fun=self.no_op)
            self.set_mt(self.mt + 16)

    def run_test(self):
        node0, node1 = self.nodes
        self.set_mt((int(time.time()) & ~0xf) + 16)
        for n in self.nodes:
            n.get_wallet_rpc(self.default_wallet_name).staking(False)
        node0.createwallet(wallet_name="relay")
        wallet = node0.get_wallet_rpc("relay")
        wallet.staking(False)

        funder = wallet.getnewaddress("", "legacy")
        attest_addr = wallet.getnewquantumaddress()["address"]
        fee_addrs = [wallet.getnewquantumaddress()["address"] for _ in range(2)]
        lock_addr = wallet.getnewquantumaddress()["address"]
        mining = wallet.getnewquantumaddress()["address"]

        self.set_mt(GOLD_RUSH_END_TIME + 16)
        self.generate(COINBASE_MATURITY + 2, funder)
        self.sync_blocks()
        # One transaction funds every output, so each stays an independent, unchained coin.
        wallet.sendmany("", {attest_addr: Decimal("11"), fee_addrs[0]: Decimal("1"), fee_addrs[1]: Decimal("1"),
                             lock_addr: Decimal("7")})
        self.generate(1, funder)
        self.log.info("Mine through the Migration window until demurrage is active")
        for _ in range(40):
            if node0.getcirculatingsupply()["demurrage_active"]:
                break
            self.generate(1, mining)
        assert node0.getcirculatingsupply()["demurrage_active"]
        self.generate(12, mining)  # the attestation is due, and the interval after a first one is a month
        self.sync_blocks()

        self.log.info("Node 1 holds the same wallet (a backup restored there)")
        backup = self.options.tmpdir + "/relay_backup.dat"
        wallet.backupwallet(backup)
        node1.restorewallet("relay_copy", backup)
        copy = node1.get_wallet_rpc("relay_copy")
        copy.staking(False)
        self.disconnect_nodes(0, 1)

        self.log.info("Both sign an attestation for the same key, from different fee inputs")
        a_txid = wallet.senddemurrageattestation(attest_addr)["txid"]
        a_inputs = [(v["txid"], v["vout"]) for v in node0.getrawtransaction(a_txid, True)["vin"]]
        for txid, vout in a_inputs:
            copy.lockunspent(False, [{"txid": txid, "vout": vout}])  # B must not reuse A's inputs
        b_txid = copy.senddemurrageattestation(attest_addr)["txid"]
        b_inputs = [(v["txid"], v["vout"]) for v in node1.getrawtransaction(b_txid, True)["vin"]]
        assert not set(a_inputs) & set(b_inputs), (a_inputs, b_inputs)
        b_hex = node1.getrawtransaction(b_txid)

        self.log.info("A confirms on node 0; B is now a validly signed attestation over an old state")
        self.generate(1, mining)
        assert_equal(node0.getrawtransaction(a_txid, True)["confirmations"], 1)

        peer = node0.add_p2p_connection(P2PInterface())
        with node0.assert_debug_log(["stale-demurrage-attestation-state"]):
            peer.send_and_ping(msg_tx(from_hex(CTransaction(), b_hex)))
        assert b_txid not in node0.getrawmempool()
        assert peer.is_connected, "relaying a stale attestation must not be punished"
        assert_raises_rpc_error(-26, "stale-demurrage-attestation-state", node0.sendrawtransaction, b_hex)
        peer.peer_disconnect()

        self.log.info("Control: a consensus-invalid transaction from a peer is punished (disconnected)")
        lock_utxo = wallet.listunspent(1, 9999999, [lock_addr])[0]
        raw = node0.createrawtransaction([{"txid": lock_utxo["txid"], "vout": lock_utxo["vout"]}],
                                         [{lock_addr: Decimal("9")}])
        bad_peer = node0.add_p2p_connection(P2PInterface())
        bad_peer.send_message(msg_tx(from_hex(CTransaction(), raw)))
        bad_peer.wait_for_disconnect()


if __name__ == '__main__':
    DemurrageAttestationRelayTest().main()
