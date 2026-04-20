#!/usr/bin/env bash
# LUKS+LVM Multi-Drive Manager
set -euo pipefail

SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname -- "$SELF")"

if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[1;33m'
    C_BLU=$'\033[0;34m'; C_NC=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_NC=''
fi

DRY_RUN="${MANAGE_DRIVE_DRY_RUN:-0}"
CONFIG_OVERRIDE=""
COMMAND=""
POSITIONAL=()

declare -A DRIVE_UUID DRIVE_LUKS DRIVE_MOUNT DRIVE_VG DRIVE_LV DRIVE_AUTO
DRIVE_NAMES=()

log_info()  { printf '%s[INFO]%s %s\n'  "$C_GRN" "$C_NC" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n'  "$C_YLW" "$C_NC" "$*" >&2; }
log_error() { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_NC" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

run_cmd() {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf '%s[DRY-RUN]%s %s\n' "$C_BLU" "$C_NC" "$*"
        return 0
    fi
    "$@"
}

require_root() {
    [[ $EUID -eq 0 ]] || die "This command must run as root (try: sudo $0 $COMMAND ...)"
}

add_drive() {
    local name="" uuid="" luks_name="" mount_point=""
    local vg_name="" lv_name="" auto_mount="no"
    local arg
    for arg in "$@"; do
        case "$arg" in
            name=*)        name="${arg#name=}" ;;
            uuid=*)        uuid="${arg#uuid=}" ;;
            luks_name=*)   luks_name="${arg#luks_name=}" ;;
            mount_point=*) mount_point="${arg#mount_point=}" ;;
            vg_name=*)     vg_name="${arg#vg_name=}" ;;
            lv_name=*)     lv_name="${arg#lv_name=}" ;;
            auto_mount=*)  auto_mount="${arg#auto_mount=}" ;;
            *) die "add_drive: unknown key in '$arg' (expected name=, uuid=, luks_name=, mount_point=, vg_name=, lv_name=, auto_mount=)" ;;
        esac
    done

    [[ -n "$name" ]]        || die "add_drive: missing required 'name'"
    [[ -n "$uuid" ]]        || die "add_drive: missing 'uuid' for drive '$name'"
    [[ -n "$mount_point" ]] || die "add_drive: missing 'mount_point' for drive '$name'"
    [[ -z "${DRIVE_UUID[$name]:-}" ]] || die "add_drive: duplicate drive name '$name'"
    if [[ -n "$vg_name" && -z "$lv_name" ]] || [[ -z "$vg_name" && -n "$lv_name" ]]; then
        die "add_drive: drive '$name' must set both vg_name and lv_name, or neither"
    fi
    case "$auto_mount" in
        yes|no) ;;
        *) die "add_drive: drive '$name' auto_mount must be 'yes' or 'no' (got '$auto_mount')" ;;
    esac
    [[ -n "$luks_name" ]] || luks_name="luks-${name}"

    DRIVE_UUID[$name]="$uuid"
    DRIVE_LUKS[$name]="$luks_name"
    DRIVE_MOUNT[$name]="$mount_point"
    DRIVE_VG[$name]="$vg_name"
    DRIVE_LV[$name]="$lv_name"
    DRIVE_AUTO[$name]="$auto_mount"
    DRIVE_NAMES+=("$name")
}

