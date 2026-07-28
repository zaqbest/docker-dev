#!/usr/bin/env bash
#
# docker-image-export.sh
#
# 从 Docker Hub（或其它 registry）拉取一个或多个镜像，然后打包成 tar 文件，
# 便于拷贝到目标机器再 import/load。
#
# 用法:
#   ./docker-image-export.sh [选项] <image[:tag]> [image[:tag] ...]
#
# 选项:
#   -o, --output <dir>          输出目录，默认 ./image-bundles
#   -p, --platform <platform>   指定平台，如 linux/amd64、linux/arm64
#   -f, --file <list-file>      从文件读取镜像列表（每行一个）
#   -s, --single <name.tar>     把所有镜像打包成一个 tar（使用 docker save 多镜像模式）
#   -z, --gzip                  额外用 gzip 压缩 (.tar.gz)
#       --no-pull               跳过 docker pull，直接使用本地镜像
#   -h, --help                  显示帮助
#
# 示例:
#   ./docker-image-export.sh nginx:1.27 redis:7
#   ./docker-image-export.sh -p linux/amd64 -z nginx:1.27
#   ./docker-image-export.sh -f images.txt -s all-images.tar -z
#

set -euo pipefail

OUTPUT_DIR="./image-bundles"
PLATFORM=""
LIST_FILE=""
SINGLE_TAR=""
GZIP=0
NO_PULL=0
IMAGES=()

usage() {
  sed -n '2,30p' "$0"
  exit 0
}

log()  { echo -e "\033[1;32m[INFO]\033[0m  $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)    OUTPUT_DIR="$2"; shift 2 ;;
    -p|--platform)  PLATFORM="$2"; shift 2 ;;
    -f|--file)      LIST_FILE="$2"; shift 2 ;;
    -s|--single)    SINGLE_TAR="$2"; shift 2 ;;
    -z|--gzip)      GZIP=1; shift ;;
    --no-pull)      NO_PULL=1; shift ;;
    -h|--help)      usage ;;
    -*)
      err "未知选项: $1"; exit 1 ;;
    *)
      IMAGES+=("$1"); shift ;;
  esac
done

# 从文件读取镜像列表
if [[ -n "$LIST_FILE" ]]; then
  if [[ ! -f "$LIST_FILE" ]]; then
    err "镜像列表文件不存在: $LIST_FILE"; exit 1
  fi
  while IFS= read -r line; do
    # 去掉注释和空行
    line="${line%%#*}"
    line="$(echo "$line" | xargs || true)"
    [[ -z "$line" ]] && continue
    IMAGES+=("$line")
  done < "$LIST_FILE"
fi

if [[ ${#IMAGES[@]} -eq 0 ]]; then
  err "必须至少指定一个镜像，或用 -f 提供列表"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  err "未找到 docker 命令"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

# 生成合法文件名: nginx:1.27 -> nginx_1.27.tar,  ghcr.io/x/y:z -> ghcr.io_x_y_z.tar
safe_name() {
  local img="$1"
  echo "$img" | sed -e 's#[/:@]#_#g'
}

# 1) 拉取镜像
if [[ "$NO_PULL" -eq 0 ]]; then
  for img in "${IMAGES[@]}"; do
    if [[ -n "$PLATFORM" ]]; then
      log "拉取镜像: $img (platform=$PLATFORM)"
      docker pull --platform "$PLATFORM" "$img"
    else
      log "拉取镜像: $img"
      docker pull "$img"
    fi
  done
else
  warn "已启用 --no-pull，跳过 docker pull"
fi

# 2) 保存镜像
MANIFEST="$OUTPUT_DIR/manifest.txt"
: > "$MANIFEST"
{
  echo "# 由 docker-image-export.sh 生成"
  echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
  [[ -n "$PLATFORM" ]] && echo "# platform: $PLATFORM"
  echo "# 使用方法: 在目标机器上执行 docker-image-import.sh 对应文件"
  echo ""
} >> "$MANIFEST"

save_one() {
  local out_file="$1"; shift
  log "保存镜像到: $out_file"
  docker save -o "$out_file" "$@"
  if [[ "$GZIP" -eq 1 ]]; then
    log "gzip 压缩: $out_file"
    gzip -f "$out_file"
    out_file="${out_file}.gz"
  fi
  local size
  size="$(du -h "$out_file" | awk '{print $1}')"
  log "完成: $out_file ($size)"
  echo "$out_file  <-  $*" >> "$MANIFEST"
}

if [[ -n "$SINGLE_TAR" ]]; then
  # 合并为一个 tar
  out="$OUTPUT_DIR/$SINGLE_TAR"
  save_one "$out" "${IMAGES[@]}"
else
  for img in "${IMAGES[@]}"; do
    name="$(safe_name "$img")"
    out="$OUTPUT_DIR/${name}.tar"
    save_one "$out" "$img"
  done
fi

log "全部完成！输出目录: $OUTPUT_DIR"
log "清单文件:       $MANIFEST"
echo
log "拷贝示例:"
echo "  scp -r \"$OUTPUT_DIR\" user@target-host:/tmp/"
echo
log "目标机器导入示例:"
echo "  ./docker-image-import.sh /tmp/$(basename "$OUTPUT_DIR")"