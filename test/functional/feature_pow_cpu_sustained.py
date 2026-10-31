#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://opensource.org/license/mit/.
"""Sustain natural PoW jobs by confirming genuine claims on a separate staker.

Process CPU includes selection, proof preparation, RPC and block validation.
Accepted claims establish renewed work and restart recovery, not an exact duty
percentage. Exact completed active/wait periods require additional telemetry.
All wallets, keys, configuration and funds belong to the isolated regtest.
"""

from decimal import Decimal
import json
from pathlib import Path
import platform
import subprocess
import time

from feature_goldrush_pow_miner_e2e import GoldRushPowMinerE2ETest
from feature_pow_cpu_budget import PowCpuBudgetTest
from test_framework.authproxy import JSONRPCException
from test_framework.blocktools import COINBASE_MATURITY
from test_framework.test_framework import SkipTest
from test_framework.util import append_config, assert_equal

SYNTHETIC_PAY_TX_FEE = Decimal("0.002")  # BLK/kvB, normal wallet fee configuration.


class SustainedPowCpuTest(GoldRushPowMinerE2ETest):
    def add_options(self, parser):
        self.add_wallet_options(parser)
        parser.add_argument("--workers", type=int, choices=(1, 2), default=2)
        parser.add_argument("--cpu-percent", type=int, choices=(1, 60, 100), default=60)
        parser.add_argument("--sustained-seconds", type=int, default=180)
        parser.add_argument("--recovery-seconds", type=int, default=120)
        parser.add_argument("--minimum-claims", type=int, default=2)
        parser.add_argument("--max-claims", type=int, default=256)
        parser.add_argument("--minimum-work-periods", type=int, default=2)

    def set_test_params(self):
        super().set_test_params()
        self.num_nodes = 2
        self.extra_args[0] = [arg for arg in self.extra_args[0]
                              if not arg.startswith("-shadowgoldrushblocks=")]
        self.extra_args[0] += ["-shadowgoldrushblocks=10000", "-autostartstaking=0"]
        self.extra_args.append(list(self.extra_args[0]))

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()
        if platform.system() not in ("Darwin", "Linux"):
            raise SkipTest("Process CPU reader supports Darwin and Linux")

    def _set_mocktime(self, timestamp):
        self.mock_time = timestamp
        for node in self.nodes:
            node.setmocktime(timestamp)

    def _event(self, kind, **values):
        event = {"sequence": self.sequence, "event": kind,
                 "monotonic_seconds": time.monotonic() - self.run_start,
                 "phase": self.phase, **values}
        self.sequence += 1
        with self.events_path.open("a", encoding="utf8") as output:
            output.write(json.dumps(event, default=float) + "\n")

    def _resources(self):
        node = self.nodes[0]
        pid = node.process.pid
        resource = {"pid": pid, "process_cpu_seconds": PowCpuBudgetTest._process_cpu(self)}
        if platform.system() == "Linux":
            status = Path(f"/proc/{pid}/status").read_text().splitlines()
            entries = dict(line.split(":", 1) for line in status if ":" in line)
            resource["rss_bytes"] = int(entries["VmRSS"].split()[0]) * 1024
            resource["threads"] = int(entries["Threads"].strip())
            resource["open_fds"] = len(list(Path(f"/proc/{pid}/fd").iterdir()))
        else:
            resource["rss_bytes"] = int(subprocess.check_output(
                ["ps", "-p", str(pid), "-o", "rss="], text=True).strip()) * 1024
            resource["threads"] = None
            resource["open_fds"] = None
        return resource

    def _sample(self, wallet):
        info = self._get_info(wallet)
        resource = self._resources()
        self._event("sample", tip=self.nodes[0].getbestblockhash(),
                    height=self.nodes[0].getblockcount(), resource=resource,
                    telemetry=PowCpuBudgetTest._telemetry(info),
                    duty_cycle=info.get("duty_cycle"))
        return info, resource

    @staticmethod
    def _get_info(wallet):
        deadline = time.monotonic() + 5
        while True:
            try:
                return wallet.getpowmininginfo()
            except JSONRPCException as error:
                # The status RPC intentionally rejects a concurrently changed
                # recovery snapshot. Retry only that documented transient.
                if (error.error["code"] != -1 or "state changed" not in error.error["message"]
                        or time.monotonic() >= deadline):
                    raise
                time.sleep(0.05)

    def _duty_result(self, before, after):
        if before is None or after is None:
            return {"status": "inconclusive_missing_completed_period_telemetry"}
        assert_equal(before["session_id"], after["session_id"])
        assert_equal(after["cpu_percent"], self.options.cpu_percent)
        assert_equal(len(after["workers"]), self.options.workers)
        records = []
        for first, last in zip(before["workers"], after["workers"]):
            assert_equal(first["worker"], last["worker"])
            delta = {key: last[key] - first[key] for key in last if key != "worker"}
            assert all(value >= 0 for value in delta.values())
            total = (delta["completed_active_ns"] + delta["completed_explicit_wait_ns"]
                     + delta["completed_duty_wait_ns"])
            ratio = delta["completed_active_ns"] / total if total else None
            enough = delta["completed_work_periods"] >= self.options.minimum_work_periods
            within = ratio is not None and ratio <= self.options.cpu_percent / 100 + 0.000001
            records.append({"worker": last["worker"], "delta": delta,
                            "completed_active_fraction": ratio,
                            "sufficient_completed_work_periods": enough,
                            "within_completed_period_budget": within})
        return {"status": "completed_periods_passed" if all(
            record["sufficient_completed_work_periods"] and record["within_completed_period_budget"]
            for record in records) else "insufficient_or_over_budget_completed_periods",
                "workers": records}

    def _wait_for_claim_relay(self, claim):
        started = time.monotonic()
        relay_clock = self.mock_time
        self._event("relay_pending", txid=claim)
        while claim not in self.nodes[1].getrawmempool():
            elapsed = time.monotonic() - started
            if elapsed >= 30:
                self._event("relay_timeout", txid=claim,
                            miner_mempool=self.nodes[0].getrawmempool(),
                            staker_mempool=self.nodes[1].getrawmempool())
                raise AssertionError("Natural claim did not relay to the staker within30 seconds")
            # Transaction INV scheduling uses mocktime. A blocking ordinary
            # sync_mempools call would freeze that clock and its Poisson timer.
            # Advance only the test clocks; no raw transaction is injected.
            self._set_mocktime(max(self.mock_time, relay_clock + 1 + int(elapsed * 8)))
            time.sleep(0.2)
        assert_equal(set(self.nodes[0].getrawmempool()), set(self.nodes[1].getrawmempool()))
        self._event("claim_relayed", txid=claim, wall_seconds=time.monotonic() - started)

    def _phase(self, wallet, staker, duration):
        node, stake_node = self.nodes
        start = time.monotonic()
        initial = self._resources()
        before_duty = self._get_info(wallet).get("duty_cycle")
        accepted = []
        samples = 0
        eligible = 0
        hashing = 0
        next_sample = start
        while time.monotonic() - start < duration:
            # Wall-based increments keep hashrate publication meaningful;
            # kernel search may advance mocktime farther, and never rolls back.
            self._set_mocktime(max(self.mock_time, self.phase_mock + int(time.monotonic() - start)))
            if time.monotonic() >= next_sample:
                info, _ = self._sample(wallet)
                assert_equal(info["enabled"], True)
                assert_equal(info["threads"], self.options.workers)
                assert_equal(info["cpu_percent"], self.options.cpu_percent)
                assert_equal(info["workers_error"], 0)
                assert_equal(info["epoch_active"], True)
                samples += 1
                eligible += bool(info["mining_gate_can_submit"])
                hashing += info["workers_hashing"] > 0
                next_sample = time.monotonic() + 2
            claims = self._pow_claim_txids()
            if claims:
                if len(accepted) == self.options.max_claims:
                    self._event("claim_limit_reached", limit=self.options.max_claims)
                    raise AssertionError("Claim safety cap reached before the observation ended; no sustained-window pass")
                claim = claims[0]
                entry = node.getmempoolentry(claim)
                minimum_configured_fee = SYNTHETIC_PAY_TX_FEE * entry["vsize"] / 1000
                assert entry["fees"]["base"] >= minimum_configured_fee
                self._event("claim_fee_observed", txid=claim, vsize=entry["vsize"],
                            base_fee_blk=entry["fees"]["base"],
                            configured_paytxfee_blk_per_kvb=SYNTHETIC_PAY_TX_FEE)
                self._wait_for_claim_relay(claim)
                assert claim in stake_node.getrawmempool()
                before = time.monotonic()
                block_hash = self._mine_pos_block_with_claim(staker, claim)
                self.sync_blocks(timeout=30)
                assert claim in node.getblock(block_hash)["tx"]
                assert wallet.gettransaction(claim)["confirmations"] > 0
                accepted.append({"txid": claim, "block": block_hash})
                self._event("claim_confirmed", txid=claim, block=block_hash,
                            confirmation_wall_seconds=time.monotonic() - before,
                            accepted_in_phase=len(accepted))
                # The fee input's confirmed change now permits another natural
                # claim. No direct claim builder, stale-work or failure hook.
            time.sleep(0.2)
        final = self._resources()
        after_duty = self._get_info(wallet).get("duty_cycle")
        wall = time.monotonic() - start
        cpu = final["process_cpu_seconds"] - initial["process_cpu_seconds"]
        summary = {"phase": self.phase, "wall_seconds": wall,
                   "process_cpu_seconds": cpu, "process_core_percent": 100 * cpu / wall,
                   "initial_resource": initial, "final_resource": final,
                   "samples": samples, "eligible_samples": eligible,
                   "hashing_samples": hashing, "accepted_claims": accepted,
                   "duty_validation": self._duty_result(before_duty, after_duty)}
        self._event("phase_complete", **summary)
        self.report["phases"].append(summary)
        assert len(accepted) >= self.options.minimum_claims, (
            "Insufficient sustained natural claims; no duty/recovery pass inferred", summary)
        assert summary["duty_validation"]["status"] == "completed_periods_passed", summary

    def _restart_from_persisted_config(self, payout):
        node = self.nodes[0]
        previous = node.process.pid
        self.restart_node(0, extra_args=self.extra_args[0] + [f"-mocktime={self.mock_time}"])
        self.connect_nodes(0, 1)
        self.sync_blocks(timeout=30)
        wallet = node.get_wallet_rpc("pow_sustained")
        self.wait_until(lambda: self._get_info(wallet)["enabled"], timeout=30)
        info = self._get_info(wallet)
        assert_equal(info["threads"], self.options.workers)
        assert_equal(info["cpu_percent"], self.options.cpu_percent)
        assert_equal(info["payout_address"], payout)
        assert_equal(info["autostart"], True)
        assert_equal(wallet.getwalletinfo()["paytxfee"], SYNTHETIC_PAY_TX_FEE)
        assert_equal(sorted(node.listwallets()), ["pow_sustained"])
        if "duty_cycle" in info:
            assert_equal(info["duty_cycle"]["session_id"], 1)
        self._event("restart_recovered", old_pid=previous, new_pid=node.process.pid,
                    telemetry=PowCpuBudgetTest._telemetry(info), payout=payout)
        return wallet

    def run_test(self):
        assert 30 <= self.options.sustained_seconds <= 1800
        assert 30 <= self.options.recovery_seconds <= 1800
        assert 1 <= self.options.minimum_claims <= self.options.max_claims <= 256
        assert 2 <= self.options.minimum_work_periods <= 10000
        self.run_start = time.monotonic()
        self.sequence = 0
        self.phase = "setup"
        self.events_path = Path(self.options.tmpdir) / "sustained-events.jsonl"
        self.report = {"schema": "blackcoin.sustained_pow.observation.v1",
                       "workers": self.options.workers, "cpu_percent": self.options.cpu_percent,
                       "platform": platform.platform(), "phases": [], "status": "incomplete",
                       "fee_policy": {"paytxfee_blk_per_kvb": str(SYNTHETIC_PAY_TX_FEE),
                                      "reason": "synthetic fee headroom above randomized peer fee filters for a bounded30-second genuine-relay wait"},
                       "limits": ["whole-process CPU includes RPC and incoming block validation",
                                  "duty checks consume only completed measured budget periods; in-progress and truncated periods are excluded",
                                  "telemetry publication overhead is outside budgeted active time but inside process CPU",
                                  "configuration-file persistence is tested; RPC controls are not claimed persistent",
                                  "no synthetic proof target, forced failure, actual machine sleep or live endpoint"]}
        self._event("setup_started", configuration=self.report)
        miner_node, stake_node = self.nodes
        for node in self.nodes:
            node.get_wallet_rpc(self.default_wallet_name).staking(False)
        # Only the intended private-key wallet may autostart on measured node0.
        miner_node.unloadwallet(self.default_wallet_name, load_on_startup=False)
        miner_node.createwallet(wallet_name="pow_sustained")
        wallet = miner_node.get_wallet_rpc("pow_sustained")
        wallet.staking(False)
        payout = wallet.getnewquantumaddress("PoW - Quantum Claim Address")["address"]
        stake_node.createwallet(wallet_name="sustained_staker")
        staker = stake_node.get_wallet_rpc("sustained_staker")
        staker.staking(False)
        address = staker.getnewaddress("", "legacy")
        self._set_mocktime((int(time.time()) & ~15) + 16)
        self.generatetoaddress(stake_node, COINBASE_MATURITY + 32, address, sync_fun=self.no_op)
        self.sync_blocks(timeout=30)
        targets = {wallet.getnewaddress("", "legacy"): 1 for _ in range(16)}
        staker.sendmany("", targets)
        self.generatetoaddress(stake_node, COINBASE_MATURITY + 1, address, sync_fun=self.no_op)
        self.sync_blocks(timeout=30)
        self._sync_mocktime_to_tip()
        self.wait_until(lambda: len(wallet.listunspent()) == 16, timeout=30)
        assert_equal(miner_node.getquantumquasarinfo()["phase"], "gold_rush")
        idle_start = time.monotonic()
        idle_resource = self._resources()
        for _ in range(5):
            self._sample(wallet)
            time.sleep(2)
        idle_wall = time.monotonic() - idle_start
        idle_cpu = self._resources()["process_cpu_seconds"] - idle_resource["process_cpu_seconds"]
        self.report["idle_control"] = {"wall_seconds": idle_wall,
            "process_cpu_seconds": idle_cpu, "process_core_percent": 100 * idle_cpu / idle_wall}
        self._event("idle_control_complete", **self.report["idle_control"])
        # These are disposable local config writes, re-read without repeated
        # mining CLI arguments on both clean restarts below.
        append_config(miner_node.datadir_path, ["[regtest]", "wallet=pow_sustained",
                      "powmining=1", f"powminingthreads={self.options.workers}",
                      f"powminingcpu={self.options.cpu_percent}", f"qqpowpayoutaddress={payout}",
                      f"paytxfee={SYNTHETIC_PAY_TX_FEE}"])
        self._event("config_persisted", workers=self.options.workers,
                    cpu_percent=self.options.cpu_percent, payout=payout)
        try:
            self.phase = "initial_autostart"
            wallet = self._restart_from_persisted_config(payout)
            self.phase = "sustained_before_restart"
            self.phase_mock = self.mock_time
            self._phase(wallet, staker, self.options.sustained_seconds)
            self.phase = "recovery_restart"
            wallet = self._restart_from_persisted_config(payout)
            self.phase = "sustained_after_restart"
            self.phase_mock = self.mock_time
            self._phase(wallet, staker, self.options.recovery_seconds)
            self.report["status"] = "natural_work_completed_periods_and_config_recovery_passed"
        except Exception as error:
            self.report["status"] = "failed"
            self.report["error"] = str(error)
            self._event("failure", error=str(error))
            raise
        finally:
            for label, stop in (("staker", lambda: staker.staking(False)),
                                ("miner", lambda: wallet.setpowmining(False))):
                try:
                    stop()
                except Exception as error:
                    self._event("cleanup_error", target=label, error=str(error))
            self.report["total_wall_seconds"] = time.monotonic() - self.run_start
            destination = Path(self.options.tmpdir) / "sustained-qualification.json"
            destination.write_text(json.dumps(self.report, indent=2, default=float) + "\n")
            self.log.info("Sustained qualification report: %s", destination)


if __name__ == "__main__":
    SustainedPowCpuTest().main()
