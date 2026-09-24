-- Comments on or off for ONE clip, chosen when posting it ("Allow comments").
--
-- The creator-wide `social_profiles.allow_comments` (054) still applies on top: a clip is open
-- to comments only when both are on. Existing clips default to on, which is how they behave
-- today. Like the creator switch, turning it off WITHHOLDS comments rather than deleting them.
alter table clips
    add column if not exists comments_enabled boolean not null default true;
