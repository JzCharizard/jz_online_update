# JZZN Sniff GitHub Online Updater

This repository provides the GitHub online-update entry point for JZZN Sniff. The product and online release versions are both **v1.2.12**.

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/JzCharizard/jz_online_update/main/jz_online_updater_github.sh | sudo bash
```

The updater performs the following steps:

1. Checks and installs runtime dependencies when necessary.
2. Downloads the encrypted update package from the GitHub Release.
3. Verifies the package SHA256.
4. Prompts for the package password and extracts the package.
5. Backs up the database and legacy files, then upgrades to v1.2.12.
6. Migrates to systemd and removes legacy SysV/`rc.local` startup entries only after validation succeeds.

Filesystem and database backups are created under `/root/jzzn-upgrade-backup/` during the upgrade. After every acceptance check passes, that directory and all historical upgrade backups are deleted. Failed updates retain their backups and temporary directory. The audit log is stored at `/var/log/jzzn-install.log`.

## Options

- `--keep`: Retain the temporary download directory after a successful update.
- `JZ_PASS`: Supply the update-package password non-interactively through an environment variable; interactive entry is recommended for normal field use.

This release no longer uses the legacy `file_manifest.json` incremental-overlay workflow.

The v1.2.12 archive includes `precheck.sh` and `CHANGELOG.md`. After extracting the archive, run `sudo bash precheck.sh` when field validation of CID, licensing, retention capacity, and interface state is required.
