import Foundation
import CoreLocation

// The iOS-only authorization enum is part of the platform seam in this macOS harness.
enum CLAuthorizationStatus { case notDetermined, restricted, denied, authorizedAlways, authorizedWhenInUse }

@MainActor final class TokenStore { static let shared = TokenStore(); var userId: String? = "location-check-\(UUID().uuidString)" }
@MainActor final class LocationService {
    static var instance: LocationService!
    var onFix: ((CLLocation) -> Void)?
    var onAuthChange: ((CLAuthorizationStatus, Bool) -> Void)?
    var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
    var isReducedAccuracy = false
    var streaming = false
    var suppliedFix: CLLocation? = CLLocation(latitude: 12.9, longitude: 77.6)
    init() { Self.instance = self }
    func requestWhenInUse() {}
    func requestAlways() {}
    func startLive() { streaming = true }
    func stopUpdating() { streaming = false }
    func cancelOneShot() {}
    func requestOneShot(_ completion: @escaping (CLLocation?) -> Void) { completion(suppliedFix) }
}
@MainActor struct LocationAPI {
    struct Response { let share_id: String; let expires_at: String? }
    static var creates = 0
    static var ended: [String] = []
    static var failEnd = false
    func createShare(conversationId: String, targetUserIds: [String], durationSeconds: Int) async throws -> Response {
        Self.creates += 1
        return Response(share_id: "share-\(Self.creates)", expires_at: ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(durationSeconds))))
    }
    func endShare(_ id: String) async throws { if Self.failEnd { throw CheckError.offline }; Self.ended.append(id) }
    func extendShare(_ id: String, durationSeconds: Int) async throws -> Response { Response(share_id: id, expires_at: nil) }
}
enum CheckError: Error { case offline }
@MainActor final class LocationKeyStore {
    static let shared = LocationKeyStore()
    var keys: [String: Data] = [:]
    func key(shareId: String) -> Data? { keys[shareId] }
    func setKey(_ key: Data, shareId: String) { keys[shareId] = key }
    func deleteKey(shareId: String) { keys[shareId] = nil }
}
@MainActor enum LocationStore {
    static var outbound: [String: OutboundShare] = [:]
    static var recipients: [String: [String]] = [:]
    static var ended: Set<String> = []
    static var fixes: [String: (fix: LocationFix, senderUserId: String, fixedAt: Date)] = [:]
    static var inbound: [(shareId: String, ownerUserId: String, expiresAt: Date, cadence: Int)] = []
    static func activeOutbound() -> [OutboundShare] { outbound.values.filter { !ended.contains($0.id) && $0.expiresAt > Date() } }
    static func targets(shareId: String) -> [String] { recipients[shareId] ?? [] }
    static func upsertOutbound(id: String, conversationId: String, isGroup: Bool, expiresAtMillis: Double, cadenceSeconds: Int, targets: [String]) {
        outbound[id] = OutboundShare(id: id, conversationId: conversationId, isGroup: isGroup, audienceCount: targets.count, expiresAt: Date(timeIntervalSince1970: expiresAtMillis/1000), cadenceSeconds: cadenceSeconds)
        recipients[id] = targets
    }
    static func end(id: String) { ended.insert(id); fixes[id] = nil }
    static func extend(id: String, expiresAtMillis: Double) { outbound[id]?.expiresAt = Date(timeIntervalSince1970: expiresAtMillis/1000) }
    static func saveFix(_ fix: LocationFix, senderUserId: String) { fixes[fix.shareId] = (fix,senderUserId,fix.date) }
    static func lastFix(shareId: String) -> (fix: LocationFix, senderUserId: String, fixedAt: Date)? { fixes[shareId] }
    static func hasActiveInbound(shareId: String) -> Bool { inbound.contains { $0.shareId == shareId && $0.expiresAt > Date() } && !ended.contains(shareId) }
    static func activeInboundAll() -> [(shareId: String, ownerUserId: String, expiresAt: Date, cadence: Int)] { inbound }
    static func isEnded(_ id: String) -> Bool { ended.contains(id) || (outbound[id].map { $0.expiresAt <= Date() } ?? false) }
}
@MainActor final class WebSocketClient {
    static let shared = WebSocketClient()
    var updates = 0
    func sendLocationStop(shareId: String, recipientIds: [String]) {}
    func sendLocationUpdate(shareId: String, recipientIds: [String], ciphertext: String) { updates += 1 }
}
@MainActor final class ChatEngine {
    static let shared = ChatEngine()
    static var failStart = false
    static var pauseStop = false
    static var pausedStop: CheckedContinuation<Void, Never>?
    static var controls: [LocationEnvelope] = []
    func sendLocation(plaintextJSON: String, conversationId: String, peerUserId: String, displayText: String, rendersBubble: Bool) async throws {
        let envelope = LocationEnvelope.parse(plaintextJSON)!
        Self.controls.append(envelope)
        if envelope.k == .live_start && Self.failStart { throw CheckError.offline }
        if envelope.k == .live_stop && Self.pauseStop {
            Self.pauseStop = false
            await withCheckedContinuation { Self.pausedStop = $0 }
        }
    }
}
@MainActor final class GroupEngine {
    static let shared = GroupEngine()
    func sendGroupMessage(conversationId: String, text: String) async throws {
        try await ChatEngine.shared.sendLocation(plaintextJSON: text, conversationId: conversationId, peerUserId: "peer", displayText: "", rendersBubble: true)
    }
}
func generateMasterSecret() -> Data { Data(repeating: 1, count: 32) }
func encryptBackup(secret: Data, plaintext: Data) throws -> Data { plaintext }
func decryptBackup(secret: Data, blob: Data) throws -> Data { blob }
extension Notification.Name { static let voiidDidSignOut = Notification.Name("location-check-signout") }
