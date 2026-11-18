# Deployment branch runbook

Branch: `maciek/cogwalker-container-setup`. This branch supplies native runtime dependencies
for this deployment without changing the public project's general-purpose `main` branch.
It includes no project checkout, game, licensed asset, credential or user-specific game path.

## What is prepared

- Dockerfile defaults install `wine`, `wine32:i386`, `gcc-mingw-w64-i686`, `unzip` and `libgl1`.
  The image requires Linux amd64. uv 0.13.5 is also included. The platform's ordinary Dockerfile
  build needs no additional build arguments.
- The manifest requests 1024 MiB of shared memory. Keep the app named `t3code` and preserve its
  existing persistent data mount. HOME, user tools, Python downloads, venvs and private assets
  under that home survive recreation. Nothing migrates files out of `/opt` or `/root` automatically.
- `executable-shm.patch` changes the host launcher only for the deployed app named `t3code`
  when its manifest requests exactly 1024 MiB. Other apps keep their existing behavior. The patch
  creates `/dev/shm` with `rw,nosuid,nodev,exec,size=1g,mode=1777`, retaining the existing capabilities,
  `no-new-privileges`, network isolation and private IPC namespace. Size alone does not enable exec.
- `check-runtime.py` checks native prerequisites and executable shared mappings without starting
  Wine. It creates and deletes one temporary page; it does not allocate a full workload buffer.

## Before the maintenance window

Do not restart, redeploy, reload the host service, change the running mount, or switch the live
app's upstream while jobs are active. The dashboard's **Save & update** action deploys immediately.
Preparing and publishing this branch does not activate it on the existing main-based deployment.

On a separate amd64 build machine, check out this branch and build/test it without the live volume:

```sh
podman build -t bottled-t3code:runtime .
podman run --rm --network=none --user=1000:1000 --read-only \
  --security-opt=no-new-privileges=true --cap-drop=ALL \
  --tmpfs=/dev/shm:rw,nosuid,nodev,exec,size=1g,mode=1777 \
  --entrypoint=python3 bottled-t3code:runtime \
  /opt/bottled-t3code/check-runtime.py
```

An equivalent GitHub Actions definition is provided in `image-ci.yml`. To enable it, a
maintainer with workflow write permission can copy it to `.github/workflows/deployment-image.yml`
and push this branch. It builds and checks the image on an isolated runner; it neither publishes
an image nor deploys anything. The current publishing token cannot create workflows, so this
template is not active CI.

The check must exit zero. This also verifies that the installed Podman version accepts the explicit
shm mount. Full Wine/game validation still requires the owner's private assets after recreation.

The host patch was prepared against Cloud in a Bottle commit
`0b95dd366f7be469fcb14b61d4137bcf0b9ab931`. Copy this branch's patch to the host and, from the
**platform source checkout**, check applicability without changing anything:

```sh
git apply --check /path/to/bottled-t3code/deployment/executable-shm.patch
```

If this fails, reconcile the patch with the installed platform version before deployment; do not
force it. The platform source is normally `/home/host/openhost`, but verify the service's actual
WorkingDirectory with `systemctl cat openhost`. No host access or installed version is assumed.

## Maintenance window: apply only after jobs finish

1. Back up the existing `t3code` app data. Confirm all private assets and required user tools are
   under persistent HOME, accessible to UID 1000. Check venv interpreter symlinks: they must not
   point into `/root`. Keep any root-created state only after correcting access as needed.
2. In the host platform checkout, record the current revision and apply the checked patch:

   ```sh
   git apply /path/to/bottled-t3code/deployment/executable-shm.patch
   ```

   Save this change in the host's maintained deployment configuration. Platform updates can
   remove it. Activate the modified launcher through the host's normal platform service restart
   procedure (normally `sudo systemctl restart openhost`); this can interrupt the router and other
   services, so include it in the maintenance window.
3. On the **existing** `t3code` app detail page, edit the git URL to:

   ```text
   https://github.com/trisiak/bottled-t3code@maciek/cogwalker-container-setup
   ```

   Use **Save & update**, reviewing the manifest resource change if prompted. For an immutable
   deployment, replace the branch suffix with the reviewed commit SHA. Do not remove/re-add the
   app or deploy it under a new name: retain the existing app identity and data. The platform
   rebuilds from this branch and recreates the container; a simple container restart is insufficient.
4. As `t3` in the new container, run:

   ```sh
   findmnt /dev/shm
   df -h /dev/shm
   python3 /opt/bottled-t3code/check-runtime.py
   ```

   Expect 1 GiB, `nosuid,nodev`, no `noexec`, and a passing mapping check. On the host, inspect
   `openhost-t3code` with Podman to confirm `no-new-privileges` and the existing security settings.
5. Use the existing persistent project environment and private asset path to run its normal smoke
   test, without the temporary shared-memory path workaround. Then validate intended concurrency
   against free shm and the 6144 MiB container memory ceiling. Python dependency synchronization
   and project-specific compilation remain the project's responsibility, run as `t3`; the image
   does not mutate any checkout at startup.

## Rollback

Keep the previous app source revision and the app-data backup. In a maintenance window, point
the existing app back to the previous revision and update/recreate. Reverse the host patch with
`git apply -R --check` followed by `git apply -R` on the same patch and restart the host launcher.
The patch also stops selecting executable shm when the manifest no longer requests 1024 MiB.
Persistent data remains in place; do not delete volumes. Rolling back the runtime reintroduces
the original dependency/mount limitations, so workload execution may need its prior workaround.
