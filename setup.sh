#!/usr/bin/env bash
# LUKS+LVM Multi-Drive Manager — installer
set -euo pipefail

SELF_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

SCRIPT_SRC="$SELF_DIR/manage_drive.sh"
SERVICE_SRC="$SELF_DIR/systemd/luks-drive-manager@.service"
UDEV_SRC="$SELF_DIR/udev/99-luks-drive-manager.rules"
EXAMPLE_SRC="$SELF_DIR/drives.conf.example"

SERVICE_DEST="/etc/systemd/system/luks-drive-manager@.service"
UDEV_DEST="/etc/udev/rules.d/99-luks-drive-manager.rules"
CONFIG_DIR="/etc/luks-drive-manager"

BIN_PREFIX=""
DO_SYSTEMD=1
DO_UDEV=1
DO_UNINSTALL=0
ASSUME_YES=0

if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[1;33m'; C_NC=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YLW=''; C_NC=''
fi

log_info()  { printf '%s[INFO]%s  %s\n'  "$C_GRN" "$C_NC" "$*"; }
log_warn()  { printf '%s[WARN]%s  %s\n'  "$C_YLW" "$C_NC" "$*" >&2; }
log_error() { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_NC" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

usage() {
    cat <<EOF
LUKS+LVM Multi-Drive Manager — installer

Usage: sudo $0 [OPTIONS]

Options:
  --prefix DIR    Install manage_drive.sh into DIR (skip interactive prompt).
                  Common values: /usr/local/bin, /usr/bin, /bin
  --no-systemd    Skip installing the systemd service.
  --no-udev       Skip installing the udev rule.
  --uninstall     Remove installed files. Preserves $CONFIG_DIR.
  --yes, -y       Assume yes for all prompts.
  --help, -h      Show this help.

Defaults to interactive mode when no options are passed.
EOF
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --prefix)     [[ $# -ge 2 ]] || die "--prefix requires an argument"
                          BIN_PREFIX="$2"; shift 2 ;;
            --prefix=*)   BIN_PREFIX="${1#--prefix=}"; shift ;;
            --no-systemd) DO_SYSTEMD=0; shift ;;
            --no-udev)    DO_UDEV=0; shift ;;
            --uninstall)  DO_UNINSTALL=1; shift ;;
            --yes|-y)     ASSUME_YES=1; shift ;;
            --help|-h)    usage; exit 0 ;;
            *)            die "unknown argument: $1 (try: $0 --help)" ;;
        esac
    done
}

require_root() {
    [[ $EUID -eq 0 ]] || die "this installer must run as root (re-run with sudo)"
}

