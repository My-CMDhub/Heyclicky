//
//  ElementActionIntent.swift
//  leanring-buddy
//
//  A structured intention plus the local resolver that turns it into exactly
//  one element, or into a refusal. A model will eventually emit these; local
//  code always decides whether and how they execute.
//

import AppKit
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

    /// Typing is a property write too, and which property depends on the mode.
    /// See `TypeMode`.
    case type

    /// Opening: a published action, and the one Finder actually answers to.
    ///
    /// Measured 2026-09-10: a Finder file row publishes only the hover pair
    /// (`AXShowDefaultUI` / `AXShowAlternateUI`), but the `AXCell` inside it
    /// publishes **`AXOpen`**. That is the whole reason this is a separate verb
    /// rather than a press — Finder's window has 12 pressable elements and none
    /// of them is a file.
    case open

    /// Pressing a menu item, resolved by its path down the menu bar rather than
    /// by a name in the focused window. Same published action as a press; a
    /// completely different way of finding the element, and a different set of
    /// facts about its frame. See `AccessibilityMenu`.
    case menu

    /// The published action this needs, or nil when the verb is a property
    /// write and there is no action to look for.
    var accessibilityActionName: String? {
        switch self {
        case .press, .menu:
            return kAXPressAction
        case .open:
            return "AXOpen"
        case .select, .type:
            return nil
        }
    }

    /// Whether this verb's target is something drawn on screen, so that its
    /// frame is evidence about whether we can act on it.
    ///
    /// True for everything in a window. False for a menu item, and measured
    /// rather than assumed — see the note on the kernel's frame checks.
    var targetHasAnOnScreenFrame: Bool {
        switch self {
        case .press, .select, .type, .open: return true
        case .menu: return false
        }
    }
}

/// Replace the field, or insert at the caret. Two different attributes, and the
/// difference is measurable, not stylistic.
///
/// Probed 2026-09-10 on TextEdit's `AXTextArea` and System Settings' search
/// field (role `AXTextField`, subrole `AXSearchField`): both publish `AXValue`,
/// `AXSelectedText`, `AXSelectedTextRange` and `AXFocused` as **settable**.
///
///     writing AXValue         replaces the WHOLE field — TextEdit went to
///                             "Edited", and System Settings' search filtered
///                             live with no AXConfirm needed at all
///     writing AXSelectedText  inserts at the caret, once AXSelectedTextRange
///                             has put the caret where you mean
enum TypeMode: String, Equatable, CaseIterable {
    case insert
    case replace

    /// The attribute the mode actually writes — and therefore the one the
    /// element must say is settable before we are allowed to try. A role is a
    /// convention; this is the element answering for itself.
    var settableAttributeRequired: String {
        switch self {
        case .insert: return kAXSelectedTextAttribute
        case .replace: return kAXValueAttribute
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

/// Typing: the other half of the action API that is not an action.
///
/// Same shape as `AccessibilitySelectionPerformer` and for the same reasons —
/// ask the element what is settable rather than believing its role, raise the
/// messaging timeout on that one element because a write animates, return the
/// raw `AXError` next to the clock, and read the value back.
///
/// The read-back matters more here than anywhere else in this project: for a
/// press or a select the effect is somewhere else in the tree, but for typing
/// **the text is the effect**. If the field does not contain what we wrote, the
/// write did not happen, whatever `AXError` says.
enum AccessibilityTypePerformer {

    static let typingTimeoutInSeconds: Float = 5.0

    /// The four attributes probed before a write. `AXFocused` and
    /// `AXSelectedTextRange` are not required by either mode, but they are what
    /// separates "this is a live text field" from "this is a label with a role
    /// that looks like one", and they cost one round trip each on a single
    /// element — not per node.
    static let probedAttributes = [
        kAXValueAttribute, kAXSelectedTextAttribute,
        kAXSelectedTextRangeAttribute, kAXFocusedAttribute
    ]

    struct Outcome: Equatable {
        let attributeWritten: String
        let error: AXError
        let milliseconds: Int
        let valueLengthBefore: Int
        /// nil when the field would not answer at all after the write, which is
        /// a different fact from "it answered with the old text".
        let valueAfter: String?
    }

    /// The element's current text, or nil when it publishes none.
    static func stringValue(of element: AXUIElement) -> String? {
        var out: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &out) == .success else {
            return nil
        }
        return out as? String
    }

    /// Which of the four the element says it will accept. Asked, never assumed —
    /// Hammerspoon's author documents writes to non-settable attributes coming
    /// back `.success` anyway, so this is the cheap half of the evidence and the
    /// read-back is the other half.
    static func settableAttributes(of element: AXUIElement) -> Set<String> {
        Set(probedAttributes.filter { AccessibilitySelectionPerformer.isSettable(element, $0) })
    }

    /// Whoever has keyboard focus in the frontmost app, as a node.
    ///
    /// This exists because **text fields are frequently anonymous**: System
    /// Settings' search field publishes no title, no description and an empty
    /// value, so `displayName` is nil and no amount of name resolution reaches
    /// it. A human does not aim at that field by name either — they click it,
    /// and then type into whatever has focus. This is that.
    ///
    /// Built from direct reads rather than looked up in the walked tree on
    /// purpose: focus can be in a sheet or a popover the window walk pruned, and
    /// "not in the tree" would then be reported as "nothing has focus".
    static func focusedNode() -> AccessibilityElementNode? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)

        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            applicationElement, kAXFocusedUIElementAttribute as CFString, &focusedValue
        ) == .success,
            let focusedValue,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let element = focusedValue as! AXUIElement

