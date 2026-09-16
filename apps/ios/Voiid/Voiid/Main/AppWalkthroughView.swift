import SwiftUI

extension Notification.Name {
    static let voiidReplayAppWalkthrough = Notification.Name("voiidReplayAppWalkthrough")
}

@MainActor
final class AppWalkthroughController: ObservableObject {
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
    }

    func complete() {
        defaults.set(AppWalkthroughPlan.version, forKey: completionKey)
        defaults.removeObject(forKey: progressKey)
        isPresented = false
    }

    private var keyPrefix: String { "voiid.walkthrough.\(accountID).v\(AppWalkthroughPlan.version)" }
    private var completionKey: String { "\(keyPrefix).completed" }
    private var progressKey: String { "\(keyPrefix).step" }
}

struct AppWalkthroughView: View {
    @ObservedObject var controller: AppWalkthroughController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Color.black.opacity(reduceTransparency ? 0.72 : 0.58)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip") { controller.skip() }
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)

                Spacer(minLength: 24)

                card
                    .id(controller.step.id)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))

                Spacer(minLength: 34)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.18)
                                : .spring(response: 0.28, dampingFraction: 0.9),
                   value: controller.currentIndex)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: controller.step.symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(VoiidColor.accentInk)
                    .frame(width: 52, height: 52)
                    .background(VoiidColor.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(controller.step.eyebrow)
                        .font(VoiidFont.rounded(11, .bold))
                        .tracking(1.1)
                        .foregroundStyle(VoiidColor.accentInk)
                    Text(controller.step.title)
                        .font(VoiidFont.rounded(25, .bold))
                        .foregroundStyle(VoiidColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(controller.step.message)
                .font(VoiidFont.rounded(16))
                .foregroundStyle(VoiidColor.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                ForEach(0..<controller.stepCount, id: \.self) { index in
                    Capsule()
                        .fill(index == controller.currentIndex ? VoiidColor.primary : VoiidColor.divider)
                        .frame(width: index == controller.currentIndex ? 22 : 6, height: 6)
                }
                Spacer()
                Text("\(controller.stepNumber) of \(controller.stepCount)")
                    .font(VoiidFont.rounded(12, .semibold))
                    .foregroundStyle(VoiidColor.textSecondary)
            }

            HStack(spacing: 12) {
                if !controller.isFirstStep {
                    Button("Back") { controller.goBack() }
                        .buttonStyle(WalkthroughSecondaryButtonStyle())
                }
                Button(controller.isLastStep ? "Done" : (controller.isFirstStep ? "Start tour" : "Next")) {
                    controller.advance()
                }
                .buttonStyle(WalkthroughPrimaryButtonStyle())
            }
        }
        .padding(24)
        .background(reduceTransparency ? VoiidColor.surfaceCard : VoiidColor.surfaceCard.opacity(0.96),
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 30, y: 14)
        .padding(.horizontal, 20)
        .accessibilityLabel("\(controller.step.eyebrow). \(controller.step.title). \(controller.step.message). Step \(controller.stepNumber) of \(controller.stepCount).")
    }
}

private struct WalkthroughPrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VoiidFont.rounded(16, .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(VoiidColor.primary, in: Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.75 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct WalkthroughSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VoiidFont.rounded(16, .semibold))
            .foregroundStyle(VoiidColor.textPrimary)
            .frame(minWidth: 88, minHeight: 50)
            .background(VoiidColor.surfaceRaised, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
