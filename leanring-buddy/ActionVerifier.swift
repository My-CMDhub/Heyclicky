//
//  ActionVerifier.swift
//  leanring-buddy
//
//  An action is not successful because the call returned .success. That only
//  means the message was delivered. Success is when the tree says the world
//  changed — so we go and look.
//

import ApplicationServices
import Foundation

enum VerificationOutcome: Equatable {
    case confirmed(afterMilliseconds: Int)
    /// The focused window we acted in stopped existing. See `verify`.
    case windowGone(afterMilliseconds: Int)
    case notObserved(afterMilliseconds: Int)
    case couldNotReadWindow
}

enum ActionVerifier {

    /// A gap must be read this many polls in a row before it counts. A window
    /// switch can leave no focused window for a moment, and one read of a gap
    /// is not evidence.
    static let consecutiveMissingWindowPollsRequired = 2

    /// Re-walks the focused window until `expectation` holds or the budget runs
    /// out, polling rather than sleeping a fixed time and hoping.
    ///
    /// The elapsed time is returned even on success: how long a native app takes
    /// to settle is a number Phase 3 will need for its waits, and we do not have
    /// it yet.
    ///
    /// The contract has always been "the app reacted", never "the intended thing
    /// happened" — a changed fingerprint is that same weak form. The focused
    /// window we acted in disappearing is the same kind of evidence, and it was
    /// being reported as a failure. Measured 2026-09-11: TextEdit `File > Close`
    /// took its window list `['Untitled']` -> `[]`, and the harness answered
    /// `notVerified / couldNotReadWindow` after the full 3 s, because with no
    /// window left every poll threw `.noFocusedWindow`. A success reported as
    /// its opposite. Finder never showed it only because its desktop window
    /// always remains.
    ///
    /// `hadFocusedWindowBefore` must be false when nothing was focused before the
    /// action. A menu can be pressed in an app with no window at all, and then
    /// "no focused window" afterwards is not a window that closed — it is the
    /// same nothing as before, and calling it `.windowGone` would confirm a
    /// no-op. Found in review, 2026-09-11, before it shipped.
    static func verify(
        hadFocusedWindowBefore: Bool = true,
        expectation: (AccessibilityWindowSnapshot) -> Bool,
        timeoutInSeconds: Double = 3.0,
        pollIntervalInSeconds: Double = 0.15
    ) -> VerificationOutcome {
        let startedAt = Date()
        var sawAnyWindow = false
        var pollErrors: [Error?] = []

        func elapsedMilliseconds() -> Int { Int(Date().timeIntervalSince(startedAt) * 1000) }

        while Date().timeIntervalSince(startedAt) < timeoutInSeconds {
            do {
                let snapshot = try AccessibilityTreeWalker.snapshotFocusedWindow()
                sawAnyWindow = true
                pollErrors.append(nil)
                if expectation(snapshot) {
                    return .confirmed(afterMilliseconds: elapsedMilliseconds())
                }
            } catch {
                pollErrors.append(error)
                if let gone = outcome(
                    afterPolls: pollErrors, elapsedMilliseconds: elapsedMilliseconds(),
                    hadFocusedWindowBefore: hadFocusedWindowBefore
                ) {
                    return gone
                }
            }
            Thread.sleep(forTimeInterval: pollIntervalInSeconds)
        }

        return sawAnyWindow ? .notObserved(afterMilliseconds: elapsedMilliseconds()) : .couldNotReadWindow
    }

    /// The gap decision, pure so it can be tested without a cross-process read.
    /// `afterPolls` holds one entry per poll, nil for a successful snapshot.
    ///
    /// Only `.noFocusedWindow` counts. A locked screen, a revoked permission or
    /// no frontmost app is a failure to *look*, never evidence of change.
    static func outcome(
        afterPolls: [Error?],
        elapsedMilliseconds: Int,
        hadFocusedWindowBefore: Bool = true
    ) -> VerificationOutcome? {
        // A window cannot have closed if there was none to begin with.
        guard hadFocusedWindowBefore else { return nil }
        let recent = afterPolls.suffix(consecutiveMissingWindowPollsRequired)
        let allGaps = recent.count == consecutiveMissingWindowPollsRequired
            && recent.allSatisfy { ($0 as? AccessibilitySnapshotError) == .noFocusedWindow }
        return allGaps ? .windowGone(afterMilliseconds: elapsedMilliseconds) : nil
    }
}
