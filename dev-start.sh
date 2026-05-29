#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$ROOT_DIR/backend"
FRONTEND_DIR="$ROOT_DIR/frontend"
LOG_DIR="${LOG_DIR:-/tmp/sub2api-dev}"
DEV_HOST="${DEV_HOST:-192.168.31.129}"

DB_NAME="${DB_NAME:-sub2api}"
DB_USER="${DB_USER:-sub2api}"
DB_PASSWORD="${DB_PASSWORD:-sub2api_dev_password}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
BACKEND_HOST="${BACKEND_HOST:-$DEV_HOST}"
BACKEND_PORT="${BACKEND_PORT:-9000}"
FRONTEND_HOST="${FRONTEND_HOST:-$DEV_HOST}"
FRONTEND_PORT="${FRONTEND_PORT:-9001}"
BACKEND_URL="${BACKEND_URL:-http://$BACKEND_HOST:$BACKEND_PORT}"
FRONTEND_URL="${FRONTEND_URL:-http://$FRONTEND_HOST:$FRONTEND_PORT}"

BACKEND_PID=""
FRONTEND_PID=""

log() {
  printf '[sub2api-dev] %s\n' "$*"
}

fail() {
  printf '[sub2api-dev] ERROR: %s\n' "$*" >&2
  exit 1
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

service_active() {
  systemctl is-active --quiet "$1" >/dev/null 2>&1
}

start_service() {
  local service="$1"

  if ! has_cmd systemctl; then
    fail "systemctl 不存在，无法自动启动 $service"
  fi

  if service_active "$service"; then
    log "$service 已运行"
    return
  fi

  log "启动 $service，需要 sudo 时按提示输入本机密码"
  sudo systemctl start "$service"
}

ensure_commands() {
  local missing=()

  for cmd in go bash psql pg_isready redis-cli; do
    if ! has_cmd "$cmd"; then
      missing+=("$cmd")
    fi
  done

  if ((${#missing[@]} > 0)); then
    fail "缺少命令: ${missing[*]}"
  fi
}

ensure_services() {
  if pg_isready -h "$DB_HOST" -p "$DB_PORT" >/dev/null 2>&1; then
    log "PostgreSQL 服务已响应"
  else
    start_service postgresql
  fi

  if redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping | grep -q PONG; then
    log "Redis 服务已响应"
  else
    start_service redis-server
  fi
}

ensure_database() {
  local db_url="postgresql://$DB_USER:$DB_PASSWORD@$DB_HOST:$DB_PORT/$DB_NAME?sslmode=disable"

  if pg_isready -h "$DB_HOST" -p "$DB_PORT" >/dev/null 2>&1 &&
    PGPASSWORD="$DB_PASSWORD" psql "$db_url" -tAc 'SELECT 1' >/dev/null 2>&1; then
    log "PostgreSQL $DB_NAME 可连接"
    return
  fi

  log "创建/修复 PostgreSQL 开发账号和数据库，需要 sudo 时按提示输入本机密码"
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "DO \$\$ BEGIN CREATE ROLE $DB_USER LOGIN PASSWORD '$DB_PASSWORD'; EXCEPTION WHEN duplicate_object THEN ALTER ROLE $DB_USER LOGIN PASSWORD '$DB_PASSWORD'; END \$\$;"

  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
    sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"
  fi

  PGPASSWORD="$DB_PASSWORD" psql "$db_url" -tAc 'SELECT 1' >/dev/null
  log "PostgreSQL $DB_NAME 已就绪"
}

ensure_redis() {
  if redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping | grep -q PONG; then
    log "Redis 可连接"
    return
  fi

  fail "Redis $REDIS_HOST:$REDIS_PORT 无法连接"
}

ensure_frontend_tooling() {
  if bash -ic 'command -v pnpm >/dev/null 2>&1' >/dev/null 2>&1; then
    return
  fi

  fail "找不到 pnpm。VSCode 终端里先确认 bash -ic 'pnpm -v' 能输出版本"
}

ensure_frontend_dependencies() {
  log "检查前端依赖"
  (
    cd "$FRONTEND_DIR"
    bash -ic 'pnpm install --frozen-lockfile --config.confirmModulesPurge=false'
  )
}

print_urls() {
  log "前端: $FRONTEND_URL"
  log "后端: $BACKEND_URL"
  log "后端日志: $LOG_DIR/backend.log"
  log "前端日志: $LOG_DIR/frontend.log"
}

cleanup() {
  local code=$?

  if [[ -n "$FRONTEND_PID" ]] && kill -0 "$FRONTEND_PID" >/dev/null 2>&1; then
    kill "$FRONTEND_PID" >/dev/null 2>&1 || true
  fi

  if [[ -n "$BACKEND_PID" ]] && kill -0 "$BACKEND_PID" >/dev/null 2>&1; then
    kill "$BACKEND_PID" >/dev/null 2>&1 || true
  fi

  exit "$code"
}

run_checks() {
  ensure_commands
  ensure_services
  ensure_database
  ensure_redis
  ensure_frontend_tooling
  ensure_frontend_dependencies
}

start_dev() {
  mkdir -p "$LOG_DIR"
  : >"$LOG_DIR/backend.log"
  : >"$LOG_DIR/frontend.log"

  trap cleanup INT TERM EXIT

  log "启动后端"
  (
    cd "$BACKEND_DIR"
    SERVER_HOST="$BACKEND_HOST" SERVER_PORT="$BACKEND_PORT" go run ./cmd/server
  ) 2>&1 | tee "$LOG_DIR/backend.log" &
  BACKEND_PID=$!

  log "启动前端"
  (
    cd "$FRONTEND_DIR"
    VITE_DEV_PROXY_TARGET="$BACKEND_URL" VITE_DEV_PORT="$FRONTEND_PORT" bash -ic 'pnpm run dev'
  ) 2>&1 | tee "$LOG_DIR/frontend.log" &
  FRONTEND_PID=$!

  print_urls
  log "按 Ctrl-C 停止前后端"

  wait -n "$BACKEND_PID" "$FRONTEND_PID"
}

case "${1:-}" in
  --check)
    run_checks
    log "开发环境检查通过"
    ;;
  -h|--help)
    cat <<'USAGE'
Usage:
  ./dev-start.sh          检查本地 PG/Redis，然后启动前端和后端
  ./dev-start.sh --check  只检查本地开发环境，不启动服务

Environment overrides:
  LOG_DIR=/tmp/sub2api-dev
  DEV_HOST=192.168.31.129
  BACKEND_HOST=$DEV_HOST
  BACKEND_PORT=9000
  FRONTEND_HOST=$DEV_HOST
  FRONTEND_PORT=9001
  DB_NAME=sub2api
  DB_USER=sub2api
  DB_PASSWORD=sub2api_dev_password
  DB_HOST=localhost
  DB_PORT=5432
  REDIS_HOST=127.0.0.1
  REDIS_PORT=6379
USAGE
    ;;
  *)
    run_checks
    start_dev
    ;;
esac
