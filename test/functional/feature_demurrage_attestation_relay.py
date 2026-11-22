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

No signature work may precede a rejection that ends without punishment. The attestation signature
does not cover the sequence numbers of the enclosing transaction, so variants of one current
attestation (with a relative lock the fee input cannot meet) carry a valid attestation into the
mempool's cheap sequence-lock decision. The node logs one line each time it verifies attestation
signatures (-debug=mempool); the variants must produce none and must not be punished. A variant
with a corrupted signature and the same cheap failure is reported for the cheap reason (a corrupted
signature can only be reported by verifying it). The same current attestation with a corrupted
signature and nothing else wrong is verified and punished (the P2P control for the verification
path), and the unchanged attestation passes testmempoolaccept with exactly one verification.

Two more cases go through real admission with a valid current attestation and assert that no
attestation verification pass happens at all:

 * the demurrage value boundary: a fee input that was still inside the grace period at the tip and
   decays at the next block (it "just crossed the boundary"). The transaction was valid when signed;
   at the next-block evaluation point its input is worth less than its output. It is turned away as a
   recent consensus change (not punished). The same transaction with an output no input could pay for
   at either point is a plain consensus failure (punished). Neither reaches the verification;
 * a package whose members pass their own checks and is rejected at the package stage (the package
   ancestor limit, node restarted with -limitancestorcount=1): nothing is verified.
