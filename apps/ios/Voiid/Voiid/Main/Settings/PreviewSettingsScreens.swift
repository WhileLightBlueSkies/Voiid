//
//  PreviewSettingsScreens.swift
//  Voiid
//
//  The settings destinations that exist as a DESIGN and not yet as a feature.
//
//  ── WHY THEY EXIST AT ALL ───────────────────────────────────────────────────────
//  These nine rows are in the reference's profile sheet and have no backend in Voiid. Two
//  options were available: leave the rows out until the backend lands, or ship the rows with
//  screens that say what they are. The rows are in, because the sheet's shape is part of what
//  is being reviewed — a settings screen missing a third of its rows cannot be judged.
//
//  ── EVERY ONE OF THEM ADMITS IT, ON SCREEN ──────────────────────────────────────
//  Each screen opens with an `UnwiredNotice` naming exactly what is missing. The row that
//  leads here carries an amber dot, so the state is legible BEFORE the tap. Controls below the
//  notice are rendered but inert: they show the intended shape without pretending to work.
//
//  ── WIRING ONE UP ───────────────────────────────────────────────────────────────
//  Delete its `UnwiredNotice`, flip the case in `SettingsRoute.isWired`, and replace the inert
//  controls. Nothing else in the sheet changes.
//

import SwiftUI

// MARK: - Shared scaffold

/// The frame every preview screen shares: the notice first, then the intended content.
private struct PreviewScaffold<Content: View>: View {
    let title: String
    let missing: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                UnwiredNotice(missing)
                content
            }
            .padding(VoiidSpacing.md)
        }
        .softTopEdgeEffect()
        .scrollIndicators(.hidden)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A card of inert rows, drawn so the screen has its intended shape.
private struct PreviewCard: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: VoiidSpacing.md) {
                    Circle()
                        .stroke(VoiidColor.accent.opacity(0.5), lineWidth: 1)
                        .frame(width: 34, height: 34)
                        .overlay {
                            Image(systemName: row.1)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(VoiidColor.accentInk)
                        }

                    Text(row.0)
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(VoiidColor.textSecondary.opacity(0.7))
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, 13)

                if index < rows.count - 1 {
                    Rectangle().fill(VoiidColor.divider)
                        .frame(height: 1).padding(.leading, 60)
                }
            }
        }
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
        // Inert, and said so to VoiceOver rather than only in colour.
        .allowsHitTesting(false)
        .opacity(0.55)
        .accessibilityHint("Preview only, not yet interactive")
    }
}

// MARK: - My QR code

/// The one screen here that could be built today — `session.profile.username` is enough to
/// encode. It is left as a preview because a QR code that scans to a link nothing handles is
/// worse than one that admits it is coming.
// MARK: - Account center

/// Social profile actions, shared by Account and Account Center in Settings.
struct AccountCenterScreen: View {
    var includesChatProfile = true
    @EnvironmentObject private var creators: SocialEngine
    @State private var showSetup = false
    @State private var showEdit = false
    @State private var loadingProfile = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VoiidSettingsHeader(includesChatProfile ? "Account Center" : "Account",
                                    subtitle: includesChatProfile ? "Manage your chat and social profiles." : "Manage your social profile.")

                if includesChatProfile {
                    VoiidCardSection("Chat profile") {
                        NavigationLink {
                            EditProfileView()
                        } label: {
                            VoiidSettingsRow(icon: "person.crop.circle", title: "Chat profile",
                                             detail: "Your name, photo and chat username") {
                                VoiidChevron()
                            }
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }

                VoiidCardSection("Social profile",
                                 footer: "Your social identity and privacy are separate from your chats.") {
                    if let profile = creators.me {
                        NavigationLink {
                            SocialProfileView(handle: profile.handle)
                        } label: {
                            VoiidSettingsRow(icon: "person.crop.square", title: "View profile",
                                             detail: "@\(profile.handle)") {
                                VoiidChevron()
                            }
                        }
                        .buttonStyle(RowButtonStyle())

                        VoiidRowDivider()

                        VoiidSettingsRow(icon: "pencil", title: "Edit profile",
                                         detail: "Photo, username, bio and link", action: {
                            showEdit = true
                        }) {
                            VoiidChevron()
                        }

                        VoiidRowDivider()

                        NavigationLink {
                            SocialPrivacyView()
                        } label: {
                            VoiidSettingsRow(icon: "slider.horizontal.3", title: "Profile settings",
                                             detail: "Visibility, followers and comments") {
                                VoiidChevron()
                            }
                        }
                        .buttonStyle(RowButtonStyle())
                    } else if loadingProfile || creators.meLoading {
                        VoiidSettingsRow(icon: "person.crop.square", title: "Social profile",
                                         detail: "Loading your profile…") {
                            ProgressView().controlSize(.small)
                        }
                    } else if creators.hasLoadedMe {
                        VoiidSettingsRow(icon: "person.crop.square", title: "Social profile",
                                         detail: "Set up your social identity", action: {
                            showSetup = true
                        }) {
                            VoiidChevron()
                        }
                    } else {
                        VoiidSettingsRow(icon: "person.crop.square", title: "Social profile",
                                         detail: "Couldn’t load your profile. Tap to retry.", action: {
                            Task { await loadProfile() }
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(VoiidColor.textSecondary)
                        }
                    }
                }
            }
            .padding(VoiidSpacing.md)
        }
        .fontDesign(.rounded)
        .voiidSettingsPage()
        .task { await loadProfile() }
        .sheet(isPresented: $showEdit) {
            if let profile = creators.me {
                CreatorEditSheet(profile: profile)
            }
        }
        .sheet(isPresented: $showSetup) {
            SocialSetupSheet { profile in
                creators.profileCreated(profile)
            }
        }
    }

