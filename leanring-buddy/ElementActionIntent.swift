//
//  ElementActionIntent.swift
//  leanring-buddy
//
//  A structured intention plus the local resolver that turns it into exactly
//  one element, or into a refusal. A model will eventually emit these; local
//  code always decides whether and how they execute.
//

import ApplicationServices
import Foundation

enum ElementAction {
    case press

    var accessibilityActionName: String {
        switch self {
        case .press:
            return kAXPressAction
        }
    }
}

struct ElementActionIntent {
    /// Optional: when given, the match must also agree on role.
    let role: String?
    let title: String
    let action: ElementAction
}

enum IntentResolution: Equatable {
    case resolved(AccessibilityElementNode)
    case notFound
    case ambiguous(matchCount: Int)

    static func == (lhs: IntentResolution, rhs: IntentResolution) -> Bool {
        switch (lhs, rhs) {
        case (.notFound, .notFound):
            return true
        case (.ambiguous(let leftCount), .ambiguous(let rightCount)):
            return leftCount == rightCount
        case (.resolved(let leftNode), .resolved(let rightNode)):
            return leftNode.role == rightNode.role
                && leftNode.title == rightNode.title
                && leftNode.frameInAppKitCoordinates == rightNode.frameInAppKitCoordinates
        default:
            return false
        }
    }
}

enum ElementActionIntentResolver {

    /// Finds every node whose title — and role, when the intent names one —
    /// matches. More than one match is a refusal, never a coin flip: System
    /// Settings shows the same word in both the sidebar and the detail pane.
    static func resolve(
        _ intent: ElementActionIntent,
        inTreeRootedAt rootNode: AccessibilityElementNode
    ) -> IntentResolution {
        let matchingNodes = rootNode.flattenedDescendants().filter { node in
            guard node.displayName == intent.title else { return false }
            guard let requiredRole = intent.role else { return true }
            return node.role == requiredRole
        }

        switch matchingNodes.count {
        case 0:
            return .notFound
        case 1:
            return .resolved(matchingNodes[0])
        default:
            return .ambiguous(matchCount: matchingNodes.count)
        }
    }
}

/// Performing an action is not the same kind of call as reading an attribute,
/// and it must not inherit the read path's timeout.
///
/// Measured 2026-09-08: paging System Settings' detail pane returned
/// `kAXErrorCannotComplete` (-25204) — "the application is busy or
/// unresponsive" — because `AccessibilitySnapshot` sets a 0.5 s process-wide
/// messaging timeout to keep a slow app from hanging a 177-node walk. A read
/// answers a question; an action *does work* and does not return until the
/// animation finishes. Same timeout, two very different jobs.
///
/// The per-element timeout is exactly right here, for the same reason it was
/// wrong in the walker: it covers this one object and nothing else.
enum AccessibilityActionPerformer {

    static let actionTimeoutInSeconds: Float = 5.0

    /// Returns how long the call blocked as well as the result. A
    /// `kAXErrorCannotComplete` that comes back in 2 ms is the app refusing;
    /// one that comes back in 5,000 ms is our own timeout firing. They are the
    /// same error code and opposite problems, and only the clock separates them.
    static func perform(
        _ actionName: String,
        on element: AXUIElement
    ) -> (error: AXError, milliseconds: Int) {
        AXUIElementSetMessagingTimeout(element, actionTimeoutInSeconds)
        let startedAt = Date()
        let error = AXUIElementPerformAction(element, actionName as CFString)
        return (error, Int(Date().timeIntervalSince(startedAt) * 1000))
    }
}

/// Scrolling when the accessibility action API refuses.
///
/// Measured 2026-09-08 on System Settings > General > About: the detail pane's
/// `AXScrollArea` publishes all four `AXScroll*ByPage` verbs and every one
/// returns `kAXErrorCannotComplete`. The window contains exactly one
/// `AXScrollBar` and it belongs to the *sidebar*, so there is no value to write
/// either. The pane scrolls perfectly well for a human.
///
/// So the verb drops one tier while the aim does not: AX supplies the exact
/// container rectangle, and a synthetic wheel event does what fingers do. This
/// is not "guess a pixel" — it is the same structural target, actuated lower
/// down.
enum SyntheticScroller {

    /// `CGEvent` uses **top-left** global display coordinates, the same origin
    /// AX uses and the opposite of AppKit. Our frames are already converted to
    /// AppKit, so they must be converted back or the event lands mirrored about
    /// the screen's horizontal centre — far away, and silently plausible.
    static func topLeftCentre(
        ofAppKitFrame frame: CGRect,
        primaryDisplayHeightInPoints: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: frame.midX,
            y: primaryDisplayHeightInPoints - frame.midY
        )
    }

    /// Negative `wheelDelta` scrolls the content down (the gesture that reveals
    /// what is below), matching `AXScrollDownByPage`.
    @discardableResult
    static func scroll(
        atTopLeftPoint point: CGPoint,
        wheelDelta: Int32,
        steps: Int = 6
    ) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        for _ in 0..<steps {
            guard let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 1,
                wheel1: wheelDelta,
                wheel2: 0,
                wheel3: 0
            ) else { return false }

            // The wheel event is delivered to whatever sits under this point,
            // so the location is the whole targeting mechanism.
            event.location = point
            event.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
        }
        return true
    }
}