"""
from decimal import Decimal
import copy as copy_module
import time

from test_framework.blocktools import COINBASE_MATURITY
from test_framework.messages import COIN, CTransaction, from_hex, msg_tx
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
            "-debug=mempool",
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
        node0.createwallet(wallet_name="relay", load_on_startup=True)
        wallet = node0.get_wallet_rpc("relay")
        wallet.staking(False)

        funder = wallet.getnewaddress("", "legacy")
        attest_addr = wallet.getnewquantumaddress()["address"]
        package_key_addr = wallet.getnewquantumaddress()["address"]  # a second key, attested by the package test
        fee_addrs = [wallet.getnewquantumaddress()["address"] for _ in range(2)]
        lock_addr = wallet.getnewquantumaddress()["address"]
        mining = wallet.getnewquantumaddress()["address"]

        self.set_mt(GOLD_RUSH_END_TIME + 16)
        self.generate(COINBASE_MATURITY + 2, funder)
        self.sync_blocks()
        # One transaction funds every output, so each stays an independent, unchained coin.
        wallet.sendmany("", {attest_addr: Decimal("11"), package_key_addr: Decimal("11"), fee_addrs[0]: Decimal("1"), fee_addrs[1]: Decimal("1"),
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

        self.log.info("B is signed on node 1 against the current state, from its own fee inputs")
        b_txid = copy.senddemurrageattestation(attest_addr)["txid"]
        b_inputs = [(v["txid"], v["vout"]) for v in node1.getrawtransaction(b_txid, True)["vin"]]
        b_hex = node1.getrawtransaction(b_txid)
        b_tx = from_hex(CTransaction(), b_hex)
        assert b_tx.nVersion >= 2, b_tx.nVersion  # relative locks apply

        verify_line = "Verifying demurrage attestation signatures of"

        def variant(sequence, corrupt=False):
            tx = copy_module.deepcopy(b_tx)
            tx.vin[0].nSequence = sequence  # not covered by the attestation signature
            if corrupt:
                attestation_outputs = [o for o in tx.vout if len(o.scriptPubKey) > 1000]
                assert len(attestation_outputs) == 1, [len(o.scriptPubKey) for o in tx.vout]
                script = bytearray(attestation_outputs[0].scriptPubKey)
                script[-50] ^= 0x01  # inside the ML-DSA signature, which ends the payload
                attestation_outputs[0].scriptPubKey = bytes(script)
            tx.rehash()
            return tx

        self.log.info("No signature work before a cheap, non-punitive rejection (relative lock the input cannot meet)")
        peer = node0.add_p2p_connection(P2PInterface())
        for k, sequence in enumerate([1000, 2000, 3000]):
            tx = variant(sequence)
            with node0.assert_debug_log(["non-BIP68-final"], unexpected_msgs=[verify_line]):
                peer.send_and_ping(msg_tx(tx))
            assert tx.hash not in node0.getrawmempool()
            assert peer.is_connected, "a cheap, non-punitive rejection must not punish"
        # The same with a corrupted signature: only verification could report it, so the report is the cheap reason.
        tx = variant(4000, corrupt=True)
        with node0.assert_debug_log(["non-BIP68-final"], unexpected_msgs=[verify_line, "bad-demurrage-attestation-signature"]):
            peer.send_and_ping(msg_tx(tx))
        assert peer.is_connected
        peer.peer_disconnect()

        self.log.info("The unchanged current attestation is verified exactly once on the way to acceptance")
        with node0.assert_debug_log([verify_line]):
            assert_equal(node0.testmempoolaccept([b_hex])[0]["allowed"], True)
        verified = [ln for ln in open(node0.debug_log_path, encoding="utf8") if verify_line in ln]
        assert len(verified) == 1, verified

        self.log.info("Control: a current attestation with a corrupted signature is verified and the peer punished")
        bad_sig_peer = node0.add_p2p_connection(P2PInterface())
        with node0.assert_debug_log([verify_line, "bad-demurrage-attestation-signature"]):
            bad_sig_peer.send_message(msg_tx(variant(b_tx.vin[0].nSequence, corrupt=True)))
            bad_sig_peer.wait_for_disconnect()

        self.log.info("The package path: a parent and a child whose attestation is current")
        copy_package_addr = copy.getnewquantumaddress()["address"]  # node 1's own address for the parent's output
        copy_change_addr = copy.getnewquantumaddress()["address"]
        p_txid = copy.sendtoaddress(address=copy_package_addr, amount=Decimal("2"), change_address=copy_change_addr)
        p_hex = node1.getrawtransaction(p_txid)
        p_vout = [i for i, o in enumerate(node1.getrawtransaction(p_txid, True)["vout"])
                  if o["scriptPubKey"].get("address") == copy_package_addr][0]
        locked = []
        for u in copy.listunspent(0):
            if (u["txid"], u["vout"]) != (p_txid, p_vout) and u.get("address") != package_key_addr:
                copy.lockunspent(False, [{"txid": u["txid"], "vout": u["vout"]}])
                locked.append({"txid": u["txid"], "vout": u["vout"]})
        # The child attests the second key (the first one is pending on node 1) and pays its fee from the parent's output.
        child_txid = copy.senddemurrageattestation(package_key_addr)["txid"]
        child_hex = node1.getrawtransaction(child_txid)
        child_tx = from_hex(CTransaction(), child_hex)
        assert any(i.prevout.hash == int(p_txid, 16) and i.prevout.n == p_vout for i in child_tx.vin), "the child must spend the parent"
        copy.lockunspent(True, locked)

        def package_variant(sequence, corrupt=False):
            tx = copy_module.deepcopy(child_tx)
            tx.vin[0].nSequence = sequence
            if corrupt:
                big = [o for o in tx.vout if len(o.scriptPubKey) > 1000]
                script = bytearray(big[0].scriptPubKey)
                script[-50] ^= 0x01
                big[0].scriptPubKey = bytes(script)
            tx.rehash()
            return tx

        def verifications():
            with open(node0.debug_log_path, encoding="utf8") as f:
                return len([ln for ln in f if verify_line in ln])

        def package_result(tx):
            return node0.testmempoolaccept([p_hex, tx.serialize_with_witness().hex()])

        def child_entry(result):
            return [r for r in result if r["txid"] != p_txid][0]

        count = verifications()
        for sequence in (1000, 2000):
            result = package_result(package_variant(sequence))
            assert_equal(child_entry(result)["reject-reason"], "non-BIP68-final")
        result = package_result(package_variant(3000, corrupt=True))
        assert_equal(child_entry(result)["reject-reason"], "non-BIP68-final")
        assert_equal(verifications(), count)  # no signature was verified for any of them

        result = node0.testmempoolaccept([p_hex, child_hex])
        assert all(r["allowed"] for r in result), result
        assert_equal(verifications(), count + 1)  # the genuine package: one verification, for its one attestation

        result = package_result(package_variant(child_tx.vin[0].nSequence, corrupt=True))
        assert_equal(child_entry(result)["reject-reason"], "bad-demurrage-attestation-signature")
        assert_equal(verifications(), count + 2)

        self.log.info("A package rejected at the package stage (ancestor limit) after its members' own checks verifies nothing")
        self.restart_node(0, extra_args=self.extra_args[0] + ["-limitancestorcount=1", f"-mocktime={self.mt}"])
        self.set_mt(self.mt)
        node0.get_wallet_rpc(self.default_wallet_name).staking(False)
        wallet = node0.get_wallet_rpc("relay")  # loaded at startup; the old proxy is stale after a restart
        wallet.staking(False)
        count = verifications()
        result = node0.testmempoolaccept([p_hex, child_hex])
        assert not any(r.get("allowed") for r in result), result
        assert any("package-mempool-limits" in str(r.get("package-error", "")) for r in result), result
        assert_equal(verifications(), count)  # members passed their cheap checks; the package stage ended it
        # The same package with a corrupted signature is also turned away at the package stage, unverified.
        result = node0.testmempoolaccept([p_hex, package_variant(child_tx.vin[0].nSequence, corrupt=True).serialize_with_witness().hex()])
        assert any("package-mempool-limits" in str(r.get("package-error", "")) for r in result), result
        assert_equal(verifications(), count)
        self.restart_node(0, extra_args=self.extra_args[0] + [f"-mocktime={self.mt}"])
        self.set_mt(self.mt)
        node0.get_wallet_rpc(self.default_wallet_name).staking(False)
        wallet = node0.get_wallet_rpc("relay")
        wallet.staking(False)
        # Control: with the default limits the same package is verified once per attestation and accepted.
        result = node0.testmempoolaccept([p_hex, child_hex])
        assert all(r["allowed"] for r in result), result
        assert_equal(verifications(), count + 1)

        self.log.info("A is signed on node 0 from other inputs and confirms; B is now a validly signed attestation over an old state")
        for txid, vout in b_inputs:
            wallet.lockunspent(False, [{"txid": txid, "vout": vout}])  # A must not reuse B's inputs
        a_txid = wallet.senddemurrageattestation(attest_addr)["txid"]
        a_inputs = [(v["txid"], v["vout"]) for v in node0.getrawtransaction(a_txid, True)["vin"]]
        assert not set(a_inputs) & set(b_inputs), (a_inputs, b_inputs)
        self.generate(1, mining)
        assert_equal(node0.getrawtransaction(a_txid, True)["confirmations"], 1)

        peer = node0.add_p2p_connection(P2PInterface())
        with node0.assert_debug_log(["stale-demurrage-attestation-state"], unexpected_msgs=[verify_line]):
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

        self.log.info("The value boundary: a valid current attestation whose fee input decays at the next block")
        self.connect_nodes(0, 1)
        self.sync_blocks()
        boundary_addr = copy.getnewquantumaddress()["address"]
        wallet.sendtoaddress(address=boundary_addr, amount=Decimal("3"), change_address=wallet.getnewquantumaddress()["address"])
        self.generate(1, mining, node=node0)
        self.sync_blocks()
        boundary_height = node0.getblockcount()
        # The coin is created at boundary_height. Its grace period is 24 blocks (six months of four blocks): a
        # spend in the block at boundary_height + 24 is still free of demurrage, one block later it is not.
        # Sign at tip boundary_height + 23 (the wallet only uses a fee input that burns nothing next block).
        self.generate(23, mining, node=node0)
        self.sync_blocks()
        assert_equal(node0.getblockcount(), boundary_height + 23)
        boundary_utxo = [u for u in copy.listunspent(1) if u.get("address") == boundary_addr]
        assert_equal(len(boundary_utxo), 1)
        self.disconnect_nodes(0, 1)
        held = []
        for u in copy.listunspent(0):
            if (u["txid"], u["vout"]) != (boundary_utxo[0]["txid"], boundary_utxo[0]["vout"]) and u.get("address") != package_key_addr:
                copy.lockunspent(False, [{"txid": u["txid"], "vout": u["vout"]}])
                held.append({"txid": u["txid"], "vout": u["vout"]})
        x_txid = copy.senddemurrageattestation(package_key_addr)["txid"]
        x_decoded = node1.getrawtransaction(x_txid, True)
        assert_equal([(v["txid"], v["vout"]) for v in x_decoded["vin"]], [(boundary_utxo[0]["txid"], boundary_utxo[0]["vout"])])
        x_hex = node1.getrawtransaction(x_txid)
        copy.lockunspent(True, held)
        x_tx = from_hex(CTransaction(), x_hex)
        # One block later on node 0 alone: the fee input is now past its grace period for the next block.
        self.generate(1, mining, node=node0)
        assert_equal(node0.getblockcount(), boundary_height + 24)
        count = verifications()
        result = node0.testmempoolaccept([x_hex])[0]
        assert_equal(result["allowed"], False)
        # The input is worth less than at the tip, so the fee the wallet left is below the minimum now.
        assert_equal(result["reject-reason"], "bad-txns-fee-not-enough")
        peer = node0.add_p2p_connection(P2PInterface())
        with node0.assert_debug_log(["bad-txns-fee-not-enough"], unexpected_msgs=[verify_line]):
            peer.send_and_ping(msg_tx(x_tx))
        assert peer.is_connected, "a fee shortfall caused only by the next block's demurrage is not punished"
        assert x_txid not in node0.getrawmempool()
        peer.peer_disconnect()
        assert_equal(verifications(), count)

        self.log.info("The same attestation paying out more than the input is worth at either point is a consensus failure, unverified")
        short = copy_module.deepcopy(x_tx)
        change = [o for o in short.vout if len(o.scriptPubKey) <= 1000][0]
        change.nValue += 100 * COIN
        short.rehash()
        result = node0.testmempoolaccept([short.serialize_with_witness().hex()])[0]
        assert_equal(result["reject-reason"], "bad-txns-in-belowout")
        punished = node0.add_p2p_connection(P2PInterface())
        with node0.assert_debug_log(["bad-txns-in-belowout"], unexpected_msgs=[verify_line]):
            punished.send_message(msg_tx(short))
            punished.wait_for_disconnect()
        assert_equal(verifications(), count)


if __name__ == '__main__':
    DemurrageAttestationRelayTest().main()
