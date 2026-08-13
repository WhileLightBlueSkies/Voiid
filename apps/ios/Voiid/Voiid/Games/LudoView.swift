//
//  LudoView.swift
//  Voiid
//
//  The Ludo match screen (docs/games/future/LUDO.md §6.3, §7, §8.2).
//
//  A dumb view over GamesEngine, like every renderer here. It never decides what is legal — the
//  server sends `legal` and this highlights exactly that set. Re-deriving legality would put a
//  second copy of the block and exact-entry rules on the phone, and §4.2 is explicit that one
//  function answers "what can this player do" for validation, auto-move, timeout and the bot.
//
//  Mirrors Android `LudoScreen.kt`.
//

import SwiftUI

struct LudoView: View {
    let matchId: String
    var onClose: (() -> Void)?
    var onRematch: ((String) -> Void)?

    @StateObject private var engine = GamesEngine.shared
    @EnvironmentObject var session: AppSession

    private var me: String? { TokenStore.shared.userId }

    /// The die face being shown while it tumbles. Local: the real face is in the frame, and this
    /// only decides what is drawn during the 700 ms roll (§9).
    @State private var tumbling = false
    @State private var tumbleFace = 1

    var body: some View {
        VStack(spacing: VoiidSpacing.sm) {
            if let s = engine.ludo {
                opponentStrips(s)
                LudoBoardView(
                    state: s,
                    mySeat: mySeat,
                    legal: isMyMove(s) ? s.legal : [],
                    onTapToken: { engine.moveLudo(token: $0) })
                    .padding(.horizontal, VoiidSpacing.sm)
                status(s)
                if s.finished {
                    RematchBar(
                        matchId: matchId,
                        onRematch: { newId in engine.leave(); onRematch?(newId) },
                        onExit: { engine.leave(); onClose?() })
                } else {
                    dieButton(s)
                }
            } else if let err = engine.joinError {
                Text(err)
                    .font(VoiidFont.rounded(15, .regular))
                    .foregroundStyle(VoiidColor.error)
                    .padding(.top, VoiidSpacing.xl)
            } else {
                ProgressView().padding(.top, VoiidSpacing.xl)
                Text("Setting up the board…")
                    .font(VoiidFont.rounded(14, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("Ludo")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { engine.leave(); onClose?() } label: {
                    Image(systemName: "chevron.left").foregroundStyle(VoiidColor.textPrimary)
                }
                .accessibilityLabel("Back")
            }
        }
        .task { await engine.open(matchId: matchId) }
        .onAppear {
            session.hideTabBar = true
            GameAudio.shared.preload(for: "ludo")
        }
        .onDisappear {
            session.hideTabBar = false
            engine.leave()
            GameAudio.shared.release(for: "ludo")
        }
        // The die settling and the move landing are two separate beats, driven by two separate
        // fields, because they are two separate events — collapsing them would read as one.
        .onChange(of: engine.ludo?.die) { _, face in
            guard face != nil else { return }
            LudoSound.dieSettled()
        }
        .onChange(of: engine.ludo?.lastMove?.to) { _, _ in
            guard let s = engine.ludo, let move = s.lastMove else { return }
            LudoSound.moved(move, mySeat: mySeat)
        }
        .onChange(of: engine.ludo?.finished) { _, finished in
            guard finished == true else { return }
            LudoSound.matchEnded(engine.ludo, me: me)
        }
    }

    // MARK: - Seats

    private var mySeat: Int? {
        guard let me, let players = engine.ludo?.players else { return nil }
        return players.firstIndex(of: me)
    }

    private func isMyTurn(_ s: LudoState) -> Bool {
        !s.finished && s.turnUserId == me
    }

    private func isMyMove(_ s: LudoState) -> Bool {
        isMyTurn(s) && s.phase == "awaitingMove"
    }

    // MARK: - Strips

    /// THE ACTIVE PLAYER'S STRIP IS THE PRIMARY TURN INDICATOR, not the board (§6.3).
    ///
    /// With four players a subtle board highlight is not enough: whose turn it is has to be
    /// readable at a glance, because in a 4-player game you are mostly waiting.
    @ViewBuilder
    private func opponentStrips(_ s: LudoState) -> some View {
        HStack(spacing: VoiidSpacing.sm) {
            ForEach(Array(s.players.enumerated()), id: \.offset) { seat, uid in
                let active = !s.finished && seat == s.turn
                let home = s.tokens.indices.contains(seat)
                    ? s.tokens[seat].filter { $0 == Ludo.home }.count : 0
                VStack(spacing: 2) {
                    HStack(spacing: 3) {
                        Image(systemName: Ludo.seatMarkers[seat % Ludo.maxSeats])
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Ludo.seatColors[seat % Ludo.maxSeats])
                        Text(uid == me ? "You" : UserDirectory.shared.displayName(uid, fallback: "Player"))
                            .font(VoiidFont.rounded(11, active ? .semibold : .regular))
                            .lineLimit(1)
                            .foregroundStyle(active ? VoiidColor.textPrimary : VoiidColor.textSecondary)
                    }
                    // Tokens home, for every player — one of the six things §8.2 requires be
                    // visible without a tap.
                    Text("\(home)/\(s.tokensPerPlayer)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(VoiidColor.textSecondary.opacity(0.8))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(active ? Ludo.seatColors[seat % Ludo.maxSeats].opacity(0.18)
                                     : Color.clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(active ? Ludo.seatColors[seat % Ludo.maxSeats] : Color.clear,
                                lineWidth: 1.5))
                .animation(.easeInOut(duration: 0.28), value: active)
            }
        }
        .padding(.top, VoiidSpacing.xs)
    }

    // MARK: - Status and die

    @ViewBuilder
    private func status(_ s: LudoState) -> some View {
        let text: String = {
            if s.finished {
                guard let winner = s.winnerUserId else { return "Match abandoned" }
                return winner == me ? "You win"
                    : "\(UserDirectory.shared.displayName(winner, fallback: "They")) wins"
            }
            if isMyTurn(s) {
                return s.phase == "awaitingMove" ? "Pick a token" : "Your turn — roll"
            }
            let who = s.players.indices.contains(s.turn)
                ? UserDirectory.shared.displayName(s.players[s.turn], fallback: "They") : "They"
            return "\(who)'s turn"
        }()

        VStack(spacing: 2) {
            Text(text)
                .font(VoiidFont.rounded(15, .semibold))
                .foregroundStyle(s.finished ? VoiidColor.primary : VoiidColor.textSecondary)
                .accessibilityAddTraits(.updatesFrequently)

            // WHAT JUST HAPPENED, called out by name (§8.2 item 6). In a 4-player game you are
            // mostly watching, and a capture that is not narrated is a token that vanished.
            if let move = s.lastMove, let captured = move.captured, captured.count == 2 {
                let victim = captured[0]
                let byMe = move.seat == mySeat
                let onMe = victim == mySeat
                Text(onMe ? "Your token was sent home"
                          : byMe ? "You sent a token home"
                                 : "\(Ludo.seatNames[victim % Ludo.maxSeats]) was sent home")
                    .font(VoiidFont.rounded(11, .medium))
                    .foregroundStyle(onMe ? VoiidColor.error : VoiidColor.textSecondary)
            }

            // A VISIBLE COUNTDOWN FROM 15 SECONDS, not from 45 — a 45-second countdown is
            // pressure applied to nothing (§13.2).
            if !s.finished, isMyTurn(s), let at = s.deadlineAt {
                let remaining = at / 1000 - Date().timeIntervalSince1970
                if remaining > 0 && remaining < 15 {
                    Text("\(Int(remaining))s")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(VoiidColor.error)
                }
            }
        }
    }

    /// The die is the primary target: bottom-centre, large, reachable by either thumb (§7.2).
    @ViewBuilder
    private func dieButton(_ s: LudoState) -> some View {
        let canRoll = isMyTurn(s) && s.phase == "awaitingRoll"
        VStack(spacing: VoiidSpacing.xs) {
            Button {
                guard canRoll else { return }
                engine.rollLudo()
                LudoSound.dieRolled()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(canRoll ? VoiidColor.primary.opacity(0.16) : VoiidColor.surfaceCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(canRoll ? VoiidColor.primary
                                               : VoiidColor.textSecondary.opacity(0.25),
                                        lineWidth: 1.5))
                    LudoDiePips(face: s.die ?? tumbleFace)
                        .padding(12)
                        .foregroundStyle(canRoll || s.die != nil
                                         ? VoiidColor.textPrimary : VoiidColor.textSecondary)
                }
                .frame(width: 64, height: 64)
                .scaleEffect(s.die != nil ? 1.0 : (canRoll ? 1.0 : 0.94))
            }
            .disabled(!canRoll)
            .accessibilityLabel(s.die.map { "Die showing \($0)" } ?? "Roll the die")

            // The three-sixes rule is invisible unless it is shown, and a player who does not
            // know it exists reads the forfeit as a bug (§13.7's reasoning applied to §2.3).
            if s.sixStreak > 0 && !s.finished {
                Text(s.sixStreak >= 2 ? "Two sixes — a third loses the turn" : "Six — roll again")
                    .font(VoiidFont.rounded(10, .medium))
                    .foregroundStyle(VoiidColor.textSecondary)
            }
        }
        .padding(.bottom, VoiidSpacing.sm)
    }
}

