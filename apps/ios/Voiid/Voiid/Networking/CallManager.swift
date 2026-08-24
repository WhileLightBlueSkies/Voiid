//
//  CallManager.swift
//  Voiid
//
//  CallKit bridge for 1:1 voice/video calls. Reports incoming calls to the OS so
//  the native full-screen / lock-screen incoming-call UI appears, and routes the
//  OS actions (answer / end / mute) back into `CallService` (the WebRTC engine).
//
//  It also owns the AVAudioSession handoff that WebRTC needs: when CallKit's
//  provider activates the audio session we hand it to WebRTC's LKRTCAudioSession
//  (manual-audio mode), and disable audio again on deactivate. This is the
//  standard CallKit + WebRTC pattern.
//
//  NOTE (runtime caveat): CallKit + VoIP push only deliver real incoming calls on
//  a SIGNED build on a real device. In the simulator this compiles and the state
//  machine runs, but the native call UI / PushKit wake-up won't fire.
//

import Foundation
import CallKit
import AVFoundation
import Intents
import LiveKitWebRTC

@MainActor
final class CallManager: NSObject {
    static let shared = CallManager()

    private let provider: CXProvider
    private let callController = CXCallController()

    /// The engine we drive. Wired up in `configure()` to avoid an init cycle.
    weak var service: CallService?

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        // Call waiting: a second inbound call must be reportable while the first
        // is up, otherwise CallKit rejects the report and the user never gets the
        // native "answer / decline" choice. One call per group, two groups — the
        // two calls are independent, never merged (we don't do conferencing).
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 2
        // CONTACT LINKING (the WhatsApp behaviour).
        //
        // `.phoneNumber` is what makes iOS link a call to the address book: given an
        // E.164 handle the system matches it to a CNContact itself and shows that
        // person's saved name and photo in Recents, on the lock screen, and in the
        // contact card. A `.generic` handle is an opaque string it cannot match, which
        // is why calls previously appeared in Recents unlinked and un-callable-back.
        //
        // `.generic` stays as a fallback for peers whose number we don't hold (met via
        // username, or an address-book entry that was never synced) — CallKit rejects
        // an empty handle outright, so there must always be something to pass.
        //
        // PRIVACY CONSEQUENCE, deliberately accepted: a `.phoneNumber` handle puts the
        // peer's number in the system call log, which syncs through iCloud. That is
        // exactly what WhatsApp and Signal do and what users expect from "it shows up
        // in my phone app", but it is a real change from an opaque handle.
        config.supportedHandleTypes = [.phoneNumber, .generic]
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
        // WebRTC drives the audio session itself, activated by CallKit's callbacks.
        let rtcSession = LKRTCAudioSession.sharedInstance()
        rtcSession.useManualAudio = true
        rtcSession.isAudioEnabled = false
        Self.configureAudioSessionForCalls()
    }

    /// The category/mode a VoIP call needs, declared up front so WebRTC configures
    /// the CallKit-provided session correctly:
    ///   .playAndRecord + .voiceChat  – two-way call audio, echo cancellation, and
    ///                                  (with the `audio` background mode) keeps
    ///                                  flowing while backgrounded or locked.
    ///   allowBluetooth(A2DP)         – headsets/car kits can take the call.
    /// This is the session WebRTC applies in `audioSessionDidActivate`.
    private static func configureAudioSessionForCalls() {
        let config = LKRTCAudioSessionConfiguration.webRTC()
        config.category = AVAudioSession.Category.playAndRecord.rawValue
        config.mode = AVAudioSession.Mode.voiceChat.rawValue
        config.categoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP, .duckOthers]
        LKRTCAudioSessionConfiguration.setWebRTC(config)
    }

    func configure(service: CallService) { self.service = service }

    // MARK: - Reporting calls to CallKit

    /// Build the handle CallKit will try to match against the address book.
    ///
    /// Prefer the E.164 number — that is the only value iOS can resolve to a contact.
    /// Fall back to the opaque routing id when we have no number, which still produces
    /// a valid (if unlinked) call rather than a rejected report.
    private func makeHandle(phoneNumber: String?, fallback: String) -> CXHandle {
        if let phone = Self.normalizedE164(phoneNumber) {
            return CXHandle(type: .phoneNumber, value: phone)
        }
        return CXHandle(type: .generic, value: fallback)
    }

    /// Strict E.164, or nil.
    ///
    /// CONSISTENCY IS THE WHOLE POINT. iOS matches a call to a contact by the handle
    /// STRING, so "+91 91234 56789" and "+919123456789" are two different people as
    /// far as Recents is concerned — the same person would accumulate duplicate,
    /// separately-linked entries in the call log. Every handle for a given peer must
    /// therefore be byte-identical, so we normalize here as well as on write.
    ///
    /// Returns nil rather than a best guess for anything that isn't a plausible E.164:
    /// a malformed handle links to nothing and pollutes Recents, so the generic
    /// fallback is strictly better.
    static func normalizedE164(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var digits = raw.filter { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        // Keep a leading "+" if it was there; otherwise we cannot invent a country
        // code, and a national-format number would match the wrong contact.
        if raw.hasPrefix("+") { digits = "+" + digits } else { return nil }
        // E.164 allows at most 15 digits; anything longer is not a phone number.
        guard digits.count >= 8, digits.count <= 16 else { return nil }
        return digits
    }

    /// Report an inbound call so the OS shows the native incoming-call UI.
    ///
    /// `phoneNumber` is the peer's E.164 when known; pass nil and the call still works,
    /// it just won't link to a contact card.
    func reportIncomingCall(uuid: UUID, handle: String, displayName: String, hasVideo: Bool,
                            phoneNumber: String? = nil,
                            completion: @escaping (Bool) -> Void) {
        let update = CXCallUpdate()
        update.remoteHandle = makeHandle(phoneNumber: phoneNumber, fallback: handle)
        // Still set this even with a phone handle: it is what shows before the system
        // finishes contact matching, and it carries OUR resolved name (which respects
        // the address-book name the user saved) rather than whatever iOS decides.
        update.localizedCallerName = displayName
        update.hasVideo = hasVideo
        // Hold is real: CXSetHeldCallAction below disables the local tracks and
        // mirrors the state to the peer over call_hold/call_unhold.
        update.supportsHolding = true
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error { NSLog("[VOIID] CallKit reportIncoming error: \(error.localizedDescription)") }
            completion(error == nil)
        }
        // Donate so this call appears in Recents attributed to Voiid, and so Siri
        // learns "call <name> on Voiid".
        donateCallIntent(displayName: displayName, phoneNumber: phoneNumber,
                         hasVideo: hasVideo, outgoing: false)
    }

    /// Start an outgoing call through CallKit (gives us the system audio session).
    func startOutgoingCall(uuid: UUID, handle: String, displayName: String, hasVideo: Bool,
                           phoneNumber: String? = nil) {
        let cxHandle = makeHandle(phoneNumber: phoneNumber, fallback: handle)
        let action = CXStartCallAction(call: uuid, handle: cxHandle)
        action.isVideo = hasVideo
        action.contactIdentifier = displayName
        callController.request(CXTransaction(action: action)) { error in
            if let error { NSLog("[VOIID] CallKit startCall error: \(error.localizedDescription)") }
        }
        let update = CXCallUpdate()
        update.remoteHandle = cxHandle
        update.localizedCallerName = displayName
        update.hasVideo = hasVideo
        update.supportsHolding = true
        provider.reportCall(with: uuid, updated: update)
        donateCallIntent(displayName: displayName, phoneNumber: phoneNumber,
                         hasVideo: hasVideo, outgoing: true)
    }

    // MARK: - Siri / Recents donation
    //
    // Donating an INStartCallIntent is the second half of contact linking. The handle
    // gets the call matched to a contact; the donation is what makes iOS offer "Voiid"
    // as a way to call that person — the row inside the contact card, the Siri phrase,
    // and a Recents entry that redials through this app instead of the carrier.
    //
    // Failure is silent and harmless: a missed donation costs a Siri suggestion, never
    // the call itself, so this must never be in the call's critical path.

    private func donateCallIntent(displayName: String, phoneNumber: String?,
                                  hasVideo: Bool, outgoing: Bool) {
        // With no number there is nothing for the system to match the person against,
        // so a donation would produce an un-actionable suggestion. Normalized for the
        // same reason as the handle: a differently-formatted number donates as a
        // different person and splits that contact's history in two.
        guard let phone = Self.normalizedE164(phoneNumber) else { return }

        let handle = INPersonHandle(value: phone, type: .phoneNumber)
        let person = INPerson(personHandle: handle,
                              nameComponents: nil,
                              displayName: displayName,
                              image: nil,
                              contactIdentifier: nil,
                              customIdentifier: nil)

        let intent = INStartCallIntent(callRecordFilter: nil,
                                       callRecordToCallBack: nil,
                                       audioRoute: .unknown,
                                       destinationType: .normal,
                                       contacts: [person],
                                       callCapability: hasVideo ? .videoCall : .audioCall)

        let interaction = INInteraction(intent: intent, response: nil)
        // Direction matters: it is what lets iOS distinguish a call you made from one
        // you received when it builds the Recents list.
        interaction.direction = outgoing ? .outgoing : .incoming
        interaction.donate { error in
            if let error {
                NSLog("[VOIID] call intent donation failed: \(error.localizedDescription)")
            }
        }
    }

    /// Ask CallKit to hold/unhold. Routed through the transaction API (not applied
    /// directly) so the in-app hold button and the system UI end up in the same
    /// state — CallKit calls us back via `CXSetHeldCallAction`.
    func requestHold(uuid: UUID, onHold: Bool) {
        let action = CXSetHeldCallAction(call: uuid, onHold: onHold)
        callController.request(CXTransaction(action: action)) { error in
            if let error { NSLog("[VOIID] CallKit setHeld error: \(error.localizedDescription)") }
        }
    }

    /// Tell CallKit the outgoing call started ringing / connected.
    func reportOutgoingConnecting(uuid: UUID) { provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil) }
    func reportOutgoingConnected(uuid: UUID) { provider.reportOutgoingCall(with: uuid, connectedAt: nil) }

    /// End a call in CallKit (peer hung up, we hung up, error, etc.).
    ///
    /// The reason is not cosmetic: `.unanswered` is what marks the entry as a MISSED
    /// call in Recents (red, and counted in the badge). Reporting `.remoteEnded` for a
    /// call that was never answered — as this always used to — files it as a normal
    /// completed call, so missed calls were invisible in the phone app.
    func endCall(uuid: UUID, reason: CXCallEndedReason = .remoteEnded) {
        provider.reportCall(with: uuid, endedAt: nil, reason: reason)
    }

    /// Request-to-end via the transaction API (when the user taps hang up in-app).
    func requestEnd(uuid: UUID) {
        let action = CXEndCallAction(call: uuid)
        callController.request(CXTransaction(action: action)) { error in
            if let error { NSLog("[VOIID] CallKit requestEnd error: \(error.localizedDescription)") }
        }
    }
}

