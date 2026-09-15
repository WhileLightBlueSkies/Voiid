/** Pure group-removal policy, evaluated against locked active membership rows. */
export function groupRemovalError(callerRole: string, targetRole: string, self: boolean, activeCount: number): string | null {
  if (self) return callerRole === 'owner' && activeCount > 1
    ? 'transfer ownership before leaving the group' : null;
  if (callerRole !== 'owner' && callerRole !== 'admin') return 'only an admin can remove another member';
  if (targetRole === 'owner') return 'the group owner cannot be removed';
  if (callerRole === 'admin' && targetRole === 'admin') return 'only the owner can remove an admin';
  return null;
}
