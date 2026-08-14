#!/usr/bin/env python3
"""Offline hostile tests for the normal-unlock helper rotation transaction."""

import copy
import hashlib
import importlib.util
import json
import os
import py_compile
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path


PACKAGE = Path(__file__).resolve().parents[1]
MODULE_PATH = PACKAGE / "helper_rotation.py"
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("helper_rotation", MODULE_PATH)
ROTATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ROTATION)
UID = os.geteuid()
GID = os.getegid()
COUNT = 0


def ok(condition, description):
    global COUNT
    COUNT += 1
    if not condition:
        raise AssertionError(f"not ok {COUNT:03d} - {description}")
    print(f"ok {COUNT:03d} - {description}")


def rejects(callable_value, description):
    try:
        callable_value()
    except Exception:
        ok(True, description)
    else:
        ok(False, description)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_secure(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(mode)
    return path


@contextmanager
def synthetic_identities():
    names = (
        "PREDECESSOR_HELPER_SHA256", "SUCCESSOR_HELPER_SHA256",
        "PREDECESSOR_SUPERVISOR_SHA256", "SUCCESSOR_SUPERVISOR_SHA256",
        "SUPERVISOR_REWRITES",
    )
    saved = {name: getattr(ROTATION, name) for name in names}
    old_helper = b"old-helper-exact\n"
    new_helper = b"new-helper-node30-and-unnamed\n"
    old_supervisor = (
        b"#!/bin/bash\nblackcoin_node_normal_unlock.sh\n"
        b"ACTIVE_HELPER_PIN=old\nHISTORICAL_JOB10=preserved\n"
    )
    rewrites = ((b"ACTIVE_HELPER_PIN=old", b"ACTIVE_HELPER_PIN=new"),)
    new_supervisor = old_supervisor.replace(*rewrites[0])
    ROTATION.PREDECESSOR_HELPER_SHA256 = sha(old_helper)
    ROTATION.SUCCESSOR_HELPER_SHA256 = sha(new_helper)
    ROTATION.PREDECESSOR_SUPERVISOR_SHA256 = sha(old_supervisor)
    ROTATION.SUCCESSOR_SUPERVISOR_SHA256 = sha(new_supervisor)
    ROTATION.SUPERVISOR_REWRITES = rewrites
    try:
        yield old_helper, new_helper, old_supervisor, new_supervisor
    finally:
        for name, value in saved.items():
            setattr(ROTATION, name, value)


def historical_contract(old_sha):
    return ROTATION.canonical_json_bytes({
        "schema": 1,
        "kind": ROTATION.HISTORICAL_JOB10_KIND,
        "installed_or_executed_by_this_package": False,
        "historical_receipt_is_read_only": True,
        "preflight": {"normal_unlock_helper_sha256": old_sha},
    })


def fixture(root, old_helper, old_supervisor, include_history=True):
    root = Path(root)
    root.mkdir(mode=0o700)
    helper = write_secure(root / "blackcoin_node_normal_unlock.sh", old_helper)
    supervisor = write_secure(root / ROTATION.SUPERVISOR_BASENAME, old_supervisor, 0o700)
    history = None
    if include_history:
        history = write_secure(root / "job-10-one-shot-contract.json",
                               historical_contract(ROTATION.PREDECESSOR_HELPER_SHA256))
    return helper, supervisor, history


def snapshot(node, active):
    pow_enabled = node != 30
    return {
        "node": node,
        "container": ROTATION.container_for_node(node),
        "wallet_selector_sha256": sha(("" if node == 30 else f"wallet-{node}").encode()),
        "wallet_unnamed": node == 30,
        "chain": {"chain": "main", "blocks": 100, "headers": 100,
                  "bestblockhash": "a" * 64, "chainwork": "b" * 64,
                  "initialblockdownload": False},
        "network_version": ROTATION.EXPECTED_NETWORK_VERSION,
        "subversion": ROTATION.EXPECTED_SUBVERSION,
        "connections": 3,
        "unlocked_until": 200000 if active else 0,
        "unlocked_staking_only": False if active else None,
        "wallet_scanning": False,
        "pos_enabled": active,
        "pos_staking": active,
        "pos_weight": 1 if active else 0,
        "pow_policy": {
            "enabled": pow_enabled, "autostart": pow_enabled, "threads": 1,
            "cpu_percent": 10, "payout_address": "q", "state": "claim_quarantined",
            "claim_quarantined": node != 30, "blocking_quarantined_claims": 1 if node != 30 else 0,
            "pending_manual_resolutions": 0, "allow_automatic_quantum_key_creation": False,
        },
        "pow_hashrate": 0,
        "quantum_inventory_sha256": "c" * 64,
    }


class FakeRuntime:
    def __init__(self, fail_node=None):
        self.invoked = []
        self.fail_node = fail_node

    def capture(self, node):
        return snapshot(node, node in self.invoked)

    def invoke_helper(self, node):
        self.invoked.append(node)
        if node == self.fail_node:
            raise ROTATION.RotationError(f"injected node {node} failure")
        return {"node": node, "exit_code": 0, "stdout_sha256": "d" * 64,
                "stderr_sha256": "e" * 64}


class PreflightFailureRuntime:
    def capture(self, node):
        raise ROTATION.RotationError(f"injected preflight failure at node {node}")

    def invoke_helper(self, node):
        raise AssertionError(f"helper unexpectedly invoked at node {node}")


class DummyLocks:
    def __init__(self, log=None, label="fleet"):
        self.handles = [1]
        self.log = log if log is not None else []
        self.label = label

    def acquire(self):
        if self.handles:
            raise ROTATION.RotationError("dummy lock already held")
        self.handles = [1]
        self.log.append(("acquire", self.label))
        return self

    def release(self):
        if self.handles:
            self.log.append(("release", self.label))
        self.handles = []

    def __enter__(self):
        if not self.handles:
            self.acquire()
        self.log.append(("enter", self.label))
        return self

    def __exit__(self, *_unused):
        self.log.append(("exit", self.label))
        self.release()


def test_static_contract():
    helper = (PACKAGE / "blackcoin_node_normal_unlock.sh").read_bytes()
    tool = MODULE_PATH.read_text(encoding="utf-8")
    ok(sha(helper) == "aa924baf0a9d384759019d50e3815e03e264b906c7b51ecc76023c854b91a3e7",
       "payload helper has the exact signed successor identity")
    ok(b"^([1-9]|[12][0-9]|3[0-2])$" in helper, "helper accepts the complete 1..32 range")
    ok(helper.count(b'[[ -z "$wallet" ]] || rpc_args+=("-rpcwallet=$wallet")') == 2,
       "both helper RPC paths omit the selector for the unnamed wallet")
    ok(b"-stdinwalletpassphrase" in helper, "wallet passphrase remains stdin-only")
    for forbidden in (b"setpowmining", b"sendrawtransaction", b"sendtoaddress", b"walletnotify"):
        ok(forbidden not in helper.lower(), f"helper excludes {forbidden.decode()} action")
    for forbidden in ("setpowmining\"", "sendrawtransaction\"", "createshadowpowclaimresolution\""):
        ok(forbidden not in tool.lower(), f"rotation tool excludes {forbidden[:-2]} mutation RPC")
    ok(ROTATION.HELPER_ORDER[0] == 30 and len(ROTATION.HELPER_ORDER) == 32,
       "node30 is the first and unique canary")
    ok(set(ROTATION.HELPER_ORDER) == set(range(1, 33)), "helper order covers every node exactly once")
    ok(ROTATION.VERIFICATION_ORDER == tuple(range(1, 33)), "terminal verification is sequential 1..32")
    ok(len(ROTATION.SHARED_LOCKS) == 6 and len(set(ROTATION.SHARED_LOCKS)) == 6,
       "canonical shared lock set is complete and unique")
    ok(len(ROTATION.RUNTIME_LOCKS) == 32 and len(set(ROTATION.RUNTIME_LOCKS)) == 32,
       "all 32 canonical node runtime locks are present")
    ok("/boot/config/plugins/blackcoin-quantum-nodes" == str(ROTATION.STATE_ROOT),
       "installed state root is fixed")
    with tempfile.TemporaryDirectory() as temporary:
        py_compile.compile(str(MODULE_PATH), cfile=str(Path(temporary) / "helper_rotation.pyc"), doraise=True)
    ok(True, "rotation Python compiles")
    result = subprocess.run(["bash", "-n", str(PACKAGE / "blackcoin_node_normal_unlock.sh")], check=False)
    ok(result.returncode == 0, "payload helper passes bash syntax")


def test_rpc_argv_and_bounds():
    empty = ROTATION.wallet_rpc_argv("c", "", "listwallets")
    named = ROTATION.wallet_rpc_argv("c", "wallet one", "getwalletinfo")
    named_stdin = ROTATION.wallet_rpc_argv("c", "wallet one", "walletpassphrase", stdin=True)
    ok(not any(value.startswith("-rpcwallet=") for value in empty),
       "unnamed wallet RPC omits -rpcwallet entirely")
    ok(named.count("-rpcwallet=wallet one") == 1, "named wallet remains one exact argv element")
    ok(named_stdin[2] == "-i" and named_stdin.count("-rpcwallet=wallet one") == 1,
       "stdin named-wallet RPC retains selector and Docker stdin")
    for node in range(1, 33):
        ok(ROTATION.container_for_node(node) == ("blackcoin-v4-gui" if node == 1 else f"blackcoin-v4-gui-{node}"),
           f"node {node} maps to its exact container")
    for node in (0, 33, -1, 100):
        rejects(lambda node=node: ROTATION.container_for_node(node), f"node bound rejects {node}")


def test_production_supervisor_transform():
    successor_path = PACKAGE.parent / "v30.1.5-rollout-durability" / ROTATION.SUPERVISOR_BASENAME
    successor = successor_path.read_bytes()
    ok(sha(successor) == ROTATION.SUCCESSOR_SUPERVISOR_SHA256,
       "repository supervisor has the exact signed successor identity")
    predecessor = successor
    for before, after in reversed(ROTATION.SUPERVISOR_REWRITES):
        ok(predecessor.count(after) == 1, "successor semantic anchor is unique")
        predecessor = predecessor.replace(after, before, 1)
    ok(sha(predecessor) == ROTATION.PREDECESSOR_SUPERVISOR_SHA256,
       "reverse semantic transform reconstructs the exact installed predecessor")
    transformed = ROTATION.rotate_supervisor_bytes(predecessor)
    ok(transformed == successor, "forward transform reproduces exact signed successor bytes")
    ok(transformed.count(ROTATION.PREDECESSOR_HELPER_SHA256.encode()) == 1,
       "successor supervisor preserves the predecessor only for historical job10")
    ok(transformed.count(ROTATION.SUCCESSOR_HELPER_SHA256.encode()) == 1,
       "successor supervisor pins the active corrected helper exactly once")
    mutated = bytearray(predecessor)
    mutated[-1] ^= 1
    rejects(lambda: ROTATION.rotate_supervisor_bytes(bytes(mutated)),
            "supervisor transform rejects any predecessor byte drift")


def test_scan_and_authority():
    with synthetic_identities() as (old_helper, new_helper, old_supervisor, new_supervisor):
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / "state"
            helper, supervisor, history = fixture(state, old_helper, old_supervisor)
            plan = ROTATION.scan_plan(state, helper, UID)
            ok(plan["state"] == "READY", "exact predecessor state is mutation-ready")
            ok(len(plan["active_consumers"]) == 1, "only the exact active supervisor is selected")
            ok(len(plan["historical_job10_refs"]) == 1, "historical job10 is classified separately")
            ok(not plan["unsupported_refs"], "exact fixture has no unsupported pin references")
            row = plan["active_consumers"][0]
            ok(row["sha256"] == sha(old_supervisor) and row["after_sha256"] == sha(new_supervisor),
               "plan binds exact supervisor before and after identities")
            ok(row["preserves_historical_helper_identity"] is True,
               "active-consumer plan explicitly preserves historical identity")
            ok(ROTATION.sha256_file(history) == sha(historical_contract(ROTATION.PREDECESSOR_HELPER_SHA256)),
               "historical receipt baseline is exact")
            package = {"manifest_sha256": "1" * 64, "tool_sha256": "2" * 64}
            plan_sha = sha(ROTATION.canonical_json_bytes(plan))
            authority = ROTATION.authority_template(plan, plan_sha, package)
            authority.update({
                "state": "authorized", "authority_nonce": "3" * 32,
                "authorization_context_sha256": "4" * 64,
                "issued_at_epoch": 100, "expires_at_epoch": 200,
                "live_helper_rotation_authorized": True,
                "active_consumer_rotation_authorized": True,
                "normal_unlock_node30_canary_authorized": True,
                "normal_unlock_fleet_authorized": True,
                "rollback_authorized": True,
            })
            ok(ROTATION.validate_authority(authority, plan, plan_sha, package, now=150),
               "exact fresh authority validates")
            mutations = {
                "state": "NOT_AUTHORIZED", "authority_nonce": "0" * 32,
                "authorization_context_sha256": "0" * 64, "issued_at_epoch": 151,
                "expires_at_epoch": 150, "tool_sha256": "9" * 64,
                "plan_sha256": "9" * 64, "successor_helper_sha256": "9" * 64,
                "live_helper_rotation_authorized": False,
                "active_consumer_rotation_authorized": False,
                "normal_unlock_node30_canary_authorized": False,
                "normal_unlock_fleet_authorized": False, "rollback_authorized": False,
                "helper_order": list(range(1, 33)), "historical_job10_immutable": False,
            }
            for key, value in mutations.items():
                candidate = copy.deepcopy(authority)
                candidate[key] = value
                rejects(lambda candidate=candidate: ROTATION.validate_authority(
                    candidate, plan, plan_sha, package, now=150), f"authority rejects mutated {key}")
            extra = copy.deepcopy(authority)
            extra["extra"] = True
            rejects(lambda: ROTATION.validate_authority(extra, plan, plan_sha, package, now=150),
                    "authority rejects an extra key")
            missing = copy.deepcopy(authority)
            del missing["plan_sha256"]
            rejects(lambda: ROTATION.validate_authority(missing, plan, plan_sha, package, now=150),
                    "authority rejects a missing key")

            write_secure(state / "unknown.txt", ROTATION.PREDECESSOR_HELPER_SHA256.encode())
            blocked = ROTATION.scan_plan(state, helper, UID)
            ok(blocked["state"] == "BLOCKED" and len(blocked["unsupported_refs"]) == 1,
               "unknown predecessor reference fails closed")
            (state / "unknown.txt").unlink()
            helper.write_bytes(new_helper)
            supervisor.write_bytes(new_supervisor)
            current = ROTATION.scan_plan(state, helper, UID)
            ok(current["state"] == "ALREADY_INSTALLED", "exact successor state is idempotently recognized")
            helper.write_bytes(b"unknown-helper\n")
            unknown = ROTATION.scan_plan(state, helper, UID)
            ok(unknown["state"] == "BLOCKED", "unknown helper identity fails closed")


def test_transaction_success_and_rollback():
    # Use one explicit synthetic identity context per transaction so global
    # constants are restored even when the transaction intentionally fails.
    with synthetic_identities() as (old_helper, new_helper, old_supervisor, new_supervisor):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            helper, supervisor, history = fixture(base / "state", old_helper, old_supervisor)
            history_sha = ROTATION.sha256_file(history)
            plan = ROTATION.scan_plan(base / "state", helper, UID)
            run_dir = base / "run"
            run_dir.mkdir(mode=0o700)
            payload = write_secure(base / "payload", new_helper)
            runtime = FakeRuntime()
            locks = DummyLocks([])
            result = ROTATION.execute_transaction(
                plan, runtime, run_dir, locks, lambda paths: DummyLocks([], str(paths[0])),
                {"authority_sha256": "1" * 64}, payload, UID, now_function=lambda: 100000,
            )
            ok(result["status"] == "PASS", "complete transaction returns PASS")
            ok(runtime.invoked == list(ROTATION.HELPER_ORDER), "helper execution is node30-first and exact")
            ok(helper.read_bytes() == new_helper, "success installs exact successor helper")
            ok(supervisor.read_bytes() == new_supervisor, "success rotates exact active supervisor")
            ok(ROTATION.sha256_file(history) == history_sha, "success leaves historical job10 byte-identical")
            ok((run_dir / "RESULT.json").exists() and (run_dir / "RESULT.json.sha256").exists(),
               "success publishes immutable JSON and digest receipts")
            result_disk = json.loads((run_dir / "RESULT.json").read_text())
            ok(result_disk["helper_attempts"][0]["node"] == 30 and
               result_disk["helper_attempts"][0]["status"] == "PASS",
               "success receipt identifies the node30 canary")
            ok(result_disk["historical_job10_unchanged"] is True,
               "success receipt attests historical immutability")
            ok(len(result_disk["helper_attempts"]) == 32,
               "success receipt contains all 32 helper attempts")

    with synthetic_identities() as (old_helper, new_helper, old_supervisor, _new_supervisor):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            helper, supervisor, history = fixture(base / "state", old_helper, old_supervisor)
            history_sha = ROTATION.sha256_file(history)
            plan = ROTATION.scan_plan(base / "state", helper, UID)
            run_dir = base / "run"
            run_dir.mkdir(mode=0o700)
            payload = write_secure(base / "payload", new_helper)
            runtime = FakeRuntime(fail_node=30)
            locks = DummyLocks([])
            rejects(lambda: ROTATION.execute_transaction(
                plan, runtime, run_dir, locks, lambda paths: DummyLocks([], str(paths[0])),
                {"authority_sha256": "1" * 64}, payload, UID, now_function=lambda: 100000,
            ), "node30 canary failure aborts the transaction")
            ok(runtime.invoked == [30], "node30 failure prevents every later node helper")
            ok(helper.read_bytes() == old_helper and supervisor.read_bytes() == old_supervisor,
               "node30 failure restores helper and active consumer predecessors")
            ok(ROTATION.sha256_file(history) == history_sha, "rollback leaves historical job10 byte-identical")
            failure = json.loads((run_dir / "FAILURE.json").read_text())
            ok(failure["status"] == "ROLLED_BACK" and failure["rollback"]["performed"] is True,
               "node30 failure receipt proves rollback")
            ok(failure["helper_attempted_nodes"] == [30], "failure receipt includes failed canary attempt")

    with synthetic_identities() as (old_helper, new_helper, old_supervisor, _new_supervisor):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            helper, supervisor, history = fixture(base / "state", old_helper, old_supervisor)
            plan = ROTATION.scan_plan(base / "state", helper, UID)
            run_dir = base / "run"
            run_dir.mkdir(mode=0o700)
            payload = write_secure(base / "payload", new_helper)
            runtime = FakeRuntime()
            locks = DummyLocks([])
            original_atomic = ROTATION.atomic_write
            injection = {"fired": False}

            def injected(path, data, *args, **kwargs):
                if (not injection["fired"] and Path(path).name == "blackcoin_node_normal_unlock.sh" and
                        kwargs.get("replace") is True):
                    injection["fired"] = True
                    raise OSError("injected helper write failure")
                return original_atomic(path, data, *args, **kwargs)

            ROTATION.atomic_write = injected
            try:
                rejects(lambda: ROTATION.execute_transaction(
                    plan, runtime, run_dir, locks, lambda paths: DummyLocks([], str(paths[0])),
                    {"authority_sha256": "1" * 64}, payload, UID, now_function=lambda: 100000,
                ), "mid-apply helper write failure aborts the transaction")
            finally:
                ROTATION.atomic_write = original_atomic
            ok(supervisor.read_bytes() == old_supervisor and helper.read_bytes() == old_helper,
               "mid-apply failure restores the already-replaced consumer")
            ok(not runtime.invoked, "mid-apply failure invokes no wallet helper")
            failure = json.loads((run_dir / "FAILURE.json").read_text())
            ok(failure["status"] == "ROLLED_BACK", "mid-apply failure has a rolled-back receipt")

    with synthetic_identities() as (old_helper, new_helper, old_supervisor, _new_supervisor):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            helper, supervisor, _history = fixture(base / "state", old_helper, old_supervisor)
            plan = ROTATION.scan_plan(base / "state", helper, UID)
            run_dir = base / "run"
            run_dir.mkdir(mode=0o700)
            payload = write_secure(base / "payload", new_helper)
            rejects(lambda: ROTATION.execute_transaction(
                plan, PreflightFailureRuntime(), run_dir, DummyLocks([]),
                lambda paths: DummyLocks([], str(paths[0])), {"authority_sha256": "1" * 64},
                payload, UID, now_function=lambda: 100000,
            ), "preflight failure aborts before mutation")
            preflight_failure = json.loads((run_dir / "FAILURE.json").read_text())
            ok(preflight_failure["changed_paths"] == [] and preflight_failure["status"] == "FAILED",
               "preflight failure receipt proves zero changed paths")
            ok(preflight_failure["historical_job10_unchanged"] is True,
               "preflight failure truthfully preserves historical evidence")
            ok(not (run_dir / "BACKUP-MANIFEST.json").exists(),
               "preflight failure requires no nonexistent backup manifest")


def test_lockset_and_file_security():
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        root.chmod(0o700)
        paths = tuple(root / f"lock-{number}" for number in range(3))
        locks = ROTATION.LockSet(paths, UID).acquire()
        ok(len(locks.handles) == 3, "lock set acquires every requested lock")
        rejects(lambda: ROTATION.LockSet((paths[0],), UID).acquire(), "contended canonical lock fails closed")
        locks.release()
        ok(not locks.handles, "lock set releases every descriptor")
        bad = write_secure(root / "bad-lock", b"", 0o644)
        rejects(lambda: ROTATION.LockSet((bad,), UID).acquire(), "unsafe lock mode is rejected")
        regular = write_secure(root / "regular", b"bytes")
        ok(ROTATION.secure_regular(regular, UID, (0o600,)).st_nlink == 1,
           "secure-file verifier accepts exact owner/mode/link identity")
        regular.chmod(0o644)
        rejects(lambda: ROTATION.secure_regular(regular, UID, (0o600,)),
                "secure-file verifier rejects broader permissions")


def main():
    print("TAP version 13")
    test_static_contract()
    test_rpc_argv_and_bounds()
    test_production_supervisor_transform()
    test_scan_and_authority()
    test_transaction_success_and_rollback()
    test_lockset_and_file_security()
    print(f"1..{COUNT}")
    print(f"PASS: {COUNT} offline helper-rotation assertions")


if __name__ == "__main__":
    main()
