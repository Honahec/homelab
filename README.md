# Homelab

[中文文档](README.zh.md)

CUE-managed Docker Compose deployments for multiple servers, delivered through
GitHub Actions and SSH.

The repository stores deployment structure and environment examples only.
Production secrets stay in GitHub Secrets or `/srv/homelab/env/` on the server.

## How it works

```text
config/*.cue
  -> compose.yaml, Caddyfile, image manifest, env examples
  -> GitHub Actions pulls pinned images
  -> images and release files are transferred over SSH
  -> docker compose up -d
```

- `primary` and `secondary` are example hosts.
- Images must use a digest or an immutable `sha-*` tag.
- Deployments are started manually from GitHub Actions.
- Missing production env files stop the deployment before containers are changed.
- `/srv/homelab/current` points to the active release.

## 1. Create your repository

Use **Fork** on GitHub, then clone your fork:

```bash
gh repo clone YOUR_NAME/homelab
cd homelab
```

Forks of public repositories are also public. If your production configuration
must be private, use GitHub's **Import repository** page instead, select
`Private`, and import:

```text
https://github.com/Honahec/homelab.git
```

Update the example configuration before deploying:

- Replace `example.com` and `ops@example.com` in `config/*.cue`.
- Replace the example services with your own services.
- Update `cue.mod/module.cue` for your repository.
- Remove `secondary` from the schema, generator, and workflows if you only use
  one server.

## 2. Validate locally

Install CUE `v0.17.0`:

```bash
GOBIN="$HOME/.local/bin" go install cuelang.org/go/cmd/cue@v0.17.0
```

Run the checks:

```bash
cue fmt config/*.cue
cue vet ./config
go test ./...
go build ./cmd/homelab
sh -n ops/*.sh tools/*.sh
git diff --check
```

The `Validate` workflow runs the same configuration checks on pushes and pull
requests.

The `homelab` CLI owns configuration generation and image transfer. It keeps
CUE as the source of truth while replacing the local JSON/YAML parsing and
image-transfer orchestration that used to live in shell scripts:

```bash
go run ./cmd/homelab generate --output /tmp/homelab-generated \
  --hosts primary,secondary
go run ./cmd/homelab transfer-images \
  --manifest /tmp/homelab-generated/primary/images.txt \
  --destination deploy@example.com --port 22 --sudo sudo
```

## 3. Prepare each server

Requirements:

- Linux `amd64`
- Docker Engine with the Compose plugin
- A dedicated SSH user with passwordless `sudo`
- At least 4 GiB of free disk space
- DNS records and required firewall ports configured

Create the directory layout and clone the repository using an URL the server
can read:

```bash
sudo install -d -m 755 \
  /srv/homelab/env \
  /srv/homelab/data \
  /srv/homelab/runtime \
  /srv/homelab/releases
sudo install -d -m 700 /srv/homelab/backups
sudo git clone https://github.com/YOUR_NAME/homelab.git /srv/homelab/stack
```

For a private repository, configure a read-only deploy key on the server before
cloning.

Create the host env file required by the example configuration:

```bash
# Run the matching command on each server.
sudo install -m 600 /dev/null /srv/homelab/env/primary.env
sudo install -m 600 /dev/null /srv/homelab/env/secondary.env
```

## 4. Configure GitHub

Create a `production` environment under **Settings → Environments**.

- Primary secret: `PRIMARY_SSH_KEY`
- Primary variables: `PRIMARY_HOST`, `PRIMARY_PORT`, `PRIMARY_USER`
- Secondary secret: `SECONDARY_SSH_KEY`
- Secondary variables: `SECONDARY_HOST`, `SECONDARY_PORT`, `SECONDARY_USER`

Use a dedicated SSH key for deployment. If the configuration references private
GHCR images, also add:

- Secret: `GHCR_TOKEN` with package read access
- Variable: `GHCR_USERNAME`

## 5. Deploy

1. Point your DNS records to the target server.
2. Push the configuration changes.
3. Open **Actions → Deploy → Run workflow**.
4. Check the deployment on the server:

```bash
sudo docker compose \
  --env-file /srv/homelab/env/primary.env \
  -f /srv/homelab/current/compose.yaml \
  ps
```

If an application env file is missing, the workflow uploads the candidate
release but leaves the running containers unchanged. Create the env file from
the generated example and deploy again:

```bash
sudo install -m 600 \
  /srv/homelab/candidate/example-app.env.example \
  /srv/homelab/env/example-app.env
sudoedit /srv/homelab/env/example-app.env
```

## Customizing services

Edit `config/primary.cue` or `config/secondary.cue`. The included `web` service
is a minimal example.

Keep these rules:

- Pin every image to a digest or `sha-*` tag; do not use `latest`.
- Put Caddy-facing services on the `edge` network.
- Put database-only traffic on the `backend` network.
- Keep persistent data under `/srv/homelab/data/<service>/`.
- Do not expose ports unless the host needs them; prefer `127.0.0.1` bindings.
- Store placeholders in CUE and real values in server env files with mode `600`.
- Set `database: true` for managed PostgreSQL applications and provide
  `DB_NAME`, `DB_USER`, `DB_PASSWORD`, and `DATABASE_URL`.

## Syncing upstream changes

For a GitHub fork, use **Sync fork → Update branch** on the repository page.

To merge locally, or when using a private imported repository:

```bash
git remote add upstream https://github.com/Honahec/homelab.git
git fetch upstream
git merge upstream/main
```

Resolve conflicts in your private configuration, run the validation commands,
and push normally.

## Database backup

```bash
sudo /srv/homelab/stack/ops/backup.sh \
  primary /srv/homelab/current example_app postgres
```

`ops/restore.sh` restores into a temporary database for verification. It does
not overwrite the production database.

## Security

- Never commit passwords, tokens, private keys, server IPs, or private hostnames.
- Keep production env files on the server with mode `600`.
- Use dedicated, limited deployment credentials.
- Review and validate image digest updates before deploying.
