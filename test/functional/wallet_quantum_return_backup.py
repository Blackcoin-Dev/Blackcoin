#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""A new quantum stake return key is backed up and verified before it becomes the return address.

Quantum keys are random, so a wallet backup made before a key existed cannot recover coins paid to
it. A key made for the legacy-stake return address is therefore stored with a pending record (one
database transaction), backed up with key verification into -quantumkeybackupdir, and only then
saved as the return address. This test checks, on regtest, with no blocks needed:

 * creation writes and verifies a private backup before the address is active, and the backup
   restores the key; the unnamed and named wallets use their own folders, files 0600, folders 0700;
 * an unwritable backup directory leaves the wallet with no active address, reports the error
   apart from readiness, refuses the pending key through existing_address, and a later call
   retries the SAME key and succeeds;
 * a restart with a pending record retries the same key (explicitly, and by the wallet's own
   maintenance);
 * concurrent callers produce one key;
 * an encrypted wallet's backup is encrypted, and a locked or staking-only wallet creates nothing;
 * crashes after key insertion, after the backup file is installed, before activation and after
   activation (the test-only, test-chain-only -quantumreturncrashpoint option) leave a state the
   next start completes with the same key;
 * retention keeps the newest three verified backups and never deletes a foreign file;
 * the choice order: a label alone does not make the claim payout key, the configured one does.
