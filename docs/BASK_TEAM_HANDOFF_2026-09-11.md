# Voiid → Bask integration handoff

Date: 11 September 2026  
Audience: Bask engineering team  
Status: deployed; authenticated HTTPS verification passed; private token transfer to Bask pending  
Credentials: intentionally excluded

## What this integration does

Bask connects to an operations agent hosted by Voiid's API. It can inspect service health, run a fixed list of operational commands and edit server environment settings. This is separate from the community admin panel in the mobile app. Voiid user login tokens and community-admin permissions do not authorize these endpoints.

This credential grants privileged server operations. Bask must restrict access to authorized operators and protect the connection token in its secret storage. Never include the token in a shared frontend bundle, source repository, analytics, request logs or this document. If Bask uses a browser client, keep the upstream token on its backend and authorize users there.

## Delivery state

- Live release: `3ea2586-bask-3ba87242`, activated 11 September 2026 at approximately 07:19 UTC.
- Baseline source: branch `server-connect`, commit `3ea2586`, plus the reviewed local corrections. The deployed artifact includes those corrections; a corrected standalone Git revision has not yet been published.
- API build passed; full API tests: 264 passed, 16 environment-dependent tests skipped, zero failures. Real-process startup regression passed for stale-key removal and token rotation.
- Deployed API and launcher/start-script changes together. All four PM2 services are online. Migration history was checked; no additional pending migration was reported.
- Live checks passed locally and through the public HTTPS endpoint: valid token works; missing/wrong tokens return 401; invalid command returns 400; service status is online; dependency health is healthy.
- A new 64-character hexadecimal token was generated privately on the Voiid server. Its value is deliberately absent from this document. Voiid must transfer it into Bask's agreed secure credential destination before Bask can authenticate.
- No new public port was opened. The existing HTTPS proxy serves `/agent` successfully; no active proxy configuration replacement was needed.
- Joint Bask-client acceptance remains pending. Live destructive commands and credential rotation were not exercised against production merely for testing.

## Connection settings

| Setting | Value |
| --- | --- |
| Host | `https://api-dev.voiid.app` |
| Agent base URL | `https://api-dev.voiid.app/agent` |
| Authentication | `Authorization: Bearer <shared-secret>` |
| Voiid token variable | `BASK_AGENT_TOKEN` |
| Token generation | 32 random bytes, encoded as 64 hexadecimal characters |
| Request body format | `application/json` |
| Suggested client timeout | 20 seconds |

If Bask asks for a host, use the host above and append `/agent/...`. If it asks for an agent base URL, use the complete base URL and append `/status`, `/command`, etc. Do not accidentally construct `/agent/agent/status`.

The hostname contains `api-dev`; use the agreed hostname as written. It is not a promise of an isolated test database. Obtain rollout confirmation before performing writes.

## HTTP contract

| Method | Path relative to host | Authentication | Purpose |
| --- | --- | --- | --- |
| GET | `/agent/health` | None | Dependency health and machine metrics |
| GET | `/agent/status` | Bearer token | Service availability and permitted service names |
| POST | `/agent/command` | Bearer token | Execute an allowed operation |
| POST | `/agent/env` | Bearer token | Apply environment edits; optional restart |

### Health

Returns HTTP 200 with `schemaVersion`, `status`, `service`, `version`, `environment`, `commitSha`, timestamps, `uptimeSeconds`, `metrics`, `dependencies` and `workers`.

- Read the JSON `status`: `healthy`, `degraded` or `unhealthy`. HTTP 200 alone is not proof that dependencies are healthy.
- Metrics include `cpuPercent`, `memoryPercent` and optional `diskPercent`. CPU is a load-average-based estimate, not sampled processor utilization.
- `workers` is currently empty; do not interpret it as evidence that workers are stopped. Use the authenticated service-status interface.
- `commitSha` can be null; `version` is descriptive, not a release-verification substitute.

### Service status

Example response shape:

```json
{
  "status": "online",
  "detail": null,
  "services": ["voiid-api", "voiid-ws", "voiid-games", "voiid-workers"]
}
```

`status` is `online` or `degraded`. A network failure is an unknown/unreachable state on the client, not an agent-provided `offline` verdict.

### Commands

