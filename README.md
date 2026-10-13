# JZZN Sniff GitHub Online Updater

This repository provides the GitHub online-update entry point for JZZN Sniff. The product and online release versions are both **v1.2.9**.

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/JzCharizard/jz_online_update/main/jz_online_updater_github.sh | sudo bash
```

The updater performs the following steps:

1. Checks and installs runtime dependencies when necessary.
2. Downloads the encrypted update package from the GitHub Release.
3. Verifies the package SHA256.
4. Prompts for the package password and extracts the package.
5. Backs up the database and legacy files, then upgrades to v1.2.9.
6. Migrates to systemd and removes legacy SysV/`rc.local` startup entries only after validation succeeds.

Failed updates retain the temporary directory. The audit log is stored at `/var/log/jzzn-install.log`, and system/database backups are stored under `/root/jzzn-upgrade-backup/`.

## Options

- `--keep`: Retain the temporary download directory after a successful update.
- `JZ_PASS`: Supply the update-package password non-interactively through an environment variable; interactive entry is recommended for normal field use.

This release no longer uses the legacy `file_manifest.json` incremental-overlay workflow.