        func string(_ attribute: String) -> String? {
            var out: AnyObject?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success,
                  let text = out as? String, !text.isEmpty else { return nil }
            return text
        }

        let primaryDisplayHeight = NSScreen.screens.first?.frame.height ?? 0
        let accessibilityFrame = frame(of: element) ?? .zero

        return AccessibilityElementNode(
            role: string(kAXRoleAttribute) ?? "AXUnknown",
            subrole: string(kAXSubroleAttribute),
            title: string(kAXTitleAttribute),
            value: string(kAXValueAttribute),
            elementDescription: string(kAXDescriptionAttribute),
            frameInAppKitCoordinates: AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(
                accessibilityFrame, primaryDisplayHeightInPoints: primaryDisplayHeight
            ),
            depth: 0,
            children: [],
            publishedActionNames: AccessibilityTreeWalker.copyActionNames(from: element),
            accessibilityElement: element
        )
    }

    /// AXFrame first, position + size as the fallback — the same order the
    /// walker uses, because AXFrame is not an SDK constant and not every app
    /// publishes it. A zero frame here would be read by the kernel as
    /// "unreachable" and refuse a perfectly good field.
    private static func frame(of element: AXUIElement) -> CGRect? {
        var frameValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &frameValue) == .success,
           let frameValue, CFGetTypeID(frameValue) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(frameValue as! AXValue, .cgRect, &rect) { return rect }
        }

        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Writes `text` into `element`.
    ///
    /// `.insert` puts the caret at the end of the current value first — an
    /// `AXSelectedText` write replaces the *selection*, and a field whose
    /// selection is the whole value would be replaced by an insert, which is
    /// exactly the destruction the replace confirmation exists to prevent.
    /// The range is in UTF-16 units, which is what the AX text APIs count in.
    static func type(_ text: String, mode: TypeMode, into element: AXUIElement) -> Outcome {
        // A write animates: a text field re-lays out, a search field re-filters.
        // It must not inherit the walker's 0.5 s read timeout.
        AXUIElementSetMessagingTimeout(element, typingTimeoutInSeconds)

        let valueBefore = stringValue(of: element) ?? ""
        let startedAt = Date()
        let error: AXError

        switch mode {
        case .replace:
            error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        case .insert:
            var caret = CFRange(location: valueBefore.utf16.count, length: 0)
            if let caretValue = AXValueCreate(.cfRange, &caret) {
                AXUIElementSetAttributeValue(
                    element, kAXSelectedTextRangeAttribute as CFString, caretValue
                )
            }
            error = AXUIElementSetAttributeValue(
                element, kAXSelectedTextAttribute as CFString, text as CFString
            )
        }

        return Outcome(
            attributeWritten: mode.settableAttributeRequired,
            error: error,
            milliseconds: Int(Date().timeIntervalSince(startedAt) * 1000),
            valueLengthBefore: valueBefore.count,
            valueAfter: stringValue(of: element)
        )
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

/// The menu bar: the app's other tree, and the one this harness could not see.
///
/// **It hangs off the APPLICATION element, not the window.**
/// `kAXMenuBarAttribute` on `AXUIElementCreateApplication(pid)`. Every walk in
/// this project starts at `kAXFocusedWindow`, so none of the below has ever
/// appeared in a snapshot. Measured 2026-09-10, menu items / named / pressable
/// / with a shortcut / full read:
///
///     Finder            301  258  300  105    545 ms
///     TextEdit          314  267  314   71  1,082 ms
///     Mail              591  502  591  113  1,580 ms
///     System Settings   205  181  205   27    577 ms
///     Cursor            428  355  428  108    279 ms
///     Google Chrome     325  281  324   72    539 ms
///
/// Finder's *window* publishes 12 pressable elements. Its *menu bar* publishes
/// 300 — and a screenshot of a closed menu shows none of them, which is the
/// whole argument for this being a verb of its own.
///
/// Re-measured through this code the same day, and the two numbers are not the
/// same measurement: `menus` on Finder reports **257 items, 105 with a
/// shortcut, 146 ms**. The shortcut count matches exactly; the item count is
/// lower because separators and other unnamed entries are not listed, and the
/// time is lower because each item's five attributes arrive in one batched
/// read. Scoped to one menu (`["View"]`) it is 37 items in 20 ms — the prefix
/// is a smaller *walk*, not a filter over a big one.
///
/// Shape, and it is regular:
///
///     AXMenuBar
///       AXMenuBarItem "File"
///         AXMenu                       ← a single wrapper, always
///           AXMenuItem "New Finder Window"
///           AXMenuItem "Open With"
///             AXMenu                   ← submenus populate WITHOUT being opened
///               AXMenuItem …
///
/// So a path is resolved by reading one level at a time — six or seven IPC
/// reads, not the 545 ms full listing.
enum AccessibilityMenu {

    static let menuBarRole = "AXMenuBar"
    static let menuRole = "AXMenu"
    static let menuItemRole = "AXMenuItem"
    static let menuBarItemRole = "AXMenuBarItem"

    static let enabledAttribute = "AXEnabled"
    static let cmdCharAttribute = "AXMenuItemCmdChar"
    static let cmdModifiersAttribute = "AXMenuItemCmdModifiers"

    /// Same rule as the window walk: every read below is synchronous
    /// cross-process IPC and a busy app would otherwise block this process.
    static let messagingTimeoutInSeconds: Float = 0.5

    /// A listing is bounded exactly like a walk is, and it names which limit
    /// fired — "this app has a big menu bar" and "this app stopped answering"
    /// demand opposite responses.
    static let maximumItemsListed = 3_000
    static let listingTimeLimitInSeconds = 5.0

    /// One menu element, flattened to what a resolution needs.
    ///
    /// `children` is populated only on hand-built trees; a live read fetches
    /// them through the provider closure instead, which is what keeps a path
    /// resolution to the path.
    struct Node {
        let label: String?
        let role: String
        let isEnabled: Bool
        let shortcut: String?
        let element: AXUIElement?
        let children: [Node]

        init(
            label: String?,
            role: String,
            isEnabled: Bool = true,
            shortcut: String? = nil,
            element: AXUIElement? = nil,
            children: [Node] = []
        ) {
            self.label = label
            self.role = role
            self.isEnabled = isEnabled
            self.shortcut = shortcut
            self.element = element
            self.children = children
        }
    }

    // MARK: - Resolution (pure; the provider is the only live part)

    enum StepOutcome: Equatable {
        case matched(index: Int)
        /// What WAS there, which is the half that makes a miss actionable.
        case notFound(available: [String])
        case ambiguous(matchCount: Int)
    }

    enum Resolution: Equatable {
        case resolved(label: String?, role: String, isEnabled: Bool)
        case notFound(atStep: Int, step: String, available: [String])
        case ambiguous(atStep: Int, step: String, matchCount: Int)
        case emptyPath
    }

    /// One path step against one level.
    ///
    /// Never takes the first of several. Chrome publishes "Close Window" under
    /// more than one menu and Finder repeats "Open" — a step matching twice is
    /// a question, and a coin flip here is a wrong menu item pressed with no
    /// undo.
    static func match(step: String, among candidates: [Node]) -> StepOutcome {
        let indices = candidates.indices.filter { candidates[$0].label == step }
        switch indices.count {
        case 1: return .matched(index: indices[0])
        case 0: return .notFound(available: candidates.compactMap(\.label))
        default: return .ambiguous(matchCount: indices.count)
        }
    }

    /// The items one level down, stepping through the single `AXMenu` wrapper
    /// that sits between a menu-bar item (or a submenu parent) and its entries.
    static func entries(of node: Node, children: (Node) -> [Node]) -> [Node] {
        let direct = children(node)
        if direct.count == 1, direct[0].role == menuRole { return children(direct[0]) }
        return direct
    }

    /// Walks **only the path**. `children` is the one impure part: live it is an
    /// AX read, in a test it is `\.children` over a hand-built tree, and both
    /// exercise the same stepping and the same `AXMenu` descent.
    static func resolveNode(
        path: [String],
        from root: Node,
        children: (Node) -> [Node]
    ) -> (node: Node?, resolution: Resolution) {
        guard !path.isEmpty else { return (nil, .emptyPath) }

        var current = root
        for (index, step) in path.enumerated() {
            let candidates = entries(of: current, children: children)
            switch match(step: step, among: candidates) {
            case .matched(let matchedIndex):
                current = candidates[matchedIndex]
            case .notFound(let available):
                return (nil, .notFound(atStep: index, step: step, available: available))
            case .ambiguous(let matchCount):
                return (nil, .ambiguous(atStep: index, step: step, matchCount: matchCount))
            }
        }
        return (current, .resolved(label: current.label, role: current.role, isEnabled: current.isEnabled))
    }

    // MARK: - Listing

    struct ListedItem {
        let path: [String]
        let role: String
        let isEnabled: Bool
        let shortcut: String?
        let hasSubmenu: Bool
    }

    struct Listing {
        let items: [ListedItem]
        let milliseconds: Int
        /// Empty means the listing finished. Never a bare `truncated: true` next
        /// to a plausible count — it says which limit fired.
        let stopReasons: [String]
    }

    /// Everything at or below `start`, with each item's full path from the bar.
    ///
    /// The prefix genuinely scopes the read: the caller resolves it first (one
    /// level at a time) and passes the resolved node in, so `menus ["File"]` on
    /// Mail reads File's subtree and not the other 550 items.
    static func list(
        from start: Node,
        pathSoFar: [String],
        children: (Node) -> [Node],
        deadline: Date
    ) -> Listing {
        let startedAt = Date()
        var items: [ListedItem] = []
        var stopReasons: Set<String> = []
        collect(start, pathSoFar: pathSoFar, children: children, deadline: deadline,
                items: &items, stopReasons: &stopReasons)
        return Listing(
            items: items,
            milliseconds: Int(Date().timeIntervalSince(startedAt) * 1000),
            stopReasons: stopReasons.sorted()
        )
    }

    private static func collect(
        _ node: Node,
        pathSoFar: [String],
        children: (Node) -> [Node],
        deadline: Date,
        items: inout [ListedItem],
        stopReasons: inout Set<String>
    ) {
        guard items.count < maximumItemsListed else {
            stopReasons.insert(WalkStopReason.nodeLimit.rawValue)
            return
        }
        guard Date() < deadline else {
            stopReasons.insert(WalkStopReason.timeLimit.rawValue)
            return
        }

        let childNodes = entries(of: node, children: children)

        // The bar itself is not an item; everything below it is.
        if node.role == menuItemRole || node.role == menuBarItemRole {
            items.append(ListedItem(
                path: pathSoFar,
                role: node.role,
                isEnabled: node.isEnabled,
                shortcut: node.shortcut,
                hasSubmenu: !childNodes.isEmpty
            ))
        }

        for child in childNodes {
            guard let label = child.label else { continue }
            collect(child, pathSoFar: pathSoFar + [label], children: children,
                    deadline: deadline, items: &items, stopReasons: &stopReasons)
        }
    }

    // MARK: - Shortcuts

    /// `AXMenuItemCmdModifiers` encodes Command **by its absence**.
    ///
    /// Bit 3 (value 8) set means "no Command"; bits 0, 1 and 2 are Shift, Option
    /// and Control. So a bare ⌘N is mask 0 — the value that looks most like "no
    /// modifiers" is the one that means Command, which is exactly the sort of
    /// encoding you get wrong silently and never notice.
    static func describeShortcut(character: String?, modifiers: Int?) -> String? {
        guard let character, !character.isEmpty else { return nil }
        let mask = modifiers ?? 0
        var text = ""
        // Apple's own display order: ⌃⌥⇧⌘, then the key.
        if mask & 4 != 0 { text += "⌃" }
        if mask & 2 != 0 { text += "⌥" }
        if mask & 1 != 0 { text += "⇧" }
        if mask & 8 == 0 { text += "⌘" }
        return text + readableKey(character)
    }

    /// The cmd char is sometimes a control character — a raw `\u{8}` in a
    /// response is not "readable", which is the whole job of this field.
    static let readableKeys: [Character: String] = [
        "\u{8}": "⌫", "\u{9}": "⇥", "\u{d}": "↩", "\u{1b}": "⎋", "\u{7f}": "⌦", " ": "␣"
    ]

    static func readableKey(_ character: String) -> String {
        if let first = character.first, let symbol = readableKeys[first] { return symbol }
        return character.uppercased()
    }

    // MARK: - The live reads

    /// The menu bar of a running application, as a root node.
    static func menuBarNode(for application: NSRunningApplication) -> Node? {
        // Bound every read that follows. The menu bar is a different element,
        // not a different rule.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeoutInSeconds)

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            applicationElement, kAXMenuBarAttribute as CFString, &value
        ) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }

        return Node(label: nil, role: menuBarRole, element: (value as! AXUIElement))
    }

    /// One level of children, each read in a single batched call.
    ///
    /// Five attributes per child in one round trip, for the same reason the
    /// walker batches: collapsing round trips is worth ~2.5x, and a full Mail
    /// listing is 591 of these.
    static let batchedAttributes = [
        kAXRoleAttribute, kAXTitleAttribute, enabledAttribute,
        cmdCharAttribute, cmdModifiersAttribute, kAXChildrenAttribute
    ]

    static func liveChildren(of node: Node) -> [Node] {
        guard let element = node.element else { return [] }

        var childrenValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        guard result == .success, let childElements = childrenValue as? [AXUIElement] else { return [] }

        return childElements.map { childElement in
            var rawValues: CFArray?
            let batchResult = AXUIElementCopyMultipleAttributeValues(
                childElement, batchedAttributes as CFArray, AXCopyMultipleAttributeOptions(), &rawValues
            )
            let values = (batchResult == .success ? rawValues as? [AnyObject] : nil) ?? []

            func entry(_ index: Int) -> AnyObject? {
                guard index < values.count else { return nil }
                let value = values[index]
                // A failed attribute comes back as an AXValue wrapping an
                // AXError, not as a missing slot.
                if CFGetTypeID(value) == AXValueGetTypeID(),
                   AXValueGetType(value as! AXValue) == .axError { return nil }
                return value
            }

            let title = entry(1) as? String
            return Node(
                label: (title?.isEmpty == false) ? title : nil,
                role: (entry(0) as? String) ?? "AXUnknown",
                // Absent AXEnabled means the app never said; treat that as
                // enabled, because the refusal below must fire on a measured
                // false and not on a missing read.
                isEnabled: (entry(2) as? Bool) ?? true,
                shortcut: describeShortcut(
                    character: entry(3) as? String,
                    modifiers: (entry(4) as? NSNumber)?.intValue
                ),
                element: childElement
            )
        }
    }

    /// The resolved menu item as the node type the safety kernel evaluates.
    ///
    /// Frame and action list are read **only here** — one element, after the
    /// path resolved — rather than on every candidate at every level.
    static func elementNode(for node: Node) -> AccessibilityElementNode {
        let element = node.element
        var frame = CGRect.zero
        if let element {
            var frameValue: AnyObject?
            if AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &frameValue) == .success,
               let frameValue, CFGetTypeID(frameValue) == AXValueGetTypeID() {
                var rect = CGRect.zero
                if AXValueGetValue(frameValue as! AXValue, .cgRect, &rect) { frame = rect }
            }
        }
        let primaryDisplayHeight = NSScreen.screens.first?.frame.height ?? 0

        return AccessibilityElementNode(
            role: node.role,
            subrole: nil,
            title: node.label,
            value: nil,
            elementDescription: nil,
            frameInAppKitCoordinates: AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(
                frame, primaryDisplayHeightInPoints: primaryDisplayHeight
            ),
            depth: 0,
            children: [],
            publishedActionNames: element.map(AccessibilityTreeWalker.copyActionNames) ?? [],
            accessibilityElement: element
        )
    }

    /// How many windows the application has open, for verification.
    ///
    /// The window fingerprint is the harness's general "did the world move"
    /// test, and it is blind to exactly the thing a File menu does: two Finder
    /// windows on the same folder have the same named elements. This is one
    /// extra IPC read that catches it.
    static func windowCount(for application: NSRunningApplication) -> Int? {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            applicationElement, kAXWindowsAttribute as CFString, &value
        ) == .success, let windows = value as? [AXUIElement] else { return nil }
        return windows.count
    }
}
