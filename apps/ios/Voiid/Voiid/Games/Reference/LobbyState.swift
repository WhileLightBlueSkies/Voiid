//
//  LobbyState.swift
//  Voiid
//
//  The party lobby's screen state — a LIVE ADAPTER over the real backend, in the shape the
//  ported reference screens already read.
//
//  ── WHAT CHANGED, AND WHY THIS FILE EXISTS AGAIN ────────────────────────────────
//  `LobbyState` was DELETED once, deliberately, and the note at the bottom of
//  ReferenceGamesModels.swift recorded why: the reference lobby wanted ready-states, a join
//  code, a chat and a host badge, and Voiid's only lobby was an invite that waits for
//  acceptance. Binding the reference screen to `game_matches.player_ids` would have shipped
//  ready checkmarks nothing set, a chat that sent nowhere and a code that joined nothing.
//
//  THAT REASONING IS NOT WRONG — IT IS SUPERSEDED. `database/migrations/052_game_lobbies.sql`
//  and the lobby block in `backend/api/src/routes/games.ts` now provide exactly the three
//  things whose absence was the argument: `game_lobby_members.state` is a real ready-state a
//  real route toggles, `game_lobbies.join_code` is a real code `POST /games/lobbies/join`
//  resolves, and `game_lobby_messages` is a real chat with a real send route and a live WS
//  event. So the screens are wired to those.
//
//  ── THE LAYOUT IS FROZEN; THIS FILE ABSORBS THE DIFFERENCE ──────────────────────
//  GameLobbyScreen and MatchStartingScreen are a signed-off, byte-for-byte port and are
//  restored VERBATIM — no control was removed, no spacing moved. That means every property
//  those screens read must exist here with the same name and the same type, including the ones
//  no server column can fill. Keeping the adapter's surface identical is what let the layout
//  stay untouched, exactly as `MapStore` did for the Friends Map.
//
//  ── WHICH PROPERTIES ARE REAL, AND WHICH ARE LOCAL-ONLY ─────────────────────────
//  Marked at every site below, and summarised here because it is the single most important
//  fact about this file:
//
//  BACKED BY A COLUMN — changes persist and reach every other member:
//    * `members`   ← game_lobby_members (state, mic_on, seat, joined order)
//    * `messages`  ← game_lobby_messages
//    * `teamCode`  ← game_lobbies.join_code
//    * `isPublic`  ← game_lobbies.is_public   (see the setter's note on write-back)
//    * `fillEmpty` ← game_lobbies.fill_empty  (same)
//    * `format`    ← game_lobbies.format
//    * `maxPlayers`← games.max_players
//
//  LOCAL-ONLY — the control renders and responds, but the value NEVER leaves this device and
//  no other member sees it. Each is a view-local preference, not a lobby fact:
//    * `voiceChat` — there is NO voice transport. See its note; this is the important one.
//    * `difficulty`, `crossplay` — no column, no route, no concept server-side.
//    * `mode` — party size is `games.max_players`, not a host-chosen preset.
//
//  A local-only control is not a control that does nothing silently: each carries a comment
//  saying what it is and, critically, what it must never be presented as.
//

import Foundation
import SwiftUI

// MARK: - Member

/// How a member reads in the roster. `invited` is retained from the reference for the pending
/// section, which nothing populates today — see `LobbyState.pending`.
enum PartyStatus: Equatable {
    case host
    case ready
    case waiting
    case invited

    var label: String {
        switch self {
        case .host:    return "Host"
        case .ready:   return "Ready"
        case .waiting: return "Waiting"
        case .invited: return "Invited"
        }
    }
}

