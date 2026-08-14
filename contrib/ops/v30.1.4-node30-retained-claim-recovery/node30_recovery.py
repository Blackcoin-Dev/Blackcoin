#!/usr/bin/python3
"""Fail-closed two-phase retained-claim recovery for node30 only.

This fleet-owned installed-v30.1.4 tool preserves node30's Free-Claim pause,
ordinary-PoW-disabled role, and active PoS.  Its only wallet-mutating RPC is
resolveallshadowpowclaims with an exact phase action and exact fee cap.
"""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import fcntl
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import time
from decimal import Decimal
from typing import Any, Iterator, Sequence


CONTRACT = "installed-v30.1.4-node30-retained-claim-recovery/v2"
RECEIPT_SCHEMA = 2
SOURCE_COMMIT = "13262151077cce3f72d07d17dc7725b2b6a8e1ab"
SOURCE_TREE = "a6f7757c34b70fab841905765462d6769112d049"
SOURCE_SIGNER = "SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70"
NETWORK_VERSION = 300104
SUBVERSION = "/Blackcoin:30.1.4/"
NODE = 30
PER_NODE_CAP = Decimal("0.00019100")
FEE_RATE_ATOMS_PER_VB = Decimal("100")
FEE_RATE_ATOMS_PER_K = 100000
EXPECTED_VSIZE = 191
PRIOR_READONLY_RECEIPT_SHA256 = "ca084d6d76fb67532fd65ff8b44943bc3a8c12f589708a11872417223066eec9"
USER_ORDER = "fix all of the quarantined issues even if you have to pay a small fee to fix it on each node. all issues must be resolved"
USER_ORDER_SHA256 = "0252ebcc3dc2ca8a20e8b9708738c30f9c32f6b0dea213bb8937467b2dab2dff"
PAUSE_MARKER_CONTENT = b"schema=1 state=paused authority=v30.1.4-fleet-transaction\n"
PRODUCTION_FREE_CLAIM_ROOT = pathlib.Path("/mnt/pulsar/Blackcoin_Blocks/operations/free-claim-pool")
PRODUCTION_LOCKS = (
    "/run/blackcoin-v3015-rollout.lock",
    "/run/blackcoin-endpoint-guard.lock",
    "/run/blackcoin-node-cutover.lock",
    "/run/blackcoin-pow-quarantine-cycle.lock",
    "/run/blackcoin-wallet-runtime-guard.lock",
    "/run/blackcoin-free-claim-pause-transition.lock",
    "/run/blackcoin-free-claim-pool.lock",
    "/run/blackcoin-node30-retained-claim-recovery.lock",
)
PRODUCTION_NODE_LOCK = "/run/blackcoin-node-30-runtime.lock"
HEX64 = re.compile(r"^[0-9a-f]{64}$")
SAFE_RECEIPT_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")

# The shared signed fleet primitive remains a hash-pinned dependency.  This
# node30 package supplies its own runtime, role, authority and receipt schemas.
BASE_RELATIVE = pathlib.Path("../v30.1.4-fleet31-recovery/fleet31_recovery.py")
BASE_SHA256 = "b97f239569be4d9bb8bdb43163c3ef25fa9f7bba276d2ace835d93264e0ff518"
TEST_TRANSPORT_SHA256 = "11eba8be3677397f5182990060628326fd7e0fabf6d262198994243b80437877"


def _sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb", buffering=0) as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _load_base() -> Any:
    path = (pathlib.Path(__file__).resolve(strict=True).parent / BASE_RELATIVE).resolve(strict=True)
    if _sha256_file(path) != BASE_SHA256:
        raise RuntimeError("hash-pinned fleet recovery primitive changed")
    spec = importlib.util.spec_from_file_location("node30_recovery_base", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load hash-pinned fleet recovery primitive")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    module.CONTRACT = CONTRACT
    module.NODE_SET = (NODE,)
    module.PER_NODE_CAP = PER_NODE_CAP
    module.AGGREGATE_CAP = PER_NODE_CAP
    module.TEST_TRANSPORT_SHA256 = TEST_TRANSPORT_SHA256
    return module


try:
    base = _load_base()
except (OSError, RuntimeError) as exc:
    print(f"FATAL: {exc}", file=sys.stderr)
    raise SystemExit(1)


class Transport(base.Transport):
    """Preserve the shared transport contract with one installed-CLI quirk."""

    def rpc(self, node: Any, method: str, *params: Any) -> Any:
        if method != "gettxout":
            return super().rpc(node, method, *params)
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
            # Installed v30.1.4 blackcoin-cli emits no bytes, with exit 0, for
            # a spent gettxout outpoint. This exception is deliberately exact:
            # whitespace and every other RPC's empty response remain invalid.
            if output == "":
                return None
            return json.loads(output)
        except (base.GateError, json.JSONDecodeError) as exc:
            raise base.RpcError(node.node, method, str(exc)) from exc


def _receipt_path(run_dir: pathlib.Path, name: str) -> pathlib.Path:
    """Return a fixed child receipt path in an owner-only canonical directory."""
    base.ensure_secure_dir(run_dir)
    if not SAFE_RECEIPT_NAME.fullmatch(name) or name in {".", ".."}:
        die(f"unsafe receipt name: {name!r}")
    path = run_dir / name
    if path.parent != run_dir or path.parent.resolve(strict=True) != run_dir:
        die(f"receipt escaped the run directory: {name!r}")
    return path


def owned_receipt_file(path: pathlib.Path, label: str) -> bytes:
    """Read a receipt, healing only our exact interrupted hard-link publish."""
    _receipt_path(path.parent, path.name)
    try:
        st = path.lstat()
    except FileNotFoundError:
        return base.owned_secure_file(path, label)
    if st.st_nlink == 2:
        pattern = re.compile(rf"^\.{re.escape(path.name)}\.tmp\.[1-9][0-9]*\.[1-9][0-9]*$")
        candidates: list[pathlib.Path] = []
        for child in path.parent.iterdir():
            if not pattern.fullmatch(child.name):
                continue
            candidate_st = child.lstat()
            if (stat.S_ISREG(candidate_st.st_mode) and not stat.S_ISLNK(candidate_st.st_mode) and
                    candidate_st.st_dev == st.st_dev and candidate_st.st_ino == st.st_ino and
                    candidate_st.st_uid == os.geteuid() and
                    stat.S_IMODE(candidate_st.st_mode) == 0o600):
                candidates.append(child)
        if (len(candidates) != 1 or not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or
                st.st_uid != os.geteuid() or stat.S_IMODE(st.st_mode) != 0o600):
            die(f"{label} has an unrecognized multi-link publication state")
        candidates[0].unlink()
        base.fsync_dir(path.parent)
        healed = path.lstat()
        if (healed.st_dev != st.st_dev or healed.st_ino != st.st_ino or healed.st_nlink != 1):
            die(f"{label} changed while healing its exact publisher hard link")
    elif st.st_nlink != 1:
        die(f"{label} has an unsafe link count")
    return base.owned_secure_file(path, label)


def publish_sidecar(path: pathlib.Path, digest: str, mode: int = 0o600) -> None:
    """Publish or verify the exact no-clobber SHA256 sidecar."""
    require_hex64(digest, "receipt digest")
    sidecar = path.with_name(path.name + ".sha256")
    data = f"{digest}  {path.name}\n".encode()
    tmp = path.parent / f".{sidecar.name}.tmp.{os.getpid()}.{time.time_ns()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                 getattr(os, "O_NOFOLLOW", 0), mode)
    try:
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        os.link(tmp, sidecar)
        base.fsync_dir(path.parent)
    except FileExistsError:
        existing = owned_receipt_file(sidecar, f"{path.name} SHA256 sidecar")
        if existing != data:
            die(f"refusing mismatched existing receipt sidecar: {sidecar}")
    finally:
        with contextlib.suppress(FileNotFoundError):
            tmp.unlink()
        base.fsync_dir(path.parent)


def publish_bytes(path: pathlib.Path, data: bytes, mode: int = 0o600) -> str:
    """Durably publish without clobbering; heal only an exact orphan."""
    run_dir = path.parent
    _receipt_path(run_dir, path.name)
    digest = base.sha256_bytes(data)
    sidecar = path.with_name(path.name + ".sha256")
    if not path.exists() and sidecar.exists():
        die(f"receipt sidecar exists without its receipt: {sidecar}")
    tmp = run_dir / f".{path.name}.tmp.{os.getpid()}.{time.time_ns()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                 getattr(os, "O_NOFOLLOW", 0), mode)
    try:
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        os.link(tmp, path)
        base.fsync_dir(run_dir)
    except FileExistsError:
        try:
            sidecar.lstat()
        except FileNotFoundError:
            existing = owned_receipt_file(path, path.name)
            if existing != data:
                die(f"refusing to clobber differing orphan receipt: {path}")
        else:
            die(f"refusing to clobber existing receipt: {path}")
    finally:
        with contextlib.suppress(FileNotFoundError):
            tmp.unlink()
        base.fsync_dir(run_dir)
    publish_sidecar(path, digest, mode)
    return digest


def publish_json(path: pathlib.Path, value: Any) -> str:
    return publish_bytes(path, base.canonical_json(value))


def load_run_receipt(run_dir: pathlib.Path, name: str) -> tuple[Any, str]:
    """Load a sidecar-bound receipt, repairing only a valid secure orphan."""
    path = _receipt_path(run_dir, name)
    sidecar = path.with_name(path.name + ".sha256")
    data = owned_receipt_file(path, name)
    try:
        sidecar.lstat()
    except FileNotFoundError:
        try:
            json.loads(data)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            die(f"{name} orphan is not valid JSON: {exc}")
        publish_sidecar(path, base.sha256_bytes(data))
    try:
        side_data = owned_receipt_file(sidecar, f"{name} SHA256 sidecar").decode("ascii", "strict")
    except UnicodeDecodeError as exc:
        die(f"{name} SHA256 sidecar is not ASCII: {exc}")
    match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_.-]+)\n", side_data)
    if not match or match.group(2) != path.name:
        die(f"{name} SHA256 sidecar has invalid shape")
    return base.parse_secure_json(path, name, match.group(1))


class GateError(base.GateError):
    pass


def die(message: str) -> "NoReturn":
    raise GateError(message)


def require_hex64(value: Any, label: str) -> str:
    if not isinstance(value, str) or not HEX64.fullmatch(value):
        die(f"{label} is not a lowercase 32-byte hex identity")
    return value


def exact_amount(value: Any, expected: Decimal, label: str) -> None:
    base.exact_amount(value, expected, label)


def test_mode() -> bool:
    return bool(os.environ.get("FLEET31_TEST_TRANSPORT"))


@dataclasses.dataclass(frozen=True)
class Contract:
    raw: dict[str, Any]
    sha256: str
    path: pathlib.Path
    runtime: Any
    pause_marker: pathlib.Path
    pause_marker_sha256: str
    pause_wrapper: pathlib.Path
    pause_wrapper_sha256: str
    original_worker: pathlib.Path
    original_worker_sha256: str


def validate_manifest(path: pathlib.Path, expected_hash: str | None = None) -> Contract:
    raw, digest = base.parse_secure_json(path, "runtime manifest", expected_hash)
    if (not isinstance(raw, dict) or raw.get("schema") != RECEIPT_SCHEMA or
            raw.get("kind") != "node30-installed-v30.1.4-runtime-contract" or
            raw.get("recovery_contract") != CONTRACT):
        die("runtime manifest schema/kind mismatch")
    exact = {
        "source_commit": SOURCE_COMMIT, "source_tree": SOURCE_TREE,
        "source_signer_fingerprint": SOURCE_SIGNER, "network_version": NETWORK_VERSION,
        "subversion": SUBVERSION,
    }
    for key, value in exact.items():
        if raw.get(key) != value:
            die(f"runtime manifest {key} mismatch")
    for key in ["compose_project", "image_ref", "image_id", "cli_path", "cli_sha256",
                "daemon_path", "daemon_sha256", "datadir", "transport_sha256",
                "pause_marker", "pause_marker_sha256", "pause_wrapper", "pause_wrapper_sha256",
                "original_worker", "original_worker_sha256", "node_lock_path"]:
        if not isinstance(raw.get(key), str) or not raw[key]:
            die(f"runtime manifest field {key} is absent")
    for key in ["cli_sha256", "daemon_sha256", "transport_sha256", "pause_marker_sha256",
                "pause_wrapper_sha256", "original_worker_sha256"]:
        require_hex64(raw[key], f"runtime manifest {key}")
    for key in ["cli_path", "daemon_path", "datadir", "pause_marker", "pause_wrapper",
                "original_worker", "node_lock_path"]:
        if not raw[key].startswith("/"):
            die(f"runtime manifest {key} must be absolute")
    locks = raw.get("global_lock_paths")
    if not isinstance(locks, list) or not locks or any(not isinstance(x, str) or not x.startswith("/") for x in locks):
        die("runtime manifest global locks are malformed")
    if len(locks) != len(set(locks)) or raw["node_lock_path"] in locks:
        die("runtime manifest lock identities are not unique")
    node = raw.get("node")
    if node != {"node": 30, "service": "node30", "container": "blackcoin-v4-gui-30", "wallet": ""}:
        die("runtime manifest must bind exactly the unnamed node30 wallet and service")
    if not test_mode():
        if tuple(locks) != PRODUCTION_LOCKS or raw["node_lock_path"] != PRODUCTION_NODE_LOCK:
            die("live node30 lock contract differs from the reviewed complete lock set")
        root = PRODUCTION_FREE_CLAIM_ROOT
        if (raw["pause_marker"] != str(root / ".v30.1.4-free-claim-paused") or
                raw["pause_wrapper"] != str(root / "pool_daemon.sh") or
                raw["original_worker"] != str(root / "pool_daemon.v30.1.4-original")):
            die("live node30 Free-Claim paths differ from the reviewed pause contract")
    runtime_node = base.RuntimeNode(30, "node30", "blackcoin-v4-gui-30", "")
    runtime = base.RuntimeContract(
        raw=raw, sha256=digest, path=path, compose_project=raw["compose_project"],
        image_ref=raw["image_ref"], image_id=raw["image_id"], cli_path=raw["cli_path"],
        cli_sha256=raw["cli_sha256"], daemon_path=raw["daemon_path"],
        daemon_sha256=raw["daemon_sha256"], datadir=raw["datadir"],
        transport_sha256=raw["transport_sha256"], lock_paths=tuple(locks),
        node_lock_template=raw["node_lock_path"].replace("30", "{node:02d}"),
        nodes=(runtime_node,),
    )
    return Contract(raw, digest, path, runtime, pathlib.Path(raw["pause_marker"]),
                    raw["pause_marker_sha256"], pathlib.Path(raw["pause_wrapper"]),
                    raw["pause_wrapper_sha256"], pathlib.Path(raw["original_worker"]),
                    raw["original_worker_sha256"])


