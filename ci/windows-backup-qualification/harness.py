#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Native Windows qualification harness for the quantum stake return key backup.

It starts the real blackcoind.exe on regtest (one data directory per case), talks JSON-RPC over HTTP with cookie
authentication, creates plain and encrypted descriptor wallets, authorises one new return key the way
test/functional/wallet_quantum_return_backup.py does, and asserts one result per case. Every case writes a JSON
file into the results directory. A case whose infrastructure could not be set up is "unresolved", and an
unresolved case fails the run exactly as a failed one does.

Regtest only. Standard library only. Meant to run as an ordinary (non-administrator) Windows user.
"""

import argparse
import base64
import datetime
import hashlib
import http.client
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import traceback
import urllib.parse

# The same options as LIFECYCLE_ARGS in test/functional/transition_t_final_util.py without
# -qqallowautokeycreation: key creation is never automatic here, the calls carry the consent. -allowunsafequantumkeyrpc
# makes dumpquantumkey available, which is how a restored key is compared with the key that was backed up.
LIFECYCLE_ARGS = [
    "-allowunsafequantumkeyrpc=1",
    "-txindex=1",
    "-staketimio=50",
    "-shadowwhitelistheight=1",
    "-shadowgoldrushblocks=60",
    "-qqgoldrushendheight=62",
    "-qqmigrationendheight=92",
]
BASE_ARGS = [
    "-regtest", "-server=1", "-listen=0", "-dnsseed=0", "-discover=0", "-fixedseeds=0", "-connect=0",
    "-printtoconsole=0", "-rpcbind=127.0.0.1", "-rpcallowip=127.0.0.1",
]
PASSPHRASE = "correct horse battery"
# The test-only crash point ends the daemon with TerminateProcess(7) on Windows (src/wallet/staking.cpp).
WINDOWS_CRASH_EXIT = 7
CRASH_POINTS = ("after_key_insertion", "after_backup_install", "before_activation", "after_activation")
LOG_INTEREST = re.compile(r"quantum|backup|durab|flush|Unable to|not active|FlushFileBuffers", re.IGNORECASE)

# Daemon error texts, from src/wallet/quantum_return_backup.cpp (lines named here are in the 30.1.7 tree):
#  - EnsureQuantumKeyBackupDirectory, l.355:  "cannot make the backup directory <path> durable[: <reason>]"
#  - FlushDirectoryWindows, l.121:            "it cannot be opened for writing: <Win32ErrorString>"  ("Access is denied. (5)")
#  - FlushDirectoryWindows, l.102 and l.131:  "its volume cannot be identified: ..." or "... not on a local volume that
#                                             has a volume GUID path (a network share, ...)"
#  - QuantumBackupVolumeRejection, l.265-268: "... network share (file system X) ..." / "... file system fat32 ..."
#  - CommitOfEntryIsInjectedToFail, l.363:    "cannot make the entry of the backup directory <path> durable"
DURABLE_RE = re.compile(r"cannot make the backup directory .* durable", re.IGNORECASE | re.DOTALL)
DENIED_RE = re.compile(r"access is denied", re.IGNORECASE)
UNSUPPORTED_VOLUME_RE = re.compile(
    r"network share|volume GUID path|volume cannot be identified|local NTFS volume", re.IGNORECASE)
FAT32_RE = re.compile(r"file system fat32", re.IGNORECASE)
ENTRY_FAIL_RE = re.compile(r"cannot make the entry of the backup directory .* durable", re.IGNORECASE | re.DOTALL)
GENERATION_RE = re.compile(r"^quantum-wallet-[0-9]{8}T[0-9]{6}Z-h[0-9]{10}-[0-9a-f]{16}\.dat$")
SEED_GENERATION = "quantum-wallet-20260101T000000Z-h0000000000-0123456789abcdef.dat"


class RpcError(Exception):
    def __init__(self, code, message):
        super().__init__("RPC error %s: %s" % (code, message))
        self.code = code
        self.message = message


class RpcUnavailable(Exception):
    """The node cannot be reached (not started yet, stopped, crashed)."""


class CheckFailed(Exception):
    """A pass criterion of a case was not met."""


class Unresolved(Exception):
    """The infrastructure a case needs could not be set up: the case is neither passed nor failed."""


def check(condition, message):
    if not condition:
        raise CheckFailed(message)


def precondition(condition, message):
    if not condition:
        raise Unresolved(message)


# ----- pure helpers (self-tested on any platform) -----
def component(name):
    """The Python twin of QuantumKeyBackupWalletComponent (src/wallet/quantum_return_backup.cpp, l.223-243)."""
    if name == "":
        return "default"
    out = "n_"
    for byte in name.encode():
        ch = chr(byte)
        if ("a" <= ch <= "z") or ("0" <= ch <= "9") or ch == "-":
            out += ch
        else:
            out += "_%02x" % byte
    if len(out) > 80:
        out = out[:50] + "~" + hashlib.sha256(name.encode()).hexdigest()[:32]
    return out


def generation_manifest(file_name, sequence, keys=()):
    """The manifest text of one generation (WriteQuantumKeyBackupManifest, l.479-481)."""
    text = "quantum-key-backup-manifest 1\nfile %s\nsequence %d\nkeys %d\n" % (file_name, sequence, len(keys))
    for key in keys:
        text += key + "\n"
    return text + "end\n"


def seed_generation(directory):
    """Put one valid earlier generation into directory (a wallet file and its manifest); return its file name."""
    os.makedirs(directory, exist_ok=True)
    wallet_path = os.path.join(directory, SEED_GENERATION)
    with open(wallet_path, "wb") as handle:
        handle.write(b"earlier generation, not a real wallet\n")
    with open(os.path.join(directory, SEED_GENERATION + ".keys"), "w", encoding="utf-8", newline="\n") as handle:
        handle.write(generation_manifest(SEED_GENERATION, 1))
    return SEED_GENERATION


def parse_manifest(text):
    """The inverse of generation_manifest: {"file", "sequence", "keys"}; ValueError when the text is not a manifest."""
    lines = text.splitlines()
    if len(lines) < 5 or lines[0] != "quantum-key-backup-manifest 1" or lines[-1] != "end":
        raise ValueError("not a quantum key backup manifest")
    fields = {}
    for line, name in zip(lines[1:4], ("file", "sequence", "keys")):
        key, _, value = line.partition(" ")
        if key != name or not value:
            raise ValueError("manifest line %r is not %r" % (line, name))
        fields[name] = value
    keys = lines[4:-1]
    if len(keys) != int(fields["keys"]):
        raise ValueError("the manifest says %s keys and lists %d" % (fields["keys"], len(keys)))
    return {"file": fields["file"], "sequence": int(fields["sequence"]), "keys": keys}


def read_generation(directory, name):
    """The parsed manifest of one generation (name = wallet file name)."""
    with open(os.path.join(directory, name + ".keys"), "r", encoding="utf-8") as handle:
        return parse_manifest(handle.read())


def generation_files(names):
    """The directory listing of these generations: each wallet file and the manifest next to it."""
    return set(names) | {name + ".keys" for name in names}


def expected_survivors(sequences, keep=3):
    """Which generations the pruner leaves when every generation holds the same keys (so no older one is the only
    holder of a live key): the newest `keep` by sequence (SelectQuantumKeyBackupsToPrune, l.411-441). sequences is
    {file name: sequence}."""
    ordered = sorted(sequences, key=lambda name: (sequences[name], name), reverse=True)
    return set(ordered[:keep])


VOLUME_GUID_RE = re.compile(r"^(\\\\\?\\Volume\{[0-9A-Fa-f-]+\}\\)", re.IGNORECASE)


def volume_guid_prefix(final_path):
    """The volume-GUID prefix (the part up to the closing brace and its backslash) of a GetFinalPathNameByHandleW result in
    VOLUME_NAME_GUID form, lower-cased, or None when the path is not in that form."""
    match = VOLUME_GUID_RE.match(final_path or "")
    return match.group(1).lower() if match else None


def snapshot(directory):
    """{file name: sha256} of the files directly in directory ({} when it does not exist)."""
    result = {}
    if not os.path.isdir(directory):
        return result
    for name in sorted(os.listdir(directory)):
        path = os.path.join(directory, name)
        if os.path.isfile(path):
            with open(path, "rb") as handle:
                result[name] = hashlib.sha256(handle.read()).hexdigest()
    return result


def generations(directory):
    """Wallet files with a manifest next to them (the verified generations), by name."""
    if not os.path.isdir(directory):
        return []
    names = sorted(n for n in os.listdir(directory) if GENERATION_RE.match(n))
    return [n for n in names if os.path.exists(os.path.join(directory, n + ".keys"))]


def wallet_files(directory):
    if not os.path.isdir(directory):
        return []
    return sorted(n for n in os.listdir(directory) if GENERATION_RE.match(n))


def default_backup_root(datadir):
    return os.path.join(datadir, "regtest", "quantum-key-backups")


def file_sha256(path):
    """SHA-256 of a file ("" when it cannot be read): recorded so the results name the exact bytes that ran."""
    try:
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError:
        return ""


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def write_json(path, document):
    temporary = path + ".tmp"
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(document, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, path)


def safe_name(name):
    return re.sub(r"[^A-Za-z0-9._-]", "_", name)


# ----- JSON-RPC over HTTP with cookie authentication -----
class Rpc:
    def __init__(self, port, cookie_file, wallet=None, timeout=180, host="127.0.0.1"):
        self.host = host
        self.port = port
        self.cookie_file = cookie_file
        self.wallet = wallet
        self.timeout = timeout
        self._id = 0

    def _auth(self):
        try:
            with open(self.cookie_file, "rb") as handle:
                return "Basic " + base64.b64encode(handle.read().strip()).decode()
        except OSError as error:
            raise RpcUnavailable("no cookie file yet: %s" % error)

    def path(self):
        return "/" if self.wallet is None else "/wallet/" + urllib.parse.quote(self.wallet, safe="")

    def call(self, method, *args, **kwargs):
        if args and kwargs:
            raise ValueError("positional or named parameters, not both")
        self._id += 1
        body = json.dumps({"jsonrpc": "1.0", "id": self._id, "method": method,
                           "params": kwargs if kwargs else list(args)})
        headers = {"Authorization": self._auth(), "Content-Type": "application/json"}
        try:
            connection = http.client.HTTPConnection(self.host, self.port, timeout=self.timeout)
            try:
                connection.request("POST", self.path(), body, headers)
                response = connection.getresponse()
                data = response.read()
            finally:
                connection.close()
        except (OSError, http.client.HTTPException) as error:
            raise RpcUnavailable("%s: %s" % (type(error).__name__, error))
        try:
            document = json.loads(data.decode("utf-8"))
        except ValueError:
            raise RpcUnavailable("HTTP %s with a body that is not JSON" % response.status)
        if document.get("error"):
            raise RpcError(document["error"].get("code"), document["error"].get("message", ""))
        return document.get("result")

    def __getattr__(self, method):
        if method.startswith("_"):
            raise AttributeError(method)
        return lambda *args, **kwargs: self.call(method, *args, **kwargs)


# ----- Windows volume facts (ctypes; empty elsewhere) -----
def volume_facts(path):
    """File system name and drive type of the volume that holds path, as Windows reports them."""
    if os.name != "nt":
        return {}
    import ctypes
    from ctypes import wintypes
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    root = ctypes.create_unicode_buffer(1024)
    if not kernel32.GetVolumePathNameW(os.path.abspath(path), root, 1024):
        return {"error": "GetVolumePathNameW failed: %d" % ctypes.get_last_error()}
    fs_name = ctypes.create_unicode_buffer(64)
    serial = wintypes.DWORD(0)
    if not kernel32.GetVolumeInformationW(root.value, None, 0, ctypes.byref(serial), None, None, fs_name, 64):
        return {"volume_root": root.value, "error": "GetVolumeInformationW failed: %d" % ctypes.get_last_error()}
    drive_type = {0: "unknown", 1: "no root", 2: "removable", 3: "fixed", 4: "remote", 5: "cdrom", 6: "ramdisk"}
    return {"volume_root": root.value, "file_system": fs_name.value, "serial": "%08x" % serial.value,
            "drive_type": drive_type.get(kernel32.GetDriveTypeW(root.value), "unknown")}


def volume_identity(path):
    """The volume of path the way the product identifies it (src/util/fs_helpers.cpp): open the path, ask
    GetFinalPathNameByHandleW for the VOLUME_NAME_GUID form, and keep the `\\\\?\\Volume{guid}\\` prefix. A drive made by
    subst resolves to the volume of its underlying folder here, which a drive letter or a path prefix would not show."""
    if os.name != "nt":
        return {}
    import ctypes
    from ctypes import wintypes
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateFileW.restype = wintypes.HANDLE
    kernel32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID, wintypes.DWORD,
                                     wintypes.DWORD, wintypes.HANDLE]
    kernel32.GetFinalPathNameByHandleW.restype = wintypes.DWORD
    kernel32.GetFinalPathNameByHandleW.argtypes = [wintypes.HANDLE, wintypes.LPWSTR, wintypes.DWORD, wintypes.DWORD]
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    file_share_all, open_existing, backup_semantics, volume_name_guid = 7, 3, 0x02000000, 0x1
    handle = kernel32.CreateFileW(os.path.abspath(path), 0, file_share_all, None, open_existing, backup_semantics, None)
    if handle is None or handle == wintypes.HANDLE(-1).value:
        return {"path": path, "error": "CreateFileW failed: %d" % ctypes.get_last_error()}
    try:
        size = 1024
        buffer = ctypes.create_unicode_buffer(size)
        length = kernel32.GetFinalPathNameByHandleW(handle, buffer, size, volume_name_guid)
        if length > size:
            size = length + 1
            buffer = ctypes.create_unicode_buffer(size)
            length = kernel32.GetFinalPathNameByHandleW(handle, buffer, size, volume_name_guid)
        if length == 0:
            return {"path": path, "error": "GetFinalPathNameByHandleW failed: %d" % ctypes.get_last_error()}
        return {"path": path, "final_path": buffer.value, "volume_guid": volume_guid_prefix(buffer.value)}
    finally:
        kernel32.CloseHandle(handle)


def run_command(arguments, timeout=120):
    """Run a command; return (exit code, combined output)."""
    try:
        completed = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout,
                                   check=False)
        return completed.returncode, completed.stdout.decode("utf-8", "replace").strip()
    except (OSError, subprocess.SubprocessError) as error:
        return -1, "%s: %s" % (type(error).__name__, error)


def run_checked(what, arguments, timeout=120):
    """run_command for infrastructure commands (net, subst, icacls, mklink): a nonzero exit code makes the case
    unresolved, never a silent success. Returns the output."""
    code, output = run_command(arguments, timeout)
    precondition(code == 0, "%s failed with exit code %s: %s" % (what, code, output))
    return output


# ----- a daemon -----
class Node:
    def __init__(self, env, datadir, extra_args=(), label="node"):
        self.env = env
        self.datadir = datadir
        self.extra_args = list(extra_args)
        self.label = label
        self.port = free_port()
        self.rpc_port = free_port()
        self.process = None
        self.stdout = None
        self.forced_kill = False
        self.cookie = os.path.join(datadir, "regtest", ".cookie")

    @property
    def log_file(self):
        return os.path.join(self.datadir, "regtest", "debug.log")

    def start(self, extra_args=None, timeout=240):
        if extra_args is not None:
            self.extra_args = list(extra_args)
        os.makedirs(self.datadir, exist_ok=True)
        if os.path.exists(self.cookie):
            os.remove(self.cookie)
        arguments = [self.env.daemon] + BASE_ARGS + LIFECYCLE_ARGS + [
            "-datadir=" + self.datadir, "-port=%d" % self.port, "-rpcport=%d" % self.rpc_port] + self.extra_args
        console_path = os.path.join(self.env.logs, "%s-%s.out" % (safe_name(self.env.case), self.label))
        self.stdout = open(console_path, "ab")
        self.process = subprocess.Popen(arguments, stdout=self.stdout, stderr=subprocess.STDOUT)
        if self not in self.env.nodes:
            self.env.nodes.append(self)
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.process.poll() is not None:
                raise CheckFailed("the daemon exited with code %s before it was ready (see %s)" % (
                    self.process.returncode, self.stdout.name))
            try:
                self.rpc().getblockcount()
                return self
            except RpcUnavailable:
                pass
            except RpcError as error:
                if error.code != -28:  # still warming up
                    raise
            time.sleep(0.5)
        raise CheckFailed("the daemon was not ready after %d seconds" % timeout)

    def rpc(self, wallet=None):
        return Rpc(self.rpc_port, self.cookie, wallet=wallet)

    def wait_wallet(self, name, timeout=90):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                if name in self.rpc().listwallets():
                    return self.rpc(wallet=name)
            except (RpcUnavailable, RpcError):
                pass
            time.sleep(0.5)
        raise CheckFailed("wallet %r was not loaded after the restart" % name)

    def wait_exit(self, timeout=90):
        try:
            return self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise CheckFailed("the daemon did not exit within %d seconds" % timeout)

    def stop(self, timeout=120, clean=True):
        """Ask the daemon to stop. A stop that does not finish within the timeout ends in a kill of this harness's own
        child (by its handle); that is recorded, and with clean=True it fails the case, because every case that restarts
        a node relies on the previous run having shut down normally."""
        if self.process is None or self.process.poll() is not None:
            return
        try:
            self.rpc().stop()
        except (RpcUnavailable, RpcError):
            pass
        try:
            self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.forced_kill = True
            self.env.forced_kills.append("%s/%s after %d s" % (self.env.case, self.label, timeout))
            self.process.kill()
            self.process.wait(timeout=30)
            if clean:
                raise CheckFailed("the daemon %s did not stop within %d seconds and was killed: the restart that follows "
                                  "would not test a clean shutdown" % (self.label, timeout))

    def restart(self, extra_args=None):
        self.stop()
        return self.start(extra_args)

    def save_full_log(self, destination):
        """The whole debug.log of this daemon, copied next to the results (the data directory is deleted afterwards)."""
        try:
            shutil.copyfile(self.log_file, destination)
            return True
        except OSError:
            return False

    def log_excerpt(self, limit=60):
        try:
            with open(self.log_file, "r", encoding="utf-8", errors="replace") as handle:
                lines = [line.rstrip() for line in handle if LOG_INTEREST.search(line)]
        except OSError:
            return []
        return lines[-limit:]


class Env:
    """What every case needs: the layout the administrator script wrote, the results folder, the daemon."""

    def __init__(self, layout, results, daemon, probe):
        self.layout = layout
        self.results = results
        self.logs = os.path.join(results, "logs")
        os.makedirs(self.logs, exist_ok=True)
        self.daemon = daemon
        self.probe = probe
        self.nodes = []
        self.case = ""
        self.cleanups = []
        self.forced_kills = []

    def case_dir(self, name):
        path = os.path.join(self.layout["cases"], name)
        os.makedirs(path, exist_ok=True)
        return path

    def node(self, datadir, extra_args=(), label=None):
        return Node(self, datadir, extra_args, label or "node%d" % (len(self.nodes) + 1))

    def finish_case(self):
        """Stop every node (a forced kill is recorded, not raised), then run the cleanups; return what failed."""
        problems = []
        for node in self.nodes:
            try:
                node.stop(clean=False)
            except Exception as error:  # pylint: disable=broad-except
                problems.append("stopping %s: %s" % (node.label, error))
        for cleanup in reversed(self.cleanups):
            try:
                outcome = cleanup()
                if isinstance(outcome, tuple) and outcome[0] != 0:
                    problems.append("cleanup command exited with %s: %s" % outcome)
            except Exception as error:  # pylint: disable=broad-except
                problems.append("cleanup raised %s: %s" % (type(error).__name__, error))
        self.cleanups = []
        return problems


# ----- wallet steps shared by the cases -----
def make_wallet(node, name, passphrase=None):
    arguments = {"wallet_name": name, "load_on_startup": True}
    if passphrase:
        arguments["passphrase"] = passphrase
    node.rpc().createwallet(**arguments)
    return node.rpc(wallet=name)


def unlock(wallet, passphrase):
    if passphrase:
        wallet.walletpassphrase(passphrase, 600)


def stake_state(wallet):
    return wallet.getquantumstakereadiness()["stake_return"]


def consent(wallet):
    return wallet.setquantumstakereturn({"allow_new_quantum_key": True})


def expect_rpc_error(function, code=-4):
    try:
        function()
    except RpcError as error:
        check(error.code == code, "expected RPC error %s, got %s: %s" % (code, error.code, error.message))
        return error.message
    raise CheckFailed("the call succeeded but a failure was expected")


def key_dump(wallet, address):
    """The private and public key of a wallet's quantum address (dumpquantumkey needs a normal unlock)."""
    info = wallet.dumpquantumkey(address)
    return {"private_key": info["private_key"], "public_key": info["public_key"]}


