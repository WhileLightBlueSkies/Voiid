//
//  GroupCallService.swift
//  Voiid
//
//  Group voice/video calls over LiveKit (an SFU).
//
//  Why an SFU: a full mesh makes every participant upload a separate stream to
//  every other participant, so cost grows with n². It falls over past ~4 people
//  and mobile devices overheat first. With an SFU each client uploads once.
//
//  The SFU still cannot decrypt anything. Media is encrypted frame-by-frame with
//  a key derived from our MLS group (see `GroupEngine.callKeyPassphrase`), which
//  rotates on every membership commit. The key never reaches the API or the SFU —
//  `POST /calls/group/token` is purely an authorization endpoint.
//
//  Two WebRTC builds coexist in this app on purpose: the vendored
//  `WebRTC.xcframework` (M150) used by `CallService` for 1:1 calls, and LiveKit's
//  LK-prefixed `LiveKitWebRTC.framework` used here. Their ObjC classes are
//  `RTC*` and `LKRTC*` respectively — verified to share zero class symbols — and
//  both are dynamic frameworks with distinct install names, so they link cleanly.
//
//  They do, however, each own an audio-session singleton (`RTCAudioSession` vs
//  `LKRTCAudioSession`) driving the same `AVAudioSession`. Letting a 1:1 call and
//  a group call run at once would put two managers in charge of one audio route,
//  so `canStart` enforces that they are mutually exclusive.
//

import Foundation
import Combine
import LiveKit
import AVFoundation
import UIKit

// MARK: - Participant view model

/// A flattened, SwiftUI-friendly snapshot of a LiveKit participant.
///
/// The grid renders from these rather than touching `Participant` directly, so a
/// view update never races the SDK's internal state.
struct GroupCallParticipant: Identifiable, Equatable {
    /// LiveKit identity — our backend mints it as `"<user_id>:<device_id>"`.
    let id: String
    let displayName: String
    let isLocal: Bool
    let isSpeaking: Bool
    let isMuted: Bool
    let hasVideo: Bool
    /// The camera track to render, if any. Not part of equality (identity compare
    /// on a class ref would defeat SwiftUI diffing on every republish).
    let videoTrack: VideoTrack?

    /// The `user_id` half of the identity, for matching against the roster.
    var userId: String { id.split(separator: ":").first.map(String.init) ?? id }

    static func == (lhs: GroupCallParticipant, rhs: GroupCallParticipant) -> Bool {
        lhs.id == rhs.id
            && lhs.displayName == rhs.displayName
            && lhs.isLocal == rhs.isLocal
            && lhs.isSpeaking == rhs.isSpeaking
            && lhs.isMuted == rhs.isMuted
            && lhs.hasVideo == rhs.hasVideo
            && lhs.videoTrack === rhs.videoTrack
    }
}

/// High-level state of the group call, for driving the UI.
enum GroupCallState: Equatable {
    case idle
    case connecting
    case connected
    case reconnecting
    /// Terminal failure. The associated text is safe to show to a user.
    case failed(String)

    var isActive: Bool {
        switch self {
        case .idle, .failed: return false
        case .connecting, .connected, .reconnecting: return true
        }
    }
}

// MARK: - Service

@MainActor
final class GroupCallService: NSObject, ObservableObject {
    static let shared = GroupCallService()

    // MARK: Published state

    @Published private(set) var state: GroupCallState = .idle
    @Published private(set) var participants: [GroupCallParticipant] = []
    @Published private(set) var muted = false
    @Published private(set) var videoEnabled = false
    @Published private(set) var speakerOn = true
    @Published private(set) var connectedSeconds = 0
    /// Set when the deployment has no LiveKit configured (backend 503). The UI
    /// should say "group calling isn't available here" rather than show an error.
    @Published private(set) var groupCallingUnavailable = false
    /// The conversation this call belongs to, or nil when idle.
    @Published private(set) var conversationId: String?

    /// True while a group call occupies the audio route.
    var isActive: Bool { state.isActive }

    // MARK: Internals

