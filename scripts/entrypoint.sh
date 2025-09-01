#!/bin/sh
set -eu

ENABLE_PROXY=${S3_MOUNTER_ENABLE_PROXY:-"false"}
PROXY_ENGINE=${S3_MOUNTER_PROXY_ENGINE:-"haproxy"} # haproxy only

# target writable paths for non-root
APP_ETC=${APP_ETC:-"/app/etc"}
APP_LOG=${APP_LOG:-"/app/var/log"}
APP_RUN=${APP_RUN:-"/app/var/run"}
HAPROXY_ETC=${HAPROXY_ETC:-"${APP_ETC}/haproxy"}
SUPERVISOR_CONF=${SUPERVISOR_CONF:-"${APP_ETC}/supervisord.conf"}

if [ "$ENABLE_PROXY" = "true" ]; then
  H_LOCAL_SERVICE=${S3_MOUNTER_HA_LOCAL_SERVICE:-"minio-local"}
  H_REMOTE_SERVICE=${S3_MOUNTER_HA_REMOTE_SERVICE:-"minio-remote"}
  H_PORT=${S3_MOUNTER_HA_PORT:-"9000"}
  H_HEALTH_PATH=${S3_MOUNTER_HA_HEALTH_PATH:-"/minio/health/ready"}
  # Build multiple local service templates if comma-separated
  LOC_LINES=""
  IFS=',' read -r -a _locals <<< "$H_LOCAL_SERVICE"
  for svc in "${_locals[@]}"; do
    svc_trim=$(echo "$svc" | sed 's/^\s*//;s/\s*$//')
    [ -z "$svc_trim" ] && continue
    LOC_LINES="$LOC_LINES\n  server-template loc 1-8 tasks.${svc_trim}:${H_PORT} resolvers docker resolve-prefer ipv4 init-addr none weight 100"
  done
  RMT_LINE=""
  if [ -n "$H_REMOTE_SERVICE" ]; then
    RMT_LINE="\n  server-template rmt 1-8 tasks.${H_REMOTE_SERVICE}:${H_PORT} resolvers docker resolve-prefer ipv4 init-addr none backup weight 10"
  fi
  mkdir -p "$HAPROXY_ETC"
  cat > "${HAPROXY_ETC}/haproxy.cfg" <<EOF
global
  log stdout format raw local0
  tune.bufsize 32768

defaults
  mode http
  option  httplog
  option  http-keep-alive
  http-reuse safe
  timeout connect 2s
  timeout client  60s
  timeout server  60s
  retries 2

resolvers docker
  nameserver dns 127.0.0.11:53
  resolve_retries 3
  timeout retry 1s
  hold valid 10s

frontend s3_in
  bind :8081
  default_backend s3_upstream

backend s3_upstream
  balance leastconn
  option httpchk GET ${H_HEALTH_PATH}
  http-check expect status 200-399
  default-server inter 2s fastinter 500ms downinter 5s fall 3 rise 2 slowstart 5s maxconn 500
${LOC_LINES}
${RMT_LINE}
EOF
fi

# Generate supervisord config based on ENABLE_PROXY
mkdir -p "${APP_LOG}/supervisor" "${APP_RUN}"
if [ "$ENABLE_PROXY" = "true" ]; then
  cat > "$SUPERVISOR_CONF" <<'SUPV'
[supervisord]
logfile=/app/var/log/supervisor/supervisord.log
pidfile=/app/var/run/supervisord.pid
loglevel=info
nodaemon=true

[program:haproxy]
command=/usr/sbin/haproxy -f /app/etc/haproxy/haproxy.cfg -db
autorestart=true
priority=10

[program:storage-ops]
command=/usr/local/bin/storage-ops
autorestart=true
priority=20
SUPV
else
  # 无代理：直接运行 storage-ops，绕过 supervisor
  exec /usr/local/bin/storage-ops
fi

exec "$@"

