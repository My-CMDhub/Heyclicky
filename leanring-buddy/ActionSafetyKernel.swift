//
//  ActionSafetyKernel.swift
//  leanring-buddy
//
//  Deterministic policy that runs before any action reaches the machine.
//  It knows nothing about models and cannot be argued out of a refusal.
//
//  The default is requireConfirmation, never allow. Anything this kernel does
//  not positively recognise becomes a question for the human.
//

import ApplicationServices
import Foundation

enum SafetyDecision: Equatable {
    case allow
    case requireConfirmation(reason: String)
    case refuse(reason: String)
}

enum ActionSafetyKernel {

    /// Roles for which a press is ordinary navigation on this machine.
    /// Deliberately short — it grows only when a measured case demands it.
    static let navigationalPressRoles: Set<String> = ["AXButton", "AXRow", "AXCell"]

    /// Words that make an action worth asking about regardless of role.
    /// Refusal reasons as constants, so the probe can classify a decision by
    /// identity rather than by re-typing the sentence and silently missing.
    static let zeroAreaRefusalReason = "listed but not reachable: element has a zero-area frame"
    static let outsideBoundsRefusalReason = "listed but not reachable: element lies outside the visible bounds"

    /// The name is the whole identity we act on, and the app wrote it. A label
    /// that is empty, document-length, or carries a newline is not a control's
    /// name — it is content that arrived in a name-shaped field, and letting it
    /// name an action is how app-controlled text becomes an instruction.
    static let implausibleNameRefusalReason = "listed but not usable as a target: the element's name is not a plain label"

    static let destructiveTitleKeywords = [
        "delete", "remove", "erase", "send", "buy", "pay", "purchase", "reset"
    ]

    static func evaluate(
        intent: ElementActionIntent,
        resolvedNode: AccessibilityElementNode,
        matchCount: Int,
        visibleBounds: CGRect
    ) -> SafetyDecision {
        // Order matters. Every refusal is checked before any permission.

        guard matchCount == 1 else {
            return .refuse(reason: "\(matchCount) elements match that title")
        }

        let frame = resolvedNode.frameInAppKitCoordinates
        guard frame.width > 0, frame.height > 0 else {
            return .refuse(reason: zeroAreaRefusalReason)
        }

        // Zero area is only the first disguise. Measured 2026-09-08:
        // AXButton desc="Transfer or Reset" (354, -66, 459, 38) [AXPress] is
        // named, correctly sized and pressable, and scrolled out of its pane.
        // Reachability is the relationship between the frame and what is on
        // screen, not a property of the frame alone.
        guard frame.intersects(visibleBounds) else {
            return .refuse(reason: outsideBoundsRefusalReason)
        }

        let requiredActionName = intent.action.accessibilityActionName
        guard resolvedNode.publishedActionNames.contains(requiredActionName) else {
            return .refuse(reason: "element does not publish \(requiredActionName)")
        }

        guard let name = resolvedNode.displayName, name.isPlausibleControlLabel else {
            return .refuse(reason: implausibleNameRefusalReason)
        }

        // App-written text may only ever make the decision *more* cautious.
        // A keyword here escalates to a question; nothing an app publishes can
        // turn a question into an allow.
        let lowercasedTitle = name.raw.lowercased()
        if let matchedKeyword = destructiveTitleKeywords.first(where: { lowercasedTitle.contains($0) }) {
            return .requireConfirmation(reason: "title suggests a destructive action: \(matchedKeyword)")
        }

        guard navigationalPressRoles.contains(resolvedNode.role) else {
            return .requireConfirmation(reason: "unrecognised role \(resolvedNode.role)")
        }

        return .allow
    }
}