def wallet_inventory(wallet):
    """Every address of the wallet's address book by label (the quantum return keys are all there), and the readiness
    of the stake return: the state compared before a failure, after a restart and after the recovery. A key that is
    missing, or an extra one, shows here and not in a check of the pending address alone."""
    book = {}
    for label in wallet.listlabels():
        book[label] = sorted(wallet.getaddressesbylabel(label).keys())
    state = stake_state(wallet)
    keep = ("ready", "address", "pending", "pending_address", "backup_verified")
    return {"address_book": book, "stake_return": {key: state.get(key) for key in keep}}


def restore_and_compare(node, backup_file, new_name, address, original_dump, passphrase, also=None):
    """Restore a backup into node as a new wallet; the restored wallet owns the address and holds the same key.

    Then call backupwallet on the restored wallet (normally unlocked): the daemon stages a copy, reopens it, and signs
    and verifies a fresh ML-DSA challenge with every quantum key of the restored wallet (src/wallet/wallet.cpp,
    BackupWallet with verify_quantum_keys) before it installs the file. That is the signing test after a restore. It is
    not a transaction: no funded chain is used and nothing here claims that a spend is accepted. `also` maps further
    addresses to their original key dumps, compared the same way."""
    node.rpc().restorewallet(new_name, backup_file)
    restored = node.rpc(wallet=new_name)
    unlock(restored, passphrase)
    check(restored.getaddressinfo(address)["ismine"] is True, "the restored wallet does not own %s" % address)
    check(key_dump(restored, address) == original_dump,
          "the restored wallet's key for %s differs from the key that was backed up" % address)
    for other, dump in (also or {}).items():
        check(restored.getaddressinfo(other)["ismine"] is True, "the restored wallet does not own %s" % other)
        check(key_dump(restored, other) == dump, "the restored wallet's key for %s differs" % other)
    challenge = os.path.join(node.datadir, new_name + "-challenge.dat")
    try:
        restored.backupwallet(challenge)
    except RpcError as error:
        raise CheckFailed("the restored wallet %s cannot make a verified backup (ML-DSA challenge): %s" % (new_name, error))
    check(os.path.isfile(challenge) and os.path.getsize(challenge) > 0,
          "backupwallet reported success but %s is missing or empty" % challenge)
    return {"restored_wallet": new_name, "challenge_backup": challenge, "challenge_bytes": os.path.getsize(challenge)}


