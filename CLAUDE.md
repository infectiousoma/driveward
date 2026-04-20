# CLAUDE.md

Project-specific context for Claude working in this repo.

## What this project does

A Bash CLI (`manage_drive.sh`) that manages one or more LUKS-encrypted drives —
optionally with LVM on top — from one or many config files. It handles:

- `mount` / `unmount` / `status` for named drives
- `recover` (LUKS header + LVM metadata recovery, with optional `vgcfgrestore`)
- `cleanup` of stale `/dev/mapper` entries
- `backup` of the script and its config to `backup/`
- `udev-trigger` for udev-driven auto-mount via a systemd template unit

An installer (`setup.sh`) copies the script into the user's chosen `bin`
directory, installs the systemd unit and udev rule (rewriting paths to match
the chosen prefix), and creates `/etc/luks-drive-manager/`.

No runtime dependencies beyond a POSIX userland plus `cryptsetup`, `lvm2`,
`util-linux`, and (for auto-mount) `systemd` + `udev`.

## File layout

```
manage_drive.sh                           Main CLI. Bash, self-contained.
setup.sh                                  Installer / uninstaller.
drives.conf.example                       Annotated config template (tracked).
conf.d/                                   Multi-file configs (gitignored).
systemd/luks-drive-manager@.service       systemd template unit; %i = drive name.
udev/99-luks-drive-manager.rules          udev rule — calls `manage_drive.sh udev-trigger`.
backup/                                   Timestamped .bak copies of script + config.
README.md
CLAUDE.md
.gitignore                                Excludes drives.conf and conf.d/.
```

## Strict rule: `backup/` contents

**`backup/` must contain ONLY timestamped backups of `manage_drive.sh` and
`drives.conf`.** The `cmd_backup` function enforces this — it copies exactly
those two files, nothing else. Do not add runtime state, logs, or other files
to `backup/`. Recovery logs belong in `~/.cache/luks-drive-manager/`.

## Config format

Config files are Bash fragments that call `add_drive` with `key=value` args:

```bash
add_drive \
    name=disk1 \
    uuid=<LUKS-UUID> \
    mount_point=/media/dave/disk1 \
    vg_name=my_vg \
    lv_name=my_lv \
    auto_mount=yes
```

Keys: `name`, `uuid`, `mount_point` (required); `luks_name` (defaults to
`luks-<name>`), `vg_name`, `lv_name` (must be set together or not at all),
`auto_mount` (`yes`|`no`, default `no`).

Two layouts are supported — users pick whichever fits:

- **Single file**: one `drives.conf` containing many `add_drive` calls.
- **Multi-file**: one drive per file in a `conf.d/` directory (e.g.
  `drive1.conf`, `backup_ssd.conf`).

The script sources everything it finds. Duplicate `name=` values error at load
time.

Search path (all sourced if present):

```
<script dir>/drives.conf              (co-located with manage_drive.sh)
$HOME/.luks-drives/drives.conf
/etc/luks-drive-manager/drives.conf
<script dir>/conf.d/*.conf
$HOME/.luks-drives/conf.d/*.conf
/etc/luks-drive-manager/conf.d/*.conf
```

Per-user configs live in `~/.luks-drives/`. System-wide configs (used by the
systemd service under root) live in `/etc/luks-drive-manager/`. `--config FILE`
bypasses the search path entirely.

## Command interface

```
manage_drive.sh [--config FILE] [--dry-run] COMMAND [DRIVE...]

  mount [DRIVE...]     No args = every drive whose UUID is currently present.
  unmount [DRIVE...]   No args = every drive that is mounted or LUKS-open.
  status [DRIVE...]    Tabular status. No args = all drives.
  cleanup [DRIVE...]   Remove broken /dev/mapper entries.
  recover [DRIVE]      Interactive LUKS+LVM recovery. DRIVE required when >1 drive.
  backup               Copy manage_drive.sh and drives.conf to ./backup/.
  udev-trigger UUID    Internal: dispatch for the udev rule.
  help
```