def secure_artifact(path: pathlib.Path, expected_hash: str, label: str,
                    exact_mode: int | None = None) -> dict[str, Any]:
    if not path.is_absolute():
        die(f"{label} path is not absolute")
    try:
        st = path.lstat()
    except FileNotFoundError:
        die(f"{label} is absent")
    if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_nlink != 1:
        die(f"{label} is not a unique regular file")
    if path.resolve(strict=True) != path:
        die(f"{label} path is not canonical")
    if st.st_uid != os.geteuid() or (st.st_mode & 0o022):
        die(f"{label} ownership/mode is unsafe")
    if exact_mode is not None and stat.S_IMODE(st.st_mode) != exact_mode:
        die(f"{label} must be mode {exact_mode:04o}")
    digest = _sha256_file(path)
    if digest != expected_hash:
        die(f"{label} SHA256 mismatch")
    return {"path": str(path), "sha256": digest, "device": st.st_dev, "inode": st.st_ino,
            "size": st.st_size, "mode": format(stat.S_IMODE(st.st_mode), "04o")}


def free_claim_snapshot(contract: Contract) -> dict[str, Any]:
    marker_bytes = base.owned_secure_file(contract.pause_marker, "node30 pause marker",
                                          contract.pause_marker_sha256)
    marker = secure_artifact(contract.pause_marker, contract.pause_marker_sha256,
                             "node30 pause marker", 0o600)
    if marker_bytes != PAUSE_MARKER_CONTENT:
        die("node30 pause-marker content changed")
    wrapper = secure_artifact(contract.pause_wrapper, contract.pause_wrapper_sha256,
                              "node30 pause wrapper")
    worker = secure_artifact(contract.original_worker, contract.original_worker_sha256,
                             "node30 preserved original worker")
    return {"pause_marker": marker, "pause_wrapper": wrapper, "original_worker": worker,
            "pause_preserved": True, "worker_invoked": False}


def preview_options(status_hint: str) -> dict[str, Any]:
    result = {"action": "preview", "max_fee_per_resolution": f"{PER_NODE_CAP:.8f}",
              "max_total_fee": f"{PER_NODE_CAP:.8f}"}
    if status_hint == "ready":
        result["fee_rate"] = str(FEE_RATE_ATOMS_PER_VB)
    return result


def stable_preview(transport: Any, node: Any, status_hint: str, allowed: set[str],
                   allow_relay: bool = False) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    for _ in range(3):
        before = base.validate_chain(transport.rpc(node, "getblockchaininfo"), NODE)
        preview = transport.rpc(node, "resolveallshadowpowclaims", preview_options(status_hint))
        after = base.validate_chain(transport.rpc(node, "getblockchaininfo"), NODE)
        if base.chain_identity(before) != base.chain_identity(after):
            continue
        original_preview = preview
        if isinstance(preview, dict) and isinstance(preview.get("actions"), list) and len(preview["actions"]) == 1:
            # The pinned v30.1.4 primitive predates the installed post-sign
            # classification. Validate its complete legacy shape on a copy,
            # then bind the real resolution_pending classification and relay
            # booleans independently below.
            preview_for_validation = json.loads(json.dumps(preview))
            if preview_for_validation["actions"][0].get("status") != "ready":
                preview_for_validation["actions"][0]["classification"] = "current_branch_ineligible"
            preview_for_validation["actions"][0]["relay_authorized"] = False
            preview_for_validation["actions"][0]["in_mempool"] = False
        else:
            preview_for_validation = preview
        base.validate_preview(preview_for_validation, NODE, allowed)
        preview = original_preview
        action = preview["actions"][0]
        expected_classification = ("current_branch_ineligible" if action.get("status") == "ready"
                                   else "resolution_pending")
        if (action.get("classification") != expected_classification or
                action.get("conflicts_with_revalidating_unbound_proof") is not True or
                action.get("frontier_may_advance") is not True or
                action.get("reason_code") != "unbound-proof-may-revalidate"):
            die(f"node30 action is not the exact {expected_classification} QQP2 family")
        if allow_relay:
            if (action.get("persisted") is not True or
                    action.get("relay_authorized") not in {True, False} or
                    action.get("in_mempool") not in {True, False}):
                die("node30 persisted action has untyped relay state")
        elif action.get("relay_authorized") is not False or action.get("in_mempool") is not False:
            die("node30 recovery already has relay or mempool state")
        if preview["active_tip"] == after["bestblockhash"] and preview["active_height"] == after["blocks"]:
            return after, preview, action
    die("node30 could not produce a stable exact recovery preview")


def role_snapshot(transport: Any, node: Any, require_blocker: bool) -> dict[str, Any]:
    runtime = transport.runtime_snapshot(node)
    chain = base.validate_chain(transport.rpc(node, "getblockchaininfo"), NODE)
    network = transport.rpc(node, "getnetworkinfo")
    peers = transport.rpc(node, "getconnectioncount")
    wallets = transport.rpc(node, "listwallets")
    wallet = transport.rpc(node, "getwalletinfo")
    staking = transport.rpc(node, "getstakinginfo")
    mining = transport.rpc(node, "getpowmininginfo")
    recovery = transport.rpc(node, "getpowclaimrecoveryinfo", True)
    if not isinstance(network, dict) or network.get("version") != NETWORK_VERSION or network.get("subversion") != SUBVERSION:
        die("node30 network identity differs from installed v30.1.4")
    if not isinstance(peers, int) or peers < 1 or wallets != [""]:
        die("node30 peer or wallet inventory is incoherent")
    if (not isinstance(wallet, dict) or wallet.get("walletname") != "" or
            wallet.get("private_keys_enabled") is not True or
            wallet.get("external_signer", False) is not False or wallet.get("scanning", False) is not False or
            wallet.get("unlocked_staking_only") is not False or not isinstance(wallet.get("unlocked_until"), int) or
            wallet["unlocked_until"] <= int(time.time()) or not isinstance(wallet.get("txcount"), int)):
        die("node30 wallet is not normally unlocked")
    if (not isinstance(staking, dict) or staking.get("enabled") is not True or
            staking.get("staking") is not True or base.decimal_amount(staking.get("weight", 0), "PoS weight") <= 0):
        die("node30 PoS is not active with positive weight")
    if (not isinstance(mining, dict) or mining.get("enabled") is not False or
            mining.get("state") != "disabled" or base.decimal_amount(mining.get("hashrate", 0), "PoW hashrate") != 0):
        die("node30 ordinary-PoW-disabled role changed")
    if (not isinstance(recovery, dict) or recovery.get("chain_ready") is not True or
            recovery.get("wallet_tip_matches") is not True or recovery.get("database_outcome_ambiguous") is not False or
            recovery.get("active_tip") != chain["bestblockhash"] or
            recovery.get("active_height") != chain["blocks"]):
        die("node30 recovery inventory is incoherent")
    if require_blocker and (recovery.get("blocking_quarantined_claims") != 1 or
                            mining.get("blocking_quarantined_claims") != 1):
        die("node30 does not have exactly one retained-claim blocker")
    inventory = {"loaded_wallets": wallets,
                 "selected_wallet": "", "walletname": wallet["walletname"],
                 "format": wallet.get("format"), "txcount": wallet["txcount"],
                 "unlocked_until": wallet["unlocked_until"],
                 "private_keys_enabled": True, "external_signer": False}
    wallet_inventory_identity(inventory, "node30 live wallet inventory")
    return {"runtime": runtime, "chain": {"height": chain["blocks"], "tip": chain["bestblockhash"]},
            "peers": peers, "wallet_inventory": inventory,
            "pos": {"enabled": True, "staking": True, "weight": staking.get("weight")},
            "ordinary_pow": {"enabled": False, "state": "disabled", "hashrate": mining.get("hashrate")},
            "recovery": recovery}


def wallet_inventory_identity(inventory: Any, label: str) -> dict[str, Any]:
    """Return the immutable unnamed-wallet selection and capability identity."""
    if (not isinstance(inventory, dict) or inventory.get("loaded_wallets") != [""] or
            inventory.get("selected_wallet") != "" or inventory.get("walletname") != "" or
            not isinstance(inventory.get("format"), str) or not inventory["format"] or
            inventory.get("private_keys_enabled") is not True or
            inventory.get("external_signer") is not False or
            type(inventory.get("txcount")) is not int or inventory["txcount"] < 0 or
            type(inventory.get("unlocked_until")) is not int):
        die(f"{label} is not the exact unnamed node30 wallet inventory")
    return {key: inventory[key] for key in ["loaded_wallets", "selected_wallet", "walletname",
                                             "format", "private_keys_enabled", "external_signer"]}


def same_wallet_inventory(expected: Any, actual: Any, label: str) -> None:
    if wallet_inventory_identity(expected, f"{label} authorized inventory") != \
            wallet_inventory_identity(actual, f"{label} current inventory"):
        die(f"{label} immutable wallet inventory changed")


def same_runtime_identity(expected: Any, actual: Any, label: str) -> None:
    stable = ["node", "service", "wallet", "container_id", "started_at", "image_ref",
              "image_id", "cli_sha256", "daemon_sha256", "healthy"]
    if (not isinstance(expected, dict) or not isinstance(actual, dict) or
            {key: expected.get(key) for key in stable} !=
            {key: actual.get(key) for key in stable}):
        die(f"{label} immutable installed runtime identity changed")


def pin_node(transport: Any, node: Any) -> tuple[Any, dict[str, Any]]:
    runtime = transport.runtime_snapshot(node)
    container_id = require_hex64(runtime.get("container_id"), "node30 container id")
    return base.RuntimeNode(NODE, node.service, container_id, node.wallet), runtime


def component_identity(action: dict[str, Any]) -> dict[str, Any]:
    result = base.component_identity(action)
    result.update({
        "frontier_may_advance": action.get("frontier_may_advance"),
        "conflicts_with_revalidating_unbound_proof":
            action.get("conflicts_with_revalidating_unbound_proof"),
        "reason_code": action.get("reason_code"), "reason": action.get("reason"),
    })
    return result


def same_stable_component(expected: dict[str, Any], action: dict[str, Any], label: str) -> None:
    """Bind stable claim/fee fields while allowing only documented tip dynamics."""
    actual = component_identity(action)
    if not isinstance(expected, dict) or set(expected) != set(actual):
        die(f"{label} component shape changed")
    require_hex64(expected.get("component_fingerprint"), f"{label} prior component fingerprint")
    require_hex64(actual.get("component_fingerprint"), f"{label} current component fingerprint")
    prior_class = expected.get("classification")
    current_class = actual.get("classification")
    allowed_transition = (prior_class == "current_branch_ineligible" and
                          current_class == "resolution_pending" and
                          action.get("status") != "ready")
    if current_class != prior_class and not allowed_transition:
        die(f"{label} classification changed outside the exact post-sign transition")
    dynamic = {"component_fingerprint", "classification"}
    if ({k: expected[k] for k in expected if k not in dynamic} !=
            {k: actual[k] for k in actual if k not in dynamic}):
        die(f"{label} stable anchor/generation/claims/fee/output fields changed")


