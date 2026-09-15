# Global – Safest Baseline (Age, Children, Consent)

> **Researched:** 15 Sep 2026
> **Status:** Research notes, not legal advice. These laws change often; recheck every 3 months.
> **Country detail:** [India](India.md) · [US](US.md) · [EU & UK](EU%20%26%20UK.md)
> **Content rules:** [Clips and Series Guideline and Changes](Clips%20and%20Series%20Guideline%20and%20Changes.md)

---

## 1. The approach

Voiid launches worldwide. Rather than build a different signup for each country, apply the strictest version of each rule to everyone. Add extra blocks only where a place goes further.

## 2. Where each strict rule comes from

| Rule we apply everywhere | Strictest source |
|---|---|
| Parent consent for everyone under 18 | India, DPDP (child = under 18), from 13 May 2027 |
| Accounts under 16 must be linked to a parent | Brazil, Digital ECA |
| A self-declared age alone isn't enough | Brazil, Digital ECA |
| The parent must be a verified adult | India, DPDP Rule 10 |
| Strong proof the adult is really a parent before any under-13 account | US, COPPA |
| No targeted ads or profiling of minors | India DPDP; EU DSA Art. 28; Brazil; US COPPA |
| No personalized ("addictive") feed for minors without parent consent | California SB 976; New York SAFE for Kids Act |
| No feed notifications to minors between midnight and 6am | New York SAFE for Kids Act |
| Location off by default for minors | UK Children's Code |
| Safe, private defaults for minors' accounts | EU DSA guidelines; UK Children's Code |

## 3. Age bands at launch

| Age | Account | Parent link | Highest content rating |
|---|---|---|---|
| Under 13 | Not available at launch | — | — |
| 13–15 | Teen | Required | U/A 13+ |
| 16–17 | Teen | Required | U/A 16+ |
| 18+ | Adult | — | Everything Voiid posts (nothing is rated A) |

**Phase 2:** add under-13 child accounts once the strong parent checks in section 6 are built and a lawyer has signed off.

**Trade-off:** requiring a parent for 16–17 year olds everywhere adds friction. Legally it's needed in India (under 18) but not in many other places. If it hurts growth, relax it country by country later.

### Extra blocks

| Place | Extra rule |
|---|---|
| Florida | Under 14: no account. 14–15: parent consent. Applies if Voiid counts as covered social media |
| Australia | Under 16 can't have accounts on age-restricted social media. Messaging apps are exempt; ask a lawyer whether Clips changes that |
| Quebec | Under 14: parent consent to collect personal information |
| EU countries | Parent consent below 13–16 depending on country; covered by the under-18 rule |

---

## 4. The proposed flow, reviewed

**Proposal:** the child logs in with the parent's phone number, and a popup asks "Is a child logging in?". If yes, the parent gets three different codes: an SMS OTP, a push code on their Voiid device, and an email code. The child types them all in, and Voiid treats that as parent consent.

### What works
- The parent must already have a Voiid account. That matches India's Rule 10 example (the parent is an existing registered user) and Brazil's parent linking.
- It uses channels the parent controls.

### What needs to change

| Problem | Why it matters | Fix |
|---|---|---|
| Two accounts on one phone number | Voiid allows one account per number (`phone_number unique` in `database/migrations/001_users.sql`). Anyone searching that number would find the wrong person | The child account gets its own ID and no phone number, linked to the parent |
| "Is a child logging in?" is self-declared | A child can just tap "No". Brazil bans self-declared age | Everyone enters birth month and year at signup, with no going back to change it |
| Codes are typed on the child's device | Young kids often use the parent's phone and can read every code | Parent approves on their own logged-in device with Face ID, fingerprint or passcode. Voiid already does this for new devices (QR approval in `backend/api/src/routes/linking.ts`) |
| Codes prove access to devices, not that the person is an adult or the parent | India requires an identifiable adult. US COPPA doesn't accept email- or text-based consent when kids can chat or post | One-time parent age check (section 6) |
| The parent isn't told what they're agreeing to | Consent must be informed (COPPA, DPDP, GDPR) | Short plain notice plus an "I'm the parent or legal guardian" confirmation |
| No way to change their mind | Parents have the right to review, delete and withdraw | Family Center (section 8) |

Keep the email idea, but as a **consent receipt** sent to the parent rather than a code.

**Also check:** when someone logs in with OTP on a new phone, are the account's existing devices notified, or asked to approve? If not, a child with the parent's SIM could log in as the parent. At minimum, notify existing devices.

---

## 5. Recommended flow

**On the child's device**
1. Welcome → "When were you born?" Month and year, no default value.
2. **Under 13 (at launch):** "Voiid isn't available for under 13 yet." Save only a device flag to stop retries.
3. **13–17:** "Ask a parent to approve." Show a QR code and a short code.