    private let api = APIClient()
    private var room: Room?
    private var tickTimer: Timer?
    /// Guards against overlapping join attempts (double-tap on the call button).
    private var joining = false
    /// Live subscription to MLS epoch changes for the active conversation. When the
    /// group's membership changes mid-call the exporter secret rotates, so we must
    /// re-derive and re-apply the media key or participants at different epochs desync.
    /// Held only while in a call; torn down on leave.
    private var epochSubscription: AnyCancellable?

    private override init() { super.init() }

    // MARK: - Token

    private struct TokenBody: Encodable { let conversation_id: String }
    private struct TokenResponse: Decodable {
        let url: String
        let token: String
        let room: String
    }

    // MARK: - Join

    /// Whether a group call may start right now. 1:1 and group calls are mutually
    /// exclusive — see the audio-session note at the top of this file.
    static func canStart() -> Bool {
        CallService.shared.active == nil && !GroupCallService.shared.isActive
    }

    /// Join (or create) the LiveKit room backing `conversationId`.
    ///
    /// Safe to call redundantly: a second call while connecting or connected is a
    /// no-op. Never throws — every failure lands in `state == .failed` so a broken
    /// group call cannot take the app down with it.
    func join(conversationId: String, title: String, isVideo: Bool) async {
        guard !joining, !state.isActive else { return }
        guard CallService.shared.active == nil else {
            state = .failed("Finish your current call first.")
            return
        }

        joining = true
        defer { joining = false }

        self.conversationId = conversationId
        groupCallingUnavailable = false
        state = .connecting
        videoEnabled = isVideo
        muted = false

        // 1. Authorization token. The SFU URL comes back with it, so the app
        //    doesn't hardcode a region.
        let auth: TokenResponse
        do {
            auth = try await api.request("POST", "calls/group/token",
                                         body: TokenBody(conversation_id: conversationId),
                                         as: TokenResponse.self)
        } catch let APIError.http(status, _) where status == 503 {
            // LIVEKIT_* unset on this deployment — not an error the user caused.
            groupCallingUnavailable = true
            state = .failed("Group calling isn't available on this server.")
            self.conversationId = nil
            return
        } catch {
            state = .failed("Couldn't start the group call.")
            self.conversationId = nil
            return
        }

        // 2. The E2EE key, derived from our MLS group. If we can't derive it we
        //    must NOT fall back to an unencrypted room — that would silently hand
        //    plaintext media to the SFU, which is the one thing this must never do.
        let passphrase: String
        do {
            passphrase = try GroupEngine.shared.callKeyPassphrase(conversationId: conversationId)
        } catch {
            state = .failed("Secure keys for this group aren't ready yet.")
            self.conversationId = nil
            return
        }

        // 3. Connect with frame-level encryption enabled.
        let options = RoomOptions(
            defaultCameraCaptureOptions: CameraCaptureOptions(position: .front),
            adaptiveStream: true,   // don't decode tiles nobody is looking at
            dynacast: true,         // stop publishing layers nobody subscribes to
            encryptionOptions: EncryptionOptions.sharedKey(passphrase)
        )

        let room = Room(delegate: self, roomOptions: options)
        self.room = room

        do {
            try await room.connect(url: auth.url, token: auth.token)
            try await room.localParticipant.setMicrophone(enabled: true)
            if isVideo {
                try await room.localParticipant.setCamera(enabled: true)
            }
        } catch {
            await teardown()
            state = .failed("Couldn't connect to the group call.")
            return
        }

        configureAudioSession()
        subscribeToEpochChanges(conversationId: conversationId)
        state = .connected
        startTicking()
        refreshParticipants()
    }

    // MARK: - Mid-call re-key (MLS epoch skew)