def signed_evidence(transport: Any, node: Any, action: dict[str, Any],
                    prove_unspent_anchor: bool) -> dict[str, Any]:
    """Prove exact signed bytes, separating identity from chain observations."""
    txid = require_hex64(action.get("resolution_txid"), "node30 resolution txid")
    tx = transport.rpc(node, "gettransaction", txid, False, True)
    if not isinstance(tx, dict) or tx.get("txid") != txid or not isinstance(tx.get("hex"), str):
        die("node30 exact signed transaction is unavailable")
    raw = tx["hex"]
    if not re.fullmatch(r"[0-9a-f]+", raw) or len(raw) % 2:
        die("node30 signed transaction hex is malformed")
    decoded = tx.get("decoded")
    if not isinstance(decoded, dict) or decoded.get("txid") != txid:
        die("node30 decoded signed transaction identity changed")
    vin, vout = decoded.get("vin"), decoded.get("vout")
    anchor = action.get("anchor")
    if (not isinstance(vin, list) or len(vin) != 1 or not isinstance(vin[0], dict) or
            vin[0].get("txid") != anchor.get("txid") or vin[0].get("vout") != anchor.get("vout") or
            vin[0].get("sequence") != 4294967295 or not isinstance(vout, list) or len(vout) != 1 or
            not isinstance(vout[0], dict) or vout[0].get("n") != 0 or decoded.get("vsize") != EXPECTED_VSIZE):
        die("node30 signed transaction is not the exact 191-vbyte one-input/one-output recycle")
    output_value = base.decimal_amount(vout[0].get("value"), "node30 signed output value")
    exact_amount(output_value, base.decimal_amount(action.get("output_amount"), "node30 action output"),
                 "node30 signed output amount")
    output_script = vout[0].get("scriptPubKey", {}).get("hex")
    if (not isinstance(output_script, str) or not re.fullmatch(r"[0-9a-f]+", output_script) or
            len(output_script) % 2):
        die("node30 signed output script is not lowercase hex")
    identity = {
        "resolution_txid": txid, "raw_hex_sha256": base.sha256_bytes(raw.encode()),
        "decoded_sha256": base.sha256_bytes(base.canonical_json(decoded)),
        "input": {"txid": vin[0]["txid"], "vout": vin[0]["vout"],
                  "sequence": vin[0]["sequence"]},
        "output": {"n": 0, "value": f"{output_value:.8f}", "script": output_script},
        "vsize": decoded["vsize"],
    }
    relay_metadata = tx.get("qq_shadow_pow_resolution_relay_authorized")
    if relay_metadata not in {"0", "1"}:
        die("node30 signed transaction lacks typed durable relay-authority metadata")
    evidence: dict[str, Any] = {
        "identity": identity,
        "identity_sha256": base.sha256_bytes(base.canonical_json(identity)),
        "observation": {"confirmations": tx.get("confirmations", 0),
                        "blockhash": tx.get("blockhash"),
                        "durable_relay_authorized_metadata": relay_metadata},
    }
    if prove_unspent_anchor:
        txout = transport.rpc(node, "gettxout", anchor["txid"], anchor["vout"], False)
        if not isinstance(txout, dict):
            die("node30 exact anchor is not independently unspent on the active chain")
        anchor_value = base.decimal_amount(txout.get("value"), "node30 active-chain anchor value")
        anchor_script = txout.get("scriptPubKey", {}).get("hex")
        if (not isinstance(anchor_script, str) or not re.fullmatch(r"[0-9a-f]+", anchor_script) or
                len(anchor_script) % 2):
            die("node30 active-chain anchor script is not lowercase hex")
        exact_amount(anchor_value, base.decimal_amount(action.get("input_amount"), "node30 action input"),
                     "node30 independently observed anchor value")
        if anchor_script != output_script:
            die("node30 signed resolution does not recycle the exact anchor script")
        fee = anchor_value - output_value
        exact_amount(fee, PER_NODE_CAP, "node30 independently computed signed fee")
        exact_amount(action.get("fee"), fee, "node30 declared action fee")
        evidence["fee_proof"] = {
            "anchor": {"txid": anchor["txid"], "vout": anchor["vout"],
                       "value": f"{anchor_value:.8f}", "script": anchor_script},
            "signed_output_value": f"{output_value:.8f}",
            "computed_fee_blk": f"{fee:.8f}", "include_mempool": False,
            "same_script": True,
        }
    return evidence


def same_signed_identity(expected: dict[str, Any], actual: dict[str, Any], label: str) -> None:
    if (not isinstance(expected, dict) or not isinstance(actual, dict) or
            expected.get("identity") != actual.get("identity") or
            expected.get("identity_sha256") != actual.get("identity_sha256")):
        die(f"{label} immutable signed transaction identity changed")


def tool_sha() -> str:
    return _sha256_file(pathlib.Path(__file__).resolve(strict=True))


def base_receipt(kind: str, contract: Contract) -> dict[str, Any]:
    return {"schema": RECEIPT_SCHEMA, "contract": CONTRACT, "kind": kind, "created_at": base.utc_now(),
            "tool_sha256": tool_sha(), "shared_primitive_sha256": BASE_SHA256,
            "installed_source": {"commit": SOURCE_COMMIT, "tree": SOURCE_TREE,
                                 "signer_fingerprint": SOURCE_SIGNER},
            "runtime_manifest_sha256": contract.sha256, "node": NODE, "role": "free_claim",
            "ordinary_pow_must_remain_disabled": True,
            "free_claim_pause_must_remain_present": True,
            "fee_cap_blk": f"{PER_NODE_CAP:.8f}",
            "prior_readonly_receipt_sha256": PRIOR_READONLY_RECEIPT_SHA256,
            "user_order_sha256": USER_ORDER_SHA256}


def validate_common_receipt(receipt: Any, kind: str, contract: Contract) -> dict[str, Any]:
    if not isinstance(receipt, dict):
        die(f"{kind} receipt is not an object")
    expected = {
        "schema": RECEIPT_SCHEMA, "contract": CONTRACT, "kind": kind,
        "tool_sha256": tool_sha(), "shared_primitive_sha256": BASE_SHA256,
        "runtime_manifest_sha256": contract.sha256, "node": NODE, "role": "free_claim",
        "ordinary_pow_must_remain_disabled": True,
        "free_claim_pause_must_remain_present": True,
        "fee_cap_blk": f"{PER_NODE_CAP:.8f}",
        "prior_readonly_receipt_sha256": PRIOR_READONLY_RECEIPT_SHA256,
        "user_order_sha256": USER_ORDER_SHA256,
    }
    for key, value in expected.items():
        if receipt.get(key) != value:
            die(f"{kind} receipt field {key} differs from the current exact contract")
    if receipt.get("installed_source") != {
            "commit": SOURCE_COMMIT, "tree": SOURCE_TREE,
            "signer_fingerprint": SOURCE_SIGNER}:
        die(f"{kind} receipt installed source identity changed")
    if not isinstance(receipt.get("created_at"), str):
        die(f"{kind} receipt creation timestamp is absent")
    return receipt


def load_audit(run_dir: pathlib.Path, contract: Contract) -> tuple[dict[str, Any], str]:
    audit, digest = load_run_receipt(run_dir, "audit.json")
    validate_common_receipt(audit, "node30-retained-claim-recovery-audit", contract)
    if (audit.get("result") != "READY_FOR_SEPARATE_PHASE_A_AUTHORITY" or
            audit.get("mutation_performed") is not False or
            not isinstance(audit.get("node_state"), dict)):
        die("node30 audit receipt is not the exact read-only authority boundary")
    return audit, digest


def load_phase_a(run_dir: pathlib.Path, contract: Contract) -> tuple[dict[str, Any], str]:
    phase_a, digest = load_run_receipt(run_dir, "phase-a.json")
    validate_common_receipt(phase_a, "node30-retained-claim-phase-a-complete", contract)
    row = phase_a.get("node_result")
    if (phase_a.get("result") != "SIGNED_WITHOUT_RELAY_AUTHORITY" or
            phase_a.get("relay_or_broadcast_authorized") is not False or
            not isinstance(row, dict) or row.get("schema") != RECEIPT_SCHEMA or
            row.get("contract") != CONTRACT or row.get("kind") != "node30-phase-a-result" or
            row.get("node") != NODE or
            row.get("status") not in {"SIGNED_AND_PERSISTED", "ALREADY_SIGNED_NONRELAY"} or
            row.get("relay_authority_granted") != 0 or row.get("broadcast") != 0 or
            not isinstance(row.get("signed_evidence"), dict) or
            row["signed_evidence"].get("observation", {}).get(
                "durable_relay_authorized_metadata") != "0"):
        die("node30 Phase-A receipt is not the exact nonrelayable completion")
    for key in ["audit_receipt_sha256", "phase_a_authority_sha256", "node_result_sha256"]:
        require_hex64(phase_a.get(key), f"Phase-A receipt {key}")
    _, audit_sha = load_audit(run_dir, contract)
    if phase_a["audit_receipt_sha256"] != audit_sha:
        die("node30 Phase-A completion no longer binds the exact audit receipt")
    row_file, row_sha = load_run_receipt(run_dir, "phase-a-node30.json")
    if row_file != row or phase_a["node_result_sha256"] != row_sha:
        die("node30 Phase-A embedded result differs from its exact sidecar-bound receipt")
    intent, intent_sha = load_run_receipt(run_dir, "phase-a-intent-node30.json")
    if (not isinstance(intent, dict) or intent.get("schema") != RECEIPT_SCHEMA or
            intent.get("contract") != CONTRACT or intent.get("kind") != "node30-phase-a-intent" or
            intent.get("action") != "sign_only" or intent.get("audit_sha256") != audit_sha or
            intent.get("authority_sha256") != phase_a["phase_a_authority_sha256"] or
            intent.get("tool_sha256") != tool_sha() or
            intent.get("runtime_manifest_sha256") != contract.sha256 or
            row.get("intent_sha256") != intent_sha):
        die("node30 Phase-A intent/authority/result chain changed")
    return phase_a, digest


def load_phase_b_preview(run_dir: pathlib.Path, contract: Contract,
                         phase_a_sha: str) -> tuple[dict[str, Any], str]:
    preview, digest = load_run_receipt(run_dir, "phase-b-preview.json")
    validate_common_receipt(preview, "node30-retained-claim-phase-b-preview", contract)
    if (preview.get("result") != "READY_FOR_SEPARATE_PHASE_B_AUTHORITY" or
            preview.get("mutation_performed") is not False or
            preview.get("phase_a_receipt_sha256") != phase_a_sha or
            not isinstance(preview.get("signed_evidence"), dict) or
            preview.get("signed_transaction_identity_sha256") !=
                preview["signed_evidence"].get("identity_sha256") or
            not isinstance(preview.get("runtime"), dict) or
            not isinstance(preview.get("wallet_inventory"), dict)):
        die("node30 Phase-B preview receipt is not the exact signed-byte authority boundary")
    wallet_inventory_identity(preview["wallet_inventory"],
                              "node30 Phase-B preview wallet inventory")
    require_hex64(preview.get("signed_transaction_identity_sha256"),
                  "Phase-B preview signed identity")
    require_hex64(preview.get("plan_id"), "Phase-B preview plan")
    require_hex64(preview.get("active_tip"), "Phase-B preview active tip")
    if (type(preview.get("active_height")) is not int or
            type(preview.get("wallet_generation")) is not int):
        die("node30 Phase-B preview chain or wallet generation is untyped")
    evidence = preview["signed_evidence"]
    proof = evidence.get("fee_proof")
    identity = evidence.get("identity")
    component = preview.get("component")
    if (not isinstance(proof, dict) or proof.get("computed_fee_blk") != f"{PER_NODE_CAP:.8f}" or
            proof.get("same_script") is not True or proof.get("include_mempool") is not False or
            not isinstance(identity, dict) or not isinstance(component, dict) or
            proof.get("anchor", {}).get("txid") != component.get("anchor", {}).get("txid") or
            proof.get("anchor", {}).get("vout") != component.get("anchor", {}).get("vout") or
            identity.get("input", {}).get("txid") != component.get("anchor", {}).get("txid") or
            identity.get("input", {}).get("vout") != component.get("anchor", {}).get("vout") or
            identity.get("output", {}).get("script") != proof.get("anchor", {}).get("script") or
            identity.get("vsize") != EXPECTED_VSIZE or
            evidence.get("observation", {}).get("durable_relay_authorized_metadata") != "0"):
        die("node30 Phase-B preview lacks the exact independently proved fee/script/bytes binding")
    return preview, digest


def load_contract(run_dir: pathlib.Path) -> Contract:
    _, digest = load_run_receipt(run_dir, "runtime-manifest.json")
    return validate_manifest(run_dir / "runtime-manifest.json", digest)


