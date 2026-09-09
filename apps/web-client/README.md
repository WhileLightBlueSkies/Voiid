# Voiid Web companion

Local 1:1 text preview, separate from the marketing app in `apps/web`.

See [implementation status, security boundaries and setup](../../docs/WEB_CLIENT_IMPLEMENTATION_2026-09-09.md)
and the [production roadmap](../../docs/WEB_CLIENT_PLAN.md).

Build the WASM binding with `../../packages/e2e-core/build-web.sh` before `npm run build`.
`npm start` serves the local app on port 4173. The API linking feature is disabled until
`VOIID_WEB_LINKING_ENABLED=1` is explicitly configured after the migration and service upgrades.

`npm test` runs the wire-parser unit test without requiring generated WASM. Crypto interop tests
require `npm run test:crypto:prepare`, then `npm run test:crypto`. Chromium checks use
`npm run test:browser` after the app and native interop executable have been built.