    /// Subscribe to the active group's MLS epoch changes. Rapid consecutive commits
    /// (e.g. adding several devices at once) are coalesced by a short debounce so we
    /// re-key once at the settled epoch rather than thrashing the key provider. Only
    /// events for the current conversation are acted on; the subscription is dropped
    /// on leave.
    private func subscribeToEpochChanges(conversationId: String) {
        epochSubscription = GroupEngine.shared.groupEpochChanged
            .filter { $0 == conversationId }
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] convId in
                Task { @MainActor in self?.reapplyCallKey(conversationId: convId) }
            }
    }

    /// Re-derive this conversation's MLS call key and re-apply it to LiveKit's shared-key
    /// E2EE provider, rolling the media key to the new epoch. Best-effort: if anything is
    /// missing or throws we log and keep the call up on the previous key rather than tear
    /// it down — a stale key degrades to "can't decrypt the newest epoch", never a crash.
    private func reapplyCallKey(conversationId: String) {
        guard state.isActive, self.conversationId == conversationId, let room else { return }
        guard let keyProvider = room.e2eeManager?.keyProvider else {
            NSLog("[VOIID] group-call rekey: no E2EE key provider on room; staying on old key")
            return
        }
        let passphrase: String
        do {
            passphrase = try GroupEngine.shared.callKeyPassphrase(conversationId: conversationId)
        } catch {
            NSLog("[VOIID] group-call rekey: re-derive failed, keeping old key: \(error)")
            return
        }
        // Shared-key mode: setKey defaults to the current key index (0, as set at join),
        // so this replaces the shared key in place — the supported way to roll it. Every
        // member that reaches this epoch derives the byte-identical passphrase, so they
        // converge on the same key once each has applied the commit.
        keyProvider.setKey(key: passphrase)
        NSLog("[VOIID] group-call rekey: applied new epoch key conv=\(conversationId)")
    }

    // MARK: - Leave

    /// Leave the call and release the audio route. Idempotent.
    func leave() async {
        guard state.isActive || room != nil else { return }
        await teardown()
        state = .idle
    }

    private func teardown() async {
        stopTicking()
        epochSubscription?.cancel()
        epochSubscription = nil
        if let room {
            room.remove(delegate: self)
            await room.disconnect()
        }
        room = nil
        participants = []
        conversationId = nil
        connectedSeconds = 0
        muted = false
        videoEnabled = false
        deactivateAudioSession()
    }

    // MARK: - Controls

    func toggleMute() {
        guard let room else { return }
        let next = !muted
        muted = next  // optimistic, so the button responds immediately
        Task { [weak self] in
            do {
                try await room.localParticipant.setMicrophone(enabled: !next)
            } catch {
                // Roll back if the SDK refused.
                await MainActor.run { self?.muted = !next }
            }
        }
    }

    func toggleVideo() {
        guard let room else { return }
        let next = !videoEnabled
        videoEnabled = next
        Task { [weak self] in
            do {
                try await room.localParticipant.setCamera(enabled: next)
            } catch {
                await MainActor.run { self?.videoEnabled = !next }
            }
            await MainActor.run { self?.refreshParticipants() }
        }
    }

    func switchCamera() {
        guard let room else { return }
        Task {
            // Reach the capturer through the published camera track.
            guard let pub = room.localParticipant.firstCameraPublication,
                  let track = pub.track as? LocalVideoTrack,
                  let capturer = track.capturer as? CameraCapturer else { return }
            _ = try? await capturer.switchCameraPosition()
        }
    }

    func toggleSpeaker() {
        speakerOn.toggle()
        configureAudioSession()
    }

    // MARK: - Audio session
    //
    // `.playAndRecord` with `.voiceChat` keeps audio alive when the app is
    // backgrounded, using the existing `audio` UIBackgroundMode already declared
    // for 1:1 calls. No new entitlement or background mode is needed.

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .voiceChat,
                                    options: speakerOn ? [.defaultToSpeaker, .allowBluetooth]
                                                       : [.allowBluetooth])
            try session.setActive(true)
            try session.overrideOutputAudioPort(speakerOn ? .speaker : .none)
        } catch {
            // A failed route change must not end the call — audio may still work.
        }
    }

    private func deactivateAudioSession() {
        // Let other audio (music, another call) resume promptly.
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Duration

    private func startTicking() {
        stopTicking()
        connectedSeconds = 0
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .connected else { return }
                self.connectedSeconds += 1
            }
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - Participant snapshot

    /// Rebuild the published participant list from the room's current state.
    ///
    /// Local participant sorts first; everyone else keeps a stable order by
    /// identity so tiles don't shuffle when unrelated state changes.
    fileprivate func refreshParticipants() {
        guard let room else {
            participants = []
            return
        }

        var out: [GroupCallParticipant] = []

        let local = room.localParticipant
        out.append(GroupCallParticipant(
            id: local.identity?.stringValue ?? "me",
            displayName: local.name?.isEmpty == false ? local.name! : "You",
            isLocal: true,
            isSpeaking: local.isSpeaking,
            isMuted: !local.isMicrophoneEnabled(),
            hasVideo: local.isCameraEnabled(),
            videoTrack: local.firstCameraVideoTrack
        ))

        let remotes = room.remoteParticipants.values.sorted {
            ($0.identity?.stringValue ?? "") < ($1.identity?.stringValue ?? "")
        }
        for p in remotes {
            let identity = p.identity?.stringValue ?? ""
            out.append(GroupCallParticipant(
                id: identity,
                displayName: p.name?.isEmpty == false ? p.name! : Self.shortName(identity),
                isLocal: false,
                isSpeaking: p.isSpeaking,
                isMuted: !p.isMicrophoneEnabled(),
                hasVideo: p.isCameraEnabled(),
                videoTrack: p.firstCameraVideoTrack
            ))
        }

        participants = out
    }

    /// Fallback label when the server didn't set a display name: show a short
    /// prefix of the user id rather than the full `user:device` identity.
    private static func shortName(_ identity: String) -> String {
        let uid = identity.split(separator: ":").first.map(String.init) ?? identity
        return uid.count > 6 ? String(uid.prefix(6)) : uid
    }
}