load_config() {
    local loaded=0

    _source_conf() {
        # shellcheck disable=SC1090
        source "$1"
        log_info "loaded config: $1"
        loaded=1
    }

    if [[ -n "$CONFIG_OVERRIDE" ]]; then
        [[ -f "$CONFIG_OVERRIDE" ]] || die "config file not found: $CONFIG_OVERRIDE"
        _source_conf "$CONFIG_OVERRIDE"
    else
        local paths=(
            "$SELF_DIR/drives.conf"
            "$HOME/.luks-drives/drives.conf"
            "/etc/luks-drive-manager/drives.conf"
        )
        local dirs=(
            "$SELF_DIR/conf.d"
            "$HOME/.luks-drives/conf.d"
            "/etc/luks-drive-manager/conf.d"
        )
        local p d f
        for p in "${paths[@]}"; do
            [[ -f "$p" ]] && _source_conf "$p"
        done
        for d in "${dirs[@]}"; do
            [[ -d "$d" ]] || continue
            for f in "$d"/*.conf; do
                [[ -f "$f" ]] && _source_conf "$f"
            done
        done
    fi

    (( loaded == 1 )) || die "no config files found (expected drives.conf or conf.d/*.conf beside the script, in ~/.luks-drives/, or in /etc/luks-drive-manager/)"
    (( ${#DRIVE_NAMES[@]} > 0 )) || die "config loaded but no drives registered — see drives.conf.example"
}

require_known_drive() {
    local name="$1"
    [[ -n "${DRIVE_UUID[$name]:-}" ]] || die "unknown drive '$name' (configured: ${DRIVE_NAMES[*]})"
}

device_for_uuid() {
    local uuid="$1"
    local link="/dev/disk/by-uuid/$uuid"
    [[ -e "$link" ]] || return 1
    readlink -f -- "$link"
}

is_luks_open() { cryptsetup status "$1" >/dev/null 2>&1; }
is_mounted()   { mountpoint -q "$1" 2>/dev/null; }

mount_one() {
    local name="$1"
    local uuid="${DRIVE_UUID[$name]}"
    local luks="${DRIVE_LUKS[$name]}"
    local mnt="${DRIVE_MOUNT[$name]}"
    local vg="${DRIVE_VG[$name]}"
    local lv="${DRIVE_LV[$name]}"

    log_info "[$name] mount"

    local dev
    if ! dev="$(device_for_uuid "$uuid")"; then
        log_warn "[$name] UUID $uuid not present on system — skipping"
        return 0
    fi
    log_info "[$name] device: $dev"

    if is_mounted "$mnt"; then
        log_info "[$name] already mounted at $mnt — skipping"
        return 0
    fi

    if is_luks_open "$luks"; then
        log_info "[$name] LUKS already open ($luks)"
    else
        log_info "[$name] opening LUKS → $luks"
        run_cmd cryptsetup open "$dev" "$luks" || { log_error "[$name] cryptsetup open failed"; return 1; }
    fi

    if [[ -n "$vg" ]]; then
        log_info "[$name] activating VG $vg"
        run_cmd pvscan --cache >/dev/null 2>&1 || true
        run_cmd vgchange -ay "$vg" >/dev/null || { log_error "[$name] vgchange failed"; return 1; }
    fi

    local src
    if [[ -n "$vg" ]]; then
        src="/dev/mapper/${vg}-${lv}"
    else
        src="/dev/mapper/$luks"
    fi

    run_cmd mkdir -p "$mnt"
    log_info "[$name] mounting $src → $mnt"
    run_cmd mount "$src" "$mnt" || { log_error "[$name] mount failed"; return 1; }
    log_info "[$name] ✓ mounted at $mnt"
}

unmount_one() {
    local name="$1"
    local luks="${DRIVE_LUKS[$name]}"
    local mnt="${DRIVE_MOUNT[$name]}"
    local vg="${DRIVE_VG[$name]}"
    local lv="${DRIVE_LV[$name]}"

    log_info "[$name] unmount"

    if is_mounted "$mnt"; then
        log_info "[$name] umount $mnt"
        run_cmd umount "$mnt" || { log_error "[$name] umount failed"; return 1; }
    else
        log_info "[$name] not mounted"
    fi

    if [[ -n "$vg" ]]; then
        log_info "[$name] deactivating VG $vg"
        [[ -n "$lv" ]] && run_cmd lvchange -an "/dev/${vg}/${lv}" >/dev/null 2>&1 || true
        run_cmd vgchange -an "$vg" >/dev/null 2>&1 || true
    fi

    if is_luks_open "$luks"; then
        log_info "[$name] closing LUKS $luks"
        run_cmd cryptsetup close "$luks" || { log_error "[$name] cryptsetup close failed"; return 1; }
    fi

    log_info "[$name] ✓ unmounted"
}

status_row() {
    local name="$1"
    local uuid="${DRIVE_UUID[$name]}"
    local luks="${DRIVE_LUKS[$name]}"
    local mnt="${DRIVE_MOUNT[$name]}"
    local vg="${DRIVE_VG[$name]}"

    local present="no" luks_state="closed" lvm_state="-" mount_state="no" where="-"
    [[ -e "/dev/disk/by-uuid/$uuid" ]] && present="yes"
    is_luks_open "$luks" && luks_state="open"
    if [[ -n "$vg" ]]; then
        if vgs "$vg" >/dev/null 2>&1; then
            lvm_state="active"
        else
            lvm_state="inactive"
        fi
    fi
    if is_mounted "$mnt"; then
        mount_state="yes"
        where="$mnt"
    fi

    printf '%-12s  %-8s  %-6s  %-8s  %-7s  %s\n' \
        "$name" "$present" "$luks_state" "$lvm_state" "$mount_state" "$where"
}

cmd_status() {
    local names=("$@")
    (( ${#names[@]} > 0 )) || names=("${DRIVE_NAMES[@]}")
    printf '%-12s  %-8s  %-6s  %-8s  %-7s  %s\n' \
        "NAME" "PRESENT" "LUKS" "LVM" "MOUNTED" "POINT"
    printf '%-12s  %-8s  %-6s  %-8s  %-7s  %s\n' \
        "------------" "--------" "------" "--------" "-------" "-----"
    local n
    for n in "${names[@]}"; do
        require_known_drive "$n"
        status_row "$n"
    done
}

cmd_mount() {
    require_root
    local names=("$@")
    (( ${#names[@]} > 0 )) || names=("${DRIVE_NAMES[@]}")
    local n rc=0
    for n in "${names[@]}"; do
        require_known_drive "$n"
        mount_one "$n" || rc=1
    done
    return $rc
}

cmd_unmount() {
    require_root
    local names=("$@")
    if (( ${#names[@]} == 0 )); then
        local n
        for n in "${DRIVE_NAMES[@]}"; do
            if is_mounted "${DRIVE_MOUNT[$n]}" || is_luks_open "${DRIVE_LUKS[$n]}"; then
                names+=("$n")
            fi
        done
    fi
    if (( ${#names[@]} == 0 )); then
        log_info "no managed drives are currently mounted"
        return 0
    fi
    local n rc=0
    for n in "${names[@]}"; do
        require_known_drive "$n"
        unmount_one "$n" || rc=1
    done
    return $rc
}

cmd_cleanup() {
    require_root
    local names=("$@")
    (( ${#names[@]} > 0 )) || names=("${DRIVE_NAMES[@]}")
    local n
    for n in "${names[@]}"; do
        require_known_drive "$n"
        local luks="${DRIVE_LUKS[$n]}"
        local vg="${DRIVE_VG[$n]}"
        local lv="${DRIVE_LV[$n]}"
        log_info "[$n] cleaning stale mappings"
        if cryptsetup status "$luks" 2>/dev/null | grep -q "device:.*null"; then
            log_warn "[$n] LUKS mapping points to null device — removing"
            [[ -n "$vg" && -n "$lv" ]] && run_cmd dmsetup remove "${vg}-${lv}" 2>/dev/null || true
            [[ -n "$vg" ]] && run_cmd vgchange -an "$vg" 2>/dev/null || true
            run_cmd cryptsetup close "$luks" 2>/dev/null || true
        fi
    done
}

cmd_recover() {
    require_root
    (( $# <= 1 )) || die "recover takes at most one drive name"
    local name
    if (( $# == 1 )); then
        name="$1"
        require_known_drive "$name"
    elif (( ${#DRIVE_NAMES[@]} == 1 )); then
        name="${DRIVE_NAMES[0]}"
    else
        die "recover requires a drive name when multiple drives are configured (have: ${DRIVE_NAMES[*]})"
    fi

    local uuid="${DRIVE_UUID[$name]}"
    local luks="${DRIVE_LUKS[$name]}"
    local mnt="${DRIVE_MOUNT[$name]}"
    local vg="${DRIVE_VG[$name]}"
    local lv="${DRIVE_LV[$name]}"

    local logdir="$HOME/.cache/luks-drive-manager"
    mkdir -p "$logdir"
    local logfile="$logdir/recovery-${name}.log"

    log_info "[$name] === recovery started ==="
    {
        echo ""
        echo "[START] $(date -Is) drive=$name uuid=$uuid"
    } >> "$logfile"

    local dev
    if ! dev="$(device_for_uuid "$uuid")"; then
        log_error "[$name] UUID $uuid not present on system"
        lsblk >> "$logfile"
        return 1
    fi
    log_info "[$name] device: $dev"
    echo "[INFO] device=$dev" >> "$logfile"

    log_info "[$name] checking LUKS header"
    if ! cryptsetup luksDump "$dev" >> "$logfile" 2>&1; then
        log_error "[$name] LUKS header invalid or unreadable"
        echo "[ERROR] luksDump failed" >> "$logfile"
        echo "Restore from header backup with:"
        echo "  sudo cryptsetup luksHeaderRestore $dev --header-backup-file <backup>.img"
        return 1
    fi
    log_info "[$name] LUKS header OK"

    if ! is_luks_open "$luks"; then
        log_info "[$name] opening LUKS"
        if ! cryptsetup open "$dev" "$luks" >> "$logfile" 2>&1; then
            log_error "[$name] cryptsetup open failed (see $logfile)"
            return 1
        fi
    else
        log_info "[$name] LUKS already open"
    fi

    if [[ -z "$vg" ]]; then
        log_info "[$name] no LVM configured — recovery complete (LUKS is open)"
        echo "[END] $(date -Is) no-lvm" >> "$logfile"
        return 0
    fi

    local luks_path="/dev/mapper/$luks"
    log_info "[$name] pvs $luks_path"
    pvs "$luks_path" >> "$logfile" 2>&1 || echo "[WARN] pvs failed on $luks_path" >> "$logfile"

    log_info "[$name] pvck on $luks_path"
    if ! pvck "$luks_path" >> "$logfile" 2>&1; then
        log_warn "[$name] pvck reported metadata issues (see $logfile)"
    else
        log_info "[$name] pvck: no metadata errors"
    fi

    log_info "[$name] scanning and activating VG $vg"
    pvscan --cache >> "$logfile" 2>&1
    if ! vgchange -ay "$vg" >> "$logfile" 2>&1; then
        log_error "[$name] failed to activate VG $vg"
        local backup_path="/etc/lvm/backup/$vg"
        if [[ -f "$backup_path" ]]; then
            log_warn "[$name] LVM metadata backup found at $backup_path"
            local restore
            read -r -p "[$name] attempt vgcfgrestore from backup? [y/N]: " restore
            if [[ "$restore" =~ ^[Yy]$ ]]; then
                if vgcfgrestore -f "$backup_path" "$vg" >> "$logfile" 2>&1 \
                   && vgchange -ay "$vg" >> "$logfile" 2>&1; then
                    log_info "[$name] VG $vg reactivated after restore"
                else
                    log_error "[$name] vgcfgrestore failed (see $logfile)"
                    return 1
                fi
            else
                log_warn "[$name] skipping metadata restore"
                return 1
            fi
        else
            log_error "[$name] no LVM metadata backup found — manual recovery needed"
            return 1
        fi
    else
        log_info "[$name] VG $vg activated"
    fi

    log_info "[$name] lvscan:"
    lvscan >> "$logfile" 2>&1

    local do_mount
    read -r -p "[$name] mount now? [y/N]: " do_mount
    if [[ "$do_mount" =~ ^[Yy]$ ]]; then
        mkdir -p "$mnt"
        if mount "/dev/mapper/${vg}-${lv}" "$mnt"; then
            log_info "[$name] ✓ mounted at $mnt"
        else
            log_error "[$name] mount failed — consider running fsck manually"
        fi
    else
        echo "To mount manually:"
        echo "  sudo mount /dev/mapper/${vg}-${lv} $mnt"
    fi

    log_info "[$name] === recovery complete ==="
    echo "[END] $(date -Is)" >> "$logfile"
}

cmd_backup() {
    local ts dest src
    ts="$(date +%Y%m%d-%H%M%S)"
    dest="$SELF_DIR/backup"
    mkdir -p "$dest"
    local copied=0
    for name in manage_drive.sh drives.conf; do
        src="$SELF_DIR/$name"
        if [[ -f "$src" ]]; then
            cp -p "$src" "$dest/${name}.${ts}.bak"
            log_info "backup: $src → $dest/${name}.${ts}.bak"
            copied=$((copied + 1))
        fi
    done
    (( copied > 0 )) || log_warn "nothing to back up (expected manage_drive.sh and/or drives.conf in $SELF_DIR)"
}

cmd_udev_trigger() {
    (( $# == 1 )) || die "udev-trigger requires exactly one UUID argument"
    local uuid="$1"
    local n
    for n in "${DRIVE_NAMES[@]}"; do
        if [[ "${DRIVE_UUID[$n]}" == "$uuid" && "${DRIVE_AUTO[$n]}" == "yes" ]]; then
            log_info "[udev] starting luks-drive-manager@${n}.service"
            systemctl start --no-block "luks-drive-manager@${n}.service"
            return 0
        fi
    done
}

show_help() {
    cat <<EOF
LUKS+LVM Multi-Drive Manager

Usage: $(basename "$0") [--config FILE] [--dry-run] COMMAND [DRIVE...]

Commands:
  mount [DRIVE...]    Open LUKS, activate LVM, and mount. No args = every drive
                      whose UUID is currently present. Skips already-mounted drives.
  unmount [DRIVE...]  Unmount, deactivate LVM, and close LUKS. No args = every
                      drive that is currently mounted or LUKS-open.
  status [DRIVE...]   Show status table. No args = all configured drives.
  cleanup [DRIVE...]  Remove broken /dev/mapper entries for the given drives.
  recover [DRIVE]     Interactive recovery (LUKS header, pvck, vgcfgrestore).
                      DRIVE required when more than one is configured.
  backup              Copy manage_drive.sh and drives.conf to ./backup/ with a
                      timestamped .bak suffix. Copies ONLY those two files.
  udev-trigger UUID   Internal: called by udev rule. Starts the auto-mount
                      service for the drive matching UUID, if auto_mount=yes.
  help                Show this message.

Options:
  --config FILE   Use FILE instead of the default search paths.
  --dry-run       Print commands without executing them. Equivalent to setting
                  MANAGE_DRIVE_DRY_RUN=1 in the environment.

Config search order (all sourced if present):
  <script dir>/drives.conf
  \$HOME/.luks-drives/drives.conf
  /etc/luks-drive-manager/drives.conf
  <script dir>/conf.d/*.conf
  \$HOME/.luks-drives/conf.d/*.conf
  /etc/luks-drive-manager/conf.d/*.conf

See drives.conf.example for the config format.
EOF
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --config)     [[ $# -ge 2 ]] || die "--config requires an argument"
                          CONFIG_OVERRIDE="$2"; shift 2 ;;
            --config=*)   CONFIG_OVERRIDE="${1#--config=}"; shift ;;
            --dry-run)    DRY_RUN=1; shift ;;
            -h|--help)    COMMAND="help"; shift ;;
            mount|unmount|status|cleanup|recover|backup|udev-trigger|help)
                          COMMAND="$1"; shift
                          while (( $# > 0 )) && [[ "$1" != --* ]]; do
                              POSITIONAL+=("$1"); shift
                          done ;;
            *)            die "unknown argument: $1 (try: $(basename "$0") help)" ;;
        esac
    done
    [[ -n "$COMMAND" ]] || COMMAND="help"
}

main() {
    parse_args "$@"

    if [[ "$COMMAND" == "help" ]]; then
        show_help
        exit 0
    fi

    load_config

    case "$COMMAND" in
        mount)         cmd_mount         "${POSITIONAL[@]}" ;;
        unmount)       cmd_unmount       "${POSITIONAL[@]}" ;;
        status)        cmd_status        "${POSITIONAL[@]}" ;;
        cleanup)       cmd_cleanup       "${POSITIONAL[@]}" ;;
        recover)       cmd_recover       "${POSITIONAL[@]}" ;;
        backup)        cmd_backup ;;
        udev-trigger)  cmd_udev_trigger  "${POSITIONAL[@]}" ;;
        *)             die "unknown command: $COMMAND" ;;
    esac
}

main "$@"