def exercise_success(node, backup_root, name, passphrase, restore_node=None):
    """The ordinary path: authorise one new key, require a verified backup before activation, restore it, compare."""
    wallet = make_wallet(node, name, passphrase)
    check(generations(os.path.join(backup_root, component(name))) == [], "backups exist before the key was made")
    unlock(wallet, passphrase)
    result = consent(wallet)
    check(result["created"] is True and result["ready"] is True and result["backup_verified"] is True,
          "the new key did not activate with a verified backup: %s" % json.dumps(result))
    state = stake_state(wallet)
    check(state["ready"] is True and state["pending"] is False and state["backup_verified"] is True
          and state["address"] == result["address"], "the readiness state after activation is wrong: %s" % state)
    directory = os.path.join(backup_root, component(name))
    found = generations(directory)
    check(len(found) == 1, "expected one verified generation in %s, found %s" % (directory, found))
    dump = key_dump(wallet, result["address"])
    target = restore_node or node
    restored = restore_and_compare(target, os.path.join(directory, found[0]), name + "-restored", result["address"], dump,
                                   passphrase)
    return {"address": result["address"], "backup_directory": directory, "generation": found[0], "restore": restored,
            "restored_on": "fresh datadir" if restore_node else "same node, new wallet name"}


def record_error(rec, message):
    rec["daemon_error"] = (rec["daemon_error"] + "\n" + message).strip() if rec["daemon_error"] else message


def require_infra(env, key, what):
    infra = env.layout.get("infra", {})
    precondition(infra.get(key) is True, "%s was not set up by the administrator step: %s" % (
        what, infra.get(key + "_error", "no detail")))


# ----- the cases -----
def case_flush_probe(env, rec):
    precondition(os.path.isfile(env.probe), "flush_probe.exe is missing: %s" % env.probe)
    root = os.path.join(env.case_dir("flush-probe"), "root")
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(root)
    code, output = run_command([env.probe, "--root", root], timeout=300)
    rec["observed"]["exit_code"] = code
    rec["observed"]["output"] = output
    try:
        report = json.loads(output)
    except ValueError:
        raise CheckFailed("the probe printed no JSON report (exit code %s)" % code)
    rec["observed"]["probe_checks"] = report.get("checks", [])
    failing = [c for c in report.get("checks", []) if not c.get("pass")]
    check(code == 0 and report.get("pass") is True and report.get("checks"), "probe checks failed: %s" % failing)


def child_profile(env):
    """child-profile.json as qualify-child.ps1 wrote it (the profile checked against the SID's registered profile)."""
    try:
        with open(os.path.join(env.results, "child-profile.json"), "r", encoding="utf-8-sig") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def case_default_path(env, rec):
    profile = os.environ.get("LOCALAPPDATA", "")
    recorded = child_profile(env)
    precondition(recorded.get("ok") is True and profile and os.path.normcase(profile) == os.path.normcase(recorded.get("localappdata", "")),
                 "LOCALAPPDATA %r is not the profile folder the child verified against its SID's registered profile (%s)" % (
                     profile, recorded or "no child-profile.json"))
    rec["observed"]["verified_profile"] = recorded
    datadir = os.path.join(profile, "QBackupQual", "data")
    shutil.rmtree(os.path.dirname(datadir), ignore_errors=True)
    node = env.node(datadir).start()  # no -quantumkeybackupdir: the default path beneath the network datadir
    rec["observed"]["datadir"] = datadir
    rec["observed"]["datadir_facts"] = volume_facts(datadir)
    rec["observed"]["default_root"] = default_backup_root(datadir)
    originals = {}
    for name, passphrase in (("wdefplain", None), ("wdefenc", PASSPHRASE)):
        outcome = exercise_success_to_fresh(node, default_backup_root(datadir), name, passphrase, originals)
        rec["observed"][name] = outcome
    node.stop()
    fresh = env.node(os.path.join(env.case_dir("default-path"), "restore", "data"), label="restore").start()
    for name, passphrase in (("wdefplain", None), ("wdefenc", PASSPHRASE)):
        data = originals[name]
        restored = restore_and_compare(fresh, os.path.join(data["backup_directory"], data["generation"]), name + "-fresh",
                                       data["address"], data["dump"], passphrase)
        rec["observed"][name]["restored_in_fresh_datadir"] = restored


