# Backup and restore review — 15 September 2026

## Implemented

- Restore now merges on Android instead of replacing current history and deleting shards. Both platforms preserve local edits/tombstones and deduplicate restored IDs.
- Invalid archives fail explicitly before mutation. Restore waits for durable message persistence and confirms local backup-key storage before reporting success. An export encoding/load failure no longer becomes an empty successful backup.
- New encrypted payloads contain a versioned `voiid-message-backup` archive bound to the Voiid user ID. Message and receipt dates use integer Unix milliseconds. Legacy iOS reference-date and Android millisecond archives remain readable. Location projections and media references work across the current iOS/Android format.
- Backup setup refuses to replace an existing server backup with a newly generated secret before restoration. Failed optional cloud uploads are surfaced, and iOS only enables a destination after its initial upload succeeds.
- Cloud filenames are account-specific; legacy shared filenames are read-only restore fallbacks. Writes/deletes use the current account’s file. Legacy archives predate account-binding metadata, so that check applies to new-format archives.
- iCloud’s container ID matches the signed entitlement (`iCloud.voiid.app`). Its download timeout now stops before attempting a blocking read. iOS cloud choices are iCloud only; Google Drive remains Android’s external cloud option. Existing encrypted Voiid server backup/recovery remains in place.
- Server transport checks archive size and complete downloads. iOS uploads allow a 120-second timeout.
- Restore accepts the existing 4–8 digit PIN range. Wrong-PIN retries return to PIN entry on Android. iOS distinguishes credential errors from download/import failures and guards duplicate restore submissions.
- Backup selection sorts actual timestamps, and fractional-second metadata dates parse correctly.
- Backend recovery fetch metering now expires after the advertised cooldown; blocked retries do not extend it. Out-of-order failure reports cannot shorten an existing lock.

## Validation

- Android Debug build and 23 targeted tests passed: archive interoperability/integrity (6), secure-preference recovery (11), Android backup rules (6).
- iOS fixture runner compiles the production encode/import code and exercises timestamps, attachment keys, both platform fixtures, legacy archives, duplicate IDs, local preservation, malformed data, path rejection, account mismatch and disk failures. It also checks iCloud container/entitlement consistency.
- 19 backend recovery tests passed, including concurrent fetches, cooldown expiry and out-of-order locks against an isolated local PostgreSQL instance. The temporary instance was stopped afterward.
- 21 Rust recovery crypto tests passed. No cryptographic primitives, KDF parameters or PIN-wrap format changed.
- API TypeScript build passed.

## Scope and remaining validation

These are message-history backups with media references/keys, not a complete device image or independent copies of attachment binaries, live-location secrets, settings, call history or ratchet/MLS state. Restored media depends on its stored encrypted object still being available. New-format archives require an updated app; old app versions cannot read the versioned envelope.

A live iCloud/Google Drive upload, fresh-install restore, offline relaunch after restore, and attachment download still need two-device testing. No real user backup was overwritten and no production restore/deletion was performed during verification. Android Google OAuth configuration and consent need device validation.

Backend recovery fixes are local: no production source upload, deployment or restart was performed. The existing PIN envelope permits offline guesses by someone who obtains it; the repository’s separate cryptographic review gate remains unresolved. Server object upload and recovery-envelope updates are separate operations, not a transactional backup-generation protocol; generation retention/rollback remains future work.
