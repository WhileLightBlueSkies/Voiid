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
# The exact commit CI verified. Set by the deploy workflows; empty for a hand-run deploy,
# which falls back to the branch tip as before.
DEPLOY_SHA="${VOIID_DEPLOY_SHA:-}"

echo "==> VOIID dev deploy  (dir=$APP_DIR  branch=$BRANCH  sha=${DEPLOY_SHA:-<branch tip>})  $(date -u +%FT%TZ)"

cd "$APP_DIR"

# ── THE COMMIT WE ARE REPLACING ─────────────────────────────────────────────────────
# Captured BEFORE anything moves, because that is the only moment it is still knowable.
# `rollback()` below checks this out again if the new build fails its health check, so a
# bad deploy self-heals instead of leaving production down until somebody notices.
#
# Empty on a first-ever deploy (no HEAD yet); rollback is then skipped rather than
# checking out the empty string, which would leave the tree in a worse state than the
# failure it was trying to undo.
PREVIOUS_SHA="$(git rev-parse HEAD 2>/dev/null || true)"

# Set once the working tree has actually moved. Until then a failure needs no rollback —
# nothing changed — and rolling back anyway would rebuild and restart for no reason.
TREE_MOVED=0

# Restore the previous commit and get the services running on it again.
#
# Deliberately NOT `set -e`-guarded internally: every step is attempted even if an earlier
# one fails, because a half-rolled-back box is worse than a noisy log. The exit code the
# caller sees is the ORIGINAL failure, not the rollback's — a rollback that itself failed
# must not look like a successful deploy.
rollback() {
  local reason="$1"
  echo
  echo "!! DEPLOY FAILED: $reason"
  if [ "$TREE_MOVED" -eq 0 ] || [ -z "$PREVIOUS_SHA" ]; then
    echo "!! Nothing to roll back (tree unchanged or no previous commit)." >&2
    return
  fi
  echo "==> ROLLING BACK to $PREVIOUS_SHA"
  git checkout --detach "$PREVIOUS_SHA" || echo "!! rollback checkout failed" >&2
  git reset --hard "$PREVIOUS_SHA"      || echo "!! rollback reset failed" >&2
  npm ci                                 || echo "!! rollback npm ci failed" >&2
  for w in @voiid/common-utils @voiid/api @voiid/websocket @voiid/workers @voiid/games; do
    npm run build -w "$w" || echo "!! rollback build failed for $w" >&2
  done
  # Rewrite the reported build sha so /health tells the truth about what is running.
  grep -q "^VOIID_BUILD_SHA=" "$APP_DIR/.env" && sed -i "/^VOIID_BUILD_SHA=/d" "$APP_DIR/.env"
  printf "VOIID_BUILD_SHA=%s\n" "$(git rev-parse --short HEAD)" >> "$APP_DIR/.env"
  pm2 restart voiid-api voiid-ws voiid-workers voiid-games --update-env \
    || echo "!! rollback pm2 restart failed" >&2
  sleep 3
  if curl -fsS http://localhost:4000/health >/dev/null 2>&1; then
    echo "==> Rolled back to $PREVIOUS_SHA and healthy."
  else
    echo "!! ROLLED BACK BUT STILL UNHEALTHY — manual intervention required." >&2
  fi
}

echo "==> Fetching latest code"
git fetch --prune origin

if [ -n "$DEPLOY_SHA" ]; then
  # Check out the VERIFIED commit, not the branch tip.
  #
  # The tip is a moving target: CI can go green on commit X and, by the time this SSH
  # session opens, origin/$BRANCH can already point at commit Y that nothing checked.
  # Deploying the SHA the gate actually ran against is what makes the gate meaningful.
  #
  # Verify it is an ancestor of the branch before touching the working tree, so a bad or
  # unrelated SHA fails here rather than half-deploying.
  if ! git merge-base --is-ancestor "$DEPLOY_SHA" "origin/$BRANCH" 2>/dev/null; then
    echo "!! $DEPLOY_SHA is not an ancestor of origin/$BRANCH — refusing to deploy" >&2
    exit 1
  fi
  git checkout --detach "$DEPLOY_SHA"
  git reset --hard "$DEPLOY_SHA"
else
  git checkout "$BRANCH"
  git reset --hard "origin/$BRANCH"   # exact match to remote; no local drift
fi
TREE_MOVED=1

# From here on a failure has already moved the working tree, so `set -e` exiting straight
# out would leave the box on new code that does not build. Each step rolls back instead.
echo "==> Installing workspace deps (npm ci)"
npm ci || { rollback "npm ci failed"; exit 1; }

echo "==> Building common-utils + api + websocket + workers + games"
for w in @voiid/common-utils @voiid/api @voiid/websocket @voiid/workers @voiid/games; do
  npm run build -w "$w" || { rollback "build failed for $w"; exit 1; }
done

echo "==> Applying DB migrations (idempotent; pending only)"
node --env-file="$APP_DIR/.env" "$APP_DIR/infrastructure/deployment/migrate.mjs"

# Stamp the commit being deployed so GET /health can report which build is serving. A green
# deploy and a serving build have turned out to be different claims.
export VOIID_BUILD_SHA="$(git rev-parse --short HEAD)"
grep -q "^VOIID_BUILD_SHA=" "$APP_DIR/.env" && sed -i "/^VOIID_BUILD_SHA=/d" "$APP_DIR/.env"
printf "VOIID_BUILD_SHA=%s\n" "$VOIID_BUILD_SHA" >> "$APP_DIR/.env"
echo "==> Deploying build $VOIID_BUILD_SHA"

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

echo "==> invites probe (TEMPORARY)"
node --env-file="$APP_DIR/.env" "$APP_DIR/infrastructure/deployment/games-probe.mjs" 2>&1 | head -12 || true
echo

echo "==> Health check"
sleep 3
# THE GATE. A build that cannot answer /health is not a deploy, it is an outage — so the
# previous commit goes back on rather than the box being left broken for whoever notices
# first. Retried a few times before giving up: a service that needs six seconds to open its
# database pool is slow, not failed, and rolling back a healthy build would be the worse
# error of the two.
API_OK=0
for attempt in 1 2 3 4 5; do
  if curl -fsS http://localhost:4000/health >/dev/null 2>&1; then API_OK=1; break; fi
  echo "   /health not ready (attempt $attempt/5), waiting..."
  sleep 3
done
if [ "$API_OK" -ne 1 ]; then
  rollback "/health did not come up after 5 attempts"
  exit 1
fi
curl -fsS http://localhost:4000/health
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
