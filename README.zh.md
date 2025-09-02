[English](README.md) | 简体中文

# swarm-s3-mounter

![CI](https://img.shields.io/github/actions/workflow/status/swarmnative/swarm-s3-mounter/publish.yml?branch=main)
![Release](https://img.shields.io/github/v/release/swarmnative/swarm-s3-mounter)
![License](https://img.shields.io/github/license/swarmnative/swarm-s3-mounter)
![Docker Pulls](https://img.shields.io/docker/pulls/swarmnative/swarm-s3-mounter)
![Image Size](https://img.shields.io/docker/image-size/swarmnative/swarm-s3-mounter/latest)
![Go Version](https://img.shields.io/github/go-mod/go-version/swarmnative/swarm-s3-mounter)
![Go Report](https://goreportcard.com/badge/github.com/swarmnative/swarm-s3-mounter)
[![OpenSSF Scorecard](https://img.shields.io/badge/OpenSSF%20Scorecard-pending-lightgrey)](https://api.securityscorecards.dev/projects/github.com/swarmnative/swarm-s3-mounter)
![Last Commit](https://img.shields.io/github/last-commit/swarmnative/swarm-s3-mounter)
![Issues](https://img.shields.io/github/issues/swarmnative/swarm-s3-mounter)
![PRs](https://img.shields.io/github/issues-pr/swarmnative/swarm-s3-mounter)

在 Docker Swarm 上为节点提供 S3 兼容对象存储挂载的轻量控制器：
- 宿主机级 rclone FUSE 挂载（业务容器通过 bind 使用）。
- 内置 HAProxy（可选）用于内网负载均衡与故障转移。
- 声明式“卷”（前缀）供给，最小改动接近 K8s 体验。

---

## 特性
- 主机级挂载与自愈：
  - 在打了 `node.labels.mount_s3=true` 的节点创建并守护 `/mnt/s3`（rshared）。
  - 异常时懒卸（fusermount/umount）并重建；退出时可懒卸（可配置）。
- 负载均衡：
  - HAProxy 默认 leastconn、keep-alive、http-reuse safe、健康检查与 slowstart。
  - 支持多个后端 Service（逗号分隔），Swarm tasks DNS 动态发现。
  - 节点本地 LB 模式：为每节点导出唯一别名 `swarm-s3-mounter-lb-<hostname>`，让 mounter 总是链接本节点代理。
- 声明式“卷”：
  - 通过 service.labels 声明 bucket/prefix/class/reclaim/access，控制器幂等创建前缀目录与可选远端前缀/桶。
- 版本与更新：
  - 发布时内嵌默认 rclone 版本；运行时可覆盖。
  - rclone 支持 `never/periodic/on_change` 自动更新策略（默认 never）。
  - CI/nightly 仅在依赖变更时发布，避免频繁更新。

---

## 快速开始（最小 Stack）
前提：已初始化 Swarm；目标节点开启 FUSE；为使用挂载的节点打标签。
```bash
docker node update --label-add mount_s3=true <NODE>
```
创建凭据（Swarm secrets）：
```bash
docker secret create s3_access_key -
# 粘贴 AccessKey 回车，Ctrl-D 结束

docker secret create s3_secret_key -
# 粘贴 SecretKey 回车，Ctrl-D 结束
```
部署（单后端 Service 示例，mounter 通过内置 HAProxy 均衡到 tasks.minio:9000）：
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
业务容器使用挂载：
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

## 配置（环境变量）

### 基本
| 变量 | 说明 | 默认 |
| --- | --- | --- |
| `S3_MOUNTER_S3_ENDPOINT` | S3 端点（如 https://s3.local:9000） | 必填 |
| `S3_MOUNTER_S3_PROVIDER` | 可选，通用 S3 留空；或 `Minio`/`AWS` | 空 |
| `S3_MOUNTER_RCLONE_REMOTE` | rclone 远端（如 `S3:bucket`） | `S3:bucket` |
| `S3_MOUNTER_MOUNTPOINT` | 宿主机挂载点 | `/mnt/s3` |
| `S3_MOUNTER_S3_ACCESS_KEY_FILE` | AccessKey 的 secret 路径 | `/run/secrets/s3_access_key` |
| `S3_MOUNTER_S3_SECRET_KEY_FILE` | SecretKey 的 secret 路径 | `/run/secrets/s3_secret_key` |
| `S3_MOUNTER_RCLONE_ARGS` | 追加 rclone 参数（唯一调优入口） | 空 |

### 负载均衡（HAProxy）
| 变量 | 说明 | 默认 |
| --- | --- | --- |
| `S3_MOUNTER_ENABLE_PROXY` | 是否启用内置反代 | `false` |
| `S3_MOUNTER_PROXY_ENGINE` | 反代引擎（仅 `haproxy`） | `haproxy` |
| `S3_MOUNTER_HA_LOCAL_SERVICE` | 后端 Service 名，支持逗号分隔（如 `minio1,minio2`） | `minio-local` |
| `S3_MOUNTER_HA_REMOTE_SERVICE` | 远端 Service 名（可留空） | `minio-remote` |
| `S3_MOUNTER_HA_PORT` | 后端端口 | `9000` |
| `S3_MOUNTER_HA_HEALTH_PATH` | 健康检查路径 | `/minio/health/ready` |

### 节点本地 LB（唯一别名）
| 变量 | 说明 | 默认 |
| --- | --- | --- |
| `S3_MOUNTER_LOCAL_LB` | 启用“每节点本地 LB 别名”模式 | `false` |
| `S3_MOUNTER_PROXY_NETWORK` | HAProxy/mounter 所在 overlay 网络（需 attachable） | 空 |
| `S3_MOUNTER_PROXY_PORT` | HAProxy 监听端口 | `8081` |
- 别名规范：`swarm-s3-mounter-lb-<hostname>`；启用后 rclone 端点自动设为 `http://swarm-s3-mounter-lb-<hostname>:<port>`。

### rclone 镜像/更新策略
| 变量 | 说明 | 默认 |
| --- | --- | --- |
| `S3_MOUNTER_DEFAULT_MOUNTER_IMAGE` | 发布时内嵌的 rclone 镜像 | `rclone/rclone:latest` |
| `S3_MOUNTER_MOUNTER_IMAGE` | 运行时覆盖 rclone 镜像 | 继承默认 |
| `S3_MOUNTER_MOUNTER_UPDATE_MODE` | `never`/`periodic`/`on_change` | `never` |
| `S3_MOUNTER_MOUNTER_PULL_INTERVAL` | `periodic` 模式拉取间隔 | `24h` |

### 清理与自动创建
| 变量 | 说明 | 默认 |
| --- | --- | --- |
| `S3_MOUNTER_UNMOUNT_ON_EXIT` | 退出时懒卸并移除本节点 mounter | `true` |
| `S3_MOUNTER_AUTOCREATE_BUCKET` | 自动创建桶（后端需支持） | `false` |
| `S3_MOUNTER_AUTOCREATE_PREFIX` | 自动创建前缀（目录） | `true` |

---

## 声明式“卷”（基于标签的前缀供给）
按 STANDARDS，默认使用“无前缀”键；也可选用域名前缀（前缀优先，冲突告警）。

在服务的 `labels` 中声明（无前缀示例）：
- `s3.enabled=true`
- `s3.bucket=my-bucket`（可选）
- `s3.prefix=teams/appA/vol-data`
- 预留：`s3.class=throughput|low-latency|low-mem`、`s3.reclaim=Retain|Delete`、`s3.access=rw|ro`、`s3.args=--vfs-cache-max-size=5G`

若需启用统一域前缀（示例 `your-org.io`）：设置 `S3_MOUNTER_LABEL_PREFIX=your-org.io`，并改用：
- `your-org.io/s3.enabled=true`
- `your-org.io/s3.bucket=my-bucket`
- `your-org.io/s3.prefix=teams/appA/vol-data`

控制器会在本节点幂等创建 `/mnt/s3/<prefix>` 目录（若启用自动创建亦会尝试创建远端前缀/桶），应用 bind 到该路径即可使用。

示例：
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

## 部署模式
- 单后端 Service：`S3_MOUNTER_HA_LOCAL_SERVICE=minio`，mounter 通过内置 HAProxy 均衡到 `tasks.minio:9000`。
- 多服务（每节点一服务）：`S3_MOUNTER_HA_LOCAL_SERVICE=minio1,minio2,...`，HAProxy 为每个 service 生成 dynamic server-template。
- 节点本地 LB：启用 `S3_MOUNTER_LOCAL_LB=true` 并指定 `S3_MOUNTER_PROXY_NETWORK`，mounter 使用 `swarm-s3-mounter-lb-<hostname>` 就近接入。
- 启动顺序：先保证后端存储可达；Swarm 无严格顺序，控制器会周期重试，/ready 失败直至可用。

---

## 运维
- 就绪探针：`/ready`（成功写入/删除标记文件即就绪）。
- 日志：采用 JSON 结构化 `slog`，支持 `S3_MOUNTER_LOG_LEVEL=debug|info|warn|error`。
- 状态：每轮输出 mounter 运行状态、挂载可写性、最近镜像拉取时间等。
- 指标：`/metrics` 暴露核心低基数指标（仅计数器/开关），默认关，需设置 `S3_MOUNTER_ENABLE_METRICS=true` 开启。
  - 新增：`s3mounter_heal_attempts_total`、`s3mounter_heal_success_total`、`s3mounter_last_heal_success_timestamp`、`s3mounter_orphan_cleanup_total`
- 发布策略：
  - 正式版：打 `v*` tag 自动发布 GHCR/Docker Hub。
  - 时间标签：镜像可能带日期/时间标签（如 `:dYYYYMMDD`/`:tYYYYMMDDHHmm`）用于可复现与回滚；生产应固定 `@sha256` 或显式 `vX.Y.Z`。
- rclone 升级：生产建议固定版本；如需自动跟随，设置 `on_change` 并指定合适的 `pull interval`（低峰窗口）。
- 容器清理：控制器在巡检时清理“非运行状态”的受管 rclone 容器（意外退出/创建未启动），不影响正在运行的容器。
- 远端仓库清理：仓库内置 `image-retention` GitHub Actions，默认每日执行；支持手动触发并可配置保留天数/保留数量。

---

## 最小 docker run 示例（默认无代理）
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

## Prometheus 抓取示例
```yaml
scrape_configs:
  - job_name: 'swarm-s3-mounter'
    scrape_interval: 30s
    static_configs:
      - targets: ['swarm-s3-mounter:8080']
```

## 代理/本地 LB 对照
- 默认（推荐）：不启用代理与本地 LB（极简、少依赖）
- 启用代理：
  - `S3_MOUNTER_ENABLE_PROXY=true`
  - 本地服务名：`S3_MOUNTER_HA_LOCAL_SERVICE=minio`（或逗号分隔多个）
- 启用“每节点本地 LB”并就近接入：
  - `S3_MOUNTER_ENABLE_PROXY=true`
  - `S3_MOUNTER_LOCAL_LB=true`
  - `S3_MOUNTER_PROXY_NETWORK=<attachable overlay>`
  - mounter 端点自动解析为 `http://swarm-s3-mounter-lb-<hostname>:<port>`

## 无代理直跑（去 supervisor）
- 当 `S3_MOUNTER_ENABLE_PROXY=false`（默认）时，容器入口将直接 `exec storage-ops`，不再启动 supervisor。

## 安全与最佳实践
- 最小权限凭据：为业务创建独立 S3 用户，仅授予目标桶/前缀权限；按周期轮换（双密钥并行）。
- 镜像最小权限与非 root：镜像内置 `app` 用户，默认 `USER app:app` 运行；配置与日志写入 `/app/etc`、`/app/var/...`。
- 限制 Docker API：可选 docker-socket-proxy，仅开放必要端点；建议只读根、no-new-privileges、丢弃 NET_RAW（由编排侧设置）。

---

## 配置校验与生效配置摘要
- 只做静态校验，不触发实际操作：
  - 命令行：`storage-ops --validate-config`（返回码 0/1，stdout 为 JSON）
  - HTTP：`GET /validate`（JSON）
- 启动时会输出 `effective_config`（脱敏），便于审计与排障。

---

## 标签前缀（可选）
- 配置优先级：参数 > 环境 > 配置 > 标签 > 默认。
- 默认支持无前缀键 `s3.*`，并接受任意域名前缀 `<prefix>/s3.*`；冲突时“前缀键”优先并告警（记录来源对象）。
- 指定 `S3_MOUNTER_LABEL_PREFIX` 或 `LABEL_PREFIX` 后，仅接受该前缀与无前缀键，其他前缀将被忽略并告警（避免跨组织误用）。
- 资源配额：为控制器与 mounter 设置合理的 CPU/内存限额；通过 `S3_MOUNTER_RCLONE_ARGS` 控制 VFS 缓存大小与期限。

---

## 安全与编排加固（示例）
在 `docker-stack.yml` 中建议：只读根、no-new-privileges、丢弃 `NET_RAW`、资源限额：
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
- MinIO 是否应先启动？
  - 建议先部署并通过健康检查；Swarm 无严格 `depends_on`，控制器会重试直至就绪。
- `tasks.<service>` 会不会连到其他节点的代理？
  - 它解析的是后端 Service 副本 IP，通常用于直连后端而非本项目的 HAProxy。若启用节点本地 LB，请使用本项目自动设置的 `swarm-s3-mounter-lb-<hostname>` 端点。

---

## 许可证
MIT（见 `LICENSE`）。

## 贡献
欢迎 PR / Issue（请先阅读 `CONTRIBUTING.md`、`CODE_OF_CONDUCT.md`）。


