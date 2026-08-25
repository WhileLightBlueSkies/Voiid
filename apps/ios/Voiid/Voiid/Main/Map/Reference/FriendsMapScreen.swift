//
//  FriendsMapScreen.swift
//  Voiid
//
//  Voiid Friends Map, step 3 — the map itself.
//
//  ── A REAL MAP, NOT A DRAWING ───────────────────────────────────────────────────
//  Every other placeholder in this app is a gradient, and that is right for a photo we do not
//  have. A map is different: MapKit IS the component, it is free, and a hand-drawn substitute
//  would have to fake pan, zoom, labels and tiles — all of which the real one does properly.
//  The friends on it are REAL — see ReferenceMapModels.swift, where MapStore is now a live
//  adapter over MapPresenceEngine rather than the reference's four sample people.
//
//  ── THE PRIVACY STATE IS ON SCREEN, ALWAYS ──────────────────────────────────────
//  The header carries who can currently see you. On a map, "am I visible right now?" is the
//  question a user asks most often and the one they should never have to open a menu to
//  answer.
//

import SwiftUI
import MapKit

struct FriendsMapScreen: View {

    // ── THE ONLY ADAPTATIONS IN THIS FILE ───────────────────────────────────────────
    // The reference injects both of these from the environment via the @Observable macro.
    // In Voiid:
    //   * MapStore exists ONLY here (ReferenceMapModels.swift) and has no injector, so the
    //     screen owns it. @State, not @Environment — same object, now fed by the real
    //     engines instead of literals (`store.start()` in onAppear below).
    //   * AppSession is an ObservableObject, so it needs @EnvironmentObject rather than
    //     @Environment(_:). RootTabView already provides it.
    // Everything below this line is the reference's layout unchanged. The only further
    // departures are DATA departures, each commented at its site: absolute coordinates
    // instead of offsets from a hardcoded centre, the "you" pin drawn only when we hold a
    // real fix of our own, and the battery / favourite / distance chips omitted rather than
    // fabricated when Voiid's wire carries no such value.
    @State private var store = MapStore()
    @EnvironmentObject private var session: AppSession

    var onOpenMove: (MapFriend) -> Void = { _ in }
    var onMessage: (MapFriend) -> Void = { _ in }
    /// Whether a direct conversation with this person ALREADY exists. The Map may open one,
    /// never mint one — a tap on a pin is not the place to start a first contact. The shell
    /// (MapTabView) answers this from ChatStore; nil-safe default = no conversations known.
    var hasConversation: (MapFriend) -> Bool = { _ in false }
    /// Tapping the header's visibility line. The shell answers it: visible → offer a ghost
    /// duration, ghosted → leave ghost outright. Kept as a closure so this screen never calls
    /// the engine and Ghost Mode's one rule stays in one place.
    var onToggleVisibility: () -> Void = {}
    /// Tapping your own avatar, top-left. The shell owns where that goes.
    var onOpenProfile: () -> Void = {}

    /// Tapping the header's bell. The shell decides what that means; nothing is drawn
    /// differently either way.
    var onOpenNotifications: () -> Void = {}
    /// The search row's trailing control. It opens Map settings — see the comment at its
    /// call site for why that, and not a filter panel.
    var onOpenSettings: () -> Void = {}

    /// The chosen base style, shared with Map settings through `@AppStorage` rather than
    /// through the shell: two entry points, one key, so they can never disagree and the
    /// choice survives a relaunch. Stored as the enum's raw value because `MapStyle` itself
    /// is opaque and not storable — see `VoiidMapStyle`.
    @AppStorage(VoiidMapStyle.storageKey) private var styleRaw = VoiidMapStyle.standard.rawValue
    /// The layers control's picker.
    @State private var showStylePicker = false

    private var mapStyle: VoiidMapStyle { VoiidMapStyle(rawValue: styleRaw) ?? .standard }