    private func loadProfile() async {
        loadingProfile = true
        await creators.ensureMeLoaded()
        loadingProfile = false
    }
}

// MARK: - Encryption status

/// Encryption information and entry points to the app’s real security controls.
struct EncryptionStatusScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VoiidSettingsHeader("End-to-end encryption",
                                    subtitle: "Understand your protection and verify who you’re talking to.")

                VoiidCardSection("Your conversations",
                                 footer: "Safety numbers let you compare device identities with someone you trust. Check each linked device separately.") {
                    NavigationLink {
                        EncryptionChatsScreen()
                    } label: {
                        VoiidSettingsRow(icon: "checkmark.shield", title: "Chat encryption",
                                         detail: "View details and verify safety numbers") {
                            VoiidChevron()
                        }
                    }
                    .buttonStyle(RowButtonStyle())
                }

                VoiidCardSection("Devices & recovery") {
                    NavigationLink {
                        LinkedDevicesView()
                    } label: {
                        VoiidSettingsRow(icon: "laptopcomputer.and.iphone", title: "Linked devices",
                                         detail: "Review and remove device access") { VoiidChevron() }
                    }
                    .buttonStyle(RowButtonStyle())
                    VoiidRowDivider()
                    NavigationLink {
                        BackupRecoveryView()
                    } label: {
                        VoiidSettingsRow(icon: "arrow.clockwise.icloud", title: "Backup & Recovery",
                                         detail: "Manage encrypted backups and recovery") { VoiidChevron() }
                    }
                    .buttonStyle(RowButtonStyle())
                }

                VoiidCardSection("How protection works") {
                    explanation("Messages & media", icon: "bubble.left.and.bubble.right",
                                text: "Direct chats use the Double Ratchet; group chats use MLS. Messages and shared media are encrypted before they leave your device.")
                    VoiidRowDivider()
                    explanation("Calls", icon: "phone",
                                text: "Calls use end-to-end encrypted media. Check the encryption indicator during a call for its current verification state.")
                    VoiidRowDivider()
                    explanation("Backups", icon: "externaldrive.badge.checkmark",
                                text: "Backups are encrypted on your device. Keep your recovery phrase safe so you can restore them on a new phone.")
                }
                Text("Public social profiles and posts aren’t covered by chat encryption. Encryption also doesn’t prevent a recipient from saving or sharing what you send.")
                    .font(.footnote)
                    .foregroundStyle(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .padding(VoiidSpacing.md)
        }
        .fontDesign(.rounded)
        .voiidSettingsPage()
    }

    private func explanation(_ title: String, icon: String, text: String) -> some View {
        VoiidSettingsRow(icon: icon, title: title, detail: text)
    }
}

/// Uses the existing chat store and never infers a verified state from a chat’s existence.
private struct EncryptionChatsScreen: View {
    @EnvironmentObject private var chat: ChatStore
    @State private var search = ""

