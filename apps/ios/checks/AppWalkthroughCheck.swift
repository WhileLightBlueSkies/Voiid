import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct AppWalkthroughCheck {
    static func main() {
        let steps = AppWalkthroughPlan.steps
        expect(steps.map(\.destination).compactMap { $0 } == [.chats, .moments, .communities, .games],
               "the tour must include only the four features shipped on both platforms")
        expect(steps.first?.id == "welcome", "welcome must be the first step")
        expect(steps.last?.id == "complete", "completion must be the final step")

        var progress = AppWalkthroughProgress(stepCount: steps.count)
        expect(progress.currentIndex == 0, "new progress starts at the welcome step")
        expect(progress.advance() == .showStep(1), "advance opens the next step")
        expect(progress.goBack() == .showStep(0), "back returns to the previous step")
        expect(progress.goBack() == .showStep(0), "back cannot move before the first step")

        for _ in 1..<steps.count { _ = progress.advance() }
        expect(progress.advance() == .completed, "advance from the last step completes the tour")
        expect(progress.isComplete, "completion is durable in the state model")

        var skipped = AppWalkthroughProgress(stepCount: steps.count)
        skipped.skip()
        expect(skipped.isSkipped, "skip suppresses the current walkthrough version")

        print("PASS: App walkthrough state and enabled-feature manifest")
    }
}
