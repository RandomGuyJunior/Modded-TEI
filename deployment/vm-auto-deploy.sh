#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# This agent runs on the VM, never in GitHub Actions.
REPO_URL="https://github.com/RandomGuyJunior/Modded-TEI.git"
CHECKOUT="$HOME/.local/share/modded-tei/deploy-checkout"
STATE_DIR="$HOME/.local/state/modded-tei"
LAST_SHA="$STATE_DIR/deployed.sha"
LIVE="$HOME/BAR-Devtools/teiserver"
CONTAINER="bar-devtools-teiserver-1"

mkdir -p "$STATE_DIR" "$(dirname "$CHECKOUT")"
exec 9>"$STATE_DIR/deploy.lock"
flock -n 9 || exit 0

for cmd in git rsync podman python3 flock; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done

if [[ ! -d "$CHECKOUT/.git" ]]; then
  git clone --branch main "$REPO_URL" "$CHECKOUT"
fi
git -C "$CHECKOUT" fetch --quiet origin main
git -C "$CHECKOUT" checkout -q -B main origin/main
NEW_SHA="$(git -C "$CHECKOUT" rev-parse HEAD)"

# First installation records the current version. It never changes the live server.
if [[ "${1:-}" == "--initialize" ]]; then
  printf '%s\n' "$NEW_SHA" > "$LAST_SHA"
  echo "Baseline saved: $NEW_SHA. No deployment performed."
  exit 0
fi
[[ -s "$LAST_SHA" ]] || { echo "Not initialized; run with --initialize first." >&2; exit 1; }
OLD_SHA="$(cat "$LAST_SHA")"
[[ "$NEW_SHA" != "$OLD_SHA" ]] || exit 0

# Only deploy runtime source directories. Never sync compose, config, env, databases,
# entrypoints, volumes, or scripts from this repository onto the live instance.
if git -C "$CHECKOUT" cat-file -e "$OLD_SHA^{commit}" 2>/dev/null; then
  if [[ -z "$(git -C "$CHECKOUT" diff --name-only "$OLD_SHA" "$NEW_SHA" -- lib assets)" ]]; then
    printf '%s\n' "$NEW_SHA" > "$LAST_SHA"
    echo "No runtime source changes; marked $NEW_SHA as current."
    exit 0
  fi
fi

[[ -d "$LIVE/lib" && -d "$LIVE/assets" ]] || { echo "Live source directories missing." >&2; exit 1; }
[[ "$(podman inspect --format '{{.State.Running}}' "$CONTAINER")" == "true" ]] || {
  echo "Container is not running. Refusing deployment." >&2; exit 1;
}
# Critical: the current entrypoint may DROP/RECREATE the database if this marker
# is missing. Never restart a container that lacks the marker.
podman exec "$CONTAINER" test -f /app/.devtools/.initialized || {
  echo "First-run marker missing; refusing deployment and restart." >&2; exit 1;
}
# Ensure these exact source paths are bind-mounted into the running container.
podman inspect "$CONTAINER" | python3 -c '
import json,os,sys
obj=json.load(sys.stdin)[0]
mounts={m["Destination"]:os.path.realpath(m["Source"]) for m in obj["Mounts"]}
base=os.path.realpath(os.path.expanduser("~/BAR-Devtools/teiserver"))
for dest,source in {"/app/lib":base+"/lib","/app/assets":base+"/assets"}.items():
    if mounts.get(dest)!=source:
        sys.exit("Unsafe mount configuration for "+dest+"; refusing deployment.")
'

echo "Deploying $NEW_SHA (previous: $OLD_SHA)"
# No --delete: never delete VM-only files, generated content, or private files.
# Exclude known VM-only sensitive code, even if someone later commits it.
rsync -a --exclude='*.env' --exclude='*.secret.exs' \
  --exclude='account_import.ex' "$CHECKOUT/lib/" "$LIVE/lib/"
rsync -a --exclude='*.env' --exclude='*.secret.exs' \
  --exclude='node_modules/' "$CHECKOUT/assets/" "$LIVE/assets/"

# Restart same container only; do not recreate volumes or run compose up/down.
podman restart "$CONTAINER" >/dev/null
sleep 5
[[ "$(podman inspect --format '{{.State.Running}}' "$CONTAINER")" == "true" ]] || {
  echo "Restart failed. State not advanced; investigate container logs." >&2; exit 1;
}
printf '%s\n' "$NEW_SHA" > "$LAST_SHA"
echo "Deployed $NEW_SHA"
