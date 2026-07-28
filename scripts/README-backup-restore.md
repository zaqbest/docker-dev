# 应用数据备份 / 恢复

两个脚本：

| 脚本 | 作用 |
| --- | --- |
| `scripts/backup-apps.sh`  | 把每个 app 的数据目录打包到 `backup/`，命名 `{appname}-{时间戳}.tar.gz`，每个 app **最多保留 5 份**（可配置） |
| `scripts/restore-apps.sh` | 从 `backup/` 恢复某个 app 的数据 |

> 备份目录默认：项目根下的 `backup/`（已加入 `.gitignore`）
> 时间戳格式：`YYYYmmdd-HHMMSS`（例如 `mysql-20260728-153000.tar.gz`）

---

## 支持的 app（数据目录）

脚本内部维护了 app -> 数据路径 的映射，来源就是各 `docker-compose-*.yml` 的 volumes：

| app            | 数据路径                                              | Compose 文件 |
| -------------- | ----------------------------------------------------- | ------------ |
| consul         | `consul/data`                                         | docker-compose-consul.yml |
| danmu-server   | `danmu-server/config`                                 | docker-compose-danmu-server.yml |
| elasticsearch  | `elasticsearch/data`                                  | docker-compose-elasticsearch.yml |
| h2             | `h2/data`                                             | docker-compose-h2.yml |
| kafka          | `kafka/data`                                          | docker-compose-kafka.yml |
| mysql          | `mysql/data`                                          | docker-compose-mysql.yml |
| nexus          | `nexus/data`                                          | docker-compose-nexus.yml |
| solr           | `solr/data`  `solr/zk/data`  `solr/zk/datalog`        | docker-compose-solr.yml |

> nginx 没有持久化数据（所有配置来自模板），不在备份列表。

查看清单：

```bash
./scripts/backup-apps.sh -l
```

---

## 1. 备份 backup-apps.sh

### 备份单个 / 多个 app

```bash
./scripts/backup-apps.sh mysql
./scripts/backup-apps.sh mysql nexus consul
```

产物：`backup/mysql-20260728-153000.tar.gz` ...

### 备份全部 app

```bash
./scripts/backup-apps.sh --all
```

### 一致性备份（推荐用于 mysql / es / kafka 等）

`--stop` 会在备份前 `docker compose stop`，备份完成后再 `start`：

```bash
./scripts/backup-apps.sh --all --stop
```

### 修改保留份数

默认每个 app 保留最近 **5 份**，超出的自动删掉最旧的：

```bash
./scripts/backup-apps.sh --all -k 10
```

### 修改输出目录

```bash
./scripts/backup-apps.sh --all -o /data/backups
```

### 全部选项

```
--all              备份所有已注册的 app
--stop             备份前 docker compose stop，备份后再 start
-k, --keep N       每个 app 最多保留 N 份（默认 5）
-o, --output DIR   备份输出目录（默认 <project>/backup）
-l, --list         列出所有可备份的 app
-h, --help         显示帮助
```

### 结合 cron 定时备份

```cron
# 每天凌晨 3 点全量备份，保留最近 7 份
0 3 * * * cd /path/to/docker-kit && ./scripts/backup-apps.sh --all -k 7 --stop >> backup/cron.log 2>&1
```

---

## 2. 恢复 restore-apps.sh

### 查看备份列表

```bash
./scripts/restore-apps.sh -l              # 全部
./scripts/restore-apps.sh -l mysql        # 只看 mysql
```

### 恢复最新一份

```bash
./scripts/restore-apps.sh mysql latest --stop
```

`--stop` 会在恢复前后自动停/启对应容器（**强烈推荐**，否则运行中的数据库/ES 会把恢复的文件搞坏）。

### 交互式选择某一份

```bash
./scripts/restore-apps.sh mysql
# 输出：
#   [1] mysql-20260728-153000.tar.gz   120M   2026-07-28 15:30:00
#   [2] mysql-20260727-030000.tar.gz   118M   2026-07-27 03:00:00
#   ...
# 请输入序号: 2
```

### 指定文件

```bash
./scripts/restore-apps.sh nexus nexus-20260728-153000.tar.gz --stop -y
# 或用绝对路径
./scripts/restore-apps.sh nexus /path/to/nexus-xxx.tar.gz --stop -y
```

### 安全备份（默认开启）

恢复前，脚本会**先**把当前的数据打包到 `backup/pre-restore-{app}-{timestamp}.tar.gz`。
如果恢复出问题，可以立刻回滚：

```bash
./scripts/restore-apps.sh --no-safety mysql pre-restore-mysql-20260728-160000.tar.gz -y
```

如果确定不需要，加 `--no-safety` 跳过。

### 全部选项

```
--stop           恢复前 docker compose stop，恢复后再 start
--no-safety      跳过"恢复前先把现存数据打包保存"
-y, --yes        跳过所有确认
-o, --output DIR backup 目录（默认 <project>/backup）
-l, --list       列出备份（可指定 app）
-h, --help       显示帮助
```

---

## 3. 完整示例

### 场景 A：日常备份 & 事故回滚

```bash
# 备份
./scripts/backup-apps.sh --all --stop

# 出事故了，回滚 mysql 到最新一份备份
./scripts/restore-apps.sh mysql latest --stop -y
```

### 场景 B：把数据从机器 A 迁到机器 B

在机器 A：
```bash
./scripts/backup-apps.sh --all --stop
scp backup/*.tar.gz user@B:/path/to/docker-kit/backup/
```

在机器 B（已有相同的 docker-compose 环境，容器可未启动）：
```bash
./scripts/restore-apps.sh mysql latest -y
./scripts/restore-apps.sh nexus latest -y
./scripts/restore-apps.sh elasticsearch latest -y
# ... 或者写个循环
for app in mysql nexus elasticsearch consul solr h2 kafka danmu-server; do
  ./scripts/restore-apps.sh "$app" latest -y --no-safety
done

# 启动
docker compose -f docker-compose-mysql.yml up -d
# ...
```

---

## 4. 注意事项

1. **一致性**：数据库 / ES / Kafka 等运行中直接 `tar` 数据目录**不保证一致性**，请配合 `--stop`。
2. **权限**：解压后的文件属主可能是宿主机的用户，如果容器内进程需要特定 UID（比如 elasticsearch 是 1000），恢复后可能要 `chown -R 1000:0 elasticsearch/data`。
3. **备份加密**：脚本没做加密。如果 backup 目录会流出机器，请自行 `gpg -c` 或放到加密卷。
4. **大小估算**：`nexus/data`、`elasticsearch/data` 可能很大，注意磁盘空间。