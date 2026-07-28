#!/usr/bin/env bash
#
# docker-image-import.sh
#
# 在目标机器上把 docker-image-export.sh 生成的 tar / tar.gz 镜像文件 load 进 docker。
#
# 用法:
#   ./docker-image-import.sh [选项] <文件或目录> [<文件或目录> ...]
#
# 选项:
#   -l, --list             只列出将要导入的文件，不实际导入
#   -k, --skip-existing    如果镜像已存在则跳过（通过读取 tar 中的 manifest.json 判断）
#   -i, --interactive      每个文件都询问是否导入（y/n/a=全部/q=退出）
#   -h, --help             显示帮助
#
# 支持:
#   - *.tar
#   - *.tar.gz / *.tgz
#   - 目录（递归查找上述文件）
#
# 示例:
#   ./docker-image-import.sh /tmp/image-bundles
#   ./docker-image-import.sh -k /tmp/image-bundles                # 跳过已存在
#   ./docker-image-import.sh -i /tmp/image-bundles                # 交互式选择
#   ./docker-image-import.sh -l /tmp/image-bundles                # 只列出
#   ./docker-image-import.sh nginx_1.27.tar redis_7.tar.gz        # 指定单个/多个文件
#

set -euo pipefail

log()  { echo -e "\033[1;32m[INFO]\033[0m  $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

LIST_ONLY=0
SKIP_EXISTING=0
INTERACTIVE=0
POSITIONAL=()

usage() { sed -n '2,30p' "$0"; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -l|--list)          LIST_ONLY=1; shift ;;
    -k|--skip-existing) SKIP_EXISTING=1; shift ;;
    -i|--interactive)   INTERACTIVE=1; shift ;;
    -h|--help)          usage ;;
    -*)                 err "未知选项: $1"; exit 1 ;;
    *)                  POSITIONAL+=("$1"); shift ;;
  esac
done

if [[ ${#POSITIONAL[@]} -eq 0 ]]; then
  err "用法: $0 [选项] <文件或目录> [...]"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  err "未找到 docker 命令"; exit 1
fi

FILES=()

collect() {
  local p="$1"
  if [[ -d "$p" ]]; then
    while IFS= read -r -d '' f; do
      FILES+=("$f")
    done < <(find "$p" -type f \( -name '*.tar' -o -name '*.tar.gz' -o -name '*.tgz' \) -print0 | sort -z)
  elif [[ -f "$p" ]]; then
    FILES+=("$p")
  else
    warn "跳过不存在的路径: $p"
  fi
}

for arg in "${POSITIONAL[@]}"; do
  collect "$arg"
done

if [[ ${#FILES[@]} -eq 0 ]]; then
  err "没有找到可导入的镜像文件"
  exit 1
fi

# 读取 tar 内的 manifest.json，得到 RepoTags（可能有多个）
# 输出格式：每行一个 tag
read_repo_tags() {
  local f="$1"
  local cmd
  case "$f" in
    *.tar.gz|*.tgz) cmd="gunzip -c \"$f\"" ;;
    *.tar)          cmd="cat \"$f\"" ;;
    *)              return 1 ;;
  esac
  # tar 里 manifest.json 一般在根目录
  eval "$cmd" 2>/dev/null | tar -xO manifest.json 2>/dev/null \
    | tr ',' '\n' \
    | grep -oE '"[^"]+:[^"]+"' \
    | tr -d '"' \
    | grep -v '^sha256:' \
    | grep -E '.+:.+' || true
}

image_exists() {
  local tag="$1"
  docker image inspect "$tag" >/dev/null 2>&1
}

log "共找到 ${#FILES[@]} 个镜像文件"

if [[ "$LIST_ONLY" -eq 1 ]]; then
  echo
  printf "%-6s %-45s %s\n" "序号" "文件" "镜像 tag"
  echo "-------------------------------------------------------------------------------"
  i=0
  for f in "${FILES[@]}"; do
    i=$((i+1))
    tags="$(read_repo_tags "$f" | paste -sd, - || true)"
    [[ -z "$tags" ]] && tags="(未识别)"
    printf "%-6s %-45s %s\n" "$i" "$(basename "$f")" "$tags"
  done
  exit 0
fi

ALL_YES=0

for f in "${FILES[@]}"; do
  tags="$(read_repo_tags "$f" | paste -sd, - || true)"

  # 跳过已存在
  if [[ "$SKIP_EXISTING" -eq 1 && -n "$tags" ]]; then
    all_present=1
    IFS=',' read -ra arr <<< "$tags"
    for t in "${arr[@]}"; do
      if ! image_exists "$t"; then all_present=0; break; fi
    done
    if [[ "$all_present" -eq 1 ]]; then
      warn "跳过（已存在）: $(basename "$f")  [$tags]"
      continue
    fi
  fi

  # 交互式
  if [[ "$INTERACTIVE" -eq 1 && "$ALL_YES" -eq 0 ]]; then
    echo
    echo "文件: $(basename "$f")"
    echo "Tag : ${tags:-(未识别)}"
    read -r -p "是否导入? [y]es / [n]o / [a]ll / [q]uit: " ans </dev/tty
    case "${ans,,}" in
      y|yes|"") ;;
      n|no)     warn "跳过: $(basename "$f")"; continue ;;
      a|all)    ALL_YES=1 ;;
      q|quit)   log "用户退出"; exit 0 ;;
      *)        warn "未知输入，跳过"; continue ;;
    esac
  fi

  log "导入: $f  ${tags:+[$tags]}"
  case "$f" in
    *.tar.gz|*.tgz) gunzip -c "$f" | docker load ;;
    *.tar)          docker load -i "$f" ;;
    *)              warn "未知格式，跳过: $f" ;;
  esac
done

log "全部处理完成，当前镜像列表如下（最近若干个）:"
docker images | head -n 20
