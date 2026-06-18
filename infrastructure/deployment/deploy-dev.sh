#!/usr/bin/env bash
#
# VOIID — DEV deploy script (runs ON the Vultr dev box).
#
# Mirrors docs/VULTR_DEPLOY.md §6 "Deploying updates": pull the latest code,
# install workspace deps, rebuild the shared package + the two backend services,
# then restart them under pm2. Invoked by the GitHub Actions pipeline over SSH on
# every push to the `dev` branch (.github/workflows/deploy-dev.yml), and safe to
# run by hand.
#
# Idempotent: re-running just fast-forwards to origin/dev and restarts.
#
# Secrets (DATABASE_URL / REDIS_URL / JWT_SECRET ...) live in /opt/voiid/.env on
# the box and are NEVER touched by this script or committed to git.

set -euo pipefail

APP_DIR="${VOIID_APP_DIR:-/opt/voiid}"
BRANCH="${VOIID_BRANCH:-dev}"

echo "==> VOIID dev deploy  (dir=$APP_DIR  branch=$BRANCH)  $(date -u +%FT%TZ)"

cd "$APP_DIR"

echo "==> Fetching latest code"
git fetch --prune origin
git checkout "$BRANCH"
git reset --hard "origin/$BRANCH"     # exact match to remote; no local drift

echo "==> Installing workspace deps (npm ci)"
npm ci

echo "==> Building common-utils + api + websocket"
npm run build -w @voiid/common-utils
npm run build -w @voiid/api
npm run build -w @voiid/websocket

echo "==> Restarting services under pm2 (start if not yet running)"
if pm2 describe voiid-api >/dev/null 2>&1; then
  pm2 restart voiid-api voiid-ws --update-env
else
  pm2 start "npm run start -w @voiid/api"       --name voiid-api
  pm2 start "npm run start -w @voiid/websocket" --name voiid-ws
fi
pm2 save

echo "==> Health check"
sleep 3
curl -fsS http://localhost:4000/health || {
  echo "!! /health failed — check 'pm2 logs' and /opt/voiid/.env (DATABASE_URL / REDIS_URL)"; exit 1;
}
echo
echo "==> Deploy complete."
