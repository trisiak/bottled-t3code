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

# System packages the owner's agents asked for. The platform runs the container with no-new-privileges, so sudo
# cannot work for `t3`; instead agents list packages in this file and restart the container (bottle-restart), and
# they are installed here while still root. The packages live on the container filesystem: they survive a restart
# but not a rebuild, so the stamp that skips a repeat install lives there too.
BOTTLE_CONFIG="$PERSIST_HOME/.config/bottle"
APT_PACKAGES_FILE="$BOTTLE_CONFIG/apt-packages"
APT_LOG="$BOTTLE_CONFIG/apt-install.log"
APT_STAMP=/var/lib/bottle-apt.sha256
# One package per line, optionally pinned. Nothing that starts with `-`, so the file cannot pass options to apt.
APT_PACKAGE_PATTERN='^[a-z0-9][a-z0-9.+-]*(=[A-Za-z0-9.+:~-]+)?$'
APT_FILE_NAME_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]*$'

mkdir -p "$PERSIST_HOME/.config" "$BOTTLE_CONFIG"
chown -h "$APP_USER:$APP_USER" "$PERSIST_HOME/.config" "$BOTTLE_CONFIG"
if [ ! -e "$APT_PACKAGES_FILE" ] && [ ! -L "$APT_PACKAGES_FILE" ]; then
    cat >"$APT_PACKAGES_FILE" <<'EOF'
# System packages installed with apt-get when the container starts. One per line; `name=version` pins a version.
# Run `bottle-restart` to apply changes; the result is logged to apt-install.log next to this file.
# Optional extra repositories: put *.sources or *.list files in apt-sources/ and their keys in apt-keyrings/
# (copied to /etc/apt/keyrings/, so reference them from there with Signed-By).
EOF
    chown -h "$APP_USER:$APP_USER" "$APT_PACKAGES_FILE"
fi

APT_PACKAGES=()
APT_INVALID=()
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    if [[ "$line" =~ $APT_PACKAGE_PATTERN ]]; then
        APT_PACKAGES+=("$line")
    else
        APT_INVALID+=("$line")
        echo "[start.sh] WARNING: ignoring invalid apt package entry: $line" >&2
    fi
done < <(cat "$APT_PACKAGES_FILE" 2>/dev/null || true)

# The log describes the latest boot, so agents (who cannot see the container's output) learn about ignored entries
# and skipped installs too. Recreated rather than appended to, so it never follows a link the app user left in its
# place; -r so a directory left there does not abort the boot under set -e.
if [ "${#APT_PACKAGES[@]}" -gt 0 ] || [ "${#APT_INVALID[@]}" -gt 0 ]; then
    rm -rf "$APT_LOG"
    install -o "$APP_USER" -g "$APP_USER" -m 0644 /dev/null "$APT_LOG"
    for entry in "${APT_INVALID[@]}"; do
        echo "WARNING: ignoring invalid apt package entry: $entry" >>"$APT_LOG"
    done
fi

if [ "${#APT_PACKAGES[@]}" -gt 0 ]; then
    # Extra repositories, copied under a prefix so ones removed from the directory are removed here too.
    rm -f /etc/apt/sources.list.d/bottle-*
    mkdir -p /etc/apt/keyrings
    for src in "$BOTTLE_CONFIG"/apt-sources/*.sources "$BOTTLE_CONFIG"/apt-sources/*.list \
            "$BOTTLE_CONFIG"/apt-keyrings/*; do
        name="$(basename "$src")"
        if [ ! -f "$src" ] || ! [[ "$name" =~ $APT_FILE_NAME_PATTERN ]]; then
            continue
        fi
        case "$src" in
            */apt-sources/*) install -m 0644 "$src" "/etc/apt/sources.list.d/bottle-$name" ;;
            *) install -m 0644 "$src" "/etc/apt/keyrings/$name" ;;
        esac
    done

    # The repositories are part of what was installed, so a change to them reinstalls too.
    APT_HASH="$(
        {
            printf '%s\n' "${APT_PACKAGES[@]}" | LC_ALL=C sort -u
            cat /etc/apt/sources.list.d/bottle-* 2>/dev/null || true
        } | sha256sum | cut -d' ' -f1
    )"
    if [ "$(cat "$APT_STAMP" 2>/dev/null || true)" = "$APT_HASH" ]; then
        echo "[start.sh] apt packages already installed: ${APT_PACKAGES[*]}"
        echo "apt packages already installed: ${APT_PACKAGES[*]}" >>"$APT_LOG"
    else
        echo "[start.sh] installing apt packages: ${APT_PACKAGES[*]} (log: $APT_LOG)"
        # A package that fails to install must not keep T3 Code from starting; the next boot retries.
        if {
            dpkg --configure -a \
                && apt-get update \
                && apt-get install -y --no-install-recommends "${APT_PACKAGES[@]}"
        } >>"$APT_LOG" 2>&1 </dev/null; then
            echo "$APT_HASH" >"$APT_STAMP"
            echo "[start.sh] apt packages installed"
        else
            rm -f "$APT_STAMP"
            echo "[start.sh] WARNING: installing apt packages failed; see $APT_LOG" >&2
            echo "apt package install FAILED; T3 Code started without them" >>"$APT_LOG"
        fi
    fi
fi

# T3 Code is installed here rather than in the image, so restarting the app moves it to the newest stable release.
# A foreground `t3 serve` never updates itself; upstream's updater belongs to its systemd/launchd service. The
# installer verifies the archive against the release's checksums, skips a version that is already downloaded, and
# links ~/.local/bin/t3 to it.
T3_BIN="$PERSIST_HOME/.local/bin/t3"
T3_VERSIONS="$PERSIST_HOME/.t3/runtime/versions"
# Downloaded to a file first: piping a failed download into sh would run an empty script and report success.
# shellcheck disable=SC2016  # $1 is for the inner shell
if as_app_user sh -c 'curl -fsSL -o "$1" https://t3.codes/install.sh && sh "$1"' _ /tmp/t3-install.sh; then
    # Each release is a few hundred MB unpacked; keep only the one just linked.
    CURRENT_VERSION_DIR="$(dirname "$(readlink -f "$T3_BIN")")"
    for version_dir in "$T3_VERSIONS"/*/; do
        if [ "$(readlink -f "$version_dir")" != "$CURRENT_VERSION_DIR" ]; then
            echo "[start.sh] removing old T3 Code runtime $version_dir"
            rm -rf "$version_dir"
        fi
    done
elif [ -x "$T3_BIN" ]; then
    # An unreachable release host must not take a working server down.
    echo "[start.sh] WARNING: could not check for a newer T3 Code; continuing with the installed one" >&2
else
    echo "[start.sh] could not install T3 Code and no earlier install exists" >&2
    exit 1
fi
echo "[start.sh] T3 Code $(as_app_user t3 --version)"

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
