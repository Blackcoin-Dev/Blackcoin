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


CONTRACT = "installed-v30.1.4-node30-retained-claim-recovery/v1"
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

# The shared signed fleet primitive remains a hash-pinned dependency.  This
# node30 package supplies its own runtime, role, authority and receipt schemas.
BASE_RELATIVE = pathlib.Path("../v30.1.4-fleet31-recovery/fleet31_recovery.py")
BASE_SHA256 = "b97f239569be4d9bb8bdb43163c3ef25fa9f7bba276d2ace835d93264e0ff518"
TEST_TRANSPORT_SHA256 = "a385c803e42467eeb110e69d779760d68ca63d1d1983ba9bf16e173db140ec7c"


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
    if not isinstance(raw, dict) or raw.get("schema") != 1 or raw.get("kind") != "node30-installed-v30.1.4-runtime-contract":
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
        if allow_relay and isinstance(preview, dict) and isinstance(preview.get("actions"), list) and len(preview["actions"]) == 1:
            # The signed-draft validator intentionally rejects any relay state.
            # Validate every other field on a deep copy, then separately type
            # and bind the original relay/mempool booleans below.
            preview_for_validation = json.loads(json.dumps(preview))
            preview_for_validation["actions"][0]["relay_authorized"] = False
            preview_for_validation["actions"][0]["in_mempool"] = False
        else:
            preview_for_validation = preview
        base.validate_preview(preview_for_validation, NODE, allowed)
        preview = original_preview
        action = preview["actions"][0]
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
    if (not isinstance(wallet, dict) or wallet.get("private_keys_enabled") is not True or
            wallet.get("external_signer", False) is not False or wallet.get("scanning", False) is not False or
            wallet.get("unlocked_staking_only") is not False or not isinstance(wallet.get("unlocked_until"), int) or
            wallet["unlocked_until"] <= int(time.time())):
        die("node30 wallet is not normally unlocked")
    if (not isinstance(staking, dict) or staking.get("enabled") is not True or
            staking.get("staking") is not True or base.decimal_amount(staking.get("weight", 0), "PoS weight") <= 0):
        die("node30 PoS is not active with positive weight")
    if (not isinstance(mining, dict) or mining.get("enabled") is not False or
            mining.get("state") != "disabled" or base.decimal_amount(mining.get("hashrate", 0), "PoW hashrate") != 0):
        die("node30 ordinary-PoW-disabled role changed")
    if (not isinstance(recovery, dict) or recovery.get("chain_ready") is not True or
            recovery.get("wallet_tip_matches") is not True or recovery.get("database_outcome_ambiguous") is not False):
        die("node30 recovery inventory is incoherent")
    if require_blocker and (recovery.get("blocking_quarantined_claims") != 1 or
                            mining.get("blocking_quarantined_claims") != 1):
        die("node30 does not have exactly one retained-claim blocker")
    return {"runtime": runtime, "chain": {"height": chain["blocks"], "tip": chain["bestblockhash"]},
            "peers": peers, "wallet": {"txcount": wallet.get("txcount"),
            "unlocked_until": wallet["unlocked_until"]},
            "pos": {"enabled": True, "staking": True, "weight": staking.get("weight")},
            "ordinary_pow": {"enabled": False, "state": "disabled", "hashrate": mining.get("hashrate")},
            "recovery": recovery}


def pin_node(transport: Any, node: Any) -> tuple[Any, dict[str, Any]]:
    runtime = transport.runtime_snapshot(node)
    container_id = require_hex64(runtime.get("container_id"), "node30 container id")
    return base.RuntimeNode(NODE, node.service, container_id, node.wallet), runtime


def component_identity(action: dict[str, Any]) -> dict[str, Any]:
    return base.component_identity(action)


def signed_transaction(transport: Any, node: Any, action: dict[str, Any]) -> dict[str, Any]:
    return base.signed_transaction(transport, node, action)


def tool_sha() -> str:
    return _sha256_file(pathlib.Path(__file__).resolve(strict=True))


