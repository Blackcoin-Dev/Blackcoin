#!/usr/bin/python3
"""Fail-closed two-phase recovery for the 31 ordinary-PoW wallets.

This program is deliberately fleet-specific and installed-v30.1.4-specific.
It never changes node30, never enables/disables mining, and has exactly one
wallet-mutating RPC surface: resolveallshadowpowclaims.  Audit, reconciliation,
signed-byte inspection, and final monitoring are read-only.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import time
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from typing import Any, Iterable, Iterator, Sequence


CONTRACT = "installed-v30.1.4-fleet31-shadowpow-recovery/v1"
SOURCE_COMMIT = "13262151077cce3f72d07d17dc7725b2b6a8e1ab"
SOURCE_TREE = "a6f7757c34b70fab841905765462d6769112d049"
SOURCE_SIGNER = "SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70"
NETWORK_VERSION = 300104
SUBVERSION = "/Blackcoin:30.1.4/"
NODE_SET = tuple([*range(1, 30), 31, 32])
WAVE_PLAN = (
    (16,), (1, 2, 3, 4), (5, 6, 7, 8), (9, 10, 11, 12),
    (13, 14, 15, 17), (18, 19, 20, 21), (22, 23, 24, 25),
    (26, 28, 29), (31, 32), (27,),
)
DEFERRED_NODE = 27
MAX_PHASE_B_ATTEMPTS = 5
USER_ORDER_TEXT = "fix all of the quarantined issues even if you have to pay a small fee to fix it on each node. all issues must be resolved"
USER_ORDER_SHA256 = "0252ebcc3dc2ca8a20e8b9708738c30f9c32f6b0dea213bb8937467b2dab2dff"
PER_NODE_CAP = Decimal("0.00019100")
AGGREGATE_CAP = Decimal("0.00592100")
FEE_RATE_ATOMS_PER_VB = Decimal("100")
FEE_RATE_ATOMS_PER_K = 100000
EXPECTED_VSIZE = 191
HEX64 = re.compile(r"^[0-9a-f]{64}$")
PRODUCTION_DOCKER = pathlib.Path("/usr/bin/docker")
# Filled from the repository fixture after the fixture is finalized.
TEST_TRANSPORT_SHA256 = "706a2269cb23d3995434760462b86813b9ec5e487f1851e7994deb3428775a45"
PHASE_A_TOOL_SHA256 = "fe81981d7ed59b277108ed50128c82b3a2df8a2127a731c8e47d343c55860fed"
PHASE_B_EXECUTOR_EVIDENCE = {
    "commit": "18ca9f4d5087668ae25257a5b978c06f4e1e1f00",
    "tree": "e66d03a4aeb4d45f1085edea179eb11cc957aeff",
    "parent": "328bce04c67d95a27d74b78cc015f40c682de231",
    "signer_fingerprint": SOURCE_SIGNER,
    "tool_sha256": "206c3293502f209515898d6ed81fe800383968e43509d33789097ab4fd09ed39",
    "tool_git_blob": "a49a9316690289e25bf64692cf0a34e02141afe3",
    "product_test_receipt_sha256": "490939cffdcbe1c3ee9c92588bd70d1dc2bea3a0cee00005d89deb8e4da00720",
    "product_test_receipt_git_blob": "abeb23f5df235e75db981af01052ec1078a8850a",
    "hostile_test_sha256": "d661c4c4fb89ae43f74ba16618baad5442c275af1ea8882aa2ce440e57fbbef2",
    "hostile_assertions": 120,
    "hostile_log_sha256": "fedcab5b5945d3f3bfa459aef91d8afce638cff9f11733944f993d1ba6793b26",
    "independent_p0_p1_review": "CLEAN",
}
PHASE_B_EXECUTOR_TOOL_SHA256 = PHASE_B_EXECUTOR_EVIDENCE["tool_sha256"]


class GateError(RuntimeError):
    pass


class RpcError(GateError):
    def __init__(self, node: int, method: str, detail: str):
        super().__init__(f"node{node} {method}: {detail}")
        self.node = node
        self.method = method
        self.detail = detail


def die(message: str) -> "NoReturn":
    raise GateError(message)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb", buffering=0) as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def decimal_amount(value: Any, label: str) -> Decimal:
    try:
        amount = Decimal(str(value))
    except (InvalidOperation, ValueError):
        die(f"{label} is not an exact decimal amount")
    if not amount.is_finite():
        die(f"{label} is not finite")
    return amount


def exact_amount(value: Any, expected: Decimal, label: str) -> None:
    if decimal_amount(value, label) != expected:
        die(f"{label} changed: expected {expected:.8f}, got {value}")


def require_hex64(value: Any, label: str) -> str:
    if not isinstance(value, str) or not HEX64.fullmatch(value):
        die(f"{label} is not a lowercase 32-byte hex identity")
    return value


def require_bool(value: Any, expected: bool, label: str) -> None:
    if value is not expected:
        die(f"{label} must be {str(expected).lower()}")


def require_int(value: Any, label: str, minimum: int | None = None) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        die(f"{label} is not an integer")
    if minimum is not None and value < minimum:
        die(f"{label} is below {minimum}")
    return value


def heal_interrupted_publish_link(path: pathlib.Path, label: str) -> os.stat_result:
    """Remove only the one exact temporary hard link left by our publisher.

    The no-clobber publisher links the fully fsynced temporary inode into its
    final name and then removes the temporary name. A power loss between those
    operations leaves exactly two links to the same inode. This function
    recognizes only that narrowly typed state; arbitrary extra hard links
    remain a fatal integrity error.
    """
    st = path.lstat()
    if st.st_nlink == 1:
        return st
    if st.st_nlink != 2 or not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode):
        die(f"{label} must have exactly one hard link")
    pattern = re.compile(rf"^\.{re.escape(path.name)}\.tmp\.[0-9]+\.[0-9]+$")
    matches: list[pathlib.Path] = []
    for candidate in path.parent.iterdir():
        if not pattern.fullmatch(candidate.name):
            continue
        try:
            candidate_st = candidate.lstat()
        except FileNotFoundError:
            continue
        if ((candidate_st.st_dev, candidate_st.st_ino) == (st.st_dev, st.st_ino) and
                stat.S_ISREG(candidate_st.st_mode) and not stat.S_ISLNK(candidate_st.st_mode)):
            matches.append(candidate)
    if len(matches) != 1:
        die(f"{label} has an unrecognized extra hard link")
    matches[0].unlink()
    fsync_dir(path.parent)
    healed = path.lstat()
    if ((healed.st_dev, healed.st_ino, healed.st_size) != (st.st_dev, st.st_ino, st.st_size) or
            healed.st_nlink != 1):
        die(f"{label} changed while healing an interrupted publication")
    return healed


def owned_secure_file(path: pathlib.Path, label: str, expected_hash: str | None = None) -> bytes:
    if not path.is_absolute():
        die(f"{label} path must be absolute")
    try:
        st = heal_interrupted_publish_link(path, label)
    except FileNotFoundError:
        die(f"{label} is absent: {path}")
    if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode):
        die(f"{label} must be a regular non-symlink file")
    if st.st_nlink != 1:
        die(f"{label} must have exactly one hard link")
    if stat.S_IMODE(st.st_mode) != 0o600:
        die(f"{label} must be mode 0600")
    if st.st_uid != os.geteuid():
        die(f"{label} must be owned by effective uid {os.geteuid()}")
    resolved = path.resolve(strict=True)
    if resolved != path:
        die(f"{label} path is not canonical")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        fst = os.fstat(fd)
        if (fst.st_dev, fst.st_ino, fst.st_size) != (st.st_dev, st.st_ino, st.st_size):
            die(f"{label} changed while opening")
        data = b""
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            data += chunk
        if os.fstat(fd).st_size != len(data):
            die(f"{label} changed while reading")
    finally:
        os.close(fd)
    actual = sha256_bytes(data)
    if expected_hash is not None and actual != expected_hash:
        die(f"{label} SHA256 mismatch: expected {expected_hash}, got {actual}")
    return data


def parse_secure_json(path: pathlib.Path, label: str, expected_hash: str | None = None) -> tuple[Any, str]:
    data = owned_secure_file(path, label, expected_hash)
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        die(f"{label} is not valid JSON: {exc}")
    return value, sha256_bytes(data)


def ensure_secure_dir(path: pathlib.Path, create: bool = False) -> None:
    if not path.is_absolute():
        die("run directory must be absolute")
    if create:
        try:
            path.mkdir(mode=0o700)
        except FileExistsError:
            die(f"run directory already exists: {path}")
    try:
        st = path.lstat()
    except FileNotFoundError:
        die(f"run directory is absent: {path}")
    if not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode):
        die("run directory must be a non-symlink directory")
    if stat.S_IMODE(st.st_mode) != 0o700 or st.st_uid != os.geteuid():
        die("run directory must be owner-only mode 0700")
    if path.resolve(strict=True) != path:
        die("run directory path must be canonical")


def fsync_dir(path: pathlib.Path) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def publish_sidecar(path: pathlib.Path, digest: str, mode: int = 0o600) -> None:
    """Publish or verify the exact no-clobber digest sidecar."""
    sidecar = path.with_name(path.name + ".sha256")
    sidecar_data = f"{digest}  {path.name}\n".encode()
    tmp_sidecar = path.parent / f".{sidecar.name}.tmp.{os.getpid()}.{time.time_ns()}"
    fd = os.open(tmp_sidecar, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), mode)
    try:
        offset = 0
        while offset < len(sidecar_data):
            offset += os.write(fd, sidecar_data[offset:])
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        os.link(tmp_sidecar, sidecar)
        fsync_dir(path.parent)
    except FileExistsError:
        existing = owned_secure_file(sidecar, f"{path.name} SHA256 sidecar")
        if existing != sidecar_data:
            die(f"refusing mismatched existing receipt sidecar: {sidecar}")
    finally:
        with contextlib.suppress(FileNotFoundError):
            tmp_sidecar.unlink()
        fsync_dir(path.parent)


def publish_bytes(path: pathlib.Path, data: bytes, mode: int = 0o600) -> str:
    """Durably publish without clobbering; heal only an exact orphan."""
    if not path.is_absolute() or path.parent.resolve(strict=True) != path.parent:
        die(f"output path is not absolute/canonical: {path}")
    digest = sha256_bytes(data)
    token = f".{path.name}.tmp.{os.getpid()}.{time.time_ns()}"
    tmp = path.parent / token
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), mode)
    try:
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.fsync(fd)
    finally:
        os.close(fd)
    linked = False
    try:
        os.link(tmp, path)
        linked = True
        fsync_dir(path.parent)
    except FileExistsError:
        sidecar = path.with_name(path.name + ".sha256")
        try:
            sidecar.lstat()
        except FileNotFoundError:
            existing = owned_secure_file(path, path.name)
            if existing != data:
                die(f"refusing to clobber differing orphan receipt: {path}")
        else:
            die(f"refusing to clobber existing receipt: {path}")
    finally:
        with contextlib.suppress(FileNotFoundError):
            tmp.unlink()
        fsync_dir(path.parent)
    publish_sidecar(path, digest, mode)
    return digest


def publish_json(path: pathlib.Path, value: Any) -> str:
    return publish_bytes(path, canonical_json(value))


def load_run_receipt(run_dir: pathlib.Path, name: str) -> tuple[Any, str]:
    path = run_dir / name
    sidecar = path.with_name(path.name + ".sha256")
    try:
        sidecar.lstat()
    except FileNotFoundError:
        # A power loss after the receipt link was fsynced but before its
        # sidecar link leaves secure immutable bytes that can be certified by
        # their exact self-hash. Never repair an existing malformed sidecar.
        data = owned_secure_file(path, name)
        try:
            json.loads(data)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            die(f"{name} orphan is not valid JSON: {exc}")
        publish_sidecar(path, sha256_bytes(data))
    side_data = owned_secure_file(sidecar, f"{name} SHA256 sidecar").decode("ascii", "strict")
    match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_.-]+)\n", side_data)
    if not match or match.group(2) != path.name:
        die(f"{name} SHA256 sidecar has invalid shape")
    return parse_secure_json(path, name, match.group(1))


@dataclass(frozen=True)
class RuntimeNode:
    node: int
    service: str
    container: str
    wallet: str


@dataclass(frozen=True)
class RuntimeContract:
    raw: dict[str, Any]
    sha256: str
    path: pathlib.Path
    compose_project: str
    image_ref: str
    image_id: str
    cli_path: str
    cli_sha256: str
    daemon_path: str
    daemon_sha256: str
    datadir: str
    transport_sha256: str
    lock_paths: tuple[str, ...]
    node_lock_template: str
    nodes: tuple[RuntimeNode, ...]


def validate_runtime_manifest(path: pathlib.Path, expected_hash: str | None = None) -> RuntimeContract:
    raw, digest = parse_secure_json(path, "runtime manifest", expected_hash)
    if not isinstance(raw, dict) or raw.get("schema") != 1 or raw.get("kind") != "fleet31-installed-v30.1.4-runtime-contract":
        die("runtime manifest schema/kind mismatch")
    if raw.get("source_commit") != SOURCE_COMMIT or raw.get("source_tree") != SOURCE_TREE:
        die("runtime manifest is not bound to the installed signed v30.1.4 source")
    if raw.get("source_signer_fingerprint") != SOURCE_SIGNER:
        die("runtime manifest source signer mismatch")
    if raw.get("network_version") != NETWORK_VERSION or raw.get("subversion") != SUBVERSION:
        die("runtime manifest network version/subversion mismatch")
    fields = ["compose_project", "image_ref", "image_id", "cli_path", "cli_sha256",
              "daemon_path", "daemon_sha256", "datadir", "transport_sha256",
              "node_lock_template"]
    for field in fields:
        if not isinstance(raw.get(field), str) or not raw[field]:
            die(f"runtime manifest field {field} is absent")
    for field in ["cli_sha256", "daemon_sha256", "transport_sha256"]:
        require_hex64(raw[field], f"runtime manifest {field}")
    for field in ["cli_path", "daemon_path", "datadir"]:
        if not raw[field].startswith("/"):
            die(f"runtime manifest {field} must be absolute")
    lock_paths_raw = raw.get("global_lock_paths")
    if not isinstance(lock_paths_raw, list) or not lock_paths_raw:
        die("runtime manifest global_lock_paths must be a nonempty list")
    lock_paths: list[str] = []
    for item in lock_paths_raw:
        if not isinstance(item, str) or not item.startswith("/") or item in lock_paths:
            die("runtime manifest global lock paths must be unique absolute paths")
        lock_paths.append(item)
    if "{node:02d}" not in raw["node_lock_template"] or not raw["node_lock_template"].startswith("/"):
        die("runtime manifest node_lock_template must be absolute and contain {node:02d}")
    nodes_raw = raw.get("nodes")
    if not isinstance(nodes_raw, list):
        die("runtime manifest nodes must be an array")
    nodes: list[RuntimeNode] = []
    for item in nodes_raw:
        if not isinstance(item, dict) or set(item) != {"node", "service", "container", "wallet"}:
            die("runtime manifest node entry shape changed")
        node = require_int(item["node"], "runtime node", 1)
        for field in ["service", "container", "wallet"]:
            if not isinstance(item[field], str):
                die(f"runtime node {node} {field} must be a string")
        if item["service"] != f"node{node:02d}":
            die(f"runtime node {node} service mismatch")
        nodes.append(RuntimeNode(node, item["service"], item["container"], item["wallet"]))
    if tuple(n.node for n in nodes) != NODE_SET:
        die("runtime manifest node set/order must be exactly 1-29,31,32; node30 is forbidden")
    return RuntimeContract(
        raw=raw, sha256=digest, path=path, compose_project=raw["compose_project"],
        image_ref=raw["image_ref"], image_id=raw["image_id"],
        cli_path=raw["cli_path"], cli_sha256=raw["cli_sha256"],
        daemon_path=raw["daemon_path"], daemon_sha256=raw["daemon_sha256"],
        datadir=raw["datadir"], transport_sha256=raw["transport_sha256"],
        lock_paths=tuple(lock_paths), node_lock_template=raw["node_lock_template"],
        nodes=tuple(nodes))


class Transport:
    def __init__(self, runtime: RuntimeContract):
        test_path = os.environ.get("FLEET31_TEST_TRANSPORT")
        if test_path:
            if os.geteuid() == 0:
                die("test transport is forbidden for root/live execution")
            path = pathlib.Path(test_path)
            expected = TEST_TRANSPORT_SHA256
            if expected == "REPLACE_TEST_TRANSPORT_SHA256" or sha256_file(path) != expected:
                die("test transport bytes do not match the sealed repository fixture")
            self.path = path
            self.test = True
        else:
            if os.geteuid() != 0:
                die("live execution requires root and the canonical /usr/bin/docker transport")
            self.path = PRODUCTION_DOCKER
            self.test = False
            try:
                st = self.path.lstat()
            except FileNotFoundError:
                die("canonical /usr/bin/docker is absent")
            if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_uid != 0 or (st.st_mode & 0o022):
                die("canonical /usr/bin/docker ownership or mode is unsafe")
            if sha256_file(self.path) != runtime.transport_sha256:
                die("canonical Docker transport hash differs from the runtime contract")
        self.runtime = runtime

    def run(self, args: Sequence[str], timeout: int = 45) -> str:
        env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "TZ": "UTC"}
        if self.test:
            fixture = os.environ.get("FLEET31_FIXTURE")
            scenario = os.environ.get("FLEET31_SCENARIO", "happy")
            if not fixture or not pathlib.Path(fixture).is_absolute():
                die("test transport requires an absolute FLEET31_FIXTURE")
            env.update({"FLEET31_FIXTURE": fixture, "FLEET31_SCENARIO": scenario})
        proc = subprocess.run([str(self.path), *args], stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, env=env, timeout=timeout, check=False)
        if proc.returncode != 0:
            detail = proc.stderr.strip() or proc.stdout.strip() or f"exit {proc.returncode}"
            raise GateError(detail)
        return proc.stdout

    def docker_json(self, args: Sequence[str]) -> Any:
        try:
            return json.loads(self.run(args))
        except json.JSONDecodeError as exc:
            die(f"transport returned invalid JSON for {' '.join(args)}: {exc}")

    def rpc(self, node: RuntimeNode, method: str, *params: Any) -> Any:
        allowed = {
            "getblockchaininfo", "getnetworkinfo", "getconnectioncount", "listwallets",
            "getwalletinfo", "getstakinginfo", "getpowmininginfo", "getpowclaimrecoveryinfo",
            "resolveallshadowpowclaims", "gettransaction", "gettxout", "getblockheader",
        }
        if method not in allowed:
            raise RpcError(node.node, method, "RPC method is not allowlisted")
        cli_args = ["exec", node.container, self.runtime.cli_path,
                    f"-datadir={self.runtime.datadir}"]
        if node.wallet:
            cli_args.append(f"-rpcwallet={node.wallet}")
        cli_args.append(method)
        for param in params:
            if isinstance(param, (dict, list)):
                cli_args.append(json.dumps(param, sort_keys=True, separators=(",", ":")))
            elif isinstance(param, bool):
                cli_args.append("true" if param else "false")
            else:
                cli_args.append(str(param))
        try:
            output = self.run(cli_args)
        except GateError as exc:
            raise RpcError(node.node, method, str(exc)) from exc
        # Installed v30.1.4 prints no bytes (exit 0) for a null gettxout result.
        # Normalize only that exact public-RPC encoding. Whitespace, malformed
        # JSON, and empty output from every other method are protocol failures,
        # not ordinary RpcError values that a caller may intentionally ignore.
        if method == "gettxout" and output == "":
            return None
        if output == "":
            die(f"node{node.node} {method} returned empty stdout")
        try:
            return json.loads(output)
        except json.JSONDecodeError as exc:
            die(f"node{node.node} {method} returned invalid JSON: {exc}")

    def runtime_snapshot(self, node: RuntimeNode) -> dict[str, Any]:
        inspect = self.docker_json(["inspect", node.container])
        if not isinstance(inspect, list) or len(inspect) != 1 or not isinstance(inspect[0], dict):
            die(f"node{node.node} Docker inspect shape changed")
        item = inspect[0]
        state = item.get("State", {})
        config = item.get("Config", {})
        labels = config.get("Labels", {}) or {}
        if (config.get("Image") != self.runtime.image_ref or item.get("Image") != self.runtime.image_id or
                state.get("Running") is not True or state.get("Paused") is not False or
                state.get("Health", {}).get("Status") != "healthy" or
                labels.get("com.docker.compose.project") != self.runtime.compose_project or
                labels.get("com.docker.compose.service") != node.service):
            die(f"node{node.node} runtime identity/health differs from the sealed contract")
        hashes = self.run(["exec", node.container, "/usr/bin/sha256sum",
                           self.runtime.cli_path, self.runtime.daemon_path]).splitlines()
        observed: dict[str, str] = {}
        for line in hashes:
            parts = line.split()
            if len(parts) != 2:
                die(f"node{node.node} executable hash output changed")
            observed[parts[1]] = parts[0]
        if observed.get(self.runtime.cli_path) != self.runtime.cli_sha256 or observed.get(self.runtime.daemon_path) != self.runtime.daemon_sha256:
            die(f"node{node.node} installed executable hashes differ from the runtime contract")
        return {
            "node": node.node, "service": node.service, "container": node.container,
            "wallet": node.wallet, "container_id": item.get("Id"),
            "started_at": state.get("StartedAt"), "image_ref": config.get("Image"),
            "image_id": item.get("Image"), "cli_sha256": observed[self.runtime.cli_path],
            "daemon_sha256": observed[self.runtime.daemon_path], "healthy": True,
        }


def chain_identity(chain: dict[str, Any]) -> dict[str, Any]:
    fields = ["chain", "blocks", "headers", "bestblockhash", "chainwork",
              "initialblockdownload", "pruned", "warnings"]
    return {key: chain.get(key) for key in fields}


def validate_chain(chain: Any, node: int) -> dict[str, Any]:
    if not isinstance(chain, dict):
        die(f"node{node} chain result is not an object")
    if (chain.get("chain") != "main" or chain.get("initialblockdownload") is not False or
            chain.get("pruned") is not False or chain.get("blocks") != chain.get("headers") or
            chain.get("warnings", "") != ""):
        die(f"node{node} is not on a clean, unpruned, synchronized main-chain cut")
    require_int(chain.get("blocks"), f"node{node} blocks", 1)
    require_hex64(chain.get("bestblockhash"), f"node{node} tip")
    require_hex64(chain.get("chainwork"), f"node{node} chainwork")
    return chain


def preview_options(status_hint: str = "ready") -> dict[str, Any]:
    options: dict[str, Any] = {
        "action": "preview", "max_fee_per_resolution": f"{PER_NODE_CAP:.8f}",
        "max_total_fee": f"{PER_NODE_CAP:.8f}",
    }
    if status_hint == "ready":
        options["fee_rate"] = str(FEE_RATE_ATOMS_PER_VB)
    return options


def component_identity(action: dict[str, Any]) -> dict[str, Any]:
    return {
        "anchor": action.get("anchor"),
        "generation_fingerprint": action.get("generation_fingerprint"),
        "component_fingerprint": action.get("component_fingerprint"),
        "classification": action.get("classification"),
        "claim_txids": action.get("claim_txids"),
        "descendant_claims": action.get("descendant_claims"),
        "fee": action.get("fee"), "vsize": action.get("vsize"),
        "input_amount": action.get("input_amount"), "output_amount": action.get("output_amount"),
    }


def validate_preview(preview: Any, node: int, allowed_status: set[str],
                     allow_relay_authorized: bool = False) -> dict[str, Any]:
    if not isinstance(preview, dict):
        die(f"node{node} recovery preview is not an object")
    required = {
        "action": "preview", "plan_reusable": True, "complete": True,
        "wallet_tip_matches": True, "one_call_finality": False,
        "frontier_may_advance": True, "contains_revalidating_unbound_proof": True,
        "success": True, "stale_plan": False, "durable_state_changed": False,
        "durable_state_ambiguous": False,
    }
    for key, expected in required.items():
        if preview.get(key) != expected:
            die(f"node{node} preview {key} changed: expected {expected!r}, got {preview.get(key)!r}")
    require_hex64(preview.get("plan_id"), f"node{node} plan_id")
    require_hex64(preview.get("active_tip"), f"node{node} preview active_tip")
    require_int(preview.get("active_height"), f"node{node} preview height", 1)
    require_int(preview.get("wallet_generation"), f"node{node} wallet generation", 0)
    exact_amount(preview.get("max_fee_per_resolution"), PER_NODE_CAP, f"node{node} per-resolution cap")
    exact_amount(preview.get("aggregate_batch_fee_cap"), PER_NODE_CAP, f"node{node} local batch cap")
    exact_amount(preview.get("total_fee"), PER_NODE_CAP, f"node{node} total fee")
    if preview.get("actionable_components") != 1 or not isinstance(preview.get("actions"), list) or len(preview["actions"]) != 1:
        die(f"node{node} must have exactly one actionable recovery component")
    if not isinstance(preview.get("refused"), list) or any(x.get("reason_code") != "anchor-spent" for x in preview["refused"] if isinstance(x, dict)):
        die(f"node{node} has a refused component outside the historical anchor-spent family")
    action = preview["actions"][0]
    if not isinstance(action, dict) or action.get("status") not in allowed_status:
        die(f"node{node} action status is not one of {sorted(allowed_status)}")
    expected_classification = (
        "current_branch_ineligible" if action["status"] == "ready"
        else "resolution_pending"
    )
    if (action.get("classification") != expected_classification or
            action.get("conflicts_with_revalidating_unbound_proof") is not True or
            action.get("reason_code") != "unbound-proof-may-revalidate" or
            action.get("frontier_may_advance") is not True):
        die(f"node{node} component is not the exact {expected_classification} QQP2 risk family")
    if not allow_relay_authorized and action.get("in_mempool") is not False:
        die(f"node{node} recovery unexpectedly entered the mempool")
    anchor = action.get("anchor")
    if not isinstance(anchor, dict) or set(anchor) != {"txid", "vout"} or anchor.get("vout") != 0:
        die(f"node{node} recovery anchor shape changed")
    require_hex64(anchor.get("txid"), f"node{node} anchor txid")
    require_hex64(action.get("generation_fingerprint"), f"node{node} generation fingerprint")
    require_hex64(action.get("component_fingerprint"), f"node{node} component fingerprint")
    if not isinstance(action.get("claim_txids"), list) or not action["claim_txids"]:
        die(f"node{node} claim transaction set is empty")
    for txid in action["claim_txids"]:
        require_hex64(txid, f"node{node} claim txid")
    exact_amount(action.get("fee"), PER_NODE_CAP, f"node{node} recovery fee")
    if action.get("vsize") != EXPECTED_VSIZE:
        die(f"node{node} recovery vsize changed")
    if action["status"] == "ready":
        if action.get("persisted") is not False or action.get("relay_authorized") is not False:
            die(f"node{node} ready recovery unexpectedly has durable state")
        require_hex64(action.get("unsigned_template_hash"), f"node{node} unsigned template")
        if preview.get("fee_rate_atoms_per_k") != FEE_RATE_ATOMS_PER_K:
            die(f"node{node} explicit fee rate changed")
    else:
        if action.get("persisted") is not True:
            die(f"node{node} signed draft is absent")
        if not allow_relay_authorized and action.get("relay_authorized") is not False:
            die(f"node{node} signed draft already has relay authority")
        if allow_relay_authorized and action.get("relay_authorized") not in {True, False}:
            die(f"node{node} signed draft relay authority is not typed")
        require_hex64(action.get("resolution_txid"), f"node{node} resolution txid")
    return preview


def read_signed_transaction(transport: Transport, node: RuntimeNode,
                            action: dict[str, Any]) -> tuple[dict[str, Any], str, dict[str, Any]]:
    txid = require_hex64(action.get("resolution_txid"), f"node{node.node} resolution txid")
    tx = transport.rpc(node, "gettransaction", txid, False, True)
    if not isinstance(tx, dict) or tx.get("txid") != txid or not isinstance(tx.get("hex"), str):
        die(f"node{node.node} exact signed transaction is unavailable")
    raw = tx["hex"]
    if not re.fullmatch(r"[0-9a-f]+", raw) or len(raw) % 2:
        die(f"node{node.node} signed transaction hex is malformed")
    decoded = tx.get("decoded")
    if not isinstance(decoded, dict) or decoded.get("txid") != txid:
        die(f"node{node.node} decoded signed transaction identity changed")
    vin = decoded.get("vin")
    vout = decoded.get("vout")
    anchor = action["anchor"]
    if (not isinstance(vin, list) or len(vin) != 1 or vin[0].get("txid") != anchor["txid"] or
            vin[0].get("vout") != anchor["vout"] or vin[0].get("sequence") != 4294967295 or
            not isinstance(vout, list) or len(vout) != 1 or vout[0].get("n") != 0):
        die(f"node{node.node} signed transaction is not the exact one-input/one-output anchor recycle")
    exact_amount(vout[0].get("value"), decimal_amount(action["output_amount"], "output amount"),
                 f"node{node.node} signed output amount")
    if decoded.get("vsize") != EXPECTED_VSIZE:
        die(f"node{node.node} signed transaction vsize changed")
    return tx, raw, decoded


def signed_transaction(transport: Transport, node: RuntimeNode, action: dict[str, Any]) -> dict[str, Any]:
    """Legacy Phase-A receipt shape retained for installed live receipts."""
    tx, raw, decoded = read_signed_transaction(transport, node, action)
    vout = decoded["vout"]
    return {
        "resolution_txid": tx["txid"], "raw_hex_sha256": sha256_bytes(raw.encode()),
        "decoded_sha256": sha256_bytes(canonical_json(decoded)),
        "output_script": vout[0].get("scriptPubKey", {}).get("hex"),
        "confirmations": tx.get("confirmations", 0), "blockhash": tx.get("blockhash"),
    }


def phase_b_signed_evidence(transport: Transport, node: RuntimeNode,
                            action: dict[str, Any], prove_unspent_anchor: bool) -> dict[str, Any]:
    """Separate immutable signed bytes from mutable chain observations."""
    tx, raw, decoded = read_signed_transaction(transport, node, action)
    vin = decoded["vin"][0]
    vout = decoded["vout"][0]
    output_value = decimal_amount(vout.get("value"), f"node{node.node} signed output")
    output_script = vout.get("scriptPubKey", {}).get("hex")
    if not isinstance(output_script, str) or not re.fullmatch(r"[0-9a-f]+", output_script):
        die(f"node{node.node} signed output script is not lowercase hex")
    identity = {
        "resolution_txid": tx["txid"], "raw_hex_sha256": sha256_bytes(raw.encode()),
        "decoded_sha256": sha256_bytes(canonical_json(decoded)),
        "input": {"txid": vin["txid"], "vout": vin["vout"], "sequence": vin["sequence"]},
        "output": {"n": vout["n"], "value": f"{output_value:.8f}", "script": output_script},
        "vsize": decoded["vsize"],
    }
    relay_metadata = tx.get("qq_shadow_pow_resolution_relay_authorized")
    if relay_metadata not in {"0", "1"}:
        die(f"node{node.node} signed resolution lacks typed durable relay-authority metadata")
    evidence: dict[str, Any] = {
        "identity": identity,
        "observation": {"confirmations": tx.get("confirmations", 0),
                        "blockhash": tx.get("blockhash"),
                        "durable_relay_authorized_metadata": relay_metadata},
    }
    if prove_unspent_anchor:
        anchor = action["anchor"]
        txout = transport.rpc(node, "gettxout", anchor["txid"], anchor["vout"], False)
        if not isinstance(txout, dict):
            die(f"node{node.node} exact anchor is not independently unspent on the active chain")
        anchor_value = decimal_amount(txout.get("value"), f"node{node.node} anchor value")
        anchor_script = txout.get("scriptPubKey", {}).get("hex")
        if not isinstance(anchor_script, str) or not re.fullmatch(r"[0-9a-f]+", anchor_script):
            die(f"node{node.node} anchor script is not lowercase hex")
        exact_amount(anchor_value, decimal_amount(action["input_amount"], "input amount"),
                     f"node{node.node} independently observed anchor value")
        if anchor_script != output_script:
            die(f"node{node.node} signed resolution does not recycle the exact anchor script")
        fee = anchor_value - output_value
        exact_amount(fee, PER_NODE_CAP, f"node{node.node} independently computed signed fee")
        exact_amount(action.get("fee"), fee, f"node{node.node} declared action fee")
        evidence["fee_proof"] = {
            "anchor": {"txid": anchor["txid"], "vout": anchor["vout"],
                       "value": f"{anchor_value:.8f}", "script": anchor_script},
            "signed_output_value": f"{output_value:.8f}",
            "computed_fee_blk": f"{fee:.8f}", "include_mempool": False,
        }
    return evidence


def require_normal_unlock(transport: Transport, node: RuntimeNode) -> dict[str, Any]:
    wallets = transport.rpc(node, "listwallets")
    wallet = transport.rpc(node, "getwalletinfo")
    if (wallets != [node.wallet] or not isinstance(wallet, dict) or
            wallet.get("walletname") != node.wallet or
            wallet.get("private_keys_enabled") is not True or
            wallet.get("external_signer", False) is not False or
            wallet.get("scanning", False) is not False or
            wallet.get("unlocked_staking_only") is not False or
            not isinstance(wallet.get("unlocked_until"), int) or
            wallet["unlocked_until"] <= int(time.time())):
        die(f"node{node.node} exact selected wallet is not normally unlocked with local private keys")
    return {
        "walletname": wallet.get("walletname"), "format": wallet.get("format"),
        "txcount": wallet.get("txcount"), "unlocked_until": wallet.get("unlocked_until"),
        "private_keys_enabled": True, "external_signer": False,
        "unlocked_staking_only": False,
    }


def pinned_node(node: RuntimeNode, runtime_snapshot: dict[str, Any]) -> RuntimeNode:
    container_id = require_hex64(runtime_snapshot.get("container_id"),
                                 f"node{node.node} container id")
    return RuntimeNode(node.node, node.service, container_id, node.wallet)


RUNTIME_STABLE_FIELDS = {
    "node", "service", "container", "wallet", "image_ref", "image_id",
    "cli_sha256", "daemon_sha256", "healthy",
}


def runtime_transition(expected: Any, observed: Any, node: int,
                       label: str) -> dict[str, Any]:
    """Validate the same installed runtime while typing restart-only drift.

    Container ID and start time are ephemeral across a normal restart.  They
    are recorded, freshly inspected, and used to pin every RPC cut, but they
    are not product/config identity.  Every stable image, executable,
    topology, and wallet field remains exact.
    """
    expected_keys = RUNTIME_STABLE_FIELDS | {"container_id", "started_at"}
    if (not isinstance(expected, dict) or not isinstance(observed, dict) or
            set(expected) != expected_keys or set(observed) != expected_keys):
        die(f"node{node} {label} runtime snapshot shape changed")
    for snapshot_label, snapshot in (("authorized", expected), ("observed", observed)):
        require_hex64(snapshot.get("container_id"),
                      f"node{node} {label} {snapshot_label} container id")
        if not isinstance(snapshot.get("started_at"), str) or not snapshot["started_at"]:
            die(f"node{node} {label} {snapshot_label} start time is untyped")
    expected_stable = {key: expected[key] for key in RUNTIME_STABLE_FIELDS}
    observed_stable = {key: observed[key] for key in RUNTIME_STABLE_FIELDS}
    if expected_stable != observed_stable:
        die(f"node{node} {label} stable runtime identity changed")
    return {
        "authorized_runtime": expected,
        "observed_runtime": observed,
        "stable_identity": observed_stable,
        "ephemeral_container_changed": any(
            expected[key] != observed[key] for key in ("container_id", "started_at")),
    }


def stable_preview(transport: Transport, node: RuntimeNode, status_hint: str,
                   allowed_status: set[str], attempts: int = 3,
                   allow_relay_authorized: bool = False) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    for _ in range(attempts):
        before = validate_chain(transport.rpc(node, "getblockchaininfo"), node.node)
        preview = transport.rpc(node, "resolveallshadowpowclaims", preview_options(status_hint))
        after = validate_chain(transport.rpc(node, "getblockchaininfo"), node.node)
        if chain_identity(before) != chain_identity(after):
            continue
        preview = validate_preview(preview, node.node, allowed_status,
                                   allow_relay_authorized=allow_relay_authorized)
        if preview["active_tip"] != after["bestblockhash"] or preview["active_height"] != after["blocks"]:
            continue
        return after, preview, preview["actions"][0]
    die(f"node{node.node} could not produce a stable exact recovery preview in {attempts} attempts")


def validate_phase_b_transient(preview: Any, node: int, chain: dict[str, Any],
                               phase_a_component: dict[str, Any]) -> dict[str, Any]:
    """Recognize only the exact temporary live-claim/no-action branch."""
    required = {"action": "preview", "plan_reusable": True, "complete": True,
                "wallet_tip_matches": True, "success": True, "stale_plan": False,
                "durable_state_changed": False, "durable_state_ambiguous": False,
                "actionable_components": 0}
    if not isinstance(preview, dict) or any(preview.get(k) != v for k, v in required.items()):
        die(f"node{node} nonactionable Phase-B preview is not the exact bounded live-claim branch")
    if (preview.get("active_tip") != chain["bestblockhash"] or
            preview.get("active_height") != chain["blocks"] or
            preview.get("actions") != []):
        die(f"node{node} transient Phase-B preview is not bound to the stable chain cut")
    exact_amount(preview.get("total_fee"), Decimal("0"), f"node{node} transient total fee")
    refused = preview.get("refused")
    if not isinstance(refused, list):
        die(f"node{node} transient Phase-B refusal set is absent")
    live = [item for item in refused if isinstance(item, dict) and
            item.get("reason_code") == "claim-not-terminal" and
            item.get("classification") == "live"]
    if len(live) != 1 or any(item.get("reason_code") not in {"claim-not-terminal", "anchor-spent"}
                             for item in refused if isinstance(item, dict)):
        die(f"node{node} transient Phase-B refusal family changed")
    item = live[0]
    for key in ["anchor", "generation_fingerprint", "claim_txids", "descendant_claims"]:
        if item.get(key) != phase_a_component.get(key):
            die(f"node{node} transient live component field {key} differs from Phase A")
    return item


def validate_phase_b_terminal_preview(preview: Any, node: int,
                                      chain: dict[str, Any],
                                      authorized_component: dict[str, Any]) -> dict[str, Any]:
    """Type only an active-chain anchor-spent terminal preview."""
    required = {"action": "preview", "plan_reusable": True, "complete": True,
                "wallet_tip_matches": True, "success": True, "stale_plan": False,
                "durable_state_changed": False, "durable_state_ambiguous": False,
                "actionable_components": 0}
    if not isinstance(preview, dict) or any(preview.get(k) != v for k, v in required.items()):
        die(f"node{node} terminal Phase-B preview semantics changed")
    if (preview.get("active_tip") != chain["bestblockhash"] or
            preview.get("active_height") != chain["blocks"] or
            preview.get("actions") != []):
        die(f"node{node} terminal Phase-B preview is not bound to its chain cut")
    exact_amount(preview.get("total_fee"), Decimal("0"),
                 f"node{node} terminal Phase-B total fee")
    refused = preview.get("refused")
    if (not isinstance(refused, list) or not refused or any(
            not isinstance(item, dict) or item.get("reason_code") != "anchor-spent"
            for item in refused)):
        die(f"node{node} terminal Phase-B refusal family is not exact anchor-spent")
    matches = [item for item in refused if
               item.get("anchor") == authorized_component.get("anchor") and
               item.get("generation_fingerprint") ==
               authorized_component.get("generation_fingerprint") and
               item.get("claim_txids") == authorized_component.get("claim_txids")]
    if len(matches) != 1:
        die(f"node{node} terminal Phase-B preview lacks the exact authorized component refusal")
    return matches[0]


def phase_b_preview_cut(transport: Transport, node: RuntimeNode,
                        allow_relay_authorized: bool,
                        phase_a_component: dict[str, Any] | None = None
                        ) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any] | None]:
    for _ in range(3):
        before = validate_chain(transport.rpc(node, "getblockchaininfo"), node.node)
        preview = transport.rpc(node, "resolveallshadowpowclaims", preview_options("reuse_managed"))
        after = validate_chain(transport.rpc(node, "getblockchaininfo"), node.node)
        if chain_identity(before) != chain_identity(after):
            continue
        if isinstance(preview, dict) and preview.get("actions") == []:
            if phase_a_component is None:
                die(f"node{node.node} unexpectedly has no actionable Phase-B component")
            refused = preview.get("refused")
            has_live = isinstance(refused, list) and any(
                isinstance(item, dict) and item.get("reason_code") == "claim-not-terminal"
                for item in refused)
            if has_live:
                validate_phase_b_transient(preview, node.node, after, phase_a_component)
            else:
                validate_phase_b_terminal_preview(
                    preview, node.node, after, phase_a_component)
            return after, preview, None
        preview = validate_preview(preview, node.node, {"reuse_managed"},
                                   allow_relay_authorized=allow_relay_authorized)
        if preview["active_tip"] != after["bestblockhash"] or preview["active_height"] != after["blocks"]:
            continue
        return after, preview, preview["actions"][0]
    die(f"node{node.node} could not produce a stable exact Phase-B preview in three attempts")


def audit_node(transport: Transport, runtime: RuntimeContract, node: RuntimeNode) -> dict[str, Any]:
    # A normally advancing chain is not an identity failure. Retry the entire
    # read-only envelope so the preview, wallet/recovery inventory, and final
    # bracket all describe one cut. Runtime drift remains immediately fatal.
    for _ in range(5):
        runtime_before = transport.runtime_snapshot(node)
        chain, preview, action = stable_preview(transport, node, "ready", {"ready", "reuse_managed"})
        # Existing signed drafts reject an explicit fee-rate override; retry the
        # preview without repricing only for that exact, persisted status.
        if action.get("status") == "reuse_managed" and "fee_rate_atoms_per_k" in preview:
            die(f"node{node.node} signed draft was unexpectedly repriced")
        network = transport.rpc(node, "getnetworkinfo")
        peers = transport.rpc(node, "getconnectioncount")
        wallets = transport.rpc(node, "listwallets")
        wallet = transport.rpc(node, "getwalletinfo")
        staking = transport.rpc(node, "getstakinginfo")
        mining = transport.rpc(node, "getpowmininginfo")
        recovery = transport.rpc(node, "getpowclaimrecoveryinfo", True)
        runtime_after = transport.runtime_snapshot(node)
        after = validate_chain(transport.rpc(node, "getblockchaininfo"), node.node)
        if runtime_before != runtime_after:
            die(f"node{node.node} runtime changed across the audit cut")
        recovery_cut_matches = (
            isinstance(recovery, dict) and
            recovery.get("active_tip") == chain["bestblockhash"] and
            recovery.get("active_height") == chain["blocks"])
        if chain_identity(chain) != chain_identity(after) or not recovery_cut_matches:
            continue
        break
    else:
        die(f"node{node.node} chain/recovery cut kept advancing across five full read-only audit attempts")
    if not isinstance(network, dict) or network.get("version") != NETWORK_VERSION or network.get("subversion") != SUBVERSION:
        die(f"node{node.node} network identity is not installed v30.1.4")
    if not isinstance(peers, int) or peers < 1:
        die(f"node{node.node} has no peers")
    if wallets != [node.wallet]:
        die(f"node{node.node} loaded-wallet inventory changed")
    if (not isinstance(wallet, dict) or wallet.get("private_keys_enabled") is not True or
            wallet.get("external_signer", False) is not False or wallet.get("scanning", False) is not False or
            wallet.get("unlocked_staking_only") is not False or not isinstance(wallet.get("unlocked_until"), int) or
            wallet["unlocked_until"] <= int(time.time())):
        die(f"node{node.node} is not normally unlocked with local private keys")
    if (not isinstance(staking, dict) or staking.get("enabled") is not True or
            staking.get("staking") is not True or decimal_amount(staking.get("weight", 0), "staking weight") <= 0):
        die(f"node{node.node} PoS is not actively searching with positive weight")
    if (not isinstance(mining, dict) or mining.get("enabled") is not True or
            mining.get("state") != "claim_quarantined" or decimal_amount(mining.get("hashrate"), "hashrate") != 0 or
            mining.get("blocking_quarantined_claims") != 1 or mining.get("actionable_quarantined_claims") != 1 or
            mining.get("indeterminate_quarantined_claims") != 0 or
            mining.get("claim_recovery_database_outcome_ambiguous") is not False):
        die(f"node{node.node} is not the exact enabled-but-one-claim-quarantined PoW baseline")
    if (not isinstance(recovery, dict) or recovery.get("chain_ready") is not True or
            recovery.get("wallet_tip_matches") is not True or recovery.get("database_outcome_ambiguous") is not False or
            recovery.get("active_tip") != chain["bestblockhash"] or recovery.get("active_height") != chain["blocks"]):
        die(f"node{node.node} verbose recovery inventory is incoherent")
    component_details = recovery.get("component_details")
    matches = [item for item in component_details or [] if isinstance(item, dict) and item.get("anchor") == {
        "txid": action["anchor"]["txid"], "vout": action["anchor"]["vout"],
        "amount": item.get("anchor", {}).get("amount"), "scriptPubKey": item.get("anchor", {}).get("scriptPubKey")
    }]
    # The direct comparison above intentionally ignores amount/script while
    # still demanding one exact outpoint; inspect those fields separately.
    matches = [item for item in component_details or [] if isinstance(item, dict) and
               item.get("anchor", {}).get("txid") == action["anchor"]["txid"] and
               item.get("anchor", {}).get("vout") == action["anchor"]["vout"]]
    if len(matches) != 1:
        die(f"node{node.node} verbose component inventory lacks the exact preview anchor")
    detail = matches[0]
    if (detail.get("generation_fingerprint") != action["generation_fingerprint"] or
            detail.get("component_fingerprint") != action["component_fingerprint"] or
            detail.get("claim_txids") != action["claim_txids"] or detail.get("anchor_authenticated") is not True or
            detail.get("anchor_unspent") is not True or detail.get("has_revalidating_unbound_proof") is not True):
        die(f"node{node.node} preview and verbose component identities differ")
    result = {
        "node": node.node, "runtime": runtime_after,
        "chain": {"height": chain["blocks"], "tip": chain["bestblockhash"], "chainwork": chain["chainwork"]},
        "peers": peers, "wallet_generation": preview["wallet_generation"],
        "wallet_txcount": wallet.get("txcount"),
        "wallet_unlock_until": wallet["unlocked_until"],
        "staking": {"enabled": True, "staking": True, "weight": staking.get("weight")},
        "pow_baseline": {
            "enabled": mining.get("enabled"), "state": mining.get("state"),
            "hashrate": mining.get("hashrate"), "claims_submitted": mining.get("claims_submitted"),
            "threads": mining.get("threads"), "cpu_percent": mining.get("cpu_percent"),
            "payout_address": mining.get("payout_address"),
        },
        "plan": preview,
        "component": component_identity(action),
        "status": action["status"],
    }
    if action["status"] == "ready":
        result["unsigned_template_hash"] = action["unsigned_template_hash"]
    else:
        result["signed_transaction"] = signed_transaction(transport, node, action)
    return result


def tool_identity() -> tuple[pathlib.Path, str]:
    path = pathlib.Path(__file__).resolve(strict=True)
    actual = sha256_file(path)
    test_override = os.environ.get("FLEET31_TEST_TOOL_SHA256")
    if test_override:
        if (not os.environ.get("FLEET31_TEST_TRANSPORT") or os.geteuid() == 0 or
                test_override not in {PHASE_A_TOOL_SHA256, PHASE_B_EXECUTOR_TOOL_SHA256}):
            die("test-only historical tool identity override is forbidden outside the sealed nonroot fixture")
        return path, test_override
    return path, actual


def require_phase_a_fixture_mode(command: str) -> None:
    """This signed follow-up is live Phase-B-only.

    Phase-A entrypoints remain solely to reproduce and hostile-test the exact
    predecessor receipt contract with the sealed offline fixture.  They must
    fail before locks, transport construction, or RPC in every live mode.
    """
    if not os.environ.get("FLEET31_TEST_TRANSPORT"):
        die(f"{command} is disabled: this follow-up artifact is Phase-B-only and consumes exact predecessor Phase-A receipts")


def base_receipt(kind: str, runtime: RuntimeContract, tool_sha: str) -> dict[str, Any]:
    return {
        "schema": 1, "contract": CONTRACT, "kind": kind, "created_at": utc_now(),
        "tool_sha256": tool_sha,
        "installed_source": {"commit": SOURCE_COMMIT, "tree": SOURCE_TREE,
                             "signer_fingerprint": SOURCE_SIGNER},
        "runtime_manifest_sha256": runtime.sha256,
        "node_set": list(NODE_SET), "node30_excluded": True,
        "per_node_fee_cap_blk": f"{PER_NODE_CAP:.8f}",
        "aggregate_fee_cap_blk": f"{AGGREGATE_CAP:.8f}",
    }


def audit_command(args: argparse.Namespace) -> None:
    require_phase_a_fixture_mode("audit")
    run_dir = pathlib.Path(args.run_dir)
    ensure_secure_dir(run_dir, create=True)
    runtime_path = pathlib.Path(args.runtime_manifest)
    runtime = validate_runtime_manifest(runtime_path)
    _, tool_sha = tool_identity()
    transport = Transport(runtime)
    runtime_snapshot = run_dir / "runtime-manifest.json"
    publish_bytes(runtime_snapshot, owned_secure_file(runtime_path, "runtime manifest", runtime.sha256))
    nodes: list[dict[str, Any]] = []
    for node in runtime.nodes:
        nodes.append(audit_node(transport, runtime, node))
    if sum(decimal_amount(item["component"]["fee"], "audit fee") for item in nodes) != AGGREGATE_CAP:
        die("fleet audit total fee is not exactly the authorized 31-node aggregate")
    receipt = base_receipt("fleet31-shadowpow-recovery-audit", runtime, tool_sha)
    receipt.update({
        "mutation_performed": False, "result": "READY_FOR_PHASE_A_AUTHORITY",
        "transport": {"path": str(transport.path), "sha256": sha256_file(transport.path)},
        "nodes": nodes,
        "required_phase_a_authority": {
            "schema": 1, "kind": "fleet31-shadowpow-recovery-phase-a-authority",
            "decision": "authorize", "action": "sign_only", "node_set": list(NODE_SET),
            "node30_excluded": True, "audit_receipt_sha256": "REPLACE_WITH_AUDIT_SHA256",
            "runtime_manifest_sha256": runtime.sha256, "tool_sha256": tool_sha,
            "source_commit": SOURCE_COMMIT, "source_tree": SOURCE_TREE,
            "per_node_fee_cap_blk": f"{PER_NODE_CAP:.8f}",
            "aggregate_fee_cap_blk": f"{AGGREGATE_CAP:.8f}",
            "fee_rate_atoms_per_vb": str(FEE_RATE_ATOMS_PER_VB),
            "allow_fresh_plan_rebind_for_unchanged_component_and_fee": True,
            "acknowledgements": {
                "fee_and_conflict_risk": True,
                "durable_signed_draft_has_no_clean_public_cancellation": True,
                "confirmation_may_permanently_forfeit_revalidating_qqp2_quantum_payout": True,
                "no_relay_or_broadcast_authority_in_phase_a": True,
                "no_generic_transaction_rpc": True,
            },
        },
    })
    digest = publish_json(run_dir / "audit.json", receipt)
    print(json.dumps({"result": receipt["result"], "audit_sha256": digest, "run_dir": str(run_dir)}, sort_keys=True))


def load_runtime_from_run(run_dir: pathlib.Path) -> RuntimeContract:
    _, digest = load_run_receipt(run_dir, "runtime-manifest.json")
    return validate_runtime_manifest(run_dir / "runtime-manifest.json", digest)


def validate_common_authority(authority: Any, kind: str, action: str, runtime: RuntimeContract,
                              tool_sha: str) -> dict[str, Any]:
    if not isinstance(authority, dict) or authority.get("schema") != 1 or authority.get("kind") != kind:
        die(f"{kind} schema/kind mismatch")
    expected = {
        "decision": "authorize", "action": action, "node_set": list(NODE_SET),
        "node30_excluded": True, "runtime_manifest_sha256": runtime.sha256,
        "tool_sha256": tool_sha, "source_commit": SOURCE_COMMIT, "source_tree": SOURCE_TREE,
        "per_node_fee_cap_blk": f"{PER_NODE_CAP:.8f}",
        "aggregate_fee_cap_blk": f"{AGGREGATE_CAP:.8f}",
    }
    for key, value in expected.items():
        if authority.get(key) != value:
            die(f"authority field {key} differs from the exact fleet contract")
    return authority


def validate_phase_a_authority(authority: Any, runtime: RuntimeContract, tool_sha: str,
                               audit_sha: str) -> dict[str, Any]:
    authority = validate_common_authority(authority, "fleet31-shadowpow-recovery-phase-a-authority",
                                          "sign_only", runtime, tool_sha)
    if authority.get("audit_receipt_sha256") != audit_sha or authority.get("fee_rate_atoms_per_vb") != str(FEE_RATE_ATOMS_PER_VB):
        die("Phase-A authority is not bound to the exact audit and fee rate")
    require_bool(authority.get("allow_fresh_plan_rebind_for_unchanged_component_and_fee"), True,
                 "Phase-A fresh-plan acknowledgement")
    acknowledgements = authority.get("acknowledgements", {})
    for key in ["fee_and_conflict_risk", "durable_signed_draft_has_no_clean_public_cancellation",
                "confirmation_may_permanently_forfeit_revalidating_qqp2_quantum_payout",
                "no_relay_or_broadcast_authority_in_phase_a", "no_generic_transaction_rpc"]:
        require_bool(acknowledgements.get(key), True, f"Phase-A acknowledgement {key}")
    return authority


@contextlib.contextmanager
def mutation_locks(runtime: RuntimeContract) -> Iterator[list[dict[str, Any]]]:
    paths = [*runtime.lock_paths, *(runtime.node_lock_template.format(node=node) for node in NODE_SET)]
    if len(paths) != len(set(paths)):
        die("mutation lock paths are not unique")
    fds: list[int] = []
    identities: list[dict[str, Any]] = []
    try:
        for item in paths:
            path = pathlib.Path(item)
            if not path.is_absolute():
                die(f"mutation lock path is not absolute: {path}")
            path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            parent_st = path.parent.lstat()
            if (not stat.S_ISDIR(parent_st.st_mode) or stat.S_ISLNK(parent_st.st_mode) or
                    path.parent.resolve(strict=True) != path.parent):
                die(f"mutation lock parent is not an exact canonical directory: {path.parent}")
            try:
                before = path.lstat()
            except FileNotFoundError:
                before = None
            if before is None:
                try:
                    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL |
                                 getattr(os, "O_NOFOLLOW", 0), 0o600)
                except FileExistsError:
                    die(f"mutation lock appeared during secure creation: {path}")
            else:
                if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode) or
                        before.st_nlink != 1 or before.st_uid != os.geteuid() or
                        stat.S_IMODE(before.st_mode) != 0o600):
                    die(f"existing mutation lock has unsafe type/owner/mode/link count: {path}")
                fd = os.open(path, os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
            st = os.fstat(fd)
            if (not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or
                    st.st_uid != os.geteuid() or stat.S_IMODE(st.st_mode) != 0o600):
                os.close(fd)
                die(f"opened mutation lock has unsafe type/owner/mode/link count: {path}")
            if before is not None and (st.st_dev, st.st_ino) != (before.st_dev, before.st_ino):
                os.close(fd)
                die(f"mutation lock identity changed while opening: {path}")
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                os.close(fd)
                die(f"mutation lock is busy: {path}")
            fds.append(fd)
            identities.append({"path": str(path), "device": st.st_dev, "inode": st.st_ino,
                               "owner_uid": st.st_uid, "mode": format(stat.S_IMODE(st.st_mode), "03o")})
        yield identities
    finally:
        for fd in reversed(fds):
            with contextlib.suppress(OSError):
                fcntl.flock(fd, fcntl.LOCK_UN)
            with contextlib.suppress(OSError):
                os.close(fd)


def same_authorized_component(audit_node_row: dict[str, Any], action: dict[str, Any], node: int) -> None:
    """Bind a fresh plan to the audit while permitting only tip-relative drift.

    Installed v30.1.4 deliberately includes the active tip in
    component_fingerprint.  A normal block therefore changes that dynamic
    fingerprint even when the recovery component itself is unchanged.  The
    authority permits a fresh-plan rebind, but only when every stable identity,
    economic, and transaction-shape field remains byte-for-byte equal.
    """
    audit_component = audit_node_row.get("component")
    fresh_component = component_identity(action)
    expected_fields = set(fresh_component)
    if not isinstance(audit_component, dict) or set(audit_component) != expected_fields:
        die(f"node{node} authority-bound component shape changed")
    require_hex64(audit_component.get("component_fingerprint"),
                  f"node{node} audit component fingerprint")
    audit_classification = audit_component.get("classification")
    fresh_classification = fresh_component.get("classification")
    allowed_classification = (
        audit_classification == "current_branch_ineligible" and
        fresh_classification == "resolution_pending" and
        action.get("status") == "reuse_managed"
    )
    if fresh_classification != audit_classification and not allowed_classification:
        die(f"node{node} component classification changed outside the exact post-sign transition")
    stable_fields = expected_fields - {"component_fingerprint", "classification"}
    if ({key: audit_component[key] for key in stable_fields} !=
            {key: fresh_component[key] for key in stable_fields}):
        die(f"node{node} stable component/fee/output changed from the authority-bound audit")


def validate_phase_a_intent_record(intent: Any, intent_sha: str, node: int,
                                   audit_sha: str, authority_sha: str,
                                   runtime: RuntimeContract, phase_a_tool: str,
                                   audit_node_row: dict[str, Any]) -> dict[str, Any]:
    """Substantively validate a durable Phase-A intent before attribution."""
    required = {
        "schema": 1, "contract": CONTRACT, "kind": "fleet31-phase-a-node-intent",
        "node": node, "action": "sign_only", "audit_sha256": audit_sha,
        "authority_sha256": authority_sha, "tool_sha256": phase_a_tool,
        "runtime_manifest_sha256": runtime.sha256,
    }
    if not isinstance(intent, dict) or any(intent.get(k) != v for k, v in required.items()):
        die(f"node{node} Phase-A intent is stale or cross-authority")
    require_hex64(intent_sha, f"node{node} Phase-A intent SHA256")
    require_hex64(intent.get("plan_id"), f"node{node} Phase-A intent plan")
    require_hex64(intent.get("active_tip"), f"node{node} Phase-A intent tip")
    require_int(intent.get("active_height"), f"node{node} Phase-A intent height", 1)
    require_int(intent.get("wallet_generation"),
                f"node{node} Phase-A intent wallet generation", 0)
    if not isinstance(intent.get("created_at"), str):
        die(f"node{node} Phase-A intent lacks a timestamp")
    audit_component = audit_node_row.get("component")
    component = intent.get("component")
    if (not isinstance(audit_component, dict) or not isinstance(component, dict) or
            set(component) != set(component_identity({}))):
        die(f"node{node} Phase-A intent component shape changed")
    if component.get("classification") not in {
            "current_branch_ineligible", "resolution_pending"}:
        die(f"node{node} Phase-A intent component classification is untyped")
    synthetic_action = dict(component)
    synthetic_action["status"] = (
        "reuse_managed" if component["classification"] == "resolution_pending" else "ready")
    same_authorized_component(audit_node_row, synthetic_action, node)
    require_hex64(component.get("generation_fingerprint"),
                  f"node{node} Phase-A intent generation fingerprint")
    require_hex64(component.get("component_fingerprint"),
                  f"node{node} Phase-A intent component fingerprint")
    exact_amount(component.get("fee"), PER_NODE_CAP,
                 f"node{node} Phase-A intent component fee")
    if (intent.get("audit_component_fingerprint") !=
            audit_component.get("component_fingerprint") or
            intent.get("fresh_component_fingerprint") !=
            component.get("component_fingerprint")):
        die(f"node{node} Phase-A intent fingerprint provenance changed")
    if intent.get("runtime") != audit_node_row.get("runtime"):
        die(f"node{node} Phase-A intent runtime differs from the audit runtime")
    runtime_transition(intent["runtime"], intent["runtime"], node,
                       "Phase-A intent")
    return intent


def same_reconciled_phase_a_component(intent_component: Any,
                                      observed_component: Any,
                                      node: int) -> None:
    """Permit only the exact ready->persisted post-sign observation transition."""
    expected_fields = set(component_identity({}))
    if (not isinstance(intent_component, dict) or
            not isinstance(observed_component, dict) or
            set(intent_component) != expected_fields or
            set(observed_component) != expected_fields):
        die(f"node{node} reconciled Phase-A component shape changed")
    if (intent_component.get("classification") != "current_branch_ineligible" or
            observed_component.get("classification") != "resolution_pending"):
        die(f"node{node} reconciled Phase-A component lacks the exact post-sign transition")
    stable = expected_fields - {"component_fingerprint", "classification"}
    if ({key: intent_component[key] for key in stable} !=
            {key: observed_component[key] for key in stable}):
        die(f"node{node} reconciled Phase-A stable component changed from its intent")
    require_hex64(observed_component.get("component_fingerprint"),
                  f"node{node} reconciled Phase-A component fingerprint")


def same_fresh_component(fresh_action: dict[str, Any], result_action: dict[str, Any], node: int) -> None:
    """Require the mutation result to bind the exact fresh plan component."""
    if component_identity(result_action) != component_identity(fresh_action):
        die(f"node{node} Phase-A result component differs from the exact fresh plan")


def phase_a_result_from_execution(node: RuntimeNode, audit_row: dict[str, Any], fresh: dict[str, Any],
                                  action: dict[str, Any], execution: dict[str, Any],
                                  transport: Transport, runtime_snapshot: dict[str, Any],
                                  intent_sha: str) -> dict[str, Any]:
    if not isinstance(execution, dict):
        die(f"node{node.node} Phase-A result is not an object")
    required = {"action": "sign_only", "acknowledged_plan_id": fresh["plan_id"],
                "acknowledged_active_tip": fresh["active_tip"],
                "acknowledged_active_height": fresh["active_height"],
                "acknowledged_wallet_generation": fresh["wallet_generation"],
                "plan_consumed": True, "plan_reusable": False, "success": True,
                "stale_plan": False, "durable_state_ambiguous": False,
                "relay_authority_granted": 0, "broadcast": 0, "already_in_mempool": 0,
                "relay_deferred": 0}
    for key, expected in required.items():
        if execution.get(key) != expected:
            die(f"node{node.node} Phase-A result {key} differs from {expected!r}")
    if not isinstance(execution.get("actions"), list) or len(execution["actions"]) != 1:
        die(f"node{node.node} Phase-A result must contain exactly one action")
    result_action = execution["actions"][0]
    if (result_action.get("status") != "signed_and_persisted" or result_action.get("persisted") is not True or
            result_action.get("relay_authorized") is not False or result_action.get("in_mempool") is not False):
        die(f"node{node.node} Phase-A did not retain one non-relayable signed draft")
    exact_amount(execution.get("acknowledged_total_fee"), PER_NODE_CAP,
                 f"node{node.node} acknowledged Phase-A total fee")
    same_fresh_component(action, result_action, node.node)
    signed = signed_transaction(transport, node, result_action)
    return {
        "schema": 1, "contract": CONTRACT, "kind": "fleet31-phase-a-node-result",
        "node": node.node, "status": "SIGNED_AND_PERSISTED", "intent_sha256": intent_sha,
        "fresh_plan": {"plan_id": fresh["plan_id"], "tip": fresh["active_tip"],
                       "height": fresh["active_height"], "wallet_generation": fresh["wallet_generation"]},
        "audit_component_fingerprint": audit_row["component"]["component_fingerprint"],
        "fresh_component_fingerprint": action["component_fingerprint"],
        "acknowledged_plan_id": execution["acknowledged_plan_id"],
        "fee_blk": result_action["fee"], "component": component_identity(result_action),
        "signed_transaction": signed, "runtime": runtime_snapshot,
        "relay_authority_granted": 0, "broadcast": 0, "mutation_performed": True,
        "durable_state_ambiguous": False, "created_at": utc_now(),
    }


def finalize_phase_a(run_dir: pathlib.Path, runtime: RuntimeContract, tool_sha: str,
                     audit_sha: str, authority_sha: str, lock_ids: list[dict[str, Any]]) -> str:
    rows: list[dict[str, Any]] = []
    for node in NODE_SET:
        row, _ = load_run_receipt(run_dir, f"phase-a-node{node:02d}.json")
        if row.get("status") not in {"SIGNED_AND_PERSISTED", "ALREADY_SIGNED_NONRELAY"}:
            die(f"node{node} lacks a conclusive non-relayable Phase-A result")
        rows.append(row)
    if sum(decimal_amount(row["fee_blk"], "Phase-A fee") for row in rows) != AGGREGATE_CAP:
        die("Phase-A total fee differs from the exact 31-node cap")
    receipt = base_receipt("fleet31-shadowpow-recovery-phase-a-complete", runtime, tool_sha)
    receipt.update({
        "result": "SIGNED_ALL_31_WITHOUT_RELAY_AUTHORITY", "audit_receipt_sha256": audit_sha,
        "phase_a_authority_sha256": authority_sha, "mutation_performed": True,
        "relay_or_broadcast_authorized": False, "lock_identities": lock_ids,
        "nodes": rows,
    })
    return publish_json(run_dir / "phase-a.json", receipt)


def phase_a_command(args: argparse.Namespace) -> None:
    require_phase_a_fixture_mode("phase-a")
    run_dir = pathlib.Path(args.run_dir)
    ensure_secure_dir(run_dir)
    runtime = load_runtime_from_run(run_dir)
    _, tool_sha = tool_identity()
    audit, audit_sha = load_run_receipt(run_dir, "audit.json")
    authority_path = pathlib.Path(args.authority)
    authority, authority_sha = parse_secure_json(authority_path, "Phase-A authority", args.authority_sha256)
    validate_phase_a_authority(authority, runtime, tool_sha, audit_sha)
    transport = Transport(runtime)
    audit_rows = {row["node"]: row for row in audit.get("nodes", [])}
    if set(audit_rows) != set(NODE_SET):
        die("audit receipt does not contain the exact node set")
    with mutation_locks(runtime) as lock_ids:
        for node in runtime.nodes:
            result_path = run_dir / f"phase-a-node{node.node:02d}.json"
            if result_path.exists():
                load_run_receipt(run_dir, result_path.name)
                continue
            intent_path = run_dir / f"phase-a-intent-node{node.node:02d}.json"
            if intent_path.exists():
                die(f"node{node.node} has an unmatched Phase-A intent; run reconcile-a, never retry blindly")
            status_hint = "ready" if audit_rows[node.node]["status"] == "ready" else "reuse_managed"
            chain, fresh, action = stable_preview(transport, node, status_hint,
                                                   {"ready", "reuse_managed"})
            same_authorized_component(audit_rows[node.node], action, node.node)
            runtime_snapshot = transport.runtime_snapshot(node)
            intent = {
                "schema": 1, "contract": CONTRACT, "kind": "fleet31-phase-a-node-intent",
                "node": node.node, "action": "sign_only", "audit_sha256": audit_sha,
                "authority_sha256": authority_sha, "tool_sha256": tool_sha,
                "runtime_manifest_sha256": runtime.sha256, "runtime": runtime_snapshot,
                "plan_id": fresh["plan_id"], "active_tip": fresh["active_tip"],
                "active_height": fresh["active_height"], "wallet_generation": fresh["wallet_generation"],
                "audit_component_fingerprint": audit_rows[node.node]["component"]["component_fingerprint"],
                "fresh_component_fingerprint": action["component_fingerprint"],
                "component": component_identity(action), "created_at": utc_now(),
            }
            intent_sha = publish_json(intent_path, intent)
            if action["status"] == "reuse_managed":
                signed = signed_transaction(transport, node, action)
                row = {
                    "schema": 1, "contract": CONTRACT, "kind": "fleet31-phase-a-node-result",
                    "node": node.node, "status": "ALREADY_SIGNED_NONRELAY", "intent_sha256": intent_sha,
                    "fresh_plan": {"plan_id": fresh["plan_id"], "tip": fresh["active_tip"],
                                   "height": fresh["active_height"], "wallet_generation": fresh["wallet_generation"]},
                    "audit_component_fingerprint": audit_rows[node.node]["component"]["component_fingerprint"],
                    "fresh_component_fingerprint": action["component_fingerprint"],
                    "fee_blk": action["fee"], "component": component_identity(action),
                    "signed_transaction": signed, "runtime": runtime_snapshot,
                    "relay_authority_granted": 0, "broadcast": 0, "mutation_performed": False,
                    "durable_state_ambiguous": False, "created_at": utc_now(),
                }
                publish_json(result_path, row)
                continue
            options = {
                "action": "sign_only", "expected_plan_id": fresh["plan_id"],
                "acknowledge_fee_and_conflict_risk": True,
                "fee_rate": str(FEE_RATE_ATOMS_PER_VB),
                "max_fee_per_resolution": f"{PER_NODE_CAP:.8f}",
                "max_total_fee": f"{PER_NODE_CAP:.8f}",
            }
            try:
                execution = transport.rpc(node, "resolveallshadowpowclaims", options)
            except RpcError:
                die(f"node{node.node} Phase-A RPC outcome is unknown after durable intent; run reconcile-a")
            if execution.get("durable_state_ambiguous") is True:
                ambiguous = {
                    "schema": 1, "contract": CONTRACT, "kind": "fleet31-phase-a-node-result",
                    "node": node.node, "status": "DURABLE_STATE_AMBIGUOUS", "intent_sha256": intent_sha,
                    "mutation_performed": "unknown", "durable_state_ambiguous": True,
                    "execution_sha256": sha256_bytes(canonical_json(execution)), "created_at": utc_now(),
                }
                publish_json(result_path, ambiguous)
                die(f"node{node.node} reported an ambiguous recovery database outcome; stop and reload before any recovery")
            row = phase_a_result_from_execution(node, audit_rows[node.node], fresh, action,
                                                 execution, transport, runtime_snapshot, intent_sha)
            publish_json(result_path, row)
        digest = finalize_phase_a(run_dir, runtime, tool_sha, audit_sha, authority_sha, lock_ids)
    print(json.dumps({"result": "SIGNED_ALL_31_WITHOUT_RELAY_AUTHORITY", "phase_a_sha256": digest}, sort_keys=True))


def reconcile_a_command(args: argparse.Namespace) -> None:
    require_phase_a_fixture_mode("reconcile-a")
    run_dir = pathlib.Path(args.run_dir)
    ensure_secure_dir(run_dir)
    runtime = load_runtime_from_run(run_dir)
    _, tool_sha = tool_identity()
    audit, audit_sha = load_run_receipt(run_dir, "audit.json")
    authority, authority_sha = parse_secure_json(pathlib.Path(args.authority), "Phase-A authority", args.authority_sha256)
    validate_phase_a_authority(authority, runtime, tool_sha, audit_sha)
    audit_rows = {row["node"]: row for row in audit["nodes"]}
    transport = Transport(runtime)
    observations: list[dict[str, Any]] = []
    all_signed = True
    with mutation_locks(runtime) as lock_ids:
        for node in runtime.nodes:
            result_path = run_dir / f"phase-a-node{node.node:02d}.json"
            if result_path.exists():
                result, _ = load_run_receipt(run_dir, result_path.name)
                observations.append({"node": node.node, "status": result.get("status")})
                all_signed &= result.get("status") in {"SIGNED_AND_PERSISTED", "ALREADY_SIGNED_NONRELAY"}
                continue
            intent_path = run_dir / f"phase-a-intent-node{node.node:02d}.json"
            if not intent_path.exists():
                all_signed = False
                observations.append({"node": node.node, "status": "NO_PHASE_A_INTENT"})
                continue
            intent, intent_sha = load_run_receipt(run_dir, f"phase-a-intent-node{node.node:02d}.json")
            validate_phase_a_intent_record(
                intent, intent_sha, node.node, audit_sha, authority_sha,
                runtime, tool_sha, audit_rows[node.node])
            for _ in range(5):
                runtime_before = transport.runtime_snapshot(node)
                if runtime_before != intent["runtime"]:
                    die(f"node{node.node} runtime differs from the unmatched Phase-A intent")
                exact_node = pinned_node(node, runtime_before)
                chain, fresh, action = stable_preview(
                    transport, exact_node, "reuse_managed", {"ready", "reuse_managed"})
                same_authorized_component(audit_rows[node.node], action, node.node)
                observed_component = component_identity(action)
                if action["status"] == "reuse_managed":
                    same_reconciled_phase_a_component(
                        intent["component"], observed_component, node.node)
                    signed = signed_transaction(transport, exact_node, action)
                    transaction = transport.rpc(
                        exact_node, "gettransaction", signed["resolution_txid"], False, True)
                    if transaction.get("qq_shadow_pow_resolution_relay_authorized") != "0":
                        die(f"node{node.node} reconciled Phase-A draft has relay authority")
                runtime_after = transport.runtime_snapshot(node)
                chain_after = validate_chain(
                    transport.rpc(exact_node, "getblockchaininfo"), node.node)
                if runtime_after != runtime_before:
                    die(f"node{node.node} runtime changed across Phase-A reconciliation")
                if chain_identity(chain) != chain_identity(chain_after):
                    continue
                break
            else:
                die(f"node{node.node} could not obtain a coherent Phase-A reconciliation cut")
            if action["status"] == "reuse_managed":
                original_intent_plan = {
                    "plan_id": intent["plan_id"], "tip": intent["active_tip"],
                    "height": intent["active_height"],
                    "wallet_generation": intent["wallet_generation"],
                }
                reconciliation_plan = {
                    "plan_id": fresh["plan_id"], "tip": fresh["active_tip"],
                    "height": fresh["active_height"],
                    "wallet_generation": fresh["wallet_generation"],
                }
                row = {
                    "schema": 1, "contract": CONTRACT, "kind": "fleet31-phase-a-node-result",
                    "node": node.node, "status": "SIGNED_AND_PERSISTED", "intent_sha256": intent_sha,
                    "reconciled_after_missing_rpc_result": True,
                    "attribution": "exact_persisted_bytes_observed_after_durable_intent",
                    "acknowledged_plan_claimed": False,
                    "original_intent_plan": original_intent_plan,
                    "reconciliation_plan": reconciliation_plan,
                    "fresh_plan": reconciliation_plan,
                    "intent_component": intent["component"],
                    "audit_component_fingerprint": audit_rows[node.node]["component"]["component_fingerprint"],
                    "fresh_component_fingerprint": action["component_fingerprint"],
                    "fee_blk": action["fee"], "component": component_identity(action),
                    "signed_transaction": signed, "runtime": runtime_before,
                    "relay_authority_granted": 0, "broadcast": 0, "mutation_performed": "unknown",
                    "durable_state_ambiguous": False, "created_at": utc_now(),
                }
                publish_json(result_path, row)
                observations.append({"node": node.node, "status": row["status"]})
            else:
                all_signed = False
                observations.append({"node": node.node, "status": "NO_MUTATION_OBSERVED"})
        reconcile = base_receipt("fleet31-shadowpow-recovery-phase-a-reconcile", runtime, tool_sha)
        reconcile.update({"audit_receipt_sha256": audit_sha, "phase_a_authority_sha256": authority_sha,
                          "result": "ALL_SIGNED" if all_signed else "PARTIAL_REQUIRES_NEW_AUDIT_AND_AUTHORITY",
                          "mutation_performed": False, "observations": observations})
        reconcile_sha = publish_json(run_dir / "phase-a-reconcile.json", reconcile)
        phase_a_sha = None
        if all_signed and not (run_dir / "phase-a.json").exists():
            phase_a_sha = finalize_phase_a(run_dir, runtime, tool_sha, audit_sha, authority_sha, lock_ids)
    print(json.dumps({"result": reconcile["result"], "reconcile_sha256": reconcile_sha,
                      "phase_a_sha256": phase_a_sha}, sort_keys=True))


def phase_b_preview_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    ensure_secure_dir(run_dir)
    runtime = load_runtime_from_run(run_dir)
    _, tool_sha = tool_identity()
    phase_a, phase_a_sha = load_run_receipt(run_dir, "phase-a.json")
    phase_a_rows = validate_phase_a_receipt_chain(
        run_dir, phase_a, phase_a_sha, runtime, tool_sha)
    transport = Transport(runtime)
    rows: list[dict[str, Any]] = []
    for node in runtime.nodes:
        cut = phase_b_envelope(transport, runtime, node,
                               phase_a_row=phase_a_rows[node.node],
                               accept_deferred=True, wait_attempts=5)
        preview = cut["preview"]
        action = cut["action"]
        evidence = cut["signed_evidence"]
        authorized_component = cut["authorized_component"]
        if action is not None:
            phase_a_signed_match(phase_a_rows[node.node], action, evidence, node.node)
        rows.append({
            "node": node.node, "runtime": cut["runtime"],
            "runtime_transition": cut["runtime_transition"], "wallet": cut["wallet"],
            "plan_id": preview["plan_id"], "active_tip": preview["active_tip"],
            "active_height": preview["active_height"], "wallet_generation": preview["wallet_generation"],
            "eligibility": cut["eligibility"],
            "component": component_identity(authorized_component), "signed_evidence": evidence,
            "operational_preflight": cut["operational_preflight"],
            "terminal_observation": cut.get("terminal_observation"),
        })
    terminal_nodes = [row["node"] for row in rows
                      if row["eligibility"] == "ALREADY_RESOLVED_ON_ACTIVE_CHAIN"]
    recovery_nodes = [node for node in NODE_SET if node not in terminal_nodes]
    maximum_recovery_fee = PER_NODE_CAP * Decimal(len(recovery_nodes))
    receipt = base_receipt("fleet31-shadowpow-recovery-phase-b-signed-byte-preview", runtime, tool_sha)
    receipt.update({
        "phase_a_receipt_sha256": phase_a_sha, "mutation_performed": False,
        "result": "READY_FOR_SEPARATE_PHASE_B_AUTHORITY", "nodes": rows,
        "wave_plan": [list(wave) for wave in WAVE_PLAN],
        "deferred_node": DEFERRED_NODE,
        "deferred_semantics": "final-wave wait only; no mutation until exact reuse_managed/resolution_pending returns",
        "terminal_node_set": terminal_nodes,
        "recovery_relay_node_set": recovery_nodes,
        "maximum_recovery_fee_blk": f"{maximum_recovery_fee:.8f}",
        "required_phase_b_authority": {
            "schema": 1, "kind": "fleet31-shadowpow-recovery-phase-b-authority",
            "decision": "authorize", "action": "commit_and_broadcast", "node_set": list(NODE_SET),
            "node30_excluded": True, "phase_a_receipt_sha256": phase_a_sha,
            "signed_byte_preview_sha256": "REPLACE_WITH_PHASE_B_PREVIEW_SHA256",
            "runtime_manifest_sha256": runtime.sha256, "tool_sha256": tool_sha,
            "source_commit": SOURCE_COMMIT, "source_tree": SOURCE_TREE,
            "per_node_fee_cap_blk": f"{PER_NODE_CAP:.8f}",
            "aggregate_fee_cap_blk": f"{AGGREGATE_CAP:.8f}",
            "user_order_text": USER_ORDER_TEXT, "user_order_sha256": USER_ORDER_SHA256,
            "wave_plan": [list(wave) for wave in WAVE_PLAN],
            "deferred_node": DEFERRED_NODE,
            "deferred_semantics": "final-wave wait only; no mutation until exact reuse_managed/resolution_pending returns",
            "terminal_node_set": terminal_nodes,
            "recovery_relay_node_set": recovery_nodes,
            "maximum_recovery_fee_blk": f"{maximum_recovery_fee:.8f}",
            "allow_fresh_plan_rebind_for_exact_signed_bytes": True,
            "acknowledgements": {
                "fee_and_conflict_risk": True,
                "independent_signed_fee_and_script_proof_reviewed": True,
                "broadcast_is_irreversible": True,
                "durable_exact_byte_relay_authority_survives_restart_or_rpc_response_loss": True,
                "confirmation_may_permanently_forfeit_revalidating_qqp2_quantum_payout": True,
                "missing_rpc_result_cannot_reconstruct_original_acknowledged_plan_on_v30_1_4": True,
                "no_generic_transaction_rpc": True,
            },
        },
    })
    digest = publish_json(run_dir / "phase-b-preview.json", receipt)
    print(json.dumps({"result": receipt["result"], "phase_b_preview_sha256": digest}, sort_keys=True))


def validate_phase_b_authority(authority: Any, runtime: RuntimeContract, tool_sha: str,
                               phase_a_sha: str, preview_sha: str,
                               preview_receipt: dict[str, Any]) -> dict[str, Any]:
    authority = validate_common_authority(authority, "fleet31-shadowpow-recovery-phase-b-authority",
                                          "commit_and_broadcast", runtime, tool_sha)
    if authority.get("phase_a_receipt_sha256") != phase_a_sha or authority.get("signed_byte_preview_sha256") != preview_sha:
        die("Phase-B authority is not bound to the exact Phase-A and signed-byte preview receipts")
    if authority.get("wave_plan") != [list(wave) for wave in WAVE_PLAN]:
        die("Phase-B authority does not bind the exact bounded wave plan")
    if (authority.get("deferred_node") != DEFERRED_NODE or
            authority.get("deferred_semantics") !=
            "final-wave wait only; no mutation until exact reuse_managed/resolution_pending returns"):
        die("Phase-B authority does not bind the exact deferred-node semantics")
    for key in ("terminal_node_set", "recovery_relay_node_set",
                "maximum_recovery_fee_blk"):
        if authority.get(key) != preview_receipt.get(key):
            die(f"Phase-B authority does not bind preview field {key}")
    if (authority.get("user_order_text") != USER_ORDER_TEXT or
            authority.get("user_order_sha256") != USER_ORDER_SHA256 or
            sha256_bytes(USER_ORDER_TEXT.encode()) != USER_ORDER_SHA256):
        die("Phase-B authority does not bind the exact user order")
    require_bool(authority.get("allow_fresh_plan_rebind_for_exact_signed_bytes"), True,
                 "Phase-B exact-byte fresh-plan acknowledgement")
    acks = authority.get("acknowledgements", {})
    for key in ["fee_and_conflict_risk", "independent_signed_fee_and_script_proof_reviewed",
                "broadcast_is_irreversible",
                "durable_exact_byte_relay_authority_survives_restart_or_rpc_response_loss",
                "confirmation_may_permanently_forfeit_revalidating_qqp2_quantum_payout",
                "missing_rpc_result_cannot_reconstruct_original_acknowledged_plan_on_v30_1_4",
                "no_generic_transaction_rpc"]:
        require_bool(acks.get(key), True, f"Phase-B acknowledgement {key}")
    return authority


def phase_b_component_match(expected: dict[str, Any], action: dict[str, Any], node: int) -> None:
    observed = component_identity(action)
    if not isinstance(expected, dict) or set(expected) != set(observed):
        die(f"node{node} Phase-B component shape differs from authority")
    stable = set(observed) - {"component_fingerprint"}
    if ({key: expected[key] for key in stable} !=
            {key: observed[key] for key in stable}):
        die(f"node{node} stable signed component differs from Phase-B authority")


def phase_b_component_dict_match(expected: dict[str, Any], observed: dict[str, Any], node: int) -> None:
    if not isinstance(observed, dict) or set(expected) != set(observed):
        die(f"node{node} acknowledged component shape differs from Phase-B authority")
    stable = set(expected) - {"component_fingerprint"}
    if ({key: expected[key] for key in stable} !=
            {key: observed[key] for key in stable}):
        die(f"node{node} acknowledged stable component differs from Phase-B authority")


def phase_a_legacy_signed_bytes_match(phase_a_row: dict[str, Any],
                                      evidence: dict[str, Any], node: int) -> None:
    expected = phase_a_row.get("signed_transaction")
    identity = evidence.get("identity", {})
    if not isinstance(expected, dict) or any([
        expected.get("resolution_txid") != identity.get("resolution_txid"),
        expected.get("raw_hex_sha256") != identity.get("raw_hex_sha256"),
        expected.get("decoded_sha256") != identity.get("decoded_sha256"),
        expected.get("output_script") != identity.get("output", {}).get("script"),
        expected.get("confirmations") != 0,
        expected.get("blockhash") is not None,
    ]):
        die(f"node{node} immutable signed bytes differ from the Phase-A completion receipt")


def phase_a_signed_match(phase_a_row: dict[str, Any], action: dict[str, Any],
                         evidence: dict[str, Any], node: int) -> None:
    same_authorized_component(phase_a_row, action, node)
    phase_a_legacy_signed_bytes_match(phase_a_row, evidence, node)


def exact_signed_match(expected: dict[str, Any], action: dict[str, Any],
                       observed: dict[str, Any], node: int,
                       require_fee_proof: bool = True) -> None:
    phase_b_component_match(expected.get("component"), action, node)
    expected_evidence = expected.get("signed_evidence", {})
    if observed.get("identity") != expected_evidence.get("identity"):
        die(f"node{node} immutable signed bytes differ from the Phase-B authority")
    if require_fee_proof and observed.get("fee_proof") != expected_evidence.get("fee_proof"):
        die(f"node{node} independent signed-fee proof differs from the Phase-B authority")


def phase_b_operational_preflight(transport: Transport, node: RuntimeNode,
                                  chain: dict[str, Any], deferred: bool) -> dict[str, Any] | None:
    network = transport.rpc(node, "getnetworkinfo")
    peers = transport.rpc(node, "getconnectioncount")
    staking = transport.rpc(node, "getstakinginfo")
    mining = transport.rpc(node, "getpowmininginfo")
    recovery = transport.rpc(node, "getpowclaimrecoveryinfo", True)
    if (not isinstance(network, dict) or network.get("version") != NETWORK_VERSION or
            network.get("subversion") != SUBVERSION):
        die(f"node{node.node} installed network identity changed before Phase B")
    if not isinstance(peers, int) or peers < 1:
        die(f"node{node.node} has no peers before Phase B")
    if (not isinstance(staking, dict) or staking.get("enabled") is not True or
            staking.get("staking") is not True or
            decimal_amount(staking.get("weight", 0), f"node{node.node} staking weight") <= 0):
        die(f"node{node.node} PoS is not coherently active before Phase B")
    expected_actionable = {0, 1} if deferred else {1}
    if (not isinstance(mining, dict) or mining.get("enabled") is not True or
            mining.get("state") != "claim_quarantined" or
            decimal_amount(mining.get("hashrate", 0), f"node{node.node} preflight hashrate") != 0 or
            mining.get("blocking_quarantined_claims") != 1 or
            mining.get("actionable_quarantined_claims") not in expected_actionable or
            mining.get("indeterminate_quarantined_claims") != 0 or
            mining.get("claim_recovery_database_outcome_ambiguous") is not False):
        die(f"node{node.node} is not the exact one-claim quarantine state before Phase B")
    if (not isinstance(recovery, dict) or recovery.get("chain_ready") is not True or
            recovery.get("wallet_tip_matches") is not True or
            recovery.get("database_outcome_ambiguous") is not False):
        die(f"node{node.node} recovery inventory is not coherent with the Phase-B chain cut")
    if (recovery.get("active_tip") != chain["bestblockhash"] or
            recovery.get("active_height") != chain["blocks"]):
        return None
    return {
        "network_version": network["version"], "subversion": network["subversion"],
        "peers": peers,
        "chain_tip": chain["bestblockhash"], "chain_height": chain["blocks"],
        "pos_enabled": True, "pos_staking": True,
        "pos_weight": staking.get("weight"),
        "pow_enabled": True, "pow_state": "claim_quarantined", "pow_hashrate": mining.get("hashrate"),
        "claims_submitted": require_int(
            mining.get("claims_submitted"), f"node{node.node} preflight claims_submitted", 0),
        "blocking_quarantined_claims": 1,
        "actionable_quarantined_claims": mining.get("actionable_quarantined_claims"),
        "database_outcome_ambiguous": False,
    }


def phase_b_terminal_operational_preflight(transport: Transport,
                                           node: RuntimeNode,
                                           chain: dict[str, Any]) -> dict[str, Any] | None:
    """Prove that an already-spent component has safely left quarantine."""
    network = transport.rpc(node, "getnetworkinfo")
    peers = transport.rpc(node, "getconnectioncount")
    staking = transport.rpc(node, "getstakinginfo")
    mining = transport.rpc(node, "getpowmininginfo")
    recovery = transport.rpc(node, "getpowclaimrecoveryinfo", True)
    if (not isinstance(network, dict) or network.get("version") != NETWORK_VERSION or
            network.get("subversion") != SUBVERSION or
            not isinstance(peers, int) or peers < 1):
        die(f"node{node.node} terminal Phase-B network/peer identity changed")
    if (not isinstance(staking, dict) or staking.get("enabled") is not True or
            staking.get("staking") is not True or
            decimal_amount(staking.get("weight", 0),
                           f"node{node.node} terminal PoS weight") <= 0):
        die(f"node{node.node} terminal Phase-B PoS is not coherent")
    if (not isinstance(mining, dict) or mining.get("enabled") is not True or
            mining.get("state") != "hashing" or
            decimal_amount(mining.get("hashrate", 0),
                           f"node{node.node} terminal hashrate") <= 0 or
            mining.get("blocking_quarantined_claims") != 0 or
            mining.get("claim_recovery_database_outcome_ambiguous") is not False):
        die(f"node{node.node} terminal component has not safely left PoW quarantine")
    if (not isinstance(recovery, dict) or recovery.get("wallet_tip_matches") is not True or
            recovery.get("database_outcome_ambiguous") is not False or
            recovery.get("blocking_quarantined_claims") != 0):
        die(f"node{node.node} terminal recovery inventory remains unsafe")
    if (recovery.get("active_tip") != chain["bestblockhash"] or
            recovery.get("active_height") != chain["blocks"]):
        return None
    return {
        "network_version": network["version"], "subversion": network["subversion"],
        "peers": peers, "chain_tip": chain["bestblockhash"],
        "chain_height": chain["blocks"], "pos_enabled": True,
        "pos_staking": True, "pos_weight": staking.get("weight"),
        "pow_enabled": True, "pow_state": "hashing",
        "pow_hashrate": mining.get("hashrate"),
        "claims_submitted": require_int(
            mining.get("claims_submitted"), f"node{node.node} terminal claims_submitted", 0),
        "blocking_quarantined_claims": 0,
        "actionable_quarantined_claims": mining.get("actionable_quarantined_claims"),
        "database_outcome_ambiguous": False,
    }


def phase_b_envelope(transport: Transport, runtime: RuntimeContract, node: RuntimeNode,
                     expected: dict[str, Any] | None = None,
                     allow_relay_authorized: bool = False,
                     phase_a_row: dict[str, Any] | None = None,
                     accept_deferred: bool = False,
                     wait_attempts: int = 1, wait_interval: int = 0) -> dict[str, Any]:
    """Obtain one coherent runtime/wallet/chain/component/signed-byte cut."""
    for wait_attempt in range(wait_attempts):
        runtime_before = transport.runtime_snapshot(node)
        authorized_runtime = (
            expected.get("runtime") if expected is not None else
            phase_a_row.get("runtime") if phase_a_row is not None else
            runtime_before)
        transition = runtime_transition(
            authorized_runtime, runtime_before, node.node, "Phase-B envelope")
        exact_node = pinned_node(node, runtime_before)
        wallet = require_normal_unlock(transport, exact_node)
        chain, preview, action = phase_b_preview_cut(
            transport, exact_node, allow_relay_authorized,
            phase_a_row.get("component") if phase_a_row else
            expected.get("component") if expected else None)
        if action is None:
            source_component = (phase_a_row["component"] if phase_a_row else expected["component"])
            phase_a_component = source_component
            deferred_action = dict(phase_a_component)
            deferred_action["classification"] = "resolution_pending"
            deferred_action["resolution_txid"] = (
                phase_a_row["signed_transaction"]["resolution_txid"] if phase_a_row else
                expected["signed_evidence"]["identity"]["resolution_txid"])
            refused = preview.get("refused", [])
            transient_live = any(
                isinstance(item, dict) and item.get("reason_code") == "claim-not-terminal"
                for item in refused)
            evidence = phase_b_signed_evidence(
                transport, exact_node, deferred_action, transient_live)
            if phase_a_row:
                phase_a_legacy_signed_bytes_match(phase_a_row, evidence, node.node)
            else:
                exact_signed_match(
                    expected, deferred_action, evidence, node.node,
                    require_fee_proof=transient_live)
            if transient_live:
                if node.node != DEFERRED_NODE:
                    die(f"node{node.node} transient live claim is not assigned to the deferred final wave")
                preflight = phase_b_operational_preflight(transport, exact_node, chain, True)
            else:
                anchor = deferred_action["anchor"]
                if transport.rpc(exact_node, "gettxout", anchor["txid"], anchor["vout"], False) is not None:
                    die(f"node{node.node} terminal preview still has an active-chain anchor UTXO")
                terminal_expected = {"component": component_identity(deferred_action),
                                     "signed_evidence": evidence}
                confirmations = evidence["observation"].get("confirmations")
                claim_winner = None
                if not (isinstance(confirmations, int) and confirmations > 0):
                    claim_winner = confirmed_authorized_claim_spender(
                        transport, exact_node, terminal_expected)
                if isinstance(confirmations, int) and confirmations > 0:
                    blockhash = require_hex64(
                        evidence["observation"].get("blockhash"),
                        f"node{node.node} terminal resolution blockhash")
                    header = transport.rpc(exact_node, "getblockheader", blockhash)
                    if (not isinstance(header, dict) or header.get("hash") != blockhash or
                            not isinstance(header.get("confirmations"), int) or
                            header["confirmations"] <= 0):
                        die(f"node{node.node} terminal resolution is not on the active chain")
                    terminal_status = "EXACT_BYTES_CONFIRMED_ON_ACTIVE_CHAIN"
                elif claim_winner is not None:
                    terminal_status = "AUTHORIZED_ORIGINAL_CLAIM_CONFIRMED_ON_ACTIVE_CHAIN"
                else:
                    die(f"node{node.node} terminal preview lacks one authorized active-chain anchor spender")
                preflight = phase_b_terminal_operational_preflight(
                    transport, exact_node, chain)
            if preflight is None:
                continue
            runtime_after = transport.runtime_snapshot(node)
            after = validate_chain(transport.rpc(exact_node, "getblockchaininfo"), node.node)
            if runtime_before != runtime_after:
                die(f"node{node.node} runtime changed across the deferred Phase-B envelope")
            if chain_identity(chain) != chain_identity(after):
                continue
            if not transient_live:
                return {"runtime": runtime_before, "node": exact_node,
                        "runtime_transition": transition, "wallet": wallet,
                        "chain": chain, "preview": preview, "action": None,
                        "authorized_component": deferred_action,
                        "signed_evidence": evidence, "operational_preflight": preflight,
                        "eligibility": "ALREADY_RESOLVED_ON_ACTIVE_CHAIN",
                        "terminal_observation": {
                            "status": terminal_status,
                            "active_chain_anchor_unspent": False,
                            "signed_identity": evidence["identity"],
                            "transaction_observation": evidence["observation"],
                            "serialized_preview_plan_id": preview.get("plan_id"),
                            "serialized_preview_tip": chain["bestblockhash"],
                            "serialized_preview_height": chain["blocks"],
                            "confirmed_authorized_claim_spender": claim_winner,
                        }}
            if accept_deferred:
                return {"runtime": runtime_before, "node": exact_node, "wallet": wallet,
                        "runtime_transition": transition,
                        "chain": chain, "preview": preview, "action": None,
                        "authorized_component": deferred_action,
                        "signed_evidence": evidence, "operational_preflight": preflight,
                        "eligibility": "DEFERRED_CLAIM_NOT_TERMINAL"}
            if wait_attempt + 1 < wait_attempts:
                time.sleep(wait_interval)
                continue
            die(f"node{node.node} exact managed resolution remains temporarily claim-not-terminal/live")
        evidence = phase_b_signed_evidence(transport, exact_node, action, True)
        preflight = phase_b_operational_preflight(transport, exact_node, chain, False)
        if preflight is None:
            continue
        runtime_after = transport.runtime_snapshot(node)
        after = validate_chain(transport.rpc(exact_node, "getblockchaininfo"), node.node)
        if runtime_before != runtime_after:
            die(f"node{node.node} runtime changed across the Phase-B envelope")
        if chain_identity(chain) != chain_identity(after):
            continue
        if (evidence["observation"].get("confirmations") != 0 or
                evidence["observation"].get("blockhash") is not None):
            die(f"node{node.node} signed resolution is not unconfirmed at the coherent Phase-B cut")
        expected_relay_metadata = "1" if action.get("relay_authorized") is True else "0"
        if evidence["observation"].get("durable_relay_authorized_metadata") != expected_relay_metadata:
            die(f"node{node.node} preview and durable relay-authority metadata differ")
        if expected is not None:
            exact_signed_match(expected, action, evidence, node.node)
        return {"runtime": runtime_before, "node": exact_node, "wallet": wallet,
                "runtime_transition": transition,
                "chain": chain, "preview": preview, "action": action,
                "authorized_component": action, "signed_evidence": evidence,
                "operational_preflight": preflight,
                "eligibility": "ACTIONABLE_REUSE_MANAGED"}
    die(f"node{node.node} could not obtain a coherent Phase-B envelope in {wait_attempts} attempts")


def validate_bound_receipt(receipt: Any, kind: str, runtime: RuntimeContract,
                           tool_sha: str, label: str) -> dict[str, Any]:
    if not isinstance(receipt, dict):
        die(f"{label} is not an object")
    expected = base_receipt(kind, runtime, tool_sha)
    expected.pop("created_at")
    for key, value in expected.items():
        if receipt.get(key) != value:
            die(f"{label} field {key} differs from the current exact contract")
    if not isinstance(receipt.get("created_at"), str):
        die(f"{label} lacks a timestamp")
    return receipt


def validate_phase_a_receipt_chain(run_dir: pathlib.Path, phase_a: Any, phase_a_sha: str,
                                   runtime: RuntimeContract,
                                   current_tool_sha: str) -> dict[int, dict[str, Any]]:
    """Validate the immutable predecessor audit/intent/result chain in full."""
    # Live Phase B consumes only the exact immutable signed predecessor.
    # Current-tool Phase-A receipts exist solely inside the sealed offline
    # hostile fixture because every live Phase-A entrypoint is hard-disabled.
    accepted_tools = {PHASE_A_TOOL_SHA256}
    if os.environ.get("FLEET31_TEST_TRANSPORT"):
        accepted_tools.add(current_tool_sha)
    if not isinstance(phase_a, dict) or phase_a.get("tool_sha256") not in accepted_tools:
        die("Phase-A completion was not produced by the exact signed Phase-A tool")
    phase_a_tool = phase_a["tool_sha256"]
    validate_bound_receipt(phase_a, "fleet31-shadowpow-recovery-phase-a-complete",
                           runtime, phase_a_tool, "Phase-A completion receipt")
    required_phase_a = {
        "result": "SIGNED_ALL_31_WITHOUT_RELAY_AUTHORITY", "mutation_performed": True,
        "relay_or_broadcast_authorized": False,
    }
    if any(phase_a.get(key) != value for key, value in required_phase_a.items()):
        die("Phase-A completion does not prove all 31 exact drafts remained non-relayable")
    audit_sha = require_hex64(phase_a.get("audit_receipt_sha256"), "Phase-A audit receipt SHA256")
    authority_sha = require_hex64(phase_a.get("phase_a_authority_sha256"),
                                  "Phase-A authority SHA256")
    audit, loaded_audit_sha = load_run_receipt(run_dir, "audit.json")
    if loaded_audit_sha != audit_sha:
        die("Phase-A completion references a different audit receipt")
    validate_bound_receipt(audit, "fleet31-shadowpow-recovery-audit", runtime,
                           phase_a_tool, "Phase-A audit receipt")
    if audit.get("result") != "READY_FOR_PHASE_A_AUTHORITY" or audit.get("mutation_performed") is not False:
        die("Phase-A audit is not the exact read-only authority baseline")
    audit_rows = {row.get("node"): row for row in audit.get("nodes", [])
                  if isinstance(row, dict) and isinstance(row.get("node"), int)}
    embedded_rows = {row.get("node"): row for row in phase_a.get("nodes", [])
                     if isinstance(row, dict) and isinstance(row.get("node"), int)}
    if (set(audit_rows) != set(NODE_SET) or set(embedded_rows) != set(NODE_SET) or
            len(audit.get("nodes", [])) != len(NODE_SET) or
            len(phase_a.get("nodes", [])) != len(NODE_SET)):
        die("Phase-A receipt chain does not contain the exact unique 31-node set")
    total = Decimal("0")
    for node in NODE_SET:
        row, row_sha = load_run_receipt(run_dir, f"phase-a-node{node:02d}.json")
        if row != embedded_rows[node]:
            die(f"node{node} embedded Phase-A row differs from its durable node receipt")
        if (row.get("schema") != 1 or row.get("contract") != CONTRACT or
                row.get("kind") != "fleet31-phase-a-node-result" or row.get("node") != node or
                row.get("status") not in {"SIGNED_AND_PERSISTED", "ALREADY_SIGNED_NONRELAY"} or
                row.get("relay_authority_granted") != 0 or row.get("broadcast") != 0 or
                row.get("durable_state_ambiguous") is not False):
            die(f"node{node} Phase-A result lacks exact durable non-relay semantics")
        require_hex64(row_sha, f"node{node} Phase-A result SHA256")
        exact_amount(row.get("fee_blk"), PER_NODE_CAP, f"node{node} Phase-A fee")
        total += decimal_amount(row["fee_blk"], f"node{node} Phase-A fee")
        intent_sha = require_hex64(row.get("intent_sha256"), f"node{node} Phase-A intent SHA256")
        intent, loaded_intent_sha = load_run_receipt(run_dir, f"phase-a-intent-node{node:02d}.json")
        if loaded_intent_sha != intent_sha:
            die(f"node{node} Phase-A result references a different durable intent")
        validate_phase_a_intent_record(
            intent, intent_sha, node, audit_sha, authority_sha,
            runtime, phase_a_tool, audit_rows[node])
        if row.get("runtime") != intent.get("runtime"):
            die(f"node{node} Phase-A result runtime differs from its intent")
        fresh = row.get("fresh_plan")
        reconciled = row.get("reconciled_after_missing_rpc_result") is True
        if reconciled:
            original = row.get("original_intent_plan")
            reconciliation = row.get("reconciliation_plan")
            expected_original = {
                "plan_id": intent["plan_id"], "tip": intent["active_tip"],
                "height": intent["active_height"],
                "wallet_generation": intent["wallet_generation"],
            }
            if (row.get("status") != "SIGNED_AND_PERSISTED" or
                    row.get("attribution") !=
                    "exact_persisted_bytes_observed_after_durable_intent" or
                    row.get("acknowledged_plan_claimed") is not False or
                    row.get("mutation_performed") != "unknown" or
                    row.get("intent_component") != intent.get("component") or
                    original != expected_original or
                    reconciliation != fresh):
                die(f"node{node} reconciled Phase-A result loses intent/observation provenance")
            if not isinstance(reconciliation, dict):
                die(f"node{node} reconciled Phase-A observation plan is absent")
            require_hex64(reconciliation.get("plan_id"),
                          f"node{node} reconciled Phase-A observation plan")
            require_hex64(reconciliation.get("tip"),
                          f"node{node} reconciled Phase-A observation tip")
            require_int(reconciliation.get("height"),
                        f"node{node} reconciled Phase-A observation height", 1)
            require_int(reconciliation.get("wallet_generation"),
                        f"node{node} reconciled Phase-A observation wallet generation", 0)
            same_reconciled_phase_a_component(
                intent["component"], row.get("component"), node)
            if any(key in row for key in (
                    "acknowledged_plan_id", "acknowledged_active_tip",
                    "acknowledged_active_height", "acknowledged_wallet_generation")):
                die(f"node{node} reconciled Phase-A result invents an RPC acknowledgement")
        else:
            if row.get("reconciled_after_missing_rpc_result") not in {None, False}:
                die(f"node{node} Phase-A reconciliation marker is untyped")
            if row.get("component") != intent.get("component"):
                die(f"node{node} Phase-A result component differs from its intent")
            if (not isinstance(fresh, dict) or fresh.get("plan_id") != intent.get("plan_id") or
                    fresh.get("tip") != intent.get("active_tip") or
                    fresh.get("height") != intent.get("active_height") or
                    fresh.get("wallet_generation") != intent.get("wallet_generation")):
                die(f"node{node} Phase-A result does not bind its exact consumed/fresh plan")
        audit_component = audit_rows[node].get("component")
        if (not isinstance(audit_component, dict) or
                row.get("audit_component_fingerprint") != audit_component.get("component_fingerprint")):
            die(f"node{node} Phase-A result does not bind the audit component")
        if row.get("fresh_component_fingerprint") != row.get("component", {}).get("component_fingerprint"):
            die(f"node{node} Phase-A result fresh component fingerprint lacks provenance")
        signed = row.get("signed_transaction")
        if (not isinstance(signed, dict) or
                signed.get("confirmations") != 0 or signed.get("blockhash") is not None or
                not isinstance(signed.get("output_script"), str) or
                not re.fullmatch(r"[0-9a-f]+", signed["output_script"])):
            die(f"node{node} Phase-A signed-transaction observation is not the exact unconfirmed draft")
        for key in ("resolution_txid", "raw_hex_sha256", "decoded_sha256"):
            require_hex64(signed.get(key), f"node{node} Phase-A signed transaction {key}")
    if total != AGGREGATE_CAP:
        die("Phase-A independently summed fee differs from the exact aggregate cap")
    require_hex64(phase_a_sha, "Phase-A completion SHA256")
    return embedded_rows


def validate_phase_b_preview_receipt(receipt: Any, runtime: RuntimeContract,
                                     tool_sha: str, phase_a_sha: str,
                                     phase_a_rows: dict[int, dict[str, Any]]) -> dict[int, dict[str, Any]]:
    validate_bound_receipt(receipt, "fleet31-shadowpow-recovery-phase-b-signed-byte-preview",
                           runtime, tool_sha, "Phase-B preview receipt")
    if (receipt.get("result") != "READY_FOR_SEPARATE_PHASE_B_AUTHORITY" or
            receipt.get("mutation_performed") is not False or
            receipt.get("phase_a_receipt_sha256") != phase_a_sha or
            receipt.get("wave_plan") != [list(wave) for wave in WAVE_PLAN] or
            receipt.get("deferred_node") != DEFERRED_NODE or
            receipt.get("deferred_semantics") !=
            "final-wave wait only; no mutation until exact reuse_managed/resolution_pending returns"):
        die("Phase-B preview does not bind the exact predecessor, node set, or wave/defer semantics")
    rows = {row.get("node"): row for row in receipt.get("nodes", [])
            if isinstance(row, dict) and isinstance(row.get("node"), int)}
    if set(rows) != set(NODE_SET) or len(receipt.get("nodes", [])) != len(NODE_SET):
        die("Phase-B preview lacks the exact unique 31-node set")
    total = Decimal("0")
    observed_terminal_nodes: list[int] = []
    for node in NODE_SET:
        row = rows[node]
        expected_transition = runtime_transition(
            phase_a_rows[node].get("runtime"), row.get("runtime"), node,
            "Phase-B preview")
        if row.get("runtime_transition") != expected_transition:
            die(f"node{node} Phase-B preview runtime transition is not exact")
        require_hex64(row.get("plan_id"), f"node{node} Phase-B preview plan_id")
        require_hex64(row.get("active_tip"), f"node{node} Phase-B preview active tip")
        require_int(row.get("active_height"), f"node{node} Phase-B preview height", 1)
        require_int(row.get("wallet_generation"), f"node{node} Phase-B preview wallet generation", 0)
        eligibility = row.get("eligibility")
        if eligibility not in {"ACTIONABLE_REUSE_MANAGED", "DEFERRED_CLAIM_NOT_TERMINAL",
                                "ALREADY_RESOLVED_ON_ACTIVE_CHAIN"}:
            die(f"node{node} Phase-B preview eligibility is untyped")
        if eligibility == "DEFERRED_CLAIM_NOT_TERMINAL" and node != DEFERRED_NODE:
            die(f"node{node} is not the authority-designated deferred node")
        component = row.get("component")
        if (not isinstance(component, dict) or component.get("classification") != "resolution_pending" or
                set(component) != set(component_identity({}))):
            die(f"node{node} Phase-B preview component shape/classification changed")
        stable = set(component) - {"component_fingerprint", "classification"}
        phase_a_component = phase_a_rows[node].get("component", {})
        if ({key: component.get(key) for key in stable} !=
                {key: phase_a_component.get(key) for key in stable}):
            die(f"node{node} Phase-B stable component differs from Phase A")
        evidence = row.get("signed_evidence")
        identity = evidence.get("identity") if isinstance(evidence, dict) else None
        fee_proof = evidence.get("fee_proof") if isinstance(evidence, dict) else None
        observation = evidence.get("observation") if isinstance(evidence, dict) else None
        if (not isinstance(identity, dict) or not isinstance(observation, dict) or
                identity.get("resolution_txid") !=
                phase_a_rows[node].get("signed_transaction", {}).get("resolution_txid")):
            die(f"node{node} Phase-B preview signed-byte identity differs from Phase A")
        for key in ("resolution_txid", "raw_hex_sha256", "decoded_sha256"):
            require_hex64(identity.get(key), f"node{node} Phase-B preview signed identity {key}")
        exact_amount(component.get("fee"), PER_NODE_CAP, f"node{node} Phase-B component fee")
        legacy = phase_a_rows[node].get("signed_transaction", {})
        if (identity.get("raw_hex_sha256") != legacy.get("raw_hex_sha256") or
                identity.get("decoded_sha256") != legacy.get("decoded_sha256") or
                identity.get("output", {}).get("script") != legacy.get("output_script")):
            die(f"node{node} Phase-B preview immutable bytes differ from Phase A")
        preflight = row.get("operational_preflight")
        common_preflight = (
            isinstance(preflight, dict) and
            preflight.get("network_version") == NETWORK_VERSION and
            preflight.get("subversion") == SUBVERSION and
            isinstance(preflight.get("peers"), int) and preflight["peers"] >= 1 and
            preflight.get("chain_tip") == row.get("active_tip") and
            preflight.get("chain_height") == row.get("active_height") and
            preflight.get("pos_enabled") is True and
            preflight.get("pos_staking") is True and
            decimal_amount(preflight.get("pos_weight", 0),
                           f"node{node} preview PoS weight") > 0 and
            preflight.get("pow_enabled") is True and
            isinstance(preflight.get("claims_submitted"), int) and
            preflight["claims_submitted"] >= 0 and
            preflight.get("database_outcome_ambiguous") is False)
        if not common_preflight:
            die(f"node{node} Phase-B preview lacks a coherent operational preflight")
        if eligibility == "ALREADY_RESOLVED_ON_ACTIVE_CHAIN":
            observed_terminal_nodes.append(node)
            terminal = row.get("terminal_observation")
            if (fee_proof is not None or preflight.get("pow_state") != "hashing" or
                    decimal_amount(preflight.get("pow_hashrate", 0),
                                   f"node{node} terminal preview hashrate") <= 0 or
                    preflight.get("blocking_quarantined_claims") != 0 or
                    not isinstance(terminal, dict) or
                    terminal.get("status") not in {
                        "EXACT_BYTES_CONFIRMED_ON_ACTIVE_CHAIN",
                        "AUTHORIZED_ORIGINAL_CLAIM_CONFIRMED_ON_ACTIVE_CHAIN"} or
                    terminal.get("active_chain_anchor_unspent") is not False or
                    terminal.get("signed_identity") != identity or
                    terminal.get("serialized_preview_plan_id") != row.get("plan_id") or
                    terminal.get("serialized_preview_tip") != row.get("active_tip") or
                    terminal.get("serialized_preview_height") != row.get("active_height")):
                die(f"node{node} already-terminal preview proof is incomplete")
            if terminal["status"] == "EXACT_BYTES_CONFIRMED_ON_ACTIVE_CHAIN":
                if (not isinstance(observation.get("confirmations"), int) or
                        observation["confirmations"] <= 0 or
                        not HEX64.fullmatch(str(observation.get("blockhash", ""))) or
                        terminal.get("confirmed_authorized_claim_spender") is not None):
                    die(f"node{node} terminal resolution confirmation proof is incoherent")
            else:
                winner = terminal.get("confirmed_authorized_claim_spender")
                if (not isinstance(winner, dict) or
                        winner.get("txid") not in component.get("claim_txids", []) or
                        not isinstance(winner.get("confirmations"), int) or
                        winner["confirmations"] <= 0 or
                        not HEX64.fullmatch(str(winner.get("blockhash", "")))):
                    die(f"node{node} terminal original-claim proof is incoherent")
        else:
            if (not isinstance(fee_proof, dict) or
                    fee_proof.get("anchor", {}).get("txid") != component.get("anchor", {}).get("txid") or
                    fee_proof.get("anchor", {}).get("vout") != component.get("anchor", {}).get("vout") or
                    observation.get("confirmations") != 0 or observation.get("blockhash") is not None or
                    observation.get("durable_relay_authorized_metadata") != "0" or
                    preflight.get("pow_state") != "claim_quarantined" or
                    decimal_amount(preflight.get("pow_hashrate", 0),
                                   f"node{node} preview PoW hashrate") != 0 or
                    preflight.get("blocking_quarantined_claims") != 1 or
                    row.get("terminal_observation") is not None):
                die(f"node{node} Phase-B preview lacks exact nonrelay signed-byte/fee evidence")
            exact_amount(fee_proof.get("computed_fee_blk"), PER_NODE_CAP,
                         f"node{node} Phase-B independently proven fee")
            total += decimal_amount(fee_proof["computed_fee_blk"],
                                    f"node{node} Phase-B proven fee")
    expected_recovery_nodes = [node for node in NODE_SET if node not in observed_terminal_nodes]
    expected_total = PER_NODE_CAP * Decimal(len(expected_recovery_nodes))
    if (receipt.get("terminal_node_set") != observed_terminal_nodes or
            receipt.get("recovery_relay_node_set") != expected_recovery_nodes or
            decimal_amount(receipt.get("maximum_recovery_fee_blk"),
                           "Phase-B maximum recovery fee") != expected_total or
            total != expected_total or total > AGGREGATE_CAP):
        die("Phase-B preview terminal set or exact remaining fee sum differs")
    return rows


def phase_b_binding_fields(phase_a_sha: str, preview_sha: str,
                           authority_sha: str, wave: int) -> dict[str, Any]:
    return {"phase_a_receipt_sha256": phase_a_sha,
            "signed_byte_preview_sha256": preview_sha,
            "phase_b_authority_sha256": authority_sha,
            "user_order_text": USER_ORDER_TEXT, "user_order_sha256": USER_ORDER_SHA256,
            "wave": wave, "wave_nodes": list(WAVE_PLAN[wave - 1])}


def phase_b_attempt_paths(run_dir: pathlib.Path, node: int,
                          attempt: int) -> tuple[pathlib.Path, pathlib.Path]:
    suffix = "" if attempt == 1 else f"-attempt{attempt:02d}"
    return (run_dir / f"phase-b-intent-node{node:02d}{suffix}.json",
            run_dir / f"phase-b-ack-node{node:02d}{suffix}.json")


def validate_phase_b_intent(intent: Any, intent_sha: str, node: int, wave: int, attempt: int,
                            runtime: RuntimeContract, tool_sha: str,
                            phase_a_sha: str, preview_sha: str, authority_sha: str,
                            expected: dict[str, Any]) -> dict[str, Any]:
    required = {
        "schema": 1, "contract": CONTRACT, "kind": "fleet31-phase-b-node-intent",
        "node": node, "attempt": attempt, "action": "commit_and_broadcast", "tool_sha256": tool_sha,
        "runtime_manifest_sha256": runtime.sha256,
        **phase_b_binding_fields(phase_a_sha, preview_sha, authority_sha, wave),
    }
    if not isinstance(intent, dict) or any(intent.get(k) != v for k, v in required.items()):
        die(f"node{node} Phase-B intent is not bound to the current exact authority chain")
    expected_transition = runtime_transition(
        expected.get("runtime"), intent.get("runtime"), node, "Phase-B intent")
    if intent.get("runtime_transition") != expected_transition:
        die(f"node{node} Phase-B intent runtime transition is not exact")
    preflight = intent.get("operational_preflight")
    if (not isinstance(preflight, dict) or preflight.get("network_version") != NETWORK_VERSION or
            preflight.get("subversion") != SUBVERSION or
            not isinstance(preflight.get("peers"), int) or preflight["peers"] < 1 or
            preflight.get("chain_tip") != intent.get("active_tip") or
            preflight.get("chain_height") != intent.get("active_height") or
            preflight.get("pos_enabled") is not True or preflight.get("pos_staking") is not True or
            decimal_amount(preflight.get("pos_weight", 0), f"node{node} intent PoS weight") <= 0 or
            preflight.get("pow_enabled") is not True or preflight.get("pow_state") != "claim_quarantined" or
            not isinstance(preflight.get("claims_submitted"), int) or
            preflight["claims_submitted"] < 0 or
            decimal_amount(preflight.get("pow_hashrate", 0), f"node{node} intent PoW hashrate") != 0 or
            preflight.get("blocking_quarantined_claims") != 1 or
            preflight.get("database_outcome_ambiguous") is not False):
        die(f"node{node} Phase-B intent lacks an exact current operational preflight")
    phase_b_component_dict_match(expected["component"], intent.get("component"), node)
    if intent.get("signed_evidence") != expected.get("signed_evidence"):
        die(f"node{node} Phase-B intent signed evidence differs from authority")
    require_hex64(intent_sha, f"node{node} Phase-B intent SHA256")
    return intent


def validate_phase_b_ack(ack: Any, ack_sha: str, node: int, wave: int, attempt: int,
                         intent: dict[str, Any], intent_sha: str,
                         runtime: RuntimeContract, tool_sha: str,
                         phase_a_sha: str, preview_sha: str, authority_sha: str,
                         expected: dict[str, Any]) -> dict[str, Any]:
    required = {
        "schema": 1, "contract": CONTRACT, "kind": "fleet31-phase-b-node-ack",
        "node": node, "attempt": attempt, "intent_sha256": intent_sha, "tool_sha256": tool_sha,
        "runtime_manifest_sha256": runtime.sha256,
        **phase_b_binding_fields(phase_a_sha, preview_sha, authority_sha, wave),
    }
    if not isinstance(ack, dict) or any(ack.get(k) != v for k, v in required.items()):
        die(f"node{node} Phase-B acknowledgement is not bound to the current exact authority chain")
    if ack.get("status") not in {
            "EXACT_PLAN_ACKNOWLEDGED_RELAY_COMPLETE",
            "EXACT_PLAN_ACKNOWLEDGED_RELAY_AUTHORIZED_PENDING",
            "NO_RELAY_AUTHORITY_PROVEN_AFTER_UNMATCHED_RPC",
            "DURABLE_STATE_AMBIGUOUS", "UNCLASSIFIED_RESPONSE_STOPPED"}:
        die(f"node{node} Phase-B acknowledgement status is unknown")
    if ack.get("status", "").startswith("EXACT_PLAN_ACKNOWLEDGED"):
        plan_binding = {
            "acknowledged_plan_id": intent.get("plan_id"),
            "acknowledged_active_tip": intent.get("active_tip"),
            "acknowledged_active_height": intent.get("active_height"),
            "acknowledged_wallet_generation": intent.get("wallet_generation"),
        }
        if any(ack.get(key) != value for key, value in plan_binding.items()):
            die(f"node{node} Phase-B acknowledgement differs from its exact intent plan")
        exact_amount(ack.get("acknowledged_total_fee"), PER_NODE_CAP,
                     f"node{node} acknowledged Phase-B fee")
        if ack.get("signed_evidence") != expected.get("signed_evidence"):
            die(f"node{node} Phase-B acknowledgement signed evidence differs from authority")
        phase_b_component_dict_match(expected["component"], ack.get("component"), node)
        if (ack.get("mutation_performed") is not True or
                ack.get("durable_state_changed") is not True or
                ack.get("durable_state_ambiguous") is not False or
                ack.get("relay_authority_granted") != 1 or
                ack.get("signed_and_persisted") != 0):
            die(f"node{node} exact acknowledgement lacks typed durable relay authority")
        for counter in ("broadcast", "already_in_mempool", "relay_deferred"):
            require_int(ack.get(counter), f"node{node} Phase-B acknowledgement {counter}", 0)
        if ack.get("status") == "EXACT_PLAN_ACKNOWLEDGED_RELAY_COMPLETE":
            if (ack.get("execution_success") is not True or
                    ack.get("execution_stale_plan") is not False or
                    ack.get("relay_complete") is not True or
                    ack.get("relay_deferred") != 0 or
                    ack.get("broadcast") + ack.get("already_in_mempool") != 1 or
                    ack.get("execution_error") not in {None, ""}):
                die(f"node{node} complete acknowledgement counters/flags are incoherent")
        else:
            if (ack.get("execution_success") is not False or
                    ack.get("relay_complete") is not False or
                    ack.get("broadcast") != 0 or ack.get("already_in_mempool") != 0 or
                    ack.get("relay_deferred") != 0 or
                    not isinstance(ack.get("execution_error"), str) or not ack["execution_error"]):
                die(f"node{node} pending acknowledgement is not an exact post-persistence stop")
    if ack.get("status") == "NO_RELAY_AUTHORITY_PROVEN_AFTER_UNMATCHED_RPC":
        if (ack.get("mutation_performed") is not False or
                ack.get("durable_state_ambiguous") is not False or
                ack.get("signed_evidence") != expected.get("signed_evidence") or
                ack.get("observation", {}).get("status") not in {
                    "NO_RELAY_AUTHORITY_OBSERVED",
                    "TRANSIENT_LIVE_CLAIM_WITHOUT_RELAY_AUTHORITY"}):
            die(f"node{node} no-authority proof is not bound to the exact signed bytes")
        phase_b_component_dict_match(expected["component"], ack.get("component"), node)
    require_hex64(ack_sha, f"node{node} Phase-B acknowledgement SHA256")
    return ack


def publish_phase_b_final(run_dir: pathlib.Path, node: int, wave: int, attempt: int,
                          intent_sha: str, ack: dict[str, Any], ack_sha: str,
                          runtime: RuntimeContract, tool_sha: str,
                          phase_a_sha: str, preview_sha: str,
                          authority_sha: str,
                          observation_name: str | None = None,
                          observation_sha: str | None = None) -> tuple[dict[str, Any], str]:
    complete_ack = ack.get("status") == "EXACT_PLAN_ACKNOWLEDGED_RELAY_COMPLETE"
    observed_completion = (ack.get("status") == "EXACT_PLAN_ACKNOWLEDGED_RELAY_AUTHORIZED_PENDING" and
                           observation_name is not None and observation_sha is not None)
    if not complete_ack and not observed_completion:
        die(f"node{node} lacks exact acknowledged relay-completion evidence")
    receipt = base_receipt("fleet31-shadowpow-recovery-phase-b-node-complete", runtime, tool_sha)
    receipt.update({
        **phase_b_binding_fields(phase_a_sha, preview_sha, authority_sha, wave),
        "node": node, "attempt": attempt, "status": "AUTHORIZED_RECOVERY_OUTCOME_COMPLETE",
        "intent_sha256": intent_sha, "ack_sha256": ack_sha,
        "acknowledged_plan_id": ack["acknowledged_plan_id"],
        "acknowledged_active_tip": ack["acknowledged_active_tip"],
        "acknowledged_active_height": ack["acknowledged_active_height"],
        "acknowledged_wallet_generation": ack["acknowledged_wallet_generation"],
        "acknowledged_total_fee": f"{PER_NODE_CAP:.8f}",
        "signed_evidence": ack["signed_evidence"], "component": ack["component"],
        "relay_authority_granted": ack["relay_authority_granted"],
        "broadcast": ack["broadcast"], "already_in_mempool": ack["already_in_mempool"],
        "mutation_performed": True, "durable_state_ambiguous": False,
        "confirmation_or_pow_success_claimed": False,
        "completion_evidence": "EXACT_RPC_ACK" if complete_ack else "ACK_PLUS_READ_ONLY_OBSERVATION",
        "observation_receipt": observation_name, "observation_sha256": observation_sha,
    })
    digest = publish_json(run_dir / f"phase-b-node{node:02d}.json", receipt)
    return receipt, digest


def publish_phase_b_observation_final(run_dir: pathlib.Path, node: int, wave: int,
                                      observed: dict[str, Any],
                                      runtime: RuntimeContract, tool_sha: str,
                                      phase_a_sha: str, preview_sha: str,
                                      authority_sha: str, expected: dict[str, Any],
                                      intent: dict[str, Any] | None = None,
                                      intent_sha: str | None = None) -> tuple[dict[str, Any], str]:
    if observed.get("status") not in {
            "EXACT_BYTES_CONFIRMED_ON_ACTIVE_CHAIN",
            "AUTHORIZED_ORIGINAL_CLAIM_CONFIRMED_ON_ACTIVE_CHAIN"}:
        die(f"node{node} observation is not an exact active-chain terminal outcome")
    if observed.get("signed_identity") != expected["signed_evidence"]["identity"]:
        die(f"node{node} terminal observation does not bind the exact authorized signed bytes")
    if (intent is None) != (intent_sha is None):
        die(f"node{node} terminal observation has an incomplete intent reference")
    observation_name = f"phase-b-observation-node{node:02d}-{time.time_ns()}.json"
    observation = base_receipt("fleet31-shadowpow-recovery-phase-b-observation", runtime, tool_sha)
    observation.update({
        **phase_b_binding_fields(phase_a_sha, preview_sha, authority_sha, wave),
        "node": node, "attempt": intent.get("attempt") if intent else None,
        "intent_sha256": intent_sha, "ack_sha256": None,
        "mutation_performed": False, **observed,
    })
    observation_sha = publish_json(run_dir / observation_name, observation)
    receipt = base_receipt("fleet31-shadowpow-recovery-phase-b-node-complete", runtime, tool_sha)
    receipt.update({
        **phase_b_binding_fields(phase_a_sha, preview_sha, authority_sha, wave),
        "node": node, "attempt": intent.get("attempt") if intent else None,
        "status": "EXACT_COMPONENT_RESOLVED_ON_ACTIVE_CHAIN_WITHOUT_RPC_ACK",
        "intent_sha256": intent_sha, "ack_sha256": None,
        "acknowledged_plan_claimed": False,
        "signed_evidence": expected["signed_evidence"], "component": expected["component"],
        "mutation_performed": False if intent is None else "unknown_after_rpc_response_loss",
        "durable_state_ambiguous": False, "confirmation_or_pow_success_claimed": False,
        "completion_evidence": "READ_ONLY_EXACT_ACTIVE_CHAIN_OBSERVATION",
        "installed_v30_1_4_ack_receipt_gap_preserved": intent is not None,
        "observation_receipt": observation_name, "observation_sha256": observation_sha,
    })
    digest = publish_json(run_dir / f"phase-b-node{node:02d}.json", receipt)
    return receipt, digest


def validate_phase_b_final(run_dir: pathlib.Path, node: int, wave: int,
                           runtime: RuntimeContract, tool_sha: str,
                           phase_a_sha: str, preview_sha: str,
                           authority_sha: str, expected: dict[str, Any]) -> tuple[dict[str, Any], str]:
    row, row_sha = load_run_receipt(run_dir, f"phase-b-node{node:02d}.json")
    validate_bound_receipt(row, "fleet31-shadowpow-recovery-phase-b-node-complete",
                           runtime, tool_sha, f"node{node} Phase-B final receipt")
    if row.get("status") == "EXACT_COMPONENT_RESOLVED_ON_ACTIVE_CHAIN_WITHOUT_RPC_ACK":
        required_external = {
            **phase_b_binding_fields(phase_a_sha, preview_sha, authority_sha, wave),
            "node": node, "ack_sha256": None, "acknowledged_plan_claimed": False,
            "signed_evidence": expected["signed_evidence"], "component": expected["component"],
            "durable_state_ambiguous": False,
            "completion_evidence": "READ_ONLY_EXACT_ACTIVE_CHAIN_OBSERVATION",
        }
        if any(row.get(key) != value for key, value in required_external.items()):
            die(f"node{node} external active-chain final receipt is stale or cross-authority")
        observation_name = row.get("observation_receipt")
        if not isinstance(observation_name, str) or "/" in observation_name:
            die(f"node{node} external active-chain observation name is invalid")
        observation, observation_sha = load_run_receipt(run_dir, observation_name)
        validate_bound_receipt(observation, "fleet31-shadowpow-recovery-phase-b-observation",
                               runtime, tool_sha, f"node{node} Phase-B external observation")
        if (row.get("observation_sha256") != observation_sha or
                observation.get("status") not in {
                    "EXACT_BYTES_CONFIRMED_ON_ACTIVE_CHAIN",
                    "AUTHORIZED_ORIGINAL_CLAIM_CONFIRMED_ON_ACTIVE_CHAIN"} or
                observation.get("node") != node or
                observation.get("signed_identity") != expected["signed_evidence"]["identity"] or
                observation.get("active_chain_anchor_unspent") is not False or
                any(observation.get(k) != v for k, v in
                    phase_b_binding_fields(phase_a_sha, preview_sha, authority_sha, wave).items())):
            die(f"node{node} external active-chain observation is not exact")
        intent_sha = row.get("intent_sha256")
        if intent_sha is None:
            if (row.get("mutation_performed") is not False or
                    row.get("installed_v30_1_4_ack_receipt_gap_preserved") is not False or
                    observation.get("intent_sha256") is not None):
                die(f"node{node} preflight external resolution receipt is incoherent")
        else:
            require_hex64(intent_sha, f"node{node} external-final intent SHA256")
            attempt = require_int(row.get("attempt"), f"node{node} external-final attempt", 1)
            intent_path, _ = phase_b_attempt_paths(run_dir, node, attempt)
            intent, loaded_intent_sha = load_run_receipt(run_dir, intent_path.name)
            if loaded_intent_sha != intent_sha:
                die(f"node{node} external-final intent reference differs")
            validate_phase_b_intent(intent, intent_sha, node, wave, attempt, runtime, tool_sha,
                                    phase_a_sha, preview_sha, authority_sha, expected)
            if (row.get("mutation_performed") != "unknown_after_rpc_response_loss" or
                    row.get("installed_v30_1_4_ack_receipt_gap_preserved") is not True or
                    observation.get("intent_sha256") != intent_sha):
                die(f"node{node} lost-response external resolution receipt is incoherent")
        return row, row_sha
    attempt = require_int(row.get("attempt"), f"node{node} Phase-B final attempt", 1)
    if attempt > MAX_PHASE_B_ATTEMPTS:
        die(f"node{node} Phase-B final attempt exceeds the bound")
    intent_path, ack_path = phase_b_attempt_paths(run_dir, node, attempt)
    intent, intent_sha = load_run_receipt(run_dir, intent_path.name)
    validate_phase_b_intent(intent, intent_sha, node, wave, attempt, runtime, tool_sha,
                            phase_a_sha, preview_sha, authority_sha, expected)
    ack, ack_sha = load_run_receipt(run_dir, ack_path.name)
    validate_phase_b_ack(ack, ack_sha, node, wave, attempt, intent, intent_sha, runtime, tool_sha,
                         phase_a_sha, preview_sha, authority_sha, expected)
    required = {**phase_b_binding_fields(phase_a_sha, preview_sha, authority_sha, wave),
                "node": node, "attempt": attempt, "status": "AUTHORIZED_RECOVERY_OUTCOME_COMPLETE",
                "intent_sha256": intent_sha, "ack_sha256": ack_sha,
                "acknowledged_plan_id": ack.get("acknowledged_plan_id"),
                "acknowledged_active_tip": ack.get("acknowledged_active_tip"),
                "acknowledged_active_height": ack.get("acknowledged_active_height"),
                "acknowledged_wallet_generation": ack.get("acknowledged_wallet_generation"),
                "acknowledged_total_fee": f"{PER_NODE_CAP:.8f}",
                "signed_evidence": expected["signed_evidence"],
                "component": ack.get("component"),
                "relay_authority_granted": ack.get("relay_authority_granted"),
                "broadcast": ack.get("broadcast"),
                "already_in_mempool": ack.get("already_in_mempool"),
                "mutation_performed": True, "durable_state_ambiguous": False}
    if any(row.get(k) != v for k, v in required.items()):
        die(f"node{node} Phase-B final receipt is stale or cross-authority")
    if ack.get("status") == "EXACT_PLAN_ACKNOWLEDGED_RELAY_AUTHORIZED_PENDING":
        observation_name = row.get("observation_receipt")
        if not isinstance(observation_name, str) or "/" in observation_name:
            die(f"node{node} observed-completion receipt name is invalid")
        observation, observation_sha = load_run_receipt(run_dir, observation_name)
        validate_bound_receipt(observation, "fleet31-shadowpow-recovery-phase-b-observation",
                               runtime, tool_sha, f"node{node} Phase-B observation")
        if (row.get("observation_sha256") != observation_sha or
                observation.get("status") not in {
                    "EXACT_BYTES_IN_MEMPOOL_WITH_DURABLE_AUTHORITY",
                    "EXACT_BYTES_CONFIRMED_ON_ACTIVE_CHAIN",
                    "AUTHORIZED_ORIGINAL_CLAIM_CONFIRMED_ON_ACTIVE_CHAIN"} or
                observation.get("intent_sha256") != intent_sha or
                observation.get("ack_sha256") != ack_sha or
                any(observation.get(k) != v for k, v in
                    phase_b_binding_fields(phase_a_sha, preview_sha, authority_sha, wave).items()) or
                observation.get("signed_identity") != expected["signed_evidence"]["identity"]):
            die(f"node{node} observed-completion receipt is not exact")
        if ((observation["status"] == "EXACT_BYTES_IN_MEMPOOL_WITH_DURABLE_AUTHORITY" and
             observation.get("active_chain_anchor_unspent") is not True) or
                (observation["status"] != "EXACT_BYTES_IN_MEMPOOL_WITH_DURABLE_AUTHORITY" and
                 observation.get("active_chain_anchor_unspent") is not False)):
            die(f"node{node} observed completion anchor state is incoherent")
    elif row.get("observation_receipt") is not None or row.get("observation_sha256") is not None:
        die(f"node{node} exact RPC completion unexpectedly references an observation")
    phase_b_component_dict_match(expected["component"], row.get("component"), node)
    exact_amount(row.get("acknowledged_total_fee"), PER_NODE_CAP,
                 f"node{node} final acknowledged fee")
    return row, row_sha


def phase_b_ack_from_execution(node: int, wave: int, attempt: int, intent_sha: str,
                               fresh: dict[str, Any], result_action: dict[str, Any] | None,
                               execution: Any, expected: dict[str, Any],
                               signed_evidence: dict[str, Any], runtime: RuntimeContract,
                               tool_sha: str, phase_a_sha: str, preview_sha: str,
                               authority_sha: str) -> dict[str, Any]:
    receipt = {
        "schema": 1, "contract": CONTRACT, "kind": "fleet31-phase-b-node-ack",
        "created_at": utc_now(), "node": node, "attempt": attempt, "intent_sha256": intent_sha,
        "tool_sha256": tool_sha, "runtime_manifest_sha256": runtime.sha256,
        **phase_b_binding_fields(phase_a_sha, preview_sha, authority_sha, wave),
        "execution_sha256": sha256_bytes(canonical_json(execution)),
    }
    if not isinstance(execution, dict):
        receipt.update({"status": "UNCLASSIFIED_RESPONSE_STOPPED",
                        "mutation_performed": "unknown", "durable_state_ambiguous": "unknown"})
        return receipt
    if execution.get("durable_state_ambiguous") is True:
        receipt.update({"status": "DURABLE_STATE_AMBIGUOUS", "mutation_performed": "unknown",
                        "durable_state_ambiguous": True})
        return receipt
    common = {
        "action": "commit_and_broadcast", "acknowledged_plan_id": fresh["plan_id"],
        "acknowledged_active_tip": fresh["active_tip"],
        "acknowledged_active_height": fresh["active_height"],
        "acknowledged_wallet_generation": fresh["wallet_generation"],
        "plan_consumed": True, "plan_reusable": False,
        "durable_state_changed": True, "durable_state_ambiguous": False,
    }
    if any(execution.get(k) != v for k, v in common.items()):
        receipt.update({"status": "UNCLASSIFIED_RESPONSE_STOPPED",
                        "mutation_performed": execution.get("durable_state_changed", "unknown"),
                        "durable_state_ambiguous": False})
        return receipt
    try:
        exact_amount(execution.get("acknowledged_total_fee"), PER_NODE_CAP,
                     f"node{node} acknowledged Phase-B total fee")
        if not isinstance(execution.get("actions"), list) or len(execution["actions"]) != 1:
            die(f"node{node} Phase-B response lacks exactly one acknowledged action")
        acknowledged_action = execution["actions"][0]
        if result_action is not acknowledged_action:
            result_action = acknowledged_action
        exact_signed_match(expected, result_action, signed_evidence, node)
        if (result_action.get("resolution_txid") !=
                signed_evidence["identity"]["resolution_txid"] or
                result_action.get("persisted") is not True or
                result_action.get("relay_authorized") is not True):
            die(f"node{node} exact acknowledged action lacks durable relay authority")
        returned_hex = result_action.get("hex")
        if (not isinstance(returned_hex, str) or len(returned_hex) % 2 or
                not re.fullmatch(r"[0-9a-f]+", returned_hex) or
                sha256_bytes(returned_hex.encode()) !=
                signed_evidence["identity"]["raw_hex_sha256"]):
            die(f"node{node} returned action bytes differ from the separately authorized signed bytes")
        if (execution.get("contains_revalidating_unbound_proof") is not True or
                not isinstance(execution.get("refused"), list) or
                any(not isinstance(item, dict) or item.get("reason_code") != "anchor-spent"
                    for item in execution["refused"])):
            die(f"node{node} acknowledged response component/refusal family changed")
    except GateError:
        receipt.update({"status": "UNCLASSIFIED_RESPONSE_STOPPED",
                        "mutation_performed": True, "durable_state_ambiguous": False})
        return receipt
    counters = {key: execution.get(key) for key in
                ["signed_and_persisted", "relay_authority_granted", "broadcast",
                 "already_in_mempool", "relay_deferred"]}
    if any(isinstance(value, bool) or not isinstance(value, int) or value < 0
           for value in counters.values()):
        receipt.update({"status": "UNCLASSIFIED_RESPONSE_STOPPED",
                        "mutation_performed": True, "durable_state_ambiguous": False})
        return receipt
    complete = (
        execution.get("success") is True and execution.get("stale_plan") is False and
        execution.get("relay_complete") is True and counters["relay_deferred"] == 0 and
        counters["signed_and_persisted"] == 0 and counters["relay_authority_granted"] == 1 and
        counters["broadcast"] + counters["already_in_mempool"] == 1 and
        result_action.get("status") in {"broadcast", "already_in_mempool"} and
        result_action.get("in_mempool") is True and execution.get("error") in {None, ""}
    )
    partial = (
        execution.get("success") is False and execution.get("relay_complete") is False and
        isinstance(execution.get("error"), str) and bool(execution["error"]) and
        counters["signed_and_persisted"] == 0 and
        counters["relay_authority_granted"] == 1 and counters["broadcast"] == 0 and
        counters["already_in_mempool"] == 0 and counters["relay_deferred"] == 0 and
        result_action.get("status") in {"reuse_managed", "signed_and_persisted"} and
        result_action.get("in_mempool") is False
    )
    status = ("EXACT_PLAN_ACKNOWLEDGED_RELAY_COMPLETE" if complete else
              "EXACT_PLAN_ACKNOWLEDGED_RELAY_AUTHORIZED_PENDING" if partial else
              "UNCLASSIFIED_RESPONSE_STOPPED")
    receipt.update({
        "status": status, "acknowledged_plan_id": fresh["plan_id"],
        "acknowledged_active_tip": fresh["active_tip"],
        "acknowledged_active_height": fresh["active_height"],
        "acknowledged_wallet_generation": fresh["wallet_generation"],
        "acknowledged_total_fee": f"{PER_NODE_CAP:.8f}",
        "component": component_identity(result_action), "signed_evidence": expected["signed_evidence"],
        **counters, "execution_success": execution.get("success"),
        "execution_stale_plan": execution.get("stale_plan"),
        "execution_error": execution.get("error"),
        "relay_complete": execution.get("relay_complete"),
        "durable_state_changed": execution.get("durable_state_changed"),
        "mutation_performed": True,
        "durable_state_ambiguous": False,
    })
    return receipt


def phase_b_observation_preview_cut(transport: Transport, node: RuntimeNode,
                                    expected_component: dict[str, Any]
                                    ) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any] | None]:
    """Serialize behind the Core recovery mutex, including terminal states."""
    for _ in range(5):
        before = validate_chain(transport.rpc(node, "getblockchaininfo"), node.node)
        preview = transport.rpc(node, "resolveallshadowpowclaims", preview_options("reuse_managed"))
        after = validate_chain(transport.rpc(node, "getblockchaininfo"), node.node)
        if chain_identity(before) != chain_identity(after):
            continue
        if not isinstance(preview, dict) or preview.get("active_tip") != after["bestblockhash"] or preview.get("active_height") != after["blocks"]:
            continue
        actions = preview.get("actions")
        if isinstance(actions, list) and len(actions) == 1:
            validated = validate_preview(preview, node.node, {"reuse_managed"},
                                         allow_relay_authorized=True)
            return after, validated, validated["actions"][0]
        if actions != []:
            die(f"node{node.node} observation preview action set is untyped")
        common = {"action": "preview", "plan_reusable": True, "complete": True,
                  "wallet_tip_matches": True, "success": True, "stale_plan": False,
                  "durable_state_changed": False, "durable_state_ambiguous": False,
                  "actionable_components": 0}
        if any(preview.get(key) != value for key, value in common.items()):
            die(f"node{node.node} terminal/nonactionable preview has unsafe semantics")
        exact_amount(preview.get("total_fee"), Decimal("0"),
                     f"node{node.node} nonactionable observation total fee")
        refused = preview.get("refused")
        if not isinstance(refused, list) or any(
                not isinstance(item, dict) or item.get("reason_code") not in {"anchor-spent", "claim-not-terminal"}
                for item in refused):
            die(f"node{node.node} nonactionable observation refusal family changed")
        live = [item for item in refused if item.get("reason_code") == "claim-not-terminal"]
        if live:
            validate_phase_b_transient(preview, node.node, after, expected_component)
        else:
            validate_phase_b_terminal_preview(
                preview, node.node, after, expected_component)
        return after, preview, None
    die(f"node{node.node} could not obtain a stable serialized observation preview")


def confirmed_authorized_claim_spender(transport: Transport, node: RuntimeNode,
                                       expected: dict[str, Any]) -> dict[str, Any] | None:
    anchor = expected["component"]["anchor"]
    confirmed: list[dict[str, Any]] = []
    for txid in expected["component"].get("claim_txids", []):
        try:
            tx = transport.rpc(node, "gettransaction", txid, False, True)
        except RpcError:
            continue
        if (not isinstance(tx, dict) or tx.get("txid") != txid or
                not isinstance(tx.get("confirmations"), int) or tx["confirmations"] <= 0):
            continue
        blockhash = require_hex64(tx.get("blockhash"), f"node{node.node} confirmed claim blockhash")
        decoded = tx.get("decoded")
        vin = decoded.get("vin") if isinstance(decoded, dict) else None
        if (not isinstance(vin, list) or
                not any(item.get("txid") == anchor["txid"] and item.get("vout") == anchor["vout"]
                        for item in vin if isinstance(item, dict))):
            continue
        header = transport.rpc(node, "getblockheader", blockhash)
        if (not isinstance(header, dict) or header.get("hash") != blockhash or
                not isinstance(header.get("confirmations"), int) or header["confirmations"] <= 0):
            continue
        confirmed.append({"txid": txid, "confirmations": tx["confirmations"],
                          "blockhash": blockhash})
    if len(confirmed) > 1:
        die(f"node{node.node} has multiple confirmed authorized claim anchor spenders")
    return confirmed[0] if confirmed else None


def phase_b_observe(transport: Transport, node: RuntimeNode,
                    expected: dict[str, Any]) -> dict[str, Any]:
    """Read exact durable/mempool/active-chain state without mutation."""
    runtime_before = transport.runtime_snapshot(node)
    transition = runtime_transition(
        expected.get("runtime"), runtime_before, node.node, "Phase-B reconciliation")
    exact_node = pinned_node(node, runtime_before)
    if transport.rpc(exact_node, "listwallets") != [node.wallet]:
        die(f"node{node.node} loaded-wallet inventory changed during reconciliation")
    wallet = transport.rpc(exact_node, "getwalletinfo")
    if not isinstance(wallet, dict) or wallet.get("walletname") != node.wallet:
        die(f"node{node.node} selected wallet changed during reconciliation")
    # The preview RPC serializes on Core's recovery-authority mutex. Read the
    # durable wallet metadata only *after* that cut so a just-returned unknown
    # mutation cannot race a stale "0" metadata read into a retry receipt.
    chain, preview, action = phase_b_observation_preview_cut(
        transport, exact_node, expected["component"])
    expected_action = dict(expected["component"])
    expected_action["resolution_txid"] = expected["signed_evidence"]["identity"]["resolution_txid"]
    evidence = phase_b_signed_evidence(transport, exact_node, expected_action, False)
    exact_signed_match(expected, expected_action, evidence, node.node, require_fee_proof=False)
    confirmations = evidence["observation"].get("confirmations")
    relay_metadata = evidence["observation"].get("durable_relay_authorized_metadata")
    anchor = expected["component"]["anchor"]
    active_anchor = transport.rpc(exact_node, "gettxout", anchor["txid"], anchor["vout"], False)
    claim_winner = None
    if active_anchor is None and not (isinstance(confirmations, int) and confirmations > 0):
        claim_winner = confirmed_authorized_claim_spender(transport, exact_node, expected)
    if isinstance(confirmations, int) and confirmations > 0:
        blockhash = require_hex64(evidence["observation"].get("blockhash"),
                                  f"node{node.node} confirmation blockhash")
        header = transport.rpc(exact_node, "getblockheader", blockhash)
        if (not isinstance(header, dict) or header.get("hash") != blockhash or
                not isinstance(header.get("confirmations"), int) or header["confirmations"] <= 0 or
                active_anchor is not None):
            die(f"node{node.node} signed resolution lacks exact active-chain confirmation proof")
        status = "EXACT_BYTES_CONFIRMED_ON_ACTIVE_CHAIN"
    elif claim_winner is not None:
        status = "AUTHORIZED_ORIGINAL_CLAIM_CONFIRMED_ON_ACTIVE_CHAIN"
    elif confirmations == 0:
        if action is not None:
            current = phase_b_signed_evidence(transport, exact_node, action, True)
            exact_signed_match(expected, action, current, node.node)
            if (action.get("relay_authorized") is True and action.get("in_mempool") is True and
                    relay_metadata == "1"):
                status = "EXACT_BYTES_IN_MEMPOOL_WITH_DURABLE_AUTHORITY"
            elif action.get("relay_authorized") is True and relay_metadata == "1":
                status = "EXACT_BYTES_DURABLY_AUTHORIZED_NOT_IN_MEMPOOL"
            elif action.get("relay_authorized") is False and action.get("in_mempool") is False and relay_metadata == "0":
                status = "NO_RELAY_AUTHORITY_OBSERVED"
            else:
                die(f"node{node.node} preview and durable relay metadata are incoherent")
        else:
            status = ("TRANSIENT_LIVE_CLAIM_WITH_DURABLE_RELAY_AUTHORITY" if relay_metadata == "1"
                      else "TRANSIENT_LIVE_CLAIM_WITHOUT_RELAY_AUTHORITY")
    elif isinstance(confirmations, int) and confirmations < 0:
        status = "EXACT_BYTES_CONFLICTED_ON_ACTIVE_CHAIN"
    else:
        die(f"node{node.node} signed transaction confirmation state is untyped")
    runtime_after = transport.runtime_snapshot(node)
    if runtime_after != runtime_before:
        die(f"node{node.node} runtime changed across Phase-B reconciliation")
    return {"status": status, "runtime": runtime_before,
            "runtime_transition": transition,
            "active_chain_anchor_unspent": active_anchor is not None,
            "signed_identity": evidence["identity"],
            "transaction_observation": evidence["observation"],
            "serialized_preview_plan_id": preview.get("plan_id"),
            "serialized_preview_tip": chain["bestblockhash"],
            "serialized_preview_height": chain["blocks"],
            "confirmed_authorized_claim_spender": claim_winner}


def finalize_phase_b(run_dir: pathlib.Path, runtime: RuntimeContract, tool_sha: str,
                     phase_a_sha: str, preview_sha: str, authority_sha: str,
                     lock_ids: list[dict[str, Any]],
                     expected_rows: dict[int, dict[str, Any]]) -> str:
    rows: list[dict[str, Any]] = []
    mutation_states: list[Any] = []
    for node in NODE_SET:
        wave = next(index for index, members in enumerate(WAVE_PLAN, 1) if node in members)
        row, row_sha = validate_phase_b_final(
            run_dir, node, wave, runtime, tool_sha, phase_a_sha, preview_sha,
            authority_sha, expected_rows[node])
        rows.append({"node": node, "receipt_sha256": row_sha,
                     "resolution_txid": row["signed_evidence"]["identity"]["resolution_txid"],
                     "outcome": row["status"]})
        mutation_states.append(row.get("mutation_performed"))
    aggregate_mutation: Any = (
        True if any(value is True for value in mutation_states) else
        False if all(value is False for value in mutation_states) else
        "unknown_after_rpc_response_loss")
    receipt = base_receipt("fleet31-shadowpow-recovery-phase-b-complete", runtime, tool_sha)
    receipt.update({
        "result": "AUTHORIZED_RECOVERY_COMPLETE_ALL_31", "phase_a_receipt_sha256": phase_a_sha,
        "signed_byte_preview_sha256": preview_sha, "phase_b_authority_sha256": authority_sha,
        "mutation_performed": aggregate_mutation,
        "lock_identities": lock_ids, "node_results": rows,
        "wave_plan": [list(wave) for wave in WAVE_PLAN],
        "confirmation_or_pow_success_claimed": False,
    })
    return publish_json(run_dir / "phase-b.json", receipt)


def validate_phase_b_complete(run_dir: pathlib.Path, runtime: RuntimeContract, tool_sha: str,
                              phase_a_sha: str, preview_sha: str, authority_sha: str,
                              expected_rows: dict[int, dict[str, Any]]) -> tuple[dict[str, Any], str]:
    receipt, digest = load_run_receipt(run_dir, "phase-b.json")
    validate_bound_receipt(receipt, "fleet31-shadowpow-recovery-phase-b-complete",
                           runtime, tool_sha, "Phase-B aggregate completion receipt")
    required = {
        "result": "AUTHORIZED_RECOVERY_COMPLETE_ALL_31",
        "phase_a_receipt_sha256": phase_a_sha,
        "signed_byte_preview_sha256": preview_sha,
        "phase_b_authority_sha256": authority_sha,
        "wave_plan": [list(wave) for wave in WAVE_PLAN],
        "confirmation_or_pow_success_claimed": False,
    }
    if any(receipt.get(key) != value for key, value in required.items()):
        die("Phase-B aggregate completion is stale or cross-authority")
    expected_results: list[dict[str, Any]] = []
    for node in NODE_SET:
        wave = next(index for index, members in enumerate(WAVE_PLAN, 1) if node in members)
        row, row_sha = validate_phase_b_final(
            run_dir, node, wave, runtime, tool_sha, phase_a_sha, preview_sha,
            authority_sha, expected_rows[node])
        expected_results.append({"node": node, "receipt_sha256": row_sha,
                                 "resolution_txid": row["signed_evidence"]["identity"]["resolution_txid"],
                                 "outcome": row["status"]})
    if receipt.get("node_results") != expected_results:
        die("Phase-B aggregate completion node-result binding differs")
    locks = receipt.get("lock_identities")
    if not isinstance(locks, list) or len(locks) != len(runtime.lock_paths) + len(NODE_SET):
        die("Phase-B aggregate completion lacks the exact lock identity count")
    return receipt, digest


def validate_phase_b_wave(run_dir: pathlib.Path, wave: int,
                          runtime: RuntimeContract, tool_sha: str,
                          phase_a_sha: str, preview_sha: str, authority_sha: str,
                          expected_rows: dict[int, dict[str, Any]]) -> tuple[dict[str, Any], str]:
    receipt, digest = load_run_receipt(run_dir, f"phase-b-wave-{wave:02d}.json")
    validate_bound_receipt(receipt, "fleet31-shadowpow-recovery-phase-b-wave",
                           runtime, tool_sha, f"Phase-B wave {wave} receipt")
    required = {"status": "AUTHORIZED_RECOVERY_WAVE_COMPLETE", "wave": wave,
                "nodes": list(WAVE_PLAN[wave - 1]),
                "phase_a_receipt_sha256": phase_a_sha,
                "signed_byte_preview_sha256": preview_sha,
                "phase_b_authority_sha256": authority_sha}
    if any(receipt.get(k) != v for k, v in required.items()):
        die(f"Phase-B wave {wave} receipt is stale or cross-authority")
    expected_results = []
    for node in WAVE_PLAN[wave - 1]:
        row, row_sha = validate_phase_b_final(
            run_dir, node, wave, runtime, tool_sha, phase_a_sha, preview_sha,
            authority_sha, expected_rows[node])
        expected_results.append({"node": node, "receipt_sha256": row_sha,
                                 "resolution_txid": row["signed_evidence"]["identity"]["resolution_txid"],
                                 "outcome": row["status"]})
    if receipt.get("node_results") != expected_results:
        die(f"Phase-B wave {wave} node-result binding differs")
    return receipt, digest


def phase_b_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    ensure_secure_dir(run_dir)
    runtime = load_runtime_from_run(run_dir)
    _, tool_sha = tool_identity()
    phase_a, phase_a_sha = load_run_receipt(run_dir, "phase-a.json")
    phase_a_rows = validate_phase_a_receipt_chain(
        run_dir, phase_a, phase_a_sha, runtime, tool_sha)
    preview_receipt, preview_sha = load_run_receipt(run_dir, "phase-b-preview.json")
    expected_rows = validate_phase_b_preview_receipt(
        preview_receipt, runtime, tool_sha, phase_a_sha, phase_a_rows)
    authority, authority_sha = parse_secure_json(pathlib.Path(args.authority), "Phase-B authority", args.authority_sha256)
    validate_phase_b_authority(
        authority, runtime, tool_sha, phase_a_sha, preview_sha, preview_receipt)
    wave_number = require_int(args.wave, "Phase-B wave", 1)
    if wave_number > len(WAVE_PLAN):
        die(f"Phase-B wave must be 1 through {len(WAVE_PLAN)}")
    wait_attempts = require_int(args.wait_attempts, "Phase-B deferred wait attempts", 1)
    wait_interval = require_int(args.wait_interval, "Phase-B deferred wait interval", 0)
    if wait_attempts > 60 or wait_interval > 60:
        die("Phase-B deferred wait bounds exceed 60 attempts/seconds")
    args.wait_attempts = wait_attempts
    args.wait_interval = wait_interval
    current_wave_path = run_dir / f"phase-b-wave-{wave_number:02d}.json"
    if current_wave_path.exists():
        _, wave_sha = validate_phase_b_wave(run_dir, wave_number, runtime, tool_sha,
                                            phase_a_sha, preview_sha, authority_sha, expected_rows)
        final_sha = None
        if wave_number == len(WAVE_PLAN):
            if (run_dir / "phase-b.json").exists():
                _, final_sha = validate_phase_b_complete(
                    run_dir, runtime, tool_sha, phase_a_sha, preview_sha, authority_sha,
                    expected_rows)
            else:
                with mutation_locks(runtime) as lock_ids:
                    # Crash-safe terminal resumption: wave 10 is already exact,
                    # so rebuild only the read-only aggregate receipt.
                    final_sha = finalize_phase_b(
                        run_dir, runtime, tool_sha, phase_a_sha, preview_sha,
                        authority_sha, lock_ids, expected_rows)
        print(json.dumps({"result": f"WAVE_{wave_number}_ALREADY_COMPLETE",
                          "wave_sha256": wave_sha, "phase_b_sha256": final_sha}, sort_keys=True))
        return
    for prior_wave in range(1, wave_number):
        validate_phase_b_wave(run_dir, prior_wave, runtime, tool_sha,
                              phase_a_sha, preview_sha, authority_sha, expected_rows)
    for future_wave in range(wave_number + 1, len(WAVE_PLAN) + 1):
        if (run_dir / f"phase-b-wave-{future_wave:02d}.json").exists():
            die(f"Phase-B future wave {future_wave} exists out of order")
    transport = Transport(runtime)
    with mutation_locks(runtime) as lock_ids:
        wave = WAVE_PLAN[wave_number - 1]
        for node_id in wave:
            node = next(item for item in runtime.nodes if item.node == node_id)
            result_path = run_dir / f"phase-b-node{node.node:02d}.json"
            if result_path.exists():
                validate_phase_b_final(run_dir, node.node, wave_number, runtime, tool_sha,
                                       phase_a_sha, preview_sha, authority_sha,
                                       expected_rows[node.node])
                continue
            selected_attempt = None
            intent_path = ack_path = None
            for attempt in range(1, MAX_PHASE_B_ATTEMPTS + 1):
                candidate_intent, candidate_ack = phase_b_attempt_paths(run_dir, node.node, attempt)
                if candidate_ack.exists() and not candidate_intent.exists():
                    die(f"node{node.node} attempt {attempt} has an acknowledgement without its intent")
                if not candidate_intent.exists():
                    if candidate_ack.exists():
                        die(f"node{node.node} attempt {attempt} acknowledgement is orphaned")
                    selected_attempt, intent_path, ack_path = attempt, candidate_intent, candidate_ack
                    break
                intent, intent_sha = load_run_receipt(run_dir, candidate_intent.name)
                validate_phase_b_intent(intent, intent_sha, node.node, wave_number, attempt,
                                        runtime, tool_sha, phase_a_sha, preview_sha,
                                        authority_sha, expected_rows[node.node])
                if not candidate_ack.exists():
                    die(f"node{node.node} attempt {attempt} has an unmatched Phase-B intent; run reconcile-b")
                ack, ack_sha = load_run_receipt(run_dir, candidate_ack.name)
                validate_phase_b_ack(ack, ack_sha, node.node, wave_number, attempt, intent, intent_sha,
                                     runtime, tool_sha, phase_a_sha, preview_sha,
                                     authority_sha, expected_rows[node.node])
                if ack.get("status") == "EXACT_PLAN_ACKNOWLEDGED_RELAY_COMPLETE":
                    publish_phase_b_final(run_dir, node.node, wave_number, attempt, intent_sha,
                                          ack, ack_sha, runtime, tool_sha, phase_a_sha,
                                          preview_sha, authority_sha)
                    selected_attempt = None
                    break
                if ack.get("status") == "NO_RELAY_AUTHORITY_PROVEN_AFTER_UNMATCHED_RPC":
                    continue
                if ack.get("status") == "EXACT_PLAN_ACKNOWLEDGED_RELAY_AUTHORIZED_PENDING":
                    die(f"node{node.node} has exact durable relay authority pending; never remutate; run reconcile-b")
                die(f"node{node.node} has a nonretryable Phase-B acknowledgement status {ack.get('status')}")
            if result_path.exists():
                validate_phase_b_final(run_dir, node.node, wave_number, runtime, tool_sha,
                                       phase_a_sha, preview_sha, authority_sha,
                                       expected_rows[node.node])
                continue
            if selected_attempt is None or intent_path is None or ack_path is None:
                die(f"node{node.node} exhausted {MAX_PHASE_B_ATTEMPTS} bounded Phase-B attempts")
            pre_observed = phase_b_observe(transport, node, expected_rows[node.node])
            expected_terminal = (
                expected_rows[node.node].get("eligibility") ==
                "ALREADY_RESOLVED_ON_ACTIVE_CHAIN")
            if pre_observed["status"] in {
                    "EXACT_BYTES_CONFIRMED_ON_ACTIVE_CHAIN",
                    "AUTHORIZED_ORIGINAL_CLAIM_CONFIRMED_ON_ACTIVE_CHAIN"}:
                publish_phase_b_observation_final(
                    run_dir, node.node, wave_number, pre_observed, runtime, tool_sha,
                    phase_a_sha, preview_sha, authority_sha, expected_rows[node.node])
                continue
            if expected_terminal:
                die(f"node{node.node} authority-bound terminal state reorged; require a new preview and authority")
            if pre_observed["status"] not in {
                    "NO_RELAY_AUTHORITY_OBSERVED",
                    "TRANSIENT_LIVE_CLAIM_WITHOUT_RELAY_AUTHORITY"}:
                die(f"node{node.node} already has unattributable durable relay state; never remutate; run reconcile-b")
            cut = phase_b_envelope(
                transport, runtime, node, expected_rows[node.node],
                phase_a_row=None, accept_deferred=False,
                wait_attempts=args.wait_attempts if node.node == DEFERRED_NODE else 5,
                wait_interval=args.wait_interval if node.node == DEFERRED_NODE else 0)
            runtime_before = cut["runtime"]
            exact_node = cut["node"]
            wallet = cut["wallet"]
            fresh = cut["preview"]
            action = cut["action"]
            observed_signed = cut["signed_evidence"]
            if cut["eligibility"] == "ALREADY_RESOLVED_ON_ACTIVE_CHAIN":
                publish_phase_b_observation_final(
                    run_dir, node.node, wave_number, cut["terminal_observation"],
                    runtime, tool_sha, phase_a_sha, preview_sha, authority_sha,
                    expected_rows[node.node])
                continue
            intent = {
                "schema": 1, "contract": CONTRACT, "kind": "fleet31-phase-b-node-intent",
                "node": node.node, "attempt": selected_attempt, "action": "commit_and_broadcast",
                **phase_b_binding_fields(phase_a_sha, preview_sha, authority_sha, wave_number),
                "tool_sha256": tool_sha,
                "runtime_manifest_sha256": runtime.sha256, "runtime": runtime_before,
                "runtime_transition": cut["runtime_transition"],
                "wallet": wallet,
                "plan_id": fresh["plan_id"], "active_tip": fresh["active_tip"],
                "active_height": fresh["active_height"], "wallet_generation": fresh["wallet_generation"],
                "component": component_identity(action), "signed_evidence": observed_signed,
                "operational_preflight": cut["operational_preflight"],
                "created_at": utc_now(),
            }
            intent_sha = publish_json(intent_path, intent)
            options = {
                "action": "commit_and_broadcast", "expected_plan_id": fresh["plan_id"],
                "acknowledge_fee_and_conflict_risk": True,
                "max_fee_per_resolution": f"{PER_NODE_CAP:.8f}",
                "max_total_fee": f"{PER_NODE_CAP:.8f}",
            }
            try:
                execution = transport.rpc(exact_node, "resolveallshadowpowclaims", options)
            except RpcError:
                die(f"node{node.node} Phase-B outcome is indeterminate after durable intent; never retry; run reconcile-b")
            result_action = (execution.get("actions", [None])[0]
                             if isinstance(execution, dict) and
                             isinstance(execution.get("actions"), list) and execution["actions"] else None)
            ack = phase_b_ack_from_execution(
                node.node, wave_number, selected_attempt, intent_sha, fresh, result_action, execution,
                expected_rows[node.node], observed_signed, runtime, tool_sha,
                phase_a_sha, preview_sha, authority_sha)
            ack_sha = publish_json(ack_path, ack)
            if ack["status"] == "EXACT_PLAN_ACKNOWLEDGED_RELAY_COMPLETE":
                publish_phase_b_final(run_dir, node.node, wave_number, selected_attempt, intent_sha,
                                      ack, ack_sha, runtime, tool_sha, phase_a_sha,
                                      preview_sha, authority_sha)
                continue
            if ack["status"] == "EXACT_PLAN_ACKNOWLEDGED_RELAY_AUTHORIZED_PENDING":
                die(f"node{node.node} durably authorized exact bytes but relay paused on drift; never remutate; run reconcile-b")
            if ack["status"] == "DURABLE_STATE_AMBIGUOUS":
                die(f"node{node.node} recovery database outcome is ambiguous; stop every recovery action")
            die(f"node{node.node} returned an unclassified nonretryable Phase-B response")
        wave_rows = []
        wave_mutation_states: list[Any] = []
        for node_id in wave:
            node_row, node_sha = validate_phase_b_final(
                run_dir, node_id, wave_number, runtime, tool_sha, phase_a_sha,
                preview_sha, authority_sha, expected_rows[node_id])
            wave_rows.append({"node": node_id, "receipt_sha256": node_sha,
                              "resolution_txid": node_row["signed_evidence"]["identity"]["resolution_txid"],
                              "outcome": node_row["status"]})
            wave_mutation_states.append(node_row.get("mutation_performed"))
        wave_mutation: Any = (True if any(value is True for value in wave_mutation_states) else
                              False if all(value is False for value in wave_mutation_states) else
                              "unknown_after_rpc_response_loss")
        wave_receipt = base_receipt("fleet31-shadowpow-recovery-phase-b-wave", runtime, tool_sha)
        wave_receipt.update({
            "status": "AUTHORIZED_RECOVERY_WAVE_COMPLETE", "wave": wave_number,
            "nodes": list(wave), "node_results": wave_rows,
            "phase_a_receipt_sha256": phase_a_sha,
            "signed_byte_preview_sha256": preview_sha,
            "phase_b_authority_sha256": authority_sha,
            "mutation_performed": wave_mutation, "confirmation_or_pow_success_claimed": False,
        })
        wave_sha = publish_json(run_dir / f"phase-b-wave-{wave_number:02d}.json", wave_receipt)
        final_sha = None
        if wave_number == len(WAVE_PLAN):
            final_sha = finalize_phase_b(run_dir, runtime, tool_sha, phase_a_sha, preview_sha,
                                         authority_sha, lock_ids, expected_rows)
    print(json.dumps({"result": f"WAVE_{wave_number}_COMPLETE", "wave_sha256": wave_sha,
                      "phase_b_sha256": final_sha}, sort_keys=True))


def reconcile_b_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    ensure_secure_dir(run_dir)
    runtime = load_runtime_from_run(run_dir)
    _, tool_sha = tool_identity()
    phase_a, phase_a_sha = load_run_receipt(run_dir, "phase-a.json")
    phase_a_rows = validate_phase_a_receipt_chain(
        run_dir, phase_a, phase_a_sha, runtime, tool_sha)
    preview_receipt, preview_sha = load_run_receipt(run_dir, "phase-b-preview.json")
    expected_rows = validate_phase_b_preview_receipt(
        preview_receipt, runtime, tool_sha, phase_a_sha, phase_a_rows)
    authority, authority_sha = parse_secure_json(pathlib.Path(args.authority), "Phase-B authority", args.authority_sha256)
    validate_phase_b_authority(
        authority, runtime, tool_sha, phase_a_sha, preview_sha, preview_receipt)
    transport = Transport(runtime)
    observations: list[dict[str, Any]] = []
    with mutation_locks(runtime):
        for node in runtime.nodes:
            wave = next(index for index, members in enumerate(WAVE_PLAN, 1) if node.node in members)
            result_path = run_dir / f"phase-b-node{node.node:02d}.json"
            if result_path.exists():
                result, _ = validate_phase_b_final(
                    run_dir, node.node, wave, runtime, tool_sha, phase_a_sha,
                    preview_sha, authority_sha, expected_rows[node.node])
                observations.append({"node": node.node, "status": result.get("status")})
                continue
            if (expected_rows[node.node].get("eligibility") ==
                    "ALREADY_RESOLVED_ON_ACTIVE_CHAIN"):
                observed = phase_b_observe(transport, node, expected_rows[node.node])
                if observed["status"] not in {
                        "EXACT_BYTES_CONFIRMED_ON_ACTIVE_CHAIN",
                        "AUTHORIZED_ORIGINAL_CLAIM_CONFIRMED_ON_ACTIVE_CHAIN"}:
                    die(f"node{node.node} authority-bound terminal state reorged; require a new preview and authority")
                publish_phase_b_observation_final(
                    run_dir, node.node, wave, observed, runtime, tool_sha,
                    phase_a_sha, preview_sha, authority_sha, expected_rows[node.node])
                observations.append({"node": node.node,
                                     "status": "FINALIZED_PREVIEW_TERMINAL_OBSERVATION"})
                continue
            found_intent = False
            for attempt in range(1, MAX_PHASE_B_ATTEMPTS + 1):
                intent_path, ack_path = phase_b_attempt_paths(run_dir, node.node, attempt)
                if not intent_path.exists():
                    break
                found_intent = True
                intent, intent_sha = load_run_receipt(run_dir, intent_path.name)
                validate_phase_b_intent(intent, intent_sha, node.node, wave, attempt,
                                        runtime, tool_sha, phase_a_sha, preview_sha,
                                        authority_sha, expected_rows[node.node])
                if ack_path.exists():
                    ack, ack_sha = load_run_receipt(run_dir, ack_path.name)
                    validate_phase_b_ack(ack, ack_sha, node.node, wave, attempt, intent, intent_sha,
                                         runtime, tool_sha, phase_a_sha, preview_sha,
                                         authority_sha, expected_rows[node.node])
                    if ack["status"] == "EXACT_PLAN_ACKNOWLEDGED_RELAY_COMPLETE":
                        publish_phase_b_final(run_dir, node.node, wave, attempt, intent_sha,
                                              ack, ack_sha, runtime, tool_sha, phase_a_sha,
                                              preview_sha, authority_sha)
                        observations.append({"node": node.node, "attempt": attempt,
                                             "status": "FINAL_REBUILT_FROM_EXACT_ACK"})
                        break
                    if ack["status"] == "NO_RELAY_AUTHORITY_PROVEN_AFTER_UNMATCHED_RPC":
                        continue
                    observed = phase_b_observe(transport, node, expected_rows[node.node])
                    if ack["status"] == "EXACT_PLAN_ACKNOWLEDGED_RELAY_AUTHORIZED_PENDING":
                        if observed["status"] in {
                                "EXACT_BYTES_IN_MEMPOOL_WITH_DURABLE_AUTHORITY",
                                "EXACT_BYTES_CONFIRMED_ON_ACTIVE_CHAIN",
                                "AUTHORIZED_ORIGINAL_CLAIM_CONFIRMED_ON_ACTIVE_CHAIN"}:
                            observation_name = f"phase-b-observation-node{node.node:02d}-attempt{attempt:02d}-{time.time_ns()}.json"
                            observation = base_receipt(
                                "fleet31-shadowpow-recovery-phase-b-observation", runtime, tool_sha)
                            observation.update({
                                **phase_b_binding_fields(phase_a_sha, preview_sha, authority_sha, wave),
                                "node": node.node, "attempt": attempt, "intent_sha256": intent_sha,
                                "ack_sha256": ack_sha, "mutation_performed": False, **observed,
                            })
                            observation_sha = publish_json(run_dir / observation_name, observation)
                            publish_phase_b_final(
                                run_dir, node.node, wave, attempt, intent_sha, ack, ack_sha,
                                runtime, tool_sha, phase_a_sha, preview_sha, authority_sha,
                                observation_name, observation_sha)
                        observations.append({"node": node.node, "attempt": attempt, **observed})
                        break
                    if observed["status"] in {
                            "EXACT_BYTES_CONFIRMED_ON_ACTIVE_CHAIN",
                            "AUTHORIZED_ORIGINAL_CLAIM_CONFIRMED_ON_ACTIVE_CHAIN"}:
                        observed = {**observed,
                                    "non_authoritative_ack_sha256": ack_sha,
                                    "non_authoritative_ack_status": ack["status"]}
                        publish_phase_b_observation_final(
                            run_dir, node.node, wave, observed, runtime, tool_sha,
                            phase_a_sha, preview_sha, authority_sha,
                            expected_rows[node.node], intent, intent_sha)
                        observations.append({"node": node.node, "attempt": attempt,
                                             "status": "FINALIZED_FROM_EXACT_ACTIVE_CHAIN_OBSERVATION",
                                             "non_authoritative_ack_status": ack["status"]})
                        break
                    observations.append({"node": node.node, "attempt": attempt,
                                         "status": ack["status"],
                                         "observation": observed})
                    break
                observed = phase_b_observe(transport, node, expected_rows[node.node])
                if observed["status"] in {
                        "EXACT_BYTES_CONFIRMED_ON_ACTIVE_CHAIN",
                        "AUTHORIZED_ORIGINAL_CLAIM_CONFIRMED_ON_ACTIVE_CHAIN"}:
                    publish_phase_b_observation_final(
                        run_dir, node.node, wave, observed, runtime, tool_sha,
                        phase_a_sha, preview_sha, authority_sha, expected_rows[node.node],
                        intent, intent_sha)
                    observations.append({"node": node.node, "attempt": attempt,
                                         "status": "FINALIZED_FROM_EXACT_ACTIVE_CHAIN_OBSERVATION"})
                    break
                if observed["status"] in {"NO_RELAY_AUTHORITY_OBSERVED",
                                           "TRANSIENT_LIVE_CLAIM_WITHOUT_RELAY_AUTHORITY"}:
                    no_authority = {
                        "schema": 1, "contract": CONTRACT, "kind": "fleet31-phase-b-node-ack",
                        "created_at": utc_now(), "node": node.node, "attempt": attempt,
                        "intent_sha256": intent_sha, "tool_sha256": tool_sha,
                        "runtime_manifest_sha256": runtime.sha256,
                        **phase_b_binding_fields(phase_a_sha, preview_sha, authority_sha, wave),
                        "status": "NO_RELAY_AUTHORITY_PROVEN_AFTER_UNMATCHED_RPC",
                        "mutation_performed": False, "durable_state_ambiguous": False,
                        "signed_evidence": expected_rows[node.node]["signed_evidence"],
                        "component": expected_rows[node.node]["component"],
                        "observation": observed,
                    }
                    ack_sha = publish_json(ack_path, no_authority)
                    observations.append({"node": node.node, "attempt": attempt,
                                         "status": no_authority["status"], "ack_sha256": ack_sha})
                    continue
                observations.append({"node": node.node, "attempt": attempt,
                                     "status": "UNATTRIBUTABLE_ACKNOWLEDGEMENT_BUT_NEVER_RETRY",
                                     "observation": observed})
                break
            if not found_intent:
                observations.append({"node": node.node, "status": "NO_PHASE_B_INTENT"})
        receipt = base_receipt("fleet31-shadowpow-recovery-phase-b-reconcile", runtime, tool_sha)
        receipt.update({
            "phase_a_receipt_sha256": phase_a_sha, "signed_byte_preview_sha256": preview_sha,
            "phase_b_authority_sha256": authority_sha, "mutation_performed": False,
            "result": "RECONCILED_WITHOUT_NEW_MUTATION",
            "installed_v30_1_4_blocker": "durable metadata does not retain the consumed acknowledged plan/tip/wallet-generation receipt",
            "never_retry_after_observed_relay_authority": True, "observations": observations,
        })
        reconcile_name = f"phase-b-reconcile-{time.time_ns()}.json"
        digest = publish_json(run_dir / reconcile_name, receipt)
    print(json.dumps({"result": receipt["result"], "receipt": reconcile_name,
                      "reconcile_sha256": digest}, sort_keys=True))


def phase_b_receipt_tool_for_monitor(phase_b_receipt: Any,
                                     current_tool_sha: str) -> tuple[str, dict[str, Any]]:
    """Select one exact receipt producer for the read-only monitor only."""
    if not isinstance(phase_b_receipt, dict):
        die("Phase-B aggregate completion is not an object")
    receipt_tool_sha = require_hex64(
        phase_b_receipt.get("tool_sha256"), "Phase-B aggregate receipt tool SHA256")
    if receipt_tool_sha == current_tool_sha:
        return receipt_tool_sha, {
            "mode": "current_exact_monitor_tool",
            "tool_sha256": current_tool_sha,
        }
    if receipt_tool_sha != PHASE_B_EXECUTOR_TOOL_SHA256:
        die("Phase-B aggregate completion was not produced by the current tool or the exact signed Phase-B executor")
    evidence = dict(PHASE_B_EXECUTOR_EVIDENCE)
    if (evidence.get("tool_sha256") != receipt_tool_sha or
            evidence.get("signer_fingerprint") != SOURCE_SIGNER or
            evidence.get("independent_p0_p1_review") != "CLEAN" or
            evidence.get("hostile_assertions") != 120):
        die("exact Phase-B executor product-test evidence is internally inconsistent")
    for key in ("tool_sha256", "product_test_receipt_sha256", "hostile_test_sha256",
                "hostile_log_sha256"):
        require_hex64(evidence.get(key), f"Phase-B executor evidence {key}")
    for key in ("commit", "tree", "parent", "tool_git_blob",
                "product_test_receipt_git_blob"):
        value = evidence.get(key)
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value):
            die(f"Phase-B executor evidence {key} is not a Git object identity")
    evidence["mode"] = "exact_signed_tested_predecessor"
    return receipt_tool_sha, evidence


def monitor_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    ensure_secure_dir(run_dir)
    runtime = load_runtime_from_run(run_dir)
    _, tool_sha = tool_identity()
    phase_a, phase_a_sha = load_run_receipt(run_dir, "phase-a.json")
    phase_a_rows = validate_phase_a_receipt_chain(
        run_dir, phase_a, phase_a_sha, runtime, tool_sha)
    audit, audit_sha = load_run_receipt(run_dir, "audit.json")
    phase_b_receipt, _ = load_run_receipt(run_dir, "phase-b.json")
    receipt_tool_sha, executor_evidence = phase_b_receipt_tool_for_monitor(
        phase_b_receipt, tool_sha)
    preview_receipt, preview_sha = load_run_receipt(run_dir, "phase-b-preview.json")
    expected_rows = validate_phase_b_preview_receipt(
        preview_receipt, runtime, receipt_tool_sha, phase_a_sha, phase_a_rows)
    authority_sha = require_hex64(phase_b_receipt.get("phase_b_authority_sha256"),
                                  "Phase-B monitor authority SHA256")
    _, phase_b_sha = validate_phase_b_complete(
        run_dir, runtime, receipt_tool_sha, phase_a_sha, preview_sha, authority_sha,
        expected_rows)
    for wave in range(1, len(WAVE_PLAN) + 1):
        validate_phase_b_wave(
            run_dir, wave, runtime, receipt_tool_sha, phase_a_sha, preview_sha,
            authority_sha, expected_rows)
    transport = Transport(runtime)
    samples = require_int(args.samples, "samples", 1)
    interval = require_int(args.interval, "interval", 0)
    latest: list[dict[str, Any]] = []
    for sample in range(samples):
        latest = []
        all_nodes_service_ready = True
        for node in runtime.nodes:
            for _ in range(5):
                runtime_before = transport.runtime_snapshot(node)
                transition = runtime_transition(
                    expected_rows[node.node].get("runtime"), runtime_before,
                    node.node, "operational monitor")
                exact_node = pinned_node(node, runtime_before)
                if transport.rpc(exact_node, "listwallets") != [node.wallet]:
                    die(f"node{node.node} wallet inventory changed during monitoring")
                network = transport.rpc(exact_node, "getnetworkinfo")
                peers = transport.rpc(exact_node, "getconnectioncount")
                chain = validate_chain(transport.rpc(exact_node, "getblockchaininfo"), node.node)
                mining = transport.rpc(exact_node, "getpowmininginfo")
                recovery = transport.rpc(exact_node, "getpowclaimrecoveryinfo", True)
                component = expected_rows[node.node]["component"]
                anchor = component["anchor"]
                confirmed: list[dict[str, Any]] = []
                candidate_txids = [*component.get("claim_txids", []),
                                   expected_rows[node.node]["signed_evidence"]["identity"]["resolution_txid"]]
                for txid in candidate_txids:
                    try:
                        tx = transport.rpc(exact_node, "gettransaction", txid, False, True)
                    except RpcError:
                        continue
                    if (not isinstance(tx, dict) or tx.get("txid") != txid or
                            not isinstance(tx.get("confirmations"), int) or tx["confirmations"] <= 0):
                        continue
                    blockhash = require_hex64(tx.get("blockhash"),
                                              f"node{node.node} monitor confirmation blockhash")
                    decoded = tx.get("decoded")
                    vin = decoded.get("vin") if isinstance(decoded, dict) else None
                    if (not isinstance(vin, list) or
                            not any(item.get("txid") == anchor["txid"] and item.get("vout") == anchor["vout"]
                                    for item in vin if isinstance(item, dict))):
                        die(f"node{node.node} confirmed candidate does not spend the exact authorized anchor")
                    header = transport.rpc(exact_node, "getblockheader", blockhash)
                    if (not isinstance(header, dict) or header.get("hash") != blockhash or
                            not isinstance(header.get("confirmations"), int) or header["confirmations"] <= 0):
                        die(f"node{node.node} candidate confirmation is not on the active chain")
                    confirmed.append({
                        "txid": txid, "confirmations": tx["confirmations"], "blockhash": blockhash,
                        "kind": "resolution" if txid == candidate_txids[-1] else "authorized_original_claim",
                    })
                anchor_utxo = transport.rpc(exact_node, "gettxout", anchor["txid"], anchor["vout"], False)
                runtime_after = transport.runtime_snapshot(node)
                chain_after = validate_chain(transport.rpc(exact_node, "getblockchaininfo"), node.node)
                if runtime_after != runtime_before:
                    die(f"node{node.node} runtime changed across the operational monitor cut")
                if chain_identity(chain) != chain_identity(chain_after):
                    continue
                break
            else:
                die(f"node{node.node} could not produce a stable operational monitor cut")
            if (not isinstance(network, dict) or network.get("version") != NETWORK_VERSION or
                    network.get("subversion") != SUBVERSION or not isinstance(peers, int) or peers < 1):
                die(f"node{node.node} network/peer identity changed during monitoring")
            if (not isinstance(recovery, dict) or recovery.get("active_tip") != chain["bestblockhash"] or
                    recovery.get("active_height") != chain["blocks"] or
                    recovery.get("wallet_tip_matches") is not True or
                    recovery.get("database_outcome_ambiguous") is not False):
                die(f"node{node.node} recovery inventory is incoherent during monitoring")
            if len(confirmed) != 1:
                die(f"node{node.node} lacks exactly one confirmed authorized anchor spender")
            anchor_spent_on_active_chain = anchor_utxo is None
            preview_claims = require_int(
                expected_rows[node.node]["operational_preflight"].get("claims_submitted"),
                f"node{node.node} Phase-B preview claims_submitted", 0)
            if not isinstance(mining, dict):
                die(f"node{node.node} PoW mining status is not an object")
            current_claims = require_int(
                mining.get("claims_submitted"),
                f"node{node.node} current claims_submitted", 0)
            restarted_since_preview = transition["ephemeral_container_changed"]
            claims_baseline = 0 if restarted_since_preview else preview_claims
            claims_evidence = (
                "positive_counter_since_restarted_process_epoch" if restarted_since_preview else
                "increment_from_phase_b_preview_in_same_process_epoch")
            if not restarted_since_preview and current_claims < claims_baseline:
                die(f"node{node.node} claims_submitted regressed in the same process epoch")
            fresh_claim_delta = max(0, current_claims - claims_baseline)
            pow_hot_blockers = require_int(
                mining.get("blocking_quarantined_claims"),
                f"node{node.node} PoW hot blocking quarantines", 0)
            pow_hot_indeterminate = require_int(
                mining.get("indeterminate_quarantined_claims"),
                f"node{node.node} PoW hot indeterminate quarantines", 0)
            recovery_inventory_blockers = require_int(
                recovery.get("blocking_quarantined_claims"),
                f"node{node.node} historical recovery inventory blockers", 0)
            operational = (
                anchor_spent_on_active_chain and isinstance(recovery, dict) and
                recovery.get("database_outcome_ambiguous") is False and
                isinstance(mining, dict) and mining.get("enabled") is True and
                mining.get("state") in {"ready", "claim_in_flight"} and
                decimal_amount(mining.get("hashrate", 0), "monitor hashrate") > 0 and
                pow_hot_blockers == 0 and
                pow_hot_indeterminate == 0 and
                mining.get("claim_recovery_database_outcome_ambiguous") is False
            )
            all_nodes_service_ready &= operational
            latest.append({
                "node": node.node, "height": chain["blocks"], "tip": chain["bestblockhash"],
                "anchor_spent_on_active_chain": anchor_spent_on_active_chain,
                "confirmed_component_transactions": confirmed,
                "runtime": runtime_before, "runtime_transition": transition,
                "network_version": network["version"], "peers": peers,
                "pow_hot_blocking_quarantined_claims": pow_hot_blockers,
                "pow_hot_indeterminate_quarantined_claims": pow_hot_indeterminate,
                "recovery_inventory_blocking_quarantined_claims": recovery_inventory_blockers,
                "pow_enabled": mining.get("enabled") if isinstance(mining, dict) else None,
                "pow_state": mining.get("state") if isinstance(mining, dict) else None,
                "hashrate": mining.get("hashrate") if isinstance(mining, dict) else None,
                "claims_submitted": current_claims,
                "claims_baseline": claims_baseline,
                "claims_baseline_source": claims_evidence,
                "fresh_claims_submitted": fresh_claim_delta,
                "fresh_claim_observed": fresh_claim_delta > 0,
                "phase_b_preview_claims_submitted": preview_claims,
                "operational": operational,
            })
        fleet_fresh_claims = sum(row["fresh_claims_submitted"] for row in latest)
        complete = all_nodes_service_ready and fleet_fresh_claims > 0
        if complete or sample + 1 == samples:
            break
        time.sleep(interval)
    receipt = base_receipt("fleet31-shadowpow-recovery-operational-monitor", runtime, tool_sha)
    operational_count = sum(1 for row in latest if row["operational"])
    fleet_fresh_claims = sum(row["fresh_claims_submitted"] for row in latest)
    fresh_claim_nodes = [row["node"] for row in latest if row["fresh_claim_observed"]]
    complete = operational_count == len(NODE_SET) and fleet_fresh_claims > 0
    receipt.update({
        "audit_receipt_sha256": audit_sha, "phase_a_receipt_sha256": phase_a_sha,
        "phase_b_receipt_sha256": phase_b_sha, "mutation_performed": False,
        "validated_phase_b_receipt_tool_sha256": receipt_tool_sha,
        "phase_b_executor_product_test_evidence": executor_evidence,
        "result": "ALL_31_POW_OPERATIONAL" if complete else "NOT_YET_OPERATIONAL",
        "operational_nodes": operational_count, "required_nodes": len(NODE_SET), "nodes": latest,
        "fleet_fresh_claims_submitted": fleet_fresh_claims,
        "nodes_with_fresh_claims": fresh_claim_nodes,
        "requires_active_chain_anchor_spend": True, "requires_positive_hashrate": True,
        "requires_zero_pow_hot_blockers": True,
        "recovery_inventory_blocker_count_is_informational": True,
        "requires_fleet_fresh_claim_submission": True,
        "requires_per_node_claim_submission_increment": False,
    })
    name = f"monitor-{int(time.time())}.json"
    digest = publish_json(run_dir / name, receipt)
    print(json.dumps({"result": receipt["result"], "operational_nodes": operational_count,
                      "receipt": name, "sha256": digest}, sort_keys=True))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    audit = sub.add_parser("audit", help="read-only stable preview of all 31 regular-PoW wallets")
    audit.add_argument("--runtime-manifest", required=True)
    audit.add_argument("--run-dir", required=True)
    audit.set_defaults(func=audit_command)
    for name, func, label in [
        ("phase-a", phase_a_command, "Phase-A"),
        ("reconcile-a", reconcile_a_command, "Phase-A"),
        ("phase-b", phase_b_command, "Phase-B"),
        ("reconcile-b", reconcile_b_command, "Phase-B"),
    ]:
        item = sub.add_parser(name)
        item.add_argument("--run-dir", required=True)
        item.add_argument("--authority", required=True)
        item.add_argument("--authority-sha256", required=True)
        if name == "phase-b":
            item.add_argument("--wave", type=int, required=True)
            item.add_argument("--wait-attempts", type=int, default=12)
            item.add_argument("--wait-interval", type=int, default=5)
        item.set_defaults(func=func)
    phase_b_preview = sub.add_parser("phase-b-preview", help="read-only exact signed-byte preview")
    phase_b_preview.add_argument("--run-dir", required=True)
    phase_b_preview.set_defaults(func=phase_b_preview_command)
    monitor = sub.add_parser("monitor", help="read-only active-chain/hashrate/claim-success monitor")
    monitor.add_argument("--run-dir", required=True)
    monitor.add_argument("--samples", type=int, default=1)
    monitor.add_argument("--interval", type=int, default=5)
    monitor.set_defaults(func=monitor_command)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    os.umask(0o077)
    for name in ["PYTHONPATH", "PYTHONHOME", "BASH_ENV", "ENV", "CDPATH"]:
        os.environ.pop(name, None)
    args = build_parser().parse_args(argv)
    try:
        args.func(args)
    except (GateError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
