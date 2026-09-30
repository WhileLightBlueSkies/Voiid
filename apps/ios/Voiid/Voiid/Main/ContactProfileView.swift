//
//  ContactProfileView.swift
//  Voiid
//
//  1:1 contact profile: header (real photo / name / identity) + quick actions,
//  about, shared media, mute, block/report.
//
//  Structure is MIRRORED by Android ContactProfileView.kt — same sections in the same
//  order with the same icons, so the two apps read as one product.
//
//  A row that does nothing is worse than no row: every action here is wired, and the two
//  that genuinely have no implementation yet (search-in-chat, wallpaper) are gone rather
//  than left as dead taps.
//

import SwiftUI

struct ContactProfileView: View {
    let conversation: VConversation
    /// Set by Call / Video, read by ChatDetailView after this screen pops. The chat owns the
    /// single call-setup path; duplicating it here would let the two drift.
    @Binding var pendingCall: CallKind?
    @EnvironmentObject var session: AppSession
    /// Needed for Clear chat, which now lives in the danger card below.
    @EnvironmentObject var chat: ChatStore
    @Environment(\.dismiss) private var dismiss
    /// Seeded from `MuteStore` on appear — the old `muted` flag was view state that reset
    /// on every open.
    @State private var isMuted = false
    /// Names what was just copied, for the confirmation toast. A copy with no feedback is
    /// indistinguishable from a tap that did nothing.
    @State private var copiedLabel: String?
    @State private var viewPhoto = false
    @State private var photoDrag: CGFloat = 0
    @State private var expandedPhoto: UIImage?
    @State private var avatarFrame: CGRect = .zero
    @State private var photoExpanded = false
    @Environment(\.accessibilityReduceMotion) private var photoReduceMotion
    @State private var showAllMedia = false
    @State private var profile: UserProfile?
    /// Blocking (043). Observed so the row flips between Block and Unblock the moment the
    /// mutation lands, without this view tracking its own copy of the state.
    @ObservedObject private var blocks = BlockService.shared
    @State private var blockFailure: String?
    /// Report flow: the confirmation establishes intent, the sheet collects the reason.
    @State private var showReportSheet = false

    /// Explicit states, because "profile == nil" meant BOTH "still loading" and "failed" —
    /// and the screen drew the same empty page for each.
    private enum LoadState { case loading, loaded, failed }
    @State private var loadState: LoadState = .loading
    @State private var showSafetyNumber = false
    @State private var showBlockConfirm = false
    @State private var showClearChatConfirm = false
    @State private var showReportConfirm = false
    @State private var notImplemented: String?

    /// Display name with the app-wide precedence: the name YOU saved in your address
    /// book wins over the name the peer chose for themselves at signup. Previously
    /// this preferred `profile?.name` (their signup name), so a contact you'd saved as
    /// "Mum" showed up as whatever they typed when registering.
    private var displayName: String {
        guard let peer = conversation.peerUserId else { return conversation.title }
        return UserDirectory.shared.displayName(peer, fallback: profile?.name ?? conversation.title)
    }

