import ActivityKit
import Combine
import SwiftUI

@MainActor
final class EventActivityController: ObservableObject {
    static let shared = EventActivityController()
    @Published private(set) var following: Set<String> = []
    @Published private(set) var busy = false
    @Published var error: String?
    private var observers: [String: Task<Void, Never>] = [:]
    private var registered: Set<String> = []
    private var stateObservers: [String: Task<Void, Never>] = [:]

    func restore() {
        for activity in Activity<EventActivityAttributes>.activities {
            following.insert(activity.attributes.ticketId)
            observe(activity)
        }
    }
    func start(ticketId: String) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            error = "Enable Live Activities for Voiid in Settings."; return
        }
        guard !Activity<EventActivityAttributes>.activities.contains(where: { $0.attributes.ticketId == ticketId }) else { return }
        do {
            struct Response: Decodable { let ticket: EventService.Ticket }
            let result = try await APIClient().request("GET", "event-tickets/\(ticketId)", as: Response.self)
            let ticket = result.ticket
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let raw = ticket.starts_at ?? ""
            let start = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
            guard ticket.canShowCode, let start, start.timeIntervalSinceNow <= 8 * 3600,
                  start.timeIntervalSinceNow > -3600 else {
                error = "Follow is available from eight hours before your event until one hour after it starts."; return
            }
            let activity = try Activity.request(attributes: EventActivityAttributes(ticketId: ticketId),
                content: ActivityContent(state: EventActivityAttributes.ContentState(startsAt: start.timeIntervalSince1970,
                    status: start > Date() ? "upcoming" : "started"), staleDate: Date().addingTimeInterval(60)), pushType: .token)
            following.insert(ticketId)
            observe(activity)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, !self.registered.contains(activity.id), self.following.contains(ticketId) else { return }
                self.error = "Couldn’t connect event updates. Please try again."
                await self.stop(ticketId: ticketId)
            }
        } catch { self.error = "Unable to follow this event. Please try again." }
    }
    private func observe(_ activity: Activity<EventActivityAttributes>) {
        guard observers[activity.id] == nil else { return }
        stateObservers[activity.id] = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                if state == .ended || state == .dismissed {
                    self?.following.remove(activity.attributes.ticketId)
                    self?.observers.removeValue(forKey: activity.id)?.cancel()
                    self?.registered.remove(activity.id)
                    self?.stateObservers.removeValue(forKey: activity.id)
                    return
                }
            }
        }
        observers[activity.id] = Task { [weak self] in
            if let token = activity.pushToken {
                guard let self, await self.register(token, for: activity) else { return }
            }
            for await token in activity.pushTokenUpdates {
                guard !Task.isCancelled, let self, await self.register(token, for: activity) else { return }
            }
        }
    }
    private func register(_ token: Data, for activity: Activity<EventActivityAttributes>) async -> Bool {
        struct Body: Encodable { let token: String; let sandbox: Bool }
        struct Response: Decodable { let ok: Bool }
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
        do {
            let _: Response = try await APIClient().request("POST", "event-tickets/\(activity.attributes.ticketId)/live-activity",
                body: Body(token: token.map { String(format: "%02x", $0) }.joined(), sandbox: sandbox))
            registered.insert(activity.id)
            return true
        } catch {
            self.error = "Event updates are unavailable. Please try again."
            await stop(ticketId: activity.attributes.ticketId)
            return false
        }
    }
    func stop(ticketId: String) async {
        following.remove(ticketId)
        for activity in Activity<EventActivityAttributes>.activities where activity.attributes.ticketId == ticketId {
            observers.removeValue(forKey: activity.id)?.cancel()
            registered.remove(activity.id)
            stateObservers.removeValue(forKey: activity.id)?.cancel()
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        struct Response: Decodable { let ok: Bool }
        let _: Response? = try? await APIClient().request("DELETE", "event-tickets/\(ticketId)/live-activity")
    }
    func stopAll() async {
        for id in Set(Activity<EventActivityAttributes>.activities.map { $0.attributes.ticketId }) {
            await stop(ticketId: id)
        }
        following = []
    }
}
