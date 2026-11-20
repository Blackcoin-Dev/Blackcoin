#!/usr/bin/env bash
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.

export LC_ALL=C
set -euo pipefail

[[ $# -ge 1 && $# -le 2 && -x "$1" ]]
[[ "${TARGET_SHA:?exact source SHA required}" =~ ^[0-9a-f]{40}$ ]]
profile=${REGRESSION_PROFILE:-bootstrap-units}
suites=clientversion_tests,https_seed_tests,net_tests
case "$profile" in
  bootstrap-units) ;;
  performance-units) suites+=,crypto_tests,shadow_tests,i2p_tests ;;
  efficiency-units) suites+=,crypto_tests,shadow_tests,i2p_tests,miner_tests,blockmanager_tests,coins_tests,wallet_tests ;;
  *) printf 'Unsupported focused unit profile: %s\n' "$profile" >&2; exit 64 ;;
esac
if [[ "$profile" == efficiency-units ]]; then
  [[ $# == 2 && -x "$2" ]] || exit 64
else
  [[ $# == 1 ]] || exit 64
fi
log=${NETWORK_REGRESSION_LOG:-${BASE_SCRATCH_DIR:-.}/$profile.log}
mkdir -p -- "$(dirname "$log")"
# One process preserves Boost suite ordering/shared state and sanitizer behavior.
# This is diagnostic evidence only, never a replacement for the full gate.
set +e
{
  printf 'target_sha=%s\n' "$TARGET_SHA"
  printf 'profile=%s\nsuites=%s\n' "$profile" "$suites"
  sha256sum "$1" || exit "$?"
  "$1" --run_test="$suites" \
    --catch_system_errors=no --log_level=test_suite --report_level=detailed
  unit_status=$?
  if [[ "$profile" == efficiency-units ]]; then
    printf 'boost_exit=%s\nqt_suites=all\n' "$unit_status"
    sha256sum "$2" || exit "$?"
    QT_QPA_PLATFORM=minimal "$2"
    qt_status=$?
    printf 'qt_exit=%s\n' "$qt_status"
    [[ "$unit_status" == 0 ]] || exit "$unit_status"
    exit "$qt_status"
  fi
  exit "$unit_status"
} 2>&1 | tee "$log"
status=("${PIPESTATUS[@]}")
set -e
[[ "${status[0]}" == 0 ]] || exit "${status[0]}"
exit "${status[1]}"
