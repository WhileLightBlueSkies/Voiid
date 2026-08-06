-- 031_consent_notice.sql — publishes the v1 privacy notice into the registry that
-- 030_dpdp.sql created, so consent has something to be consent TO.
--
-- 030_dpdp.sql built `consent_notices` and `consent_records` and explained why the two
-- are deliberately NOT joined by a foreign key: an unseeded registry must not be able to
-- turn a paperwork gap into a signup outage. The consequence is that the registry has to
-- be seeded by a migration rather than by a running server, because the endpoint's
-- version check (routes/consent.ts) rejects a version it cannot find — a 400 on the most
-- important path in the app if this row is missing. Seeding it here makes the notice
-- registry part of the schema's deployed state, not an operational step somebody
-- remembers.
--
-- METADATA ONLY. This file publishes a document reference. It grants nobody any ability
-- to read a message, a call, a location share or a moment; those are end-to-end
-- encrypted and the server holds ciphertext and no key. The notice this row points at
-- says exactly that, in plain language, and that sentence is the notice's most important
-- one.
--
-- THIS FILE IMPLEMENTS A CONTROL. IT DOES NOT CERTIFY THAT VOIID COMPLIES WITH ANYTHING.
-- The DPDP Act s.5 notice obligation is not discharged by a row in a table; it is
-- discharged by a lawful notice, and the notice text this row names still carries
-- unresolved [COUNSEL] markers (grievance officer, children's data, retention numbers,
-- cross-border processors). See docs/research/11_admin_dpdp.md §6.


-- ═════════════════════════════════════════════════════════════════════════════════
-- THE v1 NOTICE
-- ═════════════════════════════════════════════════════════════════════════════════
--
-- WHAT THE VERSION STRING NAMES. '2026-08-01' is the revision date of the LEGAL BUNDLE —
-- the privacy notice and the terms together — because the app presents them together and
-- a user accepts them in one action. Splitting them into two versions would mean two
-- consent records for one checkbox, and a consent record whose version does not match
-- what the user was shown is worse than useless as evidence. Revise both, bump one date.
--
-- WHY `url` IS AN app: LOCATOR AND NOT AN https:// ONE. The v1 notice is rendered from
-- the app binary (apps/ios/.../Legal/LegalDocuments.swift and the Android twin), because
-- a notice that only exists on a website is unreachable to the person being asked to
-- consent to it — which is the exact failure repair plan 3.31 is about. There is no
-- hosted copy yet; the marketing site's /privacy page is being built separately. Writing
-- a plausible https URL here that 404s would be a lie in the evidence record, so this
-- names where the text actually is. When the hosted document exists, publish a NEW row
-- (a new version, or this version with the site's language) carrying the real URL and
-- its hash — do not edit this row, because rows here are pointed at by consent records.
--
-- WHY `content_sha256` IS NULL. The column exists to pin the exact bytes served, so a
-- later edit to a hosted document cannot silently rewrite what people agreed to. There
-- are no served bytes to hash yet: the text lives in two hand-maintained client copies.
-- 030_dpdp.sql permits null here "only for notices published before hashing was wired
-- up, never for new ones", and this is precisely that case. Hashing becomes both possible
-- and mandatory the moment the notice is fetched rather than bundled.
--
-- LANGUAGE: English only. The Eighth-Schedule translation obligation's scope for an app
-- of this size is [COUNSEL] (11_admin_dpdp.md §6.6) and is NOT decided by seeding one
-- row. The schema takes 22 rows per version whenever the answer arrives; what it must
-- not do is imply an answer by seeding translations nobody has reviewed.
--
-- ON CONFLICT DO NOTHING: re-running a migration must not re-date a published notice.
-- `published_at` is evidence of when the text became live, and a replay that reset it
-- would quietly move the date every deploy.
insert into consent_notices (version, language, url, content_sha256, published_at)
values (
    '2026-08-01',
    'en',
    'app://voiid/legal/2026-08-01/en',
    null,
    now()
)
on conflict (version, language) do nothing;
