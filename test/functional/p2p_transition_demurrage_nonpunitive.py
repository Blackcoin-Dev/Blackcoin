#!/usr/bin/env python3
"""A peer is not punished for a transaction that demurrage invalidated at the next block.

Regtest: Gold Rush ends at G, Migration ends at M, Final (and demurrage) starts at
F = M + 1. With -qqdemurrageblockspermonth=4 the grace period is 24 blocks and a
coin locks after 96 inactive blocks, counted from F for coins created earlier.

A quantum transaction that spends an input at its decayed value is valid for the
block that is next when it is built and invalid one block later, because the
effective value of the input fell (value case) or reached zero (terminal case).
Before the fix the relaying peer received 100 misbehavior points for that.

Checked at the exact boundary heights, with an ordinary inbound peer (no NoBan):
 - value case: valid with the next block at inactive == grace, rejected one block later;
 - terminal case: valid with the next block at inactive == zero - 1, rejected one block later;
 - neither rejection punishes the peer;
 - controls that fail the value or locked-coin check already at the earlier state
   (an output above the input value, a coin that was already locked) still do.
"""
import time
from decimal import Decimal

from test_framework.messages import msg_tx, tx_from_hex
from test_framework.p2p import P2PInterface
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal

BLOCKS = 29
G = 1 + BLOCKS  # last Gold Rush block
M = G + 4       # last Migration block
F = M + 1       # first Final block, demurrage starts
GRACE = 24      # 6 * blocks per month
ZERO = 96       # 24 * blocks per month
FEE = Decimal("0.01")


class TransitionDemurrageNonPunitiveTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)

    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.extra_args = [[
            "-allowunsafequantumkeyrpc=1", "-qqallowautokeycreation=1", "-staketimio=50",
            "-shadowwhitelistheight=1", f"-shadowgoldrushblocks={BLOCKS}",
            f"-qqgoldrushendheight={G}", f"-qqmigrationendheight={M}",
            "-qqdemurrageblockspermonth=4",
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
        node = self.nodes[0]
        peer = node.add_p2p_connection(P2PInterface())
        info = [p for p in node.getpeerinfo() if p["id"] == max(x["id"] for x in node.getpeerinfo())][0]
        assert info["inbound"]
        assert_equal(info["permissions"], [])
        return peer

    def relay_not_punished(self, hexstr):
        node = self.nodes[0]
        txid = tx_from_hex(hexstr).rehash()
        peer = self.new_peer()
        with node.assert_debug_log(expected_msgs=[txid], unexpected_msgs=["Misbehaving", "discourag"]):
            peer.send_message(msg_tx(tx_from_hex(hexstr)))
            peer.sync_with_ping()
        assert peer.is_connected
        assert txid not in node.getrawmempool()
        peer.peer_disconnect()
        peer.wait_for_disconnect()

    def relay_punished(self, hexstr):
        node = self.nodes[0]
        peer = self.new_peer()
        with node.assert_debug_log(expected_msgs=["(0 -> 100) DISCOURAGE THRESHOLD EXCEEDED"]):
            peer.send_message(msg_tx(tx_from_hex(hexstr)))
            peer.wait_for_disconnect()

    def spend(self, wallet, utxo, destination, amount):
        node = self.nodes[0]
        raw = node.createrawtransaction([{"txid": utxo["txid"], "vout": utxo["vout"]}], [{destination: amount}])
        key = wallet.dumpquantumkey(utxo["address"])
        signed = node.signrawtransactionwithquantumkey(
            raw, [{"public_key": key["public_key"], "private_key": key["private_key"]}])
        assert_equal(signed["complete"], True)
        return signed["hex"]

    def accept(self, hexstr):
        # maxfeerate 0: the terminal-case transaction pays almost its whole input as fee
        return self.nodes[0].testmempoolaccept([hexstr], 0)[0]

    def run_test(self):
        node = self.nodes[0]
        wallet = node.get_wallet_rpc(self.default_wallet_name)
        wallet.staking(False)
        self.mocktime = (int(time.time()) & ~0xf) + 16
        node.setmocktime(self.mocktime)

        sources = [wallet.getnewaddress("", "legacy") for _ in range(4)]
        pow_addr = wallet.getnewaddress("", "legacy")
        for address in sources:
            self.mine(1, address)
        self.mine(M - 1 - node.getblockcount(), pow_addr)

        self.log.info("Migrate three legacy coins to quantum outputs in the last Migration block")
        quantum = [wallet.getnewquantumaddress()["address"] for _ in range(3)]
        for legacy, destination in zip(sources[:3], quantum):
            utxo = wallet.listunspent(1, 9999999, [legacy])[0]
            raw = node.createrawtransaction([{"txid": utxo["txid"], "vout": utxo["vout"]}],
                                            [{destination: Decimal(str(utxo["amount"])) - FEE}])
            signed = wallet.signrawtransactionwithwallet(raw)
            assert_equal(signed["complete"], True)
            node.sendrawtransaction(signed["hex"])
        self.mine(1, pow_addr)
        assert_equal(node.getblockcount(), M)
        assert_equal(node.getquantumquasarinfo()["next_block_phase"], "final_lockout")
        utxos = [wallet.listunspent(1, 9999999, [address])[0] for address in quantum]
        nominal = [Decimal(str(u["amount"])) for u in utxos]

        self.log.info("Final starts at F; mine Final blocks to a quantum address up to the last exempt tip")
        miner = wallet.getnewquantumaddress()["address"]
        # Inactive blocks of a spend at height h are h - F (the coin was created before F).
        # The next block is exempt while h - F <= GRACE, so the last exempt tip is F + GRACE - 1.
        value_tip = F + GRACE - 1
        self.mine(value_tip - node.getblockcount(), miner)
        assert_equal(node.getblockcount(), value_tip)
        assert node.getcirculatingsupply()["demurrage_active"]

        self.log.info("Value case: built for a next block at inactive == GRACE, so the input is not decayed")
        decayed_value_tx = self.spend(wallet, utxos[0], wallet.getnewquantumaddress()["address"], nominal[0] - FEE)
        assert self.accept(decayed_value_tx)["allowed"], self.accept(decayed_value_tx)
        # Controls: more output than the whole input is invalid at both blocks.
        too_much = self.spend(wallet, utxos[1], wallet.getnewquantumaddress()["address"], nominal[1] + Decimal("0.00000001"))
        assert_equal(self.accept(too_much)["reject-reason"], "bad-txns-in-belowout")

        self.mine(1, miner)
        assert_equal(node.getblockcount(), value_tip + 1)
        result = self.accept(decayed_value_tx)
        assert not result["allowed"]
        assert_equal(result["reject-reason"], "bad-txns-in-belowout")
        self.log.info("A peer that relays the transaction valid one block earlier is not punished")
        self.relay_not_punished(decayed_value_tx)
        self.log.info("An output above the whole input value is still punished")
        self.relay_punished(too_much)

        self.log.info("Terminal case: built for the last block before the coin locks")
        terminal_tip = F + ZERO - 2  # next block h = F + ZERO - 1, inactive == ZERO - 1
        self.mine(terminal_tip - node.getblockcount(), miner)
        assert_equal(node.getblockcount(), terminal_tip)
        small = nominal[2] / 100  # the effective value there is about 2.7 percent of nominal
        terminal_tx = self.spend(wallet, utxos[2], wallet.getnewquantumaddress()["address"], small)
        assert self.accept(terminal_tx)["allowed"], self.accept(terminal_tx)
        self.mine(1, miner)
        assert_equal(node.getblockcount(), terminal_tip + 1)
        result = self.accept(terminal_tx)
        assert not result["allowed"]
        assert_equal(result["reject-reason"], "bad-txns-spends-locked-coin")
        self.log.info("A peer that relays the transaction valid one block earlier is not punished")
        self.relay_not_punished(terminal_tx)

        self.log.info("A coin that was already locked one block earlier is still punished")
        self.mine(1, miner)
        assert_equal(node.getblockcount(), terminal_tip + 2)
        result = self.accept(terminal_tx)
        assert_equal(result["reject-reason"], "bad-txns-spends-locked-coin")
        self.relay_punished(terminal_tx)


if __name__ == '__main__':
    TransitionDemurrageNonPunitiveTest().main()
