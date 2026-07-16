# Homelab Deployment Template

用 CUE 维护多台服务器的 Docker Compose 配置，通过 GitHub Actions 生成部署产物、传输固定版本镜像，并经 SSH 发布到服务器。仓库只保存配置结构和环境变量示例；密码、Token 与私钥始终留在 GitHub Secrets 或服务器 `/srv/homelab/env/`。

## 工作方式

```text
config/*.cue
    └─ cue vet / export
       ├─ compose.yaml
       ├─ Caddyfile
       ├─ images.txt
       └─ *.env.example
            └─ GitHub Actions 拉取镜像并通过 SSH 传输
                 └─ /srv/homelab/releases/<git-sha>
                      └─ docker compose up -d
```

- `primary`、`secondary` 是两台示例主机，可按需改名或删除。
- 镜像必须固定到 digest 或 `sha-*` 标签，服务器不需要保存镜像仓库凭据。
- Caddy、Compose 与 env 示例由 CI 临时生成，不提交生成物。
- 部署前检查生产 env 是否存在且权限为 `600`；不满足时只上传 candidate，不改动现有容器。
- `/srv/homelab/current` 指向成功部署版本，`/srv/homelab/candidate` 指向最近一次尝试版本。

## 前置条件

本地：

- Git
- Go
- CUE `v0.17.0`
- `jq`
- Docker 与 Docker Compose（需要在本地完整验证时）

服务器：

- Linux `amd64`
- Docker Engine 与 Compose plugin
- 可 SSH 登录、可免密码执行 `sudo` 的部署用户
- 至少 4 GiB 可用磁盘空间
- 已放行 TCP 80/443 和 UDP 443；DNS 已指向服务器

安装固定版本 CUE：

```bash
GOBIN="$HOME/.local/bin" go install cuelang.org/go/cmd/cue@v0.17.0
cue version
```

## 1. 创建自己的仓库

Fork 本仓库，或从模板复制后初始化 Git。首先替换示例内容：

```bash
rg 'example\.com|ops@example\.com' config README.md
```

至少需要修改：

- `config/primary.cue` 和 `config/secondary.cue` 中的域名、ACME 邮箱与服务。
- `cue.mod/module.cue` 中的 module 地址。
- 不需要第二台服务器时，同时从 `config/schema.cue`、`tools/generate.sh` 和两个 workflow 中删除 `secondary`。

示例域名不会为你工作，部署前必须换成自己控制的域名并配置 DNS。

## 2. 本地配置与验证

修改 CUE 后运行：

```bash
cue fmt config/*.cue
cue vet ./config
sh -n ops/*.sh tools/*.sh
git diff --check
```

查看实际生成结果：

```bash
tmp=$(mktemp -d)
./tools/generate.sh "$tmp/generated"
find "$tmp/generated" -maxdepth 2 -type f -print
docker compose \
  --env-file "$tmp/generated/primary/.env.example" \
  -f "$tmp/generated/primary/compose.yaml" \
  config
rm -rf "$tmp"
```

`Validate` workflow 会在 push 与 pull request 时重复执行这些检查。`Deploy` 只允许手动触发，避免刚复制仓库、尚未配置 Secrets 时误部署。

## 3. 初始化服务器

每台服务器安装 Docker 后，执行以下命令。把仓库地址替换为你自己的地址：

```bash
sudo install -d -m 755 \
  /srv/homelab/env \
  /srv/homelab/data \
  /srv/homelab/runtime \
  /srv/homelab/releases
sudo install -d -m 700 /srv/homelab/backups
sudo git clone https://github.com/YOUR_NAME/YOUR_REPO.git /srv/homelab/stack
```

为每台主机创建主机级 env。模板当前没有主机变量，因此文件可以为空，但必须存在且权限为 `600`：

```bash
# primary 服务器
sudo install -m 600 /dev/null /srv/homelab/env/primary.env

# secondary 服务器
sudo install -m 600 /dev/null /srv/homelab/env/secondary.env
```

确保部署用户能通过 SSH 登录，并允许无交互执行本仓库需要的 `sudo` 命令。建议使用专用用户和专用 SSH key，不要复用个人登录密钥。

## 4. 配置 GitHub Environment

在仓库的 `Settings → Environments` 创建 `production`，添加：

| 主机 | Secrets | Variables |
| --- | --- | --- |
| Primary | `PRIMARY_SSH_KEY` | `PRIMARY_HOST`, `PRIMARY_PORT`, `PRIMARY_USER` |
| Secondary | `SECONDARY_SSH_KEY` | `SECONDARY_HOST`, `SECONDARY_PORT`, `SECONDARY_USER` |

