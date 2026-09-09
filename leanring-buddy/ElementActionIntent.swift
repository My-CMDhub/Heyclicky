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

    /// Selecting is a property write, not an action.
    ///
    /// Measured 2026-09-09 and again 2026-09-10: System Settings' 39 sidebar
    /// rows publish only `AXShowDefaultUI` / `AXShowAlternateUI` — no `AXPress`,
    /// ever. A human clicks them and the app navigates. The verb that does the
    /// same thing through Accessibility is writing `AXSelected = true`, which is
    /// not in the action API at all.
    case select

    /// The published action this needs, or nil when the verb is a property
    /// write and there is no action to look for.
    var accessibilityActionName: String? {
        switch self {
        case .press:
            return kAXPressAction
        case .select:
            return nil
        }
    }
}

struct ElementActionIntent {
    /// Optional: when given, the match must also agree on role.
    let role: String?
    let title: String
    let action: ElementAction

    /// Roughly where on screen the target is, in AppKit coordinates — what a
    /// model looking at a screenshot can say and a tree cannot.
    ///
    /// Measured 2026-09-09: of the names shared by more than one pressable
    /// element, the nearest named ancestor separates 5 of 7 in Mail but only 3
    /// of 21 in Chrome, and the role path from the window separates **zero** in
    /// either. The remaining 18 Chrome groups are siblings in the same container
    /// with the same role — nothing structural tells them apart, and only their
    /// position does.
    ///
    /// So this is the hybrid the project argues for, in one field: vision to see
    /// which one the human means, structure to aim at its exact frame. A pixel
    /// guess is a bad way to click and a perfectly good way to choose between
    /// two elements we have already found by name.
    var nearPoint: CGPoint? = nil

    /// The name of a container the target sits inside — "the Back button in the
    /// toolbar", not "one of the two Back buttons".
    ///
    /// Measured 2026-09-09 across Chrome, Mail and Claude Desktop: of 15 names
    /// shared by more than one pressable element, **10 are separated by the
    /// nearest named ancestor alone**, 3 more by a pointed-at location, 1 by the
    /// role path, and 1 by nothing at all. That is the whole ceiling — small
    /// enough that a snapshot-scoped reference protocol would be answering a
    /// question we do not have.
    var withinNamed: String? = nil
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
        var matchingNodes: [(node: AccessibilityElementNode, ancestorNames: [String])] = []
        collectMatches(in: rootNode, ancestorNames: [], for: intent, into: &matchingNodes)

        // Narrow in order of how much the runtime can trust each signal: a
        // container name is structure, a point is a model looking at pixels.
        // A hint that matches nothing narrows nothing — the kernel refuses an
        // ambiguous match either way, and inventing `.notFound` here would hide
        // that the element does exist.
        var candidates = matchingNodes
        if candidates.count > 1, let container = intent.withinNamed {
            let narrowed = candidates.filter { $0.ancestorNames.contains(container) }
            if !narrowed.isEmpty { candidates = narrowed }
        }
        if candidates.count > 1, let point = intent.nearPoint {
            let narrowed = candidates.filter { $0.node.frameInAppKitCoordinates.contains(point) }
            if !narrowed.isEmpty { candidates = narrowed }
        }

