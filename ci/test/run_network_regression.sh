#!/usr/bin/env bash
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.

export LC_ALL=C
set -euo pipefail

[[ $# == 1 && -x "$1" ]]
[[ "${TARGET_SHA:?exact source SHA required}" =~ ^[0-9a-f]{40}$ ]]
log=${NETWORK_REGRESSION_LOG:-${BASE_SCRATCH_DIR:-.}/bootstrap-units.log}
mkdir -p -- "$(dirname "$log")"
# One process preserves Boost suite ordering/shared state and sanitizer behavior.
# This is diagnostic evidence only, never a replacement for the full gate.
set +e
{
  printf 'target_sha=%s\n' "$TARGET_SHA"
  printf 'profile=bootstrap-units\nsuites=clientversion_tests,https_seed_tests,net_tests\n'
  sha256sum "$1" || exit "$?"
  "$1" --run_test=clientversion_tests,https_seed_tests,net_tests \
    --catch_system_errors=no --log_level=test_suite --report_level=detailed
} 2>&1 | tee "$log"
status=("${PIPESTATUS[@]}")
set -e
[[ "${status[0]}" == 0 ]] || exit "${status[0]}"
exit "${status[1]}"
