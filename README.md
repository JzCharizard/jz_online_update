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

Package size: `18423841` bytes.

```text
SHA-256: c3192797318d53435f611e717444141b3c8ccd62b92d03133135ae0bf5e5adc4
Public-key fingerprint: eda973d767d633f54fc31d892bdd7dacc8fdb64de160f0e349e953f93fb7376e
```

The entry script verifies the platform, minimum runtime dependencies, outer hash, RSA-SHA256 signature, archive paths, inner hashes, and upgrade precheck before stopping services. The transactional installer then creates a verified backup, switches staged files, repairs and verifies least-privilege `sdwan` runtime access, verifies local-socket SCRAM login without `-h`, and checks the database, deployed hashes, and runtime configuration. Readiness and the 120-second observation window require only the three core systemd units to remain active; acceptance does not use Controller HTTP, port 8082, heartbeat, process command line, JAR name, PID, or restart count. After a successful legacy upgrade it removes old core files, SysV links, and `rc.local` startup commands. A failed deployment triggers one automatic rollback attempt.

All GitHub user-facing messages are in English. The GitHub, Gitee, and offline deliveries use the same update archive, checksum, and signature bytes.
