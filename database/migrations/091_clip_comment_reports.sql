-- A single comment under a Clip can be reported (clip_comments.id, 022).
--
-- Reporting the clip does not cover someone being abusive underneath it, and App Review's
-- guideline 1.2 covers every kind of user-generated content, comments included. Targets the
-- COMMENT, like `community_post` targets a post: resolving it removes that one comment.
alter table content_reports
    drop constraint if exists content_reports_target_type_check;

alter table content_reports
    add constraint content_reports_target_type_check
    check (target_type in (
        'clip',
        'creator',
        'message_sender',
        'community_post',
        'community',
        'event',
        -- 091: clip_comments.id.
        'clip_comment'
    ));
