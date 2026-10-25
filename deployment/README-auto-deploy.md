# VM auto-deployment (safe source-only mode)

This repository is the public **source mirror**. The Google Cloud VM is the runtime authority for private settings and account data.

## What deploys

Every two minutes, a VM-side cron job checks `main` for new commits. If `lib/` or `assets/` changed, it copies those directories into the existing live bind mounts and restarts **only** the existing Podman TEI container.

It **never** copies `compose.yaml`, `config/`, `.env`, `teiserver.env`, database files, `deployment/` scripts, or private VM credentials. It does not run `podman compose up/down`, recreate volumes, or reset the database. It does not use GitHub-hosted SSH keys or inbound SSH access.

The agent checks that the live container is running, its bind mounts point to the expected directories, and `/app/.devtools/.initialized` exists **before** it touches live code. This marker is essential because the existing entrypoint's first-run branch runs `mix teiserver.fakedata`, which can recreate the database. If the marker is missing, deployment is refused.

This is intentionally a conservative **source-only** deployer. It does not automatically apply changes to dependencies, database migrations, Docker images, compose settings, or files outside `lib/` and `assets/`. Those require a separately reviewed deployment procedure. No `--delete` is used; files removed from GitHub may remain on the VM. The agent checks whether the container remains running after restart, but it is not a full health check and does not automatically roll back changes.

## One-time setup on the VM

Log in as `yquestmastery` on `instance-20260909-152204`. **Do not run as root.** Review the deployment script before installing it.

```bash
sudo apt-get update
sudo apt-get install -y git rsync cron util-linux
sudo systemctl enable --now cron

mkdir -p "$HOME/.local/bin" "$HOME/.local/state/modded-tei"
curl -fLsS https://raw.githubusercontent.com/RandomGuyJunior/Modded-TEI/main/deployment/vm-auto-deploy.sh \
  -o "$HOME/.local/bin/modded-tei-deploy"
chmod 700 "$HOME/.local/bin/modded-tei-deploy"

# Important: records the current GitHub commit without changing or restarting the server.
"$HOME/.local/bin/modded-tei-deploy" --initialize
```

Only after confirming the baseline command succeeds, install the two-minute schedule:

```bash
(crontab -l 2>/dev/null | grep -v '/.local/bin/modded-tei-deploy' || true; \
 echo '*/2 * * * * /home/yquestmastery/.local/bin/modded-tei-deploy >> /home/yquestmastery/.local/state/modded-tei/deploy.log 2>&1') | crontab -
crontab -l
```

A new commit touching `lib/` or `assets/` will now be deployed at the next check. To trigger a check manually:

```bash
"$HOME/.local/bin/modded-tei-deploy"
tail -n 40 "$HOME/.local/state/modded-tei/deploy.log"
```

To disable auto-deploy without touching the running server:

```bash
crontab -e
# Remove the line containing /.local/bin/modded-tei-deploy
```

## Important operational notes

- Changes to `lib/` on the VM can be overwritten by newer GitHub code. Edit and commit to GitHub instead.
- The live database and user accounts stay on the VM. Never commit credentials or production dumps.
- Do not remove the first-run marker or run the existing first-run entrypoint against a populated database.
- If the container fails to start after a deploy, inspect `podman logs bar-devtools-teiserver-1`; the agent does not silently recreate the container.
- Because the agent itself is installed outside the checked-out repository, changes to this agent require a deliberate reinstallation.
- The initial `--initialize` only records a baseline; it does **not** force the current GitHub snapshot onto the running instance.
