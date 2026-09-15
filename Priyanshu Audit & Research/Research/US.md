# United States – Age, Children, Content and Complaints

> **Researched:** 15 Sep 2026
> **Status:** Research notes, not legal advice. State laws here are changing and in court; recheck every 3 months.
> **Related:** [Global – Safest Baseline](Global%20-%20Safest%20Baseline.md) · [Clips and Series Guideline and Changes](Clips%20and%20Series%20Guideline%20and%20Changes.md)

---

## Summary

| Law | Who it covers | What it requires | Status |
|---|---|---|---|
| COPPA (amended) | Under 13 | Verifiable parent consent before collecting data, plus notices, parent rights, retention policy and security program | Compliance deadline was 22 Apr 2026 |
| TAKE IT DOWN Act | Platforms with user content | Remove non-consensual intimate images within 48 hours | Since 19 May 2026 |
| DMCA safe harbor | Platforms with user uploads | Registered agent, takedown process, repeat-infringer policy | Now |
| Florida HB 3 | Under 16 | Under 14: no account. 14–15: parent consent | Enforceable while litigation continues |
| Texas App Store Accountability Act | Under 18 | App stores verify age and get parent consent; developers assign age ratings | Enforced while the appeal continues |
| California AB 1043 | Everyone | Apps request an age signal from the OS or app store | 1 Jan 2027 |
| California SB 976 | Minors | Parent consent for personalized ("addictive") feeds | Partly in force; age verification 1 Jan 2027 |
| New York SAFE for Kids Act | Minors | No personalized feed without parent consent; no feed notifications 12am–6am | Starts 190 days after final rules |
| Utah / Louisiana / Alabama app store laws | Minors | Similar to Texas | 6 May 2027 / 1 Jul 2027 / 1 Jan 2027 |

As of July 2026, 21 states had passed laws regulating minors on social media.

---

## 1. COPPA

### Who it applies to
- Services aimed at children, **or**
- General services that know they're collecting data from under-13s. If Voiid asks for a birth date and someone enters an under-13 age, Voiid knows.

### Age screen (FTC guidance)
- Let users freely enter month and year of birth.
- No default that favours 13+.
- Don't hint that under-13s can't join.
- Stop children from going back and entering a different age, e.g. with a device flag.

### Accepted ways to get parent consent
- Signed consent form (mail, fax or scan)
- Credit or debit card, or an online payment system that notifies each transaction
- Call or video call with trained staff
- Government ID checked against databases, then deleted
- Knowledge-based questions a child couldn't answer (added 2025)
- Photo ID plus live selfie matched by face recognition and confirmed by trained staff, then deleted (added 2025)
- **Email-plus or text-plus:** only when the child's data stays internal. Not allowed when the child's information can be shared publicly or with others, e.g. chat or posting.

**For Voiid:** children can message and post, so email- or text-based methods, including the proposed OTP + push + email codes, don't meet COPPA. Use a method from the list above.

### Other duties (amended rule, compliance deadline 22 Apr 2026)
- Direct notice to parents and a children's section in the privacy policy
- Parents can review, delete and stop collection
- **Separate** parent consent before sharing a child's data with third parties for ads or AI training
- Written retention and deletion policy; keep data only as long as needed
- Written information security program
- "Personal information" now includes biometrics (fingerprints, voiceprints) and government ID numbers

### Voiid decision
- **At launch:** block under-13s with a neutral age screen.
- **Before adding under-13 accounts:** build one of the accepted consent methods and get a lawyer's sign-off.

---

## 2. TAKE IT DOWN Act (since 19 May 2026)

- Clear, easy-to-find way for people to report intimate images shared without consent
- Remove the image within **48 hours** of a valid request, and make reasonable efforts to remove known identical copies
- Enforced by the FTC

## 3. DMCA (copyright on user uploads)

To keep safe harbor when users upload copyrighted material:
- Register a DMCA agent with the US Copyright Office and show the agent's contact details in the app or website
- Remove content quickly when a valid takedown notice arrives
- Have and enforce a policy for repeat infringers

US law generally protects platforms for what users post. It doesn't protect Voiid for content Voiid posts itself, so official content needs clean licenses.

---

## 4. State laws

