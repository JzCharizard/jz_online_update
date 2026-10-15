# JZZN Sniff GitHub Online Updater

Compatibility entry point:

```bash
curl -fsSL https://raw.githubusercontent.com/JzCharizard/jz_online_update/main/jz_online_updater_github.sh | sudo bash
```

Current product release: `v1.2.12`.

Release assets:

- `jzzn-v1.2.12-update-linux-x86_64.7z`
- `jzzn-v1.2.12-update-linux-x86_64.7z.sha256`
- `jzzn-v1.2.12-update-linux-x86_64.7z.sig`

Package size: `18423361` bytes.

```text
SHA-256: d48bb0717612533231cc070fed45e8969820275a088f8f8e48dae3d315a933e1
Public-key fingerprint: eda973d767d633f54fc31d892bdd7dacc8fdb64de160f0e349e953f93fb7376e
```

The entry script verifies the platform, minimum runtime dependencies, outer hash, RSA-SHA256 signature, archive paths, inner hashes, and upgrade precheck. It then uses only `/etc/init.d/sniff` to identify a legacy deployment. If present, it stops legacy processes, removes legacy core files, SysV links, and `rc.local` startup commands, then runs the packaged `install.sh`; otherwise it runs the packaged `install.sh` directly. The packaged installer handles database migration, least-privilege `sdwan` access, local-socket SCRAM verification, file deployment, and systemd acceptance. Completion checks the current active state of the core services without a fixed 120-second observation gate and without Controller HTTP, port 8082, heartbeat, command-line, JAR-name, PID, or restart-count heuristics.

All GitHub user-facing messages are in English. The GitHub, Gitee, and offline deliveries use the same update archive, checksum, and signature bytes.
