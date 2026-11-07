#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Check diagnostic routing and one-process failure retention without a build."""

import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / f"ci/test/{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class NetworkRegressionTests(unittest.TestCase):
    def test_profile_routes_without_replacing_full_or_old_diagnostics(self):
        routing = load("test_regression_workflow")
        routing.RegressionWorkflowTests.setUpClass()
        fixture = routing.RegressionWorkflowTests()
        native_steps = fixture.steps("native-build-and-unit")
        sanitizer_steps = fixture.steps("sanitizer-gates")
        sanitizer_run = sanitizer_steps["Run sanitizer gate with pinned consensus dependencies"]
        workflow = fixture.workflow
        self.assertIn("options: [functional, bootstrap-units, performance-units, efficiency-units]", workflow)
        self.assertIn("inputs.regression_profile || 'functional'", workflow)
        self.assertIn("--enable-debug --enable-tests", native_steps["Configure focused unit binaries"])
        self.assertIn('make -C src -j "$MAKEJOBS" test/test_blackcoin',
                      native_steps["Compile only regression prerequisites"])
        self.assertIn("ci/test/run_network_regression.sh src/test/test_blackcoin",
                      native_steps["Run focused unit suites together"])
        self.assertIn('tee ".ci/${REGRESSION_PROFILE}-${{ matrix.flavor }}.log"', sanitizer_run)
        for steps, name, path in (
            (native_steps, "Retain focused unit result", ".ci/${{ inputs.regression_profile }}.log"),
            (sanitizer_steps, "Retain focused sanitizer full log",
             ".ci/${{ inputs.regression_profile }}-${{ matrix.flavor }}.log"),
        ):
            artifact = steps[name]
            self.assertIn("always()", artifact)
            self.assertIn("if-no-files-found: error", artifact)
            self.assertIn("include-hidden-files: true", artifact)
            self.assertEqual(routing.field(artifact, "path", 10), path)
        for profile in ("bootstrap-units", "performance-units", "efficiency-units"):
            for scope in ("all", "native", "asan", "tsan"):
                with self.subTest(profile=profile, scope=scope):
                    values = routing.variables(scope)
                    values["inputs.regression_profile"] = profile
                    expected = {"policy-and-lint"}
                    if scope in {"all", "native"}:
                        expected.add("native-build-and-unit")
                    if scope in {"all", "asan", "tsan"}:
                        expected.add("sanitizer-gates")
                    self.assertEqual(fixture.selected_jobs(values), expected)
                    for steps, name in (
                        (native_steps, "Configure focused unit binaries"),
                        (native_steps, "Run focused unit suites together"),
                        (native_steps, "Retain focused unit result"),
                        (sanitizer_steps, "Retain focused sanitizer full log"),
                    ):
                        condition = routing.field(steps[name], "if", 8).replace("always() && ", "")
                        self.assertTrue(routing.expression(condition, values))
                        self.assertFalse(routing.expression(condition, {**values, "inputs.regression_profile": "functional"}))
                    for name in ("Configure targeted debug binaries", "Upload exact test binaries"):
                        self.assertFalse(routing.expression(routing.field(native_steps[name], "if", 8), values))
                    for step in (native_steps["Run focused unit suites together"], sanitizer_run):
                        self.assertEqual(routing.expression(routing.field(step, "REGRESSION_PROFILE", 10), values), profile)
                    self.assertTrue(routing.expression(routing.field(sanitizer_run, "CI_NETWORK_REGRESSION", 10), values))
            for scope in ("", "full"):
                values = routing.variables(scope, release=True, extended=True)
                normal = fixture.selected_jobs(values)
                values["inputs.regression_profile"] = profile
                self.assertEqual(fixture.selected_jobs(values), normal)
                self.assertFalse(routing.expression(routing.field(sanitizer_run, "CI_NETWORK_REGRESSION", 10), values))
        for flavor in ("asan", "tsan"):
            command = f'source ci/test/00_setup_env_native_{flavor}_regression.sh; printf "%s\\n" "$BITCOIN_CONFIG" "$GOAL" "$RUN_FUNCTIONAL_TESTS"'
            output = subprocess.check_output(["bash", "-c", command], cwd=ROOT,
                                             env={**os.environ, "CI_NETWORK_REGRESSION": "true"}, text=True)
            self.assertIn("--enable-tests", output)
            self.assertIn("-C src test/test_blackcoin\nfalse\n", output)

    def test_single_process_preserves_failure_and_full_log(self):
        bootstrap_suites = "clientversion_tests,https_seed_tests,net_tests"
        profiles = {
            None: bootstrap_suites,
            "bootstrap-units": bootstrap_suites,
            "performance-units": bootstrap_suites + ",crypto_tests,shadow_tests,i2p_tests",
            "efficiency-units": bootstrap_suites + ",crypto_tests,shadow_tests,i2p_tests,miner_tests,blockmanager_tests,coins_tests,wallet_tests",
            "functional": None,
            "unknown-units": None,
        }
        for profile, suites in profiles.items():
            for status in (0, 12):
                with self.subTest(profile=profile, status=status), tempfile.TemporaryDirectory() as directory:
                    base = Path(directory)
                    binary = base / "fake-unit"
                    binary.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\necho suite-output\nexit {status}\n')
                    binary.chmod(0o700)
                    env = {**os.environ, "TARGET_SHA": "a" * 40, "CALLS": str(base / "calls"),
                           "BASE_SCRATCH_DIR": str(base)}
                    env.pop("NETWORK_REGRESSION_LOG", None)
                    env.pop("REGRESSION_PROFILE", None)
                    if profile is not None:
                        env["REGRESSION_PROFILE"] = profile
                    qt_args = []
                    if profile == "efficiency-units":
                        qt_binary = base / "fake-qt"
                        qt_binary.write_text('#!/bin/sh\nprintf "qt:%s\\n" "$QT_QPA_PLATFORM" >> "$CALLS"\necho qt-output\n')
                        qt_binary.chmod(0o700)
                        qt_args = [str(qt_binary)]
                    result = subprocess.run(["bash", str(ROOT / "ci/test/run_network_regression.sh"), str(binary), *qt_args],
                                            env=env, capture_output=True, text=True, check=False)
                    actual_profile = profile or "bootstrap-units"
                    log = base / f"{actual_profile}.log"
                    if suites is None:
                        self.assertEqual(result.returncode, 64)
                        self.assertIn("Unsupported focused unit profile", result.stderr)
                        self.assertFalse((base / "calls").exists())
                        self.assertFalse(log.exists())
                        continue
                    self.assertEqual(result.returncode, status)
                    calls = [f"--run_test={suites} --catch_system_errors=no --log_level=test_suite --report_level=detailed"]
                    expected_output = [
                        "target_sha=" + "a" * 40, f"profile={actual_profile}", f"suites={suites}",
                        f"{hashlib.sha256(binary.read_bytes()).hexdigest()}  {binary}", "suite-output",
                    ]
                    if profile == "efficiency-units":
                        calls.append("qt:minimal")
                        expected_output.extend([
                            f"boost_exit={status}", "qt_suites=all",
                            f"{hashlib.sha256(qt_binary.read_bytes()).hexdigest()}  {qt_binary}",
                            "qt-output", "qt_exit=0",
                        ])
                    self.assertEqual((base / "calls").read_text().splitlines(), calls)
                    self.assertEqual(log.read_text().splitlines(), expected_output)


    def test_efficiency_requires_qt_and_preserves_each_failure(self):
        script = str(ROOT / "ci/test/run_network_regression.sh")
        for unit_status, qt_status in ((0, 0), (13, 0), (0, 14), (13, 14)):
            with self.subTest(unit=unit_status, qt=qt_status), tempfile.TemporaryDirectory() as directory:
                base = Path(directory)
                env = {**os.environ, "TARGET_SHA": "b" * 40, "REGRESSION_PROFILE": "efficiency-units",
                       "NETWORK_REGRESSION_LOG": str(base / "log"), "CALLS": str(base / "calls")}
                binaries = []
                for name, status in (("boost", unit_status), ("qt", qt_status)):
                    binary = base / name
                    binary.write_text(f'#!/bin/sh\necho {name} >> "$CALLS"\nexit {status}\n')
                    binary.chmod(0o700)
                    binaries.append(str(binary))
                result = subprocess.run(["bash", script, *binaries], env=env, capture_output=True, check=False)
                self.assertEqual(result.returncode, unit_status or qt_status)
                self.assertEqual((base / "calls").read_text().splitlines(), ["boost", "qt"])
                self.assertIn(f"qt_exit={qt_status}", (base / "log").read_text())
                (base / "calls").unlink()
                result = subprocess.run(["bash", script, binaries[0]], env=env, capture_output=True, check=False)
                self.assertEqual(result.returncode, 64)
                self.assertFalse((base / "calls").exists())
                env["REGRESSION_PROFILE"] = "performance-units"
                result = subprocess.run(["bash", script, *binaries], env=env, capture_output=True, check=False)
                self.assertEqual(result.returncode, 64)
                self.assertFalse((base / "calls").exists())

    def test_efficiency_sanitizers_keep_parent_instrumentation_and_build_qt(self):
        config = load("test_sanitizer_regression_config")
        for flavor in ("asan", "tsan"):
            with self.subTest(flavor=flavor):
                parent = config.profile(flavor)
                command = f'source ci/test/00_setup_env_native_{flavor}_regression.sh; printf "%s\\n" "$BITCOIN_CONFIG" "$DEP_OPTS" "$GOAL" "$RUN_FUNCTIONAL_TESTS"'
                output = subprocess.check_output(["bash", "-c", command], cwd=ROOT, text=True,
                    env={"PATH": os.environ["PATH"], "CI_NETWORK_REGRESSION": "true", "CIRRUS_CI": "false",
                         "REGRESSION_PROFILE": "efficiency-units"}).splitlines()
                self.assertTrue(output[0].startswith(parent["BITCOIN_CONFIG"] + " "))
                self.assertTrue(output[0].endswith("--enable-tests --with-gui=qt5"))
                self.assertEqual(output[1], parent["DEP_OPTS"] + " NO_UPNP=1 NO_NATPMP=1")
                self.assertEqual(output[2:], ["-C src test/test_blackcoin qt/test/test_blackcoin-qt", "false"])


if __name__ == "__main__":
    unittest.main()
