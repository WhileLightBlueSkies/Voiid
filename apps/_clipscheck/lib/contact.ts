/**
 * Contact details shown on the site.
 *
 * EVERY VALUE HERE IS A PLACEHOLDER AND IS MARKED AS ONE IN THE UI. Nothing on this
 * site may invent a name, an address or an inbox — a fabricated grievance contact is
 * worse than a visibly unfilled one, because a user who writes to it gets silence and
 * believes they have exercised a right they have not.
 *
 * BEFORE LAUNCH, all of these must be filled in AND the addresses must actually be
 * monitored:
 *
 *   - DPDP Act 2023 s.13 requires a published Grievance Officer for a Data Fiduciary,
 *     with the contact details of the person able to answer questions about
 *     processing. IT Rules 2021 Rule 3(2) separately requires a Grievance Officer
 *     with a name and an Indian address, and acknowledgement/response timelines.
 *     See docs/research/11_admin_dpdp.md for the obligation register.
 *   - The officer must be a real, named individual — a role inbox alone does not
 *     satisfy Rule 3(2).
 *   - Legal wording is [COUNSEL]: do not draft SLA promises here.
 */

export type ContactField = {
  /** What to show. */
  value: string;
  /** True while the value is a stand-in — the UI renders it as visibly unfilled. */
  placeholder: boolean;
  /** mailto:/tel: target. Absent while `placeholder` is true. */
  href?: string;
};

const TBD = (value: string): ContactField => ({ value, placeholder: true });

export const CONTACT = {
  /** General enquiries. */
  general: TBD('To be published'),
  /** Security reports / coordinated disclosure. */
  security: TBD('To be published'),
  /** DPDP s.13 + IT Rules 2021 Rule 3(2) grievance officer. */
  grievance: {
    name: TBD('To be appointed'),
    email: TBD('To be published'),
    /** Rule 3(2) requires an address in India. */
    address: TBD('To be published'),
    /** Response window, once counsel has settled it. */
    responseWindow: TBD('To be published'),
  },
  /** Registered entity name, once incorporated details are confirmed. */
  entity: TBD('To be published'),
} as const;

/** True while any contact field is still a placeholder — gates the footer's notice. */
export const CONTACT_INCOMPLETE = true;
