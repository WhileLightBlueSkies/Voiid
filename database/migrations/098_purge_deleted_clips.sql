-- 098_purge_deleted_clips.sql — remove what author-deleted clips left behind.
--
-- DELETE /clips/:id used to be a SOFT delete: it stamped `deleted_at` and kept the row, so
-- a clip its author had deleted still held its caption, length, dimensions, size, storage
-- keys and author, plus every like, view, comment and highlight entry (all cascade from
-- clips.id — 022, 048). The route now deletes the row outright; this clears the rows the
-- old behaviour left.
--
-- Their media was already deleted from R2 at the time (best effort, with the bucket's
-- lifecycle rule as the net), so this touches the database only.
--
-- KEPT: clips our moderators took down (`removed_at` set) BEFORE the author deleted them.
-- Content removed on actual knowledge must be preserved for 180 days under India's IT Rules
-- 3(1)(g); those rows are hidden and are not the author's to purge. A clip the author had
-- ALREADY deleted when a moderator later removed it was the author's deletion first, so it
-- goes like any other.
delete from clips
 where deleted_at is not null
   and (removed_at is null or deleted_at <= removed_at);