        switch candidates.count {
        case 0:
            return .notFound
        case 1:
            return .resolved(candidates[0].node)
        default:
            // Still more than one. Refuse rather than rank: "nearest" always
            // returns something, and something is what a wrong click looks like.
            // The count reported is the original match count, because that is
            // what a human would have to disambiguate.
            return .ambiguous(matchCount: matchingNodes.count)
        }
    }

    /// Every match, carrying the names of the containers it sits inside.
    ///
    /// Walks with the ancestor chain in hand rather than flattening first — the
    /// chain is the disambiguator, and rebuilding it afterwards would mean
    /// matching nodes by role, name and frame, which is exactly the identity
    /// problem this is here to solve.
    private static func collectMatches(
        in node: AccessibilityElementNode,
        ancestorNames: [String],
        for intent: ElementActionIntent,
        into matches: inout [(node: AccessibilityElementNode, ancestorNames: [String])]
    ) {
        // .raw, explicitly: comparing is the one thing app-written text is safe
        // for. The intent's title came from a planner, so this is our string
        // being matched against theirs, never theirs being trusted.
        let name = node.displayName?.raw
        if name == intent.title, intent.role == nil || node.role == intent.role {
            matches.append((node, ancestorNames))
        }

        let chainBelow = name.map { ancestorNames + [$0] } ?? ancestorNames
        for child in node.children {
            collectMatches(in: child, ancestorNames: chainBelow, for: intent, into: &matches)
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

/// Selecting: the half of the action API that is not an action.
///
/// Measured 2026-09-10 on System Settings, each path tested in isolation and
/// from a pane it was not already on:
///
///     AXSelected = true on the AXRow                  AXError 0, window "" -> "Accessibility"
///     AXSelectedRows = [row] on the AXOutline         AXError 0, window "Accessibility" -> "Sound"
///
/// Then Finder split them apart. Measured the same day, each in isolation:
///
///     Finder, AXSelected = true on the row       AXError 0, reads back TRUE, window did not move
///     Finder, AXSelectedRows = [row] on outline  AXError 0, Frameworks -> Documents -> Applications
///
/// So the row write is not enough. Finder accepted it, reported the row as
/// selected, and navigated nowhere — the selection state moved and the app did
/// not act on it. **The container write is the one that works in both apps**, so
/// it is tried first and the row write is the fallback.
///
/// The awkward part is not the write, it is the aim. A sidebar row is
/// **anonymous** — its label lives two levels below it:
///
///     AXRow                     [AXShowDefaultUI, AXShowAlternateUI]
///       AXCell                  []
///         AXStaticText "Sound"  [AXShowMenu]
///
/// So a planner naming "Sound" resolves to a static text that cannot be
/// selected, sitting inside a row that can. We walk up from what was named to
/// the first ancestor whose `AXSelected` the app says is settable — asking the
/// element, never assuming from its role.
enum AccessibilitySelectionPerformer {

    static let selectedAttribute = "AXSelected"

    /// Asked of the container, in order. `AXSelectedRows` is what an `AXOutline`
    /// and an `AXTable` publish; `AXSelectedChildren` is the generic form, and
    /// Apple's own header says it is writable "only if there is no other way to
    /// manipulate the set of selected elements" — which is this case exactly.
    static let containerSelectionAttributes = ["AXSelectedRows", "AXSelectedChildren"]
    static let selectionTimeoutInSeconds: Float = 5.0

    /// Which write did it. "It worked" and "it worked the other way" are
    /// different facts, and the next app will need to know which.
    enum SelectionPath: String, Equatable {
        case containerSelectedRows = "AXSelectedRows on the container"
        case containerSelectedChildren = "AXSelectedChildren on the container"
        case elementSelected = "AXSelected on the element itself"
    }

    enum Outcome: Equatable {
        /// `levelsAboveTarget` is 0 when the named element was itself selectable.
        case selected(path: SelectionPath, levelsAboveTarget: Int, milliseconds: Int, readBackTrue: Bool)
        case writeFailed(error: AXError, levelsAboveTarget: Int, milliseconds: Int)
        case noSelectableAncestor(levelsInspected: Int)
        case noLiveElement
    }

    /// `chainFromRoot` is the path the resolver walked: root first, named
    /// element last.
    static func select(chainFromRoot: [AccessibilityElementNode]) -> Outcome {
        guard !chainFromRoot.isEmpty else { return .noLiveElement }

        var sawALiveElement = false
        for (levelsUp, node) in chainFromRoot.reversed().enumerated() {
            guard let element = node.accessibilityElement else { continue }
            sawALiveElement = true
            guard isSelectable(element) else { continue }

            // A write animates. It must not inherit the walker's read timeout,
            // for the same reason a press does not.
            AXUIElementSetMessagingTimeout(element, selectionTimeoutInSeconds)

            // The container holding this row, if the chain has one.
            let rowIndex = chainFromRoot.count - 1 - levelsUp
            let container = rowIndex > 0 ? chainFromRoot[rowIndex - 1].accessibilityElement : nil

            var lastError: AXError = .success
            var lastMilliseconds = 0

            if let container {
                AXUIElementSetMessagingTimeout(container, selectionTimeoutInSeconds)
                for attribute in containerSelectionAttributes where isSettable(container, attribute) {
                    let startedAt = Date()
                    let error = AXUIElementSetAttributeValue(
                        container, attribute as CFString, [element] as CFArray
                    )
                    lastMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                    lastError = error
                    guard error == .success else { continue }
                    return .selected(
                        path: attribute == "AXSelectedRows" ? .containerSelectedRows : .containerSelectedChildren,
                        levelsAboveTarget: levelsUp,
                        milliseconds: lastMilliseconds,
                        readBackTrue: readsBackSelected(element)
                    )
                }
            }

            let startedAt = Date()
            let error = AXUIElementSetAttributeValue(
                element, selectedAttribute as CFString, kCFBooleanTrue
            )
            let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)

            guard error == .success else {
                return .writeFailed(
                    error: error == .success ? lastError : error,
                    levelsAboveTarget: levelsUp,
                    milliseconds: milliseconds
                )
            }

            return .selected(
                path: .elementSelected,
                levelsAboveTarget: levelsUp,
                milliseconds: milliseconds,
                readBackTrue: readsBackSelected(element)
            )
        }

        // "Nothing was selectable" and "there was nothing to ask" are different
        // answers, and returning the first for the second is how a dead handle
        // becomes a fact about the app.
        return sawALiveElement
            ? .noSelectableAncestor(levelsInspected: chainFromRoot.count)
            : .noLiveElement
    }

    /// `.success` means the message was delivered. Reading the value back is the
    /// cheapest evidence that it landed — and measured on Finder, still not
    /// enough on its own: the row read back as selected while the window never
    /// moved. Only a second walk settles that.
    static func readsBackSelected(_ element: AXUIElement) -> Bool {
        var readBack: AnyObject?
        AXUIElementCopyAttributeValue(element, selectedAttribute as CFString, &readBack)
        return (readBack as? Bool) == true
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var isSettable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &isSettable)
        return error == .success && isSettable.boolValue
    }

    /// Asks the element, because a role is a convention and this is a fact.
    /// `AXIsAttributeSettable` reported true for every System Settings row
    /// measured, and every one of those writes then worked — but it is the
    /// element being asked, not us guessing from `AXRow`.
    static func isSelectable(_ element: AXUIElement) -> Bool {
        isSettable(element, selectedAttribute)
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
