# Voiid Web on Cloudflare Pages

Voiid Web is a static app plus one Worker (`cloudflare/worker.js`, copied to `dist/_worker.js`
by the build). The Worker does in production what `server.mjs` does locally: security headers,
same-origin checks, `/api/v1/*` to the API, and `/live` to the relay's WebSocket.

Account: **admin@whitelightbluesky.com**. Project: **voiid-messenger** (never `voiid-web` — that project serves the voiid.app marketing site, and deploying there would replace it). Address: **https://web.voiid.app**.

## 1. Build

The WASM binding must exist first (`packages/e2e-core/bindings/wasm/pkg/`); if it does not,
run `packages/e2e-core/build-web.sh`.

```sh
cd apps/web-client
npm run build            # dist/ now holds the app and _worker.js
```

## 2. Deploy

```sh
npx wrangler login                                   # sign in as admin@whitelightbluesky.com
npx wrangler pages project create voiid-messenger --production-branch main   # first time only
npx wrangler pages deploy dist --project-name voiid-messenger --branch main
```

The settings come from `wrangler.toml` `[vars]`: the public origin and the two upstreams.

## 3. Domain

Cloudflare dashboard → Workers & Pages → voiid-messenger → Custom domains → add `web.voiid.app`.
If voiid.app's DNS is on the same Cloudflare account this is one click; otherwise add the
CNAME it shows (`web` → `voiid-messenger.pages.dev`) at the DNS provider.

## 4. Switch linking on (production server)

Only after `https://web.voiid.app` loads. In `/opt/voiid/.env` on the production box:

```
VOIID_WEB_ORIGIN=https://web.voiid.app      # must equal the Worker's VOIID_WEB_ORIGIN exactly
VOIID_WEB_LINKING_ENABLED=1
```

then `pm2 restart voiid-api voiid-ws --update-env`. To switch linking off again, remove
`VOIID_WEB_LINKING_ENABLED` and restart; that stops NEW links but does not sign out browsers
already linked — revoke those from the phone's Linked Devices.

## 5. Check

- `https://web.voiid.app` shows the QR code (not "not switched on").
- iPhone → Settings → Linked Devices → Link a Browser → scan → codes match → approve.
- Send a message both ways; reload the tab; revoke from the phone and see the tab sign out.

## Known limit

Every browser request reaches the API from Cloudflare, so the API's per-IP rate limits see
Cloudflare's addresses rather than each person's. Fine at launch volumes; revisit before
heavy traffic (trust Cloudflare ranges at Caddy and read `CF-Connecting-IP`).
Android cannot approve a browser link yet — iPhone only.
