# LUKS+LVM Multi-Drive Manager

A small Bash tool for opening, mounting, unmounting, and recovering LUKS-encrypted
drives — with or without LVM on top — across any number of drives defined in a
config file. Optional systemd + udev integration handles auto-mount on attach.

## Repo layout

```
manage_drive.sh                 The CLI tool.
setup.sh                        Installer (copies script, systemd unit, udev rule).
drives.conf.example             Annotated config template (tracked).
conf.d/                         Multi-file configs (gitignored; your drives live here).
systemd/
  luks-drive-manager@.service   systemd template unit — mounts one named drive.
udev/
  99-luks-drive-manager.rules   udev rule that triggers the service on attach.
backup/                         Timestamped copies made by `manage_drive.sh backup`.
README.md
CLAUDE.md
```

## Install

Run the installer as root. It copies `manage_drive.sh` into a system `bin`
directory, installs the systemd unit and udev rule (with paths rewritten to
match your chosen prefix), and creates `/etc/luks-drive-manager/` plus
`/etc/luks-drive-manager/conf.d/`.

```bash
sudo ./setup.sh
```

Interactive prompts let you choose between `/usr/local/bin`, `/usr/bin`, `/bin`,
or a custom path. Non-interactive:

```bash
sudo ./setup.sh --prefix /usr/local/bin --yes
sudo ./setup.sh --prefix /usr/bin --no-udev      # skip udev integration
sudo ./setup.sh --uninstall                       # remove everything, keep configs
```

The installer also drops `drives.conf.example` into `/etc/luks-drive-manager/`
for reference.

## Config: single file OR multi-file

You can use either layout — the script sources all it finds.

### Single file

One config with many drives inside it:

```bash
# ~/.luks-drives/drives.conf  (or /etc/luks-drive-manager/drives.conf)

add_drive name=disk1 \
    uuid=f0df5c91-de1c-42a3-8d16-65ca4304e3a6 \
    mount_point=/media/dave/disk1 \
    vg_name=my_vg lv_name=my_lv auto_mount=yes

add_drive name=backup_ssd \
    uuid=11111111-2222-3333-4444-555555555555 \
    mount_point=/mnt/backup
```

### Multi-file (conf.d/)

One drive per file — useful for syncing a subset across machines, or dropping
configs in from package management:

```
~/.luks-drives/conf.d/
  drive1.conf
  backup_ssd.conf
  photos.conf
```

### Config search path

All of these are sourced if present (later ones override earlier ones only if
they re-declare something, which `add_drive` errors on):

```
<script dir>/drives.conf          (co-located with manage_drive.sh)
$HOME/.luks-drives/drives.conf
/etc/luks-drive-manager/drives.conf
<script dir>/conf.d/*.conf
$HOME/.luks-drives/conf.d/*.conf
/etc/luks-drive-manager/conf.d/*.conf
```

Use `--config FILE` to bypass the search path entirely and load one specific
file. For per-user setups, drop configs in `~/.luks-drives/` (create the dir if
it doesn't exist). For system-wide / systemd use, put them in
`/etc/luks-drive-manager/`.

## Config keys

```bash
add_drive \
    name=disk1 \
    uuid=f0df5c91-de1c-42a3-8d16-65ca4304e3a6 \
    mount_point=/media/dave/disk1 \
    luks_name=luks-disk1 \
    vg_name=my_vg \
    lv_name=my_lv \
    auto_mount=yes
```

| Key            | Required | Description                                                   |
|----------------|----------|---------------------------------------------------------------|
| `name`         | yes      | CLI handle (e.g. `disk1`).                                    |
| `uuid`         | yes      | LUKS partition UUID.                                          |
| `mount_point`  | yes      | Absolute path where the filesystem is mounted.                |
| `luks_name`    | no       | `/dev/mapper` name. Defaults to `luks-<name>`.                |
| `vg_name`      | no       | LVM VG name. Omit for plain LUKS without LVM.                 |
| `lv_name`      | no       | LVM LV name. Required if `vg_name` is set.                    |
| `auto_mount`   | no       | `yes` or `no`. Default `no`. Used by the udev rule.           |

## Commands

```bash
manage-drive mount                  # mount every drive whose UUID is present
manage-drive mount disk1            # mount one drive
manage-drive mount disk1 disk2      # mount several
manage-drive unmount                # unmount every currently-mounted managed drive
manage-drive unmount disk1
manage-drive status                 # tabular status of all drives
manage-drive status disk1
manage-drive cleanup                # remove broken /dev/mapper entries
manage-drive recover disk1          # interactive recovery (pvck, vgcfgrestore)
manage-drive backup                 # copy script + drives.conf to ./backup/*.bak
manage-drive help
```

`mount`, `unmount`, `cleanup`, and `recover` require root.

### Options

- `--config FILE` — use a specific config file instead of the default search paths.
- `--dry-run` — print commands without running them. Same as `MANAGE_DRIVE_DRY_RUN=1`.

## systemd + udev auto-mount

`setup.sh` installs the template unit and the udev rule for you and rewrites
paths to match your install prefix. To do it manually:

```bash
sudo install -m 0644 systemd/luks-drive-manager@.service /etc/systemd/system/
sudo install -m 0644 udev/99-luks-drive-manager.rules /etc/udev/rules.d/
sudo systemctl daemon-reload
sudo udevadm control --reload
```

Start a named drive:

```bash
sudo systemctl start luks-drive-manager@disk1
```

With `auto_mount=yes` in a drive's config, attaching it triggers the udev rule,
which calls `manage-drive udev-trigger <UUID>`. That dispatcher looks up the
UUID in the config and, only if `auto_mount=yes`, starts
`luks-drive-manager@<name>.service`. Drives with `auto_mount=no` are ignored
by udev and mounted manually.

Unplugging is **not** automated. Always unmount first:

```bash
sudo manage-drive unmount disk1
```

## Backups

```bash
manage-drive backup
```

Creates `backup/manage_drive.sh.YYYYmmdd-HHMMSS.bak` and
`backup/drives.conf.YYYYmmdd-HHMMSS.bak`. By design, only these two files are
ever written to `backup/`.

## Recovery

`recover <name>` walks through header checks, `pvck`, and offers an automatic
`vgcfgrestore` from `/etc/lvm/backup/<vg>` if VG activation fails. A per-drive
log is appended to `~/.cache/luks-drive-manager/recovery-<name>.log`.