/// One person in the party, built from a `GameLobbyAPI.Member` row.
struct PartyMember: Identifiable, Equatable {
    let id: String
    let name: String
    let status: PartyStatus
    /// STORED INTENT, NOT LIVE AUDIO — and the glyph the reference draws for it must never be
    /// read as "this person can be heard".
    ///
    /// `game_lobby_members.mic_on` is a real, persisted column: it survives a reconnect and it
    /// is broadcast to the other members, so the flag genuinely is shared state. What does NOT
    /// exist is anything behind it — Voiid has no lobby audio room, no SFU and no signalling
    /// for one. The column records that a member MEANS to talk when a transport ships. Until
    /// then the glyph is a statement of intent by that person, nothing more.
    let micOn: Bool
    let isYou: Bool
}

/// One lobby chat line.
///
/// SERVER-READABLE, unlike every message surface in this app. The migration header carries the
/// full argument: a lobby is ephemeral, dies with the match, and its members may have arrived
/// by join code holding no ratchet session with anyone. Nothing here applies to the message
/// pipe, which is unchanged and remains E2EE.
struct LobbyMessage: Identifiable, Equatable {
    let id: String
    let sender: String
    let text: String
}

// MARK: - Mode

/// The reference's party-size preset, kept so the header's `\(mode.partySize)v\(mode.partySize)
/// \(mode.rawValue)` line renders exactly as designed.
///
/// LOCAL-ONLY, AND DERIVED — never sent anywhere. Voiid has no notion of a host-chosen party
/// size: the seat count is `games.max_players` off the catalog row, which the server enforces
/// at join and again at start. So rather than offering a preset that could contradict the
/// catalog, this is COMPUTED FROM the catalog (see `LobbyState.mode`) — the label is always the
/// real seat count, and there is no way for the two to disagree.
enum GameMode: String, CaseIterable, Equatable {
    case solo  = "Solo"
    case duo   = "Duo"
    case squad = "Squad"

    /// Players per side, as the header renders it.
    var partySize: Int {
        switch self {
        case .solo:  return 1
        case .duo:   return 2
        case .squad: return 4
        }
    }

    /// The nearest preset for a real seat cap. Anything above four reads as a squad — the
    /// vocabulary simply runs out, and that is better than inventing a fourth name.
    static func forSeats(_ seats: Int) -> GameMode {
        switch seats {
        case ..<2: return .solo
        case 2:    return .duo
        default:   return .squad
        }
    }
}

// MARK: - Load state

/// The screen's four honest conditions. Distinct cases rather than a pair of booleans, so
/// "loaded but empty" can never be rendered as "still loading" — the bug that shape invites.
enum LobbyPhase: Equatable {
    case loading
    case ready
    /// The host has not opened a party lobby on this match. NOT an error: it is the signal to
    /// use the ordinary `GameLobbyView` invite-and-wait screen instead.
    case noLobby
    case failed(String)
}

// MARK: - The state

/// Live lobby state for one match.
///
/// `@Observable` to match how the ported screens read it (`@Bindable var lobby = lobby`).
@Observable
@MainActor
final class LobbyState {

    // MARK: Identity

    /// The catalog row this party is assembling around. Held so the header can name the game
    /// without a second lookup.
    let game: Game
    let matchId: String

    // MARK: Backed by columns

    private(set) var phase: LobbyPhase = .loading
    private(set) var members: [PartyMember] = []
    private(set) var messages: [LobbyMessage] = []

    /// `game_lobbies.join_code`. Empty only before the lobby loads.
    private(set) var teamCode: String = ""

    /// `game_lobbies.format` — the host's free-text option line ("3 overs"). Empty when the
    /// game has no such setting; no format string is invented to fill it.
    private(set) var format: String = ""

    /// `games.max_players` off the catalog row, echoed by the server. The real seat cap.
    private(set) var maxPlayers: Int = 0

    /// Whether the viewer may start the match. The SERVER decides this; this is its answer.
    private(set) var isHost: Bool = false

    /// Non-nil once the host has started — the screen's cue to hand off to the game renderer.
    private(set) var startedAt: Int64?

    /// True when the host left and the party was ended under the viewer.
    private(set) var wasCancelled = false

    /// Set when a mutation fails, so a failed toggle can say so rather than appearing to work.
    private(set) var actionError: String?

