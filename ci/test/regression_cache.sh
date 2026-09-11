#!/usr/bin/env bash
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.

export LC_ALL=C

set -euo pipefail

if [[ $# != 3 ]]; then
  echo "Usage: $0 restore|save ci_native_asan_regression|ci_native_tsan_regression HOST_CACHE_DIR" >&2
  exit 2
fi
mode=$1
container=$2
case "$mode" in restore|save) ;; *) echo "Invalid cache operation" >&2; exit 2 ;; esac
case "$container" in
  ci_native_asan_regression|ci_native_tsan_regression) ;;
  *) echo "Unsupported regression container" >&2; exit 2 ;;
esac
# Docker --mount uses commas as separators; do not reinterpret a host path.
case "$3" in
  ''|*','*|*$'\n'*) echo "Unsupported cache path" >&2; exit 2 ;;
esac
mkdir -p -- "$3/$container"
cache_dir=$(cd -- "$3/$container" && pwd -P)
host_uid=$(id -u)
host_gid=$(id -g)
for kind in ccache depends; do
  docker volume create "${container}_${kind}" >/dev/null
done
# Copy only these two cache directories. Merge without deleting existing
# entries; neither source checkout nor unrelated Docker state is mounted.
docker run --rm --network=none \
  --mount "type=bind,src=$cache_dir,dst=/cache" \
  --mount "type=volume,src=${container}_ccache,dst=/volumes/ccache" \
  --mount "type=volume,src=${container}_depends,dst=/volumes/depends" \
  ubuntu:24.04 bash -euo pipefail -c '
    for kind in ccache depends; do
      if [[ $1 == restore ]]; then
        if [[ -d /cache/$kind ]]; then
          cp -a /cache/"$kind"/. /volumes/"$kind"/
        fi
      else
        mkdir -p /cache/"$kind"
        cp -a /volumes/"$kind"/. /cache/"$kind"/
        chown -R "$2:$3" /cache/"$kind"
        chmod -R u+rwX /cache/"$kind"
      fi
    done
  ' regression-cache "$mode" "$host_uid" "$host_gid"