def base_receipt(kind: str, contract: Contract) -> dict[str, Any]:
    return {"schema": 1, "contract": CONTRACT, "kind": kind, "created_at": base.utc_now(),
            "tool_sha256": tool_sha(), "shared_primitive_sha256": BASE_SHA256,
            "installed_source": {"commit": SOURCE_COMMIT, "tree": SOURCE_TREE,
                                 "signer_fingerprint": SOURCE_SIGNER},
            "runtime_manifest_sha256": contract.sha256, "node": NODE, "role": "free_claim",
            "ordinary_pow_must_remain_disabled": True,
            "free_claim_pause_must_remain_present": True,
            "fee_cap_blk": f"{PER_NODE_CAP:.8f}",
            "prior_readonly_receipt_sha256": PRIOR_READONLY_RECEIPT_SHA256,
            "user_order_sha256": USER_ORDER_SHA256}


def load_contract(run_dir: pathlib.Path) -> Contract:
    _, digest = base.load_run_receipt(run_dir, "runtime-manifest.json")
    return validate_manifest(run_dir / "runtime-manifest.json", digest)


@contextlib.contextmanager
def mutation_locks(contract: Contract) -> Iterator[list[dict[str, Any]]]:
    paths = [*contract.runtime.lock_paths, contract.raw["node_lock_path"]]
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
                               "mode": format(stat.S_IMODE(st.st_mode), "03o")})
        yield identities
    finally:
        for fd in reversed(fds):
            with contextlib.suppress(OSError):
                fcntl.flock(fd, fcntl.LOCK_UN)
            with contextlib.suppress(OSError):
                os.close(fd)


