# Homelab

[English](README.md)

使用 CUE 管理多台服务器的 Docker Compose 配置，并通过 GitHub Actions 和 SSH 完成部署。

仓库只保存部署结构和环境变量示例。真实密码、Token 和私钥应保存在 GitHub Secrets 或服务器的 `/srv/homelab/env/` 中。

## 工作方式

```text
config/*.cue
  -> compose.yaml、Caddyfile、镜像清单、env 示例
  -> GitHub Actions 拉取固定版本镜像
  -> 通过 SSH 传输镜像和 release
  -> docker compose up -d
```

- `primary` 和 `secondary` 是两台示例主机。
- 镜像必须固定到 digest 或不可变的 `sha-*` 标签。
- 部署只允许从 GitHub Actions 手动触发。
- 缺少生产 env 时会在修改容器前停止部署。
- `/srv/homelab/current` 指向当前运行版本。

## 1. 创建自己的仓库

在 GitHub 页面点击 **Fork**，然后克隆你的仓库：

```bash
gh repo clone YOUR_NAME/homelab
cd homelab
```

公开仓库的 Fork 仍然是公开的。如果生产配置需要保密，请使用 GitHub 的 **Import repository** 页面，选择 `Private`，并导入：

```text
https://github.com/Honahec/homelab.git
```

部署前修改示例配置：

- 替换 `config/*.cue` 中的 `example.com` 和 `ops@example.com`。
- 用自己的服务替换示例服务。
- 修改 `cue.mod/module.cue` 中的仓库地址。
- 只有一台服务器时，从 schema、生成脚本和 workflows 中删除 `secondary`。

## 2. 本地验证

安装 CUE `v0.17.0`：

```bash
GOBIN="$HOME/.local/bin" go install cuelang.org/go/cmd/cue@v0.17.0
```

运行检查：

```bash
cue fmt config/*.cue
cue vet ./config
go test ./...
go build ./cmd/homelab
sh -n ops/*.sh tools/*.sh
git diff --check
```

`Validate` workflow 会在 push 和 pull request 时执行相同的配置检查。

`homelab` CLI 负责配置生成和镜像传输。CUE 仍然是配置唯一来源，Go CLI
替代了原来由 shell 完成的 JSON/YAML 解析和镜像传输编排：

```bash
go run ./cmd/homelab generate --output /tmp/homelab-generated \
  --hosts primary,secondary
go run ./cmd/homelab transfer-images \
  --manifest /tmp/homelab-generated/primary/images.txt \
  --destination deploy@example.com --port 22 --sudo sudo
```

## 3. 初始化服务器

服务器需要：

- Linux `amd64`
- Docker Engine 和 Compose plugin
- 可免密码执行 `sudo` 的专用 SSH 用户
- 至少 4 GiB 可用磁盘空间
- 已配置 DNS 和防火墙端口

创建目录，并使用服务器有权读取的地址克隆仓库：

```bash
sudo install -d -m 755 \
  /srv/homelab/env \
  /srv/homelab/data \
  /srv/homelab/runtime \
  /srv/homelab/releases
sudo install -d -m 700 /srv/homelab/backups
sudo git clone https://github.com/YOUR_NAME/homelab.git /srv/homelab/stack
```

私有仓库需要先在服务器配置只读 Deploy Key。

按服务器角色创建主机 env 文件：

```bash
# 每台服务器只执行对应的一条命令。
sudo install -m 600 /dev/null /srv/homelab/env/primary.env
sudo install -m 600 /dev/null /srv/homelab/env/secondary.env
```

## 4. 配置 GitHub

在 **Settings → Environments** 创建 `production` Environment。

- Primary Secret：`PRIMARY_SSH_KEY`
- Primary Variables：`PRIMARY_HOST`、`PRIMARY_PORT`、`PRIMARY_USER`
- Secondary Secret：`SECONDARY_SSH_KEY`
- Secondary Variables：`SECONDARY_HOST`、`SECONDARY_PORT`、`SECONDARY_USER`

部署应使用专用 SSH key。如果配置引用私有 GHCR 镜像，还需要：

- Secret：`GHCR_TOKEN`，只授予 package read 权限
- Variable：`GHCR_USERNAME`

## 5. 部署

1. 将域名 DNS 指向目标服务器。
2. 推送配置修改。
3. 打开 **Actions → Deploy → Run workflow**。
4. 在服务器检查：

```bash
sudo docker compose \
  --env-file /srv/homelab/env/primary.env \
  -f /srv/homelab/current/compose.yaml \
  ps
```

如果应用 env 不存在，workflow 只会上传 candidate，不会修改当前容器。根据生成的示例创建 env 后重新部署：

```bash
sudo install -m 600 \
  /srv/homelab/candidate/example-app.env.example \
  /srv/homelab/env/example-app.env
sudoedit /srv/homelab/env/example-app.env
```

## 修改服务

编辑 `config/primary.cue` 或 `config/secondary.cue`。仓库中的 `web` 服务是最小示例。

基本规则：

- 镜像必须固定到 digest 或 `sha-*` 标签，不要使用 `latest`。
- 需要被 Caddy 访问的服务加入 `edge` 网络。
- 数据库内部流量使用 `backend` 网络。
- 持久数据放在 `/srv/homelab/data/<service>/`。
- 没有必要时不要暴露端口；需要宿主机访问时优先绑定 `127.0.0.1`。
- CUE 只保存占位值，真实值写入权限为 `600` 的服务器 env。
- PostgreSQL 应用设置 `database: true`，并提供 `DB_NAME`、`DB_USER`、`DB_PASSWORD` 和 `DATABASE_URL`。

## 同步公共仓库更新

GitHub Fork 可以直接在仓库页面点击 **Sync fork → Update branch**。

需要本地解决冲突，或使用私有 Import 仓库时：

```bash
git remote add upstream https://github.com/Honahec/homelab.git
git fetch upstream
git merge upstream/main
```

解决私有配置中的冲突，重新运行验证，然后正常 push。

## 数据库备份

```bash
sudo /srv/homelab/stack/ops/backup.sh \
  primary /srv/homelab/current example_app postgres
```

`ops/restore.sh` 只恢复到临时数据库进行校验，不会覆盖生产数据库。

## 安全约定

- 不要提交密码、Token、私钥、服务器 IP 或内部域名。
- 生产 env 只保存在服务器，权限固定为 `600`。
- 使用专用且权限受限的部署凭据。
- 更新镜像 digest 后先检查和验证，再执行部署。
