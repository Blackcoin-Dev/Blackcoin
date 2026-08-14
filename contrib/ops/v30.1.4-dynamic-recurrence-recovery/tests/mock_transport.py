#!/usr/bin/python3
"""Subset-aware shim over the sealed fleet31 offline transport."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import subprocess
import sys


HERE = pathlib.Path(__file__).resolve(strict=True)
BASE = HERE.parent.parent.parent / "v30.1.4-fleet31-recovery" / "tests" / "mock_transport.py"
FIXTURE = pathlib.Path(os.environ["FLEET31_FIXTURE"])
FULL = tuple([*range(1, 30), 31, 32])
SCENARIO = os.environ.get("FLEET31_SCENARIO", "happy")
CLEAR_LIVE_SCENARIOS = {
    "clear-live-coherent", "clear-live-ready", "clear-live-zero-hash",
    "clear-live-blocker", "clear-live-ambiguous", "clear-live-wrong-class",
}


def h(label: str, node: int) -> str:
    return hashlib.sha256(f"{label}:{node}".encode()).hexdigest()


def node_from_container(container: str) -> int:
    if container == "blackcoin-v4-gui":
        return 1
    for node in FULL:
        if container in {h("container", node), h("container-restarted", node)}:
            return node
    return int(container.rsplit("-", 1)[1])


def blocked_set() -> set[int]:
    path = FIXTURE / "blocked_nodes.json"
    if not path.exists():
        return {5, 28}
    value = json.loads(path.read_text())
    if (not isinstance(value, list) or any(not isinstance(n, int) for n in value) or
            tuple(value) != tuple(sorted(set(value))) or any(n not in FULL for n in value)):
        raise SystemExit("invalid blocked_nodes.json")
    return set(value)


def method_and_node(args: list[str]) -> tuple[int | None, str | None]:
    if args[:1] != ["exec"] or len(args) < 4:
        return None, None
    node = node_from_container(args[1])
    rest = args[3:]
    while rest and rest[0].startswith("-"):
        rest = rest[1:]
    return node, rest[0] if rest else None


def observed_calls(node: int, method: str) -> int:
    """Count the sealed base mock's append-only transport observations."""
    path = FIXTURE / "transport.log"
    count = 0
    for line in path.read_text().splitlines():
        try:
            observed_node, observed_method = method_and_node(json.loads(line))
        except (json.JSONDecodeError, TypeError, ValueError):
            continue
        if observed_node == node and observed_method == method:
            count += 1
    return count


def passive_refusal(node: int, reason_code: str, classification: str) -> dict:
    return {
        "anchor": {"txid": h(f"{reason_code}-anchor", node), "vout": 0},
        "generation_fingerprint": h("generation", node),
        "component_fingerprint": h(f"{reason_code}-component", node),
        "classification": classification, "status": "refused",
        "claim_txids": [h(f"{reason_code}-claim", node)],
        "descendant_claims": 0, "fee": "0.00000000",
        "persisted": False, "relay_authorized": False, "in_mempool": False,
        "frontier_may_advance": False,
        "conflicts_with_revalidating_unbound_proof": False,
        "reason_code": reason_code,
        "reason": f"fixture passive {reason_code} refusal",
    }


def main() -> None:
    args = sys.argv[1:]
    base_env = dict(os.environ)
    if SCENARIO == "lost-sign-result-recovery-lag":
        base_env["FLEET31_SCENARIO"] = "lost-sign-result"
    proc = subprocess.run([sys.executable, str(BASE), *args],
                          stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, env=base_env,
                          check=False)
    if proc.returncode != 0:
        sys.stdout.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)
    node, method = method_and_node(args)
    if node is None:
        sys.stdout.write(proc.stdout)
        return
    blocked = node in blocked_set()
    handled = {"getpowmininginfo", "resolveallshadowpowclaims"}
    if (blocked and method == "getpowclaimrecoveryinfo" and
            SCENARIO == "lost-sign-result-recovery-lag" and
            observed_calls(node, method) == 3):
        marker = FIXTURE / "phase-a-recovery-lag-observed"
        fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                     getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            os.write(fd, b"inventory-cut-lagged\n")
            os.fsync(fd)
        finally:
            os.close(fd)
        value = json.loads(proc.stdout)
        value["active_tip"] = h("one-cut-behind", node)
        value["active_height"] -= 1
        print(json.dumps(value, sort_keys=True, separators=(",", ":")))
        return
    if blocked or method not in handled:
        sys.stdout.write(proc.stdout)
        return
    try:
        value = json.loads(proc.stdout)
    except json.JSONDecodeError:
        sys.stdout.write(proc.stdout)
        return
    if method == "getpowmininginfo":
        value.update({
            "enabled": True, "state": "ready", "hashrate": 42.5,
            "blocking_quarantined_claims": 0,
            "actionable_quarantined_claims": 0,
            "indeterminate_quarantined_claims": 0,
            "claim_recovery_database_outcome_ambiguous": False,
        })
        if node == 12 and SCENARIO in CLEAR_LIVE_SCENARIOS:
            value["state"] = "ready" if SCENARIO == "clear-live-ready" else "claim_in_flight"
            value["hashrate"] = 0 if SCENARIO == "clear-live-zero-hash" else 42.5
            value["blocking_quarantined_claims"] = 1 if SCENARIO == "clear-live-blocker" else 0
            value["claim_recovery_database_outcome_ambiguous"] = (
                SCENARIO == "clear-live-ambiguous")
    elif method == "resolveallshadowpowclaims":
        # Only previews occur on clear nodes. A mutation routed here is a
        # test failure, not an emulated behavior.
        rest = args[3:]
        while rest and rest[0].startswith("-"):
            rest = rest[1:]
        options = json.loads(rest[1]) if len(rest) > 1 else {}
        if options.get("action", "preview") != "preview":
            print(f"mutation routed to clear node{node}", file=sys.stderr)
            raise SystemExit(90)
        value.update({
            "total_fee": "0.00000000", "actionable_components": 0,
            "actions": [], "refused_components": 0, "refused": [],
        })
        if node == 12 and SCENARIO in CLEAR_LIVE_SCENARIOS:
            historical = [
                passive_refusal(node + index, "anchor-spent", "resolved_on_active_chain")
                for index in range(40)
            ]
            live_classification = (
                "live" if SCENARIO == "clear-live-wrong-class" else "indeterminate")
            value["refused"] = historical + [
                passive_refusal(node, "claim-live", live_classification)]
            value["refused_components"] = len(value["refused"])
    print(json.dumps(value, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
