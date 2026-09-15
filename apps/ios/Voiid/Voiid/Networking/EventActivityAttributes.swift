import ActivityKit

struct EventActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startsAt: Double
        var status: String
    }
    let ticketId: String
}