**On the parent's device (already logged in)**
4. Parent opens Voiid → Family → Scan, or taps the notification.
5. Parent reads a short notice: what Voiid collects from the child, what the child can do, and the parent's rights.
6. Parent confirms "I'm the parent or legal guardian" with Face ID, fingerprint or passcode.
7. **First time only:** parent age check (section 6).
8. Parent reviews the child's settings, with safe defaults pre-filled.

**Back on the child's device**
9. Account activates. Child sets a name and username. No phone number needed.
10. Parent gets a consent receipt by email.

## 6. Parent age check

| Where | Method |
|---|---|
| India | DigiLocker age token, or identity and age details from a government-authorised source (DPDP Rule 10) |
| US (needed before any under-13 account) | A COPPA method that works when kids can chat or post: card transaction check, government ID check, photo ID plus live selfie match confirmed by trained staff, knowledge-based questions, call or video call with trained staff, or a signed form. **Not** email-plus or text-plus |
| EU & UK | "Reasonable efforts" using available technology (GDPR Art. 8): age estimation or an ID check, following the EU DSA age-assurance guidelines |
| Brazil | Reliable age verification; self-declaration isn't allowed |
| Everywhere | Also read Apple's Declared Age Range API and Google Play Age Signals API |

Delete ID images right after the check. Keep only the result, method and date.

---

## 7. Defaults for minors

| Feature | 13–17 | Under 13 (Phase 2) |
|---|---|---|
| Profile | Private | Private |
| Found by phone number or username | Contacts only | No |
| Who can message or call | Contacts they accept | Parent-approved contacts only |
| Watching Voiid series and clips | 13–15: up to U/A 13+ · 16–17: up to U/A 16+ | U and U/A 7+ |
| Posting clips | On; visible to contacts by default | Off |
| Feed | Not personalized unless a parent turns it on | Not personalized |
| Ads and profiling | None | None |
| Location sharing | Off; parent can allow | Off, locked |
| Payments and shopping | Off | Off |
| Public communities | Allowed with safety settings | Off |
| Notifications 12am–6am | Off | Off |
| Screen time limit | Parent can set | Parent sets |

Parents can't read messages, which are end-to-end encrypted. Instead, parents control who the child can talk to.

## 8. Family Center (parent side)

- See linked children
- Approve contacts (under 13)
- Set content rating limit, clip posting, location and screen time
- See the consent record
- Download or delete the child's data
- Withdraw consent, which deletes the child's account

## 9. Data rules for minors

- Collect the minimum: birth month and year, name, username.
- No face photo required.
- No precise location by default.
- A written retention and deletion policy; delete data once it's no longer needed (COPPA).
- A written security program (COPPA).
- Never share minors' data with third parties for ads or AI training.
- Keep consent records.

---

## 10. Build order

**Before launch**
1. Birth date screen and under-13 block
2. Parent approval flow for 13–17
3. Parent age check (DigiLocker in India; an age-assurance vendor elsewhere)
4. Defaults for minors (section 7)
5. Basic Family Center
6. Report button and Complaints screen

**Phase 2**
1. Under-13 child accounts with COPPA-grade parent checks
2. Parent contact approval
3. Screen time limits

---

## Sources

- [DPDP Rule 10 text](https://dpdprules.org/rules/10) · [DPDP Rules notified (PIB)](https://static.pib.gov.in/WriteReadData/specificdocs/documents/2025/nov/doc20251117695301.pdf)
- [FTC: Complying with COPPA FAQ](https://www.ftc.gov/business-guidance/resources/complying-coppa-frequently-asked-questions) · [16 CFR 312.5 Parental consent](https://www.ecfr.gov/current/title-16/chapter-I/subchapter-C/part-312/section-312.5)
- [Brazil Digital ECA obligations (Mayer Brown)](https://www.mayerbrown.com/en/insights/publications/2026/04/enforcement-of-brazils-eca-digital-introduces-new-obligations-for-companies) · [Brazil decrees (Baker McKenzie)](https://www.bakermckenzie.com/en/insight/publications/2026/03/brazil-regulates-the-children-and-adolescents-online-safety-act)
- [Australia social media age restrictions (eSafety)](https://www.esafety.gov.au/about-us/industry-regulation/social-media-age-restrictions)
- [US state laws 2026 (Loeb & Loeb)](https://www.loeb.com/en/insights/publications/2026/06/childrens-online-privacy-2026-state-app-store-design-code-and-social-media-laws)
- [EU DSA minors guidelines (European Commission)](https://digital-strategy.ec.europa.eu/en/library/commission-publishes-guidelines-protection-minors)
- [Apple and Google age signal APIs (Xident)](https://xident.io/blog/google-play-age-signals-apple-declared-age-range-not-verification-2026/)
