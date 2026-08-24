//
//  CreateProfileScreen.swift
//  Voiid
//
//  Profile setup, step 2 of 2 — the optional half, and the page that actually SAVES.
//
//  Built to the design source (`Voiid Ui/Screens/ProfileExtrasScreen.swift`) through
//  `OnboardingKit`.
//
//  ── EVERYTHING HERE IS SKIPPABLE, AND THE SCREEN SAYS SO ────────────────────────
//  Email and bio are both optional, which is precisely why they were split off step 1: mixed in
//  with the required fields, "optional" is a word in a label that nobody reads. On their own
//  page with a visible Skip, it is a real choice.
//
//  So the primary button is ALWAYS enabled (bar a malformed email). There is nothing to
//  complete — pressing it with both fields empty is a legitimate outcome, identical to Skip. The
//  two exist together because they mean different things to the user ("I'm done" vs "not now"),
//  not because they do different things to the data.
//
//  ── THE SAVE HAPPENS ONCE, HERE ─────────────────────────────────────────────────
//  Step 1 collects identity and hands over a `ProfileDraft` without writing anything, so a user
//  who backs out has not half-created an account. Both Continue and Skip call `submit()`, which
//  is the single `ProfileService.updateProfile` for the whole flow. Skip simply submits a draft
//  with the optional fields empty — it is not a way to avoid saving the required ones.
//
//  ── EMAIL IS VALIDATED ONLY IF TYPED ────────────────────────────────────────────
//  The account is keyed on a verified phone number, so email is a recovery convenience rather
//  than an identity. An empty field passes. A field with something in it has to look like an
//  address — catching a typo here is worth it precisely BECAUSE the address is for recovery,
//  which is the one moment a wrong address cannot be corrected.
//

import SwiftUI

struct CreateProfileScreen: View {
    /// Everything collected on step 1.
    let draft: ProfileDraft
    let onFinish: () -> Void

    @EnvironmentObject var session: AppSession

    @State private var email = ""
    @State private var bio = ""
    @State private var saving = false
    @State private var errorText: String?

    /// Empty is fine — see the header. A typed value has to look like an address.
    private var emailValid: Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        if e.isEmpty { return true }
        // Deliberately loose. Strict RFC-5322 matching rejects valid addresses, and the only
        // real test is a confirmation mail.
        let parts = e.split(separator: "@")
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
            && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
    }

    var body: some View {
        ZStack {
            VoiidBrand.ground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    OnboardingHeader(
                        title: .stacked("A few more", accent: "details"),
                        blurb: "Both are optional — you can add them later."
                    )

                    VStack(spacing: 12) {
                        OnboardingField(
                            icon: "envelope",
                            label: "Email address",
                            prompt: "Enter your email address",
                            text: $email,
                            keyboard: .emailAddress,
                            contentType: .emailAddress,
                            autocapitalization: .never
                        ) {
                            if !email.isEmpty && !emailValid {
                                Image(systemName: "exclamationmark.circle")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundColor(VoiidColor.warning)
                            }
                        }

                        Text("Used to help you recover your account.")
                            .font(VoiidFont.rounded(12.5))
                            .foregroundColor(VoiidBrand.textDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 4)

                        OnboardingField(
                            icon: "pencil.line",
                            label: "Bio (optional)",
                            prompt: "Tell the world about yourself",
                            text: $bio,
                            characterLimit: 120
                        )
                    }
                    .padding(.top, VoiidSpacing.lg)

                    if let errorText {
                        Text(errorText)
                            .font(VoiidFont.rounded(13))
                            .foregroundColor(VoiidColor.error)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, VoiidSpacing.sm)
                    }

                    privacyNote
                        .padding(.top, VoiidSpacing.lg)
                }
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.bottom, 210)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                footer
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .preferredColorScheme(.dark)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    // MARK: Privacy note

    private var privacyNote: some View {
        HStack(spacing: VoiidSpacing.md) {
            Circle()
                .fill(VoiidBrand.lime.opacity(0.10))
                .frame(width: 46, height: 46)
                .overlay {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(VoiidBrand.lime)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text("You control what you share")
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidBrand.text)
                Text("Your email is never shown to other people, and you can change any of this in Settings.")
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidBrand.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 14)
        .background(VoiidBrand.card)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidBrand.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: Footer

    private var footer: some View {
        OnboardingFooter {
            OnboardingKitButton(title: saving ? "Saving…" : "Finish",
                                enabled: emailValid && !saving) {
                submit(includeExtras: true)
            }

            // Skip saves the SAME required fields — it only declines the optional ones. It is
            // not a way out of creating the profile, and it must not look like one.
            Button("Skip for now") {
                Haptics.tap()
                submit(includeExtras: false)
            }
            .font(VoiidFont.rounded(15))
            .foregroundColor(VoiidBrand.textDim)
            .buttonStyle(PressableButtonStyle())
            .disabled(saving)

            StepDots(current: 1, total: 2)
        }
    }

    // MARK: Save

    /// The single write for the whole profile flow.
    private func submit(includeExtras: Bool) {
        guard !saving else { return }
        saving = true
        errorText = nil

        let cleanEmail = includeExtras ? email.trimmingCharacters(in: .whitespaces) : ""
        let cleanBio = includeExtras ? bio.trimmingCharacters(in: .whitespaces) : ""

        Task {
            do {
                _ = try await ProfileService.shared.updateProfile(
                    fullName: draft.fullName,
                    email: cleanEmail,
                    bio: cleanBio.isEmpty ? nil : cleanBio,
                    username: draft.username
                )
                session.profile.fullName = draft.fullName
                session.profile.email = cleanEmail
                session.profile.bio = cleanBio
                Haptics.success()
                onFinish()
            } catch let APIError.http(status, _, _) where status == 409 {
                // The name was free on step 1 and was taken in between. Sending the user back is
                // the only honest fix — the field that has to change is on the other page.
                errorText = "That username was just taken. Go back and choose another."
                Haptics.error()
            } catch {
                errorText = (error as? APIError)?.errorDescription ?? "Couldn't save profile."
                Haptics.error()
            }
            saving = false
        }
    }
}
