//
//  SnakeGameView.swift
//  Voiid
//
//  SwiftUI shell over SpriteKit scene: HUD, leaderboard, boost, haptics, and pause-protected death recap.
//

import SwiftUI
import SpriteKit
import Combine
import UIKit

// MARK: - Session

final class SnakeSession: ObservableObject {
    @Published var score = 0
    @Published var length = 0
    @Published var rank = 1
    @Published var mass: CGFloat = Cfg.startMass
    @Published var alive = true
    @Published var best = 0
    @Published var kills = 0
    @Published var leaderboard: [(name: String, score: Int, isPlayer: Bool)] = []

    var botCount: Int = 11
    var boosting = false

    func reset() {
        score = 0; length = 0; rank = 1; kills = 0
        mass = Cfg.startMass
        alive = true
        boosting = false
    }
}

// MARK: - Scene holder

private final class SceneHolder: ObservableObject {
    let scene: SnakeScene

    init(session: SnakeSession) {
        let s = SnakeScene()
        s.scaleMode = .resizeFill
        s.session = session
        scene = s
    }
}

// MARK: - Screen

struct SnakeGameView: View {
    var mode: String = "arena"

    @StateObject private var session: SnakeSession
    @StateObject private var holder: SceneHolder
    @EnvironmentObject private var appSession: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var boostHeld = false
    @State private var confirmQuit = false
    @State private var isManuallyPaused = false
    @State private var showSettings = false

    /// Read once on appear and refreshed when the settings sheet closes: changing the scheme
    /// mid-match would move the controls under the player's thumb.
    @State private var scheme: SnakeChoiceStore.ControlScheme = SnakeChoiceStore.controlScheme
    @State private var knob: CGSize = .zero

    init(mode: String = "easy") {
        self.mode = mode
        let s = SnakeSession()
        if mode == "easy" || mode == "calm" || mode == "practice" {
            s.botCount = 4
        } else if mode == "hard" {
            s.botCount = 14
        } else {
            s.botCount = 8
        }
        _session = StateObject(wrappedValue: s)
        _holder = StateObject(wrappedValue: SceneHolder(session: s))
    }

