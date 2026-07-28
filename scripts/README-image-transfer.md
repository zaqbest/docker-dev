# Docker 镜像离线传输脚本

用于场景：**本地能访问 Docker Hub，但目标机器不能**。
在本地拉取镜像 → 打包成 tar → 上传到目标机器 → import 使用。

包含两个脚本：

| 脚本 | 运行位置 | 作用 |
| --- | --- | --- |
| `docker-image-export.sh` | 本地（可访问 Docker Hub） | `docker pull` + `docker save` 打包 |
| `docker-image-import.sh` | 目标机器 | `docker load` 导入 |

---

## 1. 本地导出 export

### 单个镜像

```bash
./scripts/docker-image-export.sh nginx:1.27
```

输出：`./image-bundles/nginx_1.27.tar`

### 多个镜像

```bash
./scripts/docker-image-export.sh nginx:1.27 redis:7 mysql:8.0
```

### 指定平台（Mac ARM 给 x86 服务器打包时非常重要）

```bash
./scripts/docker-image-export.sh -p linux/amd64 nginx:1.27 redis:7
```

### 使用镜像列表文件

`images.txt`：

```
# 一行一个镜像，# 开头为注释
nginx:1.27
redis:7
mysql:8.0
```

```bash
./scripts/docker-image-export.sh -f images.txt -p linux/amd64
```

### 每个镜像一个 tar（默认行为，推荐）

不加 `-s` 参数时，每个镜像都会导出成**独立**的 tar 文件，加 `-z` 可以再 gzip 压缩：

```bash
./scripts/docker-image-export.sh -f images.txt -p linux/amd64 -z
```

产物示例（每个镜像对应一个文件）：

```
image-bundles/
├── hashicorp_consul_1.22.7.tar.gz
├── bitnamilegacy_kafka_3.8.1.tar.gz
├── elasticsearch_8.19.14.tar.gz
├── kibana_8.19.14.tar.gz
├── mysql_8.0.31.tar.gz
├── nginx_1.30.3-alpine.tar.gz
├── sonatype_nexus3_3.94.0.tar.gz
├── solr_8.11.2.tar.gz
├── zookeeper_3.9.3.tar.gz
├── oscarfonts_h2_2.3.232.tar.gz
├── l429609201_misaka_danmu_server_v2.8.3.tar.gz
└── manifest.txt
```

好处：
- 可以只传输/导入你需要的那几个
- 某个文件损坏不会影响其他镜像
- 便于按需增量更新

### 打包成一个 tar 并 gzip 压缩（合并模式）

如果希望**一个文件**搞定，加 `-s`：

```bash
./scripts/docker-image-export.sh -f images.txt -p linux/amd64 \
    -s all-images.tar -z
```

输出：`./image-bundles/all-images.tar.gz`（多个镜像共享 layer，体积更小）

### 全部选项

```
-o, --output <dir>          输出目录，默认 ./image-bundles
-p, --platform <platform>   指定平台，如 linux/amd64、linux/arm64
-f, --file <list-file>      从文件读取镜像列表（每行一个）
-s, --single <name.tar>     所有镜像合并成一个 tar（docker save 多镜像模式）
-z, --gzip                  额外用 gzip 压缩 (.tar.gz)
    --no-pull               跳过 docker pull，直接使用本地已有镜像
-h, --help                  显示帮助
```

---

## 2. 上传到目标机器

```bash
# 整个目录一起传
scp -r ./image-bundles user@target-host:/tmp/

# 或者单个文件
scp ./image-bundles/all-images.tar.gz user@target-host:/tmp/

# 大文件推荐 rsync（可断点续传）
rsync -avzP ./image-bundles/ user@target-host:/tmp/image-bundles/
```

同时把 `scripts/docker-image-import.sh` 也传过去：

```bash
scp scripts/docker-image-import.sh user@target-host:/tmp/
```

---

## 3. 目标机器导入 import

