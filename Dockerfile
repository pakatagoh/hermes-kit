# syntax=docker/dockerfile:1

# Hermes Agent base image (pinned)
# https://github.com/NousResearch/hermes-agent
# Bump this when updating Hermes; keep it in sync with IMAGE_TAG / docs.
ARG HERMES_VERSION=v2026.6.19
FROM nousresearch/hermes-agent:${HERMES_VERSION}

# --- mise ---------------------------------------------------------------------
# Install mise so we can manage tools declaratively via mise.toml.
# Installer docs: https://mise.jdx.dev/getting-started.html
ENV MISE_DATA_DIR=/opt/mise \
    MISE_CONFIG_DIR=/opt/mise \
    MISE_CACHE_DIR=/opt/mise/cache \
    MISE_INSTALL_PATH=/usr/local/bin/mise \
    PATH="/opt/mise/shims:${PATH}"

RUN curl -fsSL https://mise.run | sh

# Install tools declared in mise.toml (pinned versions)
COPY mise.toml /app/mise.toml
WORKDIR /app
RUN mise install && mise global --path /app

# Expose mise-managed tools on the s6-overlay runtime PATH.
#
# The base image runs under s6-overlay (PID 1 = /init / s6-svscan). s6
# reconstructs PATH for the hermes process from /run/s6/container_environment,
# yielding roughly:
#   /command:/opt/hermes/bin:/opt/hermes/.venv/bin:/opt/data/.local/bin:/usr/local/sbin:/usr/local/bin:...
# Docker's ENV PATH (with /opt/mise/shims) does NOT reliably reach the hermes
# process, so the agent shelling out to `gh` would not find it. mise shims are
# symlinks to the `mise` binary (resolved by argv[0]), so mirroring each shim
# into /usr/local/bin — which IS on the s6 PATH and baked into the image —
# makes every mise tool discoverable without depending on PATH propagation.
RUN set -e; \
    for shim in /opt/mise/shims/*; do \
      ln -sf "$shim" "/usr/local/bin/$(basename "$shim")"; \
    done

# Smoke check: ensure mise-managed gh is on PATH
RUN gh --version

# --- Gateway mode -------------------------------------------------------------
# Run the Hermes messaging gateway in the foreground. This is the recommended
# way to run Hermes in Docker (keeps the container alive + streams logs).
#   gateway API  -> 8642
#   dashboard    -> 9119 (only reachable when HERMES_DASHBOARD=1)
EXPOSE 8642 9119
CMD ["gateway", "run"]