    var body: some View {
        ZStack {
            SpriteView(scene: holder.scene, preferredFramesPerSecond: 60)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if isManuallyPaused && session.alive { pauseOverlay }
            if !session.alive { deathScreen }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            holder.scene.session = session
            holder.scene.acceptsDirectTouches = scheme == .swipe
            appSession.requestHideTabBar()
        }
        .onDisappear {
            holder.scene.pause()
            appSession.releaseHideTabBar()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                if session.alive {
                    holder.scene.pause()
                    isManuallyPaused = true
                }
            }
        }
        .onChange(of: confirmQuit) { _, quitting in
            if quitting {
                holder.scene.pause()
            } else if !isManuallyPaused {
                holder.scene.resume()
            }
        }
        .confirmationDialog("Leave the arena?", isPresented: $confirmQuit,
                            titleVisibility: .visible) {
            Button("Leave", role: .destructive) {
                holder.scene.pause()
                dismiss()
            }
            Button("Keep playing", role: .cancel) {
                if !isManuallyPaused { holder.scene.resume() }
            }
        } message: {
            Text("Your run ends here.")
        }
        .sheet(isPresented: $showSettings) {
            GameSettingsSheet(onClose: { showSettings = false })
        }
        // Picking a scheme in the sheet has to reach the running match, or the setting looks
        // broken: it was written to defaults and nothing on screen changed.
        .onChange(of: showSettings) { _, shown in
            guard !shown else { return }
            scheme = SnakeChoiceStore.controlScheme
            holder.scene.acceptsDirectTouches = scheme == .swipe
            knob = .zero
        }
    }

    // MARK: Top

    private var topBar: some View {
        HStack(alignment: .top) {
            Button {
                if session.alive {
                    confirmQuit = true
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.black.opacity(0.32)))
            }
            .accessibilityLabel("Leave game")

            if session.alive {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if isManuallyPaused {
                        isManuallyPaused = false
                        holder.scene.resume()
                    } else {
                        holder.scene.pause()
                        isManuallyPaused = true
                    }
                } label: {
                    Image(systemName: isManuallyPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.black.opacity(0.32)))
                }
                .accessibilityLabel(isManuallyPaused ? "Resume game" : "Pause game")

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    holder.scene.pause()
                    isManuallyPaused = true
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.black.opacity(0.32)))
                }
                .accessibilityLabel("Game settings")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("\(session.score)")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text("LENGTH \(session.length)   ·   RANK \(session.rank)\(session.kills > 0 ? "   ·   KILLS \(session.kills)" : "")")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.45))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                ForEach(Array(session.leaderboard.enumerated()), id: \.offset) { i, row in
                    HStack(spacing: 6) {
                        Text("\(i + 1)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.3))
                            .frame(width: 12, alignment: .trailing)
                        Text(row.name)
                            .font(.system(size: 12, weight: row.isPlayer ? .bold : .medium,
                                          design: .rounded))
                            .foregroundStyle(row.isPlayer ? .white : .white.opacity(0.62))
                        Text("\(row.score)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.42))
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.black.opacity(0.32))
            }
        }
    }

    // MARK: Bottom

    private var bottomBar: some View {
        HStack(alignment: .bottom) {
            if scheme == .joystick {
                joystick
            } else {
                Text("Drag anywhere to steer")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
            }

            Spacer()

            ZStack {
                Circle()
                    .fill(boostHeld
                          ? Color(red: 0.91, green: 0.65, blue: 0.18)
                          : Color.white.opacity(0.14))
                    .frame(width: 84, height: 84)
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
                    }
                Text("BOOST")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(boostHeld ? .black : .white.opacity(0.7))
            }
            .scaleEffect(boostHeld ? 0.93 : 1)
            .animation(.easeOut(duration: 0.12), value: boostHeld)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard session.alive else { return }
                        if !boostHeld {
                            boostHeld = true
                            session.boosting = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                    .onEnded { _ in
                        boostHeld = false
                        session.boosting = false
                    }
            )
            .opacity(session.mass > Cfg.minMass + 4 ? 1 : 0.35)
        }
    }

    /// A fixed ring whose knob follows the thumb. The snake steers toward the knob's offset,
    /// so the control is absolute — letting go re-centres the knob but leaves the heading,
    /// which is what keeps a snake travelling straight when the thumb lifts.
    private var joystick: some View {
        let radius: CGFloat = 42

        return ZStack {
            Circle()
                .fill(.white.opacity(0.10))
                .overlay { Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1.5) }
                .frame(width: radius * 2, height: radius * 2)

            Circle()
                .fill(.white.opacity(knob == .zero ? 0.35 : 0.85))
                .frame(width: 34, height: 34)
                .offset(knob)
        }
        .animation(.easeOut(duration: 0.12), value: knob == .zero)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard session.alive else { return }
                    // Clamped to the ring so the knob cannot be dragged off its own track.
                    let v = CGPoint(x: value.translation.width, y: value.translation.height)
                    let clamped = v.length > radius
                        ? CGPoint(x: v.x / v.length * radius, y: v.y / v.length * radius)
                        : v
                    knob = CGSize(width: clamped.x, height: clamped.y)
                    // SpriteKit's y axis points up and SwiftUI's points down.
                    holder.scene.aim(direction: CGPoint(x: clamped.x, y: -clamped.y))
                }
                .onEnded { _ in knob = .zero }
        )
        .accessibilityLabel("Steering joystick")
    }

    // MARK: Death

    private var deathScreen: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()

            VStack(spacing: 6) {
                Text("Eaten")
                    .font(.system(size: 30, weight: .heavy, design: .serif))
                    .foregroundStyle(.white)

                Text("\(session.score)")
                    .font(.system(size: 52, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color(red: 0.91, green: 0.65, blue: 0.18))

                HStack(spacing: 14) {
                    Text("BEST \(session.best)")
                    if session.kills > 0 {
                        Text("·")
                        Text("\(session.kills) KILLS")
                    }
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.bottom, 22)

                Button {
                    holder.scene.restart()
                } label: {
                    Text("PLAY AGAIN")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .tracking(1.6)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 15)
                        .background {
                            Capsule().fill(Color(red: 0.91, green: 0.65, blue: 0.18))
                        }
                }

                Button("Leave arena") { dismiss() }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 10)
            }
            .padding(34)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(red: 0.08, green: 0.11, blue: 0.15))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                    }
            }
            .padding(24)
        }
        .transition(.opacity)
    }

    // MARK: Pause

    private var pauseOverlay: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()

            VStack(spacing: 16) {
                Text("GAME PAUSED")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .tracking(2.5)
                    .foregroundStyle(Color(red: 0.91, green: 0.65, blue: 0.18))

                VStack(spacing: 8) {
                    HStack(spacing: 20) {
                        statCell(label: "SCORE", val: "\(session.score)")
                        statCell(label: "RANK", val: "\(session.rank)")
                        statCell(label: "KILLS", val: "\(session.kills)")
                    }
                }
                .padding(.vertical, 8)

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    isManuallyPaused = false
                    holder.scene.resume()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("RESUME")
                            .font(.system(size: 14, weight: .heavy, design: .rounded))
                            .tracking(1.4)
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color(red: 0.91, green: 0.65, blue: 0.18)))
                }

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    isManuallyPaused = false
                    holder.scene.restart()
                } label: {
                    Text("Restart Arena")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Capsule().fill(.white.opacity(0.1)))
                }

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    showSettings = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Game Settings")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(.white.opacity(0.08)))
                }

                Button("Quit match") {
                    confirmQuit = true
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 4)
            }
            .padding(28)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(red: 0.08, green: 0.11, blue: 0.15))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
            }
            .padding(32)
        }
        .transition(.opacity)
    }

    private func statCell(label: String, val: String) -> some View {
        VStack(spacing: 2) {
            Text(val)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(minWidth: 64)
    }
}
