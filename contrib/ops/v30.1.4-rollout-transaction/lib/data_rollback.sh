#!/usr/bin/env bash

# Reversible data boundary for the v30.1.4 fleet transaction. Callers must
# stop every target container cleanly before snapshot or restore.

set -Eeuo pipefail

readonly FLEET_ZFS_PARENT='pulsar/Blackcoin_Blocks'

data_domain_for()
{
    local node="$1" role="$2" path="$3" dataset padded
    padded=$(node_padded "$node") || return 1
    [[ -d "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" ]] || return 1
    dataset=$(findmnt -n -o SOURCE -T "$path") || return 1
    zfs list -H -o name "$dataset" >/dev/null 2>&1 || return 1
    if [[ "$dataset" == "$FLEET_ZFS_PARENT" ]]; then
        [[ "$role" == raw && "$node" -ge 28 && "$node" -le 32 ]] || return 1
        printf 'fileset|%s\n' "$dataset"
        return 0
    fi
    [[ "${dataset##*/}" == "node-$padded" ]] || return 1
    [[ "$dataset" == "$FLEET_ZFS_PARENT"/* ]] || return 1
    printf 'zfs|%s\n' "$dataset"
}

verify_all_data_domains()
{
    local node data_path raw_path data_domain raw_domain dataset key prior
    local -A seen=()
    local -a roots=()
    for node in $(seq 1 "$NODE_COUNT"); do
        data_path=$(host_datadir_for "$node")
        raw_path="$(host_blocks_for "$node")/blocks"
        data_domain=$(data_domain_for "$node" data "$data_path") || return 1
        raw_domain=$(data_domain_for "$node" raw "$raw_path") || return 1
        for key in "$data_domain" "$raw_domain"; do
            dataset=${key#*|}
            if [[ "${key%%|*}" == zfs ]]; then
                [[ -z "${seen[$dataset]:-}" ]] || return 1
                for prior in "${roots[@]}"; do
                    [[ "$dataset" != "$prior"/* && "$prior" != "$dataset"/* ]] || return 1
                done
                seen[$dataset]="$node"
                roots+=("$dataset")
            fi
        done
    done
    dataset=$(findmnt -n -o SOURCE -T "$OPS_ROOT") || return 1
    [[ "$dataset" == "$FLEET_ZFS_PARENT" ]] || return 1
}

snapshot_property()
{
    local snapshot="$1" property="$2"
    zfs get -H -p -o value "$property" "$snapshot" 2>/dev/null
}

snapshot_has_hold()
{
    local snapshot="$1" tag="$2"
    zfs holds -H "$snapshot" 2>/dev/null | awk -v wanted="$tag" '$2 == wanted {found=1} END {exit !found}'
}

record_recursive_snapshot()
{
    local node="$1" role="$2" root="$3" path="$4" suffix="$5" hold_tag="$6" output="$7"
    local before after snapshot guid txg count=0
    before=$(zfs list -H -r -o name "$root" | sort) || return 1
    zfs snapshot -r "$root@$suffix" || return 1
    after=$(zfs list -H -r -o name "$root" | sort) || return 1
    [[ "$before" == "$after" ]] || return 1
    while IFS= read -r snapshot; do
        [[ "$snapshot" == *@"$suffix" ]] || continue
        guid=$(snapshot_property "$snapshot" guid) || return 1
        txg=$(snapshot_property "$snapshot" createtxg) || return 1
        [[ "$guid" =~ ^[1-9][0-9]*$ && "$txg" =~ ^[1-9][0-9]*$ ]] || return 1
        zfs hold "$hold_tag" "$snapshot" || return 1
        snapshot_has_hold "$snapshot" "$hold_tag" || return 1
        printf 'ZFS|%02d|%s|%s|%s|%s|%s|%s|%s\n' \
            "$node" "$role" "$root" "$path" "$snapshot" "$guid" "$txg" "$hold_tag" >> "$output"
        count=$((count + 1))
    done < <(zfs list -H -r -t snapshot -o name "$root" | grep -E "@${suffix}$" | sort)
    ((count >= 1))
}

record_parent_fileset_snapshot()
{
    local suffix="$1" hold_tag="$2" output="$3" snapshot guid txg mountpoint
    snapshot="$FLEET_ZFS_PARENT@$suffix"
    ! zfs list -H -o name "$snapshot" >/dev/null 2>&1 || return 1
    zfs snapshot "$snapshot" || return 1
    guid=$(snapshot_property "$snapshot" guid) || return 1
    txg=$(snapshot_property "$snapshot" createtxg) || return 1
    mountpoint=$(zfs get -H -o value mountpoint "$FLEET_ZFS_PARENT") || return 1
    [[ "$mountpoint" == /mnt/pulsar/Blackcoin_Blocks ]] || return 1
    zfs hold "$hold_tag" "$snapshot" 2>/dev/null || snapshot_has_hold "$snapshot" "$hold_tag" || return 1
    snapshot_has_hold "$snapshot" "$hold_tag" || return 1
    printf '%s|%s|%s|%s\n' "$snapshot" "$guid" "$txg" "$mountpoint"
}

snapshot_wave_data()
{
    local suffix hold_tag temporary node role path domain kind dataset
    local parent_record='' parent_snapshot parent_guid parent_txg parent_mount relative source
    suffix="v3014-${RUN_DIR##*/}-${CURRENT_WAVE_DIR##*/}"
    hold_tag="v3014-${RUN_DIR##*/}"
    temporary=$(mktemp "$CURRENT_WAVE_DIR/.data-snapshots.XXXXXX")
    : > "$temporary"
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        for role in data raw; do
            if [[ "$role" == data ]]; then
                path=$(host_datadir_for "$node")
            else
                path="$(host_blocks_for "$node")/blocks"
            fi
            domain=$(data_domain_for "$node" "$role" "$path") || return 1
            IFS='|' read -r kind dataset <<< "$domain"
            if [[ "$kind" == zfs ]]; then
                record_recursive_snapshot "$node" "$role" "$dataset" "$path" \
                    "$suffix" "$hold_tag" "$temporary" || return 1
            else
                if [[ -z "$parent_record" ]]; then
                    parent_record=$(record_parent_fileset_snapshot "$suffix" "$hold_tag" "$temporary") || return 1
                fi
                IFS='|' read -r parent_snapshot parent_guid parent_txg parent_mount <<< "$parent_record"
                relative=${path#"$parent_mount"/}
                [[ "$relative" != "$path" && "$relative" != /* && "$relative" != *'..'* ]] || return 1
                source="$parent_mount/.zfs/snapshot/${parent_snapshot#*@}/$relative"
                [[ -d "$source" && ! -L "$source" ]] || return 1
                printf 'FILESET|%02d|%s|%s|%s|%s|%s|%s|%s|%s\n' \
                    "$node" "$role" "$FLEET_ZFS_PARENT" "$path" "$parent_snapshot" \
                    "$parent_guid" "$parent_txg" "$hold_tag" "$source" >> "$temporary"
            fi
        done
    done
    [[ -s "$temporary" ]] || return 1
    chmod 600 "$temporary"
    chown root:root "$temporary"
    mv -fT -- "$temporary" "$CURRENT_WAVE_DIR/data-snapshots.tsv"
    sha256sum "$CURRENT_WAVE_DIR/data-snapshots.tsv" | awk '{print $1}' \
        > "$CURRENT_WAVE_DIR/data-snapshots.tsv.sha256"
    chmod 600 "$CURRENT_WAVE_DIR/data-snapshots.tsv.sha256"
    chown root:root "$CURRENT_WAVE_DIR/data-snapshots.tsv.sha256"
    sync -f "$CURRENT_WAVE_DIR/data-snapshots.tsv"
    sync -f "$CURRENT_WAVE_DIR/data-snapshots.tsv.sha256"
    sync -f "$CURRENT_WAVE_DIR"
}

verify_wave_snapshot_inventory()
{
    local require_live=${1:-1}
    local inventory="$CURRENT_WAVE_DIR/data-snapshots.tsv" expected type node role root path
    local snapshot guid txg hold_tag source actual_guid actual_txg count=0 dataset key
    local expected_suffix expected_hold expected_path expected_domain expected_kind expected_root
    local expected_source parent_mount member=0 current_datasets recorded_datasets
    local -A covered=() snapshots=() rows=()
    [[ "$require_live" == 0 || "$require_live" == 1 ]] || return 1
    [[ -f "$inventory" && ! -L "$inventory" &&
       "$(stat -c '%u:%g:%a' "$inventory")" == 0:0:600 ]] || return 1
    [[ -f "$CURRENT_WAVE_DIR/data-snapshots.tsv.sha256" &&
       ! -L "$CURRENT_WAVE_DIR/data-snapshots.tsv.sha256" &&
       "$(realpath -e -- "$CURRENT_WAVE_DIR/data-snapshots.tsv.sha256")" == "$CURRENT_WAVE_DIR/data-snapshots.tsv.sha256" &&
       "$(stat -c '%u:%g:%a' "$CURRENT_WAVE_DIR/data-snapshots.tsv.sha256")" == 0:0:600 ]] ||
        return 1
    expected=$(cat "$CURRENT_WAVE_DIR/data-snapshots.tsv.sha256" 2>/dev/null) || return 1
    valid_sha256_hex "$expected" || return 1
    [[ "$(sha256sum "$inventory" | awk '{print $1}')" == "$expected" ]] || return 1
    expected_suffix="v3014-${RUN_DIR##*/}-${CURRENT_WAVE_DIR##*/}"
    expected_hold="v3014-${RUN_DIR##*/}"
    while IFS='|' read -r type node role root path snapshot guid txg hold_tag source; do
        [[ "$type" == ZFS || "$type" == FILESET ]] || return 1
        valid_node "$((10#$node))" || return 1
        member=0
        for key in "${CURRENT_WAVE_NODES[@]}"; do
            [[ "$((10#$node))" -eq "$key" ]] && member=1
        done
        ((member == 1)) || return 1
        [[ "$role" == data || "$role" == raw ]] || return 1
        if [[ "$role" == data ]]; then
            expected_path=$(host_datadir_for "$((10#$node))")
        else
            expected_path="$(host_blocks_for "$((10#$node))")/blocks"
        fi
        [[ "$path" == "$expected_path" ]] || return 1
        expected_domain=$(data_domain_for "$((10#$node))" "$role" "$path") || return 1
        IFS='|' read -r expected_kind expected_root <<< "$expected_domain"
        [[ "$hold_tag" == "$expected_hold" && "${snapshot#*@}" == "$expected_suffix" ]] || return 1
        dataset=${snapshot%@*}
        [[ "$root" == "$expected_root" &&
           ( "$dataset" == "$root" || "$dataset" == "$root"/* ) &&
           "$guid" =~ ^[1-9][0-9]*$ &&
           "$txg" =~ ^[1-9][0-9]*$ ]] || return 1
        if [[ "$require_live" -eq 1 ]]; then
            actual_guid=$(snapshot_property "$snapshot" guid) || return 1
            actual_txg=$(snapshot_property "$snapshot" createtxg) || return 1
            [[ "$actual_guid" == "$guid" && "$actual_txg" == "$txg" ]] || return 1
            snapshot_has_hold "$snapshot" "$hold_tag" || return 1
        fi
        if [[ "$type" == FILESET ]]; then
            [[ "$expected_kind" == fileset && "$role" == raw &&
               "$root" == "$FLEET_ZFS_PARENT" ]] || return 1
            parent_mount=$(zfs get -H -o value mountpoint "$FLEET_ZFS_PARENT") || return 1
            expected_source="$parent_mount/.zfs/snapshot/$expected_suffix/${path#"$parent_mount"/}"
            [[ "$source" == "$expected_source" && -z "${rows[$node|$role]:-}" ]] || return 1
            if [[ "$require_live" -eq 1 ]]; then
                [[ -d "$source" && ! -L "$source" ]] || return 1
            fi
            rows["$node|$role"]=1
            if [[ -n "${snapshots[$snapshot]:-}" ]]; then
                [[ "${snapshots[$snapshot]}" == "$guid|$txg|$hold_tag" ]] || return 1
            else
                snapshots[$snapshot]="$guid|$txg|$hold_tag"
            fi
        else
            [[ "$expected_kind" == zfs && -z "$source" && -z "${snapshots[$snapshot]:-}" ]] || return 1
            snapshots[$snapshot]="$guid|$txg|$hold_tag"
        fi
        covered["$((10#$node))|$role"]=1
        count=$((count + 1))
    done < "$inventory"
    ((count >= ${#CURRENT_WAVE_NODES[@]} * 2)) || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        for key in data raw; do
            [[ -n "${covered[$node|$key]:-}" ]] || return 1
            if [[ "$key" == data ]]; then
                expected_path=$(host_datadir_for "$node")
            else
                expected_path="$(host_blocks_for "$node")/blocks"
            fi
            expected_domain=$(data_domain_for "$node" "$key" "$expected_path") || return 1
            IFS='|' read -r expected_kind expected_root <<< "$expected_domain"
            if [[ "$expected_kind" == zfs ]]; then
                current_datasets=$(zfs list -H -r -o name "$expected_root" | sort) || return 1
                recorded_datasets=$(awk -F'|' -v wanted_node="$(node_padded "$node")" \
                    -v wanted_role="$key" -v wanted_root="$expected_root" '
                    $1 == "ZFS" && $2 == wanted_node && $3 == wanted_role && $4 == wanted_root {
                        name=$6; sub(/@.*/, "", name); print name
                    }' "$inventory" | sort) || return 1
                [[ -n "$recorded_datasets" && "$current_datasets" == "$recorded_datasets" ]] ||
                    return 1
            fi
        done
    done
}

restore_filesets_from_inventory()
{
    local expected_authority_sha=${1:-}
    local type node role root path snapshot guid txg hold_tag source proof
    valid_sha256_hex "$expected_authority_sha" || return 1
    while IFS='|' read -r type node role root path snapshot guid txg hold_tag source; do
        [[ "$type" == FILESET ]] || continue
        [[ -d "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" ]] || return 1
        data_rollback_require_fileset_mutation_boundary "$expected_authority_sha" \
            "$node" "$role" "$root" "$path" "$snapshot" "$guid" "$txg" "$hold_tag" \
            "$source" || return 1
        rsync -aHAXx --numeric-ids --delete -- "$source/" "$path/" || return 1
        proof="$CURRENT_WAVE_DIR/fileset-restore-node-${node}-${role}.diff"
        rsync -aHAXxnc --numeric-ids --delete --itemize-changes -- "$source/" "$path/" > "$proof" || return 1
        chmod 600 "$proof"
        chown root:root "$proof"
        [[ ! -s "$proof" ]] || return 1
    done < "$CURRENT_WAVE_DIR/data-snapshots.tsv"
}

data_rollback_verify_snapshot_identity()
{
    local snapshot="$1" expected_guid="$2" expected_txg="$3" hold_tag="$4"
    local actual_guid actual_txg
    actual_guid=$(snapshot_property "$snapshot" guid) || return 1
    actual_txg=$(snapshot_property "$snapshot" createtxg) || return 1
    [[ "$actual_guid" == "$expected_guid" && "$actual_txg" == "$expected_txg" ]] || return 1
    snapshot_has_hold "$snapshot" "$hold_tag"
}

data_rollback_snapshot_absent()
{
    local snapshot="$1" dataset listing name
    dataset=${snapshot%@*}
    zfs list -H -o name "$dataset" >/dev/null 2>&1 || return 1
    listing=$(zfs list -H -r -t snapshot -o name "$dataset") || return 1
    while IFS= read -r name; do
        [[ "$name" == "$snapshot" ]] && return 1
    done <<< "$listing"
    return 0
}

data_rollback_capture_newer_snapshots()
{
    local dataset="$1" transaction_txg="$2" output="$3"
    local name guid txg row_dataset listing
    : > "$output" || return 1
    listing=$(zfs list -H -p -r -t snapshot -o name,guid,createtxg -s createtxg "$dataset") ||
        return 1
    while IFS=$'\t' read -r name guid txg; do
        [[ -n "$name" ]] || continue
        [[ "$name" == *@* && "$guid" =~ ^[1-9][0-9]*$ && "$txg" =~ ^[1-9][0-9]*$ ]] ||
            return 1
        row_dataset=${name%@*}
        [[ "$row_dataset" == "$dataset" ]] || continue
        if ((txg > transaction_txg)); then
            printf '%s|%s|%s\n' "$name" "$guid" "$txg" >> "$output" || return 1
        fi
    done <<< "$listing"
    chmod 600 "$output" && chown root:root "$output" && sync -f "$output"
}

data_rollback_publish_json()
{
    local source="$1" destination="$2"
    chmod 600 "$source" || return 1
    chown root:root "$source" || return 1
    sync -f "$source" || return 1
    mv -fT -- "$source" "$destination" || return 1
    sync -f "$destination" || return 1
    sync -f "${destination%/*}"
}

restore_zfs_from_inventory()
{
    local expected_authority_sha=${1:-}
    local type node role root path snapshot guid txg hold_tag source dataset diff_file
    local dataset_key mountpoint snapshot_source mode mode_file mode_tmp
    local newer_before newer_before_tmp newer_after newer_sha diff_tmp
    local -A seen=()
    valid_sha256_hex "$expected_authority_sha" || return 1
    while IFS='|' read -r type node role root path snapshot guid txg hold_tag source; do
        [[ "$type" == ZFS ]] || continue
        dataset=${snapshot%@*}
        [[ -z "${seen[$dataset]:-}" ]] || return 1
        seen[$dataset]=1
        [[ "$snapshot" == "$dataset@"* && "$guid" =~ ^[1-9][0-9]*$ &&
           "$txg" =~ ^[1-9][0-9]*$ ]] || return 1
        data_rollback_verify_snapshot_identity "$snapshot" "$guid" "$txg" "$hold_tag" ||
            return 1
        dataset_key=${dataset//\//@}
        newer_before="$CURRENT_WAVE_DIR/zfs-restore-${dataset_key}.newer-before.tsv"
        newer_before_tmp=$(mktemp "$CURRENT_WAVE_DIR/.zfs-restore-newer-before.XXXXXX") || return 1
        newer_after="$CURRENT_WAVE_DIR/.zfs-restore-${dataset_key}.newer-after.tsv.$$"
        data_rollback_capture_newer_snapshots "$dataset" "$txg" "$newer_before_tmp" || return 1
        data_rollback_publish_json "$newer_before_tmp" "$newer_before" || return 1
        mountpoint=''
        if [[ ! -s "$newer_before" ]]; then
            # Never pass -r/-R: a concurrently-created newer snapshot makes this
            # exact rollback fail instead of destroying it.
            data_rollback_require_zfs_rollback_boundary "$expected_authority_sha" \
                "$snapshot" "$guid" "$txg" "$hold_tag" || return 1
            zfs rollback "$snapshot" || return 1
            mode=rollback
        else
            mountpoint=$(zfs get -H -o value mountpoint "$dataset") || return 1
            [[ "$(zfs get -H -o value mounted "$dataset")" == yes &&
               "$mountpoint" == /* && -d "$mountpoint" && ! -L "$mountpoint" &&
               "$(realpath -e -- "$mountpoint")" == "$mountpoint" &&
               "$(findmnt -n -o SOURCE -T "$mountpoint")" == "$dataset" &&
               "$(findmnt -n -o TARGET -T "$mountpoint")" == "$mountpoint" ]] || return 1
            snapshot_source="$mountpoint/.zfs/snapshot/${snapshot#*@}"
            [[ -d "$snapshot_source" && ! -L "$snapshot_source" ]] || return 1
            data_rollback_require_zfs_rsync_boundary "$expected_authority_sha" "$dataset" \
                "$snapshot" "$guid" "$txg" "$hold_tag" "$mountpoint" "$snapshot_source" ||
                return 1
            rsync -aHAXx --numeric-ids --delete -- "$snapshot_source/" "$mountpoint/" || return 1
            data_rollback_capture_newer_snapshots "$dataset" "$txg" "$newer_after" || return 1
            cmp -s "$newer_before" "$newer_after" || return 1
            rm -f -- "$newer_after"
            mode=rsync-exact-files
        fi
        data_rollback_verify_snapshot_identity "$snapshot" "$guid" "$txg" "$hold_tag" ||
            return 1
        diff_file="$CURRENT_WAVE_DIR/zfs-restore-${dataset_key}.diff"
        diff_tmp=$(mktemp "$CURRENT_WAVE_DIR/.zfs-restore-diff.XXXXXX") || return 1
        zfs diff -FH "$snapshot" "$dataset" > "$diff_tmp" || return 1
        [[ ! -s "$diff_tmp" ]] || return 1
        data_rollback_publish_json "$diff_tmp" "$diff_file" || return 1
        newer_sha=$(sha256sum "$newer_before" | awk '{print $1}') || return 1
        mode_file="$CURRENT_WAVE_DIR/zfs-restore-${dataset_key}.mode.json"
        mode_tmp=$(mktemp "$CURRENT_WAVE_DIR/.zfs-restore-mode.XXXXXX") || return 1
        jq -n --arg dataset "$dataset" --arg snapshot "$snapshot" --arg guid "$guid" \
            --arg txg "$txg" --arg hold_tag "$hold_tag" --arg mode "$mode" \
            --arg mountpoint "$mountpoint" --arg newer_sha "$newer_sha" \
            '{schema:1,dataset:$dataset,snapshot:$snapshot,guid:$guid,createtxg:$txg,
              hold_tag:$hold_tag,restore_mode:$mode,mountpoint:$mountpoint,
              newer_snapshots_preserved:true,newer_snapshots_evidence_sha256:$newer_sha,
              snapshot_identity_verified:true,snapshot_hold_verified:true,
              snapshot_zero_diff_verified:true}' > "$mode_tmp" || {
                rm -f -- "$mode_tmp"
                return 1
            }
        data_rollback_publish_json "$mode_tmp" "$mode_file" || return 1
    done < <(awk -F'|' '$1 == "ZFS" {name=$6; sub(/@.*/, "", name); depth=gsub("/","/",name); print depth "|" $0}' \
        "$CURRENT_WAVE_DIR/data-snapshots.tsv" | sort -t'|' -k1,1nr | cut -d'|' -f2-)
}

data_rollback_protected_file()
{
    local path="$1" mode=${2:-600}
    [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
       "$(stat -c '%u:%g:%a' "$path")" == "0:0:$mode" ]]
}

data_rollback_protected_directory()
{
    local path="$1" mode=${2:-700}
    [[ -d "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
       "$(stat -c '%u:%g:%a' "$path")" == "0:0:$mode" ]]
}

data_rollback_authority_path()
{
    printf '%s/ROLLBACK-AUTHORITY.json\n' "$CURRENT_WAVE_DIR"
}

data_rollback_canonical_single_object_json()
{
    local path="$1"
    data_rollback_protected_file "$path" 600 || return 1
    cmp -s "$path" <(jq -S -e 'if type == "object" then . else error("object required") end' \
        "$path")
}

data_rollback_validate_stopped_generation()
{
    [[ "$1" =~ ^[0-9a-f]{64}\|[^\|[:space:]]+\|[0-9a-f]{64}\|[^\|[:space:]]+$ ]]
}

data_rollback_verify_wave_nodes_file()
{
    local nodes_file="$CURRENT_WAVE_DIR/NODES" node prior=0
    local -a recorded=()
    data_rollback_protected_file "$nodes_file" 600 || return 1
    [[ "$(wc -l < "$nodes_file")" -eq 1 ]] || return 1
    read -r -a recorded < "$nodes_file" || return 1
    ((${#recorded[@]} == ${#CURRENT_WAVE_NODES[@]} && ${#recorded[@]} > 0)) || return 1
    [[ "${recorded[*]}" == "${CURRENT_WAVE_NODES[*]}" ]] || return 1
    for node in "${recorded[@]}"; do
        valid_node "$node" || return 1
        ((node > prior)) || return 1
        prior=$node
    done
}

data_rollback_verify_authority_context_sealed()
{
    local transaction="$RUN_DIR/TRANSACTION.json"
    local handoff="$RUN_DIR/CANARY-FLEET-HANDOFF.json"
    local drain="$CURRENT_WAVE_DIR/WAVE-DRAIN-EVIDENCE.sha256"
    local inventory="$CURRENT_WAVE_DIR/data-snapshots.tsv"
    local inventory_sidecar="$CURRENT_WAVE_DIR/data-snapshots.tsv.sha256"
    local handoff_required
    valid_rollout_run_dir "$RUN_DIR" || return 1
    data_rollback_protected_directory "$RUN_DIR" 700 || return 1
    [[ "$CURRENT_WAVE_DIR" == "$RUN_DIR"/wave-* ]] || return 1
    data_rollback_protected_directory "$CURRENT_WAVE_DIR" 700 || return 1
    data_rollback_verify_wave_nodes_file || return 1
    data_rollback_protected_file "$transaction" 600 || return 1
    data_rollback_protected_file "$ROLLOUT_MAINTENANCE_MARKER" 600 || return 1
    data_rollback_protected_file "$drain" 600 || return 1
    data_rollback_protected_file "$inventory" 600 || return 1
    data_rollback_protected_file "$inventory_sidecar" 600 || return 1
    verify_transaction_manifest || return 1
    verify_maintenance_marker || return 1
    verify_wave_drain_evidence || return 1
    verify_wave_snapshot_inventory 1 || return 1
    handoff_required=$(jq -er '.canary_handoff.required | select(type == "boolean")' \
        "$transaction") || return 1
    if [[ "$handoff_required" == true ]]; then
        data_rollback_protected_file "$handoff" 600 || return 1
        verify_canary_fleet_handoff || return 1
    else
        [[ "$handoff_required" == false && ! -e "$handoff" && ! -L "$handoff" ]] || return 1
    fi
}

data_rollback_verify_safe_boundary_sealed()
{
    local node="$1" stopped_generation="$2"
    local path activation prefix baseline prelaunch wallet staking mining recovery txids
    local activation_sha transaction_sha drain_sha baseline_sha txids_sha fee
    path=$(wave_node_safe_rollback_path "$node") || return 1
    activation=$(wave_node_activation_path "$node") || return 1
    prefix=$(wave_node_prefix "$node") || return 1
    baseline=$(candidate_recovery_baseline_path "$node") || return 1
    prelaunch="${prefix}-wallet-txids.prelaunch.json"
    wallet="${prefix}-safe-wallet.json"
    staking="${prefix}-safe-staking.json"
    mining="${prefix}-safe-mining.json"
    recovery="${prefix}-safe-recovery.json"
    txids="${prefix}-safe-wallet-txids.json"
    for file in "$path" "$activation" "$baseline" "${baseline}.sha256" "$prelaunch" \
        "$wallet" "$staking" "$mining" "$recovery" "$txids"; do
        data_rollback_protected_file "$file" 600 || return 1
    done
    verify_candidate_recovery_baseline "$node" || return 1
    fee=$(candidate_recovery_fee_for "$node") || return 1
    candidate_safe_rollback_state_is_clean "$wallet" "$staking" "$mining" "$recovery" "$fee" ||
        return 1
    cmp -s "$prelaunch" "$txids" || return 1
    transaction_sha=$(sha256sum "$RUN_DIR/TRANSACTION.json" | awk '{print $1}') || return 1
    drain_sha=$(sha256sum "$(wave_drain_manifest_path)" | awk '{print $1}') || return 1
    baseline_sha=$(sha256sum "$baseline" | awk '{print $1}') || return 1
    txids_sha=$(sha256sum "$prelaunch" | awk '{print $1}') || return 1
    jq -e --argjson node "$node" --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
        --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
        --arg generation "$stopped_generation" --arg transaction_sha "$transaction_sha" \
        --arg drain_sha "$drain_sha" --arg baseline_sha "$baseline_sha" --arg txids_sha "$txids_sha" '
        .schema == 1 and .transaction == "v30.1.4-fleet-rollout" and
        .boundary == "before-first-wallet-unlock" and .activation_attempted == true and
        .node == $node and .run_dir == $run and .wave_dir == $wave and
        .candidate_image == $image and .candidate_image_id == $image_id and
        .container_generation == $generation and
        .transaction_manifest_sha256 == $transaction_sha and
        .wave_drain_manifest_sha256 == $drain_sha and
        .candidate_recovery_baseline_sha256 == $baseline_sha and
        .prelaunch_wallet_txids_sha256 == $txids_sha and
        .fee_payments_authorized == false and (.created_at | type) == "string"
    ' "$activation" >/dev/null || return 1
    activation_sha=$(sha256sum "$activation" | awk '{print $1}') || return 1
    jq -e --argjson node "$node" --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
        --arg generation "$stopped_generation" --arg activation_sha "$activation_sha" \
        --arg transaction_sha "$transaction_sha" --arg drain_sha "$drain_sha" \
        --arg wallet_sha "$(sha256sum "$wallet" | awk '{print $1}')" \
        --arg staking_sha "$(sha256sum "$staking" | awk '{print $1}')" \
        --arg mining_sha "$(sha256sum "$mining" | awk '{print $1}')" \
        --arg recovery_sha "$(sha256sum "$recovery" | awk '{print $1}')" \
        --arg txids_sha "$(sha256sum "$txids" | awk '{print $1}')" \
        --arg prelaunch_sha "$txids_sha" --argjson fee "$fee" '
        .schema == 1 and .transaction == "v30.1.4-fleet-rollout" and
        .boundary == "candidate-safe-for-data-rollback" and .rollback_permitted == true and
        .node == $node and .run_dir == $run and .wave_dir == $wave and
        .container_generation == $generation and
        .activation_marker_sha256 == $activation_sha and
        .transaction_manifest_sha256 == $transaction_sha and
        .wave_drain_manifest_sha256 == $drain_sha and
        .wallet_locked == true and .staking_off == true and .pow_clean_off == true and
        .recovery_clean == true and .confirmed_resolution_fees == $fee and
        .fee_unchanged == true and .wallet_transaction_set_unchanged == true and
        .evidence == {wallet_sha256:$wallet_sha,staking_sha256:$staking_sha,
          mining_sha256:$mining_sha,recovery_sha256:$recovery_sha,
          wallet_txids_sha256:$txids_sha,prelaunch_wallet_txids_sha256:$prelaunch_sha} and
        (.created_at | type) == "string"
    ' "$path" >/dev/null
}

data_rollback_verify_authority_sealed()
{
    local expected_sha=${1:-} authority transaction handoff maintenance drain inventory
    local actual_sha transaction_sha handoff_sha maintenance_sha drain_sha inventory_sha
    local handoff_required launch_marker launch_state launch_sha node expected_nodes_json
    local safe safe_sha stopped_generation entry_count attempted_count=0 actual_marker_count
    authority=$(data_rollback_authority_path) || return 1
    valid_sha256_hex "$expected_sha" || return 1
    data_rollback_protected_file "$authority" 600 || return 1
    data_rollback_canonical_single_object_json "$authority" || return 1
    actual_sha=$(sha256sum "$authority" | awk '{print $1}') || return 1
    [[ "$actual_sha" == "$expected_sha" ]] || return 1
    data_rollback_verify_authority_context_sealed || return 1
    transaction="$RUN_DIR/TRANSACTION.json"
    handoff="$RUN_DIR/CANARY-FLEET-HANDOFF.json"
    maintenance="$ROLLOUT_MAINTENANCE_MARKER"
    drain="$CURRENT_WAVE_DIR/WAVE-DRAIN-EVIDENCE.sha256"
    inventory="$CURRENT_WAVE_DIR/data-snapshots.tsv"
    transaction_sha=$(sha256sum "$transaction" | awk '{print $1}') || return 1
    maintenance_sha=$(sha256sum "$maintenance" | awk '{print $1}') || return 1
    drain_sha=$(sha256sum "$drain" | awk '{print $1}') || return 1
    inventory_sha=$(sha256sum "$inventory" | awk '{print $1}') || return 1
    [[ "$(cat "$CURRENT_WAVE_DIR/data-snapshots.tsv.sha256")" == "$inventory_sha" ]] || return 1
    handoff_required=$(jq -er '.canary_handoff.required | select(type == "boolean")' \
        "$transaction") || return 1
    if [[ "$handoff_required" == true ]]; then
        handoff_sha=$(sha256sum "$handoff" | awk '{print $1}') || return 1
    else
        handoff_sha=__NULL__
    fi
    jq -e --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
        --arg transaction_sha "$transaction_sha" --arg handoff_sha "$handoff_sha" \
        --arg maintenance_sha "$maintenance_sha" --arg drain_sha "$drain_sha" \
        --arg inventory_sha "$inventory_sha" '
        (keys | sort) == (["schema","transaction","purpose","run_dir","wave_dir",
          "transaction_manifest_sha256","canary_fleet_handoff_sha256",
          "maintenance_marker_sha256","wave_drain_manifest_sha256",
          "snapshot_inventory_sha256","nodes","published_at"] | sort) and
        .schema == 1 and .transaction == "v30.1.4-fleet-rollout" and
        .purpose == "pre-upgrade-data-restore" and .run_dir == $run and .wave_dir == $wave and
        .transaction_manifest_sha256 == $transaction_sha and
        (if $handoff_sha == "__NULL__" then .canary_fleet_handoff_sha256 == null
         else .canary_fleet_handoff_sha256 == $handoff_sha end) and
        .maintenance_marker_sha256 == $maintenance_sha and
        .wave_drain_manifest_sha256 == $drain_sha and
        .snapshot_inventory_sha256 == $inventory_sha and
        (.nodes | type) == "array" and (.published_at | type) == "string" and
        (.published_at | length) > 0
    ' "$authority" >/dev/null || return 1
    expected_nodes_json=$(printf '%s\n' "${CURRENT_WAVE_NODES[@]}" | jq -sc 'map(tonumber)') || return 1
    jq -e --argjson expected "$expected_nodes_json" '
        [.nodes[].node] == $expected and
        all(.nodes[];
          (keys | sort) == (["node","launch_state","launch_marker_sha256",
            "safe_boundary_sha256","stopped_generation"] | sort))
    ' "$authority" >/dev/null || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        entry_count=$(jq -r --argjson node "$node" '[.nodes[] | select(.node == $node)] | length' \
            "$authority") || return 1
        [[ "$entry_count" -eq 1 ]] || return 1
        stopped_generation=$(jq -er --argjson node "$node" \
            '.nodes[] | select(.node == $node) | .stopped_generation' "$authority") || return 1
        data_rollback_validate_stopped_generation "$stopped_generation" || return 1
        launch_marker=$(wave_node_launch_attempt_path "$node") || return 1
        safe=$(wave_node_safe_rollback_path "$node") || return 1
        if [[ -e "$launch_marker" || -L "$launch_marker" ]]; then
            data_rollback_protected_file "$launch_marker" 600 || return 1
            verify_candidate_launch_attempt_marker "$node" 0 || return 1
            launch_state=candidate-attempted
            launch_sha=$(sha256sum "$launch_marker" | awk '{print $1}') || return 1
            data_rollback_protected_file "$safe" 600 || return 1
            data_rollback_verify_safe_boundary_sealed "$node" "$stopped_generation" || return 1
            safe_sha=$(sha256sum "$safe" | awk '{print $1}') || return 1
            attempted_count=$((attempted_count + 1))
        else
            launch_state=not-attempted
            launch_sha=__NULL__
            [[ ! -e "$safe" && ! -L "$safe" ]] || return 1
            [[ ! -e "$(wave_node_activation_path "$node")" &&
               ! -L "$(wave_node_activation_path "$node")" ]] || return 1
            safe_sha=__NULL__
        fi
        jq -e --argjson node "$node" --arg launch_state "$launch_state" \
            --arg launch_sha "$launch_sha" --arg safe_sha "$safe_sha" \
            --arg generation "$stopped_generation" '
            [.nodes[] | select(.node == $node)] == [{node:$node,launch_state:$launch_state,
              launch_marker_sha256:(if $launch_sha == "__NULL__" then null else $launch_sha end),
              safe_boundary_sha256:(if $safe_sha == "__NULL__" then null else $safe_sha end),
              stopped_generation:$generation}]
        ' "$authority" >/dev/null || return 1
    done
    ! find "$CURRENT_WAVE_DIR" -maxdepth 1 -type l \
        -name 'node-*-CANDIDATE-LAUNCH-ATTEMPTED.json' -print -quit | grep -q . || return 1
    actual_marker_count=$(find "$CURRENT_WAVE_DIR" -maxdepth 1 -type f \
        -name 'node-*-CANDIDATE-LAUNCH-ATTEMPTED.json' -print | wc -l) || return 1
    [[ "$actual_marker_count" -eq "$attempted_count" ]]
}

data_rollback_verify_authority_stopped_generations()
{
    local expected_sha=${1:-} authority node generation inspect
    valid_sha256_hex "$expected_sha" || return 1
    authority=$(data_rollback_authority_path) || return 1
    data_rollback_canonical_single_object_json "$authority" || return 1
    [[ "$(sha256sum "$authority" | awk '{print $1}')" == "$expected_sha" ]] || return 1
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        generation=$(jq -er --argjson node "$node" \
            '.nodes[] | select(.node == $node) | .stopped_generation' "$authority") || return 1
        [[ "$(container_generation_for "$node")" == "$generation" ]] || return 1
        inspect=$(docker inspect "$(container_for "$node")") || return 1
        jq -e 'length == 1 and .[0].State.Running == false and .[0].State.Pid == 0 and
            .[0].State.Restarting == false and .[0].HostConfig.RestartPolicy.Name == "no"' \
            >/dev/null <<< "$inspect" || return 1
        [[ "$(container_generation_for "$node")" == "$generation" ]] || return 1
    done
}

data_rollback_verify_authority_live()
{
    local expected_sha=${1:-}
    data_rollback_verify_authority_sealed "$expected_sha" || return 1
    data_rollback_verify_authority_stopped_generations "$expected_sha"
}

data_rollback_require_lock_fd()
{
    local fd="$1" expected_path="$2" actual_path expected_canonical
    [[ "$fd" =~ ^[0-9]+$ && -n "$expected_path" ]] || return 1
    [[ -e "/proc/$$/fd/$fd" ]] || return 1
    actual_path=$(readlink -f -- "/proc/$$/fd/$fd") || return 1
    expected_canonical=$(realpath -e -- "$expected_path") || return 1
    [[ "$actual_path" == "$expected_canonical" ]] || return 1
    # This is idempotent for caller-held OFD locks and acquires an omitted lock
    # on the already-open descriptor without changing the established order.
    flock -n -x "$fd"
}

data_rollback_require_mutation_fences()
{
    [[ "${WAVE_LOCKS_HELD:-0}" -eq 1 ]] || return 1
    data_rollback_require_lock_fd 19 /var/run/blackcoin-v30.1.4-fleet-rollout.lock || return 1
    data_rollback_require_lock_fd 15 /run/blackcoin-endpoint-guard.lock || return 1
    data_rollback_require_lock_fd 16 /var/run/blackcoin-node-cutover.lock || return 1
    data_rollback_require_lock_fd 14 /run/blackcoin-pow-quarantine-cycle.lock || return 1
    data_rollback_require_lock_fd 17 /var/run/blackcoin-wallet-runtime-guard.lock || return 1
    if [[ " ${CURRENT_WAVE_NODES[*]} " == *" 30 "* ]]; then
        [[ "${FREE_CLAIM_LOCK_HELD:-0}" -eq 1 && -n "${FREE_CLAIM_LOCK:-}" ]] || return 1
        data_rollback_require_lock_fd 18 "$FREE_CLAIM_LOCK" || return 1
    fi
}

data_rollback_require_mutation_authority()
{
    local expected_sha=${1:-}
    valid_sha256_hex "$expected_sha" || return 1
    data_rollback_require_mutation_fences || return 1
    data_rollback_verify_authority_live "$expected_sha"
}

data_rollback_require_fileset_mutation_boundary()
{
    local expected_sha="$1" node="$2" role="$3" root="$4" path="$5"
    local snapshot="$6" guid="$7" txg="$8" hold_tag="$9" source="${10}"
    local node_number domain kind dataset mountpoint expected_source
    node_number=$((10#$node))
    valid_node "$node_number" || return 1
    [[ "$role" == raw && "$root" == "$FLEET_ZFS_PARENT" &&
       "$path" == "$(host_blocks_for "$node_number")/blocks" ]] || return 1
    domain=$(data_domain_for "$node_number" "$role" "$path") || return 1
    IFS='|' read -r kind dataset <<< "$domain"
    [[ "$kind" == fileset && "$dataset" == "$root" && "$snapshot" == "$root@"* ]] || return 1
    data_rollback_verify_snapshot_identity "$snapshot" "$guid" "$txg" "$hold_tag" || return 1
    mountpoint=$(zfs get -H -o value mountpoint "$root") || return 1
    expected_source="$mountpoint/.zfs/snapshot/${snapshot#*@}/${path#"$mountpoint"/}"
    [[ "$path" == "$mountpoint"/* && -d "$path" && ! -L "$path" &&
       "$(realpath -e -- "$path")" == "$path" &&
       -d "$source" && ! -L "$source" && "$(realpath -e -- "$source")" == "$source" &&
       "$source" == "$expected_source" &&
       "$(findmnt -n -o SOURCE -T "$path")" == "$root" ]] || return 1
    data_rollback_require_mutation_authority "$expected_sha" || return 1
    [[ -d "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
       -d "$source" && ! -L "$source" && "$(realpath -e -- "$source")" == "$source" &&
       "$source" == "$expected_source" &&
       "$(findmnt -n -o SOURCE -T "$path")" == "$root" ]] || return 1
    data_rollback_require_mutation_fences || return 1
    data_rollback_verify_authority_stopped_generations "$expected_sha"
}

data_rollback_require_zfs_rollback_boundary()
{
    local expected_sha="$1" snapshot="$2" guid="$3" txg="$4" hold_tag="$5"
    data_rollback_verify_snapshot_identity "$snapshot" "$guid" "$txg" "$hold_tag" || return 1
    data_rollback_require_mutation_authority "$expected_sha" || return 1
    data_rollback_verify_snapshot_identity "$snapshot" "$guid" "$txg" "$hold_tag" || return 1
    data_rollback_require_mutation_fences || return 1
    data_rollback_verify_authority_stopped_generations "$expected_sha"
}

data_rollback_require_zfs_rsync_boundary()
{
    local expected_sha="$1" dataset="$2" snapshot="$3" guid="$4" txg="$5" hold_tag="$6"
    local mountpoint="$7" snapshot_source="$8"
    [[ "$(zfs get -H -o value mounted "$dataset")" == yes &&
       "$(zfs get -H -o value mountpoint "$dataset")" == "$mountpoint" &&
       "$mountpoint" == /* && -d "$mountpoint" && ! -L "$mountpoint" &&
       "$(realpath -e -- "$mountpoint")" == "$mountpoint" &&
       "$(findmnt -n -o SOURCE -T "$mountpoint")" == "$dataset" &&
       "$(findmnt -n -o TARGET -T "$mountpoint")" == "$mountpoint" &&
       "$snapshot_source" == "$mountpoint/.zfs/snapshot/${snapshot#*@}" &&
       -d "$snapshot_source" && ! -L "$snapshot_source" &&
       "$(realpath -e -- "$snapshot_source")" == "$snapshot_source" ]] || return 1
    data_rollback_verify_snapshot_identity "$snapshot" "$guid" "$txg" "$hold_tag" || return 1
    data_rollback_require_mutation_authority "$expected_sha" || return 1
    [[ "$(zfs get -H -o value mounted "$dataset")" == yes &&
       "$(zfs get -H -o value mountpoint "$dataset")" == "$mountpoint" &&
       -d "$mountpoint" && ! -L "$mountpoint" &&
       "$(realpath -e -- "$mountpoint")" == "$mountpoint" &&
       "$(findmnt -n -o SOURCE -T "$mountpoint")" == "$dataset" &&
       "$(findmnt -n -o TARGET -T "$mountpoint")" == "$mountpoint" &&
       -d "$snapshot_source" && ! -L "$snapshot_source" &&
       "$(realpath -e -- "$snapshot_source")" == "$snapshot_source" ]] || return 1
    data_rollback_require_mutation_fences || return 1
    data_rollback_verify_authority_stopped_generations "$expected_sha"
}

data_rollback_publish_authority()
{
    local authority temporary nodes_tmp transaction handoff maintenance drain inventory
    local transaction_sha handoff_sha maintenance_sha drain_sha inventory_sha handoff_required
    local launch_marker launch_state launch_sha node generation safe safe_sha published_sha inspect
    authority=$(data_rollback_authority_path) || return 1
    [[ ! -e "$authority" && ! -L "$authority" ]] || return 1
    data_rollback_verify_authority_context_sealed || return 1
    transaction="$RUN_DIR/TRANSACTION.json"
    handoff="$RUN_DIR/CANARY-FLEET-HANDOFF.json"
    maintenance="$ROLLOUT_MAINTENANCE_MARKER"
    drain="$CURRENT_WAVE_DIR/WAVE-DRAIN-EVIDENCE.sha256"
    inventory="$CURRENT_WAVE_DIR/data-snapshots.tsv"
    transaction_sha=$(sha256sum "$transaction" | awk '{print $1}') || return 1
    maintenance_sha=$(sha256sum "$maintenance" | awk '{print $1}') || return 1
    drain_sha=$(sha256sum "$drain" | awk '{print $1}') || return 1
    inventory_sha=$(sha256sum "$inventory" | awk '{print $1}') || return 1
    handoff_required=$(jq -er '.canary_handoff.required | select(type == "boolean")' \
        "$transaction") || return 1
    if [[ "$handoff_required" == true ]]; then
        handoff_sha=$(sha256sum "$handoff" | awk '{print $1}') || return 1
    else
        handoff_sha=__NULL__
    fi
    temporary=$(mktemp "$CURRENT_WAVE_DIR/.rollback-authority.XXXXXX") || return 1
    nodes_tmp=$(mktemp "$CURRENT_WAVE_DIR/.rollback-authority-nodes.XXXXXX") || {
        rm -f -- "$temporary"
        return 1
    }
    : > "$nodes_tmp"
    for node in "${CURRENT_WAVE_NODES[@]}"; do
        generation=$(container_generation_for "$node") || { rm -f -- "$temporary" "$nodes_tmp"; return 1; }
        data_rollback_validate_stopped_generation "$generation" || {
            rm -f -- "$temporary" "$nodes_tmp"; return 1;
        }
        inspect=$(docker inspect "$(container_for "$node")") || {
            rm -f -- "$temporary" "$nodes_tmp"; return 1;
        }
        jq -e 'length == 1 and .[0].State.Running == false and .[0].State.Pid == 0 and
            .[0].State.Restarting == false and .[0].HostConfig.RestartPolicy.Name == "no"' \
            >/dev/null <<< "$inspect" || { rm -f -- "$temporary" "$nodes_tmp"; return 1; }
        [[ "$(container_generation_for "$node")" == "$generation" ]] || {
            rm -f -- "$temporary" "$nodes_tmp"; return 1;
        }
        safe=$(wave_node_safe_rollback_path "$node") || {
            rm -f -- "$temporary" "$nodes_tmp"; return 1;
        }
        launch_marker=$(wave_node_launch_attempt_path "$node") || {
            rm -f -- "$temporary" "$nodes_tmp"; return 1;
        }
        if [[ -e "$launch_marker" || -L "$launch_marker" ]]; then
            if ! data_rollback_protected_file "$launch_marker" 600 ||
               ! verify_candidate_launch_attempt_marker "$node" 0; then
                rm -f -- "$temporary" "$nodes_tmp"
                return 1
            fi
            launch_state=candidate-attempted
            launch_sha=$(sha256sum "$launch_marker" | awk '{print $1}') || {
                rm -f -- "$temporary" "$nodes_tmp"; return 1;
            }
            data_rollback_verify_safe_boundary_sealed "$node" "$generation" || {
                rm -f -- "$temporary" "$nodes_tmp"; return 1;
            }
            safe_sha=$(sha256sum "$safe" | awk '{print $1}') || {
                rm -f -- "$temporary" "$nodes_tmp"; return 1;
            }
        else
            launch_state=not-attempted
            launch_sha=__NULL__
            [[ ! -e "$safe" && ! -L "$safe" &&
               ! -e "$(wave_node_activation_path "$node")" &&
               ! -L "$(wave_node_activation_path "$node")" ]] || {
                rm -f -- "$temporary" "$nodes_tmp"; return 1;
            }
            safe_sha=__NULL__
        fi
        jq -cn --argjson node "$node" --arg launch_state "$launch_state" \
            --arg launch_sha "$launch_sha" --arg safe_sha "$safe_sha" \
            --arg generation "$generation" '
            {node:$node,launch_state:$launch_state,
             launch_marker_sha256:(if $launch_sha == "__NULL__" then null else $launch_sha end),
             safe_boundary_sha256:(if $safe_sha == "__NULL__" then null else $safe_sha end),
             stopped_generation:$generation}' >> "$nodes_tmp" || {
                rm -f -- "$temporary" "$nodes_tmp"; return 1;
            }
    done
    jq -n --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
        --arg transaction_sha "$transaction_sha" --arg handoff_sha "$handoff_sha" \
        --arg maintenance_sha "$maintenance_sha" --arg drain_sha "$drain_sha" \
        --arg inventory_sha "$inventory_sha" --arg published_at "$(date -u +%FT%TZ)" \
        --slurpfile nodes "$nodes_tmp" '
        {schema:1,transaction:"v30.1.4-fleet-rollout",purpose:"pre-upgrade-data-restore",
         run_dir:$run,wave_dir:$wave,transaction_manifest_sha256:$transaction_sha,
         canary_fleet_handoff_sha256:(if $handoff_sha == "__NULL__" then null else $handoff_sha end),
         maintenance_marker_sha256:$maintenance_sha,wave_drain_manifest_sha256:$drain_sha,
         snapshot_inventory_sha256:$inventory_sha,nodes:$nodes,published_at:$published_at}
    ' > "$temporary" || { rm -f -- "$temporary" "$nodes_tmp"; return 1; }
    rm -f -- "$nodes_tmp"
    jq -S . "$temporary" > "${temporary}.sorted" || { rm -f -- "$temporary" "${temporary}.sorted"; return 1; }
    mv -f -- "${temporary}.sorted" "$temporary" || { rm -f -- "$temporary"; return 1; }
    cmp -s "$temporary" <(jq -S -e 'if type == "object" then . else error("object required") end' \
        "$temporary") || { rm -f -- "$temporary"; return 1; }
    if ! chmod 600 "$temporary" || ! chown root:root "$temporary" ||
       ! sync -f "$temporary"; then
        rm -f -- "$temporary"; return 1;
    fi
    # A hard-link publication is atomic and cannot replace a pre-existing authority.
    ln -- "$temporary" "$authority" || { rm -f -- "$temporary"; return 1; }
    rm -f -- "$temporary"
    sync -f "$CURRENT_WAVE_DIR" || return 1
    published_sha=$(sha256sum "$authority" | awk '{print $1}') || return 1
    data_rollback_verify_authority_live "$published_sha" || return 1
    printf '%s\n' "$published_sha"
}

data_rollback_prepare_restore_authority()
{
    local authority expected_sha
    authority=$(data_rollback_authority_path) || return 1
    if [[ -e "$authority" || -L "$authority" ]]; then
        data_rollback_protected_file "$authority" 600 || return 1
        data_rollback_canonical_single_object_json "$authority" || return 1
        expected_sha=$(sha256sum "$authority" | awk '{print $1}') || return 1
        data_rollback_verify_authority_live "$expected_sha" || return 1
        printf '%s\n' "$expected_sha"
        return 0
    fi
    data_rollback_publish_authority
}

data_rollback_cleanup_allowed()
{
    local state audit result_sha expected_sha
    data_rollback_protected_file "$RUN_DIR/STATE" 600 || return 1
    state=$(cat -- "$RUN_DIR/STATE") || return 1
    case "$state" in
        complete)
            audit="$RUN_DIR/exact-32-soak"
            [[ -d "$audit" && ! -L "$audit" && "$(realpath -e -- "$audit")" == "$audit" &&
               "$(stat -c '%u:%g:%a' "$audit")" == 0:0:700 ]] || return 1
            data_rollback_protected_file "$audit/POST-RELEASE.json" 600 || return 1
            data_rollback_protected_file "$audit/SHA256SUMS" 600 || return 1
            (cd "$audit" && sha256sum --strict -c SHA256SUMS >/dev/null) || return 1
            jq -e '.schema == 1 and .result == "passed" and .phase == "post-release" and
                .maintenance_marker_absent == true and
                .free_claim_broadcasts_paused == false and
                .free_claim_service_healthy == true and .stale_broadcast_gate_passed == true and
                .nodes_healthy == 32 and .pos_active == 32 and .regular_pow_active == 31 and
                .free_claim_node == 30 and .free_claim_regular_pow == false and
                .final_concurrent_dynamic_gate == true and
                .final_exact_32_generation_fence == true and
                .global_chain_convergence == true and .vpn_proofs_valid_unique == 32' \
                "$audit/POST-RELEASE.json" >/dev/null
            ;;
        rolled-back)
            data_rollback_protected_file "$RUN_DIR/ROLLBACK_RESULT.json" 600 || return 1
            data_rollback_protected_file "$RUN_DIR/ROLLBACK_RESULT.sha256" 600 || return 1
            expected_sha=$(cat -- "$RUN_DIR/ROLLBACK_RESULT.sha256") || return 1
            [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
            result_sha=$(sha256sum "$RUN_DIR/ROLLBACK_RESULT.json" | awk '{print $1}') || return 1
            [[ "$result_sha" == "$expected_sha" ]] || return 1
            jq -e '.schema == 1 and .transaction == "v30.1.4-fleet-rollout" and
                .result == "rolled-back" and .state == "rolled-back" and
                .nodes_healthy == 32 and .rollback_verified == true and
                .baseline_identity_restored == true' "$RUN_DIR/ROLLBACK_RESULT.json" >/dev/null
            ;;
        *) return 1 ;;
    esac
}

data_rollback_finalization_released()
{
    local inhibitor_state state result finalization
    [[ -n "${ROLLOUT_MAINTENANCE_MARKER:-}" &&
       ! -e "$ROLLOUT_MAINTENANCE_MARKER" && ! -L "$ROLLOUT_MAINTENANCE_MARKER" ]] || return 1
    [[ -n "${INHIBITOR_RELEASER:-}" && -f "$INHIBITOR_RELEASER" &&
       ! -L "$INHIBITOR_RELEASER" ]] || return 1
    inhibitor_state=$(/bin/bash "$INHIBITOR_RELEASER" probe) || return 1
    [[ "$inhibitor_state" == \
       'state=installed-and-released cycle=v30.1.4-no-spend free_claim=enabled' ]] || return 1
    data_rollback_protected_file "$RUN_DIR/STATE" 600 || return 1
    state=$(<"$RUN_DIR/STATE")
    case "$state" in
        complete)
            result="$RUN_DIR/exact-32-soak/RESULT.json"
            finalization="$RUN_DIR/exact-32-soak/FINALIZATION-READY.json"
            ;;
        rolled-back)
            result="$RUN_DIR/ROLLBACK_RESULT.json"
            finalization="$RUN_DIR/ROLLBACK-FINALIZATION-READY.json"
            ;;
        *) return 1 ;;
    esac
    [[ "$(/bin/bash "$INHIBITOR_RELEASER" verify-release \
        "$result" "$RUN_DIR/STATE" "$finalization")" == \
       'state=installed-and-released receipt=verified' ]]
}

data_rollback_build_cleanup_plan()
{
    local require_live="$1" sources_output="$2" plan_output="$3"
    local wave wave_name wave_index result inventory_sha wave_evidence_sha
    local type node role root path snapshot guid txg hold_tag source dataset suffix prior
    local -a cleanup_nodes=()
    local -A snapshots=()
    [[ "$require_live" == 0 || "$require_live" == 1 ]] || return 1
    : > "$sources_output" || return 1
    : > "$plan_output" || return 1
    while IFS= read -r wave; do
        [[ -d "$wave" && ! -L "$wave" && "$(realpath -e -- "$wave")" == "$wave" ]] || return 1
        wave_name=${wave##*/}
        [[ "$wave_name" =~ ^wave-([0-9]{2})-nodes-[0-9]+(-[0-9]+)*(-retry-[0-9]{2})?$ ]] ||
            return 1
        wave_index=$((10#${BASH_REMATCH[1]}))
        verify_wave_evidence_manifest "$wave" "$wave_index" || return 1
        if [[ ! -e "$wave/data-snapshots.tsv" && ! -L "$wave/data-snapshots.tsv" &&
              ! -e "$wave/data-snapshots.tsv.sha256" && ! -L "$wave/data-snapshots.tsv.sha256" ]]; then
            continue
        fi
        data_rollback_protected_file "$wave/RESULT" 600 || return 1
        result=$(cat -- "$wave/RESULT") || return 1
        [[ "$result" == passed || "$result" == rolled-back ]] || return 1
        CURRENT_WAVE_DIR="$wave"
        read -r -a cleanup_nodes < "$wave/NODES"
        CURRENT_WAVE_NODES=("${cleanup_nodes[@]}")
        verify_wave_snapshot_inventory "$require_live" || return 1
        inventory_sha=$(cat -- "$wave/data-snapshots.tsv.sha256") || return 1
        [[ "$inventory_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
        wave_evidence_sha=$(sha256sum "$wave/WAVE-EVIDENCE.sha256" | awk '{print $1}') || return 1
        printf '%s|%s|%s|%s\n' "$wave_name" "$inventory_sha" "$wave_evidence_sha" "$result" \
            >> "$sources_output" || return 1
        suffix="v3014-${RUN_DIR##*/}-${wave_name}"
        while IFS='|' read -r type node role root path snapshot guid txg hold_tag source; do
            dataset=${snapshot%@*}
            [[ "$type" == ZFS || "$type" == FILESET ]] || return 1
            [[ "$snapshot" == "$dataset@$suffix" &&
               "$dataset" != *'|'* && "$dataset" != *[$'\t\r\n ']* &&
               ( "$dataset" == "$FLEET_ZFS_PARENT" ||
                 "$dataset" == "$FLEET_ZFS_PARENT"/* ) &&
               "$guid" =~ ^[1-9][0-9]*$ && "$txg" =~ ^[1-9][0-9]*$ &&
               "$hold_tag" == "v3014-${RUN_DIR##*/}" ]] || return 1
            prior="${snapshots[$snapshot]:-}"
            if [[ -n "$prior" ]]; then
                [[ "$prior" == "$type|$dataset|$guid|$txg|$hold_tag|$suffix" ]] || return 1
                continue
            fi
            snapshots[$snapshot]="$type|$dataset|$guid|$txg|$hold_tag|$suffix"
            printf '%s|%s|%s|%s|%s|%s|%s\n' \
                "$type" "$snapshot" "$dataset" "$guid" "$txg" "$hold_tag" "$suffix" \
                >> "$plan_output" || return 1
        done < "$wave/data-snapshots.tsv"
    done < <(find "$RUN_DIR" -mindepth 1 -maxdepth 1 -name 'wave-*' -print | sort)
    [[ -s "$sources_output" && -s "$plan_output" ]] || return 1
    sort -o "$sources_output" "$sources_output" || return 1
    sort -o "$plan_output" "$plan_output" || return 1
}

data_rollback_verify_cleanup_plan_dir()
{
    local cleanup_dir="$1" file expected actual entry
    [[ -d "$cleanup_dir" && ! -L "$cleanup_dir" &&
       "$(realpath -e -- "$cleanup_dir")" == "$cleanup_dir" &&
       "$(stat -c '%u:%g:%a' "$cleanup_dir")" == 0:0:700 &&
       -d "$cleanup_dir/journals" && ! -L "$cleanup_dir/journals" &&
       "$(stat -c '%u:%g:%a' "$cleanup_dir/journals")" == 0:0:700 ]] || return 1
    for file in SOURCES.tsv SOURCES.tsv.sha256 PLAN.tsv PLAN.tsv.sha256; do
        data_rollback_protected_file "$cleanup_dir/$file" 600 || return 1
    done
    for file in SOURCES PLAN; do
        expected=$(cat -- "$cleanup_dir/${file}.tsv.sha256") || return 1
        [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
        actual=$(sha256sum "$cleanup_dir/${file}.tsv" | awk '{print $1}') || return 1
        [[ "$actual" == "$expected" ]] || return 1
    done
    while IFS= read -r entry; do
        case "${entry##*/}" in
            SOURCES.tsv|SOURCES.tsv.sha256|PLAN.tsv|PLAN.tsv.sha256|RESULT.json|RESULT.json.sha256|journals) ;;
            *) return 1 ;;
        esac
    done < <(find "$cleanup_dir" -mindepth 1 -maxdepth 1 -print)
}

data_rollback_prepare_cleanup_plan()
{
    local cleanup_dir="$1" prepare sources plan file
    if [[ -e "$cleanup_dir" || -L "$cleanup_dir" ]]; then
        data_rollback_verify_cleanup_plan_dir "$cleanup_dir"
        return
    fi
    prepare=$(mktemp -d "$RUN_DIR/.snapshot-cleanup.prepare.XXXXXX") || return 1
    chmod 700 "$prepare" && chown root:root "$prepare" || return 1
    install -d -m 700 -o root -g root "$prepare/journals" || return 1
    sources="$prepare/SOURCES.tsv"
    plan="$prepare/PLAN.tsv"
    data_rollback_build_cleanup_plan 1 "$sources" "$plan" || return 1
    for file in SOURCES PLAN; do
        chmod 600 "$prepare/${file}.tsv" && chown root:root "$prepare/${file}.tsv" || return 1
        sha256sum "$prepare/${file}.tsv" | awk '{print $1}' > "$prepare/${file}.tsv.sha256" ||
            return 1
        chmod 600 "$prepare/${file}.tsv.sha256" &&
            chown root:root "$prepare/${file}.tsv.sha256" || return 1
        sync -f "$prepare/${file}.tsv" && sync -f "$prepare/${file}.tsv.sha256" || return 1
    done
    sync -f "$prepare" || return 1
    [[ ! -e "$cleanup_dir" && ! -L "$cleanup_dir" ]] || return 1
    mv -- "$prepare" "$cleanup_dir" || return 1
    sync -f "$RUN_DIR" || return 1
    data_rollback_verify_cleanup_plan_dir "$cleanup_dir"
}

data_rollback_verify_cleanup_sources()
{
    local cleanup_dir="$1" temporary_sources temporary_plan
    temporary_sources=$(mktemp "$RUN_DIR/.snapshot-cleanup-sources.XXXXXX") || return 1
    temporary_plan=$(mktemp "$RUN_DIR/.snapshot-cleanup-plan.XXXXXX") || {
        rm -f -- "$temporary_sources"
        return 1
    }
    if ! data_rollback_build_cleanup_plan 0 "$temporary_sources" "$temporary_plan" ||
       ! cmp -s "$temporary_sources" "$cleanup_dir/SOURCES.tsv" ||
       ! cmp -s "$temporary_plan" "$cleanup_dir/PLAN.tsv"; then
        rm -f -- "$temporary_sources" "$temporary_plan"
        return 1
    fi
    rm -f -- "$temporary_sources" "$temporary_plan"
}

data_rollback_verify_cleanup_journal()
{
    local directory="$1" plan_sha="$2" type="$3" snapshot="$4" dataset="$5"
    local guid="$6" txg="$7" hold_tag="$8" suffix="$9"
    [[ -d "$directory" && ! -L "$directory" && "$(realpath -e -- "$directory")" == "$directory" &&
       "$(stat -c '%u:%g:%a' "$directory")" == 0:0:700 ]] || return 1
    data_rollback_protected_file "$directory/INTENT.json" 600 || return 1
    data_rollback_protected_file "$directory/SHA256SUMS" 600 || return 1
    [[ "$(find "$directory" -mindepth 1 -maxdepth 1 -print | wc -l)" -eq 2 ]] || return 1
    (cd "$directory" && [[ "$(awk 'NF == 2 {print $2}' SHA256SUMS)" == INTENT.json ]] &&
        sha256sum --strict -c SHA256SUMS >/dev/null) || return 1
    jq -e --arg run "$RUN_DIR" --arg plan_sha "$plan_sha" --arg type "$type" \
        --arg snapshot "$snapshot" --arg dataset "$dataset" --arg guid "$guid" \
        --arg txg "$txg" --arg hold "$hold_tag" --arg suffix "$suffix" '
        . == {schema:1,transaction:"v30.1.4-snapshot-cleanup",run_dir:$run,
              plan_sha256:$plan_sha,type:$type,snapshot:$snapshot,dataset:$dataset,
              guid:$guid,createtxg:$txg,hold_tag:$hold,suffix:$suffix,
              intent:["release_exact_transaction_hold","destroy_exact_transaction_snapshot"]}
    ' "$directory/INTENT.json" >/dev/null
}

data_rollback_publish_cleanup_journal()
{
    local directory="$1" plan_sha="$2" type="$3" snapshot="$4" dataset="$5"
    local guid="$6" txg="$7" hold_tag="$8" suffix="$9" prepare
    prepare=$(mktemp -d "$RUN_DIR/.snapshot-cleanup-journal.XXXXXX") || return 1
    chmod 700 "$prepare" && chown root:root "$prepare" || return 1
    jq -S -n --arg run "$RUN_DIR" --arg plan_sha "$plan_sha" --arg type "$type" \
        --arg snapshot "$snapshot" --arg dataset "$dataset" --arg guid "$guid" \
        --arg txg "$txg" --arg hold "$hold_tag" --arg suffix "$suffix" '
        {schema:1,transaction:"v30.1.4-snapshot-cleanup",run_dir:$run,
         plan_sha256:$plan_sha,type:$type,snapshot:$snapshot,dataset:$dataset,
         guid:$guid,createtxg:$txg,hold_tag:$hold,suffix:$suffix,
         intent:["release_exact_transaction_hold","destroy_exact_transaction_snapshot"]}
    ' > "$prepare/INTENT.json" || return 1
    chmod 600 "$prepare/INTENT.json" && chown root:root "$prepare/INTENT.json" || return 1
    (cd "$prepare" && sha256sum INTENT.json > SHA256SUMS) || return 1
    chmod 600 "$prepare/SHA256SUMS" && chown root:root "$prepare/SHA256SUMS" || return 1
    sync -f "$prepare/INTENT.json" && sync -f "$prepare/SHA256SUMS" && sync -f "$prepare" || return 1
    [[ ! -e "$directory" && ! -L "$directory" ]] || return 1
    mv -- "$prepare" "$directory" || return 1
    sync -f "${directory%/*}" || return 1
    data_rollback_verify_cleanup_journal "$directory" "$plan_sha" "$type" "$snapshot" \
        "$dataset" "$guid" "$txg" "$hold_tag" "$suffix"
}

data_rollback_verify_cleanup_journal_topology()
{
    local cleanup_dir="$1" plan_sha="$2" entry key line expected_key matched
    local type snapshot dataset guid txg hold_tag suffix
    while IFS= read -r entry; do
        [[ -d "$entry" && ! -L "$entry" && "$(realpath -e -- "$entry")" == "$entry" ]] ||
            return 1
        key=${entry##*/}
        [[ "$key" =~ ^[0-9a-f]{64}$ ]] || return 1
        matched=0
        while IFS= read -r line; do
            expected_key=$(printf '%s' "$line" | sha256sum | awk '{print $1}') || return 1
            [[ "$expected_key" == "$key" ]] || continue
            IFS='|' read -r type snapshot dataset guid txg hold_tag suffix <<< "$line"
            data_rollback_verify_cleanup_journal "$entry" "$plan_sha" "$type" "$snapshot" \
                "$dataset" "$guid" "$txg" "$hold_tag" "$suffix" || return 1
            matched=1
            break
        done < "$cleanup_dir/PLAN.tsv"
        ((matched == 1)) || return 1
    done < <(find "$cleanup_dir/journals" -mindepth 1 -maxdepth 1 -print | sort)
}

# Remove only the held snapshots authenticated by this RUN_DIR. This function
# runs in a subshell so CURRENT_WAVE_DIR/CURRENT_WAVE_NODES and caller state are
# unchanged. It is safe to call again after interruption.
cleanup_transaction_snapshots()
(
    local cleanup_dir="$RUN_DIR/snapshot-cleanup" plan_sha sources_sha
    local type snapshot dataset guid txg hold_tag suffix key journal journal_preexisting
    local actual_guid actual_txg removed=0 total=0 result_tmp result_sha_tmp existing_result_sha
    valid_rollout_run_dir "$RUN_DIR" || return 1
    verify_transaction_manifest || return 1
    data_rollback_cleanup_allowed || return 1
    data_rollback_finalization_released || return 1
    data_rollback_prepare_cleanup_plan "$cleanup_dir" || return 1
    data_rollback_verify_cleanup_plan_dir "$cleanup_dir" || return 1
    data_rollback_verify_cleanup_sources "$cleanup_dir" || return 1
    plan_sha=$(cat -- "$cleanup_dir/PLAN.tsv.sha256") || return 1
    sources_sha=$(cat -- "$cleanup_dir/SOURCES.tsv.sha256") || return 1
    [[ "$plan_sha" =~ ^[0-9a-f]{64}$ && "$sources_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
    data_rollback_verify_cleanup_journal_topology "$cleanup_dir" "$plan_sha" || return 1
    while IFS='|' read -r type snapshot dataset guid txg hold_tag suffix; do
        total=$((total + 1))
        [[ "$type" == ZFS || "$type" == FILESET ]] || return 1
        [[ "$snapshot" == "$dataset@$suffix" && "$guid" =~ ^[1-9][0-9]*$ &&
           "$txg" =~ ^[1-9][0-9]*$ && "$hold_tag" == "v3014-${RUN_DIR##*/}" ]] || return 1
        key=$(printf '%s' "$type|$snapshot|$dataset|$guid|$txg|$hold_tag|$suffix" |
            sha256sum | awk '{print $1}') || return 1
        journal="$cleanup_dir/journals/$key"
        journal_preexisting=0
        if [[ -e "$journal" || -L "$journal" ]]; then
            data_rollback_verify_cleanup_journal "$journal" "$plan_sha" "$type" "$snapshot" \
                "$dataset" "$guid" "$txg" "$hold_tag" "$suffix" || return 1
            journal_preexisting=1
        else
            data_rollback_verify_snapshot_identity "$snapshot" "$guid" "$txg" "$hold_tag" ||
                return 1
            data_rollback_publish_cleanup_journal "$journal" "$plan_sha" "$type" "$snapshot" \
                "$dataset" "$guid" "$txg" "$hold_tag" "$suffix" || return 1
            data_rollback_verify_snapshot_identity "$snapshot" "$guid" "$txg" "$hold_tag" ||
                return 1
        fi
        if ! actual_guid=$(snapshot_property "$snapshot" guid 2>/dev/null); then
            data_rollback_snapshot_absent "$snapshot" || return 1
            ((journal_preexisting == 1)) || return 1
            removed=$((removed + 1))
            continue
        fi
        actual_txg=$(snapshot_property "$snapshot" createtxg) || return 1
        [[ "$actual_guid" == "$guid" && "$actual_txg" == "$txg" ]] || return 1
        if snapshot_has_hold "$snapshot" "$hold_tag"; then
            zfs release "$hold_tag" "$snapshot" || return 1
            snapshot_has_hold "$snapshot" "$hold_tag" && return 1
        else
            ((journal_preexisting == 1)) || return 1
        fi
        [[ "$(snapshot_property "$snapshot" guid)" == "$guid" &&
           "$(snapshot_property "$snapshot" createtxg)" == "$txg" ]] || return 1
        zfs destroy "$snapshot" || return 1
        data_rollback_snapshot_absent "$snapshot" || return 1
        removed=$((removed + 1))
    done < "$cleanup_dir/PLAN.tsv"
    ((total >= 1 && removed == total)) || return 1
    if [[ -e "$cleanup_dir/RESULT.json" || -L "$cleanup_dir/RESULT.json" ]]; then
        data_rollback_protected_file "$cleanup_dir/RESULT.json" 600 || return 1
        existing_result_sha=$(sha256sum "$cleanup_dir/RESULT.json" | awk '{print $1}') || return 1
        jq -e --arg run "$RUN_DIR" --arg plan "$plan_sha" --arg sources "$sources_sha" \
            --argjson total "$total" '
            .schema == 1 and .transaction == "v30.1.4-snapshot-cleanup" and
            .run_dir == $run and .result == "passed" and .plan_sha256 == $plan and
            .sources_sha256 == $sources and .snapshots_destroyed == $total and
            .exact_transaction_holds_released == $total and
            .unrelated_snapshots_destroyed == 0 and .recursive_destroy_used == false and
            .cleanup_complete == true
        ' "$cleanup_dir/RESULT.json" >/dev/null || return 1
        if [[ -e "$cleanup_dir/RESULT.json.sha256" || -L "$cleanup_dir/RESULT.json.sha256" ]]; then
            data_rollback_protected_file "$cleanup_dir/RESULT.json.sha256" 600 || return 1
            [[ "$(cat -- "$cleanup_dir/RESULT.json.sha256")" == "$existing_result_sha" ]] || return 1
        else
            result_sha_tmp=$(mktemp "$RUN_DIR/.snapshot-cleanup-result-sha.XXXXXX") || return 1
            printf '%s\n' "$existing_result_sha" > "$result_sha_tmp" || return 1
            data_rollback_publish_json "$result_sha_tmp" "$cleanup_dir/RESULT.json.sha256" ||
                return 1
        fi
        return
    fi
    [[ ! -e "$cleanup_dir/RESULT.json.sha256" && ! -L "$cleanup_dir/RESULT.json.sha256" ]] ||
        return 1
    result_tmp=$(mktemp "$RUN_DIR/.snapshot-cleanup-result.XXXXXX") || return 1
    result_sha_tmp=$(mktemp "$RUN_DIR/.snapshot-cleanup-result-sha.XXXXXX") || return 1
    jq -n --arg run "$RUN_DIR" --arg completed_at "$(date -u +%FT%TZ)" \
        --arg plan "$plan_sha" --arg sources "$sources_sha" --argjson total "$total" '
        {schema:1,transaction:"v30.1.4-snapshot-cleanup",run_dir:$run,result:"passed",
         completed_at:$completed_at,plan_sha256:$plan,sources_sha256:$sources,
         snapshots_destroyed:$total,exact_transaction_holds_released:$total,
         unrelated_snapshots_destroyed:0,recursive_destroy_used:false,cleanup_complete:true}
    ' > "$result_tmp" || return 1
    chmod 600 "$result_tmp" && chown root:root "$result_tmp" && sync -f "$result_tmp" || return 1
    sha256sum "$result_tmp" | awk '{print $1}' > "$result_sha_tmp" || return 1
    chmod 600 "$result_sha_tmp" && chown root:root "$result_sha_tmp" &&
        sync -f "$result_sha_tmp" || return 1
    mv -fT -- "$result_tmp" "$cleanup_dir/RESULT.json" || return 1
    # Persist the result entry before its recoverable sidecar publication.
    sync -f "$cleanup_dir" || return 1
    mv -fT -- "$result_sha_tmp" "$cleanup_dir/RESULT.json.sha256" || return 1
    # Persist the sidecar entry only after the result entry is durable.
    sync -f "$cleanup_dir" || return 1
)

data_rollback_restore_evidence_files()
{
    local output="$1" type node role root path snapshot guid txg hold_tag source dataset_key
    local -A seen=()
    : > "$output" || return 1
    while IFS='|' read -r type node role root path snapshot guid txg hold_tag source; do
        case "$type" in
            FILESET)
                printf 'fileset-restore-node-%s-%s.diff\n' "$node" "$role" >> "$output" || return 1
                ;;
            ZFS)
                dataset_key=${snapshot%@*}
                dataset_key=${dataset_key//\//@}
                [[ -z "${seen[$dataset_key]:-}" ]] || return 1
                seen[$dataset_key]=1
                printf 'zfs-restore-%s.diff\n' "$dataset_key" >> "$output" || return 1
                printf 'zfs-restore-%s.mode.json\n' "$dataset_key" >> "$output" || return 1
                printf 'zfs-restore-%s.newer-before.tsv\n' "$dataset_key" >> "$output" || return 1
                ;;
            *) return 1 ;;
        esac
    done < "$CURRENT_WAVE_DIR/data-snapshots.tsv"
    sort -u -o "$output" "$output" || return 1
    [[ -s "$output" ]]
}

data_rollback_verify_restore_evidence_manifest()
{
    local expected_filesets="$1" expected_zfs="$2"
    local manifest="$CURRENT_WAVE_DIR/DATA-RESTORE-EVIDENCE.sha256"
    local expected_list actual_list rel fileset_count=0 zfs_diff_count=0 failed=0
    local dataset dataset_key snapshot guid txg hold_tag newer mode mode_file newer_sha
    [[ "$expected_filesets" =~ ^[0-9]+$ && "$expected_zfs" =~ ^[0-9]+$ ]] || return 1
    data_rollback_protected_file "$manifest" 600 || return 1
    expected_list=$(mktemp "$CURRENT_WAVE_DIR/.restore-evidence-expected.XXXXXX") || return 1
    actual_list=$(mktemp "$CURRENT_WAVE_DIR/.restore-evidence-actual.XXXXXX") || {
        rm -f -- "$expected_list"; return 1;
    }
    data_rollback_restore_evidence_files "$expected_list" || {
        rm -f -- "$expected_list" "$actual_list"; return 1;
    }
    awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ &&
        $2 ~ /^(fileset-restore-node-[0-9]{2}-(data|raw)[.]diff|zfs-restore-[A-Za-z0-9@._-]+[.](diff|json|tsv))$/ {print $2}' \
        "$manifest" | sort -u > "$actual_list" || {
            rm -f -- "$expected_list" "$actual_list"; return 1;
        }
    if [[ "$(wc -l < "$manifest")" -ne "$(wc -l < "$actual_list")" ]] ||
       ! cmp -s "$expected_list" "$actual_list"; then
            rm -f -- "$expected_list" "$actual_list"; return 1;
    fi
    while IFS= read -r rel; do
        if ! data_rollback_protected_file "$CURRENT_WAVE_DIR/$rel" 600; then
            failed=1
            break
        fi
        case "$rel" in
            fileset-restore-*.diff)
                [[ ! -s "$CURRENT_WAVE_DIR/$rel" ]] || { failed=1; break; }
                fileset_count=$((fileset_count + 1))
                ;;
            zfs-restore-*.diff)
                [[ ! -s "$CURRENT_WAVE_DIR/$rel" ]] || { failed=1; break; }
                zfs_diff_count=$((zfs_diff_count + 1))
                ;;
        esac
    done < "$expected_list"
    if ((failed != 0)); then
        rm -f -- "$expected_list" "$actual_list"
        return 1
    fi
    (cd "$CURRENT_WAVE_DIR" && sha256sum --strict -c "${manifest##*/}" >/dev/null) || {
        rm -f -- "$expected_list" "$actual_list"; return 1;
    }
    [[ "$fileset_count" -eq "$expected_filesets" && "$zfs_diff_count" -eq "$expected_zfs" ]] || {
        rm -f -- "$expected_list" "$actual_list"; return 1;
    }
    while IFS='|' read -r _ _ _ _ _ snapshot guid txg hold_tag _; do
        dataset=${snapshot%@*}
        dataset_key=${dataset//\//@}
        mode_file="$CURRENT_WAVE_DIR/zfs-restore-${dataset_key}.mode.json"
        newer="$CURRENT_WAVE_DIR/zfs-restore-${dataset_key}.newer-before.tsv"
        newer_sha=$(sha256sum "$newer" | awk '{print $1}') || {
            rm -f -- "$expected_list" "$actual_list"; return 1;
        }
        jq -e --arg dataset "$dataset" --arg snapshot "$snapshot" --arg guid "$guid" --arg txg "$txg" \
            --arg hold_tag "$hold_tag" --arg newer_sha "$newer_sha" '
            .schema == 1 and .dataset == $dataset and .snapshot == $snapshot and .guid == $guid and
            .createtxg == $txg and .hold_tag == $hold_tag and
            (.restore_mode == "rollback" or .restore_mode == "rsync-exact-files") and
            (if .restore_mode == "rollback" then .mountpoint == ""
             else (.mountpoint | type == "string" and startswith("/")) end) and
            .newer_snapshots_preserved == true and
            .newer_snapshots_evidence_sha256 == $newer_sha and
            .snapshot_identity_verified == true and .snapshot_hold_verified == true and
            .snapshot_zero_diff_verified == true
        ' "$mode_file" >/dev/null || {
            rm -f -- "$expected_list" "$actual_list"; return 1;
        }
        mode=$(jq -er '.restore_mode' "$mode_file") || {
            rm -f -- "$expected_list" "$actual_list"; return 1;
        }
        if [[ -s "$newer" ]]; then
            [[ "$mode" == rsync-exact-files ]] || {
                rm -f -- "$expected_list" "$actual_list"; return 1;
            }
        else
            [[ "$mode" == rollback ]] || {
                rm -f -- "$expected_list" "$actual_list"; return 1;
            }
        fi
    done < <(awk -F'|' '$1 == "ZFS"' "$CURRENT_WAVE_DIR/data-snapshots.tsv")
    rm -f -- "$expected_list" "$actual_list"
}

data_rollback_publish_restore_evidence_manifest()
{
    local manifest="$CURRENT_WAVE_DIR/DATA-RESTORE-EVIDENCE.sha256" expected_list temporary rel
    local failed=0
    [[ ! -e "$manifest" && ! -L "$manifest" ]] || return 1
    expected_list=$(mktemp "$CURRENT_WAVE_DIR/.restore-evidence-files.XXXXXX") || return 1
    temporary=$(mktemp "$CURRENT_WAVE_DIR/.restore-evidence-manifest.XXXXXX") || {
        rm -f -- "$expected_list"; return 1;
    }
    data_rollback_restore_evidence_files "$expected_list" || {
        rm -f -- "$expected_list" "$temporary"; return 1;
    }
    : > "$temporary"
    while IFS= read -r rel; do
        if ! data_rollback_protected_file "$CURRENT_WAVE_DIR/$rel" 600 ||
           ! (cd "$CURRENT_WAVE_DIR" && sha256sum -- "$rel") >> "$temporary"; then
            failed=1
            break
        fi
    done < "$expected_list"
    rm -f -- "$expected_list"
    if ((failed != 0)); then
        rm -f -- "$temporary"
        return 1
    fi
    if ! chmod 600 "$temporary" || ! chown root:root "$temporary" ||
       ! sync -f "$temporary"; then
        rm -f -- "$temporary"; return 1;
    fi
    ln -- "$temporary" "$manifest" || { rm -f -- "$temporary"; return 1; }
    rm -f -- "$temporary"
    sync -f "$CURRENT_WAVE_DIR"
}

data_rollback_verify_data_restored_receipt_body()
{
    local expected_authority_sha=${1:-}
    local receipt="$CURRENT_WAVE_DIR/DATA-RESTORED.json"
    local manifest="$CURRENT_WAVE_DIR/DATA-RESTORE-EVIDENCE.sha256"
    local inventory_sha manifest_sha fileset_expected zfs_expected
    valid_sha256_hex "$expected_authority_sha" || return 1
    data_rollback_verify_authority_sealed "$expected_authority_sha" || return 1
    data_rollback_protected_file "$receipt" 600 || return 1
    data_rollback_canonical_single_object_json "$receipt" || return 1
    data_rollback_protected_file "$manifest" 600 || return 1
    inventory_sha=$(sha256sum "$CURRENT_WAVE_DIR/data-snapshots.tsv" | awk '{print $1}') || return 1
    manifest_sha=$(sha256sum "$manifest" | awk '{print $1}') || return 1
    fileset_expected=$(awk -F'|' '$1 == "FILESET" {count++} END {print count+0}' \
        "$CURRENT_WAVE_DIR/data-snapshots.tsv") || return 1
    zfs_expected=$(awk -F'|' '$1 == "ZFS" {count++} END {print count+0}' \
        "$CURRENT_WAVE_DIR/data-snapshots.tsv") || return 1
    data_rollback_verify_restore_evidence_manifest "$fileset_expected" "$zfs_expected" || return 1
    jq -e --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
        --arg authority_sha "$expected_authority_sha" --arg inventory_sha "$inventory_sha" \
        --arg manifest_sha "$manifest_sha" --argjson fileset_expected "$fileset_expected" \
        --argjson zfs_expected "$zfs_expected" '
        .schema == 2 and .transaction == "v30.1.4-fleet-rollout" and
        .purpose == "pre-upgrade-data-restored" and .run_dir == $run and .wave_dir == $wave and
        .pre_upgrade_data_restored == true and (.restored_at | type) == "string" and
        .rollback_authority_sha256 == $authority_sha and
        .snapshot_inventory_sha256 == $inventory_sha and
        .restore_evidence_manifest_sha256 == $manifest_sha and
        .snapshot_identity_verified == true and .snapshot_zero_diff_verified == true and
        .fileset_restore_expected == $fileset_expected and
        .fileset_restore_completed == $fileset_expected and
        .zfs_restore_expected == $zfs_expected and .zfs_restore_completed == $zfs_expected and
        .fileset_restore_proofs == $fileset_expected and .zfs_rollback_proofs == $zfs_expected
    ' "$receipt" >/dev/null
}

data_rollback_verify_data_restored_receipt()
{
    local expected_authority_sha=${1:-}
    local receipt="$CURRENT_WAVE_DIR/DATA-RESTORED.json"
    local sidecar="$CURRENT_WAVE_DIR/DATA-RESTORED.json.sha256"
    local receipt_sha expected_receipt_sha
    data_rollback_verify_data_restored_receipt_body "$expected_authority_sha" || return 1
    data_rollback_protected_file "$sidecar" 600 || return 1
    expected_receipt_sha=$(awk 'NF == 1 && $1 ~ /^[0-9a-f]{64}$/ {print $1}' "$sidecar") || return 1
    [[ -n "$expected_receipt_sha" && "$(wc -l < "$sidecar")" -eq 1 ]] || return 1
    receipt_sha=$(sha256sum "$receipt" | awk '{print $1}') || return 1
    [[ "$receipt_sha" == "$expected_receipt_sha" ]]
}

data_rollback_publish_data_restored_receipt()
{
    local expected_authority_sha="$1" fileset_expected="$2" zfs_expected="$3"
    local receipt="$CURRENT_WAVE_DIR/DATA-RESTORED.json"
    local sidecar="$CURRENT_WAVE_DIR/DATA-RESTORED.json.sha256"
    local manifest="$CURRENT_WAVE_DIR/DATA-RESTORE-EVIDENCE.sha256"
    local temporary='' sidecar_tmp inventory_sha manifest_sha
    valid_sha256_hex "$expected_authority_sha" || return 1
    [[ "$fileset_expected" =~ ^[0-9]+$ && "$zfs_expected" =~ ^[0-9]+$ ]] || return 1
    data_rollback_verify_authority_sealed "$expected_authority_sha" || return 1
    data_rollback_verify_restore_evidence_manifest "$fileset_expected" "$zfs_expected" || return 1
    if [[ -e "$sidecar" || -L "$sidecar" ]]; then
        [[ -e "$receipt" || -L "$receipt" ]] || return 1
        data_rollback_verify_data_restored_receipt "$expected_authority_sha"
        return
    fi
    inventory_sha=$(sha256sum "$CURRENT_WAVE_DIR/data-snapshots.tsv" | awk '{print $1}') || return 1
    manifest_sha=$(sha256sum "$manifest" | awk '{print $1}') || return 1
    if [[ -e "$receipt" || -L "$receipt" ]]; then
        data_rollback_verify_data_restored_receipt_body "$expected_authority_sha" || return 1
    else
        temporary=$(mktemp "$CURRENT_WAVE_DIR/.data-restored.XXXXXX") || return 1
        jq -S -n --arg run "$RUN_DIR" --arg wave "$CURRENT_WAVE_DIR" \
            --arg restored_at "$(date -u +%FT%TZ)" --arg authority_sha "$expected_authority_sha" \
            --arg inventory_sha "$inventory_sha" --arg manifest_sha "$manifest_sha" \
            --argjson fileset_expected "$fileset_expected" --argjson zfs_expected "$zfs_expected" '
            {schema:2,transaction:"v30.1.4-fleet-rollout",purpose:"pre-upgrade-data-restored",
             run_dir:$run,wave_dir:$wave,pre_upgrade_data_restored:true,restored_at:$restored_at,
             rollback_authority_sha256:$authority_sha,snapshot_inventory_sha256:$inventory_sha,
             restore_evidence_manifest_sha256:$manifest_sha,snapshot_identity_verified:true,
             snapshot_zero_diff_verified:true,fileset_restore_expected:$fileset_expected,
             fileset_restore_completed:$fileset_expected,zfs_restore_expected:$zfs_expected,
             zfs_restore_completed:$zfs_expected,fileset_restore_proofs:$fileset_expected,
             zfs_rollback_proofs:$zfs_expected}' > "$temporary" || {
                rm -f -- "$temporary"; return 1;
            }
        if ! chmod 600 "$temporary" || ! chown root:root "$temporary" ||
           ! sync -f "$temporary"; then
            rm -f -- "$temporary"; return 1
        fi
        ln -- "$temporary" "$receipt" || { rm -f -- "$temporary"; return 1; }
        rm -f -- "$temporary"
        sync -f "$CURRENT_WAVE_DIR" || return 1
        data_rollback_verify_data_restored_receipt_body "$expected_authority_sha" || return 1
    fi
    sidecar_tmp=$(mktemp "$CURRENT_WAVE_DIR/.data-restored-sha.XXXXXX") || return 1
    sha256sum "$receipt" | awk '{print $1}' > "$sidecar_tmp" || {
        rm -f -- "$sidecar_tmp"; return 1;
    }
    if ! chmod 600 "$sidecar_tmp" || ! chown root:root "$sidecar_tmp" ||
       ! sync -f "$sidecar_tmp"; then
        rm -f -- "$sidecar_tmp"; return 1;
    fi
    if ! ln -- "$sidecar_tmp" "$sidecar"; then
        rm -f -- "$sidecar_tmp"
        data_rollback_verify_data_restored_receipt "$expected_authority_sha"
        return
    fi
    rm -f -- "$sidecar_tmp"
    sync -f "$CURRENT_WAVE_DIR" || return 1
    data_rollback_verify_data_restored_receipt "$expected_authority_sha"
}

restore_wave_preupgrade_data()
{
    local expected_authority_sha=${1:-}
    local receipt="$CURRENT_WAVE_DIR/DATA-RESTORED.json"
    local sidecar="$CURRENT_WAVE_DIR/DATA-RESTORED.json.sha256"
    local manifest="$CURRENT_WAVE_DIR/DATA-RESTORE-EVIDENCE.sha256"
    local fileset_expected zfs_expected
    valid_sha256_hex "$expected_authority_sha" || return 1
    fileset_expected=$(awk -F'|' '$1 == "FILESET" {count++} END {print count+0}' \
        "$CURRENT_WAVE_DIR/data-snapshots.tsv") || return 1
    zfs_expected=$(awk -F'|' '$1 == "ZFS" {count++} END {print count+0}' \
        "$CURRENT_WAVE_DIR/data-snapshots.tsv") || return 1
    if [[ -e "$receipt" || -L "$receipt" || -e "$sidecar" || -L "$sidecar" ]]; then
        if [[ -e "$sidecar" || -L "$sidecar" ]]; then
            [[ -e "$receipt" || -L "$receipt" ]] || return 1
            data_rollback_verify_data_restored_receipt "$expected_authority_sha"
        else
            data_rollback_publish_data_restored_receipt "$expected_authority_sha" \
                "$fileset_expected" "$zfs_expected"
        fi
        return
    fi
    if [[ -e "$manifest" || -L "$manifest" ]]; then
        data_rollback_verify_authority_sealed "$expected_authority_sha" || return 1
        data_rollback_verify_restore_evidence_manifest "$fileset_expected" "$zfs_expected" ||
            return 1
        data_rollback_publish_data_restored_receipt "$expected_authority_sha" \
            "$fileset_expected" "$zfs_expected"
        return
    fi
    data_rollback_verify_authority_live "$expected_authority_sha" || return 1
    verify_wave_snapshot_inventory || return 1
    restore_filesets_from_inventory "$expected_authority_sha" || return 1
    restore_zfs_from_inventory "$expected_authority_sha" || return 1
    verify_wave_snapshot_inventory || return 1
    data_rollback_publish_restore_evidence_manifest || return 1
    data_rollback_verify_restore_evidence_manifest "$fileset_expected" "$zfs_expected" || return 1
    data_rollback_publish_data_restored_receipt "$expected_authority_sha" \
        "$fileset_expected" "$zfs_expected"
}