@contextlib.contextmanager
def mutation_locks(contract: Contract) -> Iterator[list[dict[str, Any]]]:
    paths = [*contract.runtime.lock_paths, contract.raw["node_lock_path"]]
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
                    path.parent.resolve(strict=True) != path.parent or
                    parent_st.st_uid != os.geteuid() or parent_st.st_mode & 0o022):
                die(f"mutation lock parent is not canonical and owner-controlled: {path.parent}")
            flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
            before: os.stat_result | None = None
            try:
                fd = os.open(path, flags | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                before = path.lstat()
                if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode) or
                        before.st_uid != os.geteuid() or before.st_nlink != 1 or
                        stat.S_IMODE(before.st_mode) != 0o600 or
                        path.resolve(strict=True) != path):
                    die(f"existing mutation lock is unsafe: {path}")
                fd = os.open(path, flags)
            opened = os.fstat(fd)
            if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid() or
                    opened.st_nlink != 1 or stat.S_IMODE(opened.st_mode) != 0o600 or
                    (before is not None and
                     (opened.st_dev != before.st_dev or opened.st_ino != before.st_ino))):
                os.close(fd)
                die(f"mutation lock changed during secure open: {path}")
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                os.close(fd)
                die(f"mutation lock is busy: {path}")
            st = path.lstat()
            if (st.st_dev != opened.st_dev or st.st_ino != opened.st_ino or
                    st.st_nlink != 1 or stat.S_IMODE(st.st_mode) != 0o600):
                fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)
                die(f"mutation lock pathname changed after locking: {path}")
            fds.append(fd)
            identities.append({"path": str(path), "device": st.st_dev, "inode": st.st_ino,
                               "mode": format(stat.S_IMODE(st.st_mode), "03o")})
        yield identities
    finally:
        for fd in reversed(fds):
            with contextlib.suppress(OSError):
                fcntl.flock(fd, fcntl.LOCK_UN)
            with contextlib.suppress(OSError):
                os.close(fd)


def common_authority(authority: Any, kind: str, action: str, contract: Contract) -> dict[str, Any]:
    if (not isinstance(authority, dict) or authority.get("schema") != RECEIPT_SCHEMA or
            authority.get("kind") != kind):
        die("authority schema/kind mismatch")
    expected = {"decision": "authorize", "action": action, "node": NODE, "role": "free_claim",
                "ordinary_pow_must_remain_disabled": True, "free_claim_pause_must_remain_present": True,
                "runtime_manifest_sha256": contract.sha256, "tool_sha256": tool_sha(),
                "shared_primitive_sha256": BASE_SHA256, "source_commit": SOURCE_COMMIT,
                "source_tree": SOURCE_TREE, "fee_cap_blk": f"{PER_NODE_CAP:.8f}",
                "prior_readonly_receipt_sha256": PRIOR_READONLY_RECEIPT_SHA256,
                "effective_user_order": USER_ORDER, "user_order_sha256": USER_ORDER_SHA256}
    for key, value in expected.items():
        if authority.get(key) != value:
            die(f"authority field {key} differs from the exact node30 contract")
    return authority


def phase_a_authority(authority: Any, contract: Contract, audit_sha: str) -> None:
    authority = common_authority(authority, "node30-retained-claim-phase-a-authority", "sign_only", contract)
    if authority.get("audit_receipt_sha256") != audit_sha or authority.get("fee_rate_atoms_per_vb") != "100":
        die("Phase-A authority does not bind the exact audit and fee rate")
    if authority.get("allow_fresh_plan_rebind_for_unchanged_component_and_fee") is not True:
        die("Phase-A fresh-plan rebind acknowledgement is absent")
    acks = authority.get("acknowledgements", {})
    for key in ["fee_and_conflict_risk", "durable_signed_draft_has_no_clean_public_cancellation",
                "confirmation_may_permanently_forfeit_revalidating_qqp2_quantum_payout",
                "no_relay_or_broadcast_authority_in_phase_a", "free_claim_pause_preserved",
                "ordinary_pow_remains_disabled", "no_generic_transaction_rpc"]:
        if acks.get(key) is not True:
            die(f"Phase-A acknowledgement {key} is absent")


def phase_b_authority(authority: Any, contract: Contract, phase_a_sha: str,
                      preview_sha: str, signed_identity_sha: str) -> None:
    authority = common_authority(authority, "node30-retained-claim-phase-b-authority",
                                 "commit_and_broadcast", contract)
    expected = {"phase_a_receipt_sha256": phase_a_sha,
                "signed_byte_preview_sha256": preview_sha,
                "signed_transaction_identity_sha256": signed_identity_sha,
                "allow_fresh_plan_rebind_for_exact_signed_bytes": True}
    for key, value in expected.items():
        if authority.get(key) != value:
            die(f"Phase-B authority field {key} changed")
    acks = authority.get("acknowledgements", {})
    for key in ["fee_and_conflict_risk", "broadcast_is_irreversible",
                "independently_computed_fee_and_same_script_proof_reviewed",
                "durable_exact_byte_relay_authority_survives_restart_or_rpc_response_loss",
                "confirmation_may_permanently_forfeit_revalidating_qqp2_quantum_payout",
                "missing_rpc_result_cannot_reconstruct_original_acknowledged_plan_on_v30_1_4",
                "free_claim_pause_preserved", "ordinary_pow_remains_disabled",
                "no_generic_transaction_rpc"]:
        if acks.get(key) is not True:
            die(f"Phase-B acknowledgement {key} is absent")


def audit_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    base.ensure_secure_dir(run_dir, create=True)
    contract = validate_manifest(pathlib.Path(args.runtime_manifest))
    publish_bytes(run_dir / "runtime-manifest.json",
                  base.owned_secure_file(contract.path, "runtime manifest", contract.sha256))
    pause_before = free_claim_snapshot(contract)
    transport = Transport(contract.runtime)
    node = contract.runtime.nodes[0]
    exact_node, runtime_before = pin_node(transport, node)
    role = role_snapshot(transport, exact_node, True)
    chain, preview, action = stable_preview(transport, exact_node, "ready", {"ready", "reuse_managed"})
    if preview.get("fee_rate_atoms_per_k") not in {None, FEE_RATE_ATOMS_PER_K}:
        die("node30 preview fee rate changed")
    details = role["recovery"].get("component_details") or []
    matches = [x for x in details if isinstance(x, dict) and x.get("anchor", {}).get("txid") == action["anchor"]["txid"] and x.get("anchor", {}).get("vout") == action["anchor"]["vout"]]
    if len(matches) != 1 or matches[0].get("anchor_authenticated") is not True or matches[0].get("anchor_unspent") is not True:
        die("node30 verbose recovery inventory does not authenticate the exact live anchor")
    pause_after = free_claim_snapshot(contract)
    if pause_before != pause_after:
        die("node30 Free-Claim pause artifacts changed during audit")
    row = {"node": NODE, "role": role, "plan": preview, "component": component_identity(action),
           "status": action["status"], "free_claim": pause_after}
    if action["status"] == "ready":
        row["unsigned_template_hash"] = action["unsigned_template_hash"]
    else:
        row["signed_evidence"] = signed_evidence(transport, exact_node, action, True)
    if transport.runtime_snapshot(node) != runtime_before:
        die("node30 runtime changed across the read-only audit")
    receipt = base_receipt("node30-retained-claim-recovery-audit", contract)
    receipt.update({"mutation_performed": False, "result": "READY_FOR_SEPARATE_PHASE_A_AUTHORITY",
                    "stable_tip": chain["bestblockhash"], "stable_height": chain["blocks"], "node_state": row})
    receipt["required_phase_a_authority"] = {
        "schema": RECEIPT_SCHEMA, "kind": "node30-retained-claim-phase-a-authority", "decision": "authorize",
        "action": "sign_only", "node": NODE, "role": "free_claim",
        "ordinary_pow_must_remain_disabled": True, "free_claim_pause_must_remain_present": True,
        "audit_receipt_sha256": "REPLACE_WITH_AUDIT_SHA256",
        "runtime_manifest_sha256": contract.sha256, "tool_sha256": tool_sha(),
        "shared_primitive_sha256": BASE_SHA256, "source_commit": SOURCE_COMMIT,
        "source_tree": SOURCE_TREE, "fee_cap_blk": f"{PER_NODE_CAP:.8f}",
        "fee_rate_atoms_per_vb": "100", "prior_readonly_receipt_sha256": PRIOR_READONLY_RECEIPT_SHA256,
        "effective_user_order": USER_ORDER, "user_order_sha256": USER_ORDER_SHA256,
        "allow_fresh_plan_rebind_for_unchanged_component_and_fee": True,
        "acknowledgements": {"fee_and_conflict_risk": True,
            "durable_signed_draft_has_no_clean_public_cancellation": True,
            "confirmation_may_permanently_forfeit_revalidating_qqp2_quantum_payout": True,
            "no_relay_or_broadcast_authority_in_phase_a": True,
            "free_claim_pause_preserved": True, "ordinary_pow_remains_disabled": True,
            "no_generic_transaction_rpc": True}}
    digest = publish_json(run_dir / "audit.json", receipt)
    print(json.dumps({"result": receipt["result"], "audit_sha256": digest}, sort_keys=True))


def same_component(audit: dict[str, Any], action: dict[str, Any]) -> None:
    same_stable_component(audit["node_state"]["component"], action,
                          "node30 authority-bound audit")


def phase_a_complete(run_dir: pathlib.Path, contract: Contract, audit_sha: str,
                     authority_sha: str, lock_ids: list[dict[str, Any]]) -> str:
    row, row_sha = load_run_receipt(run_dir, "phase-a-node30.json")
    if row.get("status") not in {"SIGNED_AND_PERSISTED", "ALREADY_SIGNED_NONRELAY"}:
        die("node30 lacks a conclusive nonrelayable Phase-A result")
    receipt = base_receipt("node30-retained-claim-phase-a-complete", contract)
    receipt.update({"result": "SIGNED_WITHOUT_RELAY_AUTHORITY", "mutation_performed": True,
                    "relay_or_broadcast_authorized": False, "audit_receipt_sha256": audit_sha,
                    "phase_a_authority_sha256": authority_sha, "node_result_sha256": row_sha,
                    "node_result": row, "lock_identities": lock_ids})
    return publish_json(run_dir / "phase-a.json", receipt)


