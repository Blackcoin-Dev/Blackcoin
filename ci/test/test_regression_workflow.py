#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Guard failure-only workflow routing without a YAML or Actions dependency."""

import ast
import itertools
import json
from pathlib import Path
import re
import unittest


WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/pr-gate.yml"
STANDARD_JOBS = {
    "crypto-source-provenance", "native-build-and-unit", "resource-benchmarks-linux",
    "critical-protocol", "mixed-version",
}
RELEASE_JOBS = {
    "native-linux-arm64-crypto", "native-linux-arm64-ubsan", "windows-crypto-cross-build",
    "native-windows-crypto", "native-macos-crypto", "sanitizer-gates", "fuzz-smoke",
}
NATIVE_TESTS = {
    "feature_goldrush_pow_claim_singleflight.py", "rpc_goldrushinfo.py", "feature_maxtipage.py",
}
SANITIZER_TESTS = {
    "asan": {
        "feature_goldrush_shadow_replay.py", "feature_goldrush_pow_claim_singleflight.py",
        "feature_goldrush_pos_signal.py", "feature_goldrush_pos_multiwallet_stress.py",
        "feature_goldrush_pos_signal_recovery.py", "wallet_pos_multiwallet_staking.py",
        "feature_quantum_lifecycle.py", "feature_quantum_demurrage_height_boundary.py",
        "feature_shutdown.py",
    },
    "tsan": {
        "feature_goldrush_pow_claim_singleflight.py", "feature_goldrush_pos_signal.py",
        "feature_goldrush_pos_multiwallet_stress.py", "feature_goldrush_pos_signal_recovery.py",
        "wallet_pos_multiwallet_staking.py", "feature_shutdown.py",
    },
}


def sections(text, pattern):
    matches = list(re.finditer(pattern, text, re.MULTILINE))
    return {match[1]: text[match.end():matches[i + 1].start() if i + 1 < len(matches) else len(text)]
            for i, match in enumerate(matches)}


def field(text, key, indent=4, default=None):
    match = re.search(rf"^{' ' * indent}{key}: (.+)$", text, re.MULTILINE)
    if match:
        return match[1]
    if default is not None:
        return default
    raise AssertionError(f"missing {key}")


def expression(value, variables):
    """Evaluate only the workflow's scalar boolean/choice expression subset."""
    if not value.startswith("${{"):
        return value
    source = value[3:-2].strip().replace("&&", " and ").replace("||", " or ")
    source = re.sub(r"\b(?:inputs|github|matrix)\.[a-zA-Z_]+\b",
                    lambda match: repr(variables.get(match[0], "")), source)
    source = re.sub(r"\btrue\b", "True", source)
    source = re.sub(r"\bfalse\b", "False", source)
    tree = ast.parse(source, mode="eval")
    allowed = (ast.Expression, ast.BoolOp, ast.And, ast.Or, ast.Compare, ast.Eq,
               ast.NotEq, ast.Constant, ast.Call, ast.Name, ast.Load)
    for node in ast.walk(tree):
        if not isinstance(node, allowed) or isinstance(node, ast.Name) and node.id not in {"fromJSON", "format"}:
            raise AssertionError(f"unsupported workflow expression: {source}")
    return eval(compile(tree, str(WORKFLOW), "eval"), {"__builtins__": {}}, {
        "fromJSON": json.loads, "format": lambda template, *args: template.format(*args),
    })


def variables(scope="", event="workflow_dispatch", release=False, extended=False, corrective=False, **matrix):
    return {
        "inputs.regression_scope": scope, "github.event_name": event,
        "inputs.release_mode": release, "inputs.run_extended_functional": extended,
        "inputs.corrective_fast_path": corrective,
        **{f"matrix.{key}": value for key, value in matrix.items()},
    }


class RegressionWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")
        cls.jobs = sections(cls.workflow.split("\njobs:\n", 1)[1], r"^  ([a-z0-9-]+):$")

    def selected_jobs(self, values):
        return {name for name, body in self.jobs.items()
                if expression(field(body, "if", default="${{ true }}"), values)}

    def steps(self, job):
        return sections(self.jobs[job], r"^      - name: (.+)$")

    def test_scope_is_manual_only_and_full_by_default(self):
        dispatch, reusable = self.workflow.split("  workflow_call:\n", 1)
        self.assertRegex(dispatch, r"regression_scope:\n(?:.*\n)*?        type: choice\n        default: full\n        options: \[full, all, native, asan, tsan\]")
        self.assertNotIn("regression_scope:", reusable.split("\npermissions:", 1)[0])
        self.assertIn("  pull_request:\n", dispatch)
        self.assertIn("safety-gate-${{ inputs.regression_scope || 'full' }}-", self.workflow)

    def test_focused_scopes_exclude_every_unrelated_job(self):
        for scope, release, extended, corrective in itertools.product(
                ("all", "native", "asan", "tsan"), (False, True), (False, True), (False, True)):
            expected = {"policy-and-lint"}
            if scope in {"all", "native"}:
                expected |= {"native-build-and-unit", "exhaustive-functional"}
            if scope in {"all", "asan", "tsan"}:
                expected.add("sanitizer-gates")
            with self.subTest(scope=scope, release=release, extended=extended, corrective=corrective):
                self.assertEqual(self.selected_jobs(variables(scope, release=release, extended=extended,
                                                            corrective=corrective)), expected)

    def test_pr_and_full_job_selection_preserves_previous_defaults(self):
        all_jobs = {"policy-and-lint", "exhaustive-functional"} | STANDARD_JOBS | RELEASE_JOBS
        self.assertEqual(set(self.jobs), all_jobs)
        for event, release, extended, corrective in itertools.product(
                ("pull_request", "workflow_dispatch", "workflow_call"), (False, True), (False, True), (False, True)):
            expected = {"policy-and-lint"}
            if event == "pull_request":
                expected = all_jobs
            elif not corrective:
                expected |= STANDARD_JOBS
                if release:
                    expected |= RELEASE_JOBS
                if extended:
                    expected.add("exhaustive-functional")
            for scope in (("", "full") if event == "workflow_dispatch" else ("",)):
                with self.subTest(event=event, scope=scope, release=release, extended=extended, corrective=corrective):
                    self.assertEqual(self.selected_jobs(variables(scope, event, release, extended, corrective)), expected)

    def test_native_focus_has_no_full_build_or_unit_run(self):
        steps = self.steps("native-build-and-unit")
        full = {"Configure debug and lock-order build", "Compile candidate",
                "Provision pinned Blackcoin-compatible script vectors", "Run unit and utility tests"}
        focused = {"Configure targeted debug binaries", "Compile only regression prerequisites"}
        for scope in ("", "full", "all", "native"):
            for name in full | focused:
                self.assertEqual(bool(expression(field(steps[name], "if", 8), variables(scope))),
                                 name in (full if scope in {"", "full"} else focused))
        self.assertIn("--disable-tests --disable-bench --disable-fuzz-binary", steps["Configure targeted debug binaries"])
        self.assertIn('make -C src -j "$MAKEJOBS" blackcoind blackcoin-cli', steps["Compile only regression prerequisites"])

    def test_focused_preflight_retains_identity_but_omits_unrelated_full_suites(self):
        steps = self.steps("policy-and-lint")
        full = {"Verify dependency, advisory, capability, and provenance evidence", "Install lint dependencies",
                "Test fail-closed release tooling", "Test script corpus precondition tooling", "Run repository linters"}
        always = {"Verify exact checkout", "Verify repository and source identity", "Reject malformed patch whitespace",
                  "Parse workflow YAML", "Validate workflow semantics with pinned actionlint"}
        for scope in ("", "full", "all", "native", "asan", "tsan"):
            values = variables(scope)
            for name in full:
                self.assertEqual(bool(expression(field(steps[name], "if", 8), values)), scope in {"", "full"})
            for name in always:
                self.assertTrue(expression(field(steps[name], "if", 8, "${{ true }}"), values))
            self.assertEqual(bool(expression(field(steps["Test targeted workflow configuration"], "if", 8), values)),
                             scope not in {"", "full"})

    def test_native_focus_runs_exactly_the_three_failed_functionals(self):
        steps = self.steps("exhaustive-functional")
        focus = steps["Run only previously failing functional tests"]
        full = steps["Run all default and extended functional tests"]
        self.assertEqual(set(re.findall(r"\b(?:feature|rpc)_\w+\.py\b", focus)), NATIVE_TESTS)
        self.assertNotIn("--extended", focus)
        self.assertIn("--ci --extended --jobs=4", full)
        for scope in ("", "full", "all", "native"):
            self.assertEqual(bool(expression(field(focus, "if", 8), variables(scope))), scope in {"all", "native"})
            self.assertEqual(bool(expression(field(full, "if", 8), variables(scope))), scope in {"", "full"})
        for script in (focus, self.steps("native-build-and-unit")["Configure targeted debug binaries"]):
            self.assertNotRegex(script, r"(?m)\\\\\s*$", "shell continuation must be a single backslash")

    def test_sanitizer_focus_selects_only_requested_flavor_and_singleflight(self):
        job = self.jobs["sanitizer-gates"]
        include = field(job, "include", 8)
        run = self.steps("sanitizer-gates")["Run sanitizer gate with pinned consensus dependencies"]
        for scope in ("", "full", "all", "asan", "tsan"):
            rows = expression(include, variables(scope))
            expected = {scope} if scope in {"asan", "tsan"} else {"asan", "tsan"}
            self.assertEqual({row["flavor"] for row in rows}, expected)
            for row in rows:
                values = variables(scope, **row)
                full = scope in {"", "full"}
                self.assertEqual(set(expression(field(run, "TEST_RUNNER_EXTRA", 10), values).split()),
                                 SANITIZER_TESTS[row["flavor"]] if full else {"feature_goldrush_pow_claim_singleflight.py"})
                self.assertEqual(expression(field(run, "FILE_ENV", 10), values),
                                 f"ci/test/00_setup_env_native_{row['flavor']}{'' if full else '_regression'}.sh")
                name = expression(field(job, "name"), values)
                self.assertEqual(name, f"{row['name']} consensus and liveness gate" if full
                                 else f"targeted regression ({row['name']})")

    def test_native_diagnostic_job_names_do_not_claim_full_qualification(self):
        for job, full, focused in (
                ("policy-and-lint", "source identity, workflow syntax, and lint", "targeted regression configuration"),
                ("native-build-and-unit", "pinned native build and unit tests", "targeted native regression binaries"),
                ("exhaustive-functional", "complete extended functional suite", "targeted previously failing functional tests")):
            for scope in ("", "full", "all", "native"):
                self.assertEqual(expression(field(self.jobs[job], "name"), variables(scope)),
                                 full if scope in {"", "full"} else focused)

    def test_container_copies_parent_profiles_sourced_by_focused_wrappers(self):
        root = WORKFLOW.parents[2]
        image = (root / "ci/test_imagefile").read_text(encoding="utf-8")
        copies = re.findall(r"^COPY (.+) /ci_container_base/ci/test/$", image, re.MULTILINE)
        self.assertEqual(len(copies), 1)
        sources = copies[0].split()
        self.assertIn("./${FILE_ENV}", sources)
        for flavor in ("asan", "tsan"):
            parent = f"00_setup_env_native_{flavor}.sh"
            wrapper = (root / f"ci/test/00_setup_env_native_{flavor}_regression.sh").read_text(encoding="utf-8")
            self.assertIn(f'source "$(dirname "${{BASH_SOURCE[0]}}")/{parent}"', wrapper)
            self.assertIn(f"./ci/test/{parent}", sources)


if __name__ == "__main__":
    unittest.main()
