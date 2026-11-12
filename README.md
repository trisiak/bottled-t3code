# bottled-t3code

[T3 Code](https://github.com/pingdotgg/t3code) packaged as a [Cloud in a Bottle](https://cloudinabottle.org) app: an always-on T3 Code server in your own instance, with Claude Code and Codex installed, reachable at `https://t3code.<your-domain>/`.

This repo holds only the packaging. T3 Code itself is installed by its official installer when the container starts, onto the app's data volume.

## How it fits together

```
browser -> router (owner-only) -> nginx :8080 -> t3 serve        127.0.0.1:3773
                                              -> pair_helper.py  127.0.0.1:3774
```

- The app declares no public paths, so the router refuses everyone but the instance owner. nginx checks the router's `X-OpenHost-Is-Owner` header again, because a T3 Code session is a shell in the container.
- T3 Code has its own auth and wants a pairing link from every new browser. Since the router has already authenticated you, `/_bottle/pair` mints that link for you: opening the app in a browser without a T3 Code session shows one "Pair this browser" button. The same page is linked from the app's detail page in the dashboard, for when a session expires.
- T3 Code, the agents and the terminal run as the unprivileged user `t3`. There is no `sudo`: the platform starts every app container with `no-new-privileges`, which stops `sudo` from gaining root. System packages go through a package list instead (see below).

## What persists

`HOME` is `/data/app_data/t3code/home`, on the app's permanent data volume, so these survive restarts and rebuilds:

- `~/.t3`: T3 Code's threads, settings and paired devices
- `~/.claude`, `~/.codex`, `~/.config/gh`, `~/.gitconfig`, `~/.ssh`: logins
- `~/projects`: your checkouts. T3 Code starts here.
- `~/.npm-global`: anything installed with `npm install -g`, including provider CLI updates made from T3 Code's settings. It comes before the image's copies on `PATH`.

Restarting and rebuilding are different. A restart (from the dashboard, or `bottle-restart`) keeps the container's own filesystem, so apt packages installed at boot stay installed. A rebuild (redeploy) starts from a fresh image. It keeps only the data volume above, so the package list is installed again on the first boot after it.

## System packages

`sudo` cannot work here, but agents can still install apt packages. `start.sh` installs them as root each time the container starts:

1. List packages in `~/.config/bottle/apt-packages`, one per line. `#` starts a comment and `name=version` pins a version. Lines that are not a valid package name are ignored with a warning, so the file cannot pass options to apt.
2. Run `bottle-restart`. It restarts the container, which ends T3 Code and every session in it, including the one that ran it. Reload the page after a minute.
3. Read `~/.config/bottle/apt-install.log` to check the result.

Notes:

- The install runs only when the list has changed since the last successful install, or after a rebuild. Taking a package off the list does not uninstall it; it stays until the next rebuild.
- If the install fails (a misspelt package, no network), T3 Code still starts without it, and the next boot tries again.
- For packages from other repositories, put `*.sources` or `*.list` files in `~/.config/bottle/apt-sources/` and their signing keys in `~/.config/bottle/apt-keyrings/`. Keys are copied to `/etc/apt/keyrings/`, so reference them from there with `Signed-By:`.
- A package's install scripts run as root inside the container. Anything that can edit this file can therefore run code as root inside the container on the next restart. The container stays the isolation boundary.

## Deploy

```
bottle app deploy https://github.com/trisiak/bottled-t3code --wait
```

The first start downloads about 150 MB of T3 Code; until that finishes the app shows a "starting" page.

## First run

1. Open `https://t3code.<your-domain>/` and press **Pair this browser**.
2. Open a terminal in T3 Code and sign in to the providers you use: `claude auth login`, `codex login`. Both print a URL to open on any device.
3. `gh auth login` if agents should push branches or open pull requests.
4. Clone a repository under `~/projects` and add it as a project.

## Phone and desktop apps

The router only lets a logged-in owner's browser through, so the T3 Code mobile and desktop apps cannot use `https://t3code.<your-domain>/` directly. They connect through T3 Connect, T3 Code's own relay:

1. In the T3 Code terminal, run `t3 connect link` and approve the code it prints.
2. Reload the app from the Cloud in a Bottle dashboard so the server starts its tunnel.
3. Sign in to the same T3 Connect account on the other device.

T3 Connect is an outbound tunnel. It does not pass through the router, so access over it is guarded by T3 Code's auth and your T3 Connect account alone. It stays off until you link it, and `t3 connect unlink` turns it off again.

## Updating T3 Code

Restart the app from the dashboard. Every start runs T3 Code's installer, which moves to the newest stable release and verifies the download against the release's checksums; older downloaded versions are removed. If the release host is unreachable, the version already installed keeps running.

T3 Code's own updater (`t3 update`, and the update prompt in its apps) does not apply here: it belongs to a systemd service the container does not run.

## Tests

```
uv run pytest
```

They cover `pair_helper.py`. The container as a whole is exercised by deploying it.

## License

MIT for the packaging in this repo. T3 Code is MIT-licensed by its authors and is not redistributed here.