    /// `game_lobbies.is_public`. READ FROM the lobby row and rendered by the reference's Room
    /// menu, which is left in place and still switches this value.
    ///
    /// THE WRITE IS LOCAL. `POST /games/matches/:id/lobby` sets visibility when the lobby is
    /// OPENED, and there is deliberately no route to change it afterwards — so flipping the
    /// menu updates what this device shows and does not reach the server. The menu was kept
    /// (the layout is frozen) rather than being made to look disabled, and this comment is the
    /// record that a flip does not currently revoke anyone's access. If a PATCH route lands,
    /// this setter is the one place to wire it.
    var isPublic: Bool = false

    /// `game_lobbies.fill_empty`. Same shape as `isPublic`: read from the row, toggled locally
    /// by the reference's toggle card, and NOT written back — the host chooses it at open time.
    /// The server reads the stored column when it decides whether to waive the seat count at
    /// start, so a local flip does not change what start does.
    var fillEmpty: Bool = false

    // MARK: Local-only — rendered, never transmitted

    /// ── THERE IS NO VOICE TRANSPORT BEHIND THIS. ────────────────────────────────────
    /// The reference's "Voice Chat" toggle card is kept exactly as designed, and this backs it
    /// so the layout is unchanged. But Voiid has NO lobby audio: no room, no SFU, no signalling,
    /// nothing. Flipping it changes a boolean on this device and moves no audio, opens no
    /// stream, and tells no other member anything.
    ///
    /// It must NEVER be presented as live audio — no "connected" state, no speaking indicator,
    /// no participant volume. The one persisted neighbour of this idea is per-member `mic_on`
    /// (see `PartyMember.micOn`), which is stored intent and equally not a transport.
    ///
    /// Kept rather than deleted because the layout is signed off and frozen; recorded here in
    /// full because a toggle whose emptiness is undocumented is a toggle the next reader ships
    /// a feature on top of.
    var voiceChat: Bool = false

    /// LOCAL-ONLY. No column, no route, no server concept of a lobby-wide difficulty. (Ludo has
    /// per-BOT difficulties inside its roster, which is a different thing entirely and belongs
    /// to the Ludo setup flow.) Kept so any reference control bound to it renders; the value
    /// never leaves this device and no other member sees it.
    var difficulty: String = "Normal"

    /// LOCAL-ONLY. Voiid is iOS and Android against one backend with one match table — there is
    /// no platform segregation to opt out of, so this can only ever be decorative. Kept for the
    /// frozen layout; never transmitted, and it gates nothing.
    var crossplay: Bool = true

    // MARK: Reference vocabulary the screens read

    /// The header's party-size line. DERIVED from the catalog's seat cap rather than chosen, so
    /// it cannot contradict the number the server enforces. See `GameMode`.
    var mode: GameMode { GameMode.forSeats(maxPlayers) }

    /// PENDING INVITES — always empty, so the section renders only if it ever has a source.
    ///
    /// The reference showed people invited but not present. `game_lobby_members` holds exactly
    /// who IS present, and `game_matches.player_ids` is a seat list that says nothing about
    /// whether someone was invited to a PARTY as opposed to seated in a match. No column
    /// distinguishes "invited to this lobby and has not arrived" from "seated in this match",
    /// so the list cannot be built without inventing it. The screen's
    /// `if !lobby.pending.isEmpty` gate therefore hides the section — the layout is untouched
    /// and lights up unchanged the day such a column lands.
    private(set) var pending: [PartyMember] = []

    /// Cancel a pending invite. A NO-OP while `pending` is always empty — the row it would act
    /// on cannot be rendered. Kept so the reference's cancel button compiles and stays on
    /// screen; wire it the same day `pending` gets a source.
    func cancelInvite(_ id: String) {
        pending.removeAll { $0.id == id }
    }

    /// "3/4" — present members over the catalog's seat cap. Both halves are real numbers.
    var partyText: String {
        maxPlayers > 0 ? "\(members.count)/\(maxPlayers)" : "\(members.count)"
    }