| State | Law | What it means for Voiid | Status (mid-2026) |
|---|---|---|---|
| Florida | HB 3 | If Voiid is covered social media: no accounts under 14; parent consent for 14–15; parents can end the account | Injunction lifted by the Eleventh Circuit; enforceable |
| Texas | App Store Accountability Act (SB 2420) | App stores verify age and get parent consent for downloads and purchases. Developers assign an age category (under 13, 13–15, 16–17, 18+) and tell stores about significant changes | In effect from 1 Jan 2026; blocked Dec 2025; enforced again from late May 2026 while the appeal continues |
| Utah | App Store Accountability Act (SB 142) | Similar to Texas | 6 May 2027 |
| Louisiana | HB 570 | Similar to Texas | 1 Jul 2027 |
| Alabama | App store law | Similar; covers new and existing accounts | 1 Jan 2027 |
| California | Digital Age Assurance Act (AB 1043) | Request an age-bracket signal from the OS or app store when the app is downloaded and launched | 1 Jan 2027; existing users by 1 Jul 2027 |
| California | SB 976 | Parent consent before a personalized feed for minors | Partly upheld (Ninth Circuit); age verification 1 Jan 2027 |
| California | Age-Appropriate Design Code | Age estimation, privacy tools, limits on precise location | Partly blocked |
| New York | SAFE for Kids Act | No personalized feed without parent consent; no feed notifications 12am–6am | Starts 190 days after final rules |

## 5. App store age signals

- **Apple Declared Age Range API:** returns an age band (e.g. under 13, 13–15, 16–17, 18+), not a birth date. Available globally since Feb 2026.
- **Google Play Age Signals API:** returns age status for the user's account. Live since 1 Jan 2026.
- These are signals, not full age verification. Combine them with Voiid's own age screen and use whichever answer is more protective.

---

## 6. US checklist

- [ ] Neutral birth date screen; under-13s blocked; no going back to change it
- [ ] Apple and Google age signal APIs
- [ ] Minor defaults: no personalized feed without parent consent, no night notifications, no ads
- [ ] Florida: block under 14 if Voiid is covered
- [ ] TAKE IT DOWN reporting flow with a 48-hour timer
- [ ] DMCA agent registered; takedown and repeat-infringer policy
- [ ] Children's section in the privacy policy
- [ ] Written data retention policy and security program
- [ ] Before any under-13 accounts: a COPPA consent method from the list, plus a lawyer's review

---

## Sources

- [FTC: Complying with COPPA FAQ](https://www.ftc.gov/business-guidance/resources/complying-coppa-frequently-asked-questions)
- [16 CFR 312.5 Parental consent (eCFR)](https://www.ecfr.gov/current/title-16/chapter-I/subchapter-C/part-312/section-312.5)
- [COPPA Rule, Federal Register, 22 Apr 2025](https://www.federalregister.gov/documents/2025/04/22/2025-05904/childrens-online-privacy-protection-rule)
- [FTC finalizes COPPA changes (press release)](https://www.ftc.gov/news-events/news/press-releases/2025/01/ftc-finalizes-changes-childrens-privacy-rule-limiting-companies-ability-monetize-kids-data)
- [COPPA amended rule in full effect (Finnegan)](https://www.finnegan.com/en/insights/articles/coppas-amended-rule-is-now-in-full-effect-what-operators-need-to-know.html)
- [FTC: Complying with the TAKE IT DOWN Act](https://www.ftc.gov/business-guidance/resources/complying-take-it-down-act)
- [State laws 2026 (Loeb & Loeb)](https://www.loeb.com/en/insights/publications/2026/06/childrens-online-privacy-2026-state-app-store-design-code-and-social-media-laws)
- [Children's privacy mid-year update (Mayer Brown)](https://www.mayerbrown.com/en/insights/publications/2026/08/childrens-privacy-mid-year-update-key-legislative-developments-and-emerging-trends-for-businesses)
- [Supreme Court and Texas app store law (SCOTUSblog)](https://www.scotusblog.com/2026/07/supreme-court-allows-texas-to-enforce-law-requiring-age-verification-and-parental-consent-on-app/)
- [California AB 1043 bill text](https://leginfo.legislature.ca.gov/faces/billTextClient.xhtml?bill_id=202520260AB1043)
- [Apple and Google age signal APIs (Xident)](https://xident.io/blog/google-play-age-signals-apple-declared-age-range-not-verification-2026/)
