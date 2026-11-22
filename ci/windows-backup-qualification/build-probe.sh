#!/usr/bin/env bash
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
#
# Build the flush probe from the real sources of a Blackcoin checkout.
#
#   build-probe.sh <checkout of the commit under qualification> <output directory>
#
# PROBE_TARGET=windows (default): cross-compile flush_probe.exe with x86_64-w64-mingw32-g++ (the posix-thread variant the
#                                 release build selects with update-alternatives).
# PROBE_TARGET=native:            compile and link the same sources for the host (a link check only: the checks need Windows).
#
# The real src/wallet/quantum_return_backup.cpp is included by flush_probe.cpp. The other real source files below are the
# smallest closure the linker asked for (measured on a host build); the stubs in flush_probe.cpp stand for random.cpp,
# chainparams.cpp, util/check.cpp and util/getuniquepath.cpp, which would pull in the rest of the node.
set -euo pipefail

SRC=${1:?usage: build-probe.sh <checkout> <output directory>}
OUT=${2:?usage: build-probe.sh <checkout> <output directory>}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TARGET=${PROBE_TARGET:-windows}
test -f "$SRC/src/wallet/quantum_return_backup.cpp" || { echo "no quantum_return_backup.cpp in $SRC" >&2; exit 1; }
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

SOURCES=(
  common/args.cpp
  common/settings.cpp
  chainparamsbase.cpp
  util/chaintype.cpp
  util/strencodings.cpp
  util/string.cpp
  util/fs.cpp
  util/fs_helpers.cpp
  util/time.cpp
  util/syserror.cpp
  util/threadnames.cpp
  crypto/sha256.cpp
  logging.cpp
  univalue/lib/univalue.cpp
  univalue/lib/univalue_get.cpp
  univalue/lib/univalue_read.cpp
  univalue/lib/univalue_write.cpp
)
COMMON_FLAGS=(-std=c++20 -O1 -g0 -w "-I$SRC/src" "-I$SRC/src/univalue/include")
if [[ "$TARGET" == windows ]]; then
  CXX=${CXX:-x86_64-w64-mingw32-g++}
  EXE=flush_probe.exe
  # The defines of configure.ac for the Windows target (CORE_CPPFLAGS), and no HAVE_CONFIG_H: no generated header is needed.
  FLAGS=("${COMMON_FLAGS[@]}" -D_MT -DWIN32 -D_WINDOWS -D_WIN32_WINNT=0x0601 -D_WIN32_IE=0x0501 -DWIN32_LEAN_AND_MEAN -DNOMINMAX)
  LINK=(-static -static-libgcc -static-libstdc++ -pthread -lshell32 -ladvapi32 -lole32 -lshlwapi -lws2_32)
else
  CXX=${CXX:-c++}
  EXE=flush_probe
  FLAGS=("${COMMON_FLAGS[@]}")
  LINK=()
fi

OBJ="$OUT/obj"
rm -rf "$OBJ"
mkdir -p "$OBJ"
objects=()
for source in "${SOURCES[@]}"; do
  object="$OBJ/$(echo "$source" | tr '/' '_').o"
  "$CXX" "${FLAGS[@]}" -c "$SRC/src/$source" -o "$object"
  objects+=("$object")
done
# the probe itself includes the real src/wallet/quantum_return_backup.cpp
"$CXX" "${FLAGS[@]}" -c "$HERE/flush_probe.cpp" -o "$OBJ/flush_probe.o"
"$CXX" "${FLAGS[@]}" "$OBJ/flush_probe.o" "${objects[@]}" ${LINK[@]+"${LINK[@]}"} -o "$OUT/$EXE"

# provenance: compiler, the sources by hash, the build script
{
  echo "target=$TARGET"
  echo "compiler=$("$CXX" --version | head -n 1)"
  echo "checkout_head=$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
  for source in wallet/quantum_return_backup.cpp wallet/quantum_return_backup.h "${SOURCES[@]}"; do
    echo "source $(sha256sum "$SRC/src/$source" 2>/dev/null || shasum -a 256 "$SRC/src/$source")"
  done
  echo "harness_source $(sha256sum "$HERE/flush_probe.cpp" 2>/dev/null || shasum -a 256 "$HERE/flush_probe.cpp")"
  echo "build_script $(sha256sum "${BASH_SOURCE[0]}" 2>/dev/null || shasum -a 256 "${BASH_SOURCE[0]}")"
} > "$OUT/flush_probe.provenance.txt"
(cd "$OUT" && { sha256sum "$EXE" 2>/dev/null || shasum -a 256 "$EXE"; } > "$EXE.sha256")
echo "built $OUT/$EXE"
