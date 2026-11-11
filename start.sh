#!/bin/bash
# Supervises the three processes of the container: nginx (as root, on :8080), and the T3 Code server and the pairing
# helper (both as the unprivileged `t3` user, on loopback). If any of them exits, the container exits so the
# platform restarts it as a whole.

set -euo pipefail

APP_USER=t3
APP_DIR=/opt/bottled-t3code
T3_PORT=3773

PERSIST="${BOTTLE_APP_DATA_DIR:?BOTTLE_APP_DATA_DIR is unset: this image needs the app_data mount Cloud in a Bottle provides}"

# T3 Code and the provider CLIs keep their state under os.homedir(), so HOME itself is relocated onto the persistent
# mount instead of redirecting each tool separately.
PERSIST_HOME="$PERSIST/home"
PROJECTS="$PERSIST_HOME/projects"
NPM_PREFIX="$PERSIST_HOME/.npm-global"

mkdir -p "$PROJECTS" "$NPM_PREFIX" "$PERSIST_HOME/.local/bin"
# The mount is root-owned on first boot. Not recursive: everything below is created by the app user, and walking a
# volume full of checkouts on every boot would be slow.
chown "$APP_USER:$APP_USER" "$PERSIST" "$PERSIST_HOME" "$PROJECTS" "$NPM_PREFIX" "$PERSIST_HOME/.local" \
    "$PERSIST_HOME/.local/bin"

# gosu resets HOME to the passwd entry, so the environment is passed explicitly.
#
# PATH order: tools the owner installed (persistent npm prefix, ~/.local/bin) shadow the provider CLIs baked into
# the image, which lets an update from T3 Code's provider settings take effect and survive a rebuild.
#
# T3CODE_SERVER_BROWSER_SANDBOX=0: Chrome's sandbox has to create user namespaces, which a rootless container does
# not reliably allow. The container is the isolation boundary here.
as_app_user() {
    gosu "$APP_USER" env \
        HOME="$PERSIST_HOME" \
        USER="$APP_USER" \
        LOGNAME="$APP_USER" \
        SHELL=/bin/bash \
        PATH="$NPM_PREFIX/bin:$PERSIST_HOME/.local/bin:/opt/npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        NPM_CONFIG_PREFIX="$NPM_PREFIX" \
        T3CODE_SERVER_BROWSER_SANDBOX=0 \
        "$@"
}

echo "[start.sh] starting nginx on :8080"
nginx -c "$APP_DIR/nginx.conf" -g 'daemon off;' &
NGINX_PID=$!

echo "[start.sh] starting pairing helper"
as_app_user python3 "$APP_DIR/pair_helper.py" &
HELPER_PID=$!

# Loopback only: nginx is the single way in, so the router's owner check cannot be bypassed.
echo "[start.sh] starting T3 Code on 127.0.0.1:$T3_PORT"
# shellcheck disable=SC2016  # $1 and $2 are for the inner shell
as_app_user bash -c 'cd "$1" && exec t3 serve --host 127.0.0.1 --port "$2"' _ "$PROJECTS" "$T3_PORT" &
T3_PID=$!

trap 'kill -TERM "$NGINX_PID" "$HELPER_PID" "$T3_PID" 2>/dev/null; wait' TERM INT

set +e
wait -n "$NGINX_PID" "$HELPER_PID" "$T3_PID"
EXIT_CODE=$?
set -e

echo "[start.sh] a process exited (code=$EXIT_CODE); shutting down"
kill -TERM "$NGINX_PID" "$HELPER_PID" "$T3_PID" 2>/dev/null || true
wait || true
# A clean exit of one process still means the container is no longer serving.
[ "$EXIT_CODE" -ne 0 ] || EXIT_CODE=1
exit "$EXIT_CODE"