// MARK: - RoomDelegate
//
// LiveKit already handles ICE restarts and reconnection internally; these hooks
// surface that to the UI rather than reimplementing it.

extension GroupCallService: RoomDelegate {
    nonisolated func room(_ room: Room, didUpdateConnectionState state: ConnectionState, from _: ConnectionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                // Covers both first connect and recovery from a drop.
                if self.state != .connected, self.room != nil { self.state = .connected }
                self.refreshParticipants()
            case .reconnecting:
                if self.state.isActive { self.state = .reconnecting }
            case .disconnected:
                if self.state.isActive {
                    await self.teardown()
                    self.state = .idle
                }
            default:
                break
            }
        }
    }

    nonisolated func room(_: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            guard self.state.isActive else { return }
            await self.teardown()
            // A clean hang-up also lands here; only surface genuine errors.
            self.state = error == nil ? .idle : .failed("The group call disconnected.")
        }
    }

    nonisolated func room(_: Room, didFailToConnectWithError _: LiveKitError?) {
        Task { @MainActor in
            await self.teardown()
            self.state = .failed("Couldn't connect to the group call.")
        }
    }

    nonisolated func room(_: Room, participantDidConnect _: RemoteParticipant) {
        Task { @MainActor in self.refreshParticipants() }
    }

    nonisolated func room(_: Room, participantDidDisconnect _: RemoteParticipant) {
        Task { @MainActor in self.refreshParticipants() }
    }

    nonisolated func room(_: Room, didUpdateSpeakingParticipants _: [Participant]) {
        Task { @MainActor in self.refreshParticipants() }
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didSubscribeTrack _: RemoteTrackPublication) {
        Task { @MainActor in self.refreshParticipants() }
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didUnsubscribeTrack _: RemoteTrackPublication) {
        Task { @MainActor in self.refreshParticipants() }
    }

    nonisolated func room(_: Room, participant _: LocalParticipant, didPublishTrack _: LocalTrackPublication) {
        Task { @MainActor in self.refreshParticipants() }
    }

    nonisolated func room(_: Room, participant _: LocalParticipant, didUnpublishTrack _: LocalTrackPublication) {
        Task { @MainActor in self.refreshParticipants() }
    }

    nonisolated func room(_: Room, participant _: Participant, trackPublication _: TrackPublication, didUpdateIsMuted _: Bool) {
        Task { @MainActor in self.refreshParticipants() }
    }

    /// E2EE health. If frames stop decrypting the key is out of step with the
    /// group — usually a membership commit we haven't applied yet.
    nonisolated func room(_: Room, trackPublication _: TrackPublication, didUpdateE2EEState e2eeState: E2EEState) {
        Task { @MainActor in
            // `missing_key` can appear transiently right after joining, so it is
            // deliberately not treated as fatal.
            if e2eeState == .decryption_failed || e2eeState == .encryption_failed {
                self.state = .failed("Encryption keys are out of sync. Rejoin the call.")
            }
        }
    }
}