def common_authority(authority: Any, kind: str, action: str, contract: Contract) -> dict[str, Any]:
    if not isinstance(authority, dict) or authority.get("schema") != 1 or authority.get("kind") != kind:
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
    base.publish_bytes(run_dir / "runtime-manifest.json",
                       base.owned_secure_file(contract.path, "runtime manifest", contract.sha256))
    pause_before = free_claim_snapshot(contract)
    transport = base.Transport(contract.runtime)
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
        row["signed_transaction"] = signed_transaction(transport, exact_node, action)
    if transport.runtime_snapshot(node) != runtime_before:
        die("node30 runtime changed across the read-only audit")
    receipt = base_receipt("node30-retained-claim-recovery-audit", contract)
    receipt.update({"mutation_performed": False, "result": "READY_FOR_SEPARATE_PHASE_A_AUTHORITY",
                    "stable_tip": chain["bestblockhash"], "stable_height": chain["blocks"], "node_state": row})
    receipt["required_phase_a_authority"] = {
        "schema": 1, "kind": "node30-retained-claim-phase-a-authority", "decision": "authorize",
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
    digest = base.publish_json(run_dir / "audit.json", receipt)
    print(json.dumps({"result": receipt["result"], "audit_sha256": digest}, sort_keys=True))


def same_component(audit: dict[str, Any], action: dict[str, Any]) -> None:
    if component_identity(action) != audit["node_state"]["component"]:
        die("node30 component/fee/output changed from the authority-bound audit")


def phase_a_complete(run_dir: pathlib.Path, contract: Contract, audit_sha: str,
                     authority_sha: str, lock_ids: list[dict[str, Any]]) -> str:
    row, row_sha = base.load_run_receipt(run_dir, "phase-a-node30.json")
    if row.get("status") not in {"SIGNED_AND_PERSISTED", "ALREADY_SIGNED_NONRELAY"}:
        die("node30 lacks a conclusive nonrelayable Phase-A result")
    receipt = base_receipt("node30-retained-claim-phase-a-complete", contract)
    receipt.update({"result": "SIGNED_WITHOUT_RELAY_AUTHORITY", "mutation_performed": True,
                    "relay_or_broadcast_authorized": False, "audit_receipt_sha256": audit_sha,
                    "phase_a_authority_sha256": authority_sha, "node_result_sha256": row_sha,
                    "node_result": row, "lock_identities": lock_ids})
    return base.publish_json(run_dir / "phase-a.json", receipt)


def phase_a_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    base.ensure_secure_dir(run_dir)
    contract = load_contract(run_dir)
    audit, audit_sha = base.load_run_receipt(run_dir, "audit.json")
    authority, authority_sha = base.parse_secure_json(pathlib.Path(args.authority), "Phase-A authority", args.authority_sha256)
    phase_a_authority(authority, contract, audit_sha)
    transport = base.Transport(contract.runtime)
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
        intent = {"schema": 1, "contract": CONTRACT, "kind": "node30-phase-a-intent",
                  "action": "sign_only", "audit_sha256": audit_sha, "authority_sha256": authority_sha,
                  "tool_sha256": tool_sha(), "runtime_manifest_sha256": contract.sha256,
                  "plan_id": fresh["plan_id"], "active_tip": fresh["active_tip"],
                  "active_height": fresh["active_height"], "wallet_generation": fresh["wallet_generation"],
                  "component": component_identity(action), "role_before": role_before,
                  "free_claim_before": pause_before, "created_at": base.utc_now()}
        intent_sha = base.publish_json(run_dir / "phase-a-intent-node30.json", intent)
        if action["status"] == "reuse_managed":
            signed = signed_transaction(transport, exact_node, action)
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
            signed = signed_transaction(transport, exact_node, action)
            _, persisted_preview, persisted_action = stable_preview(
                transport, exact_node, "reuse_managed", {"reuse_managed"})
            persisted_signed = signed_transaction(transport, exact_node, persisted_action)
            if (component_identity(persisted_action) != component_identity(action) or
                    persisted_signed != signed or persisted_action.get("relay_authorized") is not False or
                    persisted_action.get("in_mempool") is not False):
                die("node30 Phase-A post-call durable draft differs from the acknowledged exact bytes")
            status, mutated = "SIGNED_AND_PERSISTED", True
        role_after = role_snapshot(transport, exact_node, True)
        pause_after = free_claim_snapshot(contract)
        if (pause_after != pause_before or role_after["ordinary_pow"] != role_before["ordinary_pow"] or
                transport.runtime_snapshot(node) != runtime_before):
            die("node30 pause or ordinary-PoW role changed during Phase A")
        row = {"schema": 1, "contract": CONTRACT, "kind": "node30-phase-a-result",
               "node": NODE, "status": status, "intent_sha256": intent_sha,
               "fresh_plan": {"plan_id": fresh["plan_id"], "tip": fresh["active_tip"],
                              "height": fresh["active_height"], "wallet_generation": fresh["wallet_generation"]},
               "fee_blk": f"{PER_NODE_CAP:.8f}", "component": component_identity(action),
               "signed_transaction": signed, "role_after": role_after,
               "free_claim_after": pause_after, "relay_authority_granted": 0,
               "broadcast": 0, "mutation_performed": mutated,
               "durable_state_ambiguous": False, "created_at": base.utc_now()}
        base.publish_json(run_dir / "phase-a-node30.json", row)
        digest = phase_a_complete(run_dir, contract, audit_sha, authority_sha, lock_ids)
    print(json.dumps({"result": "SIGNED_WITHOUT_RELAY_AUTHORITY", "phase_a_sha256": digest}, sort_keys=True))


def reconcile_a_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    base.ensure_secure_dir(run_dir)
    contract = load_contract(run_dir)
    audit, audit_sha = base.load_run_receipt(run_dir, "audit.json")
    authority, authority_sha = base.parse_secure_json(pathlib.Path(args.authority), "Phase-A authority", args.authority_sha256)
    phase_a_authority(authority, contract, audit_sha)
    transport = base.Transport(contract.runtime)
    node = contract.runtime.nodes[0]
    with mutation_locks(contract) as lock_ids:
        if (run_dir / "phase-a-node30.json").exists():
            row, _ = base.load_run_receipt(run_dir, "phase-a-node30.json")
            result = row.get("status")
        elif not (run_dir / "phase-a-intent-node30.json").exists():
            result = "NO_PHASE_A_INTENT"
        else:
            intent, intent_sha = base.load_run_receipt(run_dir, "phase-a-intent-node30.json")
            exact_node, runtime_before = pin_node(transport, node)
            _, fresh, action = stable_preview(transport, exact_node, "reuse_managed", {"ready", "reuse_managed"})
            same_component(audit, action)
            if action["status"] == "reuse_managed":
                signed = signed_transaction(transport, exact_node, action)
                row = {"schema": 1, "contract": CONTRACT, "kind": "node30-phase-a-result",
                       "node": NODE, "status": "SIGNED_AND_PERSISTED", "intent_sha256": intent_sha,
                       "reconciled_after_missing_rpc_result": True,
                       "fresh_plan": {"plan_id": fresh["plan_id"], "tip": fresh["active_tip"],
                                      "height": fresh["active_height"], "wallet_generation": fresh["wallet_generation"]},
                       "fee_blk": f"{PER_NODE_CAP:.8f}", "component": component_identity(action),
                       "signed_transaction": signed, "role_after": role_snapshot(transport, exact_node, True),
                       "free_claim_after": free_claim_snapshot(contract), "relay_authority_granted": 0,
                       "broadcast": 0, "mutation_performed": "unknown", "durable_state_ambiguous": False,
                       "created_at": base.utc_now()}
                base.publish_json(run_dir / "phase-a-node30.json", row)
                result = "SIGNED_AND_PERSISTED"
            else:
                result = "NO_MUTATION_OBSERVED_NEW_AUDIT_AND_AUTHORITY_REQUIRED"
        receipt = base_receipt("node30-retained-claim-phase-a-reconcile", contract)
        receipt.update({"result": result, "mutation_performed": False,
                        "audit_receipt_sha256": audit_sha, "phase_a_authority_sha256": authority_sha})
        reconcile_sha = base.publish_json(run_dir / "phase-a-reconcile.json", receipt)
        phase_a_sha = None
        if result in {"SIGNED_AND_PERSISTED", "ALREADY_SIGNED_NONRELAY"} and not (run_dir / "phase-a.json").exists():
            phase_a_sha = phase_a_complete(run_dir, contract, audit_sha, authority_sha, lock_ids)
    print(json.dumps({"result": result, "reconcile_sha256": reconcile_sha,
                      "phase_a_sha256": phase_a_sha}, sort_keys=True))


def phase_b_preview_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    base.ensure_secure_dir(run_dir)
    contract = load_contract(run_dir)
    phase_a, phase_a_sha = base.load_run_receipt(run_dir, "phase-a.json")
    row = phase_a.get("node_result")
    if not isinstance(row, dict) or row.get("status") not in {"SIGNED_AND_PERSISTED", "ALREADY_SIGNED_NONRELAY"}:
        die("node30 Phase-A completion is not exact")
    pause_before = free_claim_snapshot(contract)
    transport = base.Transport(contract.runtime)
    node = contract.runtime.nodes[0]
    exact_node, runtime_before = pin_node(transport, node)
    role = role_snapshot(transport, exact_node, True)
    _, preview, action = stable_preview(transport, exact_node, "reuse_managed", {"reuse_managed"})
    signed = signed_transaction(transport, exact_node, action)
    if signed != row.get("signed_transaction") or signed["confirmations"] != 0:
        die("node30 signed bytes differ from Phase A or are already confirmed")
    pause_after = free_claim_snapshot(contract)
    if pause_after != pause_before or transport.runtime_snapshot(node) != runtime_before:
        die("node30 Free-Claim pause changed during Phase-B preview")
    signed_identity_sha = base.sha256_bytes(base.canonical_json(signed))
    receipt = base_receipt("node30-retained-claim-phase-b-preview", contract)
    receipt.update({"result": "READY_FOR_SEPARATE_PHASE_B_AUTHORITY", "mutation_performed": False,
                    "phase_a_receipt_sha256": phase_a_sha, "plan_id": preview["plan_id"],
                    "active_tip": preview["active_tip"], "active_height": preview["active_height"],
                    "wallet_generation": preview["wallet_generation"], "component": component_identity(action),
                    "signed_transaction": signed, "signed_transaction_identity_sha256": signed_identity_sha,
                    "role": role, "free_claim": pause_after})
    receipt["required_phase_b_authority"] = {
        "schema": 1, "kind": "node30-retained-claim-phase-b-authority", "decision": "authorize",
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
            "durable_exact_byte_relay_authority_survives_restart_or_rpc_response_loss": True,
            "confirmation_may_permanently_forfeit_revalidating_qqp2_quantum_payout": True,
            "missing_rpc_result_cannot_reconstruct_original_acknowledged_plan_on_v30_1_4": True,
            "free_claim_pause_preserved": True, "ordinary_pow_remains_disabled": True,
            "no_generic_transaction_rpc": True}}
    digest = base.publish_json(run_dir / "phase-b-preview.json", receipt)
    print(json.dumps({"result": receipt["result"], "phase_b_preview_sha256": digest}, sort_keys=True))


