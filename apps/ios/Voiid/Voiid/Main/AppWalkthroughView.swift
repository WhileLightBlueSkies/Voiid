import SwiftUI
import Combine

extension Notification.Name {
    static let voiidReplayAppWalkthrough = Notification.Name("voiidReplayAppWalkthrough")
    static let voiidOpenSettings = Notification.Name("voiidOpenSettings")
    static let voiidDismissSettings = Notification.Name("voiidDismissSettings")
}

@MainActor
final class AppWalkthroughController: ObservableObject {
    static let shared = AppWalkthroughController()

    @Published private(set) var isPresented = false
    @Published private(set) var currentIndex = 0

    private let defaults: UserDefaults
    private var accountID = "local"
    private var evaluatedInitialPresentation = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var step: AppWalkthroughStep { AppWalkthroughPlan.steps[currentIndex] }
    var stepNumber: Int { currentIndex + 1 }
    var stepCount: Int { AppWalkthroughPlan.steps.count }
    var isFirstStep: Bool { currentIndex == 0 }
    var isLastStep: Bool { currentIndex == stepCount - 1 }

    func presentIfNeeded(accountID: String?) {
        guard !evaluatedInitialPresentation else { return }
        evaluatedInitialPresentation = true
        self.accountID = accountID?.isEmpty == false ? accountID! : "local"
        guard AppWalkthroughPlan.shouldPresent(completedVersion: defaults.integer(forKey: completionKey)) else { return }
        if AppWalkthroughPlan.presentationMode == .firstIncompleteVersion {
            currentIndex = min(max(defaults.integer(forKey: progressKey), 0), stepCount - 1)
        } else {
            currentIndex = 0
        }
        isPresented = true
    }

    func replay(accountID: String?) {
        self.accountID = accountID?.isEmpty == false ? accountID! : "local"
        currentIndex = 0
        isPresented = true
    }

    func advance() {
        guard !isLastStep else { complete(); return }
        currentIndex += 1
        defaults.set(currentIndex, forKey: progressKey)
    }

    func goBack() {
        currentIndex = max(0, currentIndex - 1)
        defaults.set(currentIndex, forKey: progressKey)
    }

    func skip() {
        defaults.set(AppWalkthroughPlan.version, forKey: completionKey)
        defaults.removeObject(forKey: progressKey)
        isPresented = false
        NotificationCenter.default.post(name: .voiidDismissSettings, object: nil)
    }

    func complete() {
        defaults.set(AppWalkthroughPlan.version, forKey: completionKey)
        defaults.removeObject(forKey: progressKey)
        isPresented = false
        NotificationCenter.default.post(name: .voiidDismissSettings, object: nil)
    }

    private var keyPrefix: String { "voiid.walkthrough.\(accountID).v\(AppWalkthroughPlan.version)" }
    private var completionKey: String { "\(keyPrefix).completed" }
    private var progressKey: String { "\(keyPrefix).step" }
}

struct AppWalkthroughView: View {
    @ObservedObject var controller: AppWalkthroughController
    var targets: [String: SpotlightTargetInfo] = [:]
    var coordinateSpace: String = "root_walkthrough"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var rawTargetInfo: SpotlightTargetInfo? {
        guard let id = controller.step.targetId else { return nil }
        return targets[id]
    }