    /// WAS a hardcoded Toronto constant so the sample friends landed where they were placed.
    /// Now `store.centre` — my real fix, else the centroid of whoever is actually on the map,
    /// else a neutral fallback. See MapStore.centre for that ladder and why.
    private var centre: CLLocationCoordinate2D { store.centre }

    /// `.automatic` rather than a fixed region, because at first render there may be no fix
    /// and no friends yet; the camera is pointed at `centre` in onAppear once there is
    /// something true to point it at.
    @State private var camera: MapCameraPosition = .automatic
    @State private var query = ""

    var body: some View {
        @Bindable var store = store

        return ZStack(alignment: .top) {
            map

            VStack(spacing: VoiidSpacing.sm) {
                header
                searchRow
                filters
            }
            .padding(.top, VoiidSpacing.sm)

            if let friend = store.selected {
                friendCard(friend)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Nothing on the map, and a reason for it. Drawn OVER the map rather than in
            // place of it — the map is still pannable, and a full-bleed takeover would hide a
            // surface the user may have opened just to look around.
            if let line = statusLine {
                Text(line)
                    .font(VoiidFont.rounded(13))
                    .foregroundColor(VoiidColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, VoiidSpacing.md)
                    .frame(height: 34)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(VoiidColor.divider, lineWidth: 1))
                    .frame(maxHeight: .infinity, alignment: .center)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // WHY a second, separate line: the capsule above is about OTHER PEOPLE'S pins and
            // is suppressed as soon as any friend is drawn. Missing location permission is
            // about YOUR pin, and it is true whether or not friends are on the map — so it
            // gets its own line rather than competing for that one. Without it, a user who
            // never granted (or later revoked) location sees a map with no "You" on it and no
            // stated reason, which is the same silent failure this fix exists to remove.
            //
            // Tappable, unlike the capsule above, because this one has a remedy.
            if let permission = permissionNotice {
                Button {
                    Haptics.tap()
                    permission.act()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "location.slash.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text(permission.line)
                            .font(VoiidFont.rounded(13))
                    }
                    .foregroundColor(VoiidColor.textPrimary)
                    .padding(.horizontal, VoiidSpacing.md)
                    .frame(height: 34)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(VoiidColor.divider, lineWidth: 1))
                }
                .buttonStyle(PressableButtonStyle())
                .frame(maxHeight: .infinity, alignment: .bottom)
                // Clears the tab bar, and the friend card when one is open — the same
                // arithmetic the map controls use, so the two never overlap.
                .padding(.bottom, max(session.bottomInset, 96) + (store.selected == nil ? 8 : 148))
                .transition(.opacity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        // A confirmationDialog rather than a sheet: it is what Ghost Mode's duration picker
        // already uses (MapTabView), so it IS this app's idiom for "pick one of three", it
        // needs no chrome of its own to stay on-brand, and it does not cover the map the user
        // is choosing a style for.
        .confirmationDialog("Map style", isPresented: $showStylePicker,
                            titleVisibility: .visible) {
            ForEach(VoiidMapStyle.allCases) { option in
                // The current one is marked, because a dialog with no state shown makes the
                // user tap one just to find out which they were on.
                Button(option == mapStyle ? "\(option.title) ✓" : option.title) {
                    Haptics.selection()
                    styleRaw = option.rawValue
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            store.start()
            recentre(span: 0.028)
        }
    }

    // MARK: The map

    private var map: some View {
        Map(position: $camera) {
            // The user, drawn as a Voiid pin rather than the system blue dot, so the map reads
            // as this app's rather than as a generic MapKit view.
            //
            // WAS `if let mine = store.myCoordinate { Annotation("You", …) }`. That read the
            // SHARING provider's last fix — and Ghost Mode stops that provider by design, so
            // the pin disappeared and "Centre on me" had nothing to centre on. Ghost Mode is
            // meant to hide you from other people; it was hiding you from yourself.
            //
            // `UserAnnotation` takes its position from MAPKIT'S OWN CoreLocation session,
            // which is entirely separate from `MapLocationProvider`: it reads the same iOS
            // permission but runs its own manager, delivers into the map view, and never
            // touches `provider.onFix` — the only path to `emitFix` and the socket. So the
            // hard gate is untouched: while ghosted the provider is still stopped, still
            // holds no background privileges, and still emits nothing. Only this device's
            // screen learns where it is. This is what the old `MapCanvas` did.
            //
            // No fallback coordinate is ever invented: when MapKit holds no position it
            // simply draws nothing, and `permissionLine` below says why.
            UserAnnotation(anchor: .center) { _ in
                youPin
            }

            // `visibleFriends`, not `friends`: a non-Friends chip draws no pins at all rather
            // than quietly showing the friends list under someone else's label.
            ForEach(store.visibleFriends) { friend in
                Annotation(friend.name, coordinate: coordinate(for: friend)) {
                    FriendPin(friend: friend,
                              isSelected: store.selected?.id == friend.id) {
                        Haptics.tap()
                        withAnimation(.easeOut(duration: 0.22)) {
                            store.selected = store.selected?.id == friend.id ? nil : friend
                        }
                    }
                }
            }
        }
        // WAS the `.standard(pointsOfInterest: .excludingAll)` literal. The exclusion is
        // unchanged — it now lives on `VoiidMapStyle.standard` so the picker and the settings
        // screen apply the same one rather than each spelling it out.
        .mapStyle(mapStyle.mapStyle)
        .mapControlVisibility(.hidden)
        .ignoresSafeArea()
        .overlay(alignment: .bottomTrailing) { mapControls }
    }

    /// The reference added hand-placed offsets to a hardcoded centre. Real presences carry a
    /// real (already coarsened) coordinate, so this is now a pass-through — kept as a function
    /// so the call site above is untouched.
    private func coordinate(for friend: MapFriend) -> CLLocationCoordinate2D {
        friend.coordinate
    }

    /// The "You" marker, in its two states.
    ///
    /// The user must be able to tell AT A GLANCE whether they are hidden, without reading
    /// the header — so the difference is colour AND shape, not a caption: visible is the
    /// live accent pin with a soft halo; ghosted is drained to a muted grey with an
    /// eye-slash badge, and the halo (which reads as "broadcasting") is dropped entirely.
    /// `VoiidColor`, not `VoiidBrand`, so the pin follows the theme like the rest of the map.
    @ViewBuilder
    private var youPin: some View {
        let ghosted = !store.isVisible

        ZStack {
            // The halo is the "you are being seen" signal. Absent while ghosted, on purpose.
            if !ghosted {
                Circle()
                    .fill(VoiidColor.accent.opacity(0.22))
                    .frame(width: 46, height: 46)
            }

            Circle()
                .fill(ghosted ? VoiidColor.textSecondary : VoiidColor.accent)
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(.white, lineWidth: 2.5))

            if ghosted {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .accessibilityLabel(ghosted ? "You, hidden in Ghost Mode" : "You, visible on the map")
    }

    /// Point the camera at the user, falling back to whatever `centre` resolves to.
    /// Shared by onAppear and the "Centre on me" control so the two can never disagree
    /// about where "me" is.
    ///
    /// `.userLocation` uses MapKit's own position — the SAME source as the pin above — so
    /// centring works identically whether visible or ghosted. It used to read `centre`,
    /// which is derived from the sharing provider, so while ghosted it silently centred on
    /// the friends' centroid or on Toronto: the control appeared to work and pointed
    /// somewhere the user has never been.
    ///
    /// The fallback is only reached when MapKit genuinely has no position (no permission, or
    /// no fix yet), and it is the same honest ladder as before — never a fabricated "you".
    private func recentre(span: Double) {
        camera = .userLocation(fallback: .region(MKCoordinateRegion(
            center: centre,
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))))
    }

    /// The one line shown when the map has no pins to draw, or nil when it has.
    ///
    /// Four outcomes, deliberately four different sentences. "Nobody is sharing with you" and
    /// "we couldn't load" look identical on a blank map and mean opposite things, so they are
    /// never allowed to share wording.
    private var statusLine: String? {
        if let unavailable = store.filter.unavailableMessage { return unavailable }
        guard store.visibleFriends.isEmpty else { return nil }
        switch store.feedState {
        case .loaded:          return nil
        case .loading:         return "Waiting for their first update…"
        case .empty:           return "No one is sharing their location with you yet."
        case .failed(let why): return "Couldn't load the map. \(why)"
        }
    }

    /// The honest reason there is no "You" on the map, and the one thing that fixes it.
    ///
    /// Reuses `MapLocationProvider`'s published `authorization` (through the store) and the
    /// SAME two remedies `MapPrivacyScreen` already chose for the same two cases, rather than
    /// inventing a third vocabulary for it:
    ///   .notDetermined — iOS will still show the prompt, so ask (`requestWhenInUse`).
    ///   denied/restricted — iOS will never ask again; Settings is the only route left.
    /// Authorised is nil: MapKit will draw the pin, so there is nothing to say.
    private var permissionNotice: (line: String, act: () -> Void)? {
        switch store.locationAuthorization {
        case .notDetermined:
            return ("Turn on location to see yourself on the map",
                    { MapLocationProvider.shared.requestWhenInUse() })
        case .denied, .restricted:
            return ("Location is off, so we can't show where you are. Open Settings",
                    {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    })
        default:
            return nil
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: VoiidSpacing.sm) {
            // YOUR REAL FACE, AND A REAL DESTINATION.
            //
            // The reference drew `ProfilePhoto(name: "You")` — a deterministic initials circle
            // from the literal string "You", which rendered the same two letters for every
            // person who ever ran it, and did nothing when tapped.
            //
            // `ProfileAvatarButton` is the app's own avatar: it resolves `photoURL` (an R2
            // object key needing a presigned GET, which it handles) and falls back to the
            // initials of your actual name. It is the same component the Chats header and
            // Settings use, so your face is identical everywhere it appears.
            Button {
                Haptics.tap()
                onOpenProfile()
            } label: {
                ProfileAvatarButton(photoURL: session.profile.photoURL,
                                    name: session.profile.fullName,
                                    size: 38)
                    .overlay(Circle().stroke(VoiidColor.background, lineWidth: 2))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Your profile and settings")

            Spacer(minLength: 0)

            // Wrapped in a plain Button so the always-visible answer to "can anyone see me?"
            // is also the way to CHANGE it — one tap from the question to the control. A
            // `.plain` button draws nothing of its own, so the layout below is the
            // reference's, unchanged.
            Button {
                Haptics.tap()
                onToggleVisibility()
            } label: {
                VStack(spacing: 1) {
                    Text("Map")
                        .font(VoiidFont.rounded(17, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)

                    // The always-visible answer to "can anyone see me?".
                    HStack(spacing: 4) {
                        Image(systemName: store.isVisible ? "dot.radiowaves.left.and.right"
                                                          : "eye.slash.fill")
                            .font(.system(size: 9))
                        Text(store.statusText)
                            .font(VoiidFont.rounded(11))
                    }
                    .foregroundColor(store.isVisible ? VoiidColor.accentInk
                                                     : VoiidColor.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.isVisible ? "\(store.statusText). Enter Ghost Mode"
                                                : "Ghost Mode, hidden. Choose who can see you")

            Spacer(minLength: 0)

            Button {
                Haptics.tap()
                onOpenNotifications()
            } label: {
                Image(systemName: "bell")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(VoiidColor.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(VoiidColor.surfaceCard))
                    .overlay(Circle().stroke(VoiidColor.divider, lineWidth: 1))
                    // THE "3" BADGE IS GONE, BY DECISION. It was a literal in the design
                    // reference and counted nothing — there is no map notification feed in
                    // this app (see MapNotificationsView for what actually exists), so the
                    // only honest badge is no badge. Do not re-add it from the reference; if
                    // a real unread count ever exists, source it before drawing it.
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Map activity")
        }
        .padding(.horizontal, VoiidSpacing.md)
    }

    private var searchRow: some View {
        HStack(spacing: VoiidSpacing.sm) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(VoiidColor.textSecondary)

                TextField("Search places or friends", text: $query)
                    .font(VoiidFont.rounded(14.5))
                    .foregroundColor(VoiidColor.textPrimary)
                    .tint(VoiidColor.accent)
            }
            .padding(.horizontal, VoiidSpacing.md)
            .frame(height: 42)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(VoiidColor.divider, lineWidth: 1))

            // ── WHAT THIS BUTTON IS FOR ─────────────────────────────────────────────────
            // It was an empty closure. It is now the door to Map settings, and the three
            // alternatives were rejected for concrete reasons:
            //
            //  * "Toggle the chip row" — the chip row is signed-off layout that is always
            //    visible, and a control whose only effect is hiding four chips the user can
            //    already ignore is not worth a 42pt target beside the search field.
            //  * "A filter panel" — there is nothing to filter. Only the Friends chip has a
            //    backend; a panel over one source is a panel over nothing.
            //  * "Remove it" — that IS a layout change to a signed-off screen, and the
            //    Map otherwise has no entry point to its own settings at all.
            //
            // The glyph reads as "adjust this surface", which is exactly what it now does.
            Button {
                Haptics.tap()
                onOpenSettings()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(VoiidColor.textPrimary)
                    .frame(width: 42, height: 42)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().stroke(VoiidColor.divider, lineWidth: 1))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Map settings")
        }
        .padding(.horizontal, VoiidSpacing.md)
    }

    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(MapFilter.allCases) { option in
                    let selected = store.filter == option

                    Button {
                        Haptics.selection()
                        withAnimation(.easeOut(duration: 0.18)) { store.filter = option }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: option.icon)
                                .font(.system(size: 12, weight: .semibold))
                            Text(option.rawValue)
                                .font(VoiidFont.rounded(13, .semibold))
                        }
                        .foregroundColor(selected ? VoiidColor.textOnAccent
                                                  : VoiidColor.textPrimary)
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .background(
                            Group {
                                if selected {
                                    Capsule().fill(VoiidColor.accent)
                                } else {
                                    Capsule().fill(.regularMaterial)
                                }
                            }
                        )
                        .overlay(Capsule().stroke(selected ? .clear : VoiidColor.divider,
                                                  lineWidth: 1))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
        }
        .scrollIndicators(.hidden)
    }

    private var mapControls: some View {
        VStack(spacing: 10) {
            controlButton("location.fill", "Centre on me") {
                withAnimation(.easeOut(duration: 0.4)) { recentre(span: 0.02) }
            }
            controlButton("square.3.layers.3d", "Map layers") { showStylePicker = true }
        }
        .padding(.trailing, VoiidSpacing.md)
        // Clears the tab bar AND the friend card when one is open.
        .padding(.bottom, max(session.bottomInset, 96) + (store.selected == nil ? 8 : 148))
        .animation(.easeOut(duration: 0.22), value: store.selected)
    }

    private func controlButton(_ icon: String, _ label: String,
                               action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(VoiidColor.textPrimary)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(VoiidColor.divider, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    // MARK: The friend card

    private func friendCard(_ friend: MapFriend) -> some View {
        VStack(spacing: VoiidSpacing.md) {
            HStack(spacing: VoiidSpacing.sm + 2) {
                ProfilePhoto(name: friend.name, size: 48, allowFallbackPhoto: true)
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(VoiidColor.success)
                            .frame(width: 13, height: 13)
                            .overlay(Circle().stroke(VoiidColor.surfaceCard, lineWidth: 2.5))
                    }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(friend.name)
                            .font(VoiidFont.rounded(16, .semibold))
                            .foregroundColor(VoiidColor.textPrimary)

                        if friend.isFavourite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 11))
                                .foregroundColor(VoiidColor.accentInk)
                        }
                    }

                    // BATTERY WAS HERE AND IS GONE BY DECISION. Voiid's wire
                    // (MapEnvelope) carries lat/lon/accuracy/seq — no battery level, from
                    // anyone, ever. The reference's chip could only ever have shown a made-up
                    // number, so the chip AND its separator dot were removed rather than left
                    // dangling. Do not re-add it from the reference.
                    //
                    // Distance is optional for a different reason: it needs a fix of MY OWN
                    // to measure from, and Ghost Mode stops my provider. When there is none,
                    // the dot goes with it so the line never ends in a stray "·".
                    HStack(spacing: 6) {
                        Text("Seen \(friend.lastSeen)")
                        if let distance = friend.distanceText {
                            Text("·")
                            Text(distance)
                        }
                    }
                    .font(VoiidFont.rounded(11.5))
                    .foregroundColor(VoiidColor.textSecondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 0)

                Button {
                    Haptics.tap()
                    withAnimation(.easeOut(duration: 0.2)) { store.selected = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(VoiidColor.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Close")
            }

            // THE ACTION ROW — same three buttons, same order, same skins.
            //
            //  Message: enabled ONLY when a 1:1 with this person already exists. A tap on a
            //           pin may open a conversation; it must never mint one.
            //  Call:    Voiid's call stack needs a conversation context this card does not
            //           carry, so Call is routed to the SAME conversation-gated path as
            //           Message — it opens the chat, from which a call can be placed — and is
            //           disabled under exactly the same condition. It never dials from here,
            //           because there is nothing truthful to dial.
            //  Move:    the primary action, and the one this whole flow builds toward.
            HStack(spacing: 8) {
                let canOpenChat = hasConversation(friend)
                cardAction("message", "Message", filled: false) { onMessage(friend) }
                    .disabled(!canOpenChat)
                cardAction("phone", "Call", filled: false) { onMessage(friend) }
                    .disabled(!canOpenChat)
                cardAction("location.north.fill", "Move", filled: true) {
                    store.startMove(with: friend)
                    onOpenMove(friend)
                }
            }
        }
        .padding(VoiidSpacing.md)
        .background(.regularMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 0,
                                          bottomTrailingRadius: 0, topTrailingRadius: 22,
                                          style: .continuous))
        .overlay(alignment: .top) {
            Capsule()
                .fill(VoiidColor.textSecondary.opacity(0.4))
                .frame(width: 36, height: 4)
                .padding(.top, 7)
        }
        .padding(.bottom, max(session.bottomInset, 96) - 34)
    }

    private func cardAction(_ icon: String, _ title: String, filled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(VoiidFont.rounded(14, .semibold))
            }
            .foregroundColor(filled ? VoiidColor.textOnAccent : VoiidColor.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .fill(filled ? VoiidColor.accent : VoiidColor.surfaceCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .stroke(filled ? .clear : VoiidColor.divider, lineWidth: 1)
            )
        }
        .buttonStyle(PressableButtonStyle())
    }
}

// MARK: - A pin

/// A friend's face as the pin. The photo IS the identifier — a generic marker would make the
/// map a puzzle to be decoded rather than read.
private struct FriendPin: View {
    let friend: MapFriend
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ProfilePhoto(name: friend.name, size: isSelected ? 52 : 44,
                         allowFallbackPhoto: true)
                .overlay(
                    Circle().stroke(isSelected ? VoiidColor.accent : .white,
                                    lineWidth: isSelected ? 3 : 2.5)
                )
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(VoiidColor.success)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.3, bounce: 0.2), value: isSelected)
        .accessibilityLabel(friend.distanceText.map { "\(friend.name), \($0)" } ?? friend.name)
    }
}