def phase_b_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    base.ensure_secure_dir(run_dir)
    contract = load_contract(run_dir)
    phase_a, phase_a_sha = base.load_run_receipt(run_dir, "phase-a.json")
    preview_receipt, preview_sha = base.load_run_receipt(run_dir, "phase-b-preview.json")
    authority, authority_sha = base.parse_secure_json(pathlib.Path(args.authority), "Phase-B authority", args.authority_sha256)
    phase_b_authority(authority, contract, phase_a_sha, preview_sha,
                      preview_receipt["signed_transaction_identity_sha256"])
    transport = base.Transport(contract.runtime)
    node = contract.runtime.nodes[0]
    with mutation_locks(contract) as lock_ids:
        if (run_dir / "phase-b.json").exists() or (run_dir / "phase-b-node30.json").exists():
            die("Phase-B result already exists; refusing replay")
        if (run_dir / "phase-b-intent-node30.json").exists():
            die("node30 has an unmatched Phase-B intent; run reconcile-b and never retry")
        pause_before = free_claim_snapshot(contract)
        exact_node, runtime_before = pin_node(transport, node)
        role_before = role_snapshot(transport, exact_node, True)
        _, fresh, action = stable_preview(transport, exact_node, "reuse_managed", {"reuse_managed"})
        signed = signed_transaction(transport, exact_node, action)
        if (component_identity(action) != preview_receipt["component"] or
                signed != preview_receipt["signed_transaction"]):
            die("node30 fresh Phase-B plan differs from the separately authorized exact signed bytes")
        intent = {"schema": 1, "contract": CONTRACT, "kind": "node30-phase-b-intent",
                  "node": NODE, "action": "commit_and_broadcast", "phase_a_sha256": phase_a_sha,
                  "signed_byte_preview_sha256": preview_sha, "authority_sha256": authority_sha,
                  "tool_sha256": tool_sha(), "runtime_manifest_sha256": contract.sha256,
                  "plan_id": fresh["plan_id"], "active_tip": fresh["active_tip"],
                  "active_height": fresh["active_height"], "wallet_generation": fresh["wallet_generation"],
                  "component": component_identity(action), "signed_transaction": signed,
                  "role_before": role_before, "free_claim_before": pause_before,
                  "created_at": base.utc_now()}
        intent_sha = base.publish_json(run_dir / "phase-b-intent-node30.json", intent)
        options = {"action": "commit_and_broadcast", "expected_plan_id": fresh["plan_id"],
                   "acknowledge_fee_and_conflict_risk": True,
                   "max_fee_per_resolution": f"{PER_NODE_CAP:.8f}",
                   "max_total_fee": f"{PER_NODE_CAP:.8f}"}
        try:
            execution = transport.rpc(exact_node, "resolveallshadowpowclaims", options)
        except base.RpcError:
            die("node30 Phase-B outcome is indeterminate after durable intent; run reconcile-b and never retry")
        required = {"action": "commit_and_broadcast", "acknowledged_plan_id": fresh["plan_id"],
                    "acknowledged_active_tip": fresh["active_tip"],
                    "acknowledged_active_height": fresh["active_height"],
                    "acknowledged_wallet_generation": fresh["wallet_generation"],
                    "plan_consumed": True, "plan_reusable": False, "success": True,
                    "stale_plan": False, "durable_state_ambiguous": False,
                    "relay_deferred": 0, "relay_complete": True}
        for key, expected in required.items():
            if execution.get(key) != expected:
                die(f"node30 Phase-B result {key} changed; never retry")
        exact_amount(execution.get("acknowledged_total_fee"), PER_NODE_CAP, "Phase-B acknowledged fee")
        if not isinstance(execution.get("actions"), list) or len(execution["actions"]) != 1:
            die("node30 Phase-B result lacks exactly one action")
        result_action = execution["actions"][0]
        if (component_identity(result_action) != preview_receipt["component"] or
                result_action.get("resolution_txid") != signed["resolution_txid"] or
                result_action.get("persisted") is not True or result_action.get("relay_authorized") is not True or
                result_action.get("status") not in {"broadcast", "already_in_mempool"} or
                execution.get("broadcast", 0) + execution.get("already_in_mempool", 0) != 1):
            die("node30 Phase-B did not relay exactly the authorized signed bytes")
        _, post_preview, post_action = stable_preview(
            transport, exact_node, "reuse_managed", {"reuse_managed"}, True)
        post_signed = signed_transaction(transport, exact_node, post_action)
        if (component_identity(post_action) != preview_receipt["component"] or
                post_signed != signed or post_action.get("relay_authorized") is not True or
                post_action.get("in_mempool") is not True):
            die("node30 exact signed bytes lack post-call durable relay and mempool evidence")
        pause_after = free_claim_snapshot(contract)
        role_after = role_snapshot(transport, exact_node, True)
        if (pause_after != pause_before or role_after["ordinary_pow"] != role_before["ordinary_pow"] or
                transport.runtime_snapshot(node) != runtime_before):
            die("node30 pause or ordinary-PoW role changed during Phase B")
        row = {"schema": 1, "contract": CONTRACT, "kind": "node30-phase-b-result",
               "node": NODE, "status": "EXACT_PLAN_ACKNOWLEDGED_AND_RELAYED",
               "intent_sha256": intent_sha, "acknowledged_plan_id": execution["acknowledged_plan_id"],
               "acknowledged_active_tip": execution["acknowledged_active_tip"],
               "acknowledged_active_height": execution["acknowledged_active_height"],
               "acknowledged_wallet_generation": execution["acknowledged_wallet_generation"],
               "acknowledged_total_fee": f"{PER_NODE_CAP:.8f}", "component": component_identity(result_action),
               "signed_transaction": signed, "relay_authority_granted": execution.get("relay_authority_granted"),
               "broadcast": execution.get("broadcast"), "already_in_mempool": execution.get("already_in_mempool"),
               "role_after": role_after, "free_claim_after": pause_after,
               "mutation_performed": True, "confirmation_claimed": False,
               "durable_state_ambiguous": False, "created_at": base.utc_now()}
        row_sha = base.publish_json(run_dir / "phase-b-node30.json", row)
        receipt = base_receipt("node30-retained-claim-phase-b-complete", contract)
        receipt.update({"result": "EXACT_PLAN_ACKNOWLEDGED_AND_RELAYED", "mutation_performed": True,
                        "phase_a_receipt_sha256": phase_a_sha, "signed_byte_preview_sha256": preview_sha,
                        "phase_b_authority_sha256": authority_sha, "node_result_sha256": row_sha,
                        "node_result": row, "lock_identities": lock_ids,
                        "confirmation_or_free_claim_success_claimed": False})
        digest = base.publish_json(run_dir / "phase-b.json", receipt)
    print(json.dumps({"result": receipt["result"], "phase_b_sha256": digest}, sort_keys=True))