    /// The Start button's gate, mirroring the server's rule rather than approximating it: every
    /// PRESENT member must be ready. `fill_empty` waives the seat COUNT server-side, never the
    /// ready check, so it is deliberately not consulted here.
    ///
    /// An empty roster is NOT ready. `allSatisfy` on an empty array is vacuously true, which
    /// would light the Start button on a lobby that failed to load.
    var everyoneReady: Bool {
        !members.isEmpty && members.allSatisfy { $0.status == .ready || $0.status == .host }
    }

    /// The viewer's own ready state.
    var youAreReady: Bool {
        members.first { $0.isYou }?.status != .waiting
    }

    /// THE COUNTDOWN LENGTH THE REFERENCE TICKS.
    ///
    /// MatchStartingScreen counts down from this to a start moment the reference's server
    /// scheduled. Voiid schedules nothing: `POST /lobby/start` flips the match to active
    /// immediately and the games service broadcasts the opening board, so the screen is already
    /// past the moment it would be counting toward. The screen and its timer are frozen and
    /// unchanged; this value is what it counts from, and the real handoff happens on
    /// `startedAt` arriving over the socket regardless of where the clock is.
    var countdown: Int = 8

    // MARK: Plumbing

    private let api = GameLobbyAPI()
    private var observer: NSObjectProtocol?
    /// Whose row is "(You)". Read once — it cannot change while a lobby is on screen.
    private let me: String? = TokenStore.shared.userId
    private var hostId: String = ""

    init(game: Game, matchId: String) {
        self.game = game
        self.matchId = matchId
    }

    /// Unsubscribe when the screen goes away. `stop()` is called from the views' `onDisappear`;
    /// this is the belt-and-braces path for a state object dropped without one.
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    // MARK: Loading

    /// Fetch the lobby and subscribe to its live channel.
    ///
    /// A 404 is `noLobby`, NOT `failed`: it means the host never opened a party lobby, which is
    /// the ordinary case for a direct invite and the caller's cue to show `GameLobbyView`
    /// instead. Conflating the two would put an error banner on a perfectly healthy flow.
    func load() async {
        phase = .loading
        do {
            let snapshot = try await api.lobby(matchId: matchId)
            apply(snapshot)
            phase = .ready
            subscribe()
        } catch let APIError.http(status, _, _) where status == 404 {
            phase = .noLobby
        } catch let APIError.http(status, _, _) where status == 403 {
            phase = .failed("You're not in this lobby.")
        } catch {
            phase = .failed("Couldn't load the lobby.")
        }
    }

    /// Open a lobby as host, then hold it. Idempotent server-side, so a re-entered screen
    /// re-attaches to the existing lobby and its existing code rather than minting a second.
    func openAsHost(isPublic: Bool, format: String?, fillEmpty: Bool) async {
        phase = .loading
        do {
            let snapshot = try await api.open(
                matchId: matchId, isPublic: isPublic, format: format, fillEmpty: fillEmpty)
            apply(snapshot)
            phase = .ready
            subscribe()
        } catch {
            phase = .failed("Couldn't open the lobby.")
        }
    }

    // MARK: Mutations — every one is confirmed by a WS frame

    /// Toggle the viewer's own ready state. The server broadcasts the new roster to everyone
    /// including this device, so the local list is NOT optimistically rewritten here: one
    /// source of truth for who is ready, and it is the server's.
    func setReady(_ ready: Bool) async {
        actionError = nil
        do { _ = try await api.setReady(matchId: matchId, ready: ready) }
        catch { actionError = "Couldn't update your status." }
    }

    /// Flip the viewer's mic INTENT. Persisted and broadcast — and it moves no audio, because
    /// there is no transport. See `PartyMember.micOn` and `voiceChat`.
    func setMic(_ on: Bool) async {
        actionError = nil
        // Ready state is preserved rather than assumed: the route takes both in one row, and
        // sending a guess for `ready` would let a mic tap silently un-ready someone.
        do { _ = try await api.setReady(matchId: matchId, ready: youAreReady, micOn: on) }
        catch { actionError = "Couldn't update your mic." }
    }

