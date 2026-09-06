# Migration safety

Run `node infrastructure/deployment/migrate.mjs` with the intended `DATABASE_URL`.
The runner holds one PostgreSQL session advisory lock, checks every applied file's
SHA-256 digest before new work, and commits each ordinary migration with its ledger entry.
Historical files must never be renamed or edited; add a new migration instead.

## Existing deployments without checksums

The runner intentionally refuses to silently trust the current checkout. Obtain the
previously deployed, verified artifact. From its root generate a JSON mapping of full
migration filenames to SHA-256 hashes of their exact bytes, review the mapping against
the deployed migration ledger, and supply its path through `MIGRATION_BASELINE_FILE`.
The baseline can include additional files; only already-applied entries are used.
If any applied file differs or is missing, stop and reconcile the artifact history.
Do not generate a baseline from an unreviewed replacement checkout to bypass this check.

## Nontransactional SQL

A migration that requires this must start with `-- migrate:transaction off` on its first
line. Intent is recorded before SQL. An interrupted/failed operation leaves `in_progress`
set and automatic retry is refused. Inspect actual database effects before manually
reconciling that entry. Ordinary failed migrations roll back and leave no applied entry.

## Local verification

`MIGRATION_TEST_DATABASE_URL=... node --test infrastructure/deployment/migrate.test.mjs`
uses a disposable schema and tests concurrent runners, failure rollback, edited history,
explicit legacy baselines, and interrupted nontransactional work. Use disposable databases
for full replay. Supabase CLI migration tracking is not a substitute for this ledger.
