-- 021_clips_renditions.sql — three video renditions per clip + explicit cover source.
--
-- WHY THREE RENDITIONS: a clip is watched in two very different places. The grid never
-- plays video at all (it draws `thumb_r2_key`), but the fullscreen player runs on
-- anything from a 5G phone to a 3G one. Shipping a single 720p file means either wasting
-- data on slow connections or looking soft on good ones. Three fixed ladders let the
-- client pick by context (docs/CLIPS.md §11) without HLS segmenting or a manifest.
--
-- WHY THE COLUMNS ARE NULLABLE: renditions are produced ON-DEVICE, and an export can
-- legitimately fail or be skipped — a 480p source is never upscaled to 1080p. Playback
-- falls back down the ladder (see the `coalesce` chain in GET /clips/:id/playback), so a
-- clip with only `r2_key_sd` still plays. `r2_key` (the original column) stays the
-- REQUIRED baseline so every pre-existing row keeps working untouched.
--
-- The bytes are PLAINTEXT, exactly as in 020_clips.sql — clips are public broadcast
-- content and deliberately not E2EE. Nothing here changes that decision.

alter table clips add column if not exists r2_key_sd  text;   -- ~480p
alter table clips add column if not exists r2_key_hd  text;   -- ~720p
alter table clips add column if not exists r2_key_fhd text;   -- ~1080p

-- Per-rendition sizes, so the client can decide "is the 1080p worth it on this
-- connection" BEFORE committing to the download rather than after.
alter table clips add column if not exists byte_size_sd  bigint;
alter table clips add column if not exists byte_size_hd  bigint;
alter table clips add column if not exists byte_size_fhd bigint;

-- 'frame' = a still lifted from the video itself; 'upload' = a separate image the author
-- chose. Purely informational for the server (the cover is just an object either way),
-- but the client needs it to restore the right editor state, and it is worth being able
-- to answer "how many people actually replace their cover" without guessing.
alter table clips add column if not exists cover_source text not null default 'frame';
