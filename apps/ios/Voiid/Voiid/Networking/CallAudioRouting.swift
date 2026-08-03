//
//  CallAudioRouting.swift
//  Voiid
//
//  In-call audio-output routing: earpiece / speaker / Bluetooth / wired, with a picker.
//
//  WHY THIS EXISTS
//  ---------------
//  The call UI used to expose a single speaker ON/OFF toggle, and only on voice calls. That
//  cannot express "send this call to my AirPods" — the third, increasingly-default route — and
//  a video call had no audio control at all. When a Bluetooth headset was connected the app
//  auto-followed it (handleRouteChange), but the user had no way to route BACK to the phone, or
//  to pick Bluetooth when the auto-follow didn't fire (e.g. the headset was already connected
//  before the call began). This adds an explicit route picker, available on voice AND video.
//
//  HOW ROUTING WORKS ON iOS
//  ------------------------
//  For a `.playAndRecord` VoIP session the OUTPUT follows the INPUT for the built-in and
//  Bluetooth-HFP routes, so we steer with `setPreferredInput`, and use `overrideOutputAudioPort`
//  only for the one route that has no input of its own — the loudspeaker. Every mutation goes
//  through RTCAudioSession's lock, because WebRTC owns this session (manual-audio mode) and an
//  unlocked change races its own configuration.
//
//  Everything here is best-effort: a failed route change leaves the call on its current route,
//  never breaks it. The pre-existing auto-follow behaviour is unchanged and still the default.
//

import Foundation
import AVFoundation
import WebRTC

/// A selectable audio output. `id` is stable per route KIND (plus the port uid for external
/// devices) so SwiftUI can diff the picker and highlight the live one.
enum CallAudioRoute: Identifiable, Equatable {
    case earpiece
    case speaker
    case bluetooth(name: String, uid: String)
    case wired(name: String)

    var id: String {
        switch self {
        case .earpiece: return "earpiece"
        case .speaker: return "speaker"
        case .bluetooth(_, let uid): return "bt:\(uid)"
        case .wired: return "wired"
        }
    }

    /// SF Symbol for the picker + the collapsed button.
    var symbol: String {
        switch self {
        case .earpiece: return "iphone"
        case .speaker: return "speaker.wave.2.fill"
        case .bluetooth: return "airpodspro"   // generic BT-audio glyph; fits AirPods/most headsets
        case .wired: return "headphones"
        }
    }

    var label: String {
        switch self {
        case .earpiece: return "iPhone"
        case .speaker: return "Speaker"
        case .bluetooth(let name, _): return name
        case .wired(let name): return name
        }
    }
}

extension CallService {

    /// Bluetooth-HFP and wired input port types we treat as external call routes.
    private static let externalInputPorts: Set<AVAudioSession.Port> =
        [.bluetoothHFP, .headsetMic, .usbAudio, .carAudio]

    /// Recompute the available routes and the live one from the current AVAudioSession, and
    /// publish them. Call after any route change and when a call becomes active.
    /// True when a headset — Bluetooth, wired or USB — is connected right now.
    ///
    /// Used to decide whether the video-call speaker default should apply. It reads
    /// `availableInputs` rather than the live output, because it is asked at connect time
    /// when the route may not have settled yet.
    var hasExternalAudioDevice: Bool {
        let session = AVAudioSession.sharedInstance()
        return (session.availableInputs ?? []).contains { input in
            switch input.portType {
            case .bluetoothHFP, .carAudio, .headsetMic, .usbAudio: return true
            default: return false
            }
        }
    }

    func refreshAudioRoutes() {
        let session = AVAudioSession.sharedInstance()

        var routes: [CallAudioRoute] = [.earpiece, .speaker]
        // Connected external inputs become routes. `availableInputs` lists what could be
        // selected; a Bluetooth headset shows up here whether or not it is currently live.
        for input in session.availableInputs ?? [] {
            switch input.portType {
            case .bluetoothHFP, .carAudio:
                routes.append(.bluetooth(name: input.portName, uid: input.uid))
            case .headsetMic, .usbAudio:
                routes.append(.wired(name: input.portName))
            default:
                break
            }
        }
        // Stable order: earpiece, speaker, then external — dedup by id.
        var seen = Set<String>()
        audioRoutes = routes.filter { seen.insert($0.id).inserted }

        currentRoute = liveRoute(session)
    }

    /// Which route the session is ACTUALLY on right now, read from its output port.
    private func liveRoute(_ session: AVAudioSession) -> CallAudioRoute {
        guard let out = session.currentRoute.outputs.first else { return .earpiece }
        switch out.portType {
        case .builtInSpeaker:
            return .speaker
        case .bluetoothHFP, .bluetoothA2DP, .carAudio:
            return .bluetooth(name: out.portName, uid: out.uid)
        case .headphones, .usbAudio, .headsetMic:
            return .wired(name: out.portName)
        default:
            return .earpiece   // builtInReceiver and anything else read as "at your ear"
        }
    }

    /// Route the live call to a chosen output. Best-effort and lock-guarded.
    func selectAudioRoute(_ route: CallAudioRoute) {
        let rtc = RTCAudioSession.sharedInstance()
        let session = AVAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }

        do {
            switch route {
            case .speaker:
                // The loudspeaker is the one output with no input to steer by.
                try session.overrideOutputAudioPort(.speaker)
                speakerOnChanged(true)
            case .earpiece:
                try session.overrideOutputAudioPort(.none)
                // Force the built-in mic so output falls back to the receiver rather than
                // sticking on a still-connected Bluetooth device.
                if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                    try session.setPreferredInput(builtIn)
                }
                speakerOnChanged(false)
            case .bluetooth(_, let uid):
                try session.overrideOutputAudioPort(.none)
                if let bt = session.availableInputs?.first(where: {
                    $0.uid == uid && Self.externalInputPorts.contains($0.portType)
                }) {
                    try session.setPreferredInput(bt)
                }
                speakerOnChanged(false)
            case .wired(let name):
                try session.overrideOutputAudioPort(.none)
                if let wired = session.availableInputs?.first(where: {
                    $0.portName == name && Self.externalInputPorts.contains($0.portType)
                }) {
                    try session.setPreferredInput(wired)
                }
                speakerOnChanged(false)
            }
        } catch {
            NSLog("[VOIID] audio route change to \(route.label) failed: \(error.localizedDescription)")
        }
        refreshAudioRoutes()
    }
}
