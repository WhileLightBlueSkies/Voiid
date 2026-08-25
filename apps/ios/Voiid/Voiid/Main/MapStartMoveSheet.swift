//
//  MapStartMoveSheet.swift
//  Voiid
//
//  Feature (B), Move — the TRAVELLER's side. Pick where you're going; from then on the coarse
//  fixes you were already sending carry that destination and a measured arrival time.
//
//  ── THIS SHEET GRANTS NO NEW ACCESS ───────────────────────────────────────────────────
//  A Move is an annotation on an EXISTING share, so it reaches exactly the people who could
//  already see you on the Map, and nobody else. It cannot widen your audience and it does not
//  turn sharing on: while ghosted, no fix is taken at all, so a Move started in that state
//  would share nothing. Rather than quietly flipping visibility on the user's behalf, the
//  sheet says so and hands them the Map's own control. Consent to be seen is a separate
//  decision from choosing a destination, and collapsing the two is how a location feature
//  starts broadcasting without anyone deciding it should.
//
//  Place search is `MapSearchModel` verbatim — the same MKLocalSearchCompleter the Map tab
//  uses. No key, no billing, no proxy, and nothing about the query leaves the device except
//  to Apple's own search service.
//

import SwiftUI
import MapKit

struct MapStartMoveSheet: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var moves = MapMoveEngine.shared
    @ObservedObject private var engine = MapPresenceEngine.shared
    @ObservedObject private var visibility = MapVisibilityState.shared

    @StateObject private var search = MapSearchModel()
    @State private var query = ""
    @FocusState private var focused: Bool

    /// Where the Map camera is, so autocomplete is biased to what the traveller is looking at.
    var region: MKCoordinateRegion?

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidColor.background.ignoresSafeArea()

                VStack(spacing: VoiidSpacing.md) {
                    if let active = moves.outbound {
                        activeMove(active)
                    } else {
                        picker
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.top, VoiidSpacing.md)
            }
            .navigationTitle(moves.outbound == nil ? "Where are you going?" : "On your way")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(VoiidColor.primary)
                }
            }
        }
        .tint(VoiidColor.primary)
        .onAppear { if let region { search.setRegion(region) } }
    }

    // MARK: Choosing a destination

    private var picker: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            audienceNote

            HStack(spacing: VoiidSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(VoiidColor.textSecondary)
                TextField("Search for a destination", text: $query)
                    .font(VoiidFont.rounded(15))
                    .foregroundColor(VoiidColor.textPrimary)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .onChange(of: query) { _, new in search.update(query: new) }
                if !query.isEmpty {
                    Button {
                        query = ""
                        search.reset()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(VoiidColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, 10)
            .background(Capsule().fill(VoiidColor.surfaceCard))
            .overlay(Capsule().stroke(VoiidColor.fieldBorder, lineWidth: 1))

            if search.resolving {
                HStack(spacing: VoiidSpacing.sm) {
                    ProgressView()
                    Text("Finding that place…")
                        .font(VoiidFont.rounded(13))
                        .foregroundColor(VoiidColor.textSecondary)
                }
            }

            // A resolved place, ready to commit to.
            if let place = search.selected {
                chosen(place)
            } else {
                suggestions
            }
        }
    }

    private var suggestions: some View {
        VStack(spacing: 0) {
            ForEach(search.suggestions.prefix(8), id: \.self) { s in
                Button {
                    Haptics.tap()
                    focused = false
                    query = s.title
                    search.choose(s)
                } label: {
                    HStack(spacing: VoiidSpacing.sm) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(VoiidColor.primary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title)
                                .font(VoiidFont.rounded(14, .medium))
                                .foregroundColor(VoiidColor.textPrimary)
                                .lineLimit(1)
                            if !s.subtitle.isEmpty {
                                Text(s.subtitle)
                                    .font(VoiidFont.rounded(11))
                                    .foregroundColor(VoiidColor.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().overlay(VoiidColor.divider)
            }
        }
    }

    private func chosen(_ place: MapSearchModel.SelectedPlace) -> some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            HStack(spacing: VoiidSpacing.sm + 2) {
                Image(systemName: "flag.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(VoiidColor.accentInk)
                VStack(alignment: .leading, spacing: 1) {
                    Text(place.name)
                        .font(VoiidFont.rounded(15.5, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                    if let address = place.address {
                        Text(address)
                            .font(VoiidFont.rounded(12))
                            .foregroundColor(VoiidColor.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(VoiidSpacing.md - 2)
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1))

            Button {
                Haptics.tap()
                moves.startMove(to: place.coordinate, name: place.name, address: place.address)
                dismiss()
            } label: {
                Text("Start Move")
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundColor(VoiidColor.textOnPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(VoiidColor.primary))
            }
            .buttonStyle(.plain)

            Text("Your destination and arrival time are encrypted with your location and can only be read by the people on your Map list.")
                .font(VoiidFont.rounded(11.5))
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// States plainly who will see this — and, when ghosted, that nobody will. This is the one
    /// place a user could reasonably assume a Move creates its own audience; it doesn't.
    private var audienceNote: some View {
        HStack(alignment: .top, spacing: VoiidSpacing.sm) {
            Image(systemName: visibility.isVisible ? "eye.fill" : "eye.slash.fill")
                .font(.system(size: 13))
                .foregroundColor(visibility.isVisible ? VoiidColor.accentInk : VoiidColor.textSecondary)
            Text(visibility.isVisible
                 ? "Visible to \(engine.audience.count) \(engine.audience.count == 1 ? "person" : "people") on your Map list. A Move is shared with exactly them — it can’t add anyone."
                 : "Ghost Mode is on, so nobody can see you and no location is taken. Turn it off on the Map first, or this Move will be shared with no one.")
                .font(VoiidFont.rounded(12))
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(VoiidSpacing.sm + 2)
        .background(VoiidColor.fieldFill)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
    }

    // MARK: An active Move

    private func activeMove(_ move: MapMoveOutbound) -> some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            HStack(spacing: VoiidSpacing.sm + 2) {
                Image(systemName: "flag.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(VoiidColor.accentInk)
                VStack(alignment: .leading, spacing: 1) {
                    Text(move.name)
                        .font(VoiidFont.rounded(15.5, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                    if let address = move.address {
                        Text(address)
                            .font(VoiidFont.rounded(12))
                            .foregroundColor(VoiidColor.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(VoiidSpacing.md - 2)
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1))

            // THE THREE ETA STATES, kept visually distinct on the sender's side too, because
            // the sender needs to know what their friends are being shown.
            etaRow(move)

            Button {
                Haptics.tap()
                moves.endMove()
                dismiss()
            } label: {
                Text("End Move")
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundColor(VoiidColor.error)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(VoiidColor.fieldFill))
            }
            .buttonStyle(.plain)

            Text("Ending a Move stops sharing your destination and ETA. Your Map visibility is unchanged.")
                .font(VoiidFont.rounded(11.5))
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func etaRow(_ move: MapMoveOutbound) -> some View {
        HStack(spacing: VoiidSpacing.sm) {
            if let arrival = move.arrivalAt {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Arriving at \(arrival.formatted(date: .omitted, time: .shortened))")
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                    if let metres = move.remainingMetres {
                        Text("\(MapMoveScreen.distanceText(metres)) of route left")
                            .font(VoiidFont.rounded(12))
                            .foregroundColor(VoiidColor.textSecondary)
                    }
                }
            } else if let error = moves.routingError {
                // FAILED, and said so. The Move continues — the destination is still shared and
                // the pin still moves — but we never substitute a guessed ETA for a measured one.
                VStack(alignment: .leading, spacing: 2) {
                    Text("No ETA available")
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(VoiidColor.error)
                    Text(error)
                        .font(VoiidFont.rounded(12))
                        .foregroundColor(VoiidColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ProgressView()
                Text("Working out your route…")
                    .font(VoiidFont.rounded(13))
                    .foregroundColor(VoiidColor.textSecondary)
            }
            Spacer(minLength: 0)

            Button {
                Haptics.tap()
                moves.recomputeETA()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(VoiidColor.accentInk)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(VoiidColor.fieldFill))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Recalculate ETA")
        }
        .padding(VoiidSpacing.md - 2)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
    }
}
