# hermes-kit

Custom Docker image built on top of [Hermes Agent](https://github.com/NousResearch/hermes-agent),
configured to run in **gateway mode** and bundled with extra tools installed
declaratively via [mise](https://mise.jdx.dev).

## Versions

| Component | Version |
| --------- | ------- |
| Hermes Agent | `v2026.6.19` (see `Dockerfile` `HERMES_VERSION` ARG) |
| gh (GitHub CLI) | 2.95.0 (see [`mise.toml`](./mise.toml)) |

The image is tagged to match the Hermes version, so build with:

```sh
docker build \
  --build-arg HERMES_VERSION=v2026.6.19 \
  -t hermes-kit:v2026.6.19 .
```

To upgrade Hermes, bump `HERMES_VERSION` in `Dockerfile`, the build command,
and the `-t` tag in lockstep.

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
  hermes-kit:v2026.6.19

# background (persistent service)
docker run -d \
  --name hermes \
  --restart unless-stopped \
  -p 8642:8642 -p 9119:9119 \
  -v ~/.hermes:/opt/data \
  --env-file .env \
  hermes-kit:v2026.6.19

# enable the dashboard
docker run -d \
  -e HERMES_DASHBOARD=1 \
  -p 8642:8642 -p 9119:9119 \
  -v ~/.hermes:/opt/data \
  --env-file .env \
  hermes-kit:v2026.6.19
```

GitHub CLI reads `GH_TOKEN` from the environment (see [gh environment docs](https://cli.github.com/manual/gh_help_environment)).
Model API keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, …) and any messaging
tokens go in `.env` as well — copy `.env.example` and fill it in.

### docker-compose

```yaml
services:
  hermes:
    image: hermes-kit:v2026.6.19
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
docker run --rm -it --env-file .env hermes-kit:v2026.6.19 bash
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
```

Rebuild the image to install the new tools.

## Running in k3s

This image is built to replace the official `nousresearch/hermes-agent` image
in the hermes pod (`apps/hermes-agent/release.yaml` in the homelab repo).
Three things make it work under k3s:

### 1. Preserve the s6-overlay entrypoint

The base image runs under **s6-overlay** (`/init` = `s6-svscan` is PID 1). It
must start as **root** and must **not** override `ENTRYPOINT`/`command:` — the
s6 tree chowns the volume and drops to the internal `hermes` user (UID 10000 →
remapped to PUID/PGID 1000) itself. This Dockerfile only sets `CMD` (default
`gateway run`), so the manifest's `args: [gateway, run]` are routed through
`main-wrapper.sh` exactly as before. Do **not** add a `USER` directive.

### 2. mise tools must land on the s6 PATH

s6 reconstructs PATH from `/run/s6/container_environment`, so Docker's
`ENV PATH=/opt/mise/shims:...` does not reliably reach the `hermes` process
when it shells out to `gh`. The Dockerfile therefore symlinks every mise shim
into `/usr/local/bin` (which is on the s6 PATH and baked into the image), so
mise-managed tools are discoverable regardless of PATH propagation. mise
installs are world-readable/executable, so the remapped unprivileged `hermes`
user can run them.

### 3. Get the image into k3s's containerd

k3s uses **containerd**, not dockerd — a `docker build` lives in Docker's
image store and is invisible to k3s. Import it:

```sh
docker build --build-arg HERMES_VERSION=v2026.6.19 -t hermes-kit:v2026.6.19 .
docker save hermes-kit:v2026.6.19 | sudo k3s ctr images import -
```

### 4. Point the HelmRelease at the new image

In `apps/hermes-agent/release.yaml`, change only the image reference and keep
`pullPolicy: IfNotPresent` so k3s uses the locally-imported image instead of
trying to pull from a registry:

```yaml
image:
  repository: hermes-kit            # was: nousresearch/hermes-agent
  tag: v2026.6.19                   # matches HERMES_VERSION + build tag
  pullPolicy: IfNotPresent          # keep — local image, no registry
```

Nothing else in the release needs to change — `args`, `env` (`API_SERVER_*`,
`PUID`/`PGID`), probes (`/health` on 8642), the Service port, and the
`/opt/data` hostPath all work as-is because this image is built `FROM` the
same pinned Hermes version.

### Upgrading Hermes

Because the image is local (not in a registry Flux can scan), there is no
GitOps image automation — bumps are manual and must stay in lockstep:

1. Bump `HERMES_VERSION` in `Dockerfile`.
2. Rebuild + re-import into containerd with the matching `-t` tag.
3. Bump `image.tag` in `apps/hermes-agent/release.yaml`.
