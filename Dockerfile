# T3 Code server packaged for Cloud in a Bottle.
#
#   browser
#     -> router (t3code.<zone>; owner-only, stamps X-OpenHost-Is-Owner: true)
#     -> container :8080      nginx: health check, owner gate, WebSocket-aware proxy
#     -> 127.0.0.1:3773       t3 serve
#     -> 127.0.0.1:3774       pair_helper.py (signs the owner's browser in to T3 Code)

FROM node:24-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# nginx-light, gosu, tini        front proxy, privilege drop, PID 1
# git, gh, openssh-client, ...   what agents and the built-in terminal expect on a dev box
# sudo                           lets the app user install packages; they last until the container is rebuilt
# lib*, fonts-liberation         shared libraries and fonts for the headless Chrome behind T3 Code's browser tabs
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        nginx-light gosu tini \
        ca-certificates curl git gh openssh-client jq less procps python3 ripgrep sudo \
        libasound2 libatk-bridge2.0-0 libatk1.0-0 libcairo2 libcups2 libdrm2 libgbm1 libnss3 libpango-1.0-0 \
        libxcomposite1 libxdamage1 libxfixes3 libxkbcommon0 libxrandr2 fonts-liberation \
 && rm -rf /var/lib/apt/lists/*

# The base image's uid 1000 user becomes `t3`. Agents run as this user, never as root: Claude Code refuses its
# unattended permission mode for root.
RUN usermod --login t3 --home /home/t3 --move-home node \
 && groupmod --new-name t3 node \
 && echo 't3 ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/t3 \
 && chmod 0440 /etc/sudoers.d/t3

# T3 Code ships as a self-contained archive per release. Bump the version and both checksums together; the
# checksums are the release's SHA256SUMS entries.
ARG T3CODE_VERSION=0.1.9
ARG T3CODE_SHA256_AMD64=0141025335da334759cecd8db3483e09772f3600ca03674698524e7d94291362
ARG T3CODE_SHA256_ARM64=52023bc5728a4dee4de361ad6fef7c236f1efb2742ff25e29d5c55e2fb662eea
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) t3_arch=x64; sha="$T3CODE_SHA256_AMD64" ;; \
      arm64) t3_arch=arm64; sha="$T3CODE_SHA256_ARM64" ;; \
      *) echo "no T3 Code build for $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/t3.tar.gz \
      "https://github.com/pingdotgg/t3code/releases/download/v${T3CODE_VERSION}/t3-${T3CODE_VERSION}-linux-${t3_arch}.tar.gz"; \
    echo "${sha}  /tmp/t3.tar.gz" | sha256sum -c -; \
    mkdir -p /opt/t3; \
    tar -xzf /tmp/t3.tar.gz -C /opt/t3 --strip-components=1; \
    rm /tmp/t3.tar.gz; \
    ln -s /opt/t3/t3 /usr/local/bin/t3; \
    t3 --version

# Provider CLIs the image starts with. start.sh puts a persistent npm prefix ahead of this one on PATH, so a newer
# version installed from T3 Code's provider settings wins and survives rebuilds.
ARG CLAUDE_CODE_VERSION=2.1.322
ARG CODEX_VERSION=0.167.2
RUN npm install -g --prefix /opt/npm-global \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "@openai/codex@${CODEX_VERSION}" \
 && npm cache clean --force

COPY start.sh nginx.conf pair_helper.py /opt/bottled-t3code/
RUN chmod 0755 /opt/bottled-t3code/start.sh

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/bottled-t3code/start.sh"]
