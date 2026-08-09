# shellcheck shell=bash
# BEGIN V30.1.5 ROLLOUT MAINTENANCE INHIBITOR
V3015_ROLLOUT_MARKER="$STATE_DIR/V30_1_5_ROLLOUT_MAINTENANCE.json"
v3015_rollout_marker_valid() {
    local marker=$V3015_ROLLOUT_MARKER run_dir nonce state authority source_sha
    [[ -f "$marker" && ! -L "$marker" &&
       "$(stat -c '%u:%g:%a:%h' "$marker" 2>/dev/null)" == 0:0:600:1 ]] || return 1
    run_dir=$(jq -er '.run_dir' "$marker" 2>/dev/null) || return 1
    nonce=$(jq -er '.nonce' "$marker" 2>/dev/null) || return 1
    state=$(jq -er '.state' "$marker" 2>/dev/null) || return 1
    source_sha=$(jq -er '.source_sha' "$marker" 2>/dev/null) || return 1
    [[ "$run_dir" =~ ^/mnt/pulsar/Blackcoin_Blocks/operations/v30[.]1[.]5-rollout/run-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$ ]] || return 1
    [[ "$nonce" =~ ^[0-9a-f]{32}$ && "$source_sha" =~ ^[0-9a-f]{40}$ &&
       "$state" == active ]] || return 1
    [[ -d "$run_dir" && ! -L "$run_dir" &&
       "$(stat -c '%u:%g:%a' "$run_dir" 2>/dev/null)" == 0:0:700 ]] || return 1
    authority="$run_dir/AUTHORITY"
    [[ -f "$authority" ]] || authority="$run_dir/rollout-authority.json"
    [[ -f "$authority" && ! -L "$authority" &&
       "$(stat -c '%u:%g:%a:%h' "$authority" 2>/dev/null)" == 0:0:600:1 ]] || return 1
    jq -e --arg run "$run_dir" --arg nonce "$nonce" --arg source "$source_sha" '
      . == {schema:1,transaction:"v30.1.5-fleet-rollout",state:"active",
            run_dir:$run,nonce:$nonce,source_sha:$source}
    ' "$marker" >/dev/null 2>&1 || return 1
    jq -e --arg source "$source_sha" --arg nonce "$nonce" '
      type == "object" and (keys | sort) == ["live_execution_confirmation",
        "native_restart_confirmation","node30_probe_tool_sha256","nonce",
        "package_sha256sums_sha256","phase_b_result_sha256","schema","source_sha"] and
      .schema == 1 and .source_sha == $source and .nonce == $nonce and
      .live_execution_confirmation == ("v30.1.5:" + $source + ":" + $nonce) and
      .native_restart_confirmation ==
        ("v30.1.5-native-restart:" + $source + ":" + $nonce) and
      (.phase_b_result_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.package_sha256sums_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.node30_probe_tool_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    ' "$authority" >/dev/null 2>&1 || return 1
}
if [[ -e "$V3015_ROLLOUT_MARKER" || -L "$V3015_ROLLOUT_MARKER" ]]; then
    if v3015_rollout_marker_valid; then
        logger -t blackcoin-v3015-rollout 'v30.1.5 rollout active; supervisor mutation inhibited' || true
        exit 0
    fi
    logger -t blackcoin-v3015-rollout 'invalid v30.1.5 rollout marker; supervisor mutation refused' || true
    exit 1
fi
# END V30.1.5 ROLLOUT MAINTENANCE INHIBITOR
