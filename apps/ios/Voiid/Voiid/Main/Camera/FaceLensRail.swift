//
//  FaceLensRail.swift
//  Voiid
//
//  The face-filter picker every Voiid camera shares: clips, stories, chat and the profile
//  photo. One component so a filter looks and behaves the same wherever the camera opens.
//
//  A carousel of round lenses rather than text pills: the selected lens grows, gets a
//  white ring and centres itself, and its name floats above the rail — the shape people
//  already know from every other camera app, so there is nothing to learn.
//

import SwiftUI

extension ClipFaceEffect {
    /// Two-stop gradient behind the lens glyph. Gives each filter an identity at a glance
    /// without shipping thumbnail art for every one.
    var lensColors: [Color] {
        switch self {
        case .none:       return [Color.white.opacity(0.22), Color.white.opacity(0.10)]
        case .dog:        return [Color(red: 0.84, green: 0.58, blue: 0.36), Color(red: 0.55, green: 0.33, blue: 0.18)]
        case .tiger:      return [Color(red: 1.00, green: 0.62, blue: 0.16), Color(red: 0.80, green: 0.30, blue: 0.05)]
        case .party:      return [Color(red: 1.00, green: 0.36, blue: 0.70), Color(red: 0.55, green: 0.30, blue: 1.00)]
        case .cyber:      return [Color(red: 0.10, green: 0.95, blue: 0.90), Color(red: 0.20, green: 0.35, blue: 1.00)]
        case .bunny:      return [Color(red: 1.00, green: 0.78, blue: 0.86), Color(red: 0.93, green: 0.48, blue: 0.66)]
        case .koala:      return [Color(red: 0.72, green: 0.76, blue: 0.82), Color(red: 0.42, green: 0.46, blue: 0.54)]
        case .cat:        return [Color(red: 0.98, green: 0.82, blue: 0.45), Color(red: 0.90, green: 0.52, blue: 0.22)]
        case .sunglasses: return [Color(red: 0.30, green: 0.30, blue: 0.34), Color(red: 0.08, green: 0.08, blue: 0.10)]
        case .crown:      return [Color(red: 1.00, green: 0.88, blue: 0.35), Color(red: 0.86, green: 0.60, blue: 0.08)]
        case .halo:       return [Color(red: 1.00, green: 0.97, blue: 0.80), Color(red: 0.98, green: 0.84, blue: 0.40)]
        case .devil:      return [Color(red: 1.00, green: 0.30, blue: 0.24), Color(red: 0.62, green: 0.05, blue: 0.10)]
        }
    }
}

struct FaceLensRail: View {
    @Binding var selection: ClipFaceEffect

    private let lens: CGFloat = 54

    var body: some View {
        VStack(spacing: 6) {
            // The selected name, above the rail rather than under each lens: one label reads
            // cleanly, eleven do not.
            Text(selection == .none ? "No filter" : selection.label)
                .font(VoiidFont.rounded(13, .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.35))
                .clipShape(Capsule())
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.15), value: selection)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(ClipFaceEffect.allCases) { e in
                            lensButton(e).id(e)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                }
                .onChange(of: selection) { _, e in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        proxy.scrollTo(e, anchor: .center)
                    }
                }
            }
            .frame(height: lens + 20)
        }
    }

    private func lensButton(_ e: ClipFaceEffect) -> some View {
        let on = selection == e
        return Button {
            guard selection != e else { return }
            Haptics.selection()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { selection = e }
        } label: {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: e.lensColors,
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: e == .none ? "circle.slash" : e.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            }
            .frame(width: lens, height: lens)
            .overlay(Circle().strokeBorder(Color.white.opacity(on ? 1 : 0.35),
                                           lineWidth: on ? 3 : 1))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            .scaleEffect(on ? 1.12 : 0.92)
            .contentShape(Circle())
        }
        .buttonStyle(SoftPressStyle())
        .accessibilityLabel(e == .none ? "No filter" : "\(e.label) filter")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}
