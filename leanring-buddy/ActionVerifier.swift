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
    case notObserved(afterMilliseconds: Int)
    case couldNotReadWindow
}

enum ActionVerifier {

    /// Re-walks the focused window until `expectation` holds or the budget runs
    /// out, polling rather than sleeping a fixed time and hoping.
    ///
    /// The elapsed time is returned even on success: how long a native app takes
    /// to settle is a number Phase 3 will need for its waits, and we do not have
    /// it yet.
    static func verify(
        expectation: (AccessibilityWindowSnapshot) -> Bool,
        timeoutInSeconds: Double = 3.0,
        pollIntervalInSeconds: Double = 0.15
    ) -> VerificationOutcome {
        let startedAt = Date()
        var sawAnyWindow = false

        while Date().timeIntervalSince(startedAt) < timeoutInSeconds {
            if let snapshot = try? AccessibilityTreeWalker.snapshotFocusedWindow() {
                sawAnyWindow = true
                if expectation(snapshot) {
                    let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                    return .confirmed(afterMilliseconds: elapsed)
                }
            }
            Thread.sleep(forTimeInterval: pollIntervalInSeconds)
        }

        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        return sawAnyWindow ? .notObserved(afterMilliseconds: elapsed) : .couldNotReadWindow
    }
}
