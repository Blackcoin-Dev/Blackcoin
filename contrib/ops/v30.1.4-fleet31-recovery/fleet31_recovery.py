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
PER_NODE_CAP = Decimal("0.00019100")
AGGREGATE_CAP = Decimal("0.00592100")
FEE_RATE_ATOMS_PER_VB = Decimal("100")
FEE_RATE_ATOMS_PER_K = 100000
EXPECTED_VSIZE = 191
HEX64 = re.compile(r"^[0-9a-f]{64}$")
PRODUCTION_DOCKER = pathlib.Path("/usr/bin/docker")
# Filled from the repository fixture after the fixture is finalized.
TEST_TRANSPORT_SHA256 = "de0180917c9c436d68b7c7f85c4276ad6564c95c30ca444395b7b05d21a9bf56"


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


def owned_secure_file(path: pathlib.Path, label: str, expected_hash: str | None = None) -> bytes:
    if not path.is_absolute():
        die(f"{label} path must be absolute")
    try:
        st = path.lstat()
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


def publish_bytes(path: pathlib.Path, data: bytes, mode: int = 0o600) -> str:
    """Durably publish without clobbering an existing path."""
    if not path.is_absolute() or path.parent.resolve(strict=True) != path.parent:
        die(f"output path is not absolute/canonical: {path}")
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
    try:
        os.link(tmp, path)
        fsync_dir(path.parent)
    except FileExistsError:
        die(f"refusing to clobber existing receipt: {path}")
    finally:
        with contextlib.suppress(FileNotFoundError):
            tmp.unlink()
        fsync_dir(path.parent)
    digest = sha256_bytes(data)
    sidecar = path.with_name(path.name + ".sha256")
    sidecar_data = f"{digest}  {path.name}\n".encode()
    tmp_sidecar = path.parent / f".{sidecar.name}.tmp.{os.getpid()}.{time.time_ns()}"
    fd = os.open(tmp_sidecar, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), mode)
    try:
        os.write(fd, sidecar_data)
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        os.link(tmp_sidecar, sidecar)
        fsync_dir(path.parent)
    except FileExistsError:
        die(f"refusing to clobber existing receipt sidecar: {sidecar}")
    finally:
        with contextlib.suppress(FileNotFoundError):
            tmp_sidecar.unlink()
        fsync_dir(path.parent)
    return digest


def publish_json(path: pathlib.Path, value: Any) -> str:
    return publish_bytes(path, canonical_json(value))


def load_run_receipt(run_dir: pathlib.Path, name: str) -> tuple[Any, str]:
    path = run_dir / name
    sidecar = path.with_name(path.name + ".sha256")
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
                    f"-datadir={self.runtime.datadir}", f"-rpcwallet={node.wallet}", method]
        for param in params:
            if isinstance(param, (dict, list)):
                cli_args.append(json.dumps(param, sort_keys=True, separators=(",", ":")))
            elif isinstance(param, bool):
                cli_args.append("true" if param else "false")
            else:
                cli_args.append(str(param))
        try:
            output = self.run(cli_args)
            return json.loads(output)
        except (GateError, json.JSONDecodeError) as exc:
            raise RpcError(node.node, method, str(exc)) from exc

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


def validate_preview(preview: Any, node: int, allowed_status: set[str]) -> dict[str, Any]:
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
    if (action.get("classification") != "current_branch_ineligible" or
            action.get("conflicts_with_revalidating_unbound_proof") is not True or
            action.get("reason_code") != "unbound-proof-may-revalidate" or
            action.get("frontier_may_advance") is not True or
            action.get("in_mempool") is not False):
        die(f"node{node} component is not the exact current-branch-ineligible QQP2 risk family")
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
        if action.get("persisted") is not True or action.get("relay_authorized") is not False:
            die(f"node{node} signed draft is absent or already has relay authority")
        require_hex64(action.get("resolution_txid"), f"node{node} resolution txid")
    return preview


def signed_transaction(transport: Transport, node: RuntimeNode, action: dict[str, Any]) -> dict[str, Any]:
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
    return {
        "resolution_txid": txid, "raw_hex_sha256": sha256_bytes(raw.encode()),
        "decoded_sha256": sha256_bytes(canonical_json(decoded)),
        "output_script": vout[0].get("scriptPubKey", {}).get("hex"),
        "confirmations": tx.get("confirmations", 0), "blockhash": tx.get("blockhash"),
    }


