#!/bin/bash

set -e

echo "========================================="
echo "  Gitea Git 服务 Setup"
echo "========================================="

# 检查 docker 是否可用
if ! command -v docker &> /dev/null; then
    echo "Error: docker is not installed or not in PATH"
    exit 1
fi

# 创建网络（如果不存在）
bash scripts/create-network.sh

# 检查 env/gitea.env 是否存在
if [ ! -f "env/gitea.env" ]; then
    echo "Error: env/gitea.env not found!"
    exit 1
fi

# 启动数据库
echo ""
echo "Starting Gitea database (PostgreSQL)..."
docker compose -f docker-compose-gitea.yml up -d gitea-db

# 等待数据库就绪
echo ""
echo "Waiting for PostgreSQL to be ready..."
max_attempts=20
attempt=0
while [ $attempt -lt $max_attempts ]; do
    if docker compose -f docker-compose-gitea.yml exec gitea-db \
        pg_isready -U "${GITEA_DB_USER:-gitea}" -d "${GITEA_DB_NAME:-gitea}" > /dev/null 2>&1; then
        echo "✓ PostgreSQL is ready!"
        break
    fi
    attempt=$((attempt + 1))
    echo "  Attempt $attempt/$max_attempts - Database not ready yet, waiting..."
    sleep 5
done

if [ $attempt -eq $max_attempts ]; then
    echo "Error: PostgreSQL failed to start. Please check logs:"
    echo "  docker compose -f docker-compose-gitea.yml logs gitea-db"
    exit 1
fi

# 启动 Gitea
echo ""
echo "Starting Gitea..."
docker compose -f docker-compose-gitea.yml up -d gitea

# 等待 Gitea 启动
echo ""
echo "Waiting for Gitea to start..."
max_attempts=30
attempt=0
while [ $attempt -lt $max_attempts ]; do
    if docker compose -f docker-compose-gitea.yml exec gitea \
        curl -sf http://localhost:3000/-/health > /dev/null 2>&1; then
        echo "✓ Gitea is ready!"
        break
    fi
    attempt=$((attempt + 1))
    echo "  Attempt $attempt/$max_attempts - Gitea not ready yet, waiting..."
    sleep 10
done

if [ $attempt -eq $max_attempts ]; then
    echo "Warning: Gitea may not be fully ready. Please check:"
    echo "  docker compose -f docker-compose-gitea.yml logs gitea"
fi

GITEA_HTTP_PORT_VAL=${GITEA_HTTP_PORT:-3000}
GITEA_SSH_PORT_VAL=${GITEA_SSH_PORT:-2222}

echo ""
echo "========================================="
echo "  Gitea Setup Complete!"
echo "========================================="
echo ""
echo "  Web UI : http://localhost:${GITEA_HTTP_PORT_VAL}"
echo "  SSH    : ssh://git@localhost:${GITEA_SSH_PORT_VAL}"
echo ""
echo "首次访问请通过 Web 界面完成安装向导，创建管理员账号。"
echo ""
echo "常用命令："
echo "  查看日志 : docker compose -f docker-compose-gitea.yml logs -f"
echo "  停止服务 : docker compose -f docker-compose-gitea.yml down"
echo "  重启服务 : docker compose -f docker-compose-gitea.yml restart"
echo ""
