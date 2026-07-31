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
echo "==> Games schema + query probe (temporary diagnostic)"
# Runs the actually-failing statements against the real database FROM THE BOX and prints the
# error. Indirect probing (log greps, response bodies) kept coming back empty or flattened by the
# global error handler, so this executes the thing that fails and reports what Postgres says.
node --env-file="$APP_DIR/.env" -e '
const { Client } = require("/opt/voiid/node_modules/pg");
(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL,
                          ssl: { rejectUnauthorized: false } });
  await c.connect();
  const show = async (label, sql, params) => {
    try { const r = await c.query(sql, params); console.log(label, "OK rows=" + r.rows.length,
            JSON.stringify(r.rows[0] ?? null).slice(0, 200)); }
    catch (e) { console.log(label, "FAILED", e.code, e.message); }
  };
  await show("[probe] game_matches cols:",
    "select string_agg(column_name, ',') as cols from information_schema.columns where table_name = 'game_matches'");
  await show("[probe] games cols:",
    "select string_agg(column_name, ',') as cols from information_schema.columns where table_name = 'games'");
  await show("[probe] catalog:", "select slug from games where enabled = true limit 5");
  const u = (await c.query("select id from users limit 1")).rows[0]?.id;
  await show("[probe] insert match:",
    "insert into game_matches (game_id, player_ids, created_by, status, options) " +
    "values ((select id from games limit 1), $1::jsonb, $2, 'waiting', $3::jsonb) returning id",
    [JSON.stringify([u]), u, "{}"]);
  await c.end();
})().catch((e) => { console.log("[probe] fatal", e.message); process.exit(0); });
' 2>&1 | head -20 || echo "[probe] node failed"
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
