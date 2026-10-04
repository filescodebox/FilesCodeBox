# FilesCodeBox

**Anonymous code-based file & text sharing — like picking up a parcel.** Upload, get a pickup code, share the code; the recipient enters the code and downloads. No registration required.

FilesCodeBox is the Go multirepo workspace of the [filescodebox](https://github.com/orgs/filescodebox/repositories) organization. This repository is the **umbrella (hub)**: no business code, only tooling to assemble the module repos into a buildable workspace.

## Repositories

| Repo | Role | Version |
|------|------|---------|
| [contracts](https://github.com/filescodebox/contracts) | Contract layer: error codes + Thrift-generated types (zero business deps) | v0.2.1 |
| [core](https://github.com/filescodebox/core) | Business core library: 11 domain services + repo/storage + `bootstrap.Bootstrap()` | v0.8.0 |
| [server](https://github.com/filescodebox/server) | Deployable app: thin main + configs + Dockerfile (pure backend since 0.9.0) | v0.10.0 |
| [frontend](https://github.com/filescodebox/frontend) | Vue3 + TS + Vite + Element Plus (nginx image, released with server) | with server `v*` |
| [desktop](https://github.com/filescodebox/desktop) | Desktop client: Tauri 2 tray app connecting to any FilesCodeBox server | desktop-v1.2.0 |
| [fnos](https://github.com/filescodebox/fnos) | fnOS (fnNAS) adapter (optional) | v1.2.0 |
| [p2p](https://github.com/filescodebox/p2p) | P2P federated registry: node leases + passcode federation routing (optional) | v0.1.0 |
| [kit](https://github.com/filescodebox/kit) | Shared Go toolkit: 20 general-purpose packages with zero ecosystem deps | v0.1.0 |
| [charts](https://github.com/filescodebox/charts) | Kubernetes Helm chart (frontend + server split deployments) | chart 1.3.5 |

Dependency direction (CI-enforced): `server / fnos / frontend ──► core ──► contracts`; `p2p` and `kit` are leaf repos with zero ecosystem deps

## Highlights

- **Share text or files anonymously** with pickup codes, expiry by time and/or download count, optional access password (bcrypt).
- **Chunked uploads** with resume + instant upload (SHA-256 dedup) + presigned direct upload.
- **Storage backends**: local disk, S3-compatible (AWS/MinIO/OSS/COS/B2…), WebDAV, FTP/FTPS, SFTP, GCS, Azure Blob, HDFS, OneDrive — hot-switchable at runtime, persisted across restarts.
- **Admin console**: dashboard, file/user management, audit log, site config persisted in DB, transfer logs.
- **User system**: quotas, API keys, notifications (in-app + webhook).
- **Ops-ready**: Prometheus metrics, OpenTelemetry tracing (opt-in), health checks, Helm chart with ServiceMonitor, multi-arch images.
- Light by design: a parcel locker, not a cloud drive.

## Quick start

```bash
docker compose up -d          # or: BUILD=1 make compose-up (local build, run make setup first)
```

Frontend entry `http://localhost:12345` (`FCB_API_PORT`, default 12345) — the frontend image also proxies the API, the server publishes no ports. `FCB_HTTP_PORT` (default 80) only applies to the optional nginx profile. Default admin is `admin / admin123` — override with `FCB_ADMIN_PASSWORD` in production.

Build from source:

```bash
git clone https://github.com/filescodebox/filescodebox.git && cd filescodebox
make setup     # fetch module repos (idempotent)
make test      # Go tests + frontend typecheck
make build     # workspace build → bin/
make smoke     # boot server & smoke-test
```

## Documentation

- Architecture (Mermaid): [docs/architecture.md](docs/architecture.md)
- Roadmap: [ROADMAP.md](ROADMAP.md) · Changelog: [CHANGELOG.md](CHANGELOG.md)
- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md) · Security policy: [SECURITY.md](SECURITY.md)
- Environment variables: [docs/ENVIRONMENT_VARIABLES.md](docs/ENVIRONMENT_VARIABLES.md)

## License

[Apache-2.0](LICENSE) © FilesCodeBox