```bash
chmod +x /tmp/docker-image-import.sh

# 【1】导入整个目录里的所有 tar/tar.gz
/tmp/docker-image-import.sh /tmp/image-bundles

# 【2】只导入指定的某一个或几个
/tmp/docker-image-import.sh /tmp/image-bundles/mysql_8.0.31.tar.gz
/tmp/docker-image-import.sh /tmp/image-bundles/mysql_8.0.31.tar.gz \
                            /tmp/image-bundles/nginx_1.30.3-alpine.tar.gz

# 【3】先看看目录里都有哪些镜像（不实际导入）
/tmp/docker-image-import.sh -l /tmp/image-bundles

# 【4】跳过已经存在的镜像（重复导入很有用）
/tmp/docker-image-import.sh -k /tmp/image-bundles

# 【5】交互式，一个个确认（y/n/a=全部/q=退出）
/tmp/docker-image-import.sh -i /tmp/image-bundles
```

### import 选项

```
-l, --list             只列出将要导入的文件（含 tag），不实际导入
-k, --skip-existing    如果镜像已存在则跳过
-i, --interactive      每个文件都询问是否导入
-h, --help             显示帮助
```

支持的文件类型：`*.tar`、`*.tar.gz`、`*.tgz`。
目录参数会**递归**查找所有匹配文件。

---

## 4. 常见问题

**Q: 目标机器是 x86_64，我在 Mac M1/M2 上打包，启动后报 exec format error？**
A: 一定要加 `-p linux/amd64`，让 `docker pull` 拉 amd64 平台镜像再打包。

**Q: 一个大 tar 好还是多个小 tar 好？**
A: 
- 多个小 tar：可以增量传输，某个坏了不影响其他；
- 单个大 tar（`-s`）：多个镜像共享 layer，体积更小，传输一次即可。
- 推荐一次性交付时使用 `-s all-images.tar -z`。

**Q: 目标机器 docker load 后镜像名不对？**
A: `docker save/load` 会**完整保留** repository:tag。如果 tag 是 `sha256:...` 那种（拉的是 digest），load 后会是 `<none>`，请使用带 tag 的镜像名。

**Q: 想要直接推到目标机器上的私有 registry？**
A: 这套脚本只做文件传输。如果目标机器上有 Nexus / Harbor / registry:2，也可以先 `docker load`，然后 `docker tag` + `docker push` 到内网 registry。

---

## 5. 完整示例：本项目所有镜像

项目根目录已经准备好 `images.txt`，包含所有 `docker-compose-*.yml` 使用的镜像。

### 方案 A：每个镜像一个文件（推荐，灵活）

```bash
# 本地打包（Mac ARM 给 x86 服务器）
./scripts/docker-image-export.sh -f images.txt -p linux/amd64 -z

# 上传（每个文件独立，可以只传需要的几个）
scp -r ./image-bundles scripts/docker-image-import.sh user@target:/tmp/

# 目标机器：查看清单
ssh user@target '/tmp/docker-image-import.sh -l /tmp/image-bundles'

# 目标机器：全部导入（跳过已存在）
ssh user@target 'chmod +x /tmp/docker-image-import.sh && \
                 /tmp/docker-image-import.sh -k /tmp/image-bundles'

# 或者只导入 mysql
ssh user@target '/tmp/docker-image-import.sh /tmp/image-bundles/mysql_8.0.31.tar.gz'
```

### 方案 B：合并成一个文件（简单，适合一次性交付）

```bash
./scripts/docker-image-export.sh \
    -f images.txt \
    -p linux/amd64 \
    -s docker-kit-images.tar \
    -z
# 生成 ./image-bundles/docker-kit-images.tar.gz

scp ./image-bundles/docker-kit-images.tar.gz scripts/docker-image-import.sh user@target:/tmp/
ssh user@target 'chmod +x /tmp/docker-image-import.sh && \
                 /tmp/docker-image-import.sh /tmp/docker-kit-images.tar.gz'
```

完成。
