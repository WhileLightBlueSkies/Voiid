import Foundation

/// Cache day boundaries, never message values: receipts, reactions and deletion can
/// change an existing row without changing the count, id or creation date.
final class MessageDayGroups<Message: Identifiable> {
    private struct Key: Equatable {
        let id: Message.ID
        let date: Date
    }
    private let date: KeyPath<Message, Date>
    private var keys: [Key] = []
    private var calendar: Calendar?
    private var layout: [(Date, [Int])] = []

    init(date: KeyPath<Message, Date>) { self.date = date }

    func groups(_ messages: [Message], calendar: Calendar = .current) -> [(Date, [Message])] {
        let next = messages.map { Key(id: $0.id, date: $0[keyPath: date]) }
        if next != keys || self.calendar != calendar {
            keys = next
            self.calendar = calendar
            let indices = Dictionary(grouping: messages.indices) {
                calendar.startOfDay(for: messages[$0][keyPath: date])
            }
            layout = indices.keys.sorted().map { ($0, indices[$0]!) }
        }
        return layout.map { day, indices in (day, indices.map { messages[$0] }) }
    }
}
