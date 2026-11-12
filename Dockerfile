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
# lib*, fonts-liberation         shared libraries and fonts for the headless Chrome behind T3 Code's browser tabs
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        nginx-light gosu tini \
        ca-certificates curl git gh openssh-client jq less procps python3 ripgrep \
        libasound2 libatk-bridge2.0-0 libatk1.0-0 libcairo2 libcups2 libdrm2 libgbm1 libnss3 libpango-1.0-0 \
        libxcomposite1 libxdamage1 libxfixes3 libxkbcommon0 libxrandr2 fonts-liberation \
 && rm -rf /var/lib/apt/lists/*

# The base image's uid 1000 user becomes `t3`. Agents run as this user, never as root: Claude Code refuses its
# unattended permission mode for root.
# The platform runs the container with no-new-privileges, so sudo could never work for it; system packages go in
# ~/.config/bottle/apt-packages instead, which start.sh installs as root at boot.
RUN usermod --login t3 --home /home/t3 --move-home node \
 && groupmod --new-name t3 node

# T3 Code itself is not in the image: start.sh installs the newest stable release onto the persistent volume at
# every boot.

# Provider CLIs the image starts with. start.sh puts a persistent npm prefix ahead of this one on PATH, so a newer
# version installed from T3 Code's provider settings wins and survives rebuilds.
ARG CLAUDE_CODE_VERSION=2.1.322
ARG CODEX_VERSION=0.167.2
RUN npm install -g --prefix /opt/npm-global \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "@openai/codex@${CODEX_VERSION}" \
 && npm cache clean --force

COPY start.sh nginx.conf pair_helper.py /opt/bottled-t3code/
COPY bottle-restart /usr/local/bin/
RUN chmod 0755 /opt/bottled-t3code/start.sh /usr/local/bin/bottle-restart

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/bottled-t3code/start.sh"]
