#!/usr/bin/env bash

# Atomically align the persistent Compose, image-policy, and endpoint-guard
# desired state after the direct all-32 v30.1.4 service restoration.

set -Eeuo pipefail
umask 077
export LC_ALL=C TZ=UTC

readonly PKG=/mnt/pulsar/Blackcoin_Blocks/operations/v30.1.4-packages/rollout-express-readoption-20260806T1323Z/seal-root/v30.1.4-rollout-transaction
readonly ENV_FILE=/mnt/pulsar/Blackcoin_Blocks/operations/v30.1.4-packages/rollout-express-c15d60a/rollout.env
readonly RUN=/mnt/pulsar/Blackcoin_Blocks/operations/v30.1.4-fleet-rollout/rollout-20260806T094713Z
STAGE="/mnt/pulsar/Blackcoin_Blocks/operations/v30.1.4-packages/direct-all32-triplet-$(date -u +%Y%m%dT%H%M%SZ)"
readonly STAGE
readonly EXPECTED_CURRENT_COMPOSE=75d405222a36e716fedb1193033bf9ab69abf7ca856e14fef76c0b38e2dcdcf0
readonly EXPECTED_CURRENT_POLICY=257cd6530fae932181d5414f89c792117c36cd29657f02de6ef06e47806322fb
readonly EXPECTED_CURRENT_GUARD=c710b17da501796a6e184f7692a9d01ca5173e2d0aab7ef60e3e8544396b4fc7
readonly EXPECTED_FINAL_POLICY=fd54e0a02d01def8dc7f0d2001f1ed78b06933f8fa0d2ac63b4f822ffdb95a72
readonly EXPECTED_FINAL_GUARD=eddb1bd591633f813483da873bcdfb8ca9d2ec748a263a6d7197ec54e924bfbe

# shellcheck disable=SC1090
source "$ENV_FILE"
export RESUME_RUN_DIR="$RUN"
export SEALED_TRANSACTION_PACKAGE_ROOT=/mnt/pulsar/Blackcoin_Blocks/operations/v30.1.4-packages/rollout-express-c15d60a/seal-root/v30.1.4-rollout-transaction
export PATH="$PKG/tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
set -- plan
# shellcheck disable=SC1090,SC1091
source "$PKG/fleet_rollout.sh" >/dev/null

install -d -m 700 -o root -g root "$STAGE"
[[ ! -L /var/run/blackcoin-v30.1.4-fleet-rollout.lock ]]
exec 19>/var/run/blackcoin-v30.1.4-fleet-rollout.lock
flock -n 19 || die 'another rollout/direct writer is active'

direct_triplet_cleanup()
{
    local rc=$?
    trap - EXIT
    release_wave_locks >/dev/null 2>&1 || true
    flock -u 19 2>/dev/null || true
    exec 19>&- 2>/dev/null || true
    exit "$rc"
}

trap direct_triplet_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# shellcheck disable=SC2034
CURRENT_WAVE_DIR="$STAGE"
# shellcheck disable=SC2034
mapfile -t CURRENT_WAVE_NODES < <(seq 1 32)
acquire_wave_locks
verify_maintenance_marker || die 'maintenance is not active for this run'
verify_free_claim_pause || die 'Free Claim is not paused'
assert_empty_control_marker "$ENABLE_GUARD_STARTS" || die 'guard-start marker invalid'
assert_empty_control_marker "$STATE_DIR/ENABLE_WALLET_RUNTIME" ||
    die 'wallet-runtime marker invalid'
verify_node30_role_policy
verify_current_policy_assets
[[ "$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')" == "$EXPECTED_CURRENT_COMPOSE" ]]
[[ "$(sha256sum "$IMAGE_POLICY" | awk '{print $1}')" == "$EXPECTED_CURRENT_POLICY" ]]
[[ "$(sha256sum "$ENDPOINT_GUARD" | awk '{print $1}')" == "$EXPECTED_CURRENT_GUARD" ]]

install -m 600 -o root -g root "$COMPOSE_FILE" "$STAGE/docker-compose.before.yml"
install -m 600 -o root -g root "$IMAGE_POLICY" "$STAGE/fleet-image-policy.before.json"
install -m 600 -o root -g root "$ENDPOINT_GUARD" \
    "$STAGE/blackcoin_endpoint_guard.before.sh"
