-- Hash pins docs/legal/2026-09-10-bundle.json, containing both complete native documents.
insert into consent_notices(version,language,url,content_sha256,published_at)
values('2026-09-10','en','app://voiid/legal/2026-09-10/en',decode('7eb88ac0f5d87eb5bebceb833667bf0958c06fc3d65c5a3e87aa845fa39ff3b1','hex'),now())
on conflict(version,language) do nothing;
