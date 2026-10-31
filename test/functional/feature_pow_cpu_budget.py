#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://opensource.org/license/mit/.
"""Bounded process-CPU observations for natural wallet PoW jobs.

This diagnostic deliberately has no precise OS CPU pass threshold. A natural
proof can end available work, and 128-try batches can exceed a short sample's
duty budget before their compensating sleep completes. Every matrix cell is
therefore reported as an observation, never as a duty-cycle validation pass.
Only disposable framework regtest wallets and public RPCs are used.
"""

from decimal import Decimal
import json
import os
from pathlib import Path
import platform
import subprocess
import time

from test_framework.blocktools import COINBASE_MATURITY
from test_framework.test_framework import BitcoinTestFramework, SkipTest
from test_framework.util import assert_equal


class PowCpuBudgetTest(BitcoinTestFramework):
    def add_options(self, parser):
        self.add_wallet_options(parser)
        parser.add_argument("--cpu-sample-seconds", type=float, default=30,
                            help="Wall seconds per matrix cell, 15..30")
        parser.add_argument("--cpu-idle-seconds", type=float, default=5,
                            help="Same-poll idle control before each cell, 3..10")
        parser.add_argument("--cpu-fee-utxos", type=int, default=8,
                            help="Confirmed natural fee inputs per wallet, 2..128")

    def set_test_params(self):
        self.num_nodes = 1
        self.setup_clean_chain = True
        self.extra_args = [[
            "-allowunsafequantumkeyrpc=1", "-txindex=1",
            "-shadowwhitelistheight=1", "-shadowcompetingclaimsheight=2",
            "-shadowqqp4height=2", "-shadowgoldrushblocks=500",
            "-qqgoldrushendtime=2000000000",
            "-qqmigrationdeadlinetime=2000040000",
        ]]

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()
        if platform.system() not in ("Darwin", "Linux"):
            raise SkipTest("Process CPU reader supports Darwin and Linux")

    def _process_cpu(self):
        """Return cumulative user+system CPU for the daemon, in core-seconds."""
        pid = self.nodes[0].process.pid
        if platform.system() == "Linux":
            fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
            return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")
        value = subprocess.check_output(
            ["ps", "-p", str(pid), "-o", "time="], text=True).strip()
        days = 0
        if "-" in value:
            day_text, value = value.split("-", 1)
            days = int(day_text)
        parts = [float(part) for part in value.split(":")]
        seconds = 0.0
        for part in parts:
            seconds = seconds * 60 + part
        return days * 86400 + seconds

    @staticmethod
    def _telemetry(info):
        names = ("enabled", "state", "threads", "cpu_percent",
                 "workers_hashing", "workers_error", "hashrate",
                 "claims_submitted", "epoch_active", "mining_gate_action",
                 "mining_gate_can_submit", "claim_coins_after_stake_reserve",
                 "claim_input_enumeration")
        return {name: info.get(name) for name in names}

    def _observe(self, wallet, duration, *, workers=None, percent=None):
        node = self.nodes[0]
        start_wall = time.monotonic()
        start_cpu = self._process_cpu()
        start_mock = self.mock_time
        started = None
        if workers is not None:
            # CPU accounting starts before worker creation: selection, proof
            # preparation and control/key creation overhead are all included.
            started = wallet.setpowmining(True, workers, percent, True)
            assert_equal(started["threads"], workers)
            assert_equal(started["cpu_percent"], percent)
        samples = []
        try:
            while True:
                elapsed = time.monotonic() - start_wall
                self.mock_time = start_mock + int(elapsed)
                node.setmocktime(self.mock_time)
                info = wallet.getpowmininginfo()
                elapsed = time.monotonic() - start_wall
                samples.append({"wall_seconds": elapsed,
                                "process_cpu_seconds": self._process_cpu() - start_cpu,
                                **self._telemetry(info)})
                if elapsed >= duration:
                    break
                time.sleep(min(1.0, duration - elapsed))
            wall = time.monotonic() - start_wall
            cpu = self._process_cpu() - start_cpu
        finally:
            if workers is not None:
                wallet.setpowmining(False)
        # Stop/join CPU is intentionally outside the observation window.
        return {"wall_seconds": wall, "process_cpu_seconds": cpu,
                "process_core_percent": 100 * cpu / wall,
                "started": started, "samples": samples}

    def run_test(self):
        assert 15 <= self.options.cpu_sample_seconds <= 30
        assert 3 <= self.options.cpu_idle_seconds <= 10
        assert 2 <= self.options.cpu_fee_utxos <= 128
        node = self.nodes[0]
        node.get_wallet_rpc(self.default_wallet_name).staking(False)
        self.mock_time = (int(time.time()) & ~15) + 16
        node.setmocktime(self.mock_time)
        node.createwallet(wallet_name="cpu_budget_donor")
        donor = node.get_wallet_rpc("cpu_budget_donor")
        donor.staking(False)
        donor_address = donor.getnewaddress("", "legacy")
        self.generatetoaddress(node, COINBASE_MATURITY + 32, donor_address,
                               sync_fun=self.no_op)
        self.mock_time = node.getblockheader(node.getbestblockhash())["time"] + 16
        node.setmocktime(self.mock_time)
        cells = []
        # A fresh funded wallet for every cell avoids reusing an anchor already
        # reserved by a previous natural proof. No claim cleanup is attempted.
        for workers in (1, 2):
            for percent in (1, 60, 100):
                name = f"cpu_budget_{workers}_{percent}"
                node.createwallet(wallet_name=name)
                wallet = node.get_wallet_rpc(name)
                wallet.staking(False)
                outputs = {wallet.getnewaddress("", "legacy"): Decimal("1")
                           for _ in range(self.options.cpu_fee_utxos)}
                donor.sendmany("", outputs)
                cells.append((workers, percent, wallet))
        self.generatetoaddress(node, 1, donor_address, sync_fun=self.no_op)
        self.mock_time = node.getblockheader(node.getbestblockhash())["time"] + 16
        node.setmocktime(self.mock_time)
        assert_equal(node.getquantumquasarinfo()["phase"], "gold_rush")
        measurements = []
        for workers, percent, wallet in cells:
            self.wait_until(lambda: len(wallet.listunspent()) == self.options.cpu_fee_utxos,
                            timeout=30)
            idle = self._observe(wallet, self.options.cpu_idle_seconds)
            active = self._observe(wallet, self.options.cpu_sample_seconds,
                                   workers=workers, percent=percent)
            samples = active["samples"]
            first_claim = next((sample for sample in samples
                                if (sample.get("claims_submitted") or 0) > 0), None)
            hash_samples = sum((sample.get("workers_hashing") or 0) > 0 for sample in samples)
            # Polls can miss entire batches. This is observable transition
            # evidence, not an exact completed-iteration or per-worker counter.
            resumed = 0
            saw_hash = False
            saw_gap = False
            for sample in samples:
                if sample.get("workers_hashing", 0):
                    if saw_hash and saw_gap:
                        resumed += 1
                    saw_hash, saw_gap = True, False
                elif saw_hash:
                    saw_gap = True
            reasons = ["public RPCs expose no exact active/wait iteration counters; duty-period coverage is unproven"]
            if first_claim:
                reasons.append("a natural proof was submitted; subsequent claim gating can leave workers without eligible jobs")
            if not hash_samples:
                reasons.append("no hashing batch was observed; polling can miss short batches and no saturation is established")
            if not resumed:
                reasons.append("no hash/idle/hash transition was observed within the capped window")
            record = {"workers": workers, "target_percent_per_worker": percent,
                      "nominal_aggregate_core_percent": workers * percent,
                      "fee_utxos_at_setup": self.options.cpu_fee_utxos,
                      "idle_control": idle, "active_observation": active,
                      "observed_process_core_percent_above_idle":
                          active["process_core_percent"] - idle["process_core_percent"],
                      "hashing_samples": hash_samples,
                      "observed_hash_idle_hash_transitions": resumed,
                      "first_claim_observed_at_seconds": first_claim["wall_seconds"] if first_claim else None,
                      "duty_validation": "inconclusive", "limits": reasons}
            measurements.append(record)
            self.log.info("CPU observation workers=%d target=%d process=%.2f%% idle=%.2f%% claim_at=%s status=inconclusive",
                          workers, percent, active["process_core_percent"],
                          idle["process_core_percent"], record["first_claim_observed_at_seconds"])
        destination = Path(self.options.tmpdir) / "pow-cpu-budget.json"
        destination.write_text(json.dumps({
            "schema": "blackcoin.pow_cpu_budget.observation.v1",
            "platform": platform.platform(), "logical_cpus": os.cpu_count(),
            "scope": "daemon user+system process CPU; 100 percent is one logical core",
            "poll_interval_seconds": 1,
            "limits": ["no CPU percentage assertion and no duty-cycle validation pass",
                       "daemon CPU includes RPC/control, selection, proof preparation and other node threads",
                       "idle subtraction is descriptive, not attribution to miner workers",
                       "one-second polls can miss batches; hashrate is publication telemetry, not a work counter",
                       "fixed-tip natural jobs can end on a found proof; no jobs are forged or forced to fail"],
            "measurements": measurements}, indent=2, default=float) + "\n")
        self.log.info("CPU observations: %s", destination)


if __name__ == "__main__":
    PowCpuBudgetTest().main()