install -m 600 -o root -g root "$COMPOSE_FILE" "$STAGE/docker-compose.candidate.yml"

services_csv=
for node in $(seq 1 32); do
    service=$(service_for "$node")
    services_csv+="${services_csv:+,}$service"
done
verify_compose_candidate "$services_csv"

input="$IMAGE_POLICY"
i=0
for group in '1 2 3 4' '5 6 7 8' '9 10 11 12' '13 14 15 16' \
             '17 18 19 20' '21 22 23 24' '25 26 27 28' '29 30 31 32'; do
    i=$((i + 1))
    output=$(printf '%s/fleet-image-policy.pass-%02d.json' "$STAGE" "$i")
    read -r -a nodes <<< "$group"
    "$RENDER_POLICY" "$input" "$output" "$CANDIDATE_IMAGE_REF" \
        "$CANDIDATE_IMAGE_ID" "${nodes[@]}"
    input="$output"
done

jq -e --arg ref "$CANDIDATE_IMAGE_REF" --arg id "$CANDIDATE_IMAGE_ID" '
  .schema == 1 and (.nodes | length) == 32 and
  .images.final3014 == {config_image:$ref,image_id:$id} and
  all(.nodes[]; . == "final3014")
' "$input" >/dev/null
policy_sha=$(sha256sum "$input" | awk '{print $1}')
[[ "$policy_sha" == "$EXPECTED_FINAL_POLICY" ]]
"$RENDER_GUARD" "$ENDPOINT_GUARD" \
    "$STAGE/blackcoin_endpoint_guard.candidate.sh" "$policy_sha"
triplet_policy_guard_valid "$input" "$STAGE/blackcoin_endpoint_guard.candidate.sh"
[[ "$(sha256sum "$STAGE/blackcoin_endpoint_guard.candidate.sh" | awk '{print $1}')" == "$EXPECTED_FINAL_GUARD" ]]

sha256sum "$STAGE/docker-compose.before.yml" \
    "$STAGE/fleet-image-policy.before.json" \
    "$STAGE/blackcoin_endpoint_guard.before.sh" \
    "$STAGE/docker-compose.candidate.yml" "$input" \
    "$STAGE/blackcoin_endpoint_guard.candidate.sh" > "$STAGE/TRIPLET-CANDIDATES.sha256"
chmod 600 "$STAGE/TRIPLET-CANDIDATES.sha256"
sync -f "$STAGE/TRIPLET-CANDIDATES.sha256"

install_triplet "$STAGE/docker-compose.candidate.yml" "$input" \
    "$STAGE/blackcoin_endpoint_guard.candidate.sh"
verify_current_policy_assets
jq -e '(.nodes | length) == 32 and all(.nodes[]; . == "final3014")' \
    "$IMAGE_POLICY" >/dev/null
model=$(docker compose -f "$COMPOSE_FILE" config --format json)
for node in $(seq 1 32); do
    service=$(service_for "$node")
    jq -e --arg service "$service" --arg ref "$CANDIDATE_IMAGE_REF" \
        '.services[$service].image == $ref' >/dev/null <<< "$model"
done
[[ "$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')" == "$EXPECTED_CURRENT_COMPOSE" ]]
[[ "$(sha256sum "$IMAGE_POLICY" | awk '{print $1}')" == "$EXPECTED_FINAL_POLICY" ]]
[[ "$(sha256sum "$ENDPOINT_GUARD" | awk '{print $1}')" == "$EXPECTED_FINAL_GUARD" ]]
sha256sum "$COMPOSE_FILE" "$IMAGE_POLICY" "$ENDPOINT_GUARD" > \
    "$STAGE/LIVE-TRIPLET.after.sha256"
chmod 600 "$STAGE/LIVE-TRIPLET.after.sha256"
sync -f "$STAGE/LIVE-TRIPLET.after.sha256"
sync -f "$STAGE"

release_wave_locks
flock -u 19
exec 19>&-
trap - EXIT HUP INT TERM
printf 'triplet=installed compose=%s policy=%s guard=%s evidence=%s\n' \
    "$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')" \
    "$(sha256sum "$IMAGE_POLICY" | awk '{print $1}')" \
    "$(sha256sum "$ENDPOINT_GUARD" | awk '{print $1}')" "$STAGE"