def exercise_success_to_fresh(node, backup_root, name, passphrase, originals):
    """exercise_success for a restore into another datadir: keep what the later restore needs."""
    outcome = exercise_success(node, backup_root, name, passphrase)
    wallet = node.rpc(wallet=name)
    unlock(wallet, passphrase)
    outcome["dump"] = key_dump(wallet, outcome["address"])
    originals[name] = dict(outcome)
    return {k: v for k, v in outcome.items() if k != "dump"}


def case_mounted_ntfs(env, rec):
    require_infra(env, "ntfs_vhd", "the NTFS VHD")
    layout = env.layout
    mount = layout["ntfs_mount"]
    facts = volume_facts(mount)
    precondition(facts.get("file_system", "").lower() == "ntfs", "the mount is not NTFS: %s" % facts)
    datadir = layout["ntfs_mount_datadir"]
    check(os.path.normcase(os.path.dirname(os.path.dirname(mount))) == os.path.normcase(datadir),
          "the mount is not inside the network datadir of the case")
    letter = layout["ntfs_letter"]

    # the administrator made this datadir (it holds the mount point), so it is used as it is
    node = env.node(datadir, ["-quantumkeybackupdir=mounted\\qb"]).start()
    rec["observed"]["mount_facts"] = facts
    for name, passphrase in (("wmntplain", None), ("wmntenc", PASSPHRASE)):
        outcome = exercise_success(node, os.path.join(mount, "qb"), name, passphrase)
        on_volume = "%s:\\qb\\%s\\%s" % (letter, component(name), outcome["generation"])
        check(os.path.isfile(on_volume), "the generation is not on the mounted volume: %s" % on_volume)
        outcome["found_on_volume_letter"] = on_volume
        rec["observed"][name] = outcome


def case_junction(env, rec):
    require_infra(env, "ntfs_vhd", "the NTFS VHD")
    letter = env.layout["ntfs_letter"]
    target = "%s:\\target" % letter
    os.makedirs(target, exist_ok=True)
    datadir = os.path.join(env.case_dir("junction"), "data")
    shutil.rmtree(datadir, ignore_errors=True)
    junction = os.path.join(datadir, "regtest", "junction")
    os.makedirs(os.path.dirname(junction))
    rec["observed"]["mklink"] = run_checked("mklink /J", ["cmd", "/c", "mklink", "/J", junction, target])
    env.cleanups.append(lambda: run_command(["cmd", "/c", "rmdir", junction]))
    node = env.node(datadir, ["-quantumkeybackupdir=junction\\qb"]).start()
    for name, passphrase in (("wjunplain", None), ("wjunenc", PASSPHRASE)):
        outcome = exercise_success(node, os.path.join(junction, "qb"), name, passphrase)
        physical = os.path.join(target, "qb", component(name), outcome["generation"])
        check(os.path.isfile(physical), "the generation is not on the junction target volume: %s" % physical)
        outcome["target_volume"] = volume_facts(target)
        rec["observed"][name] = outcome


def case_subst(env, rec):
    letter = env.layout["subst_letter"]
    drive = letter + ":"
    underlying = env.case_dir("subst")
    datadir = os.path.join(underlying, "data")
    shutil.rmtree(datadir, ignore_errors=True)
    os.makedirs(datadir)
    listing = run_checked("subst (listing)", ["subst"])
    precondition(drive.upper() + "\\" not in listing.upper(), "%s is already a substituted drive: %s" % (drive, listing))
    run_checked("subst " + drive, ["subst", drive, underlying])
    env.cleanups.append(lambda: run_command(["subst", drive, "/D"]))  # after the node stopped; its exit code is checked
    rec["observed"]["subst"] = run_checked("subst (listing)", ["subst"])
    rec["observed"]["drive_facts"] = volume_facts(drive + "\\")
    # the substituted path and its underlying folder must be the same volume, by the opened handle's volume GUID path
    substituted_identity = volume_identity(drive + "\\data")
    underlying_identity = volume_identity(datadir)
    rec["observed"]["substituted_identity"] = substituted_identity
    rec["observed"]["underlying_identity"] = underlying_identity
    precondition(substituted_identity.get("volume_guid") and underlying_identity.get("volume_guid"),
                 "a volume GUID path could not be read: %s / %s" % (substituted_identity, underlying_identity))
    check(substituted_identity["volume_guid"] == underlying_identity["volume_guid"],
          "the substituted drive and its underlying folder are different volumes: %s / %s" % (substituted_identity, underlying_identity))
    node = env.node(drive + "\\data").start()
    for name, passphrase in (("wsubplain", None), ("wsubenc", PASSPHRASE)):
        outcome = exercise_success(node, default_backup_root(drive + "\\data"), name, passphrase)
        physical = os.path.join(default_backup_root(datadir), component(name), outcome["generation"])
        check(os.path.isfile(physical), "the generation is not under the underlying folder: %s" % physical)
        outcome["underlying_path"] = physical
        outcome["backup_volume_identity"] = volume_identity(os.path.dirname(physical))
        check(outcome["backup_volume_identity"].get("volume_guid") == underlying_identity["volume_guid"],
              "the backup file is not on the volume of the underlying folder: %s" % outcome["backup_volume_identity"])
        rec["observed"][name] = outcome


def pending_checks(wallet, address=None):
    state = stake_state(wallet)
    check(state["ready"] is False and state["pending"] is True and state.get("pending_error"),
          "the key is not pending with an error: %s" % state)
    check("address" not in state, "an active return address exists while the key is pending: %s" % state)
    if address:
        check(state["pending_address"] == address, "the pending key changed")
    return state


def refused_and_recovered(env, rec, node, wallet_name, passphrase, error_checks, directory_files_before,
                          guarded_directory, datadir, label):
    """One refused backup path: the accurate pending error, the existing generations untouched, then the SAME key
    activates once the node uses the default path."""
    wallet = make_wallet(node, wallet_name, passphrase)
    unlock(wallet, passphrase)
    message = expect_rpc_error(lambda: consent(wallet))
    record_error(rec, "%s: %s" % (label, message))
    for description, pattern in error_checks:
        check(pattern.search(message), "%s: the error does not %s: %s" % (label, description, message))
    state = pending_checks(wallet)
    pending_address = state["pending_address"]
    check(pending_address in wallet.getaddressesbylabel("PoS - Quantum Stake Address"),
          "%s: the pending key is not in the wallet" % label)
    check(len(wallet.getaddressesbylabel("PoS - Quantum Stake Address")) == 1, "%s: more than one key was made" % label)
    inventory_before = wallet_inventory(wallet)
    if guarded_directory is not None:
        check(snapshot(guarded_directory) == directory_files_before,
              "%s: existing generations in %s changed" % (label, guarded_directory))
    rec["observed"][label + "_pending_error"] = state["pending_error"]
    node.stop()
    node.start(extra_args=[])  # the default path beneath the datadir
    wallet = node.wait_wallet(wallet_name)
    unlock(wallet, passphrase)
    result = wallet.setquantumstakereturn()  # no new consent: the key that exists is completed
    check(result["address"] == pending_address and result["ready"] is True and result["backup_verified"] is True,
          "%s: the same key did not activate after switching to the default path: %s" % (label, result))
    state = stake_state(wallet)
    check(state["pending"] is False and state["ready"] is True and state["address"] == pending_address
          and state["backup_verified"] is True, "%s: the state after recovery is wrong: %s" % (label, state))
    inventory_after = wallet_inventory(wallet)
    check(inventory_after["address_book"] == inventory_before["address_book"],
          "%s: the key inventory changed across the recovery: %s -> %s" % (label, inventory_before, inventory_after))
    directory = os.path.join(default_backup_root(datadir), component(wallet_name))
    found = generations(directory)
    check(len(found) == 1, "%s: expected one generation in the default directory, found %s" % (label, found))
    restored = restore_and_compare(node, os.path.join(directory, found[0]), wallet_name + "-restored", pending_address,
                                   key_dump(wallet, pending_address), passphrase)
    rec["observed"][label + "_recovered_address"] = pending_address
    rec["observed"][label + "_recovery_restore"] = restored
    rec["observed"][label + "_inventory"] = inventory_after