```json
{"command":"tail_logs","service":"voiid-workers","lines":100}
```

| Command | Additional fields | Behavior |
| --- | --- | --- |
| `status` | None | Selected PM2 service information |
| `restart_service` | `service` | Restart one allowed service |
| `stop_service` | `service` | Stop one allowed service |
| `start_service` | `service` | Start one allowed service |
| `reload_config` | None | Reload all four services; fork mode means restarts |
| `tail_logs` | `service`, optional `lines` | Bounded, redacted log output; default 100 lines, range 1–500 |
| `disk_usage` | None | Disk/log-storage summary |
| `run_migrations` | None | Start a migration run or poll the current run |

Use only the service names supplied by `/agent/status`. Arbitrary shell commands and service name `all` are not supported.

Commands that execute return HTTP 200 with:

```json
{"exitCode":0,"output":"Human-readable operation result"}
```

Check **both** HTTP status and `exitCode`. HTTP 200 with nonzero `exitCode` is not completed success. Render `output` as plain text, never HTML. Do not assume status/log output contains unrestricted raw PM2 data: malformed or oversized captures are withheld, and known credentials are redacted.

### Migration polling — important

The server waits approximately 14 seconds for a result. If the job remains active, the current response is HTTP 200 with `exitCode: 1` and output beginning:

```text
Migrations are still running.
```

This means pending, not failed. There is currently **no structured job ID or durable job-status field**. Until that contract changes, distinguish this explicit pending message from completed errors. Poll `run_migrations` again, allowing roughly 10 seconds between requests; repeat calls reuse the in-flight job within the same API process.

- A completed response has the runner's result. Stop polling after completion.
- Do not restart the API or edit its environment during the run. The agent refuses these operations with `409 migration_running` while its local job is active.
- Tracking is process-local. If the API restarts externally, stop automatic polling and have Voiid inspect the ledger/logs before retrying an uncertain operation.
- PostgreSQL's advisory lock provides additional serialization against deployments and other API processes.

### Environment editing

Example only; use approved keys and values for the intended environment:

```json
{
  "changes": [
    {"key":"APPROVED_SETTING","value":"new-value"},
    {"key":"OBSOLETE_SETTING","value":null}
  ],
  "restart":false
}
```

- Send 1–50 unique changes. Keys match `^[A-Z_][A-Z0-9_]{0,127}$`.
- String values set a key; null removes it.
- Unsupported control characters/newlines or values that cannot round-trip safely are rejected.
- Ambiguous existing duplicate/multiline assignments can produce `409 ambiguous_env_file`; ask Voiid to resolve them through SSH.
- Deleting the agent token or shortening it below 16 characters is refused. Use a new 64-character random token for rotation.
- Responses name changed keys, never their values. There is no GET endpoint for reading secrets back.
- `restart:false` saves the file but does not activate changes. `restart:true` requests restarting all four services.
- Restarting the API may drop the HTTP connection after the file is saved. Show an **unconfirmed outcome**, reconnect and verify service status. Do not blindly replay a write or display either success or failure solely from that connection drop.

### Error handling

- `401`: missing/incorrect token; stop retrying automatically and request operator attention.
- `400`: invalid command, service, arguments, duplicate keys or unsupported values; correct the request.
- `409`: operation blocked by an active migration or ambiguous environment file; act on the error field.
- `429`: honor `Retry-After`, back off and avoid concurrent polling loops.
- `5xx`/network errors: show unavailable or outcome unknown; avoid automatic replay of writes.

## Responsibilities and acceptance

**Voiid:** deployment, token creation and endpoint checks are complete. Transfer the token privately, provide the release identifier above, and publish the corrected source revision when preparing the Git handoff.

**Bask:** store the matching token securely, implement the response/pending/error semantics above, restrict operator access and confirm which secure channel/secret destination should receive the credential. Do not return the credential in screenshots or logs.

For joint Bask-client acceptance, verify: unauthenticated status is refused; authenticated status works; health degrades visibly; invalid commands are rejected; authorized test-environment restart recovers; duplicate submissions are controlled; environment update/removal/rotation works; long-running migrations remain pending and complete without a duplicate run.

Real disruptive tests belong in an agreed test environment. Production connection is not accepted until both teams confirm the deployed revision and these checks.
