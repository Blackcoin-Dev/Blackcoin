#!/usr/bin/python3
"""Offline wrapper for deterministic rejection/requeue companion tests."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import subprocess
import sys


FIXTURE = pathlib.Path(os.environ["FLEET31_FIXTURE"])
SCENARIO = os.environ.get("FLEET31_SCENARIO", "cleared")
ORIGINAL = pathlib.Path(__file__).resolve(strict=True).with_name("mock_transport.py")
MEMPOOL_TXID = hashlib.sha256(b"occupied-shadow-proof-slot").hexdigest()
TARGET_SCRIPT = "76a914" + "9" * 40 + "88ac"
PAYOUT_SCRIPT = "6020" + "8" * 64


def state_path() -> pathlib.Path:
    return FIXTURE / "state.json"


def load_state() -> dict:
    if state_path().exists():
        return json.loads(state_path().read_text())
    return {"claim": False, "confirmed": False, "send_calls": 0,
            "listunspent_calls": 0}


def save_state(value: dict) -> None:
    tmp = state_path().with_suffix(".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True) + "\n")
    tmp.replace(state_path())


def proof_hex() -> str:
    target = bytes.fromhex(TARGET_SCRIPT)
    payout = bytes.fromhex(PAYOUT_SCRIPT)
    return (b"QQSPROOF" + b"QQP2" + b"\x00" + (101).to_bytes(8, "little") +
            len(target).to_bytes(2, "little") + target +
            len(payout).to_bytes(2, "little") + payout).hex()


def proof_script() -> str:
    proof = bytes.fromhex(proof_hex())
    return "6a4c" + f"{len(proof):02x}" + proof.hex()


def rpc_method(args: list[str]) -> str | None:
    if args[:1] != ["exec"] or len(args) < 4:
        return None
    rest = args[3:]
    while rest and rest[0].startswith("-"):
        rest = rest[1:]
    return rest[0] if rest else None


def log(args: list[str]) -> None:
    with (FIXTURE / "transport.log").open("a") as handle:
        handle.write(json.dumps(args, separators=(",", ":")) + "\n")


def create_race_target(kind: str) -> None:
    fixture_root = FIXTURE.parent.resolve(strict=True)
    done = fixture_root / "free-claim" / "done"
    queue = fixture_root / "free-claim" / "queue"
    if kind == "terminal":
        sources = list(done.glob("*.uncertain.json"))
        if len(sources) != 1:
            raise RuntimeError("terminal race has no exact uncertain source")
        target = done / (sources[0].name[:-len(".uncertain.json")] + ".rejected.json")
    elif kind == "requeue":
        sources = list(done.glob("*.rejected.json"))
        if len(sources) != 1:
            raise RuntimeError("requeue race has no exact rejected source")
        target = queue / (sources[0].name[:-len(".rejected.json")] + ".json")
    else:
        raise RuntimeError("unknown lifecycle race kind")
    parent = target.parent.resolve(strict=True)
    allowed = {(fixture_root / "free-claim" / name).resolve(strict=True)
               for name in ["queue", "done"]}
    if not target.is_absolute() or parent not in allowed or target.name in {"", ".", ".."}:
        raise RuntimeError("race target is outside the offline lifecycle fixture")
    try:
        fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o644)
    except FileExistsError:
        return
    try:
        os.write(fd, b'{"hostile":"destination-appeared"}\n')
        os.fsync(fd)
    finally:
        os.close(fd)
    parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)


def delegate(args: list[str]) -> int:
    completed = subprocess.run(
        [str(ORIGINAL), *args], stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        env={**os.environ, "FLEET31_SCENARIO": "happy"}, check=False)
    sys.stdout.write(completed.stdout)
    sys.stderr.write(completed.stderr)
    return completed.returncode


def main() -> int:
    args = sys.argv[1:]
    method = rpc_method(args)
    if method == "sendshadowpowclaim" and SCENARIO == "mempool-reject":
        log(args)
        state = load_state()
        state["send_calls"] = state.get("send_calls", 0) + 1
        save_state(state)
        print("error code: -26", file=sys.stderr)
        print("error message:", file=sys.stderr)
        print("Shadow PoW claim rejected: shadow-proof-mempool-limit", file=sys.stderr)
        return 1
    if method == "listtransactions" and SCENARIO == "terminal-target-race":
        state = load_state()
        state["terminal_race_listtransactions_calls"] = (
            state.get("terminal_race_listtransactions_calls", 0) + 1)
        save_state(state)
        if state["terminal_race_listtransactions_calls"] == 2:
            create_race_target("terminal")
    if method == "getrawmempool":
        log(args)
        if SCENARIO == "requeue-target-race":
            state = load_state()
            state["requeue_race_mempool_calls"] = (
                state.get("requeue_race_mempool_calls", 0) + 1)
            save_state(state)
            if state["requeue_race_mempool_calls"] == 4:
                create_race_target("requeue")
        print(json.dumps([MEMPOOL_TXID] if SCENARIO == "mempool-blocked" else [],
                         separators=(",", ":")))
        return 0
    if method == "getrawtransaction" and SCENARIO == "mempool-blocked":
        log(args)
        print(json.dumps({
            "txid": MEMPOOL_TXID,
            "vout": [{"n": 0, "value": "0.00000000",
                      "scriptPubKey": {"type": "nulldata",
                                       "hex": proof_script(),
                                       "asm": "OP_RETURN " + proof_hex()}}],
        }, sort_keys=True, separators=(",", ":")))
        return 0
    return delegate(args)


if __name__ == "__main__":
    raise SystemExit(main())