def case_outside_denied(env, rec):
    layout = env.layout
    drive = os.path.splitdrive(layout["root"])[0]
    datadir = os.path.join(env.case_dir("outside"), "data")
    shutil.rmtree(datadir, ignore_errors=True)
    shutil.rmtree(os.path.join(layout["root"], "outside"), ignore_errors=True)
    os.makedirs(datadir)
    outside = os.path.join(layout["root"], "outside", "backups")
    # an earlier destination: a wallet backed up in the default directory
    node = env.node(datadir).start()
    previous = make_wallet(node, "wprev")
    consent(previous)
    previous_dir = os.path.join(default_backup_root(datadir), component("wprev"))
    before = snapshot(previous_dir)
    check(len(generations(previous_dir)) == 1, "the earlier wallet has no backup")
    previous_state = stake_state(previous)
    node.stop()
    node.start(extra_args=["-quantumkeybackupdir=" + outside])
    ancestor = re.escape(drive + "\\")
    refused_and_recovered(
        env, rec, node, "wdeny", None,
        [("name the root of the drive as the denied ancestor", re.compile(r"backup directory " + ancestor + r" durable", re.I)),
         ("report access denied", DENIED_RE), ("say the backup failed", re.compile(r"wallet backup failed", re.I))],
        before, previous_dir, datadir, "outside-root-denied")
    check(stake_state(node.wait_wallet("wprev")) == previous_state, "the earlier wallet's state changed")
    check(snapshot(previous_dir) == before, "the earlier destination changed")
    check(not wallet_files(os.path.join(outside, component("wdeny"))), "a backup file was left in the refused outside path")
    # the unrestricted outside-path claim needs a writable test-volume root
    require_infra(env, "ntfs_vhd", "the NTFS VHD (the writable test-volume root)")
    positive = "%s:\\outside" % layout["ntfs_letter"]
    node.stop()
    node.start(extra_args=["-quantumkeybackupdir=" + positive])
    outcome = exercise_success(node, positive, "wposout", None)
    rec["observed"]["positive_outside_path"] = outcome
    rec["observed"]["positive_volume"] = volume_facts(positive)


def share_precondition(env, base):
    """Ordinary file creation works through the share before any backup path is judged."""
    os.makedirs(base, exist_ok=True)
    probe = os.path.join(base, "ordinary-file-check.txt")
    with open(probe, "w", encoding="utf-8") as handle:
        handle.write("ordinary file creation works\n")
    with open(probe, "r", encoding="utf-8") as handle:
        check(handle.read().startswith("ordinary"), "a file written through the share cannot be read back")
    os.remove(probe)


def unsupported_case(env, rec, case, backup_dir_arg, directory, wallet_name, label):
    datadir = os.path.join(env.case_dir(case), "data")
    shutil.rmtree(datadir, ignore_errors=True)
    os.makedirs(datadir)
    try:
        share_precondition(env, os.path.dirname(directory.rstrip("\\")))
    except (OSError, CheckFailed) as error:
        raise Unresolved("ordinary file creation through the share does not work: %s" % error)
    seed_generation(os.path.join(directory, component(wallet_name)))
    before = snapshot(os.path.join(directory, component(wallet_name)))
    node = env.node(datadir, ["-quantumkeybackupdir=" + backup_dir_arg]).start()
    refused_and_recovered(
        env, rec, node, wallet_name, None,
        [("name a missing durable commit", DURABLE_RE), ("say the volume is unsupported", UNSUPPORTED_VOLUME_RE)],
        before, os.path.join(directory, component(wallet_name)), datadir, label)


def case_unc_share(env, rec):
    require_infra(env, "share", "the SMB share")
    unc = env.layout["share_unc"]
    unsupported_case(env, rec, "unc", unc + "\\backups", unc + "\\backups", "wunc", "unc")


def case_mapped_drive(env, rec):
    require_infra(env, "share", "the SMB share")
    letter = env.layout["mapped_letter"] + ":"
    rec["observed"]["net_use"] = run_checked("net use", ["net", "use", letter, env.layout["share_unc"], "/persistent:no"])
    env.cleanups.append(lambda: run_command(["net", "use", letter, "/delete", "/y"]))
    rec["observed"]["drive_facts"] = volume_facts(letter + "\\")
    unsupported_case(env, rec, "mapped", letter + "\\backups", letter + "\\backups", "wmap", "mapped")


def case_denied_ancestor(env, rec):
    user = env.layout["user"]
    datadir = os.path.join(env.case_dir("denied"), "data")
    shutil.rmtree(datadir, ignore_errors=True)
    blocked = os.path.join(datadir, "regtest", "blocked")
    leaf = os.path.join(blocked, "sub", component("wblk"))
    os.makedirs(leaf)  # the leaf exists before the ancestor is denied
    rec["observed"]["icacls_deny"] = run_checked("icacls /deny", ["icacls", blocked, "/deny", "%s:(W)" % user])
    denial = {"active": True}
    env.cleanups.append(lambda: run_command(["icacls", blocked, "/remove:d", user]) if denial["active"] else None)
    try:
        with open(os.path.join(leaf, "leaf-access.txt"), "w", encoding="utf-8") as handle:
            handle.write("the leaf is still writable\n")
        os.remove(os.path.join(leaf, "leaf-access.txt"))
    except OSError as error:
        raise Unresolved("the leaf is not writable although only the ancestor was denied: %s" % error)
    node = env.node(datadir, ["-quantumkeybackupdir=blocked\\sub"]).start()
    wallet = make_wallet(node, "wblk")
    message = expect_rpc_error(lambda: consent(wallet))
    record_error(rec, message)
    check(DURABLE_RE.search(message) and DENIED_RE.search(message), "not an access-denied durability error: %s" % message)
    check(re.search(r"\\blocked durable", message, re.I), "the error does not name the denied ancestor: %s" % message)
    state = pending_checks(wallet)
    pending_address = state["pending_address"]
    inventory_before = wallet_inventory(wallet)
    check(not wallet_files(leaf), "a backup file was written although the ancestor was denied")
    node.stop()
    code, output = run_command(["icacls", blocked, "/remove:d", user])
    rec["observed"]["icacls_remove"] = output
    check(code == 0, "icacls /remove:d failed: %s" % output)
    denial["active"] = False
    node.start(extra_args=["-quantumkeybackupdir=blocked\\sub"])  # retry after a restart
    wallet = node.wait_wallet("wblk")
    result = wallet.setquantumstakereturn()
    check(result["address"] == pending_address and result["ready"] is True and result["backup_verified"] is True,
          "the same key did not activate after the denial was removed: %s" % result)
    state = stake_state(wallet)
    check(state["pending"] is False and state["backup_verified"] is True and state["address"] == pending_address,
          "the state after the recovery is wrong: %s" % state)
    inventory_after = wallet_inventory(wallet)
    check(inventory_after["address_book"] == inventory_before["address_book"], "the key inventory changed across the recovery")
    check(len(generations(leaf)) == 1, "no verified generation in the leaf after the retry")
    rec["observed"]["recovery_restore"] = restore_and_compare(
        node, os.path.join(leaf, generations(leaf)[0]), "wblk-restored", pending_address, key_dump(wallet, pending_address), None)
    rec["observed"]["recovered_address"] = pending_address


def crash_cycle(node, base_args, point, name, passphrase):
    """Restart the node with a crash point, make it reach the point through setquantumstakereturn, and require the
    abrupt exit (TerminateProcess, exit code 7). The wallet and the files stay as the daemon itself left them."""
    node.restart(extra_args=list(base_args) + ["-quantumreturncrashpoint=" + point])
    wallet = node.wait_wallet(name)
    unlock(wallet, passphrase)
    try:
        consent(wallet)
    except (RpcUnavailable, RpcError):
        pass  # the connection closes with the process
    else:
        raise CheckFailed("the daemon did not stop at %s" % point)
    code = node.wait_exit(90)
    check(code == WINDOWS_CRASH_EXIT, "crash point %s: exit code %s, expected %s" % (point, code, WINDOWS_CRASH_EXIT))
    return code


