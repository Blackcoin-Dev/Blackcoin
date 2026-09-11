#!/usr/bin/env bash
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.

export LC_ALL=C.UTF-8

# Keep the production sanitizer/compiler policy; narrow only build/test scope.
# shellcheck source=ci/test/00_setup_env_native_asan.sh
source "$(dirname "${BASH_SOURCE[0]}")/00_setup_env_native_asan.sh"

export CONTAINER_NAME=ci_native_asan_regression
export PACKAGES="cmake systemtap-sdt-dev clang-17 llvm-17 libclang-rt-17-dev python3-zmq ${BPFCC_PACKAGE}"
export DEP_OPTS="${DEP_OPTS} NO_QT=1 NO_UPNP=1 NO_NATPMP=1"
export BITCOIN_CONFIG="${BITCOIN_CONFIG} --with-gui=no --disable-tests --disable-bench --disable-fuzz-binary"
export GOAL="-C src blackcoind blackcoin-cli"
export RUN_UNIT_TESTS=false
export RUN_UNIT_TESTS_SEQUENTIAL=false
export RUN_FUNCTIONAL_TESTS=true
export RUN_FUZZ_TESTS=false
export CI_REGRESSION_ONLY=true
export CCACHE_MAXSIZE=1G
