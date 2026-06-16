//
//  Components.swift
//  Voiid
//
//  Reusable UI components built from design tokens (Section 6.5).
//

import SwiftUI

// MARK: - Dismiss keyboard on tap outside any text field

extension View {
    /// Taps outside a text field resign first responder (close the keyboard).
    func dismissKeyboardOnTap() -> some View {
        self.contentShape(Rectangle())
            .onTapGesture {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
    }
}

// MARK: - Zoomable profile photo viewer (tap avatar -> fullscreen, pinch to zoom)

struct ProfilePhotoViewer: View {
    let title: String
    var imageName: String? = nil
    let onClose: () -> Void
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                if let imageName, let ui = UIImage(named: imageName) {
                    Image(uiImage: ui).resizable().scaledToFit()
                } else {
                    // placeholder avatar (no photo set)
                    ZStack {
                        Circle().fill(VoiidColor.fieldFill)
                        Image("VoiidWordmark").resizable().scaledToFit().frame(width: 120).opacity(0.3)
                    }
                    .frame(width: 280, height: 280)
                }
            }
            .scaleEffect(scale)
            .gesture(
                MagnificationGesture()
                    .onChanged { v in scale = max(1, lastScale * v) }
                    .onEnded { _ in lastScale = scale
                        if scale < 1.05 { withAnimation(.spring()) { scale = 1; lastScale = 1 } } }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring()) { scale = scale > 1 ? 1 : 2.5; lastScale = scale }
            }

            VStack {
                HStack {
                    Text(title).font(VoiidFont.rounded(17, .semibold)).foregroundColor(.white)
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark").font(.title3).foregroundColor(.white).padding(8)
                    }
                }
                .padding()
                Spacer()
            }
        }
    }
}

// MARK: - Bouncy emoji button (reaction pill)

struct BouncyEmojiStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.4 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: configuration.isPressed)
    }
}

// MARK: - Soft press style (Apple-grade tactile feedback: scale + dim + haptic on press)

struct SoftPressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.soft() }
            }
    }
}

// MARK: - Primary button (the dark plum pill seen on every onboarding screen)

struct VoiidPrimaryButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(VoiidFont.headline)
                .foregroundColor(VoiidColor.textOnPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .background(VoiidColor.primary)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
                .opacity(enabled ? 1 : 0.5)
        }
        .disabled(!enabled)
    }
}

// MARK: - Text field (fill #FCF4F8, border #E3BED8, focus = primary)

struct VoiidTextField: View {
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt:
            Text(placeholder).foregroundColor(VoiidColor.placeholder))
            .font(VoiidFont.body)
            .foregroundColor(VoiidColor.textPrimary)   // adaptive: plum (light) / #FCF4F8 (dark)
            .keyboardType(keyboard)
            .focused($focused)
            .padding(.horizontal, VoiidSpacing.md)
            .frame(height: 61)
            .background(VoiidColor.fieldFill)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .stroke(focused ? VoiidColor.primary : VoiidColor.fieldBorder, lineWidth: 1)
            )
    }
}

// MARK: - Screen background

struct VoiidBackground: View {
    var body: some View {
        VoiidColor.background.ignoresSafeArea()
    }
}

// MARK: - Circular avatar with the "voiid" placeholder wordmark used in the chat grid

struct VoiidAvatar: View {
    var size: CGFloat = 100
    var imageName: String? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .fill(VoiidColor.fieldFill)
            if let imageName, let ui = UIImage(named: imageName) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Text("voiid")
                    .font(VoiidFont.rounded(size * 0.28, .semibold))
                    .foregroundColor(VoiidColor.textSecondary.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
    }
}