def phase_a_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    base.ensure_secure_dir(run_dir)
    contract = load_contract(run_dir)
    audit, audit_sha = load_audit(run_dir, contract)
    authority, authority_sha = base.parse_secure_json(pathlib.Path(args.authority), "Phase-A authority", args.authority_sha256)
    phase_a_authority(authority, contract, audit_sha)
    transport = Transport(contract.runtime)
    node = contract.runtime.nodes[0]
    with mutation_locks(contract) as lock_ids:
        if (run_dir / "phase-a.json").exists():
            die("Phase-A completion already exists; refusing replay")
        if (run_dir / "phase-a-node30.json").exists():
            digest = phase_a_complete(run_dir, contract, audit_sha, authority_sha, lock_ids)
            print(json.dumps({"result": "SIGNED_WITHOUT_RELAY_AUTHORITY", "phase_a_sha256": digest}, sort_keys=True))
            return
        if (run_dir / "phase-a-intent-node30.json").exists():
            die("node30 has an unmatched Phase-A intent; run reconcile-a and never retry")
        pause_before = free_claim_snapshot(contract)
        exact_node, runtime_before = pin_node(transport, node)
        role_before = role_snapshot(transport, exact_node, True)
        _, fresh, action = stable_preview(transport, exact_node, "ready" if audit["node_state"]["status"] == "ready" else "reuse_managed", {"ready", "reuse_managed"})
        same_component(audit, action)
        intent = {"schema": RECEIPT_SCHEMA, "contract": CONTRACT, "kind": "node30-phase-a-intent",
                  "action": "sign_only", "audit_sha256": audit_sha, "authority_sha256": authority_sha,
                  "tool_sha256": tool_sha(), "runtime_manifest_sha256": contract.sha256,
                  "plan_id": fresh["plan_id"], "active_tip": fresh["active_tip"],
                  "active_height": fresh["active_height"], "wallet_generation": fresh["wallet_generation"],
                  "component": component_identity(action), "role_before": role_before,
                  "free_claim_before": pause_before, "created_at": base.utc_now()}
        intent_sha = publish_json(run_dir / "phase-a-intent-node30.json", intent)
        if action["status"] == "reuse_managed":
            signed = signed_evidence(transport, exact_node, action, True)
            status, mutated = "ALREADY_SIGNED_NONRELAY", False
        else:
            options = {"action": "sign_only", "expected_plan_id": fresh["plan_id"],
                       "acknowledge_fee_and_conflict_risk": True,
                       "fee_rate": "100", "max_fee_per_resolution": f"{PER_NODE_CAP:.8f}",
                       "max_total_fee": f"{PER_NODE_CAP:.8f}"}
            try:
                execution = transport.rpc(exact_node, "resolveallshadowpowclaims", options)
            except base.RpcError:
                die("node30 Phase-A outcome is unknown after durable intent; run reconcile-a and never retry")
            ack = base_receipt("node30-retained-claim-phase-a-rpc-ack", contract)
            ack.update({"intent_sha256": intent_sha, "phase_a_authority_sha256": authority_sha,
                        "rpc_method": "resolveallshadowpowclaims", "rpc_action": "sign_only",
                        "rpc_response": execution, "published_before_post_call_reads": True})
            publish_json(run_dir / "phase-a-ack-node30.json", ack)
            required = {"action": "sign_only", "acknowledged_plan_id": fresh["plan_id"],
                        "acknowledged_active_tip": fresh["active_tip"],
                        "acknowledged_active_height": fresh["active_height"],
                        "acknowledged_wallet_generation": fresh["wallet_generation"],
                        "plan_consumed": True, "plan_reusable": False, "success": True,
                        "stale_plan": False, "durable_state_ambiguous": False,
                        "relay_authority_granted": 0, "broadcast": 0,
                        "already_in_mempool": 0, "relay_deferred": 0}
            for key, expected in required.items():
                if execution.get(key) != expected:
                    die(f"node30 Phase-A result {key} changed; never retry")
            exact_amount(execution.get("acknowledged_total_fee"), PER_NODE_CAP, "Phase-A acknowledged fee")
            if not isinstance(execution.get("actions"), list) or len(execution["actions"]) != 1:
                die("node30 Phase-A result lacks exactly one action")
            action = execution["actions"][0]
            if (action.get("status") != "signed_and_persisted" or action.get("persisted") is not True or
                    action.get("relay_authorized") is not False or action.get("in_mempool") is not False):
                die("node30 Phase-A did not persist exactly one nonrelayable draft")
            same_component(audit, action)
            signed = signed_evidence(transport, exact_node, action, True)
            _, persisted_preview, persisted_action = stable_preview(
                transport, exact_node, "reuse_managed", {"reuse_managed"})
            persisted_signed = signed_evidence(transport, exact_node, persisted_action, True)
            same_stable_component(component_identity(action), persisted_action,
                                  "node30 Phase-A acknowledged component")
            if (persisted_action.get("relay_authorized") is not False or
                    persisted_action.get("in_mempool") is not False):
                die("node30 Phase-A post-call durable draft differs from the acknowledged exact bytes")
            same_signed_identity(signed, persisted_signed, "node30 Phase-A durable draft")
            status, mutated = "SIGNED_AND_PERSISTED", True
        role_after = role_snapshot(transport, exact_node, True)
        pause_after = free_claim_snapshot(contract)
        if (pause_after != pause_before or role_after["ordinary_pow"] != role_before["ordinary_pow"] or
                transport.runtime_snapshot(node) != runtime_before):
            die("node30 pause or ordinary-PoW role changed during Phase A")
        row = {"schema": RECEIPT_SCHEMA, "contract": CONTRACT, "kind": "node30-phase-a-result",
               "node": NODE, "status": status, "intent_sha256": intent_sha,
               "fresh_plan": {"plan_id": fresh["plan_id"], "tip": fresh["active_tip"],
                              "height": fresh["active_height"], "wallet_generation": fresh["wallet_generation"]},
               "fee_blk": f"{PER_NODE_CAP:.8f}", "component": component_identity(action),
               "signed_evidence": signed, "role_after": role_after,
               "free_claim_after": pause_after, "relay_authority_granted": 0,
               "broadcast": 0, "mutation_performed": mutated,
               "durable_state_ambiguous": False, "created_at": base.utc_now()}
        publish_json(run_dir / "phase-a-node30.json", row)
        digest = phase_a_complete(run_dir, contract, audit_sha, authority_sha, lock_ids)
    print(json.dumps({"result": "SIGNED_WITHOUT_RELAY_AUTHORITY", "phase_a_sha256": digest}, sort_keys=True))


def reconcile_a_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    base.ensure_secure_dir(run_dir)
    contract = load_contract(run_dir)
    audit, audit_sha = load_audit(run_dir, contract)
    authority, authority_sha = base.parse_secure_json(pathlib.Path(args.authority), "Phase-A authority", args.authority_sha256)
    phase_a_authority(authority, contract, audit_sha)
    transport = Transport(contract.runtime)
    node = contract.runtime.nodes[0]
    with mutation_locks(contract) as lock_ids:
        if (run_dir / "phase-a-node30.json").exists():
            row, _ = load_run_receipt(run_dir, "phase-a-node30.json")
            result = row.get("status")
        elif not (run_dir / "phase-a-intent-node30.json").exists():
            result = "NO_PHASE_A_INTENT"
        else:
            intent, intent_sha = load_run_receipt(run_dir, "phase-a-intent-node30.json")
            exact_node, runtime_before = pin_node(transport, node)
            _, fresh, action = stable_preview(transport, exact_node, "reuse_managed", {"ready", "reuse_managed"})
            same_component(audit, action)
            if action["status"] == "reuse_managed":
                signed = signed_evidence(transport, exact_node, action, True)
                row = {"schema": RECEIPT_SCHEMA, "contract": CONTRACT, "kind": "node30-phase-a-result",
                       "node": NODE, "status": "SIGNED_AND_PERSISTED", "intent_sha256": intent_sha,
                       "reconciled_after_missing_rpc_result": True,
                       "fresh_plan": {"plan_id": fresh["plan_id"], "tip": fresh["active_tip"],
                                      "height": fresh["active_height"], "wallet_generation": fresh["wallet_generation"]},
                       "fee_blk": f"{PER_NODE_CAP:.8f}", "component": component_identity(action),
                       "signed_evidence": signed, "role_after": role_snapshot(transport, exact_node, True),
                       "free_claim_after": free_claim_snapshot(contract), "relay_authority_granted": 0,
                       "broadcast": 0, "mutation_performed": "unknown", "durable_state_ambiguous": False,
                       "created_at": base.utc_now()}
                publish_json(run_dir / "phase-a-node30.json", row)
                result = "SIGNED_AND_PERSISTED"
            else:
                result = "NO_MUTATION_OBSERVED_NEW_AUDIT_AND_AUTHORITY_REQUIRED"
        receipt = base_receipt("node30-retained-claim-phase-a-reconcile", contract)
        receipt.update({"result": result, "mutation_performed": False,
                        "audit_receipt_sha256": audit_sha, "phase_a_authority_sha256": authority_sha})
        reconcile_sha = publish_json(run_dir / "phase-a-reconcile.json", receipt)
        phase_a_sha = None
        if result in {"SIGNED_AND_PERSISTED", "ALREADY_SIGNED_NONRELAY"} and not (run_dir / "phase-a.json").exists():
            phase_a_sha = phase_a_complete(run_dir, contract, audit_sha, authority_sha, lock_ids)
    print(json.dumps({"result": result, "reconcile_sha256": reconcile_sha,
                      "phase_a_sha256": phase_a_sha}, sort_keys=True))


def validate_phase_b_intent(intent: Any, contract: Contract, phase_a_sha: str,
                            preview_sha: str, authority_sha: str,
                            preview: dict[str, Any]) -> dict[str, Any]:
    expected = {
        "schema": RECEIPT_SCHEMA, "contract": CONTRACT, "kind": "node30-phase-b-intent",
        "node": NODE, "action": "commit_and_broadcast", "phase_a_sha256": phase_a_sha,
        "signed_byte_preview_sha256": preview_sha, "authority_sha256": authority_sha,
        "tool_sha256": tool_sha(), "shared_primitive_sha256": BASE_SHA256,
        "runtime_manifest_sha256": contract.sha256,
        "signed_transaction_identity_sha256": preview["signed_transaction_identity_sha256"],
    }
    if not isinstance(intent, dict):
        die("node30 Phase-B intent is not an object")
    for key, value in expected.items():
        if intent.get(key) != value:
            die(f"node30 Phase-B intent field {key} changed")
    for key in ["plan_id", "active_tip"]:
        require_hex64(intent.get(key), f"node30 Phase-B intent {key}")
    if (type(intent.get("active_height")) is not int or
            type(intent.get("wallet_generation")) is not int or
            intent.get("runtime") != preview.get("runtime") or
            not isinstance(intent.get("wallet_inventory"), dict)):
        die("node30 Phase-B intent runtime/wallet/chain binding changed")
    same_wallet_inventory(preview["wallet_inventory"], intent["wallet_inventory"],
                          "node30 Phase-B intent")
    role_before = intent.get("role_before")
    if (not isinstance(role_before, dict) or
            role_before.get("ordinary_pow") != preview.get("role_state", {}).get("ordinary_pow") or
            role_before.get("ordinary_pow", {}).get("enabled") is not False or
            role_before.get("pos", {}).get("staking") is not True or
            intent.get("free_claim_before") != preview.get("free_claim") or
            intent.get("free_claim_before", {}).get("pause_preserved") is not True):
        die("node30 Phase-B intent role or Free-Claim identity changed")
    same_runtime_identity(preview.get("role_state", {}).get("runtime"),
                          role_before.get("runtime"), "node30 Phase-B intent role")
    same_signed_identity(preview["signed_evidence"], intent.get("signed_evidence"),
                         "node30 Phase-B intent")
    # Intent components are already normalized dictionaries, so compare their
    # stable fields directly and permit only a different tip-relative fingerprint.
    expected_component = preview["component"]
    actual_component = intent.get("component")
    if not isinstance(actual_component, dict) or set(actual_component) != set(expected_component):
        die("node30 Phase-B intent component shape changed")
    dynamic = {"component_fingerprint"}
    if ({k: expected_component[k] for k in expected_component if k not in dynamic} !=
            {k: actual_component[k] for k in actual_component if k not in dynamic}):
        die("node30 Phase-B intent stable component changed")
    require_hex64(actual_component.get("component_fingerprint"),
                  "node30 Phase-B intent component fingerprint")
    return intent


def load_phase_b_ack(run_dir: pathlib.Path, contract: Contract, intent_sha: str,
                     authority_sha: str) -> tuple[dict[str, Any], str]:
    ack, digest = load_run_receipt(run_dir, "phase-b-ack-node30.json")
    validate_common_receipt(ack, "node30-retained-claim-phase-b-rpc-ack", contract)
    if (ack.get("intent_sha256") != intent_sha or
            ack.get("phase_b_authority_sha256") != authority_sha or
            ack.get("rpc_method") != "resolveallshadowpowclaims" or
            ack.get("rpc_action") != "commit_and_broadcast" or
            ack.get("published_before_post_call_reads") is not True or
            "rpc_response" not in ack):
        die("node30 Phase-B RPC acknowledgement chain changed")
    return ack, digest


def classify_phase_b_response(execution: Any, intent: dict[str, Any],
                              preview: dict[str, Any]) -> tuple[str, dict[str, Any] | None]:
    if not isinstance(execution, dict):
        die("node30 Phase-B RPC acknowledgement is not an object; never retry")
    if execution.get("durable_state_ambiguous") is True:
        return "DURABLE_STATE_AMBIGUOUS_STOP", None
    required = {
        "action": "commit_and_broadcast", "acknowledged_plan_id": intent["plan_id"],
        "acknowledged_active_tip": intent["active_tip"],
        "acknowledged_active_height": intent["active_height"],
        "acknowledged_wallet_generation": intent["wallet_generation"],
        "plan_consumed": True, "plan_reusable": False, "durable_state_ambiguous": False,
    }
    for key, value in required.items():
        if execution.get(key) != value:
            die(f"node30 Phase-B acknowledged field {key} changed; never retry")
    exact_amount(execution.get("acknowledged_total_fee"), PER_NODE_CAP,
                 "node30 Phase-B acknowledged total fee")
    actions = execution.get("actions")
    if not isinstance(actions, list) or len(actions) != 1 or not isinstance(actions[0], dict):
        die("node30 Phase-B acknowledgement lacks exactly one action; never retry")
    action = actions[0]
    same_stable_component(preview["component"], action, "node30 Phase-B RPC acknowledgement")
    if (action.get("resolution_txid") !=
            preview["signed_evidence"]["identity"]["resolution_txid"] or
            action.get("persisted") is not True or action.get("relay_authorized") is not True):
        die("node30 Phase-B acknowledgement does not bind the authorized exact bytes")
    raw = action.get("hex")
    if (not isinstance(raw, str) or not re.fullmatch(r"[0-9a-f]+", raw) or len(raw) % 2 or
            base.sha256_bytes(raw.encode()) !=
                preview["signed_evidence"]["identity"]["raw_hex_sha256"]):
        die("node30 Phase-B acknowledgement signed hex differs from the authorized bytes")
    counters = ["signed_and_persisted", "relay_authority_granted", "broadcast",
                "already_in_mempool", "relay_deferred"]
    if any(type(execution.get(key)) is not int for key in counters):
        die("node30 Phase-B acknowledgement counters are not exact integers; never retry")
    full = (execution.get("success") is True and execution.get("stale_plan") is False and
            execution.get("durable_state_changed") is True and
            execution["signed_and_persisted"] == 0 and
            execution["relay_authority_granted"] == 1 and
            execution["relay_deferred"] == 0 and execution.get("relay_complete") is True and
            execution.get("error") == "" and isinstance(execution.get("current_plan"), dict) and
            action.get("status") in {"broadcast", "already_in_mempool"} and
            action.get("in_mempool") is True and
            execution["broadcast"] + execution["already_in_mempool"] == 1)
    if full:
        return "EXACT_PLAN_ACKNOWLEDGED_AND_RELAYED", action
    partial = (execution.get("success") is False and execution.get("stale_plan") is True and
               execution.get("durable_state_changed") is True and
               execution["signed_and_persisted"] == 0 and
               execution["relay_authority_granted"] == 1 and
               execution["broadcast"] == 0 and execution["already_in_mempool"] == 0 and
               execution["relay_deferred"] == 0 and execution.get("relay_complete") is False and
               action.get("status") in {"reuse_managed", "signed_and_persisted", "relay_deferred"} and
               action.get("in_mempool") is False and isinstance(execution.get("error"), str) and
               bool(execution.get("error")) and isinstance(execution.get("current_plan"), dict))
    if partial:
        return "EXACT_RELAY_AUTHORITY_PERSISTED_PENDING_RELAY", action
    die("node30 Phase-B returned an unrecognized post-intent result; never retry")