    /// Send a chat line.
    ///
    /// SYNCHRONOUS, because the reference's send button and its three quick-reaction buttons
    /// call it directly from a non-async label closure and that layout is frozen. The work is
    /// handed to a Task; the sent line arrives back over the lobby's WS channel like everyone
    /// else's, so nothing is appended locally (that would double it).
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty and whitespace-only drafts are dropped here rather than 400'd by the server —
        // the quick-reaction buttons make an accidental empty send easy.
        guard !trimmed.isEmpty else { return }
        actionError = nil
        let body = String(trimmed.prefix(500))
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.api.send(matchId: self.matchId, body: body) }
            catch { self.actionError = "Message not sent." }
        }
    }

    /// Leave the party. Returns true when the whole lobby was cancelled because the viewer was
    /// the HOST — the route cancels rather than transferring, and the caller must dismiss.
    @discardableResult
    func leave() async -> Bool {
        do {
            let res = try await api.leave(matchId: matchId)
            if res.cancelled { wasCancelled = true }
            return res.cancelled
        } catch {
            actionError = "Couldn't leave the lobby."
            return false
        }
    }

    /// Host only. The server re-checks host, readiness and the seat cap — this is a request,
    /// not a decision. Returns true when the match is live.
    @discardableResult
    func start() async -> Bool {
        actionError = nil
        do {
            let res = try await api.start(matchId: matchId)
            startedAt = res.started_at ?? Int64(Date().timeIntervalSince1970 * 1000)
            return true
        } catch let APIError.http(_, message, _) {
            // The server's reason is shown as-is where it has one ("not everyone is ready"),
            // because it knows something this screen does not — it saw the roster at the
            // instant of the tap.
            actionError = message.isEmpty ? "Couldn't start the match." : message
            return false
        } catch {
            actionError = "Couldn't start the match."
            return false
        }
    }

    // MARK: Live updates

    /// Subscribe to `game_lobby_update` / `game_lobby_message` for THIS match.
    ///
    /// The WS client relays these frames whole and unparsed (see WebSocketClient) exactly as it
    /// does `game_state`; this is the only place that decodes them, so the roster has one
    /// decoder rather than two that can disagree.
    private func subscribe() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .voiidGameLobbyEvent, object: nil, queue: .main
        ) { [weak self] note in
            // Frames for OTHER matches share this channel — every lobby a user is in publishes
            // to the same per-user channel — so the match id is filtered before anything else.
            guard let mid = note.userInfo?["match_id"] as? String,
                  let frame = note.userInfo?["frame"] as? [String: Any] else { return }
            let kind = (note.userInfo?["type"] as? String) ?? ""
            MainActor.assumeIsolated {
                guard let self, mid == self.matchId else { return }
                self.handle(kind: kind, frame: frame)
            }
        }
    }

    private func handle(kind: String, frame: [String: Any]) {
        switch kind {
        case "game_lobby_update":
            // A cancelled lobby arrives with an empty roster and is the one frame that ends the
            // screen. Checked BEFORE the roster is applied, so the screen never flashes an
            // empty party on its way out.
            if (frame["reason"] as? String) == "cancelled" {
                wasCancelled = true
                return
            }
            // Re-decoded through the SAME typed models the REST call uses, by round-tripping
            // the frame's JSON. Hand-reading the dictionary here would be a second parser for a
            // payload that already has one — precisely how two code paths end up disagreeing
            // about whether someone is ready.
            guard let data = try? JSONSerialization.data(withJSONObject: frame),
                  let decoded = try? JSONDecoder().decode(LobbyFrame.self, from: data)
            else { return }
            if let lobby = decoded.lobby { applyLobby(lobby) }
            applyMembers(decoded.members)
            // A frame is authoritative even if the screen was mid-load: it carries the full
            // roster, which is exactly what `loading` was waiting for.
            if phase == .loading { phase = .ready }

        case "game_lobby_message":
            guard let data = try? JSONSerialization.data(withJSONObject: frame),
                  let decoded = try? JSONDecoder().decode(MessageFrame.self, from: data),
                  let message = decoded.message else { return }
            // De-duplicated by id: the sender's own device receives its message back over this
            // channel too, and a reconnect can replay one.
            guard !messages.contains(where: { $0.id == message.id }) else { return }
            messages.append(LobbyMessage(
                id: message.id,
                sender: senderName(userId: message.user_id, name: message.name),
                text: message.body))

        default:
            break
        }
    }

    /// The WS frame's decodable shell. Separate from `LobbySnapshot` because the frame nests
    /// the same two objects alongside routing fields the REST body does not carry.
    private struct LobbyFrame: Decodable {
        var lobby: GameLobbyAPI.Lobby?
        var members: [GameLobbyAPI.Member] = []
        private enum CodingKeys: String, CodingKey { case lobby, members }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lobby   = try c.decodeIfPresent(GameLobbyAPI.Lobby.self, forKey: .lobby)
            members = try c.decodeIfPresent([GameLobbyAPI.Member].self, forKey: .members) ?? []
        }
    }

    private struct MessageFrame: Decodable {
        var message: GameLobbyAPI.Message?
        private enum CodingKeys: String, CodingKey { case message }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            message = try c.decodeIfPresent(GameLobbyAPI.Message.self, forKey: .message)
        }
    }

    // MARK: Mapping

    private func apply(_ snapshot: GameLobbyAPI.LobbySnapshot) {
        applyLobby(snapshot.lobby)
        isHost = snapshot.is_host || snapshot.lobby.host_user_id == me
        applyMembers(snapshot.members)
        messages = snapshot.messages.map {
            LobbyMessage(id: $0.id,
                         sender: senderName(userId: $0.user_id, name: $0.name),
                         text: $0.body)
        }
    }

    private func applyLobby(_ lobby: GameLobbyAPI.Lobby) {
        teamCode   = lobby.join_code ?? ""
        isPublic   = lobby.is_public
        format     = lobby.format ?? ""
        fillEmpty  = lobby.fill_empty
        maxPlayers = lobby.max_players
        startedAt  = lobby.started_at
        if !lobby.host_user_id.isEmpty {
            hostId = lobby.host_user_id
            isHost = lobby.host_user_id == me
        }
    }

    private func applyMembers(_ rows: [GameLobbyAPI.Member]) {
        members = rows.map { row in
            PartyMember(
                id: row.user_id,
                name: displayName(row),
                status: status(for: row),
                micOn: row.mic_on,
                isYou: row.user_id == me)
        }
    }

    /// The SERVER names members, because a join-code member is someone this device may never
    /// have messaged — the local contact directory cannot name them, and an unnamed row would
    /// render a raw uuid. "Player" is the last resort for a deleted account, never a uuid.
    private func displayName(_ row: GameLobbyAPI.Member) -> String {
        if row.user_id == me { return "You" }
        if let name = row.name, !name.isEmpty { return name }
        if let username = row.username, !username.isEmpty { return "@\(username)" }
        return "Player"
    }

    /// Host outranks ready in the chip, because "Host" is an identity and "Ready" is a state —
    /// the reference's MemberRow makes the same distinction visually.
    private func status(for row: GameLobbyAPI.Member) -> PartyStatus {
        if !hostId.isEmpty && row.user_id == hostId { return .host }
        return row.isReady ? .ready : .waiting
    }

    private func senderName(userId: String?, name: String?) -> String {
        if let userId, userId == me { return "You" }
        if let name, !name.isEmpty { return name }
        // The migration's ON DELETE SET NULL: the author's account is gone, and the line reads
        // as "Left" rather than being hidden — other people were part of that exchange.
        return userId == nil ? "Left" : "Player"
    }
}
