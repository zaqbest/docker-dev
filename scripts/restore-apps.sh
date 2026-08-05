#!/usr/bin/env bash
#
# restore-apps.sh
#
# 从 backup/ 恢复某个 app 的数据。
# 备份文件命名：backup/{appname}-{YYYYmmdd-HHMMSS}.tar.gz
#              backup/pre-restore-{appname}-{YYYYmmdd-HHMMSS}.tar.gz
#
# 兼容 bash 3.2（macOS 自带），不使用关联数组。
#
# 用法:
#   ./scripts/restore-apps.sh <app>                       # 交互式选择
#   ./scripts/restore-apps.sh <app> latest                # 恢复最新一份
#   ./scripts/restore-apps.sh <app> <backup-file>         # 指定文件
#   ./scripts/restore-apps.sh <backup-file>               # 仅给文件，自动识别 app
#   ./scripts/restore-apps.sh -l [<app>]                  # 列出备份
#

set -euo pipefail

# --- 与 backup-apps.sh 保持一致 ---
ALL_APPS=(consul danmu-server elasticsearch h2 kafka mysql nexus solr gitea)

app_paths() {
  case "$1" in
    consul)        echo "consul/data" ;;
    danmu-server)  echo "danmu-server/app-data danmu-server/db-data" ;;
    elasticsearch) echo "elasticsearch/data" ;;
    h2)            echo "h2/data" ;;
    kafka)         echo "kafka/data" ;;
    mysql)         echo "mysql/data" ;;
    nexus)         echo "nexus/data" ;;
    solr)          echo "solr/data solr/zk/data solr/zk/datalog" ;;
    gitea)         echo "gitea/app_data gitea/db_data" ;;
    *)             return 1 ;;
  esac
}

app_compose() {
  case "$1" in
    consul)        echo "docker-compose-consul.yml" ;;
    danmu-server)  echo "docker-compose-danmu-server.yml" ;;
    elasticsearch) echo "docker-compose-elasticsearch.yml" ;;
    h2)            echo "docker-compose-h2.yml" ;;
    kafka)         echo "docker-compose-kafka.yml" ;;
    mysql)         echo "docker-compose-mysql.yml" ;;
    nexus)         echo "docker-compose-nexus.yml" ;;
    solr)          echo "docker-compose-solr.yml" ;;
    gitea)         echo "docker-compose-gitea.yml" ;;
    *)             return 1 ;;
  esac
}

is_valid_app() {
  local x
  for x in "${ALL_APPS[@]}"; do
    [[ "$x" == "$1" ]] && return 0
  done
  return 1
}

# 从备份文件名推断 app 名称
# 支持:
#   {app}-YYYYmmdd-HHMMSS.tar.gz
#   pre-restore-{app}-YYYYmmdd-HHMMSS.tar.gz
detect_app_from_filename() {
  local base
  base="$(basename "$1")"
  local core="$base"
  if [[ "$core" == pre-restore-* ]]; then
    core="${core#pre-restore-}"
  fi
  # 去掉 -YYYYmmdd-HHMMSS.tar.gz 后缀
  local candidate
  candidate="$(echo "$core" | sed -E 's/-[0-9]{8}-[0-9]{6}\.tar\.gz$//')"
  if [[ -z "$candidate" || "$candidate" == "$core" ]]; then
    return 1
  fi
  if is_valid_app "$candidate"; then
    echo "$candidate"
    return 0
  fi
  return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_DIR="$PROJECT_ROOT/backup"

DO_STOP=0
DO_SAFETY=1
ASSUME_YES=0
LIST_ONLY=0
POSITIONAL=()

log()  { echo -e "\033[1;32m[INFO]\033[0m  $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

usage() {
  cat <<EOF
用法: $0 [选项] <app> [<备份文件|latest>]
      $0 [选项] <备份文件>            # 从文件名自动识别 app
      $0 -l [<app>]

选项:
  --stop           恢复前 docker compose stop，恢复后再 start
  --no-safety      跳过"恢复前先把现有数据打包保存"这一步
  -y, --yes        跳过所有确认
  -o, --output DIR backup 目录（默认 <project>/backup）
  -l, --list       列出备份（可指定 app）
  -h, --help       显示帮助

可用的 app: ${ALL_APPS[*]}

示例:
  $0 -l
  $0 -l mysql
  $0 mysql
  $0 mysql latest --stop
  $0 nexus nexus-20260728-153000.tar.gz -y
  $0 backup/nexus-20260728-092427.tar.gz   # 自动识别为 nexus
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop)         DO_STOP=1; shift ;;
    --no-safety)    DO_SAFETY=0; shift ;;
    -y|--yes)       ASSUME_YES=1; shift ;;
    -o|--output)    BACKUP_DIR="$2"; shift 2 ;;
    -l|--list)      LIST_ONLY=1; shift ;;
    -h|--help)      usage ;;
    -*)             err "未知选项: $1"; exit 1 ;;
    *)              POSITIONAL+=("$1"); shift ;;
  esac
