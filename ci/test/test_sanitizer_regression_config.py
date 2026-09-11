#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Check focused sanitizer profiles without building or launching containers."""

import json
import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
FIELDS = (
    "BITCOIN_CONFIG", "DEP_OPTS", "GOAL", "PACKAGES", "CONTAINER_NAME",
    "RUN_UNIT_TESTS", "RUN_UNIT_TESTS_SEQUENTIAL", "RUN_FUNCTIONAL_TESTS",
    "RUN_FUZZ_TESTS", "CI_REGRESSION_ONLY", "CCACHE_MAXSIZE",
)


def profile(name):
    export_fields = f"import json, os; print(json.dumps({{key: os.getenv(key) for key in {FIELDS!r}}}))"
    result = subprocess.run(
        ["bash", "-c", 'source "$1"; python3 -c "$2"', "profile",
         f"ci/test/00_setup_env_native_{name}.sh", export_fields],
        cwd=ROOT, env={"PATH": os.environ["PATH"], "CIRRUS_CI": "false"},
        text=True, capture_output=True, check=True,
    )
    return json.loads(result.stdout)


class SanitizerRegressionConfigTests(unittest.TestCase):
    def test_focused_profiles_preserve_instrumentation_and_bound_build_scope(self):
        for sanitizer in ("asan", "tsan"):
            with self.subTest(sanitizer=sanitizer):
                full = profile(sanitizer)
                focused = profile(sanitizer + "_regression")
                self.assertEqual(full["GOAL"], "install")
                self.assertTrue(focused["BITCOIN_CONFIG"].startswith(full["BITCOIN_CONFIG"] + " "))
                self.assertTrue(focused["BITCOIN_CONFIG"].endswith(
                    "--with-gui=no --disable-tests --disable-bench --disable-fuzz-binary"
                ))
                self.assertEqual(focused["DEP_OPTS"], full["DEP_OPTS"] + " NO_QT=1 NO_UPNP=1 NO_NATPMP=1")
                self.assertEqual(focused["GOAL"], "-C src blackcoind blackcoin-cli")
                self.assertEqual(focused["RUN_UNIT_TESTS"], "false")
                self.assertEqual(focused["RUN_UNIT_TESTS_SEQUENTIAL"], "false")
                self.assertEqual(focused["RUN_FUNCTIONAL_TESTS"], "true")
                self.assertEqual(focused["RUN_FUZZ_TESTS"], "false")
                self.assertEqual(focused["CI_REGRESSION_ONLY"], "true")
                self.assertEqual(focused["CCACHE_MAXSIZE"], "1G")
                self.assertNotEqual(focused["CONTAINER_NAME"], full["CONTAINER_NAME"])
                self.assertNotIn("qt", focused["PACKAGES"])


if __name__ == "__main__":
    unittest.main()
