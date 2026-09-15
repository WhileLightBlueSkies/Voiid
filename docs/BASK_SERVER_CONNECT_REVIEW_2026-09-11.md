# Bask server-connect review — 2026-09-11

Pulled `origin/server-connect` into the local `main` checkout by fast-forward to `3ea2586`. Existing uncommitted community/mobile work was preserved. The corrected artifact is now deployed as `3ea2586-bask-3ba87242`. See the rollout result below.

## Connection requirements

- Once deployed, the agent base URL is `https://api-dev.voiid.app/agent`.
- Authenticated endpoints use `Authorization: Bearer <BASK_AGENT_TOKEN>`: GET `/status`, POST `/command`, POST `/env`.
- GET `/health` under the agent prefix is deliberately unauthenticated in this branch.
- The same token must be configured in Voiid's server environment and Bask's secure connection configuration. Never commit it or bundle it in a public client.
- Defaults already match this server: app directory `/opt/voiid`, environment `/opt/voiid/.env`, PM2 services `voiid-api`, `voiid-ws`, `voiid-games`, `voiid-workers`.
- The new API refuses startup without a token at least 16 characters long. Generate 32 random bytes as 64 hexadecimal characters instead of choosing a human password.

Read-only server check: zero `BASK_AGENT_TOKEN` assignments; `/opt/voiid/.env` permissions already `600`. No token was disclosed during review. A token was subsequently generated privately during the authorized deployment.

## Generate on the Voiid server

Run this on the server, not the Mac. It does not print the token and refuses to add a duplicate assignment:

```bash
sudo bash <<'SH'
set -euo pipefail
file=/opt/voiid/.env
test -f "$file"
if grep -Eq '^[[:space:]]*(export[[:space:]]+)?BASK_AGENT_TOKEN[[:space:]]*=' "$file"; then
  echo 'Token entry already exists; keep it or rotate it deliberately.'
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

Copy the value privately through your SSH editor into Bask's secure token field. Do not paste it in chat. Avoid repeatedly running the original append-only command: duplicate environment keys make rotation and troubleshooting ambiguous. Deployment and a verified process restart are still required; adding this line alone does not install the agent.

## Resolved findings

1. **PM2 output:** status now parses a separate bounded 4-MiB internal capture and returns only selected service fields. Malformed/oversized captures are withheld entirely. Other command output redacts known current and previous-process environment values, escaped variants, and bearer/credential patterns before response truncation. This avoids leaking fragments by truncating a secret before redaction; log hygiene remains necessary for unknown credentials.
2. **Migration polling:** the HTTP wait timer no longer kills the runner. Repeat polls reuse one in-flight promise and return its eventual result. PostgreSQL still serializes against other API processes/deploys through the existing advisory lock. Agent commands that restart/stop the API or edit its environment are refused while its migration is active. Tracking is process-local, not a durable job system: after an external API restart, inspect the ledger/logs before retrying an operation with unknown outcome.
3. **Environment reload:** all four npm start scripts now use `infrastructure/deployment/service-launcher.mjs`. It forwards only OS plumbing to the Node child, whose application configuration comes from the current `.env`. Deleted application keys no longer survive in PM2's cache; changed credentials take effect at next service start. The migration command uses the same launcher. Verified read-only that all four current production services use npm start.
4. **Environment safety:** edits validate round trips against Node's real env parser before replacement. Ambiguous duplicate/multiline source edits fail without changing the environment. Unrepresentable values are rejected, and the agent token cannot be removed or shortened below its startup minimum through the endpoint.

## Verification and rollout

- TypeScript build passed.
- Full API suite: 264 passed, 16 environment-dependent tests skipped, zero failures.
- Tests exercise the actual router and helpers, replacing the former mirrored test implementations.
- New regressions cover large/malformed PM2 output, old/new secret redaction, bounded captures, migration polling without duplicate jobs, unauthorized requests, command validation and real Node env parsing.
- Real child-process launcher regression passed: a fresh token overrides stale inherited configuration, deleted keys disappear, and subsequent token rotation is read from disk.

The fixes were deployed on 11 September 2026 as `3ea2586-bask-3ba87242`. A 64-character hexadecimal token was generated privately; do not repeat the initial-generation command. API and all four start scripts/launcher were deployed together. Public HTTPS health/authentication checks passed. The normal deployment workflow must retain `.env` as the application configuration source; settings held only in PM2 must be migrated to the file before rollout.