// MARK: - CXProviderDelegate

extension CallManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in self.service?.endActiveCall(notifyPeer: true, fromCallKit: true) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            self.service?.callKitAnswer(uuid: action.callUUID)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            self.service?.callKitEnd(uuid: action.callUUID)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            self.service?.callKitStart(uuid: action.callUUID)
            action.fulfill()
        }
    }

    /// Hold, from the native in-call UI, from our own hold button (which routes
    /// through `requestHold`), or implicitly when the user answers a second,
    /// waiting call.
    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        Task { @MainActor in
            self.service?.callKitSetHeld(uuid: action.callUUID, held: action.isOnHold)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in
            self.service?.setMuted(action.isMuted)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // Hand the CallKit-activated session to WebRTC and enable audio.
        LKRTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        LKRTCAudioSession.sharedInstance().isAudioEnabled = true
        // The ringback tone may have activated this session itself (it plays
        // before the call connects, and didActivate only fires on connect). Now
        // that WebRTC owns it, CallToneService must stop treating it as its own
        // so it can never deactivate a live call's session.
        Task { @MainActor in
            CallToneService.shared.noteWebRTCTookOverSession()
            // The session is live now, so its route list is finally meaningful — populate
            // the picker, and reflect a Bluetooth device that was already connected before
            // the call started (no route-change notification fires for that case).
            CallService.shared.refreshAudioRoutes()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        LKRTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
        LKRTCAudioSession.sharedInstance().isAudioEnabled = false
    }
}