confirm() {
    local prompt="$1" reply
    (( ASSUME_YES == 1 )) && return 0
    read -r -p "$prompt [y/N]: " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

prompt_prefix() {
    if [[ -n "$BIN_PREFIX" ]]; then
        return
    fi
    echo "Where should manage_drive.sh be installed?"
    echo "  1) /usr/local/bin  (recommended for locally-installed software)"
    echo "  2) /usr/bin"
    echo "  3) /bin"
    echo "  4) custom path"
    local choice
    while :; do
        read -r -p "Choice [1]: " choice
        choice="${choice:-1}"
        case "$choice" in
            1) BIN_PREFIX="/usr/local/bin"; break ;;
            2) BIN_PREFIX="/usr/bin"; break ;;
            3) BIN_PREFIX="/bin"; break ;;
            4) read -r -p "Enter absolute path: " BIN_PREFIX
               [[ "$BIN_PREFIX" == /* ]] && break
               log_warn "path must be absolute" ;;
            *) log_warn "invalid choice" ;;
        esac
    done
}

install_script() {
    [[ -f "$SCRIPT_SRC" ]] || die "missing $SCRIPT_SRC"
    local dest="$BIN_PREFIX/manage_drive.sh"
    install -d -m 0755 "$BIN_PREFIX"
    install -m 0755 "$SCRIPT_SRC" "$dest"
    log_info "installed $dest"
    # Short alias for convenience
    ln -sf manage_drive.sh "$BIN_PREFIX/manage-drive"
    log_info "symlink:   $BIN_PREFIX/manage-drive -> manage_drive.sh"
}

install_systemd() {
    [[ -f "$SERVICE_SRC" ]] || die "missing $SERVICE_SRC"
    local tmp
    tmp="$(mktemp)"
    sed -E \
        -e "s|^(ExecStart=).*/manage_drive\.sh(.*)$|\1${BIN_PREFIX}/manage_drive.sh\2|" \
        -e "s|^(ExecStop=).*/manage_drive\.sh(.*)$|\1${BIN_PREFIX}/manage_drive.sh\2|" \
        "$SERVICE_SRC" > "$tmp"
    install -d -m 0755 "$(dirname "$SERVICE_DEST")"
    install -m 0644 "$tmp" "$SERVICE_DEST"
    rm -f "$tmp"
    log_info "installed $SERVICE_DEST (ExecStart → $BIN_PREFIX/manage_drive.sh)"
    systemctl daemon-reload
    log_info "systemctl daemon-reload done"
}

install_udev() {
    [[ -f "$UDEV_SRC" ]] || die "missing $UDEV_SRC"
    local tmp
    tmp="$(mktemp)"
    sed -E "s|/usr/local/bin/manage_drive\.sh|${BIN_PREFIX}/manage_drive.sh|g" \
        "$UDEV_SRC" > "$tmp"
    install -d -m 0755 "$(dirname "$UDEV_DEST")"
    install -m 0644 "$tmp" "$UDEV_DEST"
    rm -f "$tmp"
    log_info "installed $UDEV_DEST (RUN → $BIN_PREFIX/manage_drive.sh)"
    udevadm control --reload
    log_info "udevadm control --reload done"
}

install_config_dir() {
    install -d -m 0755 "$CONFIG_DIR" "$CONFIG_DIR/conf.d"
    log_info "config dir: $CONFIG_DIR (with conf.d/)"
    if [[ -f "$EXAMPLE_SRC" && ! -f "$CONFIG_DIR/drives.conf.example" ]]; then
        install -m 0644 "$EXAMPLE_SRC" "$CONFIG_DIR/drives.conf.example"
        log_info "copied example to $CONFIG_DIR/drives.conf.example"
    fi
}

do_install() {
    require_root
    prompt_prefix

    echo
    echo "=== Install plan ==="
    echo "  script          -> $BIN_PREFIX/manage_drive.sh"
    echo "  alias           -> $BIN_PREFIX/manage-drive"
    (( DO_SYSTEMD == 1 )) && echo "  systemd service -> $SERVICE_DEST"
    (( DO_UDEV == 1 ))    && echo "  udev rule       -> $UDEV_DEST"
    echo "  config dir      -> $CONFIG_DIR/ (and $CONFIG_DIR/conf.d/)"
    echo

    confirm "Proceed?" || die "aborted"

    install_script
    install_config_dir
    (( DO_SYSTEMD == 1 )) && install_systemd
    (( DO_UDEV == 1 ))    && install_udev

    echo
    log_info "done."
    cat <<EOF

Next steps:
  1. Create your drive config:
       sudo cp $CONFIG_DIR/drives.conf.example $CONFIG_DIR/conf.d/drive1.conf
       sudo \$EDITOR $CONFIG_DIR/conf.d/drive1.conf
  2. Check status:
       manage-drive status
  3. Mount a drive:
       sudo manage-drive mount drive1
  4. (Optional) Enable auto-mount on attach:
       - Set auto_mount=yes in the drive's config entry.
       - Enable the instanced service so it survives reboots:
           sudo systemctl enable luks-drive-manager@drive1.service

EOF
}

do_uninstall() {
    require_root
    # Discover where the script was installed. Try common paths and the
    # current PATH lookup, but also accept --prefix for a non-standard location.
    local candidates=()
    [[ -n "$BIN_PREFIX" ]] && candidates+=("$BIN_PREFIX/manage_drive.sh")
    candidates+=(
        "/usr/local/bin/manage_drive.sh"
        "/usr/bin/manage_drive.sh"
        "/bin/manage_drive.sh"
    )

    echo "=== Uninstall plan ==="
    local found_any=0 c
    for c in "${candidates[@]}"; do
        if [[ -f "$c" ]]; then
            echo "  remove $c"
            local dir
            dir="$(dirname "$c")"
            [[ -L "$dir/manage-drive" ]] && echo "  remove $dir/manage-drive"
            found_any=1
        fi
    done
    [[ -f "$SERVICE_DEST" ]] && echo "  remove $SERVICE_DEST"
    [[ -f "$UDEV_DEST" ]]    && echo "  remove $UDEV_DEST"
    echo "  keep   $CONFIG_DIR/ (your configs are safe)"
    echo

    (( found_any == 1 )) || log_warn "script not found at any known location"

    confirm "Proceed?" || die "aborted"

    for c in "${candidates[@]}"; do
        if [[ -f "$c" ]]; then
            local dir
            dir="$(dirname "$c")"
            rm -f "$c"
            log_info "removed $c"
            if [[ -L "$dir/manage-drive" ]]; then
                rm -f "$dir/manage-drive"
                log_info "removed $dir/manage-drive"
            fi
        fi
    done

    if [[ -f "$SERVICE_DEST" ]]; then
        rm -f "$SERVICE_DEST"
        systemctl daemon-reload
        log_info "removed $SERVICE_DEST and reloaded systemd"
    fi
    if [[ -f "$UDEV_DEST" ]]; then
        rm -f "$UDEV_DEST"
        udevadm control --reload
        log_info "removed $UDEV_DEST and reloaded udev"
    fi

    log_info "uninstall complete. $CONFIG_DIR/ was preserved."
}

main() {
    parse_args "$@"
    if (( DO_UNINSTALL == 1 )); then
        do_uninstall
    else
        do_install
    fi
}

main "$@"