def case_affected_wallet(env, rec):
    """The state the preservation promise is about: the AFFECTED wallet has an active return address, a second key is
    pending, and a failing backup path is retried while several verified generations sit in that path's directory.

    How the product reaches that state (read from the source, not assumed):
     - PrepareQuantumStakeReturn creates a new key only when no usable return address is saved
       (src/wallet/staking.cpp, the `already saved` return in PrepareQuantumStakeReturn), so allow_new_quantum_key
       cannot make a second pending key next to an active address.
     - The way in is the other order: a key becomes pending first (crash point after_key_insertion leaves it pending), and
       an existing quantum address of the wallet is then saved with existing_address (SetQuantumStakeReturn does not
       touch the pending record). ActivatePendingQuantumStakeReturn is written for exactly this ("unless a valid
       destination was saved meanwhile"): the pending key is backed up but the saved address stays.
     - Generations are only written by BackupQuantumReturnKey, which only FinishPendingQuantumStakeReturn calls, and
       pruning runs only after a successful activation. A backup that succeeds but is followed by the crash point
       before_activation leaves a genuine, manifested generation and the key still pending; repeating that gives as many
       real generations as wanted, all produced by the daemon.
    Only then the path is made to fail (an ancestor is denied), the call is repeated, the daemon is restarted, the
    denial is removed and the same key completes: the generations of the failing path must be untouched at every step
    and the pruning that follows the success must leave exactly the newest three."""
    user = env.layout["user"]
    datadir = os.path.join(env.case_dir("affected"), "data")
    shutil.rmtree(datadir, ignore_errors=True)
    blocked = os.path.join(datadir, "regtest", "blocked")
    name, passphrase = "waffect", PASSPHRASE
    leaf = os.path.join(blocked, "sub", component(name))
    os.makedirs(os.path.dirname(leaf))
    arguments = ["-quantumkeybackupdir=blocked\\sub"]
    node = env.node(datadir)
    node.start(extra_args=arguments)
    wallet = make_wallet(node, name, passphrase)

    # 1. a key becomes pending: the daemon ends right after the key was stored, before any backup
    crash_cycle(node, arguments, "after_key_insertion", name, passphrase)
    node.restart(extra_args=arguments)
    wallet = node.wait_wallet(name)
    unlock(wallet, passphrase)
    state = pending_checks(wallet)
    pending_address = state["pending_address"]
    check(not wallet_files(leaf), "a backup exists before any backup was made")

    # 2. an existing quantum address of the wallet becomes the active return address while that key is pending
    active_address = wallet.getnewquantumaddress("affected-destination")["address"]
    saved = wallet.setquantumstakereturn({"existing_address": active_address})
    check(saved["address"] == active_address and saved["ready"] is True, "the existing address was not saved: %s" % saved)
    state = stake_state(wallet)
    check(state["ready"] is True and state["address"] == active_address and state["pending"] is True
          and state["pending_address"] == pending_address, "the wallet is not in the pending-plus-active state: %s" % state)
    dumps = {active_address: key_dump(wallet, active_address), pending_address: key_dump(wallet, pending_address)}

    # 3. four genuine generations written by the daemon, the key staying pending and the active address staying active
    sequences = {}
    for round_number in range(1, 5):
        crash_cycle(node, arguments, "before_activation", name, passphrase)
        found = generations(leaf)
        check(len(found) == round_number, "expected %d verified generations after round %d, found %s" % (round_number, round_number, found))
        sequences = {n: read_generation(leaf, n)["sequence"] for n in found}
        check(len(set(sequences.values())) == len(sequences), "two generations share a sequence number: %s" % sequences)
    node.restart(extra_args=arguments)
    wallet = node.wait_wallet(name)
    unlock(wallet, passphrase)
    old_generations = generations(leaf)
    manifests = {n: read_generation(leaf, n) for n in old_generations}
    key_lists = {tuple(sorted(m["keys"])) for m in manifests.values()}
    check(len(key_lists) == 1 and len(next(iter(key_lists))) >= 2, "the generations do not hold the same two or more keys: %s" % manifests)
    inventory_start = wallet_inventory(wallet)
    check(inventory_start["stake_return"]["pending"] is True and inventory_start["stake_return"]["address"] == active_address,
          "the state before the failure is wrong: %s" % inventory_start)
    snapshot_start = snapshot(leaf)
    check(set(snapshot_start) == generation_files(old_generations),
          "the directory holds %s, expected exactly four wallet files and their four manifests" % sorted(snapshot_start))
    rec["observed"]["generations_before"] = {n: manifests[n]["sequence"] for n in old_generations}
    rec["observed"]["inventory_before"] = inventory_start

    # 4. the path fails: an ancestor of the (existing) leaf is denied; the call is repeated, then the node restarted
    node.stop()
    rec["observed"]["icacls_deny"] = run_checked("icacls /deny", ["icacls", blocked, "/deny", "%s:(W)" % user])
    denial = {"active": True}
    env.cleanups.append(lambda: run_command(["icacls", blocked, "/remove:d", user]) if denial["active"] else None)
    try:
        probe = os.path.join(leaf, "leaf-access.txt")
        with open(probe, "w", encoding="utf-8") as handle:
            handle.write("the leaf is still writable\n")
        os.remove(probe)
    except OSError as error:
        raise Unresolved("the leaf is not writable although only the ancestor was denied: %s" % error)
    node.start(extra_args=arguments)
    wallet = node.wait_wallet(name)
    unlock(wallet, passphrase)
    message = expect_rpc_error(lambda: consent(wallet))
    record_error(rec, message)
    check(DURABLE_RE.search(message) and DENIED_RE.search(message), "not an access-denied durability error: %s" % message)
    check(re.search(r"\\blocked durable", message, re.I), "the error does not name the denied ancestor: %s" % message)
    after_failure = wallet_inventory(wallet)
    check(after_failure["stake_return"]["pending"] is True and after_failure["stake_return"]["pending_address"] == pending_address
          and after_failure["stake_return"]["address"] == active_address and after_failure["stake_return"]["ready"] is True,
          "the active address or the pending key changed after the failed retry: %s" % after_failure)
    check(after_failure["address_book"] == inventory_start["address_book"], "the key inventory changed after the failed retry")
    check(snapshot(leaf) == snapshot_start, "the generations of the failing path changed during the failed retry")
    node.restart(extra_args=arguments)  # still denied
    wallet = node.wait_wallet(name)
    unlock(wallet, passphrase)
    after_restart = wallet_inventory(wallet)
    check(after_restart == after_failure, "the inventory differs after the restart: %s -> %s" % (after_failure, after_restart))
    check(snapshot(leaf) == snapshot_start, "the generations of the failing path changed across the restart")
    rec["observed"]["inventory_after_failure"] = after_failure
    rec["observed"]["inventory_after_restart"] = after_restart

    # 5. the denial is removed after a clean stop; the same key completes and only now are the generations pruned
    node.stop()
    code, output = run_command(["icacls", blocked, "/remove:d", user])
    rec["observed"]["icacls_remove"] = output
    check(code == 0, "icacls /remove:d failed: %s" % output)
    denial["active"] = False
    node.start(extra_args=arguments)
    wallet = node.wait_wallet(name)
    unlock(wallet, passphrase)
    result = wallet.setquantumstakereturn()
    check(result["address"] == active_address and result["ready"] is True and result["backup_verified"] is True,
          "the saved address is not intact after the recovery: %s" % result)
    after_recovery = wallet_inventory(wallet)
    check(after_recovery["stake_return"]["pending"] is False and after_recovery["stake_return"]["backup_verified"] is True
          and after_recovery["stake_return"]["address"] == active_address, "the state after the recovery is wrong: %s" % after_recovery)
    check(after_recovery["address_book"] == inventory_start["address_book"], "the key inventory changed across the recovery")
    rec["observed"]["inventory_after_recovery"] = after_recovery
    survivors = generations(leaf)
    all_sequences = dict(sequences)
    new_names = [n for n in survivors if n not in old_generations]
    check(len(new_names) == 1, "expected one new generation from the recovery, found %s" % new_names)
    all_sequences[new_names[0]] = read_generation(leaf, new_names[0])["sequence"]
    expected = expected_survivors(all_sequences, 3)
    check(set(survivors) == expected, "pruning left %s, expected the newest three %s" % (sorted(survivors), sorted(expected)))
    check(set(snapshot(leaf)) == generation_files(survivors),
          "the directory holds %s, expected exactly three wallet files and their manifests" % sorted(snapshot(leaf)))
    check(all(tuple(sorted(read_generation(leaf, n)["keys"])) == next(iter(key_lists)) for n in survivors),
          "the key list of a surviving generation changed")
    rec["observed"]["survivors"] = {n: all_sequences[n] for n in sorted(survivors)}
    rec["observed"]["restore"] = restore_and_compare(
        node, os.path.join(leaf, new_names[0]), name + "-restored", pending_address, dumps[pending_address], passphrase,
        also={active_address: dumps[active_address]})
    rec["observed"]["pending_address"] = pending_address
    rec["observed"]["active_address"] = active_address


def case_fat32(env, rec):
    require_infra(env, "fat32_vhd", "the FAT32 VHD")
    mount = env.layout["fat_mount"]
    facts = volume_facts(mount)
    precondition(facts.get("file_system", "").lower() == "fat32", "the mount is not FAT32: %s" % facts)
    rec["observed"]["mount_facts"] = facts
    try:
        probe = os.path.join(mount, "ordinary-write-check.txt")
        with open(probe, "w", encoding="utf-8") as handle:
            handle.write("ordinary writes succeed on the FAT32 volume\n")
        os.remove(probe)
    except OSError as error:
        raise Unresolved("ordinary writes to the FAT32 volume fail: %s" % error)
    datadir = env.layout["fat_mount_datadir"]
    seed_dir = os.path.join(mount, "qb", component("wfat"))
    seed_generation(seed_dir)
    before = snapshot(seed_dir)
    node = env.node(datadir, ["-quantumkeybackupdir=fatmount\\qb"]).start()
    refused_and_recovered(
        env, rec, node, "wfat", None,
        [("name a missing durable commit", DURABLE_RE), ("name the file system fat32", FAT32_RE)],
        before, seed_dir, datadir, "fat32")