变量说明：

- `*_HOST`：服务器 IP 或 SSH 域名。
- `*_PORT`：SSH 端口，通常为 `22`。
- `*_USER`：部署用户名。
- `*_SSH_KEY`：对应部署用户公钥的私钥内容。

如果配置引用私有 GHCR 镜像，再添加：

- Secret：`GHCR_TOKEN`，只授予 package read 权限。
- Variable：`GHCR_USERNAME`。

公共镜像或当前仓库有权读取的 GHCR 镜像可直接使用默认 `GITHUB_TOKEN`。

## 5. 首次部署

1. 将域名 DNS 指向目标服务器。
2. 确认服务器上的 `/srv/homelab/stack` 是当前仓库 clone。
3. 确认主机 env 文件存在且权限为 `600`。
4. 打开 `Actions → Deploy → Run workflow` 手动部署。
5. 在服务器检查：

```bash
sudo readlink -f /srv/homelab/current
sudo docker ps
sudo docker compose \
  --env-file /srv/homelab/env/primary.env \
  -f /srv/homelab/current/compose.yaml \
  ps
```

若应用 env 尚未创建，Action 会显示“等待生产 env”。此时 release 已上传，但容器未变更。复制 candidate 中的示例并填写真实值：

```bash
sudo install -m 600 \
  /srv/homelab/candidate/example-app.env.example \
  /srv/homelab/env/example-app.env
sudoedit /srv/homelab/env/example-app.env
```

填写后再次手动运行 `Deploy`。

## 6. 添加服务

在目标主机的 `services` 中添加：

```cue
"example-app": {
	image: {
		source: "ghcr.io/example/example-app:sha-a1b2c3d"
		target: source
	}
	env: {
		PORT:       "3000"
		APP_SECRET: "replace-me"
	}
	compose: {
		env_file: [{
			path:     "/srv/homelab/env/example-app.env"
			required: false
		}]
		healthcheck: {
			test:         ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:3000/health"]
			interval:     "30s"
			timeout:      "10s"
			retries:      5
			start_period: "30s"
		}
		networks:  ["edge"]
		mem_limit: "256m"
	}
}
```

约定：

- `image.source` 必须是 digest 或 `sha-*` 标签；不要使用 `latest`。
- 需要被 Caddy 访问的服务加入 `edge` 网络。
- 只访问数据库的内部服务加入 `backend` 网络。
- 不需要从宿主机访问的端口不要写入 `ports`；确需暴露时优先绑定 `127.0.0.1`。
- 持久数据放在 `/srv/homelab/data/<service>/`。
- CUE 中的 env 只能放示例值；真实值写入服务器 env。

添加反向代理：

```cue
caddy: {
	email: "ops@example.com"
	proxySites: {
		"app.example.com": {service: "example-app", port: 3000}
	}
	routeSites: {}
}
```

## 7. 添加 PostgreSQL 应用

数据库应用设置 `database: true`，并提供四个标准变量：

```cue
database: true
env: {
	DB_NAME:      "example_app"
	DB_USER:      "example_app"
	DB_PASSWORD:  "replace-me"
	DATABASE_URL: "postgres://example_app:replace-me@postgres:5432/example_app"
}
compose: {
	depends_on: {"postgres": {condition: "service_healthy"}}
	networks: ["edge", "backend"]
}
```

目标主机还必须定义名为 `postgres` 的服务。部署时 `ops/init-databases.sh` 会按 env 文件创建或更新角色与数据库；仓库中的 `replace-me` 只用于生成示例。

## 8. 备份与恢复校验

数据库备份：

```bash
sudo /srv/homelab/stack/ops/backup.sh \
  primary /srv/homelab/current example_app postgres
```

恢复脚本默认只恢复到临时数据库并执行查询校验，不会覆盖生产库：

```bash
sudo /srv/homelab/stack/ops/restore.sh \
  primary /srv/homelab/current example_app \
  /srv/homelab/backups/database/<timestamp>/example_app.dump postgres
```

## 安全边界

- 不要向 CUE、workflow、README 或 Git 历史提交真实密码、Token、私钥、服务器 IP 和内部域名。
- 生产 env 只保存在服务器，权限固定为 `600`。
- GitHub SSH key 使用专用部署密钥并定期轮换。
- 镜像固定版本后再部署；更新 digest 应经过 pull request 和验证。
- 公开仓库适合保存可复用框架与示例，真实资产清单和生产拓扑应继续放在私有仓库。