def load_phase_b_complete(run_dir: pathlib.Path, contract: Contract,
                          phase_a_sha: str, preview: dict[str, Any], preview_sha: str,
                          authority_sha: str) -> tuple[dict[str, Any], str]:
    """Validate the complete sidecar-bound Phase-B authority/result chain."""
    receipt, digest = load_run_receipt(run_dir, "phase-b.json")
    validate_common_receipt(receipt, "node30-retained-claim-phase-b-complete", contract)
    intent, intent_sha = load_run_receipt(run_dir, "phase-b-intent-node30.json")
    validate_phase_b_intent(intent, contract, phase_a_sha, preview_sha,
                            authority_sha, preview)
    ack, ack_sha = load_phase_b_ack(run_dir, contract, intent_sha, authority_sha)
    ack_class, _ = classify_phase_b_response(ack["rpc_response"], intent, preview)
    if ack_class not in {"EXACT_PLAN_ACKNOWLEDGED_AND_RELAYED",
                         "EXACT_RELAY_AUTHORITY_PERSISTED_PENDING_RELAY"}:
        die("node30 Phase-B completion has no exact nonambiguous RPC acknowledgement")
    row, row_sha = load_run_receipt(run_dir, "phase-b-node30.json")
    expected_links = {
        "phase_a_receipt_sha256": phase_a_sha,
        "signed_byte_preview_sha256": preview_sha,
        "phase_b_authority_sha256": authority_sha,
        "intent_sha256": intent_sha,
        "rpc_ack_sha256": ack_sha,
        "node_result_sha256": row_sha,
    }
    for key, value in expected_links.items():
        if receipt.get(key) != value:
            die(f"node30 Phase-B completion field {key} changed")
    if (receipt.get("result") not in {
                "EXACT_PLAN_ACKNOWLEDGED_AND_RELAYED",
                "EXACT_AUTHORIZED_COMPONENT_CONFIRMED_ON_ACTIVE_CHAIN"} or
            receipt.get("mutation_performed") is not True or
            receipt.get("node_result") != row or not isinstance(receipt.get("lock_identities"), list)):
        die("node30 Phase-B completion has an invalid terminal result shape")
    expected_lock_paths = [*contract.runtime.lock_paths, contract.raw["node_lock_path"]]
    lock_ids = receipt["lock_identities"]
    if (len(lock_ids) != len(expected_lock_paths) or
            [item.get("path") if isinstance(item, dict) else None for item in lock_ids] !=
                expected_lock_paths or
            any(item.get("mode") != "600" or not isinstance(item.get("device"), int) or
                not isinstance(item.get("inode"), int) for item in lock_ids)):
        die("node30 Phase-B completion lock identities changed")
    if (not isinstance(row, dict) or row.get("schema") != RECEIPT_SCHEMA or
            row.get("contract") != CONTRACT or row.get("kind") != "node30-phase-b-result" or
            row.get("node") != NODE or row.get("status") != receipt["result"] or
            row.get("intent_sha256") != intent_sha or row.get("rpc_ack_sha256") != ack_sha or
            row.get("ack_classification") != ack_class or
            row.get("acknowledged_plan_id") != intent["plan_id"] or
            row.get("acknowledged_active_tip") != intent["active_tip"] or
            row.get("acknowledged_active_height") != intent["active_height"] or
            row.get("acknowledged_wallet_generation") != intent["wallet_generation"] or
            row.get("component") != preview["component"] or
            row.get("signed_evidence") != preview["signed_evidence"] or
            row.get("relay_authority_granted") !=
                ack["rpc_response"].get("relay_authority_granted") or
            row.get("broadcast") != ack["rpc_response"].get("broadcast") or
            row.get("already_in_mempool") != ack["rpc_response"].get("already_in_mempool") or
            row.get("acknowledged_error") != ack["rpc_response"].get("error") or
            row.get("mutation_performed") is not True or
            row.get("durable_state_ambiguous") is not False):
        die("node30 Phase-B node result differs from its exact authority chain")
    exact_amount(row.get("acknowledged_total_fee"), PER_NODE_CAP,
                 "node30 Phase-B completion acknowledged fee")
    same_signed_identity(preview["signed_evidence"], row["signed_evidence"],
                         "node30 Phase-B completion")
    post_state = row.get("post_call_state")
    role_after = row.get("role_after")
    if (not isinstance(post_state, dict) or not isinstance(role_after, dict) or
            post_state.get("role") != role_after or
            role_after.get("ordinary_pow") != intent["role_before"].get("ordinary_pow") or
            role_after.get("ordinary_pow", {}).get("enabled") is not False or
            role_after.get("pos", {}).get("staking") is not True or
            row.get("free_claim_after") != intent.get("free_claim_before") or
            row.get("free_claim_after", {}).get("pause_preserved") is not True):
        die("node30 Phase-B completion does not preserve the exact node30 role")
    same_runtime_identity(intent["runtime"], role_after.get("runtime"),
                          "node30 Phase-B completion")
    same_wallet_inventory(intent["wallet_inventory"], role_after.get("wallet_inventory"),
                          "node30 Phase-B completion")
    confirmed = row.get("status") == "EXACT_AUTHORIZED_COMPONENT_CONFIRMED_ON_ACTIVE_CHAIN"
    if (row.get("confirmation_claimed") is not confirmed or
            receipt.get("confirmation_or_free_claim_success_claimed") is not confirmed):
        die("node30 Phase-B confirmation claim differs from the authenticated result")
    if confirmed:
        confirmed_rows = post_state.get("confirmed_component_transactions")
        candidates = {preview["signed_evidence"]["identity"]["resolution_txid"],
                      *preview["component"]["claim_txids"]}
        anchor = preview["component"]["anchor"]
        if (post_state.get("state") != "ACTIVE_CHAIN_CLEARED" or
                post_state.get("anchor_spent_on_active_chain") is not True or
                post_state.get("blocking_quarantined_claims") != 0 or
                not isinstance(confirmed_rows, list) or len(confirmed_rows) != 1 or
                confirmed_rows[0].get("txid") not in candidates or
                not isinstance(confirmed_rows[0].get("confirmations"), int) or
                confirmed_rows[0]["confirmations"] <= 0 or
                not HEX64.fullmatch(confirmed_rows[0].get("blockhash", "")) or
                not HEX64.fullmatch(confirmed_rows[0].get("decoded_sha256", "")) or
                confirmed_rows[0].get("anchor_input") != anchor):
            die("node30 Phase-B completion lacks authenticated active-chain clearance")
    else:
        if (ack_class != "EXACT_PLAN_ACKNOWLEDGED_AND_RELAYED" or
                post_state.get("state") != "PERSISTED_DRAFT" or
                post_state.get("relay_authorized") is not True):
            die("node30 Phase-B relay completion is inconsistent with its exact acknowledgement")
        if not isinstance(post_state.get("component"), dict):
            die("node30 Phase-B completion observation lacks an exact component")
        same_stable_component(preview["component"], post_state.get("component"),
                              "node30 Phase-B completion observation")
        same_signed_identity(preview["signed_evidence"], post_state.get("signed_evidence"),
                             "node30 Phase-B completion observation")
    return receipt, digest


def confirmed_component_spenders(transport: Any, node: Any, component: dict[str, Any],
                                 expected_signed: dict[str, Any]) -> list[dict[str, Any]]:
    """Authenticate the unique active-chain transaction that spent the anchor."""
    anchor = component["anchor"]
    candidates = [expected_signed["identity"]["resolution_txid"], *component["claim_txids"]]
    confirmed: list[dict[str, Any]] = []
    for txid in candidates:
        try:
            tx = transport.rpc(node, "gettransaction", txid, False, True)
        except base.RpcError:
            continue
        decoded = tx.get("decoded") if isinstance(tx, dict) else None
        vin = decoded.get("vin") if isinstance(decoded, dict) else None
        spends = ([item for item in vin if isinstance(item, dict) and
                   item.get("txid") == anchor["txid"] and item.get("vout") == anchor["vout"]]
                  if isinstance(vin, list) else [])
        if (not isinstance(tx, dict) or tx.get("txid") != txid or
                not isinstance(decoded, dict) or decoded.get("txid") != txid or len(spends) != 1 or
                type(tx.get("confirmations")) is not int or tx["confirmations"] <= 0 or
                not isinstance(tx.get("blockhash"), str) or
                not HEX64.fullmatch(tx["blockhash"])):
            continue
        header = transport.rpc(node, "getblockheader", tx["blockhash"])
        if (not isinstance(header, dict) or header.get("hash") != tx["blockhash"] or
                type(header.get("confirmations")) is not int or header["confirmations"] <= 0):
            continue
        if txid == expected_signed["identity"]["resolution_txid"]:
            synthetic = {**component, "resolution_txid": txid}
            current = signed_evidence(transport, node, synthetic, False)
            same_signed_identity(expected_signed, current,
                                 "node30 active-chain resolution confirmation")
        confirmed.append({"txid": txid, "confirmations": tx["confirmations"],
                          "blockhash": tx["blockhash"],
                          "decoded_sha256": base.sha256_bytes(base.canonical_json(decoded)),
                          "anchor_input": {"txid": anchor["txid"], "vout": anchor["vout"]}})
    if len(confirmed) != 1:
        die("node30 does not have exactly one authenticated active-chain component spender")
    return confirmed


def confirmed_clearance(transport: Any, node: Any, phase_a: dict[str, Any]) -> dict[str, Any]:
    row = phase_a["node_result"]
    component = row["component"]
    expected_signed = row["signed_evidence"]
    anchor = component["anchor"]
    if transport.rpc(node, "gettxout", anchor["txid"], anchor["vout"], False) is not None:
        die("node30 anchor remains unspent on the active chain")
    confirmed = confirmed_component_spenders(transport, node, component, expected_signed)
    role = role_snapshot(transport, node, False)
    blockers = role["recovery"].get("blocking_quarantined_claims")
    if blockers != 0:
        die("node30 anchor is spent without an authenticated active-chain component confirmation")
    return {"state": "ACTIVE_CHAIN_CLEARED", "anchor_spent_on_active_chain": True,
            "confirmed_component_transactions": confirmed,
            "blocking_quarantined_claims": blockers, "role": role}


def phase_b_preview_barrier(transport: Any, node: Any) -> None:
    """Take a mutex-serialized read-only preview before post-intent observations."""
    for _ in range(3):
        before = base.validate_chain(transport.rpc(node, "getblockchaininfo"), NODE)
        preview = transport.rpc(node, "resolveallshadowpowclaims",
                                preview_options("reuse_managed"))
        after = base.validate_chain(transport.rpc(node, "getblockchaininfo"), NODE)
        if base.chain_identity(before) != base.chain_identity(after):
            continue
        if (not isinstance(preview, dict) or preview.get("action") != "preview" or
                preview.get("active_tip") != after["bestblockhash"] or
                preview.get("active_height") != after["blocks"] or
                preview.get("wallet_tip_matches") is not True or
                preview.get("plan_reusable") is not True or preview.get("complete") is not True or
                preview.get("success") is not True or preview.get("stale_plan") is not False or
                preview.get("durable_state_changed") is not False or
                preview.get("durable_state_ambiguous") is not False):
            die("node30 Phase-B serialization preview is incoherent")
        counters = ["relay_authority_granted", "broadcast", "already_in_mempool",
                    "relay_deferred"]
        if any(type(preview.get(key)) is not int or preview[key] != 0 for key in counters):
            die("node30 Phase-B serialization preview has nonzero or untyped counters")
        require_hex64(preview.get("plan_id"), "node30 Phase-B serialization plan")
        if type(preview.get("wallet_generation")) is not int:
            die("node30 Phase-B serialization preview lacks wallet generation")
        return
    die("node30 could not take a stable Phase-B serialization preview")


