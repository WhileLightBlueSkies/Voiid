//
//  PartyLobbyHost.swift
//  Voiid
//
//  The PARTY lobby, made reachable.
//
//  ── WHAT WAS ACTUALLY BROKEN ────────────────────────────────────────────────────
//  `Games/Reference/GameLobbyScreen.swift` is a fully wired party lobby — real ready-states
//  (`game_lobby_members.state`), a real join code (`game_lobbies.join_code`), real chat
//  (`game_lobby_messages`), all over a live WS channel via `LobbyState`. Every route it needs
//  exists in `GameLobbyAPI`. And NOTHING IN THE APP PRESENTED IT. `GamesScreen` routed every
//  path to `GameLobbyView` — the 1:1 invite-and-wait screen — so a signed-off, backend-complete
//  surface was dead code the moment it landed.
//
//  ── WHY A WRAPPER RATHER THAN WIRING GameLobbyScreen DIRECTLY ───────────────────
//  Two reasons, and the first is the load-bearing one.
//
//  1. GameLobbyScreen NEVER READS `LobbyState.phase`. It is a frozen byte-for-byte port of the
//     design reference, and the reference had no loading state to render — so it draws an empty
//     roster, a blank team code and a disabled Start button while the fetch is in flight, and
//     draws exactly the same thing if the fetch FAILS. That is the "loaded but empty rendered as
//     still loading" bug `LobbyPhase` was written to make impossible, and it can only be fixed
//     outside that file without unfreezing the layout. This wrapper owns the four states and
//     hands the frozen screen over only once there is genuinely a lobby to draw.
//
//  2. A HOST HAS NO LOBBY YET. `LobbyState.load()` GETs the lobby and answers `.noLobby` on a
//     404 — which is precisely what a freshly created match returns, because a party lobby is
//     something a host OPENS (`POST /games/matches/:id/lobby`) rather than something a match is
//     born with. The creator's path is therefore `openAsHost`, not `load`; a member arriving by
//     invite takes `load`. One flag decides which, and it is set by the caller who knows.
//
//  ── PUBLIC OR PRIVATE, AND WHY PUBLIC ───────────────────────────────────────────
//  Opened PUBLIC. A private lobby refuses its own join code server-side, and the join code is
//  the one thing a party lobby offers that the direct-invite path structurally cannot — opening
//  private by default would ship the room with its own reason for existing switched off. The
//  host can flip it in the room bar (that toggle's write-back limitation is documented on
//  `LobbyState.isPublic` and is unchanged here).
//

import SwiftUI

/// Everything the party lobby needs to address itself. Carried rather than re-fetched, exactly
/// as `LobbyArgs` is for the 1:1 path — the creator already knows what they just chose.
struct PartyArgs: Identifiable, Hashable {
    /// The match id the lobby hangs off.
    let id: String
    let gameId: String
    /// True when the viewer created this match and must OPEN the lobby rather than join one.
    var asHost: Bool = true
    /// The host's free-text option line ("3 overs"). Empty when the game has no such setting;
    /// no format string is invented to fill it.
    var format: String = ""

    static func == (a: PartyArgs, b: PartyArgs) -> Bool {
        a.id == b.id && a.gameId == b.gameId && a.asHost == b.asHost && a.format == b.format
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(gameId); hasher.combine(asHost)
    }
}

/// Opens or joins the party lobby for one match, then hands off to the frozen reference screen.
struct PartyLobbyHost: View {
    let game: Game
    let args: PartyArgs
    /// The host started the match — the caller opens the board.
    let onStart: () -> Void
    let onClose: () -> Void

    @EnvironmentObject private var session: AppSession
    @State private var lobby: LobbyState?

    var body: some View {
        ZStack {
            VoiidColor.background.ignoresSafeArea()

            if let lobby {
                // FOUR DISTINCT STATES, none of which the frozen screen can express itself.
                switch lobby.phase {
                case .loading:
                    loading
                case .ready:
                    GameLobbyScreen(lobby: lobby, onStart: onStart)
                        .environmentObject(session)
                        // Materialises rather than cutting in (§12): the roster arrives as a
                        // surface with depth, scaled up from just under full size, so the
                        // transition from spinner to lobby reads as one thing becoming another.
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                case .noLobby:
                    // NOT AN ERROR. It means the host never opened a party lobby on this match,
                    // which is the ordinary case for a direct invite. Conflating it with a
                    // failure would put a red banner on a perfectly healthy flow.
                    message(icon: "person.3.slash",
                            title: "No lobby here",
                            detail: "Nobody opened a party for this match. It's an ordinary invite — check your chat.",
                            retry: nil)
                case .failed(let text):
                    message(icon: "wifi.exclamationmark",
                            title: "Couldn't open the lobby",
                            detail: text,
                            retry: { Task { await begin(lobby) } })
                }
            } else {
                loading
            }

            // The one control that must exist in EVERY state, including the failed one — a
            // screen you cannot leave is the wayfinding failure §16 names outright.
            if lobby?.phase != .ready {
                closeBar.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 1.0), value: lobby?.phase)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear { session.hideTabBar = true }
        .onDisappear {
            session.hideTabBar = false
            lobby?.stop()
        }
        .task {
            // Built here rather than in an initializer: `LobbyState` is @MainActor and holds a
            // live subscription, so it must not be constructed during a view body evaluation
            // that SwiftUI may repeat.
            guard lobby == nil else { return }
            let state = LobbyState(game: game, matchId: args.id)
            lobby = state
            await begin(state)
        }
        // The host left and the party was ended under us — or we were the host and ended it.
        .onChange(of: lobby?.wasCancelled ?? false) { _, cancelled in
            if cancelled { onClose() }
        }
    }

    /// Open as host, or load as a member. `openAsHost` is IDEMPOTENT server-side, so a screen
    /// re-entered after a background re-attaches to the existing lobby and its existing code
    /// rather than minting a second live code.
    private func begin(_ state: LobbyState) async {
        if args.asHost {
            await state.openAsHost(isPublic: true,
                                   format: args.format.isEmpty ? nil : args.format,
                                   fillEmpty: false)
        } else {
            await state.load()
        }
    }

    private var loading: some View {
        VStack(spacing: VoiidSpacing.sm) {
            ProgressView()
                .tint(VoiidColor.accent)
            Text(args.asHost ? "Opening the lobby…" : "Joining the lobby…")
                .font(VoiidFont.rounded(14, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
        }
    }

    private func message(icon: String, title: String, detail: String,
                         retry: (() -> Void)?) -> some View {
        VStack(spacing: VoiidSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(VoiidColor.textSecondary)
            Text(title)
                .font(VoiidFont.rounded(17, .semibold))
                .foregroundStyle(VoiidColor.textPrimary)
            Text(detail)
                .font(VoiidFont.rounded(13, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)

            if let retry {
                Button {
                    Haptics.tap()
                    retry()
                } label: {
                    Text("Try again")
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundStyle(VoiidColor.textOnAccent)
                        .padding(.horizontal, VoiidSpacing.lg)
                        .frame(height: 40)
                        .background(Capsule().fill(VoiidColor.accent))
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.top, VoiidSpacing.xs)
            }
        }
        .padding(VoiidSpacing.lg)
    }

    private var closeBar: some View {
        HStack {
            Button("Close") {
                Haptics.tap()
                onClose()
            }
            .font(VoiidFont.rounded(16, .semibold))
            .foregroundStyle(VoiidColor.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.md)
    }
}
