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

echo "==> Building common-utils + api + websocket + workers + games"
npm run build -w @voiid/common-utils
npm run build -w @voiid/api
npm run build -w @voiid/websocket
npm run build -w @voiid/workers
npm run build -w @voiid/games

echo "==> Applying DB migrations (idempotent; pending only)"
node --env-file="$APP_DIR/.env" "$APP_DIR/infrastructure/deployment/migrate.mjs"

echo "==> Restarting services under pm2 (start if not yet running)"
# voiid-workers is the background job runner (story expiry: R2 objects + DB rows).
# It is started separately from the api/ws pair so a box that predates it still picks
# it up on the next deploy without a manual pm2 start.
if pm2 describe voiid-api >/dev/null 2>&1; then
  pm2 restart voiid-api voiid-ws --update-env
else
  pm2 start "npm run start -w @voiid/api"       --name voiid-api
  pm2 start "npm run start -w @voiid/websocket" --name voiid-ws
fi
if pm2 describe voiid-workers >/dev/null 2>&1; then
  pm2 restart voiid-workers --update-env
else
  pm2 start "npm run start -w @voiid/workers"   --name voiid-workers
fi
# voiid-games referees every move (docs/GAMES.md §2). Started separately for the same
# reason as the workers above: a box that predates the service picks it up on the next
# deploy without a manual pm2 start. Without it the catalog loads and matches can be
# created, but no move ever resolves — nothing consumes channel:games:input.
if pm2 describe voiid-games >/dev/null 2>&1; then
  pm2 restart voiid-games --update-env
else
  pm2 start "npm run start -w @voiid/games"     --name voiid-games
fi
pm2 save

# TEMPORARY DIAGNOSTIC — dump recent api errors into the deploy log.
#
# The games leaderboard has been returning 500 with no way to see why: the global error handler
# replaces every 5xx body with "internal error", and the box is not reachable by SSH from the
# machine debugging it. The deploy pipeline IS reachable, so it is the only channel back. Remove
# this block once that query is fixed.
echo "==> Recent api errors (temporary diagnostic)"
# Read the pm2 log FILES, not `pm2 logs`: the restart above resets the streamed buffer, so a
# buffer read here is always empty. The files persist across restarts.
for f in "$HOME"/.pm2/logs/voiid-api-error.log "$HOME"/.pm2/logs/voiid-api-out.log; do
  [ -f "$f" ] || continue
  echo "--- $f ---"
  grep -iE "leaderboard|unhandled error|column|syntax|operator" "$f" 2>/dev/null | tail -20
done
echo "(end diagnostic)"
echo

echo "==> Health check"
sleep 3
curl -fsS http://localhost:4000/health || {
  echo "!! /health failed — check 'pm2 logs' and /opt/voiid/.env (DATABASE_URL / REDIS_URL)"; exit 1;
}
echo
# The reaper is NOT what makes a story expire (every read path filters expires_at >
# now()), so a degraded worker must not fail the deploy — it only means expired
# ciphertext is piling up at rest. Warn loudly instead.
curl -fsS "http://localhost:${WORKERS_PORT:-3003}/health" || {
  echo "!! voiid-workers /health failed — expired story media will NOT be cleaned up."
  echo "   Check 'pm2 logs voiid-workers'. Deploy continues (story expiry itself is unaffected)."
}
echo
echo "==> Deploy complete."