"""
import os
import signal
import stat
from threading import Barrier, Thread
from urllib.parse import quote

from test_framework.authproxy import JSONRPCException
from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import (
    assert_equal,
    assert_raises_rpc_error,
    get_rpc_proxy,
)
from transition_t_final_util import LIFECYCLE_ARGS, TransitionTFinalTestBase

LABEL = "PoS - Quantum Stake Address"
# The test-only crash point ends the process with SIGKILL on POSIX (the exit status is the negated signal)
# and with TerminateProcess(7) on Windows.
CRASH_EXIT = 7 if os.name == "nt" else -signal.SIGKILL


def component(name):
    """The Python twin of QuantumKeyBackupWalletComponent for short names."""
    if name == "":
        return "default"
    out = "n_"
    for byte in name.encode():
        ch = chr(byte)
        if ("a" <= ch <= "z") or ("0" <= ch <= "9") or ch == "-":
            out += ch
        else:
            out += "_%02x" % byte
    return out


class QuantumReturnBackupTest(TransitionTFinalTestBase, BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        # Key creation is never automatic here: the calls below carry the consent.
        self.base_args = [a for a in LIFECYCLE_ARGS if not a.startswith("-qqallowautokeycreation")] + [
            "-quantumkeybackupdir=qkbackups",
        ]
        self.extra_args = [self.base_args]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    # ----- helpers -----
    def root(self):
        return os.path.join(self.nodes[0].chain_path, "qkbackups")

    def wallet_dir(self, name):
        return os.path.join(self.root(), component(name))

    def generations(self, name):
        """The wallet files of the verified generations (a manifest next to them), oldest first."""
        directory = self.wallet_dir(name)
        if not os.path.isdir(directory):
            return []
        files = sorted(f for f in os.listdir(directory) if f.startswith("quantum-wallet-") and f.endswith(".dat"))
        return [f for f in files if os.path.exists(os.path.join(directory, f + ".keys"))]

    def wallet_files(self, name):
        directory = self.wallet_dir(name)
        if not os.path.isdir(directory):
            return []
        return sorted(f for f in os.listdir(directory) if f.startswith("quantum-wallet-") and f.endswith(".dat"))

    def state(self, wallet):
        return wallet.getquantumstakereadiness()["stake_return"]

    def keys_with_label(self, wallet):
        try:
            return sorted(wallet.getaddressesbylabel(LABEL).keys())
        except JSONRPCException as error:
            assert_equal(error.error["code"], -11)  # no such label: no key
            return []

    def make_wallet(self, name, **kwargs):
        self.nodes[0].createwallet(name, load_on_startup=True, **kwargs)
        return self.nodes[0].get_wallet_rpc(name)

    def crash_at(self, point, name):
        """Restart the node so it ends at `point` of the preparation, run the call, wait for the exit."""
        node = self.nodes[0]
        self.restart_node(0, extra_args=self.base_args + ["-quantumreturncrashpoint=" + point])
        wallet = node.get_wallet_rpc(name)
        try:
            wallet.setquantumstakereturn({"allow_new_quantum_key": True})
        except Exception:  # the connection closes with the process
            pass
        else:
            raise AssertionError("the node did not stop at " + point)
        self.wait_until(lambda: node.is_node_stopped(expected_ret_code=CRASH_EXIT), timeout=60)
        self.start_node(0, extra_args=self.base_args)
        return node.get_wallet_rpc(name)

    def run_test(self):
        node = self.nodes[0]
        self.log.info("Creation: the backup is made and verified before the address is active")
        w1 = self.make_wallet("wone")
        assert_equal(self.generations("wone"), [])
        result = w1.setquantumstakereturn({"allow_new_quantum_key": True})
        assert_equal(result["created"], True)
        assert_equal(result["ready"], True)
        assert_equal(result["backup_verified"], True)
        address = result["address"]
        state = self.state(w1)
        assert_equal(state["ready"], True)
        assert_equal(state["address"], address)
        assert_equal(state["pending"], False)
        assert_equal(state["backup_verified"], True)
        generations = self.generations("wone")
        assert_equal(len(generations), 1)
        assert_equal(self.keys_with_label(w1), [address])
        backup = os.path.join(self.wallet_dir("wone"), generations[0])
        assert generations[0].startswith("quantum-wallet-") and "-h0000000000-" in generations[0]
        self.log.info("Permissions: directory 0700, wallet file and manifest 0600")
        assert_equal(stat.S_IMODE(os.stat(self.wallet_dir("wone")).st_mode), 0o700)
        assert_equal(stat.S_IMODE(os.stat(backup).st_mode), 0o600)
        assert_equal(stat.S_IMODE(os.stat(backup + ".keys").st_mode), 0o600)
        self.log.info("The backup restores the key")
        node.restorewallet("wone-restored", backup)
        assert_equal(node.get_wallet_rpc("wone-restored").getaddressinfo(address)["ismine"], True)
        # a second call changes nothing: saved destination first
        again = w1.setquantumstakereturn({"allow_new_quantum_key": True})
        assert_equal(again["address"], address)
        assert_equal(again["created"], False)
        assert_equal(len(self.generations("wone")), 1)
        assert_equal(self.keys_with_label(w1), [address])

        self.log.info("The unnamed wallet has its own folder 'default', apart from a wallet called default")
        unnamed = self.make_wallet("")
        unnamed_result = unnamed.setquantumstakereturn({"allow_new_quantum_key": True})
        assert unnamed_result["address"] != address
        assert_equal(len(self.generations("")), 1)
        assert os.path.isdir(os.path.join(self.root(), "default"))
        named_default = self.make_wallet("default")
        named_result = named_default.setquantumstakereturn({"allow_new_quantum_key": True})
        assert named_result["address"] != unnamed_result["address"]
        assert_equal(len(self.generations("default")), 1)
        assert os.path.isdir(os.path.join(self.root(), "n_default"))

        self.log.info("An unwritable backup directory: no active address, the error, the same key on retry")
        w2 = self.make_wallet("wtwo")
        os.chmod(self.root(), 0o500)
        try:
            assert_raises_rpc_error(-4, "wallet backup failed", w2.setquantumstakereturn, {"allow_new_quantum_key": True})
            state = self.state(w2)
            assert_equal(state["ready"], False)
            assert "address" not in state
            assert_equal(state["pending"], True)
            assert state["pending_error"]
            pending_address = state["pending_address"]
            assert_equal(state["backup_verified"], False)
            info = w2.getstakinginfo()
            assert_equal(info["legacy_stake_return_ready"], False)
            assert_equal(info["legacy_stake_return_pending"], True)
            assert_equal(info["legacy_stake_return_pending_address"], pending_address)
            assert info["legacy_stake_return_pending_error"]
            assert "NOT active" in info["legacy_staking_notice"]
            self.log.info("The pending key cannot be named through existing_address")
            assert_raises_rpc_error(-8, "waiting for its first verified wallet backup", w2.setquantumstakereturn,
                                    {"existing_address": pending_address})
            assert_equal(self.state(w2)["ready"], False)
            self.log.info("A second attempt reuses the same key, it makes no new one")
            assert_raises_rpc_error(-4, "wallet backup failed", w2.setquantumstakereturn, {"allow_new_quantum_key": True})
            assert_equal(self.state(w2)["pending_address"], pending_address)
            assert_equal(self.keys_with_label(w2), [pending_address])
            self.log.info("An unwritable wallet folder fails the same way")
        finally:
            os.chmod(self.root(), 0o700)
        os.makedirs(self.wallet_dir("wtwo"), mode=0o700, exist_ok=True)
        os.chmod(self.wallet_dir("wtwo"), 0o500)
        try:
            assert_raises_rpc_error(-4, "wallet backup failed", w2.setquantumstakereturn, {"allow_new_quantum_key": True})
            assert_equal(self.state(w2)["pending_address"], pending_address)
        finally:
            os.chmod(self.wallet_dir("wtwo"), 0o700)
        result = w2.setquantumstakereturn({"allow_new_quantum_key": True})
        assert_equal(result["address"], pending_address)
        assert_equal(result["created"], True)
        assert_equal(result["ready"], True)
        state = self.state(w2)
        assert_equal(state["pending"], False)
        assert_equal(state["ready"], True)
        assert_equal(state["backup_verified"], True)
        assert_equal(len(self.generations("wtwo")), 1)
        assert_equal(self.keys_with_label(w2), [pending_address])
        # no staged files are left behind
        assert_equal([f for f in os.listdir(self.wallet_dir("wtwo")) if f.startswith(".")], [])

        self.log.info("A restart with a pending record retries the same key (explicit call)")
        w3 = self.make_wallet("wthree")
        os.chmod(self.root(), 0o500)
        try:
            assert_raises_rpc_error(-4, "wallet backup failed", w3.setquantumstakereturn, {"allow_new_quantum_key": True})
        finally:
            os.chmod(self.root(), 0o700)
        pending_three = self.state(w3)["pending_address"]
        self.restart_node(0, extra_args=self.base_args)
        w3 = node.get_wallet_rpc("wthree")
        state = self.state(w3)
        assert_equal(state["ready"], False)
        assert_equal(state["pending"], True)
        assert_equal(state["pending_address"], pending_three)
        assert_raises_rpc_error(-8, "waiting for its first verified wallet backup", w3.setquantumstakereturn,
                                {"existing_address": pending_three})
        result = w3.setquantumstakereturn()  # no consent flag: a key that exists is completed, none is made
        assert_equal(result["address"], pending_three)
        assert_equal(self.state(w3)["ready"], True)
        assert_equal(self.keys_with_label(w3), [pending_three])

        self.log.info("A restart with a pending record retries the same key (the wallet's own maintenance)")
        w4 = self.make_wallet("wfour")
        os.chmod(self.root(), 0o500)
        try:
            assert_raises_rpc_error(-4, "wallet backup failed", w4.setquantumstakereturn, {"allow_new_quantum_key": True})
        finally:
            os.chmod(self.root(), 0o700)
        pending_four = self.state(w4)["pending_address"]
        self.restart_node(0, extra_args=self.base_args)
        w4 = node.get_wallet_rpc("wfour")
        assert_equal(self.state(w4)["pending"], True)

        def maintenance_done():
            node.mockscheduler(61)
            return self.state(w4)["ready"]

        self.wait_until(maintenance_done, timeout=60)
        assert_equal(self.state(w4)["address"], pending_four)
        assert_equal(self.state(w4)["pending"], False)
        assert_equal(self.keys_with_label(w4), [pending_four])

        self.log.info("Concurrent callers produce one key and one backup")
        w5 = self.make_wallet("wfive")
        url = "%s/wallet/%s" % (node.url, quote("wfive", safe=""))
        callers = 6
        barrier = Barrier(callers)
        results, errors = [], []

        def call():
            rpc = get_rpc_proxy(url, 0, timeout=120, coveragedir=node.coverage_dir)
            barrier.wait()
            try:
                results.append(rpc.setquantumstakereturn({"allow_new_quantum_key": True})["address"])
            except Exception as error:  # pylint: disable=broad-except
                errors.append(str(error))

        threads = [Thread(target=call, daemon=True) for _ in range(callers)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=180)
        assert_equal(errors, [])
        assert_equal(len(results), callers)
        assert_equal(len(set(results)), 1)
        assert_equal(self.keys_with_label(w5), [results[0]])
        assert_equal(len(self.generations("wfive")), 1)

        self.log.info("An encrypted wallet: the backup is encrypted, and it is made only under a normal unlock")
        enc = self.make_wallet("wenc", passphrase="correct horse")
        assert_raises_rpc_error(-4, "unlock state", enc.setquantumstakereturn, {"allow_new_quantum_key": True})
        enc.walletpassphrase("correct horse", 600, True)  # staking only
        assert_raises_rpc_error(-4, "unlock state", enc.setquantumstakereturn, {"allow_new_quantum_key": True})
        assert_equal(self.keys_with_label(enc), [])
        assert_equal(self.wallet_files("wenc"), [])
        assert_equal(self.state(enc)["pending"], False)
        enc.walletlock()
        enc.walletpassphrase("correct horse", 600)
        result = enc.setquantumstakereturn({"allow_new_quantum_key": True})
        assert_equal(result["ready"], True)
        generation = os.path.join(self.wallet_dir("wenc"), self.generations("wenc")[0])
        node.restorewallet("wenc-restored", generation)
        restored = node.get_wallet_rpc("wenc-restored")
        assert "unlocked_until" in restored.getwalletinfo(), "the backup of an encrypted wallet must stay encrypted"
        assert_raises_rpc_error(-13, "walletpassphrase", restored.getnewquantumaddress)
        restored.walletpassphrase("correct horse", 60)
        assert_equal(restored.getaddressinfo(result["address"])["ismine"], True)

        self.log.info("A locked wallet after a restart keeps its pending record and completes it when unlocked")
        locked = self.make_wallet("wlocked", passphrase="open sesame")
        locked.walletpassphrase("open sesame", 600)
        os.chmod(self.root(), 0o500)
        try:
            assert_raises_rpc_error(-4, "wallet backup failed", locked.setquantumstakereturn, {"allow_new_quantum_key": True})
        finally:
            os.chmod(self.root(), 0o700)
        pending_locked = self.state(locked)["pending_address"]
        self.restart_node(0, extra_args=self.base_args)
        locked = node.get_wallet_rpc("wlocked")
        assert_equal(self.state(locked)["pending"], True)
        assert_raises_rpc_error(-4, "waiting for its wallet backup", locked.setquantumstakereturn)  # locked: no retry
        assert_equal(self.state(locked)["pending"], True)
        locked.walletpassphrase("open sesame", 600)
        assert_equal(locked.setquantumstakereturn()["address"], pending_locked)
        assert_equal(self.state(locked)["pending"], False)

        self.log.info("Crash after the key insertion: key and record are durable, no backup yet")
        wc = self.make_wallet("wcrashkey")
        wc = self.crash_at("after_key_insertion", "wcrashkey")
        state = self.state(wc)
        assert_equal(state["pending"], True)
        assert_equal(state["ready"], False)
        key_address = state["pending_address"]
        assert_equal(self.wallet_files("wcrashkey"), [])
        assert_equal(self.keys_with_label(wc), [key_address])
        result = wc.setquantumstakereturn()
        assert_equal(result["address"], key_address)
        assert_equal(self.keys_with_label(wc), [key_address])
        assert_equal(len(self.generations("wcrashkey")), 1)

        self.log.info("Crash after the backup file is installed (no manifest yet): the same key, a new backup")
        wb = self.make_wallet("wcrashfile")
        wb = self.crash_at("after_backup_install", "wcrashfile")
        state = self.state(wb)
        assert_equal(state["pending"], True)
        assert_equal(state["ready"], False)
        key_address = state["pending_address"]
        assert_equal(len(self.wallet_files("wcrashfile")), 1)
        assert_equal(self.generations("wcrashfile"), [])  # the file is not a counted generation
        orphan = self.wallet_files("wcrashfile")[0]
        result = wb.setquantumstakereturn()
        assert_equal(result["address"], key_address)
        assert_equal(len(self.generations("wcrashfile")), 1)
        assert orphan in self.wallet_files("wcrashfile"), "a file with no manifest is never deleted"
        assert_equal(self.keys_with_label(wb), [key_address])

        self.log.info("Crash just before the activation (backup and manifest are in place)")
        wa = self.make_wallet("wcrashact")
        wa = self.crash_at("before_activation", "wcrashact")
        state = self.state(wa)
        assert_equal(state["pending"], True)
        assert_equal(state["ready"], False)
        key_address = state["pending_address"]
        assert_equal(len(self.generations("wcrashact")), 1)
        result = wa.setquantumstakereturn()
        assert_equal(result["address"], key_address)
        assert_equal(len(self.generations("wcrashact")), 2)
        assert_equal(self.state(wa)["ready"], True)

        self.log.info("Crash just after the activation: the address is active and nothing is pending")
        wd = self.make_wallet("wcrashdone")
        wd = self.crash_at("after_activation", "wcrashdone")
        state = self.state(wd)
        assert_equal(state["pending"], False)
        assert_equal(state["ready"], True)
        assert_equal(state["backup_verified"], True)
        assert_equal(len(self.generations("wcrashdone")), 1)
        assert_equal(self.keys_with_label(wd), [state["address"]])

        self.log.info("Retention: the three newest verified backups stay, a foreign file is never touched")
        wr = self.make_wallet("wretain")
        directory = self.wallet_dir("wretain")
        os.makedirs(directory, mode=0o700, exist_ok=True)
        foreign = os.path.join(directory, "my-own-notes.txt")
        with open(foreign, "w", encoding="utf-8") as handle:
            handle.write("not written by the wallet")
        look_alike = os.path.join(directory, "quantum-wallet-note.dat")
        with open(look_alike, "w", encoding="utf-8") as handle:
            handle.write("not a generation")
        for _ in range(4):  # four crashes before the activation: four verified generations, nothing active
            wr = self.crash_at("before_activation", "wretain")
            assert_equal(self.state(wr)["ready"], False)
        assert_equal(len(self.generations("wretain")), 4)
        assert_equal(wr.setquantumstakereturn()["ready"], True)
        remaining = self.generations("wretain")
        assert_equal(len(remaining), 3)
        assert os.path.exists(foreign) and os.path.exists(look_alike)
        for name in remaining:
            assert os.path.exists(os.path.join(directory, name + ".keys"))
        assert_equal(len([f for f in os.listdir(directory) if f.endswith(".keys")]), 3)

        self.log.info("The choice order: a label does not make the claim payout key, the configured one does")
        wo = self.make_wallet("wclaim")
        older = wo.getnewquantumaddress("some older key")["address"]
        claim = wo.getnewquantumaddress("PoW - Quantum Claim Address")["address"]
        newest_pos = wo.getnewquantumaddress(LABEL)["address"]
        # the label ranking (as before) puts the PoS-labelled key first when nothing else identifies a claim key
        result = wo.setquantumstakereturn()
        assert_equal(result["address"], newest_pos)
        assert_equal(result["created"], False)
        wp = self.make_wallet("wclaimtwo")
        older = wp.getnewquantumaddress("some older key")["address"]
        claim = wp.getnewquantumaddress("PoW - Quantum Claim Address")["address"]
        self.restart_node(0, extra_args=self.base_args + ["-qqpowpayoutaddress=" + claim])
        wp = node.get_wallet_rpc("wclaimtwo")
        newest_pos = wp.getnewquantumaddress(LABEL)["address"]
        result = wp.setquantumstakereturn()
        assert_equal(result["address"], claim)
        assert_equal(result["created"], False)
        assert_equal(len(self.generations("wclaimtwo")), 0)  # a reused key makes no backup, no new key
        assert_equal(wp.getaddressesbylabel(LABEL).keys(), {newest_pos})


if __name__ == '__main__':
    QuantumReturnBackupTest().main()
