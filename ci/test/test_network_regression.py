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
        self.assertIn("options: [functional, bootstrap-units, performance-units]", workflow)
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
        for profile in ("bootstrap-units", "performance-units"):
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
                    result = subprocess.run(["bash", str(ROOT / "ci/test/run_network_regression.sh"), str(binary)],
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
                    self.assertEqual((base / "calls").read_text().splitlines(), [
                        f"--run_test={suites} --catch_system_errors=no --log_level=test_suite --report_level=detailed",
                    ])
                    output = log.read_text().splitlines()
                    self.assertEqual(output, [
                        "target_sha=" + "a" * 40, f"profile={actual_profile}", f"suites={suites}",
                        f"{hashlib.sha256(binary.read_bytes()).hexdigest()}  {binary}", "suite-output",
                    ])


if __name__ == "__main__":
    unittest.main()