done

# 兼容 bash 3.2：数组可能为空时的取值
get_pos() { [[ ${#POSITIONAL[@]} -gt $1 ]] && echo "${POSITIONAL[$1]}" || echo ""; }

# --- list 模式 ---
if [[ "$LIST_ONLY" -eq 1 ]]; then
  filter_app="$(get_pos 0)"
  if [[ ! -d "$BACKUP_DIR" ]]; then
    warn "备份目录不存在: $BACKUP_DIR"; exit 0
  fi
  if [[ -n "$filter_app" ]]; then
    pattern="$BACKUP_DIR/${filter_app}-*.tar.gz"
    log "$filter_app 的备份文件（新 -> 旧）:"
  else
    pattern="$BACKUP_DIR/*.tar.gz"
    log "所有备份文件（新 -> 旧）:"
  fi
  # shellcheck disable=SC2086
  files=$(ls -1t $pattern 2>/dev/null || true)
  if [[ -z "$files" ]]; then
    warn "没有找到匹配的备份"; exit 0
  fi
  printf "%-4s %-45s %-10s %s\n" "No." "文件" "大小" "时间"
  echo "--------------------------------------------------------------------------------"
  i=0
  while IFS= read -r f; do
    i=$((i+1))
    size="$(du -h "$f" | awk '{print $1}')"
    mtime="$(date -r "$f" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || stat -c '%y' "$f" 2>/dev/null | cut -d. -f1)"
    printf "%-4s %-45s %-10s %s\n" "$i" "$(basename "$f")" "$size" "$mtime"
  done <<< "$files"
  exit 0
fi

# --- restore 模式 ---
if [[ ${#POSITIONAL[@]} -lt 1 ]]; then
  err "必须指定 <app> 或 <备份文件>"
  usage
fi

ARG0="$(get_pos 0)"
ARG1="$(get_pos 1)"

APP=""
CHOICE=""

# 情况 1: 第一个参数就是合法 app 名
if is_valid_app "$ARG0"; then
  APP="$ARG0"
  CHOICE="$ARG1"
else
  # 情况 2: 第一个参数可能是文件路径 / 文件名，尝试识别 app
  detected=""
  if detected="$(detect_app_from_filename "$ARG0" 2>/dev/null)"; then
    APP="$detected"
    CHOICE="$ARG0"
    log "从文件名识别到 app: $APP"
  else
    err "未知的 app: $ARG0"
    err "可用: ${ALL_APPS[*]}"
    err "或直接传入形如 <app>-YYYYmmdd-HHMMSS.tar.gz 的备份文件"
    exit 1
  fi
fi

if [[ ! -d "$BACKUP_DIR" ]]; then
  err "备份目录不存在: $BACKUP_DIR"; exit 1
fi

# 解析要恢复的文件
resolve_backup_file() {
  local sel="$1"
  local pattern="$BACKUP_DIR/${APP}-*.tar.gz"

  if [[ -z "$sel" ]]; then
    # 交互式选择（bash 3.2 无 mapfile，用 while read）
    local list=()
    while IFS= read -r line; do
      list+=("$line")
    done < <(ls -1t $pattern 2>/dev/null || true)

    if [[ ${#list[@]} -eq 0 ]]; then
      err "$APP 没有任何备份"
      return 1
    fi
    echo "请选择要恢复的 $APP 备份：" >&2
    local i=0
    local f
    for f in "${list[@]}"; do
      i=$((i+1))
      local size mtime
      size="$(du -h "$f" | awk '{print $1}')"
      mtime="$(date -r "$f" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || stat -c '%y' "$f" 2>/dev/null | cut -d. -f1)"
      printf "  [%s] %s  %s  %s\n" "$i" "$(basename "$f")" "$size" "$mtime" >&2
    done
    local idx=""
    read -r -p "输入序号 (1-${#list[@]}): " idx </dev/tty
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#list[@]} )); then
      err "无效的序号: $idx"
      return 1
    fi
    echo "${list[$((idx-1))]}"
    return 0
  fi

  if [[ "$sel" == "latest" ]]; then
    local latest
    # shellcheck disable=SC2086
    latest="$(ls -1t $pattern 2>/dev/null | head -1 || true)"
    if [[ -z "$latest" ]]; then
      err "$APP 没有任何备份"; return 1
    fi
    echo "$latest"
    return 0
  fi

  # 显式文件名 / 路径
  if [[ -f "$sel" ]]; then
    echo "$sel"; return 0
  fi
  if [[ -f "$BACKUP_DIR/$sel" ]]; then
    echo "$BACKUP_DIR/$sel"; return 0
  fi
  # 尝试用 basename 在 BACKUP_DIR 中查找
  local bn
  bn="$(basename "$sel")"
  if [[ -f "$BACKUP_DIR/$bn" ]]; then
    echo "$BACKUP_DIR/$bn"; return 0
  fi
  err "找不到备份文件: $sel"
  return 1
}

BACKUP_FILE="$(resolve_backup_file "$CHOICE")" || exit 1
log "将从此备份恢复: $BACKUP_FILE"

# 校验文件名前缀跟 app 匹配（防止误操作）
base="$(basename "$BACKUP_FILE")"
if [[ "$base" != "${APP}-"*".tar.gz" && "$base" != "pre-restore-${APP}-"*".tar.gz" ]]; then
  warn "文件名 $base 与 app '$APP' 不匹配"
  if [[ "$ASSUME_YES" -eq 0 ]]; then
    read -r -p "仍然继续? [y/N]: " ans </dev/tty
    case "$ans" in
      y|Y|yes|YES) ;;
      *) log "已取消"; exit 0 ;;
    esac
  fi
fi

# 展示将会覆盖的路径
PATHS="$(app_paths "$APP")"
echo
log "将覆盖以下目录（相对 ${PROJECT_ROOT}）："
for p in $PATHS; do
  full="$PROJECT_ROOT/$p"
  if [[ -e "$full" ]]; then
    echo "  - $p  (已存在)"
  else
    echo "  - $p  (不存在，将会新建)"
  fi
done

if [[ "$ASSUME_YES" -eq 0 ]]; then
  echo
  read -r -p "确认恢复? 这会覆盖现有数据 [y/N]: " ans </dev/tty
  case "$ans" in
    y|Y|yes|YES) ;;
    *) log "已取消"; exit 0 ;;
  esac
fi

# 检测 compose
COMPOSE_CMD=""
COMPOSE_FILE="$(app_compose "$APP")"
if [[ "$DO_STOP" -eq 1 ]]; then
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
  else
    err "启用了 --stop 但未找到 docker compose"
    exit 1
  fi
fi

# 1) 停容器
stopped=0
if [[ "$DO_STOP" -eq 1 && -n "$COMPOSE_FILE" && -f "$PROJECT_ROOT/$COMPOSE_FILE" ]]; then
  log "停止 $APP 容器..."
  (cd "$PROJECT_ROOT" && $COMPOSE_CMD -f "$COMPOSE_FILE" stop) || warn "停止失败，继续恢复"
  stopped=1
fi

# 2) 安全备份当前数据
SAFETY_FILE=""
if [[ "$DO_SAFETY" -eq 1 ]]; then
  mkdir -p "$BACKUP_DIR"
  SAFETY_TS="$(date +%Y%m%d-%H%M%S)"
  SAFETY_FILE="$BACKUP_DIR/pre-restore-${APP}-${SAFETY_TS}.tar.gz"
  existing=()
  for p in $PATHS; do
    [[ -e "$PROJECT_ROOT/$p" ]] && existing+=("$p")
  done
  if [[ ${#existing[@]} -gt 0 ]]; then
    log "安全备份当前数据到: $SAFETY_FILE"
    ( cd "$PROJECT_ROOT" && tar -czf "$SAFETY_FILE" "${existing[@]}" ) \
      || warn "安全备份失败，但会继续恢复"
  else
    log "当前无数据，跳过安全备份"
    SAFETY_FILE=""
  fi
else
  warn "已跳过安全备份 (--no-safety)"
fi

# 3) 清空目标目录
for p in $PATHS; do
  full="$PROJECT_ROOT/$p"
  if [[ -e "$full" ]]; then
    log "清空: $p"
    find "$full" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  else
    log "创建: $p"
    mkdir -p "$full"
  fi
done

# 4) 解压恢复
log "解压 $BACKUP_FILE -> $PROJECT_ROOT"
tar -xzf "$BACKUP_FILE" -C "$PROJECT_ROOT"

# 5) 重启容器
if [[ "$stopped" -eq 1 ]]; then
  log "启动 $APP 容器..."
  (cd "$PROJECT_ROOT" && $COMPOSE_CMD -f "$COMPOSE_FILE" start) || warn "启动失败，请手动检查"
fi

log "恢复完成 ✅"
log "  app:    $APP"
log "  source: $BACKUP_FILE"
if [[ -n "$SAFETY_FILE" && -f "$SAFETY_FILE" ]]; then
  log "  回滚:   若需回滚，可执行"
  echo "         ./scripts/restore-apps.sh --no-safety $APP $(basename "$SAFETY_FILE")"
fi
