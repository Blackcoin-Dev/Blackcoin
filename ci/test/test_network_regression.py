#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Check diagnostic routing and one-process failure retention without a build."""

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
        for scope in ("all", "native", "asan", "tsan"):
            values = routing.variables(scope)
            values["inputs.regression_profile"] = "bootstrap-units"
            expected = {"policy-and-lint"}
            if scope in {"all", "native"}:
                expected.add("native-build-and-unit")
            if scope in {"all", "asan", "tsan"}:
                expected.add("sanitizer-gates")
            self.assertEqual(fixture.selected_jobs(values), expected)
        for scope in ("", "full"):
            values = routing.variables(scope, release=True, extended=True)
            normal = fixture.selected_jobs(values)
            values["inputs.regression_profile"] = "bootstrap-units"
            self.assertEqual(fixture.selected_jobs(values), normal)
        workflow = (ROOT / ".github/workflows/pr-gate.yml").read_text()
        self.assertIn("inputs.regression_profile || 'functional'", workflow)
        self.assertIn("--enable-debug --enable-tests", workflow)
        self.assertIn('make -C src -j "$MAKEJOBS" test/test_blackcoin', workflow)
        native_steps = fixture.steps("native-build-and-unit")
        self.assertEqual(native_steps["Compile only regression prerequisites"].count("\n        env:"), 1)
        self.assertIn("always()", native_steps["Retain bootstrap unit result"])
        self.assertIn("if-no-files-found: error", native_steps["Retain bootstrap unit result"])
        for flavor in ("asan", "tsan"):
            command = f'source ci/test/00_setup_env_native_{flavor}_regression.sh; printf "%s\\n" "$BITCOIN_CONFIG" "$GOAL" "$RUN_FUNCTIONAL_TESTS"'
            output = subprocess.check_output(["bash", "-c", command], cwd=ROOT,
                                             env={**os.environ, "CI_NETWORK_REGRESSION": "true"}, text=True)
            self.assertIn("--enable-tests", output)
            self.assertIn("-C src test/test_blackcoin\nfalse\n", output)

    def test_single_process_preserves_failure_and_full_log(self):
        for status in (0, 12):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                base = Path(directory)
                binary = base / "fake-unit"
                binary.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\necho suite-output\nexit {status}\n')
                binary.chmod(0o700)
                env = {**os.environ, "TARGET_SHA": "a" * 40, "CALLS": str(base / "calls"),
                       "NETWORK_REGRESSION_LOG": str(base / "result.log")}
                result = subprocess.run(["bash", str(ROOT / "ci/test/run_network_regression.sh"), str(binary)],
                                        env=env, capture_output=True, text=True, check=False)
                self.assertEqual(result.returncode, status)
                calls = (base / "calls").read_text().splitlines()
                self.assertEqual(len(calls), 1)
                self.assertIn("--run_test=clientversion_tests,https_seed_tests,net_tests", calls[0])
                self.assertIn("--catch_system_errors=no", calls[0])
                log = (base / "result.log").read_text()
                self.assertIn("target_sha=" + "a" * 40, log)
                self.assertIn("suite-output", log)


if __name__ == "__main__":
    unittest.main()