def reconcile_b_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    base.ensure_secure_dir(run_dir)
    contract = load_contract(run_dir)
    _, phase_a_sha = base.load_run_receipt(run_dir, "phase-a.json")
    preview, preview_sha = base.load_run_receipt(run_dir, "phase-b-preview.json")
    authority, authority_sha = base.parse_secure_json(pathlib.Path(args.authority), "Phase-B authority", args.authority_sha256)
    phase_b_authority(authority, contract, phase_a_sha, preview_sha,
                      preview["signed_transaction_identity_sha256"])
    transport = base.Transport(contract.runtime)
    node = contract.runtime.nodes[0]
    with mutation_locks(contract):
        if (run_dir / "phase-b-node30.json").exists():
            row, _ = base.load_run_receipt(run_dir, "phase-b-node30.json")
            result = row.get("status")
            observation = {"status": result}
        elif not (run_dir / "phase-b-intent-node30.json").exists():
            result = "NO_PHASE_B_INTENT"
            observation = {"status": result}
        else:
            intent, intent_sha = base.load_run_receipt(run_dir, "phase-b-intent-node30.json")
            exact_node, runtime_before = pin_node(transport, node)
            _, fresh, action = stable_preview(transport, exact_node, "reuse_managed", {"reuse_managed"}, True)
            signed = signed_transaction(transport, exact_node, action)
            if component_identity(action) != preview["component"] or signed != preview["signed_transaction"]:
                die("node30 reconciliation sees different signed bytes")
            if action.get("relay_authorized") is True or action.get("in_mempool") is True:
                result = "EXACT_BYTES_RELAY_AUTHORIZED_BUT_ACKNOWLEDGED_PLAN_UNATTRIBUTABLE"
            else:
                result = "NO_RELAY_AUTHORITY_OBSERVED_NEW_PREVIEW_AND_AUTHORITY_REQUIRED"
            observation = {"status": result, "intent_sha256": intent_sha,
                           "current_plan_id": fresh["plan_id"], "signed_transaction": signed,
                           "durable_relay_authorized": action.get("relay_authorized"),
                           "in_mempool": action.get("in_mempool"),
                           "role": role_snapshot(transport, exact_node, True),
                           "free_claim": free_claim_snapshot(contract)}
        receipt = base_receipt("node30-retained-claim-phase-b-reconcile", contract)
        receipt.update({"result": "OBSERVATION_ONLY_NOT_ADMISSIBLE_AS_PHASE_B_COMPLETION",
                        "observed_status": result, "mutation_performed": False,
                        "phase_a_receipt_sha256": phase_a_sha,
                        "signed_byte_preview_sha256": preview_sha,
                        "phase_b_authority_sha256": authority_sha,
                        "never_retry_after_unmatched_phase_b_intent": True,
                        "installed_v30_1_4_blocker": "durable metadata omits consumed acknowledged plan receipt",
                        "observation": observation})
        digest = base.publish_json(run_dir / "phase-b-reconcile.json", receipt)
    print(json.dumps({"result": receipt["result"], "reconcile_sha256": digest}, sort_keys=True))