def observe_phase_b_state(transport: Any, node: Any, phase_a: dict[str, Any],
                          preview: dict[str, Any]) -> dict[str, Any]:
    component = phase_a["node_result"]["component"]
    anchor = component["anchor"]
    phase_b_preview_barrier(transport, node)
    txout = transport.rpc(node, "gettxout", anchor["txid"], anchor["vout"], False)
    if txout is None:
        return confirmed_clearance(transport, node, phase_a)
    role = role_snapshot(transport, node, True)
    chain, current, action = stable_preview(transport, node, "reuse_managed",
                                             {"reuse_managed"}, True)
    if role["chain"] != {"height": chain["blocks"], "tip": chain["bestblockhash"]}:
        die("node30 role inventory and mutex-serialized Phase-B preview differ by chain tip")
    same_stable_component(preview["component"], action, "node30 current Phase-B state")
    evidence = signed_evidence(transport, node, action, True)
    same_signed_identity(preview["signed_evidence"], evidence,
                         "node30 current Phase-B state")
    expected_metadata = "1" if action.get("relay_authorized") is True else "0"
    if evidence["observation"].get("durable_relay_authorized_metadata") != expected_metadata:
        die("node30 preview relay authority differs from durable wallet metadata")
    return {"state": "PERSISTED_DRAFT", "plan_id": current["plan_id"],
            "tip": chain["bestblockhash"], "height": chain["blocks"],
            "relay_authorized": action.get("relay_authorized"),
            "in_mempool": action.get("in_mempool"), "signed_evidence": evidence,
            "component": component_identity(action), "role": role}


def finalize_phase_b_from_ack(run_dir: pathlib.Path, contract: Contract,
                              phase_a: dict[str, Any], phase_a_sha: str,
                              preview: dict[str, Any], preview_sha: str,
                              authority_sha: str, intent: dict[str, Any], intent_sha: str,
                              ack: dict[str, Any], ack_sha: str, transport: Any,
                              exact_node: Any, node: Any, runtime_before: dict[str, Any],
                              pause_before: dict[str, Any], lock_ids: list[dict[str, Any]]) -> tuple[str, str | None]:
    ack_class, _ = classify_phase_b_response(ack["rpc_response"], intent, preview)
    if ack_class == "DURABLE_STATE_AMBIGUOUS_STOP":
        die("node30 Phase-B durable database outcome is ambiguous; stop and never retry")
    state = observe_phase_b_state(transport, exact_node, phase_a, preview)
    same_wallet_inventory(intent["wallet_inventory"], state["role"]["wallet_inventory"],
                          "node30 Phase-B post-call")
    pause_after = free_claim_snapshot(contract)
    runtime_after = transport.runtime_snapshot(node)
    if (pause_after != pause_before or runtime_after != runtime_before or
            state["role"]["ordinary_pow"] != intent["role_before"]["ordinary_pow"]):
        die("node30 runtime, Free-Claim pause, or ordinary-PoW role changed during Phase B")
    completed = ack_class == "EXACT_PLAN_ACKNOWLEDGED_AND_RELAYED"
    if state["state"] == "ACTIVE_CHAIN_CLEARED":
        completed = True
        result = "EXACT_AUTHORIZED_COMPONENT_CONFIRMED_ON_ACTIVE_CHAIN"
    elif ack_class == "EXACT_RELAY_AUTHORITY_PERSISTED_PENDING_RELAY":
        if state.get("relay_authorized") is not True:
            die("node30 acknowledged durable relay authority is absent from current wallet state")
        result = "EXACT_RELAY_AUTHORITY_PERSISTED_PENDING_RELAY"
    else:
        if state.get("relay_authorized") is not True:
            die("node30 fully acknowledged relay authority is absent from current wallet state")
        result = "EXACT_PLAN_ACKNOWLEDGED_AND_RELAYED"
    if not completed:
        pending = base_receipt("node30-retained-claim-phase-b-observation", contract)
        pending.update({"result": result, "mutation_performed": False,
                        "phase_a_receipt_sha256": phase_a_sha,
                        "signed_byte_preview_sha256": preview_sha,
                        "phase_b_authority_sha256": authority_sha,
                        "intent_sha256": intent_sha, "rpc_ack_sha256": ack_sha,
                        "ack_classification": ack_class, "observation": state,
                        "acknowledged_error": ack["rpc_response"].get("error"),
                        "never_retry_exact_intent": True,
                        "free_claim": pause_after})
        name = f"phase-b-observation-{time.time_ns()}.json"
        digest = publish_json(run_dir / name, pending)
        return result, digest
    row = {"schema": RECEIPT_SCHEMA, "contract": CONTRACT, "kind": "node30-phase-b-result",
           "node": NODE, "status": result, "intent_sha256": intent_sha,
           "rpc_ack_sha256": ack_sha, "ack_classification": ack_class,
           "acknowledged_plan_id": intent["plan_id"],
           "acknowledged_active_tip": intent["active_tip"],
           "acknowledged_active_height": intent["active_height"],
           "acknowledged_wallet_generation": intent["wallet_generation"],
           "acknowledged_total_fee": f"{PER_NODE_CAP:.8f}",
           "component": preview["component"], "signed_evidence": preview["signed_evidence"],
           "relay_authority_granted": ack["rpc_response"].get("relay_authority_granted"),
           "broadcast": ack["rpc_response"].get("broadcast"),
           "already_in_mempool": ack["rpc_response"].get("already_in_mempool"),
           "acknowledged_error": ack["rpc_response"].get("error"),
           "post_call_state": state, "role_after": state["role"],
           "free_claim_after": pause_after, "mutation_performed": True,
           "confirmation_claimed": state["state"] == "ACTIVE_CHAIN_CLEARED",
           "durable_state_ambiguous": False, "created_at": base.utc_now()}
    result_path = run_dir / "phase-b-node30.json"
    if result_path.exists():
        existing, row_sha = load_run_receipt(run_dir, result_path.name)
        if existing != row:
            # A crash-recovery read occurs later and has newer observations;
            # accept only a fully validated immutable result chain already published.
            fixed = {k: row[k] for k in ["schema", "contract", "kind", "node", "intent_sha256",
                     "rpc_ack_sha256", "ack_classification", "acknowledged_plan_id",
                     "acknowledged_active_tip", "acknowledged_active_height",
                     "acknowledged_wallet_generation", "acknowledged_total_fee",
                     "component", "signed_evidence", "relay_authority_granted",
                     "broadcast", "already_in_mempool", "acknowledged_error",
                     "durable_state_ambiguous"]}
            if (any(existing.get(k) != v for k, v in fixed.items()) or
                    existing.get("status") not in {
                        "EXACT_PLAN_ACKNOWLEDGED_AND_RELAYED",
                        "EXACT_AUTHORIZED_COMPONENT_CONFIRMED_ON_ACTIVE_CHAIN"} or
                    existing.get("mutation_performed") is not True or
                    not isinstance(existing.get("role_after"), dict) or
                    existing["role_after"].get("ordinary_pow", {}).get("enabled") is not False or
                    existing["role_after"].get("pos", {}).get("staking") is not True or
                    existing.get("free_claim_after", {}).get("pause_preserved") is not True):
                die("node30 existing Phase-B result differs from the exact authority chain")
            row = existing
    else:
        row_sha = publish_json(result_path, row)
    receipt = base_receipt("node30-retained-claim-phase-b-complete", contract)
    receipt.update({"result": row["status"], "mutation_performed": True,
                    "phase_a_receipt_sha256": phase_a_sha,
                    "signed_byte_preview_sha256": preview_sha,
                    "phase_b_authority_sha256": authority_sha,
                    "intent_sha256": intent_sha, "rpc_ack_sha256": ack_sha,
                    "node_result_sha256": row_sha, "node_result": row,
                    "lock_identities": lock_ids,
                    "confirmation_or_free_claim_success_claimed": row["confirmation_claimed"]})
    final_path = run_dir / "phase-b.json"
    if final_path.exists():
        existing, digest = load_run_receipt(run_dir, final_path.name)
        validate_common_receipt(existing, "node30-retained-claim-phase-b-complete", contract)
        if (existing.get("node_result_sha256") != row_sha or
                existing.get("node_result") != row or
                existing.get("phase_a_receipt_sha256") != phase_a_sha or
                existing.get("signed_byte_preview_sha256") != preview_sha or
                existing.get("phase_b_authority_sha256") != authority_sha or
                existing.get("intent_sha256") != intent_sha or
                existing.get("rpc_ack_sha256") != ack_sha):
            die("node30 existing Phase-B completion differs from the exact result")
    else:
        digest = publish_json(final_path, receipt)
    verified, digest = load_phase_b_complete(run_dir, contract, phase_a_sha, preview,
                                             preview_sha, authority_sha)
    return verified["result"], digest


def phase_b_preview_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    base.ensure_secure_dir(run_dir)
    contract = load_contract(run_dir)
    phase_a, phase_a_sha = load_phase_a(run_dir, contract)
    row = phase_a["node_result"]
    pause_before = free_claim_snapshot(contract)
    transport = Transport(contract.runtime)
    node = contract.runtime.nodes[0]
    exact_node, runtime_before = pin_node(transport, node)
    anchor = row["component"]["anchor"]
    if transport.rpc(exact_node, "gettxout", anchor["txid"], anchor["vout"], False) is None:
        cleared = confirmed_clearance(transport, exact_node, phase_a)
        pause_after = free_claim_snapshot(contract)
        if pause_after != pause_before or transport.runtime_snapshot(node) != runtime_before:
            die("node30 runtime or Free-Claim pause changed during cleared Phase-B preview")
        receipt = base_receipt("node30-retained-claim-phase-b-preview", contract)
        receipt.update({"result": "ALREADY_CLEARED_NO_PHASE_B_AUTHORITY", "mutation_performed": False,
                        "phase_a_receipt_sha256": phase_a_sha, "clearance": cleared,
                        "runtime": runtime_before, "free_claim": pause_after})
        digest = publish_json(run_dir / "phase-b-preview.json", receipt)
        print(json.dumps({"result": receipt["result"], "phase_b_preview_sha256": digest}, sort_keys=True))
        return
    role = role_snapshot(transport, exact_node, True)
    _, preview, action = stable_preview(transport, exact_node, "reuse_managed", {"reuse_managed"})
    same_stable_component(row["component"], action, "node30 Phase-A to Phase-B preview")
    evidence = signed_evidence(transport, exact_node, action, True)
    same_signed_identity(row["signed_evidence"], evidence,
                         "node30 Phase-A to Phase-B preview")
    if evidence["observation"].get("confirmations") != 0:
        die("node30 signed resolution is not an exact unconfirmed Phase-B candidate")
    pause_after = free_claim_snapshot(contract)
    if pause_after != pause_before or transport.runtime_snapshot(node) != runtime_before:
        die("node30 Free-Claim pause or runtime changed during Phase-B preview")
    signed_identity_sha = evidence["identity_sha256"]
    receipt = base_receipt("node30-retained-claim-phase-b-preview", contract)
    receipt.update({"result": "READY_FOR_SEPARATE_PHASE_B_AUTHORITY", "mutation_performed": False,
                    "phase_a_receipt_sha256": phase_a_sha, "plan_id": preview["plan_id"],
                    "active_tip": preview["active_tip"], "active_height": preview["active_height"],
                    "wallet_generation": preview["wallet_generation"], "component": component_identity(action),
                    "signed_evidence": evidence,
                    "signed_transaction_identity_sha256": signed_identity_sha,
                    "runtime": runtime_before, "wallet_inventory": role["wallet_inventory"],
                    "role_state": role, "free_claim": pause_after})
    receipt["required_phase_b_authority"] = {
        "schema": RECEIPT_SCHEMA, "kind": "node30-retained-claim-phase-b-authority", "decision": "authorize",
        "action": "commit_and_broadcast", "node": NODE, "role": "free_claim",
        "ordinary_pow_must_remain_disabled": True, "free_claim_pause_must_remain_present": True,
        "phase_a_receipt_sha256": phase_a_sha,
        "signed_byte_preview_sha256": "REPLACE_WITH_PHASE_B_PREVIEW_SHA256",
        "signed_transaction_identity_sha256": signed_identity_sha,
        "runtime_manifest_sha256": contract.sha256, "tool_sha256": tool_sha(),
        "shared_primitive_sha256": BASE_SHA256, "source_commit": SOURCE_COMMIT,
        "source_tree": SOURCE_TREE, "fee_cap_blk": f"{PER_NODE_CAP:.8f}",
        "prior_readonly_receipt_sha256": PRIOR_READONLY_RECEIPT_SHA256,
        "effective_user_order": USER_ORDER, "user_order_sha256": USER_ORDER_SHA256,
        "allow_fresh_plan_rebind_for_exact_signed_bytes": True,
        "acknowledgements": {"fee_and_conflict_risk": True, "broadcast_is_irreversible": True,
            "independently_computed_fee_and_same_script_proof_reviewed": True,
            "durable_exact_byte_relay_authority_survives_restart_or_rpc_response_loss": True,
            "confirmation_may_permanently_forfeit_revalidating_qqp2_quantum_payout": True,
            "missing_rpc_result_cannot_reconstruct_original_acknowledged_plan_on_v30_1_4": True,
            "free_claim_pause_preserved": True, "ordinary_pow_remains_disabled": True,
            "no_generic_transaction_rpc": True}}
    digest = publish_json(run_dir / "phase-b-preview.json", receipt)
    print(json.dumps({"result": receipt["result"], "phase_b_preview_sha256": digest}, sort_keys=True))


