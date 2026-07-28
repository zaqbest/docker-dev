#!/usr/bin/env bash
#
# backup-apps.sh
#
# 备份 docker-kit 各应用的数据目录，产物形如：
#   backup/{appname}-{YYYYmmdd-HHMMSS}.tar.gz
#
# 特性:
#   - 每个 app 一个 tar.gz
#   - 每个 app 只保留最近 N 份（默认 5），更旧的自动清理
#   - 支持通过参数指定要备份的 app
#   - 支持 --all 备份全部
#   - 支持 --stop 备份前停止对应容器 / 完成后再启动（一致性备份）
#
# 用法:
#   ./scripts/backup-apps.sh --all
#   ./scripts/backup-apps.sh mysql nexus
#   ./scripts/backup-apps.sh --all --stop
#   ./scripts/backup-apps.sh -l                # 列出所有可备份的 app
#   ./scripts/backup-apps.sh -k 10 --all       # 保留 10 份
#

set -euo pipefail

# --- 配置区：app -> 需要备份的相对路径（多个用空格） ---
# 只备份数据目录，不备份配置模板等无状态内容。
declare -A APP_PATHS=(
  [consul]="consul/data"
  [danmu-server]="danmu-server/config"
  [elasticsearch]="elasticsearch/data"
  [h2]="h2/data"
  [kafka]="kafka/data"
  [mysql]="mysql/data"
  [nexus]="nexus/data"
  [solr]="solr/data solr/zk/data solr/zk/datalog"
)

# 对应 docker-compose 文件（用于可选的 --stop）
declare -A APP_COMPOSE=(
  [consul]="docker-compose-consul.yml"
  [danmu-server]="docker-compose-danmu-server.yml"
  [elasticsearch]="docker-compose-elasticsearch.yml"
  [h2]="docker-compose-h2.yml"
  [kafka]="docker-compose-kafka.yml"
  [mysql]="docker-compose-mysql.yml"
  [nexus]="docker-compose-nexus.yml"
  [solr]="docker-compose-solr.yml"
)

# --- 参数解析 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_DIR="$PROJECT_ROOT/backup"
KEEP=5
DO_ALL=0
DO_STOP=0
LIST_ONLY=0
TARGET_APPS=()

log()  { echo -e "\033[1;32m[INFO]\033[0m  $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

usage() {
  cat <<EOF
用法: $0 [选项] [app1 app2 ...]

选项:
  --all              备份所有已注册的 app
  --stop             备份前 docker compose stop，备份后再 start（一致性备份）
  -k, --keep N       每个 app 最多保留 N 份备份（默认 5）
  -o, --output DIR   备份输出目录（默认 <project>/backup）
  -l, --list         列出所有可备份的 app 及其数据路径
  -h, --help         显示帮助

可用的 app: ${!APP_PATHS[@]}

示例:
  $0 --all
  $0 mysql nexus
  $0 --all --stop -k 10
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)          DO_ALL=1; shift ;;
    --stop)         DO_STOP=1; shift ;;
    -k|--keep)      KEEP="$2"; shift 2 ;;
    -o|--output)    BACKUP_DIR="$2"; shift 2 ;;
    -l|--list)      LIST_ONLY=1; shift ;;
    -h|--help)      usage ;;
    -*)             err "未知选项: $1"; exit 1 ;;
    *)              TARGET_APPS+=("$1"); shift ;;
  esac
done

# --list 模式
if [[ "$LIST_ONLY" -eq 1 ]]; then
  echo "可备份的 app 列表："
  printf "%-15s %-40s %s\n" "APP" "数据路径" "Compose 文件"
  echo "-------------------------------------------------------------------------------"
  for app in "${!APP_PATHS[@]}"; do
    printf "%-15s %-40s %s\n" "$app" "${APP_PATHS[$app]}" "${APP_COMPOSE[$app]:-}"
  done | sort
  exit 0
fi

# 确定目标
if [[ "$DO_ALL" -eq 1 ]]; then
  TARGET_APPS=("${!APP_PATHS[@]}")
fi

if [[ ${#TARGET_APPS[@]} -eq 0 ]]; then
  err "必须指定要备份的 app，或使用 --all"
  echo
  usage
fi

# 检查 app 是否合法
for app in "${TARGET_APPS[@]}"; do
  if [[ -z "${APP_PATHS[$app]:-}" ]]; then
    err "未知的 app: $app"
    err "可用: ${!APP_PATHS[@]}"
    exit 1
  fi
done

mkdir -p "$BACKUP_DIR"

# 检测 compose 命令
COMPOSE_CMD=""
if [[ "$DO_STOP" -eq 1 ]]; then
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
  else
    err "启用了 --stop 但未找到 docker compose 命令"
    exit 1
  fi
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

backup_one() {
  local app="$1"
  local paths="${APP_PATHS[$app]}"
  local compose="${APP_COMPOSE[$app]:-}"
  local out="$BACKUP_DIR/${app}-${TIMESTAMP}.tar.gz"

  log "===== 备份 $app ====="

  # 检查数据目录是否存在（至少一个）
  local has_data=0
  local existing_paths=()
  for p in $paths; do
    if [[ -e "$PROJECT_ROOT/$p" ]]; then
      has_data=1
      existing_paths+=("$p")
    else
      warn "路径不存在，跳过: $p"
    fi
  done
  if [[ "$has_data" -eq 0 ]]; then
    warn "$app 没有任何数据目录，跳过备份"
    return
  fi

  # 可选：先停容器
  local stopped=0
  if [[ "$DO_STOP" -eq 1 && -n "$compose" && -f "$PROJECT_ROOT/$compose" ]]; then
    log "停止 $app 容器..."
    (cd "$PROJECT_ROOT" && $COMPOSE_CMD -f "$compose" stop) || warn "停止失败，继续备份（可能会不一致）"
    stopped=1
  fi

  # 打包
  log "打包 -> $out"
  # 用相对路径打包，恢复时更方便
  ( cd "$PROJECT_ROOT" && tar -czf "$out" "${existing_paths[@]}" )
  local size
  size="$(du -h "$out" | awk '{print $1}')"
  log "完成: $(basename "$out") ($size)"

  # 恢复容器
  if [[ "$stopped" -eq 1 ]]; then
    log "重启 $app 容器..."
    (cd "$PROJECT_ROOT" && $COMPOSE_CMD -f "$compose" start) || warn "重启失败，请手动检查"
  fi

  # 清理旧备份，只保留最近 $KEEP 份
  local pattern="$BACKUP_DIR/${app}-*.tar.gz"
  local total
  total="$(ls -1t $pattern 2>/dev/null | wc -l | tr -d ' ')"
  if (( total > KEEP )); then
    local to_remove=$(( total - KEEP ))
    log "清理 $app 旧备份：共 $total 份，超出 $to_remove 份"
    # shellcheck disable=SC2012
    ls -1t $pattern | tail -n "$to_remove" | while IFS= read -r old; do
      warn "  删除: $(basename "$old")"
      rm -f "$old"
    done
  fi
}

log "备份目录: $BACKUP_DIR"
log "本次时间戳: $TIMESTAMP"
log "保留份数:   $KEEP"
[[ "$DO_STOP" -eq 1 ]] && log "启用了 --stop：会临时停止容器"
echo

for app in "${TARGET_APPS[@]}"; do
  backup_one "$app"
  echo
done

log "全部完成！当前备份文件："
ls -lh "$BACKUP_DIR" | tail -n +2