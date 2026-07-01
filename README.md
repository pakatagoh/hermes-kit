# hermes-kit

Custom Docker image built on top of [Hermes Agent](https://github.com/NousResearch/hermes-agent),
configured to run in **gateway mode** and bundled with extra tools installed
declaratively via [mise](https://mise.jdx.dev).

Published to GHCR at `ghcr.io/pakatagoh/hermes-kit` and consumed by the homelab
k3s cluster via Flux image automation.

## Versions

| Component | Version |
| --------- | ------- |
| Image (this repo) | independent SemVer, e.g. `0.1.0` |
| Hermes Agent (base image) | `v2026.6.19` (see `Dockerfile` `HERMES_VERSION` ARG) |
| gh (GitHub CLI) | 2.95.0 (see [`mise.toml`](./mise.toml)) |
| ctx7 (Upstash Context7 CLI) | latest (npm: [`ctx7`](https://www.npmjs.com/package/ctx7)) |

The image has its **own** SemVer tag — it does **not** track the Hermes
version. Bumping Hermes (or any Dockerfile/mise change) is just a commit to
`main`; the [build workflow](./.github/workflows/docker-publish.yml)
publishes a new uniquely-tagged image to GHCR on every commit.

## Build & publish

Builds run automatically on push to `main` via GitHub Actions. The workflow:

1. Tags the image `<epoch-millis>-<short-sha>` (e.g. `1735689600123-abc1234`)
   — one tag per build, millisecond-grained and monotonic, with no `latest`.
2. Reads `ARG HERMES_VERSION` from the `Dockerfile` and passes it as a
   build-arg (so the base image is pinned in one place).
3. Prunes old image versions to stay within the GHCR storage quota.

To do a manual local build (e.g. for testing before pushing):

```sh
docker build \
  --build-arg HERMES_VERSION=v2026.6.19 \
  -t ghcr.io/pakatagoh/hermes-kit:dev .
```

## Gateway mode

The image runs `hermes gateway run` by default — the recommended way to run
Hermes in Docker (runs in the foreground, keeps the container alive, streams
logs). See the [gateway docs](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/messaging/index.md).

| Port  | Purpose                          |
| ----- | -------------------------------- |
| 8642  | Gateway API                      |
| 9119  | Dashboard (only if `HERMES_DASHBOARD=1`) |

Data is stored under `/opt/data` inside the container; bind-mount it to your
host's `~/.hermes` for persistence.

## Run

```sh
# foreground: gateway streams logs to your terminal
docker run --rm -it \
  -p 8642:8642 -p 9119:9119 \
  -v ~/.hermes:/opt/data \
  --env-file .env \
  ghcr.io/pakatagoh/hermes-kit:latest

# background (persistent service)
docker run -d \
  --name hermes \
  --restart unless-stopped \
  -p 8642:8642 -p 9119:9119 \
  -v ~/.hermes:/opt/data \
  --env-file .env \
  ghcr.io/pakatagoh/hermes-kit:latest

# enable the dashboard
docker run -d \
  -e HERMES_DASHBOARD=1 \
  -p 8642:8642 -p 9119:9119 \
  -v ~/.hermes:/opt/data \
  --env-file .env \
  ghcr.io/pakatagoh/hermes-kit:latest
```

GitHub CLI reads `GH_TOKEN` from the environment (see [gh environment docs](https://cli.github.com/manual/gh_help_environment)).
Model API keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, …) and any messaging
tokens go in `.env` as well — copy `.env.example` and fill it in.

### docker-compose

```yaml
services:
  hermes:
    image: ghcr.io/pakatagoh/hermes-kit:latest
    container_name: hermes
    restart: unless-stopped
    ports:
      - "8642:8642"   # gateway API
      - "9119:9119"   # dashboard (only when HERMES_DASHBOARD=1)
    volumes:
      - ~/.hermes:/opt/data
    env_file:
      - .env
    environment:
      - HERMES_DASHBOARD=1
    deploy:
      resources:
        limits:
          memory: 4G
          cpus: "2.0"
```

## Overriding the default command

`CMD ["gateway", "run"]` can be overridden to drop into a shell instead:

```sh
# shell into the image without starting the gateway
docker run --rm -it --env-file .env ghcr.io/pakatagoh/hermes-kit:latest bash
```

Inside the container:

```sh
gh auth status
gh repo list
```

## Adding tools

Append to `[tools]` in `mise.toml`, e.g.:

```toml
[tools]
gh = "2.95.0"
jq = "latest"

# npm-based tools use the "npm:" backend prefix
"npm:ctx7" = "latest"
```

Committing the change triggers a rebuild that installs the new tools.

## Running in k3s (Flux image automation)

This image replaces the official `nousresearch/hermes-agent` image in the
hermes pod. The homelab Flux config (in the separate homelab repo) wires it
up with standard image automation, mirroring the `sg-voucher-manager` pattern:

- `ImageRepository` scans `ghcr.io/pakatagoh/hermes-kit` every 5m.
- `ImagePolicy` with `semver: ">=0.0.0"` selects the highest published tag.
- `ImageUpdateAutomation` rewrites the `$imagepolicy` markers in
  `apps/hermes-agent/release.yaml` and commits the new tag back to Git.
- Flux reconciles the commit → the pod rolls.

Because the image is public on GHCR, **no pull secret is needed** — k3s pulls
anonymously, and the `ImageRepository` has no `secretRef`.

### Why this image works under s6-overlay

Two things in the `Dockerfile` make it behave correctly in the cluster:

1. **The s6-overlay entrypoint is preserved.** The base image runs under
   s6-overlay (`/init` = `s6-svscan` is PID 1). It must start as **root** and
   must **not** override `ENTRYPOINT`/`command:` — the s6 tree chowns the
   volume and drops to the internal `hermes` user (UID 10000 → remapped to
   PUID/PGID 1000) itself. This `Dockerfile` only sets `CMD` (default
   `gateway run`), so the pod's `args: [gateway, run]` are routed through
   `main-wrapper.sh` exactly as in the base image. There is no `USER`
   directive.

2. **mise tools land on the s6 PATH.** s6 reconstructs PATH from
   `/run/s6/container_environment`, so Docker's `ENV PATH=/opt/mise/shims:...`
   does not reliably reach the `hermes` process when it shells out to `gh`.
   The `Dockerfile` therefore symlinks every mise shim into `/usr/local/bin`
   (which is on the s6 PATH and baked into the image), so mise-managed tools
   are discoverable regardless of PATH propagation. mise installs are
   world-readable/executable, so the remapped unprivileged `hermes` user can
   run them.

## Upgrading Hermes

There is no manual lockstep — Flux automates the rollout:

1. Bump `ARG HERMES_VERSION=` in the `Dockerfile` and commit to `main`.
2. The workflow builds the new base and publishes the next patch tag (e.g.
   `0.1.4`) to GHCR.
3. Flux's `ImagePolicy` picks it up and updates the homelab repo automatically.
