# JZZN Sniff GitHub Online Updater

## 2026-11-09: preserve networking and SSH during dependency installation

Every APT/dpkg command suspends needrestart and uses a temporary policy-rc.d plus runtime RefuseManualStop protection for network/SSH services. Existing administrator policies are preserved and restored on success, failure or handled signals. Network files and live addresses are backed up before the first package command. Hosts without recognizable persistent network configuration stop before APT; restore valid configuration from the console first. IPv4 fallback remains enabled. Product service restarts required by an update are unaffected; no network/SSH restart is requested by the updater.

When missing runtime dependencies require APT, the entry checks for both a global IPv6 address and an IPv6 default route. If IPv6 is unavailable, only those APT commands automatically use `Acquire::ForceIPv4=true`.

Compatibility entry point:

```bash
curl -fsSL https://raw.githubusercontent.com/JzCharizard/jz_online_update/main/jz_online_updater_github.sh | sudo bash
```

Current product release: `v1.2.14`.

Release assets:

- `jzzn-v1.2.13-update-linux-x86_64.7z`
- `jzzn-v1.2.13-update-linux-x86_64.7z.sha256`
- `jzzn-v1.2.13-update-linux-x86_64.7z.sig`

Package size: `18421713` bytes.

```text
SHA-256: 9c1b069c032306a98c13288e619bc21b99d8c934a4695966ff971bab1e13a7a5
Public-key fingerprint: eda973d767d633f54fc31d892bdd7dacc8fdb64de160f0e349e953f93fb7376e
```

The entry script verifies the platform, minimum runtime dependencies, outer hash, RSA-SHA256 signature, archive paths, inner hashes, and upgrade precheck. It then uses only `/etc/init.d/sniff` to identify a legacy deployment. If present, it stops legacy processes, removes legacy core files, SysV links, and `rc.local` startup commands, then runs the packaged `install.sh`; otherwise it runs the packaged `install.sh` directly. The packaged installer handles database migration, least-privilege `sdwan` access, local-socket SCRAM verification, file deployment, and systemd acceptance. Completion checks the current active state of the core services without a fixed 120-second observation gate and without Controller HTTP, port 8082, heartbeat, command-line, JAR-name, PID, or restart-count heuristics. The transaction backup exists only for failure recovery during this run; success removes the old program/configuration copies and database dump, while failure retains the evidence.

All GitHub user-facing messages are in English. The GitHub, Gitee, and offline deliveries use the same update archive, checksum, and signature bytes.
