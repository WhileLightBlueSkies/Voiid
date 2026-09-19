//
// social/identity.ts — the one place public identity is resolved.
//
// ── TWO IDENTITY PLANES, AND THIS IS THE PUBLIC ONE ─────────────────────────────
// Voiid gives every person two identities on purpose:
//
//   users            the Voiid account. Phone number, E2EE chat, contacts. PRIVATE.
//                    `photo_url` here is governed by `photo_privacy` (019), and
//                    `encrypted_photo_url` (021) is end-to-end encrypted and must never
//                    reach a public surface.
//
//   social_profiles  the Social Profile. Handle, display name, avatar, bio. PUBLIC by
//                    definition — anyone can see it, including people with no account.
//
// Clips, Games and Communities are public surfaces, so they read the second one. Chat,
// calls and contacts read the first. Nothing in this module touches `users`.
//
// ── WHY IT IS SHARED ────────────────────────────────────────────────────────────
// Three routers each grew their own copy of "join social_profiles, then presign the
// avatar", and they drifted: Communities and Games rendered `users.photo_url` on public
// surfaces without checking `photo_privacy`, so a photo restricted to contacts was shown
// to strangers. Games later joined the right table but returned raw R2 keys, which
// typechecks cleanly and renders a broken image. Both are the kind of bug that only
// appears at runtime, which is the argument for one implementation rather than four.
//

import type { Request, Response, NextFunction } from 'express';
import { query } from '../db';
import { presignGet, r2Configured } from '../r2';

/**
 * The canonical join. Every public surface uses this so no router hand-writes it again.
 *
 * LEFT, not inner: a row whose author has no Social Profile must still render. The gate
 * below is what stops new ones appearing; this keeps existing data legible instead of
 * dropping rows from a feed.
 *
 * @param idExpr the SQL expression holding the user id to join on, e.g. `p.author_id`
 * @param alias  the table alias to expose, default `sp`
 */
export function socialJoin(idExpr: string, alias = 'sp'): string {
  return `left join social_profiles ${alias} on ${alias}.user_id = ${idExpr}`;
}

/**
 * Turn an avatar column from an R2 KEY into a signed URL, in place.
 *
 * The column stores a key and the client needs a URL. Batched so one page costs one round
 * of presigns rather than one per row.
 *
 * A failure nulls that row's avatar rather than failing the request: the client renders
 * initials, which is a complete row. An avatar is never worth a 500.
 */
export async function signAvatars<T extends Record<string, any>>(
  rows: T[],
  field: string = 'photo_url'
): Promise<T[]> {
  if (!r2Configured() || rows.length === 0) return rows;
  await Promise.all(
    rows.map(async (row) => {
      const key = row?.[field];
      if (!key || typeof key !== 'string') return;
      try {
        (row as any)[field] = await presignGet(key);
      } catch {
        (row as any)[field] = null;
      }
    })
  );
  return rows;
}

/** Sign several avatar fields on the same rows — e.g. an author and an inviter. */
export async function signAvatarFields<T extends Record<string, any>>(
  rows: T[],
  fields: string[]
): Promise<T[]> {
  for (const field of fields) await signAvatars(rows, field);
  return rows;
}

export type SocialGateResult =
  | { ok: true }
  | { ok: false; status: number; body: { error: string; code: string } };

/**
 * Does this user have a usable Social Profile?
 *
 * 428 PRECONDITION REQUIRED rather than 403: the request is not forbidden, it is missing a
 * prerequisite the user can satisfy. Both clients turn this specific code into the setup
 * sheet rather than an error toast, which is the whole reason it is not a 403.
 */
export async function checkSocialProfile(userId: string): Promise<SocialGateResult> {
  const rows = await query<{ suspended_at: Date | null }>(
    `select suspended_at from social_profiles where user_id = $1`,
    [userId]
  );

  if (!rows[0]) {
    return {
      ok: false,
      status: 428,
      body: { error: 'social profile required', code: 'profile_required' },
    };
  }

  if (rows[0].suspended_at) {
    return {
      ok: false,
      status: 403,
      body: { error: 'this profile is suspended', code: 'suspended' },
    };
  }

  return { ok: true };
}

/**
 * Express middleware form, for routes that can gate wholesale.
 *
 * Mount it on the FIRST PUBLIC ACTION of a surface — publishing a clip, liking, commenting,
 * joining a community, starting a match — not on reads. Someone browsing has not yet done
 * anything public, and a wall in front of a feed asks for an identity before showing why
 * anyone would want one.
 */
export function requireSocialProfile() {
  return async (req: Request, res: Response, next: NextFunction) => {
    const { user_id } = (req as any).auth ?? {};
    if (!user_id) return res.status(401).json({ error: 'unauthorized' });

    const gate = await checkSocialProfile(user_id);
    if (!gate.ok) return res.status(gate.status).json(gate.body);
    next();
  };
}