    var body: some View {
        GeometryReader { geo in
            let screenWidth = geo.size.width
            let screenHeight = geo.size.height
            let myOrigin = geo.frame(in: .global).origin
            let targetInfo = rawTargetInfo?.offsetBy(dx: -myOrigin.x, dy: -myOrigin.y)
            // THE SCRIM HAS A DIFFERENT ORIGIN FROM EVERYTHING ELSE HERE. It ignores the safe
            // area, so its drawing space starts under the status bar, while `targetInfo` is in
            // this reader's space, which starts BELOW it. Using `targetInfo` for the hole drew
            // it higher than the ring and the control it points at, by the top inset. The hole
            // gets the target in the scrim's own space instead.
            let insets = geo.safeAreaInsets
            let cutoutInfo = rawTargetInfo?.offsetBy(dx: -(myOrigin.x - insets.leading),
                                                     dy: -(myOrigin.y - insets.top))

            ZStack {
                // 1. Scrim with cutout punched hole
                SpotlightCutoutShape(target: cutoutInfo)
                    .fill(Color.black.opacity(reduceTransparency ? 0.76 : 0.68), style: FillStyle(eoFill: true))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.tap()
                        controller.advance()
                    }
                    .accessibilityHidden(true)

                // 2. Animated Pulsing Halo Ring & Inner Border
                if let target = targetInfo {
                    WalkthroughPulseRing(target: target)
                        .id("pulse_\(target.id)")
                        .allowsHitTesting(false)
                }

                // Keep Skip above the full-size tooltip layout so it always receives taps.
                cardView(target: targetInfo, screenWidth: screenWidth, screenHeight: screenHeight)

                VStack {
                    HStack {
                        Spacer()
                        Button {
                            Haptics.tap()
                            controller.skip()
                        } label: {
                            Text("Skip")
                                .font(VoiidFont.rounded(15, .semibold))
                                .foregroundStyle(.white)
                                .frame(minWidth: 72, minHeight: 44)
                                .background(Color.black.opacity(0.45), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Skip walkthrough")
                        .padding(.top, 12)
                        .padding(.trailing, 18)
                    }
                    Spacer()
                }
                .zIndex(10)
            }
            .frame(width: screenWidth, height: screenHeight)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.18)
                                : .spring(response: 0.28, dampingFraction: 0.9),
                   value: controller.currentIndex)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private func cardView(target: SpotlightTargetInfo?, screenWidth: CGFloat, screenHeight: CGFloat) -> some View {
        let hasArrow = target != nil
        let targetCenterX = target?.bounds.midX ?? (screenWidth / 2)
        let pointingUp = target != nil ? (target!.bounds.midY < screenHeight * 0.48) : false

        let minArrowOffset: CGFloat = 20
        let maxArrowOffset: CGFloat = max(minArrowOffset, screenWidth - 36 - 20 - 18)
        let arrowOffset = min(max(targetCenterX - 18 - 9, minArrowOffset), maxArrowOffset)

        VStack(spacing: 0) {
            if hasArrow && pointingUp {
                HStack {
                    SpeechBubbleArrow(pointingUp: true)
                        .fill(VoiidColor.surfaceCard)
                        .frame(width: 18, height: 9)
                        .offset(x: arrowOffset)
                    Spacer()
                }
            }

            speechBubbleCardBody

            if hasArrow && !pointingUp {
                HStack {
                    SpeechBubbleArrow(pointingUp: false)
                        .fill(VoiidColor.surfaceCard)
                        .frame(width: 18, height: 9)
                        .offset(x: arrowOffset)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 18)
        .id(controller.step.id)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cardAlignment(pointingUp: pointingUp, hasTarget: hasArrow))
        .padding(.top, topCardPadding(target: target, pointingUp: pointingUp, screenHeight: screenHeight))
        .padding(.bottom, bottomCardPadding(target: target, pointingUp: pointingUp, screenHeight: screenHeight))
    }

    private func cardAlignment(pointingUp: Bool, hasTarget: Bool) -> Alignment {
        guard hasTarget else { return .center }
        return pointingUp ? .top : .bottom
    }

    private func topCardPadding(target: SpotlightTargetInfo?, pointingUp: Bool, screenHeight: CGFloat) -> CGFloat {
        guard let target = target, pointingUp else { return 0 }
        let targetBottom = target.bounds.maxY + target.padding
        return max(targetBottom + 12, 54)
    }

    private func bottomCardPadding(target: SpotlightTargetInfo?, pointingUp: Bool, screenHeight: CGFloat) -> CGFloat {
        guard let target = target, !pointingUp else { return 0 }
        let targetTop = target.bounds.minY - target.padding
        return max(screenHeight - targetTop + 12, 34)
    }

    private var speechBubbleCardBody: some View {
        VStack(spacing: 0) {
            // Top: Full width pastel photo banner
            if let imageName = controller.step.imageName {
                Image(imageName)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 152)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }

            // Bottom: Text, progress indicator, and action buttons
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(controller.step.eyebrow)
                        .font(VoiidFont.rounded(11, .bold))
                        .tracking(1.1)
                        .foregroundStyle(VoiidColor.primary)
                    Text(controller.step.title)
                        .font(VoiidFont.rounded(20, .bold))
                        .foregroundStyle(VoiidColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(controller.step.message)
                    .font(VoiidFont.rounded(14))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                // Step progress track
                HStack(spacing: 5) {
                    ForEach(0..<controller.stepCount, id: \.self) { index in
                        Capsule()
                            .fill(index == controller.currentIndex ? VoiidColor.primary : VoiidColor.divider)
                            .frame(width: index == controller.currentIndex ? 20 : 6, height: 6)
                    }
                    Spacer()
                    Text("\(controller.stepNumber) of \(controller.stepCount)")
                        .font(VoiidFont.rounded(12, .semibold))
                        .foregroundStyle(VoiidColor.textSecondary)
                }
                .padding(.top, 4)

                // Action buttons
                HStack(spacing: 10) {
                    if !controller.isFirstStep {
                        Button("Back") {
                            Haptics.tap()
                            controller.goBack()
                        }
                        .buttonStyle(WalkthroughSecondaryButtonStyle())
                    }
                    Button(controller.isLastStep ? "Done" : "Next") {
                        Haptics.tap()
                        controller.advance()
                    }
                    .buttonStyle(WalkthroughPrimaryButtonStyle())
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity)
        .background(reduceTransparency ? VoiidColor.surfaceCard : VoiidColor.surfaceCard.opacity(0.98),
                    in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .stroke(VoiidColor.divider.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.24), radius: 26, y: 12)
        .accessibilityLabel("\(controller.step.eyebrow). \(controller.step.title). \(controller.step.message). Step \(controller.stepNumber) of \(controller.stepCount).")
    }
}

struct WalkthroughPulseRing: View {
    let target: SpotlightTargetInfo
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseAlpha: Double = 0.85

    var body: some View {
        let pad = target.padding
        let bounds = target.bounds.insetBy(dx: -pad, dy: -pad)

        ZStack {
            switch target.shape {
            case .circle:
                let diameter = max(bounds.width, bounds.height)
                // Radiant pulse ring
                Circle()
                    .stroke(VoiidColor.primary.opacity(reduceMotion ? 0.0 : pulseAlpha), lineWidth: 2.5)
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(reduceMotion ? 1.0 : pulseScale)
                // Sharp inner border ring
                Circle()
                    .stroke(VoiidColor.primary.opacity(0.6), lineWidth: 1.5)
                    .frame(width: diameter, height: diameter)

            case .rounded(let radius):
                // Radiant pulse ring
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(VoiidColor.primary.opacity(reduceMotion ? 0.0 : pulseAlpha), lineWidth: 2.5)
                    .frame(width: bounds.width, height: bounds.height)
                    .scaleEffect(reduceMotion ? 1.0 : pulseScale)
                // Sharp inner border ring
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(VoiidColor.primary.opacity(0.6), lineWidth: 1.5)
                    .frame(width: bounds.width, height: bounds.height)

            case .capsule:
                Capsule()
                    .stroke(VoiidColor.primary.opacity(reduceMotion ? 0.0 : pulseAlpha), lineWidth: 2.5)
                    .frame(width: bounds.width, height: bounds.height)
                    .scaleEffect(reduceMotion ? 1.0 : pulseScale)
                Capsule()
                    .stroke(VoiidColor.primary.opacity(0.6), lineWidth: 1.5)
                    .frame(width: bounds.width, height: bounds.height)
            }
        }
        .position(x: bounds.midX, y: bounds.midY)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false)) {
                pulseScale = 1.25
                pulseAlpha = 0.0
            }
        }
    }
}

private struct WalkthroughPrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VoiidFont.rounded(15, .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(VoiidColor.primary, in: Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.75 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct WalkthroughSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VoiidFont.rounded(15, .semibold))
            .foregroundStyle(VoiidColor.textPrimary)
            .frame(minWidth: 88, minHeight: 48)
            .background(VoiidColor.surfaceRaised, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
