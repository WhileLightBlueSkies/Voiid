-- The profile counters after the rename to social_profiles (081).
--
-- 081 renamed creator_profiles -> social_profiles and creator_follows -> social_follows, and the
-- triggers moved with their tables — but the two trigger FUNCTIONS from 029 name their target
-- table inside their bodies, and a rename does not rewrite function source. Both kept updating
-- `creator_profiles`, which no longer exists, so:
--
--   • every INSERT into clips failed ("relation creator_profiles does not exist"): the video
--     reached storage, then POST /clips answered 500 and no clip was ever saved;
--   • every follow and unfollow failed the same way on social_follows.
--
-- Same bodies as 029, pointed at social_profiles. Then every counter is recomputed from the
-- rows, so whatever drifted while the triggers were broken is correct again.

create or replace function bump_follow_counts() returns trigger as $$
begin
    if tg_op = 'INSERT' then
        update social_profiles set follower_count = follower_count + 1
         where user_id = new.followee_id;
        update social_profiles set following_count = following_count + 1
         where user_id = new.follower_id;
    elsif tg_op = 'DELETE' then
        -- greatest(...,0): a counter must never render as -1 on a public profile.
        update social_profiles set follower_count = greatest(follower_count - 1, 0)
         where user_id = old.followee_id;
        update social_profiles set following_count = greatest(following_count - 1, 0)
         where user_id = old.follower_id;
    end if;
    return null;
end;
$$ language plpgsql;

-- Counts live clips only: a removed or deleted clip must not be advertised on the profile.
create or replace function bump_clip_count() returns trigger as $$
begin
    if tg_op = 'INSERT' and new.deleted_at is null and new.removed_at is null then
        update social_profiles set clip_count = clip_count + 1 where user_id = new.author_id;
    elsif tg_op = 'DELETE' and old.deleted_at is null and old.removed_at is null then
        update social_profiles set clip_count = greatest(clip_count - 1, 0)
         where user_id = old.author_id;
    elsif tg_op = 'UPDATE' then
        -- Visibility is a function of BOTH flags, so compare the combined state — a takedown
        -- and an author-delete must not double-decrement.
        if (old.deleted_at is null and old.removed_at is null)
           is distinct from (new.deleted_at is null and new.removed_at is null) then
            if new.deleted_at is null and new.removed_at is null then
                update social_profiles set clip_count = clip_count + 1
                 where user_id = new.author_id;
            else
                update social_profiles set clip_count = greatest(clip_count - 1, 0)
                 where user_id = new.author_id;
            end if;
        end if;
    end if;
    return null;
end;
$$ language plpgsql;

-- The triggers themselves, re-stated on the renamed tables so a replay lands in one state.
drop trigger if exists trg_follow_counts on social_follows;
create trigger trg_follow_counts
    after insert or delete on social_follows
    for each row execute function bump_follow_counts();

drop trigger if exists trg_clip_count on clips;
create trigger trg_clip_count
    after insert or delete or update of deleted_at, removed_at on clips
    for each row execute function bump_clip_count();

-- Recount from the rows.
update social_profiles p set
    clip_count = (select count(*) from clips c
                   where c.author_id = p.user_id and c.deleted_at is null and c.removed_at is null),
    follower_count = (select count(*) from social_follows f where f.followee_id = p.user_id),
    following_count = (select count(*) from social_follows f where f.follower_id = p.user_id);