def monitor_command(args: argparse.Namespace) -> None:
    run_dir = pathlib.Path(args.run_dir)
    base.ensure_secure_dir(run_dir)
    contract = load_contract(run_dir)
    audit, audit_sha = base.load_run_receipt(run_dir, "audit.json")
    phase_a, phase_a_sha = base.load_run_receipt(run_dir, "phase-a.json")
    transport = base.Transport(contract.runtime)
    node = contract.runtime.nodes[0]
    exact_node, runtime_before = pin_node(transport, node)
    role = role_snapshot(transport, exact_node, False)
    component = audit["node_state"]["component"]
    signed = phase_a["node_result"]["signed_transaction"]
    candidates = [signed["resolution_txid"], *component.get("claim_txids", [])]
    confirmed: list[dict[str, Any]] = []
    for txid in candidates:
        try:
            tx = transport.rpc(exact_node, "gettransaction", txid, False, True)
        except base.RpcError:
            continue
        if isinstance(tx, dict) and isinstance(tx.get("confirmations"), int) and tx["confirmations"] > 0 and isinstance(tx.get("blockhash"), str):
            header = transport.rpc(exact_node, "getblockheader", tx["blockhash"])
            if isinstance(header, dict) and header.get("confirmations", 0) > 0:
                confirmed.append({"txid": txid, "confirmations": tx["confirmations"],
                                  "blockhash": tx["blockhash"]})
    anchor = component["anchor"]
    anchor_utxo = transport.rpc(exact_node, "gettxout", anchor["txid"], anchor["vout"], False)
    blockers = role["recovery"].get("blocking_quarantined_claims")
    cleared = anchor_utxo is None and bool(confirmed) and blockers == 0
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
    digest = base.publish_json(run_dir / name, receipt)
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