Root is required for `mount`, `unmount`, `cleanup`, `recover`.

## Installer (`setup.sh`)

```
sudo ./setup.sh                       # interactive
sudo ./setup.sh --prefix /usr/bin --yes
sudo ./setup.sh --no-systemd --no-udev
sudo ./setup.sh --uninstall
```

- Installs `manage_drive.sh` to the chosen prefix (default `/usr/local/bin`).
  Also symlinks `manage-drive` → `manage_drive.sh` for shorter invocation.
- Rewrites the `ExecStart`/`ExecStop` paths in the systemd service and the
  `RUN+=` path in the udev rule to match the chosen prefix, then installs them
  to `/etc/systemd/system/` and `/etc/udev/rules.d/`.
- Creates `/etc/luks-drive-manager/` and `/etc/luks-drive-manager/conf.d/`,
  and drops `drives.conf.example` into the former.
- Reloads systemd and udev.
- `--uninstall` removes everything it installed but preserves
  `/etc/luks-drive-manager/` so user configs aren't lost.

## Coding conventions

- `#!/usr/bin/env bash` + `set -euo pipefail` at the top of both scripts.
- Logging helpers: `log_info`, `log_warn`, `log_error`, `die`. Colour only when
  stdout is a TTY (`[[ -t 1 ]]`).
- All privileged commands in `manage_drive.sh` go through `run_cmd`, which
  respects `MANAGE_DRIVE_DRY_RUN=1` / `--dry-run`.
- Root-requiring commands call `require_root` at the top, not inline `sudo`.
- Drive metadata lives in six parallel associative arrays keyed by drive name
  (`DRIVE_UUID`, `DRIVE_LUKS`, `DRIVE_MOUNT`, `DRIVE_VG`, `DRIVE_LV`,
  `DRIVE_AUTO`) plus `DRIVE_NAMES` for iteration order.
- Per-drive operations live in `mount_one`, `unmount_one`, `status_row`. The
  `cmd_*` functions iterate over names and call them.
- Device discovery uses `/dev/disk/by-uuid/<UUID>` + `readlink -f`, never
  `blkid | grep`.
- All `add_drive` inputs are validated at config-load time (required keys,
  duplicate names, VG/LV consistency, `auto_mount` value).
- Prefer `printf` over `echo -e` for anything with escapes.

## systemd / udev notes

- The service is a **template** (`@.service`); instance name = drive `name=`
  from the config, e.g. `luks-drive-manager@disk1`.
- Type is `oneshot` with `RemainAfterExit=yes` so `systemctl status` reflects
  the mounted state after `ExecStart` completes.
- The service file in `systemd/` hard-codes `/usr/local/bin/manage_drive.sh`
  as the default; `setup.sh` rewrites this to whatever `--prefix` was chosen
  before installing to `/etc/systemd/system/`.
- The udev rule matches `ID_FS_TYPE=="crypto_LUKS"` and calls
  `manage_drive.sh udev-trigger <UUID>`, which only acts when the UUID resolves
  to a drive with `auto_mount=yes`. Non-auto-mount drives are ignored.
- `udev-trigger` uses `systemctl start --no-block` so the udev event returns
  quickly.
- The rule covers **attach** only. Removal / unmount is always manual, by
  design.

## When editing

- Keep both scripts pure Bash; no Python or other interpreters at runtime.
- Don't reintroduce `DRIVE_UUID`, `VG_NAME`, `LV_NAME`, `MOUNT_POINT`,
  `LUKS_NAME` as bare globals — those were the legacy single-drive shape.
- Don't write to `backup/` from anywhere except `cmd_backup`.
- `drives.conf` and `conf.d/*.conf` are user data — never overwrite them.
  Edits go to `drives.conf.example` and let the user copy.
- If you change the service or udev rule's default path, keep `setup.sh`'s
  `sed` rewrites in sync — they assume the default is `/usr/local/bin`.
