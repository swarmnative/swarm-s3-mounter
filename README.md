English | [简体中文](README.zh.md)

# swarm-s3-mounter

![CI](https://img.shields.io/github/actions/workflow/status/swarmnative/swarm-s3-mounter/publish.yml?branch=main)
![Release](https://img.shields.io/github/v/release/swarmnative/swarm-s3-mounter)
![License](https://img.shields.io/github/license/swarmnative/swarm-s3-mounter)
![Docker Pulls](https://img.shields.io/docker/pulls/swarmnative/swarm-s3-mounter)
![Image Size](https://img.shields.io/docker/image-size/swarmnative/swarm-s3-mounter/latest)
![Go Version](https://img.shields.io/github/go-mod/go-version/swarmnative/swarm-s3-mounter)
[![Go Report Card](https://goreportcard.com/badge/github.com/swarmnative/swarm-s3-mounter)](https://goreportcard.com/report/github.com/swarmnative/swarm-s3-mounter)
![Last Commit](https://img.shields.io/github/last-commit/swarmnative/swarm-s3-mounter)
![Issues](https://img.shields.io/github/issues/swarmnative/swarm-s3-mounter)
![PRs](https://img.shields.io/github/issues-pr/swarmnative/swarm-s3-mounter)

Lightweight controller that provides S3-compatible object storage mounts on Docker Swarm nodes:
- Host-level rclone FUSE mount (application containers use it via bind).
- Optional in-cluster HAProxy for LB and failover.
- Declarative "volumes" (prefix provisioning) with a K8s-like experience.

---

## Features
- Host mount & self-healing:
  - Creates and watches `/mnt/s3` (rshared) on nodes labeled `node.labels.mount_s3=true`.
  - Lazy unmount/recreate on failures; optional lazy unmount on container exit.
- Load balancing:
  - HAProxy with leastconn, keep-alive, http-reuse safe, health checks, and slowstart.
  - Supports multiple backend services (comma-separated), dynamic discovery via Swarm tasks DNS.
  - Node-local LB mode exports a unique alias `swarm-s3-mounter-lb-<hostname>` so mounter talks to the local proxy.
- Declarative "volumes":
  - Use `service.labels` to declare bucket/prefix/class/reclaim/access; the controller idempotently creates local prefix dirs and optional remote bucket/prefix.
- Versioning & updates:
  - Ships with a default rclone version; can be overridden at runtime.
  - rclone update strategies: `never`/`periodic`/`on_change` (default `never`).
  - CI/nightly only publishes when dependencies change.

---

## Quick Start (minimal stack)
Prereqs: Swarm initialized; FUSE enabled; label nodes that should mount.
```bash
docker node update --label-add mount_s3=true <NODE>
```
Create credentials (Swarm secrets):
```bash
docker secret create s3_access_key -
# paste AccessKey then Ctrl-D

docker secret create s3_secret_key -
# paste SecretKey then Ctrl-D
```
Deploy (single backend service, mounter reaches `tasks.minio:9000` via built-in HAProxy):
```yaml
version: "3.8"

networks:
  s3_net:
    driver: overlay
    internal: true

secrets:
  s3_access_key:
    external: true
  s3_secret_key:
    external: true

services:
  minio:
    image: minio/minio:latest
    command: server --console-address :9001 /data
    environment:
      - MINIO_ROOT_USER_FILE=/run/secrets/s3_access_key
      - MINIO_ROOT_PASSWORD_FILE=/run/secrets/s3_secret_key
    secrets: [s3_access_key, s3_secret_key]
    volumes:
      - /srv/minio/data:/data
    networks: [s3_net]
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:9000/minio/health/ready || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 10
    deploy:
      placement:
        constraints:
          - node.labels.minio == true

  swarm-s3-mounter:
    image: ghcr.io/swarmnative/swarm-s3-mounter:latest
    networks: [s3_net]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - type: bind
        source: /mnt/s3
        target: /mnt/s3
        bind: { propagation: rshared }
    secrets: [s3_access_key, s3_secret_key]
    environment:
      - S3_MOUNTER_ENABLE_PROXY=true
      - S3_MOUNTER_PROXY_ENGINE=haproxy
      - S3_MOUNTER_HA_LOCAL_SERVICE=minio
      - S3_MOUNTER_HA_PORT=9000
      - S3_MOUNTER_HA_HEALTH_PATH=/minio/health/ready
      - S3_MOUNTER_S3_PROVIDER=Minio
      - S3_MOUNTER_RCLONE_REMOTE=S3:mybucket
      - S3_MOUNTER_MOUNTPOINT=/mnt/s3
      - S3_MOUNTER_S3_ACCESS_KEY_FILE=/run/secrets/s3_access_key
      - S3_MOUNTER_S3_SECRET_KEY_FILE=/run/secrets/s3_secret_key
      - S3_MOUNTER_RCLONE_ARGS=--vfs-cache-mode=writes --dir-cache-time=12h
      - S3_MOUNTER_UNMOUNT_ON_EXIT=true
      - S3_MOUNTER_AUTOCREATE_BUCKET=false
      - S3_MOUNTER_AUTOCREATE_PREFIX=true
    deploy:
      mode: global
      placement:
        constraints:
          - node.labels.mount_s3 == true
      restart_policy: { condition: any }
```
Use the mount from application containers:
```yaml
services:
  app:
    image: your/app:latest
    volumes:
      - type: bind
        source: /mnt/s3
        target: /data
        bind: { propagation: rshared }
    deploy:
      placement:
        constraints:
          - node.labels.mount_s3 == true
```

---

## Configuration (env vars)

### Basic
| Variable | Description | Default |
| --- | --- | --- |
| `S3_MOUNTER_S3_ENDPOINT` | S3 endpoint (e.g. https://s3.local:9000) | required |
| `S3_MOUNTER_S3_PROVIDER` | Optional, leave empty for generic S3; `Minio`/`AWS` | empty |
| `S3_MOUNTER_RCLONE_REMOTE` | rclone remote (e.g. `S3:bucket`) | `S3:bucket` |
| `S3_MOUNTER_MOUNTPOINT` | Host mountpoint | `/mnt/s3` |
| `S3_MOUNTER_S3_ACCESS_KEY_FILE` | Path to AccessKey secret | `/run/secrets/s3_access_key` |
| `S3_MOUNTER_S3_SECRET_KEY_FILE` | Path to SecretKey secret | `/run/secrets/s3_secret_key` |
| `S3_MOUNTER_RCLONE_ARGS` | Extra rclone args (single tuning entrypoint) | empty |

### Load Balancing (HAProxy)
| Variable | Description | Default |
| --- | --- | --- |
| `S3_MOUNTER_ENABLE_PROXY` | Enable built-in reverse proxy | `false` |
| `S3_MOUNTER_PROXY_ENGINE` | Proxy engine (only `haproxy`) | `haproxy` |
| `S3_MOUNTER_HA_LOCAL_SERVICE` | Backend service name(s), comma-separated | `minio-local` |
| `S3_MOUNTER_HA_REMOTE_SERVICE` | Remote service name (optional) | `minio-remote` |
| `S3_MOUNTER_HA_PORT` | Backend port | `9000` |
| `S3_MOUNTER_HA_HEALTH_PATH` | Health check path | `/minio/health/ready` |

### Node-local LB (unique alias)
| Variable | Description | Default |
| --- | --- | --- |
| `S3_MOUNTER_LOCAL_LB` | Enable per-node local LB alias mode | `false` |
| `S3_MOUNTER_PROXY_NETWORK` | Overlay network for HAProxy/mounter (attachable) | empty |
| `S3_MOUNTER_PROXY_PORT` | HAProxy listen port | `8081` |
- Alias: `swarm-s3-mounter-lb-<hostname>`; rclone endpoint auto-sets to `http://swarm-s3-mounter-lb-<hostname>:<port>` when enabled.

### rclone image/update
| Variable | Description | Default |
| --- | --- | --- |
| `S3_MOUNTER_DEFAULT_MOUNTER_IMAGE` | rclone image embedded at release | `rclone/rclone:latest` |
| `S3_MOUNTER_MOUNTER_IMAGE` | Override rclone image at runtime | inherit default |
| `S3_MOUNTER_MOUNTER_UPDATE_MODE` | `never`/`periodic`/`on_change` | `never` |
| `S3_MOUNTER_MOUNTER_PULL_INTERVAL` | Pull interval in `periodic` mode | `24h` |

### Cleanup & autocreation
| Variable | Description | Default |
| --- | --- | --- |
| `S3_MOUNTER_UNMOUNT_ON_EXIT` | Lazy unmount on exit and remove node mounter | `true` |
| `S3_MOUNTER_AUTOCREATE_BUCKET` | Autocreate bucket (if backend supports) | `false` |
| `S3_MOUNTER_AUTOCREATE_PREFIX` | Autocreate prefix (directory) | `true` |

---

## Declarative "volumes" (label-based prefix provisioning)
By default, unprefixed keys are accepted; optional domain prefix can be enabled (prefixed keys take precedence; conflicts are warned).

Declare on service `labels` (unprefixed example):
- `s3.enabled=true`
- `s3.bucket=my-bucket` (optional)
- `s3.prefix=teams/appA/vol-data`
- Reserved: `s3.class=throughput|low-latency|low-mem`, `s3.reclaim=Retain|Delete`, `s3.access=rw|ro`, `s3.args=--vfs-cache-max-size=5G`

To enable an organization-wide domain prefix (e.g. `your-org.io`): set `S3_MOUNTER_LABEL_PREFIX=your-org.io` and use:
- `your-org.io/s3.enabled=true`
- `your-org.io/s3.bucket=my-bucket`
- `your-org.io/s3.prefix=teams/appA/vol-data`

The controller idempotently creates `/mnt/s3/<prefix>` on the node (and optionally remote bucket/prefix). Bind this path in apps to use it.

Example:
```yaml
services:
  app:
    image: your/app:latest
    labels:
      - s3.mounter.swarmnative.io/enabled=true
      - s3.mounter.swarmnative.io/prefix=teams/appA/vol-data
      - s3.mounter.swarmnative.io/reclaim=Retain
    volumes:
      - type: bind
        source: /mnt/s3/teams/appA/vol-data
        target: /data
        bind: { propagation: rshared }
    deploy:
      placement:
        constraints:
          - node.labels.mount_s3 == true
```

---

## Deployment Modes
- Single backend service: `S3_MOUNTER_HA_LOCAL_SERVICE=minio`, mounter reaches `tasks.minio:9000` via HAProxy.
- Multiple services (one per node): comma-separated `S3_MOUNTER_HA_LOCAL_SERVICE=minio1,minio2,...` generating HAProxy server-templates.
- Node-local LB: enable `S3_MOUNTER_LOCAL_LB=true` and set `S3_MOUNTER_PROXY_NETWORK`; mounter uses `swarm-s3-mounter-lb-<hostname>`.
- Startup order: ensure backend is reachable first; controller retries periodically and `/ready` fails until available.

---

## Operations
- Readiness: `/ready` (writes/deletes a marker file successfully).
- Logs: JSON `slog`, `S3_MOUNTER_LOG_LEVEL=debug|info|warn|error`.
- Status: periodically prints mounter status, mount writability, last image pull time, etc.
- Metrics: `/metrics` exposes low-cardinality core metrics (counters/switches). Off by default; set `S3_MOUNTER_ENABLE_METRICS=true` to enable.
  - New: `s3mounter_heal_attempts_total`, `s3mounter_heal_success_total`, `s3mounter_last_heal_success_timestamp`, `s3mounter_orphan_cleanup_total`.
- Release policy:
  - Official: tagging `v*` publishes to GHCR/Docker Hub.
  - Time tags (e.g. `:dYYYYMMDD`/`:tYYYYMMDDHHmm`) for reproducibility/rollback; pin `@sha256` or explicit `vX.Y.Z` for production.
- rclone upgrades: pin in production; for automatic follow, use `on_change` with a reasonable pull interval (off-peak window).
- Container cleanup: the controller prunes non-running managed rclone containers on patrol; running containers are not affected.
- Registry retention: repository has `image-retention` GitHub Action running daily by default; can be triggered manually; retention days/count configurable.

---

## Minimal docker run (no proxy by default)
```bash
docker run -d --name s3m \
  -e S3_MOUNTER_S3_ENDPOINT=http://s3.local:9000 \
  -e S3_MOUNTER_RCLONE_REMOTE=S3:your-bucket \
  -e S3_MOUNTER_MOUNTPOINT=/mnt/s3 \
  -e S3_MOUNTER_S3_ACCESS_KEY_FILE=/run/secrets/s3_access_key \
  -e S3_MOUNTER_S3_SECRET_KEY_FILE=/run/secrets/s3_secret_key \
  -e S3_MOUNTER_ENABLE_METRICS=false \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /mnt/s3:/mnt/s3:rshared \
  --restart=always \
  ghcr.io/swarmnative/swarm-s3-mounter:latest
```

## Prometheus scrape example
```yaml
scrape_configs:
  - job_name: 'swarm-s3-mounter'
    scrape_interval: 30s
    static_configs:
      - targets: ['swarm-s3-mounter:8080']
```

## Proxy/local LB matrix
- Default (recommended): no proxy and no local LB (minimal, fewer deps)
- Enable proxy:
  - `S3_MOUNTER_ENABLE_PROXY=true`
  - Local service name(s): `S3_MOUNTER_HA_LOCAL_SERVICE=minio`
- Enable per-node local LB and nearest access:
  - `S3_MOUNTER_ENABLE_PROXY=true`
  - `S3_MOUNTER_LOCAL_LB=true`
  - `S3_MOUNTER_PROXY_NETWORK=<attachable overlay>`
  - mounter endpoint auto-resolves to `http://swarm-s3-mounter-lb-<hostname>:<port>`

## No-proxy direct mode (no supervisor)
- When `S3_MOUNTER_ENABLE_PROXY=false` (default), the container entrypoint directly `exec storage-ops` without starting supervisor.

## Security & Best Practices
- Least-privileged credentials: create a dedicated S3 user per app with only the required bucket/prefix permissions; rotate periodically.
- Non-root minimal image: runs as `app:app`; configs/logs under `/app/etc` and `/app/var/...`.
- Restrict Docker API: optionally use docker-socket-proxy; set read-only root, no-new-privileges, drop NET_RAW (via orchestrator).

---

## Config validation & effective config
- Static validation only; no side effects:
  - CLI: `storage-ops --validate-config` (exit code 0/1; JSON on stdout)
  - HTTP: `GET /validate` (JSON)
- Prints `effective_config` (redacted) at startup for audit/debugging.

---

## Label prefix (optional)
- Precedence: args > env > config > labels > defaults.
- Supports unprefixed `s3.*` and any domain-prefixed `<prefix>/s3.*`; on conflicts, prefixed keys win with warnings (record source object).
- When `S3_MOUNTER_LABEL_PREFIX` or `LABEL_PREFIX` is set, only that prefix and unprefixed keys are accepted; others are ignored with warnings.
- Resource quotas: set reasonable CPU/memory limits for controller and mounter; tune VFS cache via `S3_MOUNTER_RCLONE_ARGS`.

---

## Security & hardening (compose snippet)
Recommended `docker-stack.yml`: read-only root, no-new-privileges, drop `NET_RAW`, and resource limits:
```yaml
deploy:
  resources:
    limits: { cpus: '0.50', memory: 256M }
    reservations: { cpus: '0.10', memory: 64M }
security_opt: ["no-new-privileges:true"]
cap_drop: ["NET_RAW"]
read_only: true
tmpfs: ["/tmp"]
```

---

## FAQ
- Should MinIO start first?
  - Recommended yes, and pass health checks first; Swarm has no strict `depends_on`. The controller will keep retrying until ready.
- Will `tasks.<service>` connect to proxies on other nodes?
  - It resolves replicas of the backend service, typically used to talk to the backend directly rather than this project's HAProxy. If node-local LB is enabled, use the auto-set endpoint `swarm-s3-mounter-lb-<hostname>`.

---

## License
MIT (see `LICENSE`).

## Contributing
PRs/Issues welcome (please read `CONTRIBUTING.md` and `CODE_OF_CONDUCT.md` first).