def stable_preview(transport: Transport, node: RuntimeNode, status_hint: str,
                   allowed_status: set[str], attempts: int = 3) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    for _ in range(attempts):
        before = validate_chain(transport.rpc(node, "getblockchaininfo"), node.node)
        preview = transport.rpc(node, "resolveallshadowpowclaims", preview_options(status_hint))
        after = validate_chain(transport.rpc(node, "getblockchaininfo"), node.node)
        if chain_identity(before) != chain_identity(after):
            continue
        preview = validate_preview(preview, node.node, allowed_status)
        if preview["active_tip"] != after["bestblockhash"] or preview["active_height"] != after["blocks"]:
            continue
        return after, preview, preview["actions"][0]
    die(f"node{node.node} could not produce a stable exact recovery preview in {attempts} attempts")


def audit_node(transport: Transport, runtime: RuntimeContract, node: RuntimeNode) -> dict[str, Any]:
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
    if runtime_before != runtime_after or chain_identity(chain) != chain_identity(after):
        die(f"node{node.node} runtime or chain changed across the audit cut")
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
    return path, sha256_file(path)


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
            path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            fd = os.open(path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
            os.fchmod(fd, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                die(f"mutation lock is busy: {path}")
            st = os.fstat(fd)
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


def same_component(audit_node_row: dict[str, Any], action: dict[str, Any], node: int) -> None:
    if component_identity(action) != audit_node_row.get("component"):
        die(f"node{node} component/fee/output changed from the authority-bound audit")


def phase_a_result_from_execution(node: RuntimeNode, audit_row: dict[str, Any], fresh: dict[str, Any],
                                  action: dict[str, Any], execution: dict[str, Any],
                                  transport: Transport, runtime_snapshot: dict[str, Any],
                                  intent_sha: str) -> dict[str, Any]:
    if not isinstance(execution, dict):
        die(f"node{node.node} Phase-A result is not an object")
    required = {"action": "sign_only", "acknowledged_plan_id": fresh["plan_id"],
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
    same_component(audit_row, result_action, node.node)
    signed = signed_transaction(transport, node, result_action)
    return {
        "schema": 1, "contract": CONTRACT, "kind": "fleet31-phase-a-node-result",
        "node": node.node, "status": "SIGNED_AND_PERSISTED", "intent_sha256": intent_sha,
        "fresh_plan": {"plan_id": fresh["plan_id"], "tip": fresh["active_tip"],
                       "height": fresh["active_height"], "wallet_generation": fresh["wallet_generation"]},
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
            same_component(audit_rows[node.node], action, node.node)
            runtime_snapshot = transport.runtime_snapshot(node)
            intent = {
                "schema": 1, "contract": CONTRACT, "kind": "fleet31-phase-a-node-intent",
                "node": node.node, "action": "sign_only", "audit_sha256": audit_sha,
                "authority_sha256": authority_sha, "tool_sha256": tool_sha,
                "runtime_manifest_sha256": runtime.sha256, "runtime": runtime_snapshot,
                "plan_id": fresh["plan_id"], "active_tip": fresh["active_tip"],
                "active_height": fresh["active_height"], "wallet_generation": fresh["wallet_generation"],
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
            chain, fresh, action = stable_preview(transport, node, "reuse_managed",
                                                   {"ready", "reuse_managed"})
            same_component(audit_rows[node.node], action, node.node)
            if action["status"] == "reuse_managed":
                signed = signed_transaction(transport, node, action)
                row = {
                    "schema": 1, "contract": CONTRACT, "kind": "fleet31-phase-a-node-result",
                    "node": node.node, "status": "SIGNED_AND_PERSISTED", "intent_sha256": intent_sha,
                    "reconciled_after_missing_rpc_result": True,
                    "attribution": "exact_persisted_bytes_observed_after_durable_intent",
                    "fresh_plan": {"plan_id": fresh["plan_id"], "tip": fresh["active_tip"],
                                   "height": fresh["active_height"], "wallet_generation": fresh["wallet_generation"]},
                    "fee_blk": action["fee"], "component": component_identity(action),
                    "signed_transaction": signed, "runtime": transport.runtime_snapshot(node),
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
    transport = Transport(runtime)
    rows: list[dict[str, Any]] = []
    for node in runtime.nodes:
        chain, preview, action = stable_preview(transport, node, "reuse_managed", {"reuse_managed"})
        signed = signed_transaction(transport, node, action)
        if signed["confirmations"] != 0:
            die(f"node{node.node} signed resolution is no longer unconfirmed; use monitor/re-audit")
        rows.append({
            "node": node.node, "runtime": transport.runtime_snapshot(node),
            "plan_id": preview["plan_id"], "active_tip": preview["active_tip"],
            "active_height": preview["active_height"], "wallet_generation": preview["wallet_generation"],
            "component": component_identity(action), "signed_transaction": signed,
        })
    receipt = base_receipt("fleet31-shadowpow-recovery-phase-b-signed-byte-preview", runtime, tool_sha)
    receipt.update({
        "phase_a_receipt_sha256": phase_a_sha, "mutation_performed": False,
        "result": "READY_FOR_SEPARATE_PHASE_B_AUTHORITY", "nodes": rows,
        "required_phase_b_authority": {
            "schema": 1, "kind": "fleet31-shadowpow-recovery-phase-b-authority",
            "decision": "authorize", "action": "commit_and_broadcast", "node_set": list(NODE_SET),
            "node30_excluded": True, "phase_a_receipt_sha256": phase_a_sha,
            "signed_byte_preview_sha256": "REPLACE_WITH_PHASE_B_PREVIEW_SHA256",
            "runtime_manifest_sha256": runtime.sha256, "tool_sha256": tool_sha,
            "source_commit": SOURCE_COMMIT, "source_tree": SOURCE_TREE,
            "per_node_fee_cap_blk": f"{PER_NODE_CAP:.8f}",
            "aggregate_fee_cap_blk": f"{AGGREGATE_CAP:.8f}",
            "allow_fresh_plan_rebind_for_exact_signed_bytes": True,
            "acknowledgements": {
                "fee_and_conflict_risk": True,
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
                               phase_a_sha: str, preview_sha: str) -> dict[str, Any]:
    authority = validate_common_authority(authority, "fleet31-shadowpow-recovery-phase-b-authority",
                                          "commit_and_broadcast", runtime, tool_sha)
    if authority.get("phase_a_receipt_sha256") != phase_a_sha or authority.get("signed_byte_preview_sha256") != preview_sha:
        die("Phase-B authority is not bound to the exact Phase-A and signed-byte preview receipts")
    require_bool(authority.get("allow_fresh_plan_rebind_for_exact_signed_bytes"), True,
                 "Phase-B exact-byte fresh-plan acknowledgement")
    acks = authority.get("acknowledgements", {})
    for key in ["fee_and_conflict_risk", "broadcast_is_irreversible",
                "durable_exact_byte_relay_authority_survives_restart_or_rpc_response_loss",
                "confirmation_may_permanently_forfeit_revalidating_qqp2_quantum_payout",
                "missing_rpc_result_cannot_reconstruct_original_acknowledged_plan_on_v30_1_4",
                "no_generic_transaction_rpc"]:
        require_bool(acks.get(key), True, f"Phase-B acknowledgement {key}")
    return authority


def exact_signed_match(expected: dict[str, Any], action: dict[str, Any], observed: dict[str, Any], node: int) -> None:
    if component_identity(action) != expected.get("component") or observed != expected.get("signed_transaction"):
        die(f"node{node} signed bytes/component differ from the separately authorized Phase-B preview")


def finalize_phase_b(run_dir: pathlib.Path, runtime: RuntimeContract, tool_sha: str,
                     phase_a_sha: str, preview_sha: str, authority_sha: str,
                     lock_ids: list[dict[str, Any]]) -> str:
    rows: list[dict[str, Any]] = []
    for node in NODE_SET:
        row, _ = load_run_receipt(run_dir, f"phase-b-node{node:02d}.json")
        if row.get("status") != "EXACT_PLAN_ACKNOWLEDGED_AND_RELAYED":
            die(f"node{node} lacks a conclusive exact-plan Phase-B result")
        rows.append(row)
    receipt = base_receipt("fleet31-shadowpow-recovery-phase-b-complete", runtime, tool_sha)
    receipt.update({
        "result": "EXACT_PLAN_ACKNOWLEDGED_FOR_ALL_31", "phase_a_receipt_sha256": phase_a_sha,
        "signed_byte_preview_sha256": preview_sha, "phase_b_authority_sha256": authority_sha,
        "mutation_performed": True, "lock_identities": lock_ids, "nodes": rows,
        "confirmation_or_pow_success_claimed": False,
    })
    return publish_json(run_dir / "phase-b.json", receipt)


def phase_b_command(args: argparse.Namespace) -> None:
    die("Phase B is hard-disabled in this Phase-A-only stage; no receipt was parsed, no lock was acquired, and no transport or RPC was contacted")
    # The reviewed successor implementation remains below as inert source for
    # the separately signed Phase-B stage.  The unconditional fail-closed gate
    # above is tested as a before-transport boundary.
    run_dir = pathlib.Path(args.run_dir)
    ensure_secure_dir(run_dir)
    runtime = load_runtime_from_run(run_dir)
    _, tool_sha = tool_identity()
    phase_a, phase_a_sha = load_run_receipt(run_dir, "phase-a.json")
    preview_receipt, preview_sha = load_run_receipt(run_dir, "phase-b-preview.json")
    expected_rows = {row["node"]: row for row in preview_receipt["nodes"]}
    authority, authority_sha = parse_secure_json(pathlib.Path(args.authority), "Phase-B authority", args.authority_sha256)
    validate_phase_b_authority(authority, runtime, tool_sha, phase_a_sha, preview_sha)
    transport = Transport(runtime)
    with mutation_locks(runtime) as lock_ids:
        for node in runtime.nodes:
            result_path = run_dir / f"phase-b-node{node.node:02d}.json"
            if result_path.exists():
                load_run_receipt(run_dir, result_path.name)
                continue
            intent_path = run_dir / f"phase-b-intent-node{node.node:02d}.json"
            if intent_path.exists():
                die(f"node{node.node} has an unmatched Phase-B intent; run reconcile-b and never retry")
            chain, fresh, action = stable_preview(transport, node, "reuse_managed", {"reuse_managed"})
            observed_signed = signed_transaction(transport, node, action)
            exact_signed_match(expected_rows[node.node], action, observed_signed, node.node)
            runtime_snapshot = transport.runtime_snapshot(node)
            intent = {
                "schema": 1, "contract": CONTRACT, "kind": "fleet31-phase-b-node-intent",
                "node": node.node, "action": "commit_and_broadcast",
                "phase_a_sha256": phase_a_sha, "signed_byte_preview_sha256": preview_sha,
                "authority_sha256": authority_sha, "tool_sha256": tool_sha,
                "runtime_manifest_sha256": runtime.sha256, "runtime": runtime_snapshot,
                "plan_id": fresh["plan_id"], "active_tip": fresh["active_tip"],
                "active_height": fresh["active_height"], "wallet_generation": fresh["wallet_generation"],
                "component": component_identity(action), "signed_transaction": observed_signed,
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
                execution = transport.rpc(node, "resolveallshadowpowclaims", options)
            except RpcError:
                die(f"node{node.node} Phase-B outcome is indeterminate after durable intent; never retry; run reconcile-b")
            if execution.get("durable_state_ambiguous") is True:
                row = {
                    "schema": 1, "contract": CONTRACT, "kind": "fleet31-phase-b-node-result",
                    "node": node.node, "status": "DURABLE_STATE_AMBIGUOUS", "intent_sha256": intent_sha,
                    "durable_state_ambiguous": True, "mutation_performed": "unknown",
                    "execution_sha256": sha256_bytes(canonical_json(execution)), "created_at": utc_now(),
                }
                publish_json(result_path, row)
                die(f"node{node.node} recovery database outcome is ambiguous; stop every recovery action")
            required = {"action": "commit_and_broadcast", "acknowledged_plan_id": fresh["plan_id"],
                        "plan_consumed": True, "plan_reusable": False, "success": True,
                        "stale_plan": False, "durable_state_ambiguous": False,
                        "relay_deferred": 0, "relay_complete": True}
            for key, expected in required.items():
                if execution.get(key) != expected:
                    die(f"node{node.node} Phase-B result {key} differs from {expected!r}; do not retry")
            if not isinstance(execution.get("actions"), list) or len(execution["actions"]) != 1:
                die(f"node{node.node} Phase-B result does not contain exactly one action")
            result_action = execution["actions"][0]
            if (result_action.get("resolution_txid") != observed_signed["resolution_txid"] or
                    result_action.get("persisted") is not True or result_action.get("relay_authorized") is not True or
                    result_action.get("status") not in {"broadcast", "already_in_mempool"} or
                    execution.get("broadcast", 0) + execution.get("already_in_mempool", 0) != 1):
                die(f"node{node.node} Phase-B did not relay exactly the separately authorized signed bytes")
            row = {
                "schema": 1, "contract": CONTRACT, "kind": "fleet31-phase-b-node-result",
                "node": node.node, "status": "EXACT_PLAN_ACKNOWLEDGED_AND_RELAYED",
                "intent_sha256": intent_sha, "acknowledged_plan_id": execution["acknowledged_plan_id"],
                "acknowledged_active_tip": execution.get("acknowledged_active_tip"),
                "acknowledged_active_height": execution.get("acknowledged_active_height"),
                "acknowledged_wallet_generation": execution.get("acknowledged_wallet_generation"),
                "acknowledged_total_fee": execution.get("acknowledged_total_fee"),
                "signed_transaction": observed_signed, "component": component_identity(result_action),
                "runtime": runtime_snapshot, "relay_authority_granted": execution.get("relay_authority_granted"),
                "broadcast": execution.get("broadcast"), "already_in_mempool": execution.get("already_in_mempool"),
                "mutation_performed": True, "durable_state_ambiguous": False, "created_at": utc_now(),
            }
            publish_json(result_path, row)
        digest = finalize_phase_b(run_dir, runtime, tool_sha, phase_a_sha, preview_sha,
                                  authority_sha, lock_ids)
    print(json.dumps({"result": "EXACT_PLAN_ACKNOWLEDGED_FOR_ALL_31", "phase_b_sha256": digest}, sort_keys=True))


def reconcile_b_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    ensure_secure_dir(run_dir)
    runtime = load_runtime_from_run(run_dir)
    _, tool_sha = tool_identity()
    phase_a, phase_a_sha = load_run_receipt(run_dir, "phase-a.json")
    preview_receipt, preview_sha = load_run_receipt(run_dir, "phase-b-preview.json")
    expected_rows = {row["node"]: row for row in preview_receipt["nodes"]}
    authority, authority_sha = parse_secure_json(pathlib.Path(args.authority), "Phase-B authority", args.authority_sha256)
    validate_phase_b_authority(authority, runtime, tool_sha, phase_a_sha, preview_sha)
    transport = Transport(runtime)
    observations: list[dict[str, Any]] = []
    with mutation_locks(runtime):
        for node in runtime.nodes:
            result_path = run_dir / f"phase-b-node{node.node:02d}.json"
            if result_path.exists():
                result, _ = load_run_receipt(run_dir, result_path.name)
                observations.append({"node": node.node, "status": result.get("status")})
                continue
            intent, intent_sha = load_run_receipt(run_dir, f"phase-b-intent-node{node.node:02d}.json")
            chain, fresh, action = stable_preview(transport, node, "reuse_managed", {"reuse_managed"})
            observed_signed = signed_transaction(transport, node, action)
            exact_signed_match(expected_rows[node.node], action, observed_signed, node.node)
            if action.get("relay_authorized") is True or action.get("in_mempool") is True:
                status = "EXACT_BYTES_RELAY_AUTHORIZED_BUT_ACKNOWLEDGED_PLAN_UNATTRIBUTABLE"
            else:
                status = "NO_RELAY_AUTHORITY_OBSERVED"
            observations.append({
                "node": node.node, "status": status, "intent_sha256": intent_sha,
                "current_plan_id": fresh["plan_id"], "signed_transaction": observed_signed,
                "durable_relay_authorized": action.get("relay_authorized"),
                "in_mempool": action.get("in_mempool"),
            })
        receipt = base_receipt("fleet31-shadowpow-recovery-phase-b-reconcile", runtime, tool_sha)
        receipt.update({
            "phase_a_receipt_sha256": phase_a_sha, "signed_byte_preview_sha256": preview_sha,
            "phase_b_authority_sha256": authority_sha, "mutation_performed": False,
            "result": "OBSERVATION_ONLY_NOT_ADMISSIBLE_AS_PHASE_B_COMPLETION",
            "installed_v30_1_4_blocker": "durable metadata does not retain the consumed acknowledged plan/tip/wallet-generation receipt",
            "never_retry_after_observed_relay_authority": True, "observations": observations,
        })
        digest = publish_json(run_dir / "phase-b-reconcile.json", receipt)
    print(json.dumps({"result": receipt["result"], "reconcile_sha256": digest}, sort_keys=True))


def monitor_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    ensure_secure_dir(run_dir)
    runtime = load_runtime_from_run(run_dir)
    _, tool_sha = tool_identity()
    audit, audit_sha = load_run_receipt(run_dir, "audit.json")
    transport = Transport(runtime)
    audit_rows = {row["node"]: row for row in audit["nodes"]}
    samples = require_int(args.samples, "samples", 1)
    interval = require_int(args.interval, "interval", 0)
    latest: list[dict[str, Any]] = []
    for sample in range(samples):
        latest = []
        complete = True
        for node in runtime.nodes:
            chain = validate_chain(transport.rpc(node, "getblockchaininfo"), node.node)
            mining = transport.rpc(node, "getpowmininginfo")
            recovery = transport.rpc(node, "getpowclaimrecoveryinfo", True)
            component = audit_rows[node.node]["component"]
            confirmed: list[dict[str, Any]] = []
            candidate_txids = list(component.get("claim_txids", []))
            phase_a_path = run_dir / f"phase-a-node{node.node:02d}.json"
            if phase_a_path.exists():
                phase_a_row, _ = load_run_receipt(run_dir, phase_a_path.name)
                txid = phase_a_row.get("signed_transaction", {}).get("resolution_txid")
                if isinstance(txid, str):
                    candidate_txids.append(txid)
            for txid in candidate_txids:
                try:
                    tx = transport.rpc(node, "gettransaction", txid, False, True)
                except RpcError:
                    continue
                if isinstance(tx, dict) and isinstance(tx.get("confirmations"), int) and tx["confirmations"] > 0 and isinstance(tx.get("blockhash"), str):
                    header = transport.rpc(node, "getblockheader", tx["blockhash"])
                    if isinstance(header, dict) and header.get("confirmations", 0) > 0:
                        confirmed.append({"txid": txid, "confirmations": tx["confirmations"], "blockhash": tx["blockhash"]})
            anchor = component["anchor"]
            anchor_utxo = transport.rpc(node, "gettxout", anchor["txid"], anchor["vout"], False)
            anchor_spent_on_active_chain = anchor_utxo is None and bool(confirmed)
            baseline_claims = audit_rows[node.node]["pow_baseline"]["claims_submitted"]
            operational = (
                anchor_spent_on_active_chain and isinstance(recovery, dict) and
                recovery.get("database_outcome_ambiguous") is False and
                recovery.get("blocking_quarantined_claims") == 0 and
                isinstance(mining, dict) and mining.get("enabled") is True and
                decimal_amount(mining.get("hashrate", 0), "monitor hashrate") > 0 and
                isinstance(mining.get("claims_submitted"), int) and mining["claims_submitted"] > baseline_claims
            )
            complete &= operational
            latest.append({
                "node": node.node, "height": chain["blocks"], "tip": chain["bestblockhash"],
                "anchor_spent_on_active_chain": anchor_spent_on_active_chain,
                "confirmed_component_transactions": confirmed,
                "blocking_quarantined_claims": recovery.get("blocking_quarantined_claims") if isinstance(recovery, dict) else None,
                "pow_enabled": mining.get("enabled") if isinstance(mining, dict) else None,
                "pow_state": mining.get("state") if isinstance(mining, dict) else None,
                "hashrate": mining.get("hashrate") if isinstance(mining, dict) else None,
                "claims_submitted": mining.get("claims_submitted") if isinstance(mining, dict) else None,
                "baseline_claims_submitted": baseline_claims, "operational": operational,
            })
        if complete or sample + 1 == samples:
            break
        time.sleep(interval)
    receipt = base_receipt("fleet31-shadowpow-recovery-operational-monitor", runtime, tool_sha)
    operational_count = sum(1 for row in latest if row["operational"])
    receipt.update({
        "audit_receipt_sha256": audit_sha, "mutation_performed": False,
        "result": "ALL_31_POW_OPERATIONAL" if operational_count == len(NODE_SET) else "NOT_YET_OPERATIONAL",
        "operational_nodes": operational_count, "required_nodes": len(NODE_SET), "nodes": latest,
        "requires_active_chain_anchor_spend": True, "requires_positive_hashrate": True,
        "requires_claim_submission_increment": True,
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
