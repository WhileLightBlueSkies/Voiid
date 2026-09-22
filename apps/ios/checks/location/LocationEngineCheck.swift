import Foundation
import CoreLocation

@main struct LocationEngineCheck {
    @MainActor static func main() async {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); count += 1
        }
        let engine = LocationShareEngine.shared
        let account = TokenStore.shared.userId!
        defer { UserDefaults.standard.removeObject(forKey: "voiid.location.pending-stops.\(account)") }
        func start() async -> String? {
            await engine.startLiveShare(conversationId: "chat", isGroup: false, peerUserId: "peer", recipientIds: ["peer"], duration: .oneHour)
        }
        LocationService.instance.suppliedFix = nil
        let missing = await start()
        check(missing == nil && LocationAPI.creates == 0, "No server share without a first fix")
        check(engine.lastError != nil, "Location failure surfaces an error")
        LocationService.instance.suppliedFix = CLLocation(latitude: 12.9, longitude: 77.6)
        ChatEngine.failStart = true
        let failed = await start()
        check(failed == nil && engine.outboundShares.isEmpty, "Failed invitation never shows a running share")
        check(!LocationService.instance.streaming, "Failed invitation never starts GPS stream")
        check(LocationKeyStore.shared.keys.isEmpty, "Failed start deletes its key")
        for _ in 0..<20 { await Task.yield() }
        check(LocationAPI.ended.contains("share-1"), "Failed/ambiguous start retires server session")
        ChatEngine.failStart = false
        let id = await start()!
        check(engine.isEmitting(id) && LocationService.instance.streaming, "Successful invitation starts stream")
        check(engine.lastFix(shareId: id) != nil && WebSocketClient.shared.updates > 0, "First location is sent immediately")
        check(engine.outboundShares.first?.audienceCount == 1, "Audience saved")
        ChatEngine.pauseStop = true
        let stopping = Task { await engine.stopLiveShare(id) }
        while ChatEngine.pausedStop == nil { await Task.yield() }
        check(!engine.isEmitting(id) && !LocationService.instance.streaming, "Stop shuts down locally before network completes")
        check(engine.outboundShares.isEmpty && LocationKeyStore.shared.key(shareId: id) == nil, "Stop clears banner and key immediately")
        check(engine.shareState(shareId: id, expiresAt: Date().addingTimeInterval(3600), cadence: 15) == .ended, "Stop is rendered as ended")
        ChatEngine.pausedStop?.resume(); ChatEngine.pausedStop = nil
        await stopping.value
        check(LocationAPI.ended.contains(id), "Server stop completes after local stop")
        let offline = await start()!
        LocationAPI.failEnd = true
        await engine.stopLiveShare(offline)
        check(!engine.isEmitting(offline), "Offline stop still stops locally")
        check(UserDefaults.standard.data(forKey: "voiid.location.pending-stops.\(account)") != nil, "Offline stop is persisted for retry")
        LocationAPI.failEnd = false
        engine.configure()
        for _ in 0..<30 { await Task.yield() }
        check(LocationAPI.ended.contains(offline), "Foreground retries pending stop")
        var fix = LocationFix(shareId: "valid", seq: 1, timestampMillis: Date().timeIntervalSince1970*1000, lat: 12, lon: 77, acc: 10)
        check(fix.isValid, "Valid coordinate accepted")
        fix.lat = 91; check(!fix.isValid, "Out-of-range coordinate rejected")
        fix.lat = .nan; check(!fix.isValid, "Non-finite coordinate rejected")
        fix.lat = 12; fix.acc = -1; check(!fix.isValid, "Invalid accuracy rejected")
        fix.acc = 10; fix.seq = -1; check(!fix.isValid, "Invalid sequence rejected")
        LocationStore.ended.insert("persisted-stop")
        check(engine.shareState(shareId: "persisted-stop", expiresAt: nil, cadence: 15) == .ended, "Persisted stop survives missing in-memory marker")
        LocationStore.inbound = [("incoming", "owner", Date().addingTimeInterval(3600), 15)]
        LocationKeyStore.shared.setKey(Data(repeating: 1, count: 32), shareId: "incoming")
        func receive(_ fix: LocationFix, from: String = "owner") async {
            NotificationCenter.default.post(name: .voiidLocationRelayUpdate, object: nil,
                userInfo: ["share_id": "incoming", "from": from,
                           "ciphertext": fix.envelope().encoded().base64EncodedString()])
            for _ in 0..<15 { await Task.yield() }
        }
        let incoming = LocationFix(shareId: "incoming", seq: 1, timestampMillis: Date().timeIntervalSince1970*1000, lat: 12, lon: 77, acc: 10)
        await receive(incoming, from: "stranger")
        check(engine.lastFix(shareId: "incoming") == nil, "Wrong sender cannot replace live location")
        var wrongShare = incoming; wrongShare.shareId = "another-share"
        await receive(wrongShare)
        check(engine.lastFix(shareId: "incoming") == nil, "Envelope share must match relay share")
        await receive(incoming)
        check(engine.lastFix(shareId: "incoming")?.seq == 1, "Valid owner update reaches location store")
        var replay = incoming; replay.lat = 50
        await receive(replay)
        check(engine.lastFix(shareId: "incoming")?.lat == 12, "Duplicate sequence cannot move pin")
        var future = incoming; future.seq = 2; future.timestampMillis += 3_600_000
        await receive(future)
        check(engine.lastFix(shareId: "incoming")?.seq == 1, "Future timestamp cannot keep a share falsely live")
        let extended = await start()!
        await engine.extendLiveShare(extended, duration: .eightHours)
        check(ChatEngine.controls.last?.k == .live_start && ChatEngine.controls.last?.s == extended,
              "Extending distributes the new expiry to recipients")
        await engine.stopLiveShare(extended)
        print("Passed \(count) location lifecycle and fix-validation checks")
    }
}