def phase_b_context(run_dir: pathlib.Path, args: argparse.Namespace) -> tuple[Any, ...]:
    contract = load_contract(run_dir)
    phase_a, phase_a_sha = load_phase_a(run_dir, contract)
    preview, preview_sha = load_phase_b_preview(run_dir, contract, phase_a_sha)
    authority, authority_sha = base.parse_secure_json(pathlib.Path(args.authority),
                                                      "Phase-B authority", args.authority_sha256)
    phase_b_authority(authority, contract, phase_a_sha, preview_sha,
                      preview["signed_transaction_identity_sha256"])
    return contract, phase_a, phase_a_sha, preview, preview_sha, authority_sha


def phase_b_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    base.ensure_secure_dir(run_dir)
    contract, phase_a, phase_a_sha, preview, preview_sha, authority_sha = phase_b_context(run_dir, args)
    transport = Transport(contract.runtime)
    node = contract.runtime.nodes[0]
    with mutation_locks(contract) as lock_ids:
        if (run_dir / "phase-b.json").exists():
            load_phase_b_complete(run_dir, contract, phase_a_sha, preview,
                                  preview_sha, authority_sha)
            die("Phase-B completion already exists; refusing replay")
        pause_before = free_claim_snapshot(contract)
        exact_node, runtime_before = pin_node(transport, node)
        if runtime_before != preview["runtime"]:
            die("node30 runtime differs from the separately authorized Phase-B preview")
        intent_path = run_dir / "phase-b-intent-node30.json"
        ack_path = run_dir / "phase-b-ack-node30.json"
        if intent_path.exists():
            intent, intent_sha = load_run_receipt(run_dir, intent_path.name)
            validate_phase_b_intent(intent, contract, phase_a_sha, preview_sha,
                                    authority_sha, preview)
            if not ack_path.exists():
                die("node30 has an unmatched Phase-B intent without an RPC acknowledgement; reconcile and never retry")
            ack, ack_sha = load_phase_b_ack(run_dir, contract, intent_sha, authority_sha)
            result, digest = finalize_phase_b_from_ack(
                run_dir, contract, phase_a, phase_a_sha, preview, preview_sha, authority_sha,
                intent, intent_sha, ack, ack_sha, transport, exact_node, node,
                runtime_before, pause_before, lock_ids)
            print(json.dumps({"result": result, "phase_b_or_observation_sha256": digest}, sort_keys=True))
            return
        role_before = role_snapshot(transport, exact_node, True)
        state = observe_phase_b_state(transport, exact_node, phase_a, preview)
        if state["state"] != "PERSISTED_DRAFT" or state.get("relay_authorized") is not False or state.get("in_mempool") is not False:
            die("node30 is not the exact nonrelayable Phase-B draft")
        same_wallet_inventory(role_before["wallet_inventory"], state["role"]["wallet_inventory"],
                              "node30 Phase-B pre-mutation")
        same_runtime_identity(runtime_before, state["role"]["runtime"],
                              "node30 Phase-B pre-mutation")
        fresh_component = state["component"]
        fresh_evidence = state["signed_evidence"]
        intent = {"schema": RECEIPT_SCHEMA, "contract": CONTRACT, "kind": "node30-phase-b-intent",
                  "node": NODE, "action": "commit_and_broadcast", "phase_a_sha256": phase_a_sha,
                  "signed_byte_preview_sha256": preview_sha, "authority_sha256": authority_sha,
                  "tool_sha256": tool_sha(), "shared_primitive_sha256": BASE_SHA256,
                  "runtime_manifest_sha256": contract.sha256,
                  "signed_transaction_identity_sha256": preview["signed_transaction_identity_sha256"],
                  "plan_id": state["plan_id"], "active_tip": state["tip"],
                  "active_height": state["height"],
                  "wallet_generation": state["role"]["recovery"].get("wallet_generation",
                                      preview["wallet_generation"]),
                  "component": fresh_component, "signed_evidence": fresh_evidence,
                  "runtime": runtime_before, "wallet_inventory": role_before["wallet_inventory"],
                  "role_before": role_before, "free_claim_before": pause_before,
                  "created_at": base.utc_now()}
        # The current preview, not verbose recovery inventory, is authoritative
        # for wallet_generation. Re-read it without mutation to bind that exact value.
        _, fresh_preview, fresh_action = stable_preview(
            transport, exact_node, "reuse_managed", {"reuse_managed"})
        same_stable_component(preview["component"], fresh_action,
                              "node30 final pre-mutation Phase-B cut")
        final_evidence = signed_evidence(transport, exact_node, fresh_action, True)
        same_signed_identity(preview["signed_evidence"], final_evidence,
                             "node30 final pre-mutation Phase-B cut")
        intent.update({"plan_id": fresh_preview["plan_id"], "active_tip": fresh_preview["active_tip"],
                       "active_height": fresh_preview["active_height"],
                       "wallet_generation": fresh_preview["wallet_generation"],
                       "component": component_identity(fresh_action),
                       "signed_evidence": final_evidence})
        intent_sha = publish_json(intent_path, intent)
        options = {"action": "commit_and_broadcast", "expected_plan_id": intent["plan_id"],
                   "acknowledge_fee_and_conflict_risk": True,
                   "max_fee_per_resolution": f"{PER_NODE_CAP:.8f}",
                   "max_total_fee": f"{PER_NODE_CAP:.8f}"}
        try:
            execution = transport.rpc(exact_node, "resolveallshadowpowclaims", options)
        except base.RpcError:
            die("node30 Phase-B outcome is indeterminate after durable intent; reconcile and never retry")
        # This exact return value is the first durable operation after the RPC.
        # No wallet, chain, runtime, or Free-Claim read may precede it.
        ack = base_receipt("node30-retained-claim-phase-b-rpc-ack", contract)
        ack.update({"intent_sha256": intent_sha, "phase_b_authority_sha256": authority_sha,
                    "rpc_method": "resolveallshadowpowclaims", "rpc_action": "commit_and_broadcast",
                    "rpc_response": execution, "published_before_post_call_reads": True})
        ack_sha = publish_json(ack_path, ack)
        result, digest = finalize_phase_b_from_ack(
            run_dir, contract, phase_a, phase_a_sha, preview, preview_sha, authority_sha,
            intent, intent_sha, ack, ack_sha, transport, exact_node, node,
            runtime_before, pause_before, lock_ids)
    print(json.dumps({"result": result, "phase_b_or_observation_sha256": digest}, sort_keys=True))


def reconcile_b_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    base.ensure_secure_dir(run_dir)
    contract, phase_a, phase_a_sha, preview, preview_sha, authority_sha = phase_b_context(run_dir, args)
    transport = Transport(contract.runtime)
    node = contract.runtime.nodes[0]
    with mutation_locks(contract) as lock_ids:
        if (run_dir / "phase-b.json").exists():
            receipt, digest = load_phase_b_complete(run_dir, contract, phase_a_sha,
                                                    preview, preview_sha, authority_sha)
            print(json.dumps({"result": receipt["result"], "phase_b_sha256": digest}, sort_keys=True))
            return
        intent_path = run_dir / "phase-b-intent-node30.json"
        if not intent_path.exists():
            die("node30 has no Phase-B intent to reconcile")
        intent, intent_sha = load_run_receipt(run_dir, intent_path.name)
        validate_phase_b_intent(intent, contract, phase_a_sha, preview_sha, authority_sha, preview)
        pause_before = free_claim_snapshot(contract)
        exact_node, runtime_before = pin_node(transport, node)
        ack_path = run_dir / "phase-b-ack-node30.json"
        if ack_path.exists():
            ack, ack_sha = load_phase_b_ack(run_dir, contract, intent_sha, authority_sha)
            result, digest = finalize_phase_b_from_ack(
                run_dir, contract, phase_a, phase_a_sha, preview, preview_sha, authority_sha,
                intent, intent_sha, ack, ack_sha, transport, exact_node, node,
                runtime_before, pause_before, lock_ids)
            print(json.dumps({"result": result, "phase_b_or_observation_sha256": digest}, sort_keys=True))
            return
        state = observe_phase_b_state(transport, exact_node, phase_a, preview)
        same_wallet_inventory(intent["wallet_inventory"], state["role"]["wallet_inventory"],
                              "node30 Phase-B reconciliation")
        if state["state"] == "ACTIVE_CHAIN_CLEARED":
            status = "ACTIVE_CHAIN_CLEARED_BUT_ACKNOWLEDGED_PLAN_UNATTRIBUTABLE"
        elif state.get("relay_authorized") is True:
            status = "EXACT_BYTES_RELAY_AUTHORIZED_BUT_ACKNOWLEDGED_PLAN_UNATTRIBUTABLE"
        else:
            status = "NO_RELAY_AUTHORITY_OBSERVED_NEW_PREVIEW_AND_AUTHORITY_REQUIRED"
        if free_claim_snapshot(contract) != pause_before or transport.runtime_snapshot(node) != runtime_before:
            die("node30 runtime or Free-Claim pause changed during Phase-B reconciliation")
        receipt = base_receipt("node30-retained-claim-phase-b-reconcile", contract)
        receipt.update({"result": "OBSERVATION_ONLY_NOT_ADMISSIBLE_AS_PHASE_B_COMPLETION",
                        "observed_status": status, "mutation_performed": False,
                        "phase_a_receipt_sha256": phase_a_sha,
                        "signed_byte_preview_sha256": preview_sha,
                        "phase_b_authority_sha256": authority_sha,
                        "intent_sha256": intent_sha,
                        "never_retry_after_unmatched_phase_b_intent": True,
                        "installed_v30_1_4_blocker":
                            "durable metadata omits consumed acknowledged plan receipt",
                        "observation": state})
        name = f"phase-b-reconcile-{time.time_ns()}.json"
        digest = publish_json(run_dir / name, receipt)
    print(json.dumps({"result": receipt["result"], "observed_status": status,
                      "reconcile_sha256": digest, "receipt": name}, sort_keys=True))


def monitor_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    base.ensure_secure_dir(run_dir)
    contract = load_contract(run_dir)
    audit, audit_sha = load_audit(run_dir, contract)
    phase_a, phase_a_sha = load_phase_a(run_dir, contract)
    transport = Transport(contract.runtime)
    node = contract.runtime.nodes[0]
    exact_node, runtime_before = pin_node(transport, node)
    role = role_snapshot(transport, exact_node, False)
    component = audit["node_state"]["component"]
    signed = phase_a["node_result"]["signed_evidence"]
    confirmed: list[dict[str, Any]] = []
    anchor = component["anchor"]
    anchor_utxo = transport.rpc(exact_node, "gettxout", anchor["txid"], anchor["vout"], False)
    if anchor_utxo is None:
        confirmed = confirmed_component_spenders(transport, exact_node, component, signed)
    blockers = role["recovery"].get("blocking_quarantined_claims")
    cleared = anchor_utxo is None and len(confirmed) == 1 and blockers == 0
    receipt = base_receipt("node30-retained-claim-operational-monitor", contract)
    receipt.update({"result": "RETAINED_CLAIM_CLEARED_ROLE_PRESERVED" if cleared else "NOT_YET_CONFIRMED",
                    "mutation_performed": False, "audit_receipt_sha256": audit_sha,
                    "phase_a_receipt_sha256": phase_a_sha, "anchor_spent_on_active_chain": anchor_utxo is None,
                    "confirmed_component_transactions": confirmed, "blocking_quarantined_claims": blockers,
                    "ordinary_pow_disabled": role["ordinary_pow"], "pos": role["pos"],
                    "free_claim": free_claim_snapshot(contract),
                    "free_claim_worker_invoked": False, "pause_marker_removed": False})
    if transport.runtime_snapshot(node) != runtime_before:
        die("node30 runtime changed across the confirmation monitor")
    name = f"monitor-{time.time_ns()}.json"
    digest = publish_json(run_dir / name, receipt)
    print(json.dumps({"result": receipt["result"], "receipt": name, "sha256": digest}, sort_keys=True))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    audit = commands.add_parser("audit")
    audit.add_argument("--runtime-manifest", required=True)
    audit.add_argument("--run-dir", required=True)
    audit.set_defaults(func=audit_command)
    for name, func in [("phase-a", phase_a_command), ("reconcile-a", reconcile_a_command),
                       ("phase-b", phase_b_command), ("reconcile-b", reconcile_b_command)]:
        item = commands.add_parser(name)
        item.add_argument("--run-dir", required=True)
        item.add_argument("--authority", required=True)
        item.add_argument("--authority-sha256", required=True)
        item.set_defaults(func=func)
    preview = commands.add_parser("phase-b-preview")
    preview.add_argument("--run-dir", required=True)
    preview.set_defaults(func=phase_b_preview_command)
    monitor = commands.add_parser("monitor")
    monitor.add_argument("--run-dir", required=True)
    monitor.set_defaults(func=monitor_command)
    return result


def main(argv: Sequence[str] | None = None) -> int:
    os.umask(0o077)
    for name in ["PYTHONPATH", "PYTHONHOME", "BASH_ENV", "ENV", "CDPATH"]:
        os.environ.pop(name, None)
    args = parser().parse_args(argv)
    try:
        args.func(args)
    except (base.GateError, GateError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