    /// Shown under the name: the phone number if we have one, else the peer's own
    /// profile name when it differs from what we're displaying — so there is always a
    /// second identifying line rather than a bare name.
    private var secondaryIdentity: String? {
        guard let peer = conversation.peerUserId else { return nil }
        if let phone = UserDirectory.shared.user(peer)?.phoneE164, !phone.isEmpty { return phone }
        if let full = profile?.name, !full.isEmpty, full != displayName { return full }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Full-bleed: no horizontal padding, and it runs UNDER the status bar. A
                // photo inset from the edges reads as a picture ON a page; one that touches
                // all three edges reads as the page itself, which is the point.
                headerCard

                // 20pt between sections, not 24 — with titles sitting outside the cards,
                // each section already carries 8pt of its own leading space, and 24 opened
                // gaps wide enough to read as unrelated screens stacked together.
                // THE REFERENCE'S ORDER AND SPACING: 10pt between sections, not 20.
                //
                // Encryption comes straight after the actions rather than sixth — it is a
                // fact about this conversation, and burying it under About and Media made
                // the page's most load-bearing statement its least prominent.
                //
                // 10pt reads as one continuous page; at 20 each card floated as its own
                // screen. Calls and Settings have no reference equivalent and keep their
                // place at the end, before the danger zone.
                // THE REFERENCE'S ORDER, exactly (Voiid Ui ContactScreen): identity, actions,
                // contact details, encryption, about, media, block/report, footer.
                VStack(spacing: 10) {
                    quickActions
                    contactDetailsCard
                    encryptionCard
                    aboutCard
                    sharedMediaCard
                    callHistoryCard
                    dangerCard
                    versionNote
                        .padding(.top, VoiidSpacing.sm)
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.top, 10)
                .padding(.bottom, VoiidSpacing.xl)
                // SKELETON TO CONTENT IS A CROSSFADE, NOT A CUT.
                //
                // The skeletons are deliberately the same GEOMETRY as the real text, so the
                // layout does not move when the profile lands — but the swap itself was one
                // frame, which made that carefully-matched geometry read as a glitch rather
                // than as content arriving. Fading turns "the screen flickered" into "it
                // loaded".
                //
                // On the SECTION STACK, not on each card: every card swaps on the same
                // `loadState`, so one modifier covers all of them and they resolve together
                // instead of popping in a ragged sequence.
                //
                // Opacity only — nothing travels, so this is safe under Reduce Motion and
                // needs no gate. Keyed on `loadState` rather than `profile` so a silent
                // refresh that changes nothing visible does not flash the page.
                .animation(.easeInOut(duration: 0.22), value: loadState)
            }
        }
        // The photo extends past the top safe area; everything else respects it.
        // A FLAT GROUND, and the safe area respected.
        //
        // Both the tinted wash and the `ignoresSafeArea` existed to serve the full-bleed
        // portrait: the photo ran under the status bar, and the glass cards needed something
        // to sample or they rendered as grey slabs. With a centred avatar on a plain ground
        // there is no photo to bleed and nothing to sample, so the tint is now just a
        // coloured haze over a details page.
        .background(VoiidColor.background.ignoresSafeArea())
        // Confirmation, bottom-anchored so it never covers the row just tapped. Auto-
        // dismissing because it is status, and status that must be dismissed is a task.
        .overlay(alignment: .bottom) {
            if let copiedLabel {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
                    Text("\(copiedLabel) copied").font(VoiidFont.rounded(14, .medium))
                }
                .foregroundColor(VoiidColor.textOnAccent)
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, 10)
                .background(Capsule().fill(VoiidColor.accent))
                .padding(.bottom, VoiidSpacing.xl)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .scrollIndicators(.hidden)
        .softTopEdgeEffect()
        // THE REFERENCE'S CHROME: two floating circles over the page rather than the system
        // bar, so the page starts at the avatar. The system bar is hidden, and swipe-back is
        // restored explicitly — hiding the back button otherwise kills the edge swipe.
        .overlay(alignment: .top) { floatingHeader }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .voiidInteractiveSwipeBack()
        // The system's own chevron and tint. The forced-white version was correct while a
        // dark photograph sat behind the bar; on the flat ground it is now white-on-light —
        // the one control that must always be findable would be invisible.
        // Hide the bottom bar on this detail screen. We do NOT reset on disappear: when you
        // pop back to the CHAT (also a detail screen) its onAppear does not re-fire, so a
        // reset here would wrongly show the bar over the chat. The bar is restored only when
        // a ROOT tab page appears (each sets hideTabBar = false).
        .onAppear {
            session.hideTabBar = true
            // Read from the store, not remembered in the view. A mute set here survives the
            // app being killed, and one set on another screen shows up correctly here.
            isMuted = MuteStore.isMuted(conversation.id)
        }
        .task { await loadProfile() }
        .task { await loadLocalContent() }
        .overlay {
            if viewPhoto {
                GeometryReader { geometry in
                    ZStack {
                        Color.black.opacity(photoExpanded ? 0.72 : 0).ignoresSafeArea()
                            .onTapGesture { setPhotoVisible(false) }
                        let diameter = max(88, min(geometry.size.width - 48, geometry.size.height - 96, 360))
                        let origin = geometry.frame(in: .global)
                        let side = photoExpanded ? diameter : avatarFrame.width
                        Group {
                            if let expandedPhoto {
                                Image(uiImage: expandedPhoto).resizable().scaledToFill()
                                    .frame(width: side, height: side).clipShape(Circle())
                            } else {
                                ProfileAvatarButton(photoURL: photoRef, name: displayName, size: side)
                            }
                        }
                        .task(id: photoRef) {
                            guard let ref = photoRef else { return }
                            let image = await AvatarStorage.shared.expandedPhoto(ref)
                            guard !Task.isCancelled else { return }
                            expandedPhoto = image
                        }
                            .position(x: photoExpanded ? geometry.size.width / 2 : avatarFrame.midX - origin.minX,
                                      y: photoExpanded ? geometry.size.height / 2 : avatarFrame.midY - origin.minY)
                            .accessibilityLabel("Profile photo of \(displayName)")
                            .offset(y: photoDrag)
                            .gesture(DragGesture(minimumDistance: 12)
                                .onChanged { value in
                                    guard abs(value.translation.height) > abs(value.translation.width) else { return }
                                    photoDrag = max(0, value.translation.height)
                                }
                                .onEnded { value in
                                    if photoDrag > 100 || (photoDrag > 24 && value.predictedEndTranslation.height > 260) {
                                        setPhotoVisible(false)
                                    } else {
                                        withAnimation(.easeOut(duration: 0.2)) { photoDrag = 0 }
                                    }
                                })
                        VStack {
                            HStack {
                                Spacer()
                                Button { setPhotoVisible(false) } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(.white).frame(width: 48, height: 48)
                                        .background(.white.opacity(0.14), in: Circle())
                                }.accessibilityLabel("Close profile photo")
                            }
                            Spacer()
                        }.padding(16).opacity(photoExpanded ? 1 : 0)

                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape) { setPhotoVisible(false) }
                }
                .onAppear {
                    withAnimation(photoReduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1)) {
                        photoExpanded = true
                    }
                }
                .zIndex(10)
            }
        }
        .sheet(isPresented: $showSafetyNumber) {
            SafetyNumberView(peerUserId: conversation.peerUserId ?? "", peerName: displayName)
        }
        .sheet(isPresented: $showAllMedia) { SharedMediaSheet(title: conversation.title, conversationId: conversation.id) }
        .sheet(isPresented: $showAllCalls) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(allCalls.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { callDivider }
                            callRow(entry)
                        }
                    }
                    .glassCard()
                    .padding(VoiidSpacing.md)
                }
                .background(VoiidColor.background)
                .navigationTitle("Calls with \(firstName)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showAllCalls = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Clear this chat?", isPresented: $showClearChatConfirm,
                            titleVisibility: .visible) {
            Button("Clear chat", role: .destructive) {
                chat.clearChat(conversation.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every message in this conversation is deleted from this device. This cannot be undone.")
        }
        // Block / unblock. The copy differs because the two actions promise different
        // things, and because blocking is SYMMETRIC — saying only "they won't be able to
        // message you" would leave the user to discover their own sends failing and read
        // it as a bug.
        .confirmationDialog(
            isBlocked ? "Unblock \(displayName)?" : "Block \(displayName)?",
            isPresented: $showBlockConfirm, titleVisibility: .visible
        ) {
            if isBlocked {
                Button("Unblock") { toggleBlock() }
            } else {
                Button("Block", role: .destructive) { toggleBlock() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isBlocked
                 ? "You'll both be able to message and call each other again."
                 : "Neither of you will be able to message or call the other. They won't be "
                   + "told. Your messages and any groups you share stay where they are.")
        }
        // A group has no single person to report, so the sheet is only reachable when there
        // is a peer. Guarded here rather than inside the sheet: a sheet that opens and
        // cannot submit is worse than a button that explains itself.
        .sheet(isPresented: $showReportSheet) {
            if let peerId = conversation.peerUserId {
                ReportSheet(target: .person(userId: peerId)) { showReportSheet = false }
            } else {
                VStack(spacing: 14) {
                    Text("There's no individual contact to report in a group.")
                        .font(VoiidFont.rounded(16, .regular))
                        .foregroundColor(VoiidColor.textPrimary)
                        .multilineTextAlignment(.center)
                    Button("OK") { showReportSheet = false }
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(VoiidColor.primary)
                }
                .padding(32)
            }
        }
        .alert(isBlocked ? "Couldn't unblock" : "Couldn't block",
               isPresented: Binding(get: { blockFailure != nil },
                                    set: { if !$0 { blockFailure = nil } })) {
            Button("OK", role: .cancel) { blockFailure = nil }
        } message: {
            Text(blockFailure ?? "")
        }
        .confirmationDialog("Report \(displayName)?", isPresented: $showReportConfirm, titleVisibility: .visible) {
            // Opens the SHEET rather than submitting. The confirmation establishes intent;
            // a report needs a reason, and a one-tap Report that guessed one would file
            // "spam" against someone reported for something serious.
            Button("Report", role: .destructive) { showReportSheet = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The last few messages from this chat are sent to Voiid for review.")
        }
        .alert("Not available yet",
               isPresented: Binding(get: { notImplemented != nil },
                                    set: { if !$0 { notImplemented = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notImplemented ?? "")
        }
    }

    // Header: a full-bleed portrait with the identity laid over it.
    //
    // WHY NOT A CENTERED AVATAR ON A CARD. That layout — round photo, name under it,
    // buttons under that, all centered on a plain ground — is the 2016 iOS profile, and it
    // wastes the one asset the screen actually has: the person's photo, shown at 104pt in a
    // circle while two thirds of the width sits empty. Apple stopped building profiles that
    // way years ago; Contacts, Photos and Music all now anchor identity to a large image and
    // let content scroll beneath it.
    //
    // So the photo goes edge-to-edge at the top, the name sits ON it in white, and the
    // scrim underneath guarantees the text is legible over ANY photo — a dark portrait, a
    // blown-out selfie, or no photo at all. Nothing is centered for its own sake.
    /// Identity — the Voiid Ui reference's `ContactScreen.identity`.
    ///
    /// ── A CENTRED AVATAR, NOT A FULL-BLEED PORTRAIT ─────────────────────────────
    /// This was a 360pt photograph running under the status bar with the name laid over a
    /// scrim. It looked striking and it was the wrong screen: a contact page is a page of
    /// DETAILS, and a photograph occupying the top third pushes every one of them below the
    /// fold. The reference gives the face 88pt and lets the information start immediately.
    ///
    /// The reference's own note explains the ring: no glow, no double ring — those belong to
    /// the call screen, where a ring reports live audio and earns its place. On a static
    /// portrait it is decoration that makes the avatar the loudest thing on a screen whose
    /// job is details.
    private var headerCard: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Button { setPhotoVisible(true) } label: {
                avatar.opacity(viewPhoto ? 0 : 1)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { avatarFrame = $0 }

            }
                .buttonStyle(.plain)
                .disabled(photoRef == nil && conversation.photoName == nil)
                .accessibilityLabel("View profile photo")
                .overlay(Circle().stroke(VoiidColor.accent.opacity(0.6), lineWidth: 2))
                // 16, not the reference's 52.
                //
                // The reference draws its OWN floating back button over the content, so it
                // must reserve the full height of that chrome. Ours uses the system
                // navigation bar, which already occupies that space — adding 52 on top of it
                // pushed the avatar a bar's height down the screen and left a visible gap
                // under the title.
                //
                // Copying the number without the layout it compensates for is how a value
                // that is correct in one place becomes wrong in another.
                // Clears the floating header, as in the reference.
                .padding(.top, 52)

            HStack(spacing: 6) {
                Text(displayName)
                    .font(VoiidFont.rounded(22, .bold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                // NO VERIFIED SEAL. The reference draws one, but `UserProfile` carries no
                // verification flag — a badge that is either always shown or never shown
                // says nothing. It goes in the day the field exists.
            }

            // PRESENCE, from the same live source as the chat header, and hidden by the same
            // privacy switch. When nothing is known the line is left out rather than guessed.
            if let presence {
                Text(presence.text)
                    .font(VoiidFont.rounded(14))
                    .foregroundColor(presence.online ? VoiidColor.onlineText : VoiidColor.textSecondary)
            }

            encryptedPill
        }
        .frame(maxWidth: .infinity)
    }

    @ObservedObject private var privacy = PrivacySettings.shared

    private var presence: (text: String, online: Bool)? {
        guard privacy.showOnlineStatus else { return nil }
        let live = chat.directConversations.first(where: { $0.id == conversation.id })
        if live?.isOnline == true { return ("Online", true) }
        if let seen = live?.lastSeenAt { return ("Last seen \(VoiidDate.relative(seen))", false) }
        return nil
    }

    /// Back and More, floating over the page — the reference's header.
    ///
    /// MORE IS A REAL MENU. The reference draws the button and leaves it empty; here it holds
    /// the two conversation actions that have no tile of their own, so it is never a dead tap.
    private var floatingHeader: some View {
        HStack {
            Button { Haptics.tap(); dismiss() } label: {
                circleChrome("chevron.left")
            }
            .buttonStyle(SoftPressStyle())
            .accessibilityLabel("Back")

            Spacer(minLength: 0)

            Menu {
                Button { showSafetyNumber = true } label: {
                    Label("Verify safety number", systemImage: "lock.shield")
                }
                Button(role: .destructive) { showClearChatConfirm = true } label: {
                    Label("Clear chat", systemImage: "trash")
                }
            } label: {
                circleChrome("ellipsis")
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.xs)
    }

    private func circleChrome(_ icon: String) -> some View {
        Circle()
            .fill(VoiidColor.surfaceCard)
            .frame(width: 38, height: 38)
            .overlay(Circle().stroke(VoiidColor.divider, lineWidth: 1))
            .overlay {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
            }
            .contentShape(Circle())
    }

    /// The reference's footer. It said "You're both using the latest version of Voiid", which
    /// this app cannot know about the other phone — so the same line states what IS true.
    private var versionNote: some View {
        HStack(alignment: .top, spacing: VoiidSpacing.sm) {
            Image(systemName: "lock.fill")
                .font(.system(size: 13))
                .foregroundColor(VoiidColor.textSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(VoiidColor.surfaceCard))
            Text("Messages and calls with \(firstName) are end-to-end encrypted.\nYour conversations are protected.")
                .font(VoiidFont.rounded(12.5))
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// 88pt, no photo bleed. Falls back to initials on the brand gradient.
    private func setPhotoVisible(_ visible: Bool) {
        if visible {
            photoExpanded = false
            photoDrag = 0
            viewPhoto = true
        } else {
            withAnimation(.easeInOut(duration: photoReduceMotion ? 0.15 : 0.3), completionCriteria: .logicallyComplete) {
                photoExpanded = false
                photoDrag = 0
            } completion: {
                viewPhoto = false
            }
        }
    }

    private var avatar: some View {
        ProfileAvatarButton(photoURL: photoRef, name: displayName, size: 88)
    }

    /// The encryption guarantee, stated on the identity block rather than only as a row far
    /// down the page — it is a property of this contact, and the reference treats it as
    /// identity rather than as a setting.
    private var encryptedPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").font(.system(size: 12))
            Text("End-to-end Encrypted").font(VoiidFont.rounded(13, .medium))
        }
        .foregroundColor(VoiidColor.accentInk)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(VoiidColor.accent.opacity(0.10)))
        .overlay(Capsule().stroke(VoiidColor.accent.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    /// FOUR EQUAL TILES — the Voiid Ui reference's `ContactScreen.actions`.
    ///
    /// Mute joins Message, Voice call and Video call as the fourth. It used to be a separate
    /// "Notifications" card near the bottom, which put an action you reach for on this
    /// contact below their shared media and call history. Muting passes the same test as the
    /// other three — it is something you do TO this conversation from here — so it sits with
    /// them, and the tile turns solid while it is on, saying so without opening anything.
    private var quickActions: some View {
        HStack(spacing: 10) {
            actionTile("message", "Message") { dismiss() }
            actionTile("phone", "Voice call") { requestCall(.voice) }
            actionTile("video", "Video call") { requestCall(.video) }
            muteTile
        }
    }

    private func actionTile(_ icon: String, _ label: String,
                            _ tap: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); tap() } label: {
            tileLabel(icon: icon, label: label, isActive: false)
        }
        .buttonStyle(SoftPressStyle())
        .accessibilityLabel(label)
    }

    /// Mute: the system dropdown of durations, opened from the tile. A switch silently picks
    /// the most extreme mute; a duration lifts on its own. Unmute leads when already muted.
    ///
    /// ── THE MENU HANGS OFF AN INVISIBLE UIKIT BUTTON ────────────────────────────
    /// As a SwiftUI `Menu`, iOS lifted the TILE itself into the menu's presentation and, after
    /// closing, kept it in that layer — so while the page scrolled the tile lagged and bobbed
    /// up and down. Here the visible tile is plain SwiftUI and the real `UIMenu` belongs to a
    /// transparent UIButton laid over it: the same native dropdown, but what gets lifted is
    /// invisible, and the tile never leaves the scroll.
    private var muteTile: some View {
        tileLabel(icon: isMuted ? "bell.slash.fill" : "bell",
                  label: muteTileLabel, isActive: isMuted)
            .overlay {
                NativeMenuButton(menu: muteMenu)
                    .accessibilityLabel(isMuted ? "Notifications \(muteSubtitle)" : "Mute")
                    .accessibilityHint("Choose how long to mute")
            }
    }

    private var muteMenu: UIMenu {
        var items: [UIMenuElement] = []
        if isMuted {
            items.append(UIAction(title: "Unmute", image: UIImage(systemName: "bell"),
                                  attributes: .destructive) { _ in unmute() })
        }
        let durations = MuteStore.Duration.allCases.map { d in
            UIAction(title: d == .always ? "Always" : d.title,
                     image: UIImage(systemName: d == .always ? "bell.slash.fill" : "clock")) { _ in
                mute(for: d)
            }
        }
        items.append(UIMenu(title: "Mute for", options: .displayInline, children: durations))
        return UIMenu(children: items)
    }

    /// Says WHEN it lifts — "Muted" alone leaves the user guessing whether it is an hour or
    /// forever, which is the problem the durations exist to solve.
    private var muteTileLabel: String {
        guard isMuted else { return "Mute" }
        guard let until = MuteStore.mutedUntil(conversation.id) else { return "Muted" }
        let hours = max(1, Int((until.timeIntervalSinceNow / 3600).rounded(.up)))
        return hours < 24 ? "Muted · \(hours)h" : "Muted · \((hours + 23) / 24)d"
    }

    /// One appearance for all four tiles, so the three buttons and the mute menu cannot drift.
    private func tileLabel(icon: String, label: String, isActive: Bool) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(isActive ? VoiidColor.textOnAccent : VoiidColor.accentInk)
                .contentTransition(.symbolEffect(.replace))
            Text(label)
                .font(VoiidFont.rounded(11.5, .medium))
                .foregroundColor(isActive ? VoiidColor.textOnAccent : VoiidColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .background(isActive ? VoiidColor.accent : VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
            .stroke(isActive ? VoiidColor.accent : VoiidColor.divider, lineWidth: 1))
        .animation(.easeOut(duration: 0.18), value: isActive)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    /// The peer's photo reference, preferring the freshly-fetched profile and falling back to
    /// whatever the directory already cached — so a face shows on the first frame offline.
    private var photoRef: String? {
        // Freshest first, then two caches. The CONVERSATION's photo is the third fallback and
        // it matters: it is already on screen in the chat header the user just tapped, so
        // omitting it meant the profile could open with a blank portrait for a face the app
        // was displaying a moment earlier.
        if let u = profile?.photoURL, !u.isEmpty { return u }
        if let peer = conversation.peerUserId,
           let cached = UserDirectory.shared.photoURL(peer), !cached.isEmpty { return cached }
        if let convPhoto = conversation.photoURL, !convPhoto.isEmpty { return convPhoto }
        return nil
    }

    /// Call and Video used to be EMPTY closures — the buttons were decoration.
    ///
    /// Rather than duplicate ChatDetailView's call setup (which resolves the peer id, checks
    /// the group-call lock and builds a CallRequest), this pops back to the chat and asks it
    /// to place the call. One code path owns starting a call, so the two can never drift.
    private func requestCall(_ kind: CallKind) {
        pendingCall = kind
        dismiss()
    }

    /// About AND status — two distinct fields the server has always returned separately
    /// (`bio` and `status_text`). They were being collapsed into one, so a user who set a
    /// status saw it labelled "About" and a user with both lost the status entirely.
    @ViewBuilder
    private var aboutCard: some View {
        // The reference's About card: a title and the words, nothing else — and ABSENT when
        // the person wrote nothing, rather than a stock line they never wrote. Status and bio
        // are separate server fields; status is parsed against the vocabulary so an
        // unrecognised value shows as nothing rather than as unvetted text.
        let status = AvailabilityStatus.from(profile?.statusText)
        let about = (profile?.about ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let aboutShown = about == status?.label ? "" : about
        if loadState == .loading || loadState == .failed || status != nil || !aboutShown.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("About")
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)

                if loadState == .loading && status == nil && aboutShown.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule().fill(VoiidColor.textPrimary.opacity(0.08)).frame(height: 12)
                        Capsule().fill(VoiidColor.textPrimary.opacity(0.08)).frame(width: 180, height: 12)
                    }
                    .modifier(PulsePlaceholder())
                } else if loadState == .failed && status == nil && aboutShown.isEmpty {
                    HStack(spacing: VoiidSpacing.sm) {
                        Text("Couldn't load profile")
                            .font(VoiidFont.rounded(14))
                            .foregroundColor(VoiidColor.textSecondary)
                        Spacer(minLength: 0)
                        Button("Retry") { Haptics.tap(); Task { await loadProfile() } }
                            .font(VoiidFont.rounded(14, .semibold))
                            .foregroundStyle(VoiidColor.primary)
                    }
                } else {
                    if let status {
                        HStack(spacing: 5) {
                            Image(systemName: status.systemImage)
                                .font(.system(size: 11))
                                .foregroundColor(status.tint)
                            Text(status.label)
                                .font(VoiidFont.rounded(14))
                                .foregroundColor(VoiidColor.textSecondary)
                        }
                    }
                    if !aboutShown.isEmpty {
                        Text(aboutShown)
                            .font(VoiidFont.rounded(14))
                            .foregroundColor(VoiidColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(VoiidSpacing.md)
            .glassCard()
        }
    }

    /// All shared visual media in this 1:1, newest first — real, from the message store.
    /// Videos count too: the strip previously filtered to `image/` only, so a chat full of
    /// videos reported "no media shared yet".
    /// Computed ONCE, in `.task`, not on every render.
    ///
    /// THIS IS WHY THE PROFILE FELT SLOW. It was a computed property that decoded the whole
    /// message store for this conversation, filtered it and reversed it — and SwiftUI
    /// evaluated it SIX times per render pass (`isEmpty` in the accessory, `isEmpty` again in
    /// the body, `count`, `prefix(8)`, and so on). On a chat with real history that is six
    /// full decodes for one frame, on the main actor, every time anything on the screen
    /// changed. Same for `recentCalls`, which hit SQLite three times per render.
    @State private var sharedMedia: [MediaRef] = []
    @State private var recentCalls: [LocalStore.CallHistoryEntry] = []
    /// The fuller list behind "See all". Held so expanding costs no query.
    @State private var allCalls: [LocalStore.CallHistoryEntry] = []
    @State private var showAllCalls = false

    /// Load both off the render path. Cheap enough to redo on appear (so a photo sent while
    /// the profile was open shows up), expensive enough that it must never sit in `body`.
    private func loadLocalContent() async {
        let convId = conversation.id
        // LET THE PUSH FINISH FIRST. This used to start on the frame the profile appeared,
        // so its work competed with the slide-in and the transition stuttered.
        try? await Task.sleep(for: .milliseconds(320))
        guard !Task.isCancelled else { return }
        // From the chat that is ALREADY IN MEMORY (ChatStore holds the open conversation).
        // `ChatEngine.messages` looked off-main but ChatEngine is @MainActor, so it re-decoded
        // and re-sorted the whole history on the main thread — the lag on opening a profile
        // from a long chat.
        let media: [MediaRef] = chat.messages(for: convId)
            .compactMap { $0.mediaRef }
            .filter { $0.mime.hasPrefix("image/") || $0.mime.hasPrefix("video/") }
            .reversed()
        // Load more than the card shows, so "See all" has something to reveal without a
        // second query. 40 bounds it — a card is not a call log.
        allCalls = Array(LocalStore.callsForConversation(convId).reversed().prefix(40))
        let calls = Array(allCalls.prefix(4))
        sharedMedia = media
        recentCalls = calls
    }

    /// The reference's media card: a header that is itself the way in (title, count,
    /// chevron), then one row of equal squares ending in the overflow count as a tile.
    /// A "+12" that cannot be tapped is a tease, so it opens the same gallery.
    @ViewBuilder
    private var sharedMediaCard: some View {
        // The reference's card: a header that is itself the way in, then one row of equal
        // squares ending in the overflow count. Absent when nothing has been shared, as in
        // the reference.
        if !sharedMedia.isEmpty {
            VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                Button { Haptics.tap(); showAllMedia = true } label: {
                    HStack {
                        Text("Media")
                            .font(VoiidFont.rounded(16, .semibold))
                            .foregroundColor(VoiidColor.textPrimary)
                        Spacer(minLength: 0)
                        Text("\(sharedMedia.count)")
                            .font(VoiidFont.rounded(15))
                            .foregroundColor(VoiidColor.textSecondary)
                            .monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(VoiidColor.textSecondary.opacity(0.7))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                let overflow = sharedMedia.count - 4
                HStack(spacing: 8) {
                    ForEach(Array(sharedMedia.prefix(overflow > 1 ? 4 : 5)), id: \.mediaUrl) { ref in
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay { SharedMediaThumb(ref: ref) }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    if overflow > 1 {
                        Button { Haptics.tap(); showAllMedia = true } label: {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(VoiidColor.fieldFill)
                                .aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    Text("+\(overflow)")
                                        .font(VoiidFont.rounded(15, .semibold))
                                        .foregroundColor(VoiidColor.textPrimary)
                                        .minimumScaleFactor(0.7)
                                        .lineLimit(1)
                                }
                        }
                        .buttonStyle(SoftPressStyle())
                        .accessibilityLabel("See all \(sharedMedia.count) items")
                    } else if sharedMedia.count < 5 {
                        ForEach(0..<(5 - sharedMedia.count), id: \.self) { _ in
                            Color.clear.aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
            }
            .padding(VoiidSpacing.md)
            .glassCard()
        }
    }

    /// The empty state.
    ///
    /// GHOST TILES, not a floating icon in a void. The previous version centred a disc and two
    /// lines in an otherwise blank card, which read as a hole in the layout rather than an
    /// empty shelf. Showing the SHAPE the content will take — three dashed squares the size of
    /// real thumbnails — makes the card look designed-but-empty, and tells the user at a
    /// glance what would appear here.
    private var mediaEmptyState: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            HStack(spacing: VoiidSpacing.sm) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                        // A faint FILL under the dashes. On the old opaque card an outline
                        // alone was enough; on glass a bare dashed rectangle has nothing to
                        // sit on and reads as scratches across the blur. The fill gives each
                        // ghost tile a body, so it reads as an empty slot.
                        .fill(VoiidColor.textPrimary.opacity(0.04))
                        .frame(width: 76, height: 76)
                        .overlay(
                            RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                                .strokeBorder(VoiidColor.divider,
                                              style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        )
                        .overlay {
                            Image(systemName: i == 0 ? "photo" : (i == 1 ? "video" : "doc"))
                                .font(.system(size: 18))
                                .foregroundStyle(VoiidColor.placeholder.opacity(0.5))
                        }
                }
                Spacer(minLength: 0)
            }
            Text("Photos, videos and files you share with \(displayName) appear here.")
                .font(VoiidFont.rounded(12, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
        }
        .padding(.vertical, 2)
    }

    /// Recent calls with this person, from the local `call_history` table.
    ///
    /// The transcript already shows call bubbles, but a profile is where you go to answer
    /// "how often do we actually talk?" — and scrolling a whole chat to reconstruct that is
    /// not an answer. Same data, different question.


    /// Phone and @username — the reference's `contactDetails`, and the one section of that
    /// screen we never had.
    ///
    /// ── EVERY VALUE IS COPYABLE, AND SAYS SO ────────────────────────────────────
    /// A phone number on a profile exists to be USED: dialled, pasted into a message, sent
    /// to someone else. Showing it as inert text means the only way to get it out is to
    /// read it aloud. Tapping the value copies it and a toast confirms — feedback on the
    /// causal event, not silence.
    ///
    /// The trailing button is the value's PRIMARY action, separate from copying: a phone
    /// number calls, a username opens a chat. Two intentions, two targets, so neither has to
    /// be guessed at.
    @ViewBuilder
    private var contactDetailsCard: some View {
        // ── WHERE THE PHONE NUMBER COMES FROM, AND WHY IT IS OFTEN ABSENT ───────
        //
        // NOT from the profile. The server returns `phone_number` only to the account's
        // OWNER (users.ts: `isOwner ? u.phone_number : undefined`) — a number is an
        // account's identity and is never disclosed to anyone else. Reading it from
        // `profile` would therefore always be nil for a contact, and the row would never
        // appear at all.
        //
        // The number shown here is the one from YOUR OWN ADDRESS BOOK, matched during
        // contact sync. That is the correct source and the correct behaviour: you see a
        // number you already had, not one the app disclosed to you.
        //
        // So someone who reached you by @username, and whom you have never saved, shows
        // only their handle — there is no number to show, and inventing one would leak
        // exactly what the server is careful not to.
        let phone = conversation.peerUserId
            .flatMap { UserDirectory.shared.user($0)?.phoneE164 }?
            .trimmingCharacters(in: .whitespaces)
        let handle = profile?.username?.trimmingCharacters(in: .whitespaces)

        if (phone?.isEmpty == false) || (handle?.isEmpty == false) {
            // THE REFERENCE'S CARD: title inside, rows edge to edge, an inset rule between.
            // Phone's trailing button messages them; the username's copies it.
            VStack(alignment: .leading, spacing: 0) {
                Text("Contact details")
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.top, VoiidSpacing.md)
                    .padding(.bottom, VoiidSpacing.sm)

                if let phone, !phone.isEmpty {
                    detailRow(icon: "phone", label: "Phone number", value: phone)
                    if handle?.isEmpty == false {
                        Rectangle()
                            .fill(VoiidColor.divider)
                            .frame(height: 1)
                            .padding(.leading, 60)
                    }
                }
                if let handle, !handle.isEmpty {
                    detailRow(icon: "at", label: "Username", value: "@\(handle)")
                }
            }
            .padding(.bottom, VoiidSpacing.sm)
            .glassCard()
        }
    }

    private func copy(_ value: String, as label: String) {
        UIPasteboard.general.string = value
        Haptics.success()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { copiedLabel = label }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.25)) { copiedLabel = nil }
        }
    }

    /// One detail row.
    ///
    /// ── MAPPING: THE CONTROL SITS BY WHAT IT AFFECTS ────────────────────────────
    /// Three things live on this row and each has one job. The glyph names the KIND of
    /// value. The label/value pair IS the value, and tapping it copies — the most common
    /// thing anyone wants from a number on a screen. The trailing button is that value's
    /// own action: a number calls, a handle messages.
    ///
    /// ── HIERARCHY: THE VALUE IS THE CONTENT ─────────────────────────────────────
    /// The value is 15pt medium in primary ink; its label is 13pt secondary ABOVE it. That
    /// order matters — reading down, you meet the category then the thing, which is how a
    /// form reads. Reversing it makes the label the headline of a row whose subject is the
    /// number.
    ///
    /// ── FEEDBACK ON THE CAUSAL EVENT ────────────────────────────────────────────
    /// Copy fires a success haptic and a toast naming what was copied, on the same frame as
    /// the tap. A copy with no feedback is indistinguishable from a tap that missed.
    /// A detail row: glyph, label, value; tapping the row copies the value.
    ///
    /// NO TRAILING BUTTONS (Voiid Ui ContactScreen). The message and copy icons repeated
    /// actions the screen already has — Message is the first tile, and the row copies.
    private func detailRow(icon: String, label: String, value: String) -> some View {
        Button { copy(value, as: label) } label: {
            HStack(spacing: VoiidSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(VoiidColor.accentInk)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(VoiidFont.rounded(13))
                        .foregroundColor(VoiidColor.textSecondary)
                    Text(value)
                        .font(VoiidFont.rounded(15, .medium))
                        .foregroundColor(VoiidColor.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel("\(label), \(value)")
        .accessibilityHint("Copies to the clipboard")
    }

    /// Calls with this person — the Voiid Ui design, on the real `call_history` table.
    ///
    /// The header says how you talk in one line (how many calls, how long in total); the rows
    /// are the three most recent, because that is what anyone opening a profile after a missed
    /// call is looking for. A missed call carries Call back: the one row whose obvious next
    /// action is not "look at it". Hidden when you have only ever texted.
    @ViewBuilder
    private var callHistoryCard: some View {
        if !allCalls.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Calls")
                            .font(VoiidFont.rounded(16, .semibold))
                            .foregroundColor(VoiidColor.textPrimary)
                        Text(callSummary)
                            .font(VoiidFont.rounded(12.5))
                            .foregroundColor(VoiidColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                    if allCalls.count > 3 {
                        Button { Haptics.tap(); showAllCalls = true } label: {
                            HStack(spacing: 3) {
                                Text("See all")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .font(VoiidFont.rounded(14, .medium))
                            .foregroundColor(VoiidColor.accentInk)
                        }
                        .buttonStyle(SoftPressStyle())
                    }
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.top, VoiidSpacing.md)
                .padding(.bottom, VoiidSpacing.sm)

                ForEach(Array(allCalls.prefix(3).enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { callDivider }
                    callRow(entry)
                }
            }
            .padding(.bottom, VoiidSpacing.xs)
            .glassCard()
        }
    }

    private var callDivider: some View {
        Rectangle().fill(VoiidColor.divider).frame(height: 1).padding(.leading, 64)
    }

    private func isMissed(_ entry: LocalStore.CallHistoryEntry) -> Bool {
        entry.direction == "incoming" && entry.outcome != "answered" && !isRinging(entry)
    }

    /// Still ringing — not missed yet. See `LocalStore.isRinging`.
    private func isRinging(_ entry: LocalStore.CallHistoryEntry) -> Bool {
        LocalStore.isRinging(outcome: entry.outcome, startedAt: entry.startedAt,
                             endedAt: entry.endedAt, connectedAt: entry.connectedAt)
    }

    /// Talk time, from when the call connected (not when it started ringing) to when it ended.
    private func talkSeconds(_ entry: LocalStore.CallHistoryEntry) -> Int {
        guard entry.outcome == "answered", let ended = entry.endedAt else { return 0 }
        return max(0, Int(ended.timeIntervalSince(entry.connectedAt ?? entry.startedAt)))
    }

    /// "4 calls · 35 min talked" — or just the count when nothing connected.
    private var callSummary: String {
        let count = allCalls.count == 1 ? "1 call" : "\(allCalls.count) calls"
        let minutes = allCalls.map(talkSeconds).reduce(0, +) / 60
        return minutes > 0 ? "\(count) · \(minutes) min talked" : count
    }

    private func callRow(_ entry: LocalStore.CallHistoryEntry) -> some View {
        let missed = isMissed(entry)
        let video = entry.kind == "video"
        return HStack(spacing: 12) {
            // The glyph says what kind; the badge says which way; the tint says whether it
            // connected. Red is never the only signal — the title says "Missed" too.
            Circle()
                .fill(missed ? VoiidColor.error.opacity(0.12) : VoiidColor.accent.opacity(0.12))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: video ? "video.fill" : "phone.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(missed ? VoiidColor.error : VoiidColor.accentInk)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: missed ? "xmark"
                          : (entry.direction == "incoming" ? "arrow.down.left" : "arrow.up.right"))
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundColor(.white)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(missed ? VoiidColor.error : VoiidColor.accentInk))
                        .overlay(Circle().stroke(VoiidColor.surfaceCard, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(callTitle(entry))
                    .font(VoiidFont.rounded(15, .medium))
                    .foregroundColor(missed ? VoiidColor.error : VoiidColor.textPrimary)
                Text(entry.startedAt.formatted(.relative(presentation: .named)))
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidColor.textSecondary)
            }

            Spacer(minLength: 0)

            if missed {
                Button {
                    Haptics.tap()
                    showAllCalls = false
                    requestCall(video ? .video : .voice)
                } label: {
                    Text("Call back")
                        .font(VoiidFont.rounded(13, .semibold))
                        .foregroundColor(VoiidColor.textOnAccent)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().fill(VoiidColor.accent))
                }
                .buttonStyle(SoftPressStyle())
            } else {
                Text(callTrailing(entry))
                    .font(VoiidFont.rounded(13))
                    .foregroundColor(VoiidColor.textSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func callTitle(_ entry: LocalStore.CallHistoryEntry) -> String {
        let medium = entry.kind == "video" ? "video" : "voice"
        if isMissed(entry) { return entry.outcome == "declined" ? "Declined \(medium) call" : "Missed \(medium) call" }
        return entry.direction == "incoming" ? "Incoming \(medium)" : "Outgoing \(medium)"
    }

    /// Duration for a call that connected; otherwise what happened to it.
    private func callTrailing(_ entry: LocalStore.CallHistoryEntry) -> String {
        // Ringing, or answered and still going: there is no finished call to describe yet.
        if isRinging(entry) || (entry.outcome == "answered" && entry.endedAt == nil) { return "Now" }
        switch entry.outcome {
        case "answered":
            let secs = talkSeconds(entry)
            if secs < 60 { return "\(secs) sec" }
            let mins = secs / 60
            return mins < 60 ? "\(mins) min" : "\(mins / 60) hr \(mins % 60) min"
        case "busy":     return "Busy"
        case "declined": return "Declined"
        case "failed":   return "Failed"
        default:         return "No answer"
        }
    }

    /// Encryption, and the way to check it.
    ///
    /// A claim of end-to-end encryption that the user cannot verify is a claim they have to
    /// take on faith. This row is what turns it into something checkable — and it sits above
    /// mute and block because it is the more consequential fact about the conversation.
    private var encryptionCard: some View {
        Button {
            Haptics.tap(); showSafetyNumber = true
        } label: {
            HStack(spacing: VoiidSpacing.md) {
                Circle()
                    .fill(VoiidColor.accent.opacity(0.10))
                    .frame(width: 44, height: 44)
                    .overlay(Circle().stroke(VoiidColor.accent.opacity(0.5), lineWidth: 1))
                    .overlay {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 20))
                            .foregroundColor(VoiidColor.accentInk)
                    }
                    .padding(.leading, VoiidSpacing.md)
                VStack(alignment: .leading, spacing: 4) {
                    Text("End-to-end Encrypted")
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(VoiidColor.accentInk)
                    // Names the person, and still says where to CHECK it: a claim you cannot
                    // verify is one you have to take on faith.
                    Text("Messages, calls and media are secured with end-to-end encryption. Only you and \(firstName) can read or listen to them.")
                        .font(VoiidFont.rounded(12.5))
                        .foregroundColor(VoiidColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(VoiidColor.textSecondary.opacity(0.7))
            }
            .padding(.trailing, VoiidSpacing.md)
            .padding(.vertical, VoiidSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPressStyle(scale: 0.98))
        .glassCard()
        .accessibilityElement(children: .combine)
    }

    private var firstName: String {
        displayName.split(separator: " ").first.map(String.init) ?? displayName
    }

    /// Mute, with real durations and real effect.
    ///
    /// ── WHAT THIS REPLACED ──────────────────────────────────────────────────────
    /// A `Toggle` bound to `@State private var muted` — local view state, written nowhere.
    /// It reset to off every time the screen opened and silenced precisely nothing. The
    /// control existed, looked correct, and was decoration.
    ///
    /// ── WHY A MENU AND NOT A SWITCH ─────────────────────────────────────────────
    /// "Mute" is not a binary anyone actually means. Silencing a group for the afternoon
    /// and silencing it permanently are different intentions, and a switch forces the
    /// second when the first is what is usually wanted — so people either never mute, or
    /// mute forever and miss things. The durations make the temporary case reachable.
    ///
    /// A muted conversation still DELIVERS: it lands in Notification Centre and the badge,
    /// without a sound or a banner. Muting means "stop interrupting me", not "hide this".
    private var muteSubtitle: String {
        guard isMuted else { return "On" }
        guard let until = MuteStore.mutedUntil(conversation.id) else { return "Muted" }
        return "Muted until \(VoiidDate.relative(until))"
    }

    private func mute(for duration: MuteStore.Duration) {
        Haptics.tap()
        MuteStore.mute(conversation.id, for: duration)
        isMuted = true
    }

    private func unmute() {
        Haptics.tap()
        MuteStore.unmute(conversation.id)
        isMuted = false
    }

    /// Block is live (043_user_blocks + /blocks, enforced server-side across messages,
    /// calls, profile, presence, conversation creation, group invites, stories and typing).
    /// The row flips to Unblock when this person is already blocked, so the one control
    /// carries both directions rather than hiding the way back.
    ///
    /// Report is live too: the confirmation establishes intent and ReportSheet collects the
    /// reason. The route and table (035_reports) had shipped with no client on either
    /// platform — Android even had a finished sheet that was reachable from nowhere.
    ///
    /// Destructive actions sit LAST and unlabelled — no "DANGER" header shouting at a screen
    /// you opened to see someone's photo. The red carries it, and the confirmation catches
    /// the mistake.
    private var dangerCard: some View {
        // The reference's card: two rows, edge to edge. Clear chat moved to the More menu in
        // the header — it acts on the conversation, not on the person.
        VStack(spacing: 0) {
            Button { Haptics.rigid(); showBlockConfirm = true } label: {
                dangerRow(icon: isBlocked ? "hand.raised.slash.fill" : "hand.raised.fill",
                          title: isBlocked ? "Unblock \(firstName)" : "Block \(firstName)",
                          tint: isBlocked ? VoiidColor.accentInk : VoiidColor.error)
            }
            .buttonStyle(RowButtonStyle())

            Rectangle()
                .fill(VoiidColor.divider)
                .frame(height: 1)
                .padding(.leading, 56)

            Button { Haptics.rigid(); showReportConfirm = true } label: {
                dangerRow(icon: "exclamationmark.bubble.fill",
                          title: "Report \(firstName)", tint: VoiidColor.error)
            }
            .buttonStyle(RowButtonStyle())
        }
        .glassCard()
    }

    private func dangerRow(icon: String, title: String, tint: Color) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 26)
            Text(title)
                .font(VoiidFont.rounded(15, .medium))
                .foregroundColor(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    // MARK: blocking

    /// Whether THIS account has blocked the peer. Answers from BlockService's cache, which
    /// is why the profile does not need its own fetch or its own loading state.
    ///
    /// Deliberately cannot answer the reverse — whether the peer blocked US. There is no
    /// route for that and there must not be: a blocked person being able to detect the
    /// block defeats the point of blocking silently.
    private var isBlocked: Bool {
        guard let peerId = conversation.peerUserId else { return false }
        return blocks.isBlocked(peerId)
    }

    /// Block or unblock, whichever the current state calls for.
    ///
    /// On failure the service has already rolled its optimistic change back, so the row
    /// returns to its previous label on its own; this only has to say what happened. A
    /// silent failure here is the dangerous case — someone believing they are protected
    /// when they are not.
    private func toggleBlock() {
        guard let peerId = conversation.peerUserId else {
            blockFailure = "This conversation has no contact to block."
            return
        }
        let wasBlocked = isBlocked
        Task {
            let ok = wasBlocked
                ? await blocks.unblock(userId: peerId)
                : await blocks.block(userId: peerId,
                                     displayName: displayName,
                                     username: profile?.username,
                                     photoURL: profile?.photoURL)
            if !ok {
                blockFailure = wasBlocked
                    ? "Check your connection and try again. \(displayName) is still blocked."
                    : "Check your connection and try again. \(displayName) has not been blocked."
            }
        }
    }

    // MARK: data

    /// Load the peer's public profile (name, about, username, photo). Phone is not
    /// fetched — the backend doesn't expose it on the profile endpoint (privacy).
    /// Load the peer's public profile.
    ///
    /// THE OLD VERSION FAILED SILENTLY, THREE WAYS. `guard let peerId ... else { return }`
    /// returned with no state change; `try?` swallowed every network and decode error; and
    /// `profile` starting nil is indistinguishable from a load that never finished. All
    /// three produced the same thing on screen: a profile with nothing on it, no spinner, no
    /// message, and no way to retry. Each is now a distinct, visible state.
    private func loadProfile() async {
        guard let peerId = conversation.peerUserId else {
            // No peer id at all — the conversation row never resolved one. Real, and not the
            // user's fault, so it says so rather than rendering a blank page forever.
            loadState = .failed
            return
        }

        loadState = .loading
        do {
            let p = try await ChatService.shared.userProfile(userId: peerId)
            profile = p
            loadState = .loaded
            // Cache what the server told us, so the next visit (and every call from this
            // person) can name them with no network at all.
            UserDirectory.shared.upsertFromServer(userId: peerId, fullName: p.name,
                                                  username: p.username, photoURL: p.photoURL)
        } catch {
            // A cached name/photo is still worth showing — the header renders from the
            // directory, so a failed fetch degrades to "less detail" rather than "nothing".
            loadState = .failed
            NSLog("[VOIID] profile load failed for \(peerId): \(error.localizedDescription)")
        }
    }

    // MARK: helpers
    /// A grouped surface, optionally titled.
    ///
    /// The TITLE SITS OUTSIDE the card, in caps at 12pt — the iOS grouped-list idiom. It was
    /// inside, at 15pt semibold, which made every card open with a line of text the same
    /// weight as its content; six of those stacked gave the page no hierarchy at all. Outside
    /// and quieter, the eye skips titles to find a section and reads content within it.
    private func card<Content: View>(
        _ title: String? = nil,
        accessory: AnyView? = nil,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        // THE TITLE SITS INSIDE THE CARD, as in the Voiid Ui reference: "Contact details",
        // "About", "Calls" each head their own surface, so a section reads as one object
        // rather than a caption floating over a box.
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            if title != nil || accessory != nil {
                HStack(alignment: .firstTextBaseline, spacing: VoiidSpacing.sm) {
                    if let title {
                        Text(title)
                            .font(VoiidFont.rounded(16, .semibold))
                            .foregroundColor(VoiidColor.textPrimary)
                    }
                    Spacer(minLength: 0)
                    accessory
                }
            }
            content()
        }
        .padding(VoiidSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func actionRow(_ icon: String, _ text: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: { Haptics.rigid(); tap() }) {
            HStack(spacing: VoiidSpacing.md) {
                Image(systemName: icon).font(.system(size: 17)).foregroundColor(VoiidColor.error).frame(width: 24)
                Text(text).font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.error)
                Spacer()
            }.padding(.vertical, 4)
        }
        // A 44pt destructive row that does not move under the finger reads as disabled. The
        // rigid haptic on the ACTION stays alongside the press haptic: one says "I felt
        // that", the other says "this is serious". Same deliberate exception as end-call.
        .buttonStyle(SoftPressStyle(scale: 0.98))
    }
}

// MARK: - Glass card

extension View {
    /// A translucent card in the system material.
    ///
    /// `.regularMaterial`, NOT a flat `surfaceCard` fill. Material samples and blurs what is
    /// behind it, so the cards pick up the portrait's colour as you scroll them over it —
    /// the page reads as one continuous surface instead of opaque tiles sliding across a
    /// photo. It is also the language the rest of the OS speaks in 2026, and the app already
    /// uses it on the map and AI chrome.
    ///
    /// NOT `.glassEffect`: that is iOS 26-only and this project targets iOS 18, so it would
    /// have to be availability-gated and would leave older devices with a flat fallback that
    /// looks nothing like the design. Material gets the same result everywhere.
    ///
    /// THE HAIRLINE IS WHAT MAKES IT READ AS GLASS. Without a lit top edge a blurred
    /// rectangle just looks like a washed-out fill; the 1px white-to-transparent stroke is
    /// the specular highlight that says "this has a surface". The shadow is deliberately
    /// soft and low-opacity — enough to lift the card off the ground, not enough to look
    /// like a dropped box.
    /// Apply [glassCard] only when `condition` holds, so a caller can switch between a solid
    /// and a glass treatment without duplicating the whole view.
    @ViewBuilder
    func glassIfNeeded(_ condition: Bool, cornerRadius: CGFloat = 20) -> some View {
        if condition { glassCard(cornerRadius: cornerRadius) } else { self }
    }

    /// A card: flat `surfaceCard` with a hairline — the reference's treatment.
    ///
    /// ── WHY THE GLASS IS GONE ───────────────────────────────────────────────────
    /// The material version existed to solve a problem that no longer exists. The page used
    /// to sit on a tinted wash, `.regularMaterial` blurs toward neutral grey, and the two
    /// read as different colour families — grey slabs on a coloured page. Every part of that
    /// card (the material, the 0.06 primary tint pulling it back into the page's hue, the
    /// white gradient hairline, the drop shadow) was compensation for the wash.
    ///
    /// With a flat ground there is nothing to blur and nothing to reconcile: a translucent
    /// card over a single flat colour is just a slightly dimmer version of that colour, at
    /// the cost of a blur pass per card. The reference draws these flat, and on a flat
    /// ground that is both simpler and more legible.
    ///
    /// The name is kept so every call site stays untouched.
    func glassCard(cornerRadius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(VoiidColor.surfaceCard, in: shape)
            .overlay(shape.stroke(VoiidColor.divider, lineWidth: 1))
    }
}

/// A transparent UIButton whose tap opens a native `UIMenu`. Laid over a SwiftUI view so the
/// view keeps its own look while the menu is the system's — see `ContactProfileView.muteTile`.
struct NativeMenuButton: UIViewRepresentable {
    let menu: UIMenu

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.backgroundColor = .clear
        button.showsMenuAsPrimaryAction = true
        button.menu = menu
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        // Rebuilt on every state change so Unmute appears the moment something is muted.
        button.menu = menu
    }
}