def case_failcommit(env, rec):
    datadir = os.path.join(env.case_dir("failcommit"), "data")
    shutil.rmtree(datadir, ignore_errors=True)
    os.makedirs(datadir)
    node = env.node(datadir)
    pending = {}
    for name, passphrase in (("wfcplain", None), ("wfcenc", PASSPHRASE)):
        arguments = ["-quantumreturnfailcommit=" + component(name)]
        if node.process is None:
            node.start(extra_args=arguments)
        else:
            node.restart(extra_args=arguments)
        wallet = make_wallet(node, name, passphrase)
        unlock(wallet, passphrase)
        message = expect_rpc_error(lambda: consent(wallet))
        record_error(rec, "%s: %s" % (name, message))
        check(ENTRY_FAIL_RE.search(message), "%s: not the commit-failure error: %s" % (name, message))
        pending[name] = pending_checks(wallet)["pending_address"]
        check(not generations(os.path.join(default_backup_root(datadir), component(name))), "a generation exists")
    node.restart(extra_args=[])
    for name, passphrase in (("wfcplain", None), ("wfcenc", PASSPHRASE)):
        wallet = node.wait_wallet(name)
        unlock(wallet, passphrase)
        inventory_before = wallet_inventory(wallet)
        result = wallet.setquantumstakereturn()
        check(result["address"] == pending[name] and result["ready"] is True and result["backup_verified"] is True,
              "%s: the same key did not activate on retry: %s" % (name, result))
        state = stake_state(wallet)
        check(state["pending"] is False and state["backup_verified"] is True and state["address"] == pending[name],
              "%s: the state after the retry is wrong: %s" % (name, state))
        inventory_after = wallet_inventory(wallet)
        check(inventory_after["address_book"] == inventory_before["address_book"], "%s: the key inventory changed" % name)
        directory = os.path.join(default_backup_root(datadir), component(name))
        found = generations(directory)
        check(len(found) == 1, "no generation")
        restored = restore_and_compare(node, os.path.join(directory, found[0]), name + "-restored", pending[name],
                                       key_dump(wallet, pending[name]), passphrase)
        rec["observed"][name] = {"pending_then_active_address": pending[name], "recovery_restore": restored}


def crash_at(node, point, name, passphrase):
    node.restart(extra_args=["-quantumreturncrashpoint=" + point])
    wallet = node.wait_wallet(name)
    unlock(wallet, passphrase)
    try:
        consent(wallet)
    except (RpcUnavailable, RpcError):
        pass  # the connection closes with the process
    else:
        raise CheckFailed("the daemon did not stop at %s" % point)
    code = node.wait_exit(90)
    check(code == WINDOWS_CRASH_EXIT, "crash point %s: exit code %s, expected %s" % (point, code, WINDOWS_CRASH_EXIT))
    node.start(extra_args=[])
    wallet = node.wait_wallet(name)
    unlock(wallet, passphrase)
    return wallet, code


def case_crash_points(env, rec):
    datadir = os.path.join(env.case_dir("crash"), "data")
    shutil.rmtree(datadir, ignore_errors=True)
    os.makedirs(datadir)
    node = env.node(datadir).start()
    root = default_backup_root(datadir)
    plan = (("after_key_insertion", None), ("after_backup_install", None),
            ("before_activation", PASSPHRASE), ("after_activation", PASSPHRASE))
    for point, passphrase in plan:
        name = "wcr" + point.replace("_", "")
        make_wallet(node, name, passphrase)
        wallet, code = crash_at(node, point, name, passphrase)
        directory = os.path.join(root, component(name))
        state = stake_state(wallet)
        found = {"exit_code": code, "encrypted": bool(passphrase)}
        if point == "after_key_insertion":
            check(state["pending"] is True and state["ready"] is False, "state after %s: %s" % (point, state))
            check(wallet_files(directory) == [], "a backup exists after %s" % point)
            address = state["pending_address"]
        elif point == "after_backup_install":
            check(state["pending"] is True and state["ready"] is False, "state after %s: %s" % (point, state))
            check(len(wallet_files(directory)) == 1 and generations(directory) == [],
                  "expected one wallet file with no manifest after %s" % point)
            address = state["pending_address"]
        elif point == "before_activation":
            check(state["pending"] is True and state["ready"] is False, "state after %s: %s" % (point, state))
            check(len(generations(directory)) == 1, "expected one verified generation after %s" % point)
            address = state["pending_address"]
        else:
            check(state["pending"] is False and state["ready"] is True and state["backup_verified"] is True,
                  "state after %s: %s" % (point, state))
            check(len(generations(directory)) == 1, "expected one verified generation after %s" % point)
            address = state["address"]
        if point != "after_activation":
            result = wallet.setquantumstakereturn()
            check(result["address"] == address and result["ready"] is True, "the same key did not activate: %s" % result)
        dump = key_dump(wallet, address)
        latest = generations(directory)[-1]
        found["restore"] = restore_and_compare(node, os.path.join(directory, latest), name + "-restored", address, dump, passphrase)
        found["address"] = address
        found["recoverable"] = True
        rec["observed"][point] = found


CASES = [
    # name, expected (one line, as the plan states it), function
    ("flush-probe",
     "real EnsureQuantumKeyBackupDirectory succeeds, an injected ERROR_WRITE_FAULT on a directory handle fails it with the flush error, "
     "the retry on the existing directories succeeds", case_flush_probe),
    ("default-path",
     "omitted -quantumkeybackupdir under the user's profile: the key activates only after a verified backup; the backup restores in a fresh "
     "datadir with the same key; plain and encrypted", case_default_path),
    ("mounted-ntfs",
     "an NTFS VHD mounted inside the network datadir: backup, restore and the same key; the files are on the mounted volume", case_mounted_ntfs),
    ("junction", "a junction to another NTFS volume inside the datadir: backup and restore succeed on the target volume", case_junction),
    ("subst-drive", "a subst drive in the child's own session as the datadir: success, files under the underlying folder", case_subst),
    ("outside-denied", "an outside path whose ancestors reach C:\\ is refused with an accurate pending error, the earlier destination is "
     "untouched, the same key activates on the default path; a writable test-volume root succeeds", case_outside_denied),
    ("unc-share", "a UNC share is refused as unsupported, the key stays pending, existing generations are untouched, the same key "
     "activates on the default path", case_unc_share),
    ("mapped-drive", "a mapped drive is refused as unsupported, with the same pending and recovery behaviour", case_mapped_drive),
    ("denied-ancestor", "a denied ancestor gives an ancestor-specific refusal; after the denial is removed and the node restarted the "
     "same key activates", case_denied_ancestor),
    ("affected-wallet", "the affected wallet has an active return address and a second key pending: after four real generations and a "
     "failing path, the retry, a restart and the recovery leave the active address, the key inventory and the generations of the "
     "failing path untouched until the success prunes to the newest three", case_affected_wallet),
    ("fat32", "a FAT32 mounted volume is refused naming the file system although ordinary writes succeed", case_fat32),
    ("failcommit", "-quantumreturnfailcommit fails the entry commit, the key stays pending, a restart without it activates the same key",
     case_failcommit),
    ("crash-points", "the four crash points exit with code 7, and after a restart the pending or active state is the expected one with a "
     "recoverable key", case_crash_points),
]


def run_case(env, name, expected, function):
    rec = {"name": name, "expected": expected, "observed": {}, "status": "fail", "pass": False, "daemon_error": "",
           "log_lines": [], "started": now(), "finished": None, "failure": ""}
    env.case = name
    env.nodes = []
    env.forced_kills = []
    try:
        function(env, rec)
        rec["status"] = "pass"
    except Unresolved as error:
        rec["status"] = "unresolved"
        rec["failure"] = str(error)
    except CheckFailed as error:
        rec["failure"] = str(error)
    except RpcError as error:
        rec["failure"] = "unexpected %s" % error
    except Exception:  # pylint: disable=broad-except
        rec["failure"] = traceback.format_exc()
    finally:
        problems = []
        try:
            problems = env.finish_case()
        except Exception as error:  # pylint: disable=broad-except
            problems = ["finishing the case raised %s: %s" % (type(error).__name__, error)]
        rec["full_logs"] = []
        for index, node in enumerate(env.nodes, 1):
            rec["log_lines"].extend("[%s] %s" % (node.label, line) for line in node.log_excerpt())
            destination = os.path.join(env.logs, "%s-%d-%s-debug.log" % (safe_name(name), index, safe_name(node.label)))
            if node.save_full_log(destination):
                rec["full_logs"].append(os.path.basename(destination))
        rec["forced_kills"] = list(env.forced_kills)
        rec["cleanup_problems"] = problems
        if problems:
            rec["failure"] = (rec["failure"] + "\n" if rec["failure"] else "") + "clean-up problems: " + "; ".join(problems)
            if rec["status"] == "pass":
                rec["status"] = "fail"
        if env.forced_kills and rec["status"] == "pass":
            rec["status"] = "fail"
            rec["failure"] = "a daemon had to be killed after a stop timeout: %s" % env.forced_kills
    rec["pass"] = rec["status"] == "pass"
    rec["finished"] = now()
    write_json(os.path.join(env.results, "case-%s.json" % safe_name(name)), rec)
    print("%-16s %s%s" % (name, rec["status"].upper(), "" if rec["pass"] else "  " + rec["failure"].splitlines()[0][:200]),
          flush=True)
    return rec


def run_all(layout_path, results, daemon, probe, only):
    with open(layout_path, "r", encoding="utf-8-sig") as handle:  # tolerate a byte order mark from Windows PowerShell
        layout = json.load(handle)
    os.makedirs(results, exist_ok=True)
    env = Env(layout, results, daemon or layout["daemon"], probe or layout["probe"])
    identity = {"user": os.environ.get("USERNAME"), "profile": os.environ.get("USERPROFILE"),
                "localappdata": os.environ.get("LOCALAPPDATA"), "temp": os.environ.get("TEMP"),
                "python": sys.version, "daemon": env.daemon, "started": now(),
                "harness_sha256": file_sha256(os.path.abspath(__file__)), "daemon_sha256": file_sha256(env.daemon),
                "probe_sha256": file_sha256(env.probe)}
    write_json(os.path.join(results, "harness-identity.json"), identity)
    records = []
    for name, expected, function in CASES:
        if only and name not in only:
            continue
        records.append(run_case(env, name, expected, function))
    statuses = [r["status"] for r in records]
    summary = {"cases": [{"name": r["name"], "status": r["status"]} for r in records], "passed": statuses.count("pass"),
               "failed": statuses.count("fail"), "unresolved": statuses.count("unresolved"), "finished": now()}
    write_json(os.path.join(results, "summary.json"), summary)
    print(json.dumps(summary), flush=True)
    if summary["failed"]:
        return 1
    if summary["unresolved"] or not records:
        return 3
    return 0


