#!/usr/bin/python3
"""Stateful offline transport for the preauthorized node30 edge executor."""

from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import sys


HERE = pathlib.Path(__file__).resolve(strict=True).parent
WRAPPED = HERE / "rejection_requeue_mock_transport.py"
spec = importlib.util.spec_from_file_location("edge_wrapped_transport", WRAPPED)
if spec is None or spec.loader is None:
    raise RuntimeError("cannot load wrapped offline transport")
wrapped = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = wrapped
spec.loader.exec_module(wrapped)
original_spec = importlib.util.spec_from_file_location(
    "edge_original_transport", HERE / "mock_transport.py")
if original_spec is None or original_spec.loader is None:
    raise RuntimeError("cannot load original offline transport")
original = importlib.util.module_from_spec(original_spec)
sys.modules[original_spec.name] = original
original_spec.loader.exec_module(original)


def custom_mempool(scenario: str) -> bool:
    if scenario not in {"edge-blocked-then-clear", "edge-refill-during-rebind"}:
        return False
    args = sys.argv[1:]
    method = wrapped.rpc_method(args)
    if method == "getrawmempool":
        wrapped.log(args)
        state = wrapped.load_state()
        calls = state.get("edge_mempool_calls", 0) + 1
        state["edge_mempool_calls"] = calls
        wrapped.save_state(state)
        # mempool_shadow_inventory brackets every observation with two reads;
        # keep each pair stable while changing state between observations.
        observation = (calls + 1) // 2
        occupied = ((scenario == "edge-blocked-then-clear" and observation <= 2) or
                    (scenario == "edge-refill-during-rebind" and
                     observation % 2 == 0))
        print(json.dumps([wrapped.MEMPOOL_TXID] if occupied else [],
                         separators=(",", ":")))
        return True
    if method == "getrawtransaction":
        wrapped.log(args)
        print(json.dumps({
            "txid": wrapped.MEMPOOL_TXID,
            "vout": [{"n": 0, "value": "0.00000000",
                      "scriptPubKey": {"type": "nulldata",
                                       "hex": wrapped.proof_script(),
                                       "asm": "OP_RETURN " + wrapped.proof_hex()}}],
        }, sort_keys=True, separators=(",", ":")))
        return True
    return False


def custom_send(scenario: str) -> bool:
    args = sys.argv[1:]
    if (wrapped.rpc_method(args) != "sendshadowpowclaim" or
            scenario not in {"edge-happy", "edge-blocked-then-clear",
                             "edge-refill-during-rebind", "edge-send-reject"}):
        return False
    wrapped.log(args)
    state = wrapped.load_state()
    # The source receipt chain contains exactly one earlier, definitively
    # rejected call.  This successor may make exactly one fresh call.
    if state.get("send_calls") != 1:
        print("edge mock requires exactly one prior rejected call", file=sys.stderr)
        return 91
    state["send_calls"] = 2
    wrapped.save_state(state)
    if scenario == "edge-send-reject":
        print("error code: -26", file=sys.stderr)
        print("error message:", file=sys.stderr)
        print("Shadow PoW claim rejected: shadow-proof-mempool-limit", file=sys.stderr)
        return True
    state["claim"] = True
    wrapped.save_state(state)
    original.SCENARIO = "happy"
    print(json.dumps(original.claim_result(), sort_keys=True, separators=(",", ":")))
    return True


def main() -> int:
    scenario = os.environ.get("FLEET31_SCENARIO", "edge-happy")
    if custom_mempool(scenario):
        return 0
    sent = custom_send(scenario)
    if sent is True:
        return 0
    if sent is not False:
        return int(sent)
    mapping = {
        "edge-happy": "cleared",
        "edge-send-reject": "mempool-reject",
        "edge-blocked-then-clear": "cleared",
        "edge-refill-during-rebind": "cleared",
    }
    wrapped.SCENARIO = mapping.get(scenario, scenario)
    return wrapped.main()


if __name__ == "__main__":
    raise SystemExit(main())
