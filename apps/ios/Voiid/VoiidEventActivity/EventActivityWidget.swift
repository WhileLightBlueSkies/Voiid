import ActivityKit
import WidgetKit
import SwiftUI

@main
struct VoiidEventActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: EventActivityAttributes.self) { context in
            HStack(spacing: 16) {
                Image(systemName: "ticket.fill").font(.title).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your Voiid event").font(.headline)
                    status(context)
                    Text("Open your ticket for entry").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.bold())
            }
            .padding(20)
            .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
            .widgetURL(URL(string: "https://api-dev.voiid.app/tickets/\(context.attributes.ticketId)"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "ticket.fill").foregroundStyle(.mint) }
                DynamicIslandExpandedRegion(.trailing) { Text("Voiid").font(.headline) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        status(context)
                        Text("Tap to open your ticket").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
            } compactLeading: {
                Image(systemName: "ticket.fill").foregroundStyle(.mint)
            } compactTrailing: {
                if context.isStale { Image(systemName: "arrow.clockwise") }
                else if context.state.status == "upcoming" {
                    Text(timerInterval: Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: max(0, context.state.startsAt)), countsDown: true)
                        .monospacedDigit().frame(maxWidth: 52)
                } else { Image(systemName: "checkmark") }
            } minimal: {
                Image(systemName: "ticket.fill").foregroundStyle(.mint)
            }
            .widgetURL(URL(string: "https://api-dev.voiid.app/tickets/\(context.attributes.ticketId)"))
            .keylineTint(.mint)
        }
    }
    @ViewBuilder private func status(_ context: ActivityViewContext<EventActivityAttributes>) -> some View {
        if context.isStale { Text("Open Voiid to refresh").font(.subheadline) }
        else if context.state.status == "ended" { Text("Follow ended").font(.subheadline) }
        else if context.state.status == "started" { Text("Event has started").font(.subheadline) }
        else {
            HStack(spacing: 5) {
                Text("Starts in")
                Text(timerInterval: Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: max(0, context.state.startsAt)), countsDown: true).monospacedDigit()
            }.font(.subheadline.weight(.medium))
        }
    }
}