# ----- self-test of the pure helpers (any platform) -----
def selftest():
    import tempfile
    import threading
    from http.server import BaseHTTPRequestHandler, HTTPServer

    assert component("") == "default"
    assert component("wone") == "n_wone"
    assert component("default") == "n_default"
    assert component("W-1") == "n__57-1"
    assert component("a b/c") == "n_a_20b_2fc"
    assert component("e\u00e9") == "n_e_c3_a9"
    long_name = "a" * 100
    long_component = component(long_name)
    assert len(long_component) == 50 + 1 + 32 and long_component.startswith("n_" + "a" * 48 + "~")
    assert component("x" * 40) != component("x" * 41)
    assert GENERATION_RE.match(SEED_GENERATION)
    assert not GENERATION_RE.match("quantum-wallet-note.dat")
    assert generation_manifest("f", 3, ["aa"]) == "quantum-key-backup-manifest 1\nfile f\nsequence 3\nkeys 1\naa\nend\n"
    # daemon error texts (copied from the source) against the patterns
    durable = "cannot make the backup directory C:\\ durable: it cannot be opened for writing: Access is denied. (5)"
    assert DURABLE_RE.search(durable) and DENIED_RE.search(durable)
    unc = ("cannot make the backup directory \\\\localhost\\QBackup\\backups\\n_wunc durable: the directory is not on a local "
           "volume that has a volume GUID path (a network share, or a path that cannot be tied to one local volume); "
           "use a folder on a local NTFS volume")
    assert DURABLE_RE.search(unc) and UNSUPPORTED_VOLUME_RE.search(unc) and not DENIED_RE.search(unc)
    fat = ("cannot make the backup directory V:\\qb durable: the backup directory is on a volume with file system fat32, where "
           "a flush does not prove that the directory entries are on disk; use a folder on a local NTFS volume")
    assert FAT32_RE.search(fat) and DURABLE_RE.search(fat)
    assert ENTRY_FAIL_RE.search("cannot make the entry of the backup directory C:\\x\\n_wfp durable")
    # manifests, pruning expectation, volume GUID paths, hashes
    text = generation_manifest("f.dat", 7, ["aa", "bb"])
    assert parse_manifest(text) == {"file": "f.dat", "sequence": 7, "keys": ["aa", "bb"]}
    assert parse_manifest(generation_manifest("g.dat", 1)) == {"file": "g.dat", "sequence": 1, "keys": []}
    for bad in ("", "x\n", text.replace("keys 2", "keys 3"), text.replace("sequence 7", "seq 7"), text[:-4], text.replace(" 1\n", " 2\n", 1)):
        try:
            parse_manifest(bad)
            raise AssertionError("accepted %r" % bad)
        except ValueError:
            pass
    assert expected_survivors({"a": 1, "b": 2, "c": 3, "d": 4, "e": 5}, 3) == {"c", "d", "e"}
    assert expected_survivors({"a": 1, "b": 2}, 3) == {"a", "b"}
    assert generation_files(["a", "b"]) == {"a", "b", "a.keys", "b.keys"}
    assert expected_survivors({"x": 5, "y": 5, "z": 1}, 1) == {"y"}
    guid = "\\\\?\\Volume{12345678-1234-1234-1234-123456789ABC}\\"
    assert volume_guid_prefix(guid + "data\\regtest") == guid.lower()
    assert volume_guid_prefix("\\\\?\\C:\\data") is None and volume_guid_prefix("") is None and volume_guid_prefix(None) is None
    assert volume_guid_prefix("\\\\?\\Volume{12345678-1234-1234-1234-123456789ABC}") is None
    assert volume_identity("anything") == {} or os.name == "nt"
    assert file_sha256(__file__) != "" and file_sha256(__file__ + ".missing") == ""
    assert {"affected-wallet", "denied-ancestor"} <= {case_name for case_name, _, _ in CASES}
    assert not DURABLE_RE.search("cannot make the entry of the backup directory C:\\x durable")
    with tempfile.TemporaryDirectory() as temporary:
        directory = os.path.join(temporary, "n_w")
        assert generations(directory) == [] and snapshot(directory) == {}
        seeded = seed_generation(directory)
        assert generations(directory) == [seeded] and wallet_files(directory) == [seeded]
        before = snapshot(directory)
        assert len(before) == 2 and snapshot(directory) == before
        with open(os.path.join(directory, "other.txt"), "w", encoding="utf-8") as handle:
            handle.write("x")
        assert snapshot(directory) != before
        out = os.path.join(temporary, "result.json")
        write_json(out, {"name": "n", "pass": True})
        with open(out, "r", encoding="utf-8") as handle:
            assert json.load(handle) == {"name": "n", "pass": True}
        assert not os.path.exists(out + ".tmp")
        # the RPC client against nothing
        cookie = os.path.join(temporary, ".cookie")
        try:
            Rpc(free_port(), cookie).getblockcount()
            raise AssertionError("expected RpcUnavailable")
        except RpcUnavailable:
            pass
        with open(cookie, "w", encoding="utf-8") as handle:
            handle.write("__cookie__:secret")
        try:
            Rpc(free_port(), cookie, timeout=2).getblockcount()
            raise AssertionError("expected RpcUnavailable")
        except RpcUnavailable:
            pass
        # and against a fake server
        seen = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):  # noqa: N802
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                seen.append((self.path, self.headers.get("Authorization"), body))
                if body["method"] == "boom":
                    reply, status = {"result": None, "error": {"code": -4, "message": "wallet backup failed"}, "id": 1}, 500
                else:
                    reply, status = {"result": {"echo": body["params"]}, "error": None, "id": 1}, 200
                data = json.dumps(reply).encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            rpc = Rpc(server.server_port, cookie, wallet="w one")
            assert rpc.createwallet(wallet_name="x") == {"echo": {"wallet_name": "x"}}
            assert rpc.getblockcount(1, 2) == {"echo": [1, 2]}
            path, auth, _ = seen[-1]
            assert path == "/wallet/w%20one"
            assert base64.b64decode(auth.split()[1]) == b"__cookie__:secret"
            try:
                rpc.boom()
                raise AssertionError("expected RpcError")
            except RpcError as error:
                assert error.code == -4 and "backup failed" in error.message
            assert expect_rpc_error(lambda: rpc.boom()) == "wallet backup failed"
        finally:
            server.shutdown()
            server.server_close()
    try:
        check(False, "x")
        raise AssertionError("check must raise")
    except CheckFailed:
        pass
    try:
        precondition(False, "x")
        raise AssertionError("precondition must raise")
    except Unresolved:
        pass
    # a stop that times out ends in a recorded kill that fails the case; clean-up commands that fail are reported
    with tempfile.TemporaryDirectory() as temporary:
        env = Env({"cases": temporary}, os.path.join(temporary, "results"), "daemon", "probe")
        env.case = "selftest"
        node = Node(env, os.path.join(temporary, "data"), label="fake")
        node.process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        env.nodes.append(node)
        try:
            node.stop(timeout=1)
            raise AssertionError("a killed daemon must fail a clean stop")
        except CheckFailed:
            pass
        assert node.forced_kill and env.forced_kills and node.process.poll() is not None
        node.process = subprocess.Popen([sys.executable, "-c", "pass"])
        node.process.wait()
        env.cleanups.append(lambda: (3, "boom"))
        env.cleanups.append(lambda: (0, "fine"))
        env.cleanups.append(lambda: None)
        problems = env.finish_case()
        assert any("exited with 3" in problem for problem in problems) and len(problems) == 1
        assert env.cleanups == []
    assert {name for name, _, _ in CASES} >= {"flush-probe", "default-path", "crash-points", "fat32"}
    print("harness self-test passed")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--layout", help="layout.json written by qualify-admin.ps1")
    parser.add_argument("--results", help="results folder (created)")
    parser.add_argument("--daemon", help="blackcoind.exe (default: from the layout)")
    parser.add_argument("--probe", help="flush_probe.exe (default: from the layout)")
    parser.add_argument("--only", help="comma-separated case names")
    parser.add_argument("--list", action="store_true", help="list the cases")
    parser.add_argument("--selftest", action="store_true", help="test the pure helpers and exit")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    if args.list:
        for name, expected, _ in CASES:
            print("%-16s %s" % (name, expected))
        return 0
    if not args.layout or not args.results:
        parser.error("--layout and --results are required")
    only = set(args.only.split(",")) if args.only else None
    return run_all(args.layout, args.results, args.daemon, args.probe, only)


if __name__ == "__main__":
    sys.exit(main())
