#!/usr/bin/env bash

# Byte-pinned, crash-recoverable compatibility update for the wallet-runtime
# guard and its endpoint-guard hash pin. The default probe performs no writes.

set -Eeuo pipefail
umask 077
export LC_ALL=C TZ=UTC

readonly PACKAGE_ROOT=${BASH_SOURCE[0]%/*}
readonly ACTION=${1:-probe}
readonly CONFIRM_VALUE=v30.1.4-install-runtime-guard-compat
readonly STATE_DIR=/boot/config/plugins/blackcoin-quantum-nodes
readonly RUNTIME_GUARD="$STATE_DIR/blackcoin_wallet_runtime_guard.sh"
readonly ENDPOINT_GUARD="$STATE_DIR/blackcoin_endpoint_guard.sh"
readonly RUNTIME_BACKUP="$STATE_DIR/.blackcoin_wallet_runtime_guard.pre-v30.1.4"
readonly ENDPOINT_BACKUP="$STATE_DIR/.blackcoin_endpoint_guard.pre-v30.1.4"
readonly JOURNAL="$STATE_DIR/.runtime-guard-v30.1.4-compat.journal.json"
readonly ENDPOINT_LOCK=/run/blackcoin-endpoint-guard.lock
readonly WALLET_LOCK=/var/run/blackcoin-wallet-runtime-guard.lock
readonly MAINTENANCE_BLOCK="$PACKAGE_ROOT/guard_rollout_maintenance_block.sh.inc"
readonly OLD_RUNTIME_SHA256=5f80bf8113c2b193b2beed335aa6155a6ba64710f8b441778f852f6ca2531130
readonly OLD_ENDPOINT_SHA256=77402bc3148e5f5ed91fcd24ba56a014d5bf71411545fb0695a708ae18442f21
# shellcheck disable=SC2016
readonly OLD_RUNTIME_LINE='    [[ "$class" == final3013 || "$class" == node16fix ]] && expected_replay_schema=12'
# shellcheck disable=SC2016
readonly NEW_RUNTIME_LINE='    [[ "$class" == final3013 || "$class" == node16fix || "$class" == final3014 ]] && expected_replay_schema=12'
readonly OLD_ENDPOINT_PIN="EXPECTED_RUNTIME_GUARD_SHA='$OLD_RUNTIME_SHA256'"
readonly RUNTIME_MAINTENANCE_ANCHOR='flock -n 7 || exit 1'
readonly ENDPOINT_MAINTENANCE_ANCHOR='flock -n 9 || exit 0'
readonly MAINTENANCE_BLOCK_BEGIN='# BEGIN V30.1.4 DURABLE ROLLOUT MAINTENANCE INHIBITOR'
readonly MAINTENANCE_BLOCK_END='# END V30.1.4 DURABLE ROLLOUT MAINTENANCE INHIBITOR'
readonly EXPECTED_MAINTENANCE_BLOCK_SHA256=9f336f2f61efd785cd0a6c63107724ac47c99038d29e0e211de7c3f702387a5b
readonly EXPECTED_NEW_RUNTIME_SHA256=9ed02479801cb0de4085f9d6055500bb7d22de86d2fc2b91be6c19e9955398ee
readonly EXPECTED_NEW_ENDPOINT_SHA256=81135dd9637cd5b4fa42a0c634f1decb37fcd68a280c55c661b640226196880f

RUNTIME_CANDIDATE=
ENDPOINT_CANDIDATE=
TRANSFORM_STAGE=
STRIPPED_STAGE=
REVERSE_CHECK=
NEW_RUNTIME_SHA256=$EXPECTED_NEW_RUNTIME_SHA256
NEW_ENDPOINT_SHA256=$EXPECTED_NEW_ENDPOINT_SHA256
MAINTENANCE_BLOCK_SHA256=$EXPECTED_MAINTENANCE_BLOCK_SHA256
MUTATION_STARTED=0

log()
{
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"
}

die()
{
    log "FATAL: $*" >&2
    exit 1
}

file_sha()
{
    sha256sum "$1" | awk '{print $1}'
}

protected_file()
{
    local path="$1"
    [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
       "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]]
}

protected_directory()
{
    local path="$1" owner mode
    [[ -d "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" ]] || return 1
    owner=$(stat -c '%u:%g' "$path") || return 1
    mode=$(stat -c '%a' "$path") || return 1
    [[ "$owner" == 0:0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 ))
}

verify_package()
{
    protected_directory "$PACKAGE_ROOT" && protected_file "$PACKAGE_ROOT/SHA256SUMS" &&
        (cd "$PACKAGE_ROOT" && sha256sum --strict -c SHA256SUMS >/dev/null)
}

exact_old_pair()
{
    protected_file "$RUNTIME_GUARD" && protected_file "$ENDPOINT_GUARD" &&
        [[ "$(file_sha "$RUNTIME_GUARD")" == "$OLD_RUNTIME_SHA256" &&
           "$(file_sha "$ENDPOINT_GUARD")" == "$OLD_ENDPOINT_SHA256" ]]
}

exact_backups()
{
    protected_file "$RUNTIME_BACKUP" && protected_file "$ENDPOINT_BACKUP" &&
        [[ "$(file_sha "$RUNTIME_BACKUP")" == "$OLD_RUNTIME_SHA256" &&
           "$(file_sha "$ENDPOINT_BACKUP")" == "$OLD_ENDPOINT_SHA256" ]]
}

transform_exact_line()
{
    local source="$1" destination="$2" old_line="$3" new_line="$4"
    awk -v old_line="$old_line" -v new_line="$new_line" '
        BEGIN { replacements = 0 }
        $0 == old_line { $0 = new_line; replacements++ }
        { print }
        END { if (replacements != 1) exit 42 }
    ' "$source" > "$destination"
}

insert_exact_block_after_line()
{
    local source="$1" destination="$2" anchor="$3" block="$4"
    awk -v anchor="$anchor" -v block="$block" '
        BEGIN {
            count = 0
            while ((getline line < block) > 0) lines[++count] = line
            close(block)
            if (count == 0) exit 41
        }
        $0 == anchor {
            matches++
            print
            for (i = 1; i <= count; i++) print lines[i]
            next
        }
        { print }
        END { if (matches != 1) exit 42 }
    ' "$source" > "$destination"
}

remove_exact_block()
{
    local source="$1" destination="$2" block="$3"
    awk -v block="$block" '
        BEGIN {
            count = 0
            while ((getline line < block) > 0) lines[++count] = line
            close(block)
            if (count == 0) exit 41
        }
        $0 == lines[1] {
            matches++
            for (i = 2; i <= count; i++) {
                if ((getline observed) <= 0 || observed != lines[i]) exit 43
            }
            next
        }
        { print }
        END { if (matches != 1) exit 42 }
    ' "$source" > "$destination"
}

prepare_candidate_file()
{
    local path="$1"
    chmod 600 "$path" || return 1
    chown root:root "$path" || return 1
    sync -f "$path" || return 1
}

derive_candidates()
{
    local runtime_source="$1" endpoint_source="$2" policy_before policy_after new_endpoint_pin
    [[ -f "$MAINTENANCE_BLOCK" && ! -L "$MAINTENANCE_BLOCK" &&
       "$(grep -Fxc -- "$MAINTENANCE_BLOCK_BEGIN" "$MAINTENANCE_BLOCK")" -eq 1 &&
       "$(grep -Fxc -- "$MAINTENANCE_BLOCK_END" "$MAINTENANCE_BLOCK")" -eq 1 ]] || return 1
    [[ "$(file_sha "$MAINTENANCE_BLOCK")" == "$EXPECTED_MAINTENANCE_BLOCK_SHA256" ]] || return 1
    [[ "$(file_sha "$runtime_source")" == "$OLD_RUNTIME_SHA256" &&
       "$(file_sha "$endpoint_source")" == "$OLD_ENDPOINT_SHA256" ]] || return 1
    [[ "$(grep -Fxc -- "$OLD_RUNTIME_LINE" "$runtime_source")" -eq 1 &&
       "$(grep -Fxc -- "$NEW_RUNTIME_LINE" "$runtime_source")" -eq 0 &&
       "$(grep -Fxc -- "$OLD_ENDPOINT_PIN" "$endpoint_source")" -eq 1 &&
       "$(grep -Fxc -- "$RUNTIME_MAINTENANCE_ANCHOR" "$runtime_source")" -eq 1 &&
       "$(grep -Fxc -- "$ENDPOINT_MAINTENANCE_ANCHOR" "$endpoint_source")" -eq 1 &&
       "$(grep -Fxc -- "$MAINTENANCE_BLOCK_BEGIN" "$runtime_source")" -eq 0 &&
       "$(grep -Fxc -- "$MAINTENANCE_BLOCK_BEGIN" "$endpoint_source")" -eq 0 ]] || return 1

    RUNTIME_CANDIDATE=$(mktemp "$STATE_DIR/.runtime-guard-v30.1.4.candidate.XXXXXX") || return 1
    ENDPOINT_CANDIDATE=$(mktemp "$STATE_DIR/.endpoint-guard-v30.1.4.candidate.XXXXXX") || return 1
    TRANSFORM_STAGE=$(mktemp "$STATE_DIR/.guard-v30.1.4.transform.XXXXXX") || return 1
    STRIPPED_STAGE=$(mktemp "$STATE_DIR/.guard-v30.1.4.stripped.XXXXXX") || return 1
    REVERSE_CHECK=$(mktemp "$STATE_DIR/.runtime-guard-v30.1.4.reverse.XXXXXX") || return 1
    transform_exact_line "$runtime_source" "$TRANSFORM_STAGE" \
        "$OLD_RUNTIME_LINE" "$NEW_RUNTIME_LINE" || return 1
    insert_exact_block_after_line "$TRANSFORM_STAGE" "$RUNTIME_CANDIDATE" \
        "$RUNTIME_MAINTENANCE_ANCHOR" "$MAINTENANCE_BLOCK" || return 1
    prepare_candidate_file "$RUNTIME_CANDIDATE" || return 1
    /bin/bash -n "$RUNTIME_CANDIDATE" || return 1
    [[ "$(grep -Fxc -- "$OLD_RUNTIME_LINE" "$RUNTIME_CANDIDATE")" -eq 0 &&
       "$(grep -Fxc -- "$NEW_RUNTIME_LINE" "$RUNTIME_CANDIDATE")" -eq 1 &&
       "$(grep -Fxc -- "$MAINTENANCE_BLOCK_BEGIN" "$RUNTIME_CANDIDATE")" -eq 1 &&
       "$(grep -Fxc -- "$MAINTENANCE_BLOCK_END" "$RUNTIME_CANDIDATE")" -eq 1 ]] || return 1
    remove_exact_block "$RUNTIME_CANDIDATE" "$STRIPPED_STAGE" "$MAINTENANCE_BLOCK" || return 1
    cmp -s "$TRANSFORM_STAGE" "$STRIPPED_STAGE" || return 1
    transform_exact_line "$STRIPPED_STAGE" "$REVERSE_CHECK" \
        "$NEW_RUNTIME_LINE" "$OLD_RUNTIME_LINE" || return 1
    cmp -s "$runtime_source" "$REVERSE_CHECK" || return 1
    NEW_RUNTIME_SHA256=$(file_sha "$RUNTIME_CANDIDATE") || return 1
    [[ "$NEW_RUNTIME_SHA256" == "$EXPECTED_NEW_RUNTIME_SHA256" ]] || return 1

    new_endpoint_pin="EXPECTED_RUNTIME_GUARD_SHA='$NEW_RUNTIME_SHA256'"
    transform_exact_line "$endpoint_source" "$TRANSFORM_STAGE" \
        "$OLD_ENDPOINT_PIN" "$new_endpoint_pin" || return 1
    insert_exact_block_after_line "$TRANSFORM_STAGE" "$ENDPOINT_CANDIDATE" \
        "$ENDPOINT_MAINTENANCE_ANCHOR" "$MAINTENANCE_BLOCK" || return 1
    prepare_candidate_file "$ENDPOINT_CANDIDATE" || return 1
    /bin/bash -n "$ENDPOINT_CANDIDATE" || return 1
    [[ "$(grep -Fxc -- "$OLD_ENDPOINT_PIN" "$ENDPOINT_CANDIDATE")" -eq 0 &&
       "$(grep -Fxc -- "$new_endpoint_pin" "$ENDPOINT_CANDIDATE")" -eq 1 &&
       "$(grep -Fxc -- "$MAINTENANCE_BLOCK_BEGIN" "$ENDPOINT_CANDIDATE")" -eq 1 &&
       "$(grep -Fxc -- "$MAINTENANCE_BLOCK_END" "$ENDPOINT_CANDIDATE")" -eq 1 ]] || return 1
    remove_exact_block "$ENDPOINT_CANDIDATE" "$STRIPPED_STAGE" "$MAINTENANCE_BLOCK" || return 1
    cmp -s "$TRANSFORM_STAGE" "$STRIPPED_STAGE" || return 1
    transform_exact_line "$STRIPPED_STAGE" "$REVERSE_CHECK" \
        "$new_endpoint_pin" "$OLD_ENDPOINT_PIN" || return 1
    cmp -s "$endpoint_source" "$REVERSE_CHECK" || return 1
    policy_before=$(sed -n "s/^EXPECTED_IMAGE_POLICY_SHA='\([0-9a-f]\{64\}\)'$/\1/p" \
        "$endpoint_source") || return 1
    policy_after=$(sed -n "s/^EXPECTED_IMAGE_POLICY_SHA='\([0-9a-f]\{64\}\)'$/\1/p" \
        "$ENDPOINT_CANDIDATE") || return 1
    [[ "$policy_before" =~ ^[0-9a-f]{64}$ && "$policy_after" == "$policy_before" ]] || return 1
    NEW_ENDPOINT_SHA256=$(file_sha "$ENDPOINT_CANDIDATE") || return 1
    [[ "$NEW_ENDPOINT_SHA256" == "$EXPECTED_NEW_ENDPOINT_SHA256" ]]
}

cleanup_candidates()
{
    local path
    for path in "$RUNTIME_CANDIDATE" "$ENDPOINT_CANDIDATE" "$TRANSFORM_STAGE" \
        "$STRIPPED_STAGE" "$REVERSE_CHECK"; do
        [[ -z "$path" || ! -e "$path" || -L "$path" ]] || rm -f -- "$path"
    done
}

ensure_backup()
{
    local source="$1" backup="$2" expected="$3" temporary
    if [[ -e "$backup" || -L "$backup" ]]; then
        protected_file "$backup" && [[ "$(file_sha "$backup")" == "$expected" ]]
        return
    fi
    protected_file "$source" && [[ "$(file_sha "$source")" == "$expected" ]] || return 1
    temporary=$(mktemp "${backup}.install.XXXXXX") || return 1
    install -m 600 -o root -g root -- "$source" "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    [[ "$(file_sha "$temporary")" == "$expected" ]] || {
        rm -f -- "$temporary"
        return 1
    }
    sync -f "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    mv -T -- "$temporary" "$backup" || {
        rm -f -- "$temporary"
        return 1
    }
    sync -f "$STATE_DIR" || return 1
}

write_journal()
{
    local phase="$1" temporary
    temporary=$(mktemp "$STATE_DIR/.runtime-guard-v30.1.4-journal.XXXXXX") || return 1
    jq -n --arg phase "$phase" --arg old_runtime "$OLD_RUNTIME_SHA256" \
        --arg new_runtime "$NEW_RUNTIME_SHA256" --arg old_endpoint "$OLD_ENDPOINT_SHA256" \
        --arg new_endpoint "$NEW_ENDPOINT_SHA256" --arg runtime_backup "$RUNTIME_BACKUP" \
        --arg endpoint_backup "$ENDPOINT_BACKUP" --arg block "$MAINTENANCE_BLOCK_SHA256" \
        --arg updated_at "$(date -u +%FT%TZ)" \
        '{schema:1,transaction:"runtime-guard-v30.1.4-compat",phase:$phase,
          old_runtime_sha256:$old_runtime,new_runtime_sha256:$new_runtime,
          old_endpoint_sha256:$old_endpoint,new_endpoint_sha256:$new_endpoint,
          maintenance_inhibitor_sha256:$block,
          runtime_backup:$runtime_backup,endpoint_backup:$endpoint_backup,
          updated_at:$updated_at}' > "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    prepare_candidate_file "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    mv -fT -- "$temporary" "$JOURNAL" || {
        rm -f -- "$temporary"
        return 1
    }
    sync -f "$STATE_DIR" || return 1
}

valid_journal()
{
    protected_file "$JOURNAL" && jq -e \
        --arg old_runtime "$OLD_RUNTIME_SHA256" --arg new_runtime "$NEW_RUNTIME_SHA256" \
        --arg old_endpoint "$OLD_ENDPOINT_SHA256" --arg new_endpoint "$NEW_ENDPOINT_SHA256" \
        --arg runtime_backup "$RUNTIME_BACKUP" --arg endpoint_backup "$ENDPOINT_BACKUP" \
        --arg block "$MAINTENANCE_BLOCK_SHA256" '
        .schema == 1 and .transaction == "runtime-guard-v30.1.4-compat" and
        (.phase | IN("prepared","before-runtime-commit","runtime-committed",
          "before-endpoint-commit","pair-committed","complete","rollback-started","rolled-back")) and
        .old_runtime_sha256 == $old_runtime and .new_runtime_sha256 == $new_runtime and
        .old_endpoint_sha256 == $old_endpoint and .new_endpoint_sha256 == $new_endpoint and
        .maintenance_inhibitor_sha256 == $block and
        .runtime_backup == $runtime_backup and .endpoint_backup == $endpoint_backup and
        (.updated_at | type == "string")
    ' "$JOURNAL" >/dev/null
}

live_pair_state()
{
    local runtime_sha endpoint_sha
    protected_file "$RUNTIME_GUARD" && protected_file "$ENDPOINT_GUARD" || return 1
    runtime_sha=$(file_sha "$RUNTIME_GUARD") || return 1
    endpoint_sha=$(file_sha "$ENDPOINT_GUARD") || return 1
    if [[ "$runtime_sha" == "$OLD_RUNTIME_SHA256" && "$endpoint_sha" == "$OLD_ENDPOINT_SHA256" ]]; then
        printf '%s\n' old
    elif [[ "$runtime_sha" == "$NEW_RUNTIME_SHA256" && "$endpoint_sha" == "$OLD_ENDPOINT_SHA256" ]]; then
        printf '%s\n' runtime-new
    elif [[ "$runtime_sha" == "$OLD_RUNTIME_SHA256" && "$endpoint_sha" == "$NEW_ENDPOINT_SHA256" ]]; then
        printf '%s\n' endpoint-new
    elif [[ "$runtime_sha" == "$NEW_RUNTIME_SHA256" && "$endpoint_sha" == "$NEW_ENDPOINT_SHA256" ]]; then
        printf '%s\n' complete
    else
        return 1
    fi
}

atomic_replace()
{
    local candidate="$1" destination="$2" expected="$3" temporary
    temporary=$(mktemp "${destination}.commit.XXXXXX") || return 1
    install -m 600 -o root -g root -- "$candidate" "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    [[ "$(file_sha "$temporary")" == "$expected" ]] || {
        rm -f -- "$temporary"
        return 1
    }
    sync -f "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    mv -fT -- "$temporary" "$destination" || {
        rm -f -- "$temporary"
        return 1
    }
    sync -f "$STATE_DIR" || return 1
    protected_file "$destination" && [[ "$(file_sha "$destination")" == "$expected" ]]
}

rollback_pair()
{
    exact_backups || return 1
    write_journal rollback-started || return 1
    # Restore the old endpoint pin first. Any intermediate mixed generation is
    # therefore fail-closed rather than authorizing an unpinned runtime guard.
    atomic_replace "$ENDPOINT_BACKUP" "$ENDPOINT_GUARD" "$OLD_ENDPOINT_SHA256" || return 1
    atomic_replace "$RUNTIME_BACKUP" "$RUNTIME_GUARD" "$OLD_RUNTIME_SHA256" || return 1
    exact_old_pair || return 1
    write_journal rolled-back
}

on_exit()
{
    local rc=$?
    trap - EXIT INT TERM
    if [[ "$rc" -ne 0 && "$MUTATION_STARTED" -eq 1 ]]; then
        rollback_pair || log 'FATAL: automatic exact rollback failed; journal and backups retained' >&2
    fi
    cleanup_candidates
    exit "$rc"
}

verify_complete_pair()
{
    protected_file "$RUNTIME_GUARD" && protected_file "$ENDPOINT_GUARD" &&
        [[ "$(file_sha "$RUNTIME_GUARD")" == "$NEW_RUNTIME_SHA256" &&
           "$(file_sha "$ENDPOINT_GUARD")" == "$NEW_ENDPOINT_SHA256" ]] &&
        /bin/bash -n "$RUNTIME_GUARD" && /bin/bash -n "$ENDPOINT_GUARD" &&
        [[ "$(grep -Fxc -- "$NEW_RUNTIME_LINE" "$RUNTIME_GUARD")" -eq 1 &&
           "$(grep -Fxc -- "EXPECTED_RUNTIME_GUARD_SHA='$NEW_RUNTIME_SHA256'" \
              "$ENDPOINT_GUARD")" -eq 1 &&
           "$(grep -Fxc -- "$MAINTENANCE_BLOCK_BEGIN" "$RUNTIME_GUARD")" -eq 1 &&
           "$(grep -Fxc -- "$MAINTENANCE_BLOCK_BEGIN" "$ENDPOINT_GUARD")" -eq 1 ]]
}

probe()
{
    local runtime_sha endpoint_sha
    verify_package || die 'package integrity verification failed'
    [[ "$(id -u)" -eq 0 ]] || die 'root is required'
    protected_directory "$STATE_DIR" || die 'state directory is unsafe'
    if ! protected_file "$RUNTIME_GUARD" || ! protected_file "$ENDPOINT_GUARD"; then
        die 'live guard pair is not canonical root:root 0600'
    fi
    runtime_sha=$(file_sha "$RUNTIME_GUARD")
    endpoint_sha=$(file_sha "$ENDPOINT_GUARD")
    if [[ "$runtime_sha" == "$OLD_RUNTIME_SHA256" && "$endpoint_sha" == "$OLD_ENDPOINT_SHA256" &&
          ! -e "$JOURNAL" && ! -L "$JOURNAL" ]]; then
        printf '%s\n' 'state=compatible-install-required'
        return 0
    fi
    [[ "$(file_sha "$MAINTENANCE_BLOCK")" == "$EXPECTED_MAINTENANCE_BLOCK_SHA256" ]] ||
        die 'maintenance inhibitor package bytes changed'
    exact_backups || die 'guard pair is not pristine and exact old backups are unavailable'
    valid_journal || die 'compatibility journal is absent or invalid'
    case "$(live_pair_state)" in
        complete)
            verify_complete_pair || die 'installed guard pair failed compatibility verification'
            printf 'state=installed runtime_sha256=%s endpoint_sha256=%s\n' \
                "$NEW_RUNTIME_SHA256" "$NEW_ENDPOINT_SHA256"
            ;;
        old|runtime-new|endpoint-new)
            printf '%s\n' 'state=interrupted-or-rolled-back-confirmed-install-required'
            ;;
        *)
            die 'guard pair state is not recoverable'
            ;;
    esac
}

install_compatibility()
{
    local state
    [[ "${CONFIRM_INSTALL_RUNTIME_GUARD_3014_COMPAT:-}" == "$CONFIRM_VALUE" ]] ||
        die "install requires CONFIRM_INSTALL_RUNTIME_GUARD_3014_COMPAT=$CONFIRM_VALUE"
    verify_package || die 'package integrity verification failed'
    [[ "$(id -u)" -eq 0 ]] || die 'root is required'
    protected_directory "$STATE_DIR" || die 'state directory is unsafe'
    [[ ! -L "$ENDPOINT_LOCK" && ! -L "$WALLET_LOCK" ]] || die 'guard lock path is unsafe'
    exec 15>"$ENDPOINT_LOCK"
    flock -w 1800 15 || die 'endpoint guard did not drain'
    exec 17>"$WALLET_LOCK"
    flock -w 1800 17 || die 'wallet runtime guard did not drain'

    if exact_old_pair; then
        ensure_backup "$RUNTIME_GUARD" "$RUNTIME_BACKUP" "$OLD_RUNTIME_SHA256" ||
            die 'could not establish exact runtime backup'
        ensure_backup "$ENDPOINT_GUARD" "$ENDPOINT_BACKUP" "$OLD_ENDPOINT_SHA256" ||
            die 'could not establish exact endpoint backup'
    else
        exact_backups || die 'non-pristine pair lacks exact rollback backups'
    fi
    derive_candidates "$RUNTIME_BACKUP" "$ENDPOINT_BACKUP" || {
        cleanup_candidates
        die 'candidate derivation failed'
    }
    trap cleanup_candidates EXIT
    if [[ -e "$JOURNAL" || -L "$JOURNAL" ]]; then
        valid_journal || die 'existing compatibility journal is invalid'
    else
        write_journal prepared
    fi
    state=$(live_pair_state) || die 'live pair contains an unknown generation'
    if [[ "$state" == complete ]]; then
        verify_complete_pair || die 'installed guard pair failed compatibility verification'
        write_journal complete
        log "runtime guard compatibility already installed runtime_sha256=$NEW_RUNTIME_SHA256 endpoint_sha256=$NEW_ENDPOINT_SHA256"
        cleanup_candidates
        return 0
    fi

    MUTATION_STARTED=1
    trap on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ "$state" == old || "$state" == endpoint-new ]]; then
        write_journal before-runtime-commit
        atomic_replace "$RUNTIME_CANDIDATE" "$RUNTIME_GUARD" "$NEW_RUNTIME_SHA256" ||
            die 'runtime guard atomic commit failed'
        write_journal runtime-committed
    fi
    state=$(live_pair_state) || die 'runtime commit produced an unknown pair state'
    if [[ "$state" == runtime-new ]]; then
        write_journal before-endpoint-commit
        atomic_replace "$ENDPOINT_CANDIDATE" "$ENDPOINT_GUARD" "$NEW_ENDPOINT_SHA256" ||
            die 'endpoint guard atomic commit failed'
        write_journal pair-committed
    fi
    verify_complete_pair || die 'committed guard pair failed final verification'
    write_journal complete
    MUTATION_STARTED=0
    trap - EXIT INT TERM
    cleanup_candidates
    log "runtime guard compatibility installed runtime_sha256=$NEW_RUNTIME_SHA256 endpoint_sha256=$NEW_ENDPOINT_SHA256"
}

for command in awk bash chmod chown cmp date flock grep install jq mktemp mv realpath rm \
    sed sha256sum stat sync; do
    command -v "$command" >/dev/null 2>&1 || die "required command unavailable: $command"
done

case "$ACTION" in
    probe) probe ;;
    install) install_compatibility ;;
    *) printf 'usage: %s [probe|install]\n' "$0" >&2; exit 64 ;;
esac
