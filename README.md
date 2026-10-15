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

Package size: `18422593` bytes.

```text
SHA-256: 29c506b75a4923294772d5e8f17deaef047db8f7d5aedb6ca2a8eb8a9683e7bd
Public-key fingerprint: eda973d767d633f54fc31d892bdd7dacc8fdb64de160f0e349e953f93fb7376e
```

The entry script verifies the platform, minimum runtime dependencies, outer hash, RSA-SHA256 signature, archive paths, inner hashes, and upgrade precheck before stopping services. The transactional installer then creates a verified backup, switches staged files, checks the real Controller HTTP endpoint, database, heartbeat, deployed hashes and runtime configuration, and enforces a 120-second stability gate. A failed deployment triggers one automatic rollback attempt.

All GitHub user-facing messages are in English. The GitHub, Gitee, and offline deliveries use the same update archive, checksum, and signature bytes.
