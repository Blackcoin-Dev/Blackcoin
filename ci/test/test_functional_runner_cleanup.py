#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Exercise functional-runner cleanup without launching a node."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


RUNNER = Path(__file__).resolve().parents[2] / "test/functional/test_runner.py"
SPEC = importlib.util.spec_from_file_location("functional_runner", RUNNER)
RUNNER_MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER_MODULE)


class FunctionalRunnerCleanupTests(unittest.TestCase):
    def test_framework_unit_failure_returns_failure(self):
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(RUNNER_MODULE, "TEST_FRAMEWORK_MODULES", []), \
                mock.patch.object(RUNNER_MODULE.unittest, "TextTestRunner") as runner:
            runner.return_value.run.return_value.wasSuccessful.return_value = False
            with self.assertRaises(SystemExit) as result:
                RUNNER_MODULE.run_tests(
                    test_list=["unused.py"], src_dir=directory, build_dir=directory,
                    tmpdir=directory, use_term_control=False,
                )
            self.assertEqual(result.exception.code, 1)

    @unittest.skipUnless(os.name == "posix", "POSIX process-group containment")
    def test_failure_and_interrupt_preserve_caller_and_reap_test_families(self):
        for interrupt in (False, True):
            with self.subTest(interrupt=interrupt), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                scripts = root / "test/functional"
                scripts.mkdir(parents=True)
                (scripts / "create_cache.py").write_text("pass\n", encoding="utf-8")
                ids = root / "family.json"
                (scripts / "long.py").write_text(
                    "import json, os, subprocess, sys, time\n"
                    "from pathlib import Path\n"
                    "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])\n"
                    f"ready = Path({str(ids.with_suffix('.tmp'))!r})\n"
                    "ready.write_text(json.dumps([os.getpid(), child.pid]))\n"
                    f"ready.replace({str(ids)!r})\n"
                    "time.sleep(60)\n", encoding="utf-8",
                )
                (scripts / "fail.py").write_text(
                    "import os, signal, sys, time\nfrom pathlib import Path\n"
                    f"ready = Path({str(ids)!r})\n"
                    "for _ in range(200):\n"
                    "    if ready.exists(): break\n"
                    "    time.sleep(0.01)\n"
                    "assert ready.exists()\n"
                    + ("os.kill(os.getppid(), signal.SIGINT)\ntime.sleep(60)\n"
                       if interrupt else
                       "import subprocess, json\n"
                       "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])\n"
                       f"Path({str(root / 'failed-family.json')!r}).write_text(json.dumps([os.getpid(), child.pid]))\n"
                       "sys.exit(1)\n"), encoding="utf-8",
                )
                wrapper = (
                    "import importlib.util, subprocess, sys\nfrom pathlib import Path\n"
                    f"spec = importlib.util.spec_from_file_location('runner', {str(RUNNER)!r})\n"
                    "runner = importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)\n"
                    "runner.TEST_FRAMEWORK_MODULES = []\n"
                    "sentinel = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])\n"
                    "status = 0\ntry:\n"
                    f"    runner.run_tests(test_list=['fail.py', 'long.py'], src_dir={directory!r}, "
                    f"build_dir={directory!r}, tmpdir={directory!r}, jobs=2, failfast=True, use_term_control=False)\n"
                    "except SystemExit as error: status = int(error.code)\n"
                    "except KeyboardInterrupt: status = 130\n"
                    "finally:\n"
                    "    assert sentinel.poll() is None, 'unrelated sibling was killed'\n"
                    f"    Path({str(root / 'collector-ran')!r}).write_text('preserved')\n"
                    "    sentinel.terminate(); sentinel.wait(timeout=5)\n"
                    "sys.exit(status)\n"
                )
                environment = os.environ.copy()
                environment.pop("CI_FAILFAST_TEST_LEAVE_DANGLING", None)
                proc = subprocess.Popen(
                    [sys.executable, "-c", wrapper], env=environment,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                    start_new_session=True,
                )
                try:
                    stdout, stderr = proc.communicate(timeout=15)
                    self.assertEqual(proc.returncode, 130 if interrupt else 1, stdout + stderr)
                    self.assertEqual((root / "collector-ran").read_text(), "preserved")
                    families = json.loads(ids.read_text())
                    if not interrupt:
                        families += json.loads((root / "failed-family.json").read_text())
                    for pid in families:
                        result = subprocess.run(
                            ["ps", "-o", "stat=", "-p", str(pid)],
                            text=True, stdout=subprocess.PIPE, check=False,
                        )
                        # Orphaned grandchildren may await the system reaper;
                        # a zombie is terminated and cannot continue test work.
                        self.assertTrue(not result.stdout.strip() or result.stdout.strip().startswith("Z"), result.stdout)
                finally:
                    families = [proc.pid]
                    for path in (ids, root / "failed-family.json"):
                        if path.exists():
                            families += json.loads(path.read_text())
                    for pgid in families:
                        try:
                            os.killpg(pgid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    proc.wait(timeout=5)

    def test_cleanup_tolerates_exited_group_and_closes_logs(self):
        handler = RUNNER_MODULE.TestHandler(
            num_tests_parallel=1, tests_dir="", tmpdir="", test_list=[],
            flags=[], use_term_control=False,
        )
        process, stdout, stderr = mock.Mock(pid=12345), mock.Mock(), mock.Mock()
        handler.jobs = [("test", 0, process, "", stdout, stderr)]
        with mock.patch.object(RUNNER_MODULE.os, "name", "posix"), \
                mock.patch.object(RUNNER_MODULE.signal, "SIGKILL", 9, create=True), \
                mock.patch.object(RUNNER_MODULE.os, "killpg", side_effect=ProcessLookupError, create=True) as kill:
            handler.kill_remaining()
        kill.assert_called_once_with(12345, 9)
        process.wait.assert_called_once_with(timeout=30)
        stdout.close.assert_called_once()
        stderr.close.assert_called_once()
        self.assertEqual(handler.jobs, [])

    def test_windows_cleanup_targets_only_the_test_tree(self):
        process = mock.Mock(pid=12345)
        with mock.patch.object(RUNNER_MODULE.os, "name", "nt"), \
                mock.patch.object(RUNNER_MODULE.subprocess, "run") as run:
            run.return_value.returncode = 0
            RUNNER_MODULE.TestHandler.kill_family(process)
        self.assertEqual(run.call_args.args[0], ['taskkill', '/PID', '12345', '/T', '/F'])


if __name__ == "__main__":
    unittest.main()