    private var conversations: [VConversation] {
        (chat.directConversations + chat.groupConversations)
            .filter { $0.type != .self && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        List {
            if let error = chat.loadError {
                SettingsSection {
                    Text(error).font(.subheadline).foregroundStyle(VoiidColor.error)
                    Button("Retry") { Task { await chat.loadConversations() } }
                }
            }
            if !chat.didLoadConversations && chat.loadError == nil && conversations.isEmpty {
                ProgressView("Loading chats…")
            } else if conversations.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No chats yet" : "No matching chats",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text(search.isEmpty
                                        ? "Your conversations will appear here so you can compare safety numbers."
                                        : "Try another name."))
            } else {
                SettingsSection(footer: "Choose a chat to see its encryption details and compare safety numbers.") {
                    ForEach(conversations) { conversation in
                        NavigationLink {
                            ChatEncryptionDetailsScreen(conversation: conversation)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(conversation.title).font(.body)
                                    Text(conversation.type == .group ? "Group chat" : "Direct chat")
                                        .font(.footnote).foregroundStyle(VoiidColor.textSecondary)
                                }
                            } icon: {
                                VoiidRowIcon(systemName: conversation.type == .group ? "person.2" : "person")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .voiidSettingsList()
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("Chat encryption")
        .searchable(text: $search, prompt: "Find a chat")
        .task { if !chat.didLoadConversations { await chat.loadConversations() } }
        .refreshable { await chat.loadConversations() }
        .tint(VoiidColor.primary)
    }
}

private struct ChatEncryptionDetailsScreen: View {
    let conversation: VConversation
    @State private var showVerification = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VoiidSettingsHeader(conversation.title, subtitle: "Encryption details")
                VoiidCardSection("Encryption") {
                    VoiidSettingsRow(icon: "lock.shield", title: conversation.type == .group ? "MLS" : "Double Ratchet",
                                     detail: conversation.type == .group
                                        ? "End-to-end encryption for this group’s messages and media."
                                        : "End-to-end encryption for this direct chat’s messages and media.")
                }
                VoiidCardSection("Verify identities",
                                 footer: "Compare the safety number or scan the other person’s code in person or through a trusted channel. Verification is per device pair, so check other linked devices too.") {
                    VoiidSettingsRow(icon: "qrcode.viewfinder",
                                     title: conversation.type == .group ? "Verify a group member" : "Compare safety numbers",
                                     action: { showVerification = true }) {
                        VoiidChevron()
                    }
                }
            }
            .padding(VoiidSpacing.md)
        }
        .fontDesign(.rounded)
        .voiidSettingsPage()
        .sheet(isPresented: $showVerification) {
            if conversation.type == .direct, let peer = conversation.peerUserId, !peer.isEmpty {
                SafetyNumberView(peerUserId: peer, peerName: conversation.title)
            } else {
                // Fetches real members when a direct chat’s peer has not been resolved yet.
                GroupSecurityVerificationSheet(conversationId: conversation.id)
            }
        }
    }
}

// MARK: - Account

/// The reference's "Phone, email, username" screen. Every one of those fields is already
/// editable in Voiid — on Edit Profile — so this row is a second door to settings that have a
/// home. It stays for layout parity and points at the screen that works.
struct AccountScreen: View {
    var body: some View {
        PreviewScaffold(title: "Account",
                        missing: "Your name, username and photo are edited on Edit Profile, "
                               + "which is wired. Changing your phone number and adding an "
                               + "email have no endpoint yet.") {
            PreviewCard(rows: [
                ("Change phone number", "phone"),
                ("Add email address", "envelope"),
                ("Request account info", "square.and.arrow.down"),
            ])
        }
    }
}

// MARK: - Chats

/// Reference name for chat appearance settings. Voiid's two chat-appearance controls — chat
/// list layout and app theme — are on the settings root under Display, where they are inline
/// and take effect instantly. What is missing is everything else this screen implies.
// MARK: - Voiid One

struct VoiidOneScreen: View {
    var body: some View {
        PreviewScaffold(title: "Voiid One",
                        missing: "Voiid One is not a product yet. Encrypted backup and restore "
                               + "already exist and are wired — see Backup & Recovery on the "
                               + "settings root.") {
            PreviewCard(rows: [
                ("Subscription", "star"),
                ("Extra storage", "externaldrive"),
                ("Priority support", "bolt"),
            ])
        }
    }
}

// MARK: - Payments

struct PaymentsScreen: View {
    var body: some View {
        PreviewScaffold(title: "Payments",
                        missing: "No payment provider is wired up. The events API answers 501 "
                               + "for paid tickets for the same reason — money needs a "
                               + "processor, webhooks, refunds and tax records.") {
            PreviewCard(rows: [
                ("Payment methods", "creditcard"),
                ("Transaction history", "list.bullet.rectangle.portrait"),
                ("UPI", "indianrupeesign.circle"),
            ])
        }
    }
}

