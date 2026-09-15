# Voiid operator rollout checklist for Bask

Date: 11 September 2026  
Status: deployed as `3ea2586-bask-3ba87242`; token created privately; Bask credential transfer pending  
This document contains no credentials.

## 1. Release the complete implementation

The baseline is `3ea2586`, but that commit alone lacks the corrections. Publish/review the final revision before handing a deployment reference to Bask. Preserve the existing uncommitted mobile/community work when preparing the release.

Include the corrected API agent, tests, `infrastructure/deployment/service-launcher.mjs` and all four backend package start scripts. Include the existing agent mounts/health endpoint and reviewed reverse-proxy configuration. No new database migration is required specifically for the Bask fixes; review any other pending migrations in the release independently.

## 2. Confirm configuration before changing startup

All four production PM2 services were verified to use npm start. The new launcher deliberately discards cached application environment values and loads the current `.env`.

Before deployment, ensure every required application setting—including production mode and provider credentials—is in the intended environment file. Move any required PM2-only settings into the file privately. Do not dump PM2 JSON or environment values into shared logs.

Back up current application artifacts, PM2 startup configuration and the environment file with restrictive permissions. Review the release's normal rollback procedure before activation.

## 3. Generate the token on the Voiid server

Run once on the server. This preserves an existing token instead of silently rotating it, and never prints the new value:

```bash
sudo bash <<'SH'
set -euo pipefail
file=/opt/voiid/.env
test -f "$file"
if grep -Eq '^[[:space:]]*(export[[:space:]]+)?BASK_AGENT_TOKEN[[:space:]]*=' "$file"; then
  echo 'Token entry already exists; keep it or rotate deliberately.'
  exit 1
fi
chmod 600 "$file"
umask 077
token=$(openssl rand -hex 32)
printf '\nBASK_AGENT_TOKEN=%s\n' "$token" >> "$file"
unset token
echo 'Token saved without displaying it.'
SH
```

The result is 32 random bytes represented as 64 hexadecimal characters. Keep one active assignment. Do not use a password, a Voiid user JWT or a community-admin session token.

Copy the same value privately into Bask's agreed secure secret destination. Never include it in the handoff document, Git, chat, screenshots, issue trackers or public client configuration.

## 4. Deploy and activate

Deploy the complete corrected release using the normal backup/health/rollback workflow. The new API will refuse startup without an acceptable Bask token.

Restart services through the reviewed deployment workflow so the new npm launcher takes effect. Validate the reverse-proxy configuration before reload if changing it. Keep using the existing HTTPS host; do not open a new public application port for the agent.

Verify both the existing app health endpoint and the new agent endpoints. Confirm all four services are online, the expected release identifier is reported, and ordinary app connections still work. Verify unauthenticated `/agent/status` returns 401. Perform authenticated checks using private tooling that does not log the Authorization header.

## 5. Joint acceptance and rotation

Give Bask the deployed revision, activation time and confirmed base URL—not the token in the status message. Complete the acceptance cases in `BASK_TEAM_HANDOFF_2026-09-11.md`.

For rotation, coordinate both ends: save a new token, restart the API through the new launcher, update Bask's secure token setting and verify the old token is refused. The current contract does not support overlapping old/new tokens, so plan for a brief interruption. Do not rotate during a migration.

If a restart or write disconnects unexpectedly, establish the actual service/file state privately before retrying. After an external API restart during migration, inspect the migration ledger before repeating an uncertain operation.

## Deployment result — 11 September 2026

Completed the API/launcher rollout and verified the public HTTPS agent. Backups of API artifacts, start scripts, environment, PM2 state and database are in `/opt/voiid-backups/bask-20260911/`, with restricted permissions. All four services are online and PM2 state was saved. Existing backend community/event/migration files were compared before deployment and already matched the checkout; no server-side fixes were overwritten.

The token now exists as one generated `BASK_AGENT_TOKEN` assignment in `/opt/voiid/.env` (mode 600). **Do not run token generation again.** Retrieve only this value through a private SSH editor and place it into Bask's secure connection setting. Do not send the environment file itself.

Authenticated and unauthenticated HTTP checks passed through the public HTTPS host. Remaining handoff work: privately transfer the token, let Bask configure the base URL/authentication and validate its UI, and publish the source fixes separately if their team needs the repository revision. Mobile builds, payment-provider activation and Wallet setup are separate releases/configuration tasks.
