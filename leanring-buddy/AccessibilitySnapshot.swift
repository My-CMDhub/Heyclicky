//
//  AccessibilitySnapshot.swift
//  leanring-buddy
//
//  Phase 1 of J.A.R.V.I.S.: reads the structural description macOS apps
//  publish for VoiceOver, so the agent can ground itself in named elements
//  instead of guessing pixel coordinates from a screenshot.
//

import AppKit
import ApplicationServices

/// One element in an app's Accessibility tree, with its frame already
/// converted out of AX coordinates into AppKit coordinates.
struct AccessibilityElementNode {
    let role: String
    let subrole: String?
    let title: String?
    let value: String?

    /// AXDescription. System Settings' detail-pane rows are AXButtons with no
    /// title and no value — measured 2026-09-07, all 14 came back anonymous
    /// until this attribute was read.
    let elementDescription: String?

    let frameInAppKitCoordinates: CGRect
    let depth: Int
    let children: [AccessibilityElementNode]

    /// The actions this element says it can perform. Empty means "cannot be
    /// acted on through the Accessibility API".
    let publishedActionNames: [String]

    /// The human-readable name, wherever the app chose to publish it.
    ///
    /// Measured 2026-09-07: zero of System Settings' 177 nodes carried an
    /// AXTitle — every visible label ("Wi-Fi", "Accessibility") arrived as
    /// AXValue instead. Matching only on title finds nothing in that app.
    /// An app may publish its label as AXTitle, AXDescription or AXValue, and
    /// System Settings uses a different one for each control type: nothing for
    /// rows, AXValue for sidebar labels, AXDescription for detail-pane buttons.
    var displayName: String? { title ?? elementDescription ?? value }

    /// Whether this element is something an agent could actually act on:
    /// it has a name, it publishes at least one action, and it occupies space.
    var isActionable: Bool {
        displayName != nil
            && !publishedActionNames.isEmpty
            && frameInAppKitCoordinates.width > 0
            && frameInAppKitCoordinates.height > 0
    }

    /// The live cross-process handle. Present only on nodes produced by a real
    /// walk — hand-built nodes in tests leave it nil.
    let accessibilityElement: AXUIElement?

    init(
        role: String,
        subrole: String?,
        title: String?,
        value: String?,
        elementDescription: String? = nil,
        frameInAppKitCoordinates: CGRect,
        depth: Int,
        children: [AccessibilityElementNode],
        publishedActionNames: [String] = [],
        accessibilityElement: AXUIElement? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.elementDescription = elementDescription
        self.frameInAppKitCoordinates = frameInAppKitCoordinates
        self.depth = depth
        self.children = children
        self.publishedActionNames = publishedActionNames
        self.accessibilityElement = accessibilityElement
    }
}

/// Bounds a tree walk and — critically — records that it was bounded.
///
/// A truncated tree is indistinguishable from a genuinely shallow app, so a
/// silent cap would quietly teach us the wrong lesson about how AX behaves.
struct AccessibilityWalkBudget {
    let maximumDepth: Int
    let maximumNodeCount: Int

    private(set) var nodesVisited = 0
    private(set) var wasTruncated = false

    init(maximumDepth: Int, maximumNodeCount: Int) {
        self.maximumDepth = maximumDepth
        self.maximumNodeCount = maximumNodeCount
    }

    /// Returns true if a node at this depth may be visited, spending one slot.
    /// Returns false and flags truncation when either limit is reached.
    mutating func claimSlot(atDepth depth: Int) -> Bool {
        guard depth < maximumDepth else {
            wasTruncated = true
            return false
        }
        guard nodesVisited < maximumNodeCount else {
            wasTruncated = true
            return false
        }

        nodesVisited += 1
        return true
    }
}

/// The result of one walk, carrying both the tree and what it cost.
struct AccessibilityWindowSnapshot {
    let rootNode: AccessibilityElementNode?
    let applicationName: String
    let bundleIdentifier: String
    let walkDurationInSeconds: Double
    let nodeCount: Int
    let deepestLevelReached: Int
    let wasTruncatedByBudget: Bool
    let timedOutNodePaths: [String]
    let nodesWithoutReadableFrame: Int
    let subtreesLostToFailedReads: Int

    /// True when the frontmost application changed while the walk was running.
    ///
    /// Measured 2026-09-08: Mail took 27.1 seconds to walk. Anything that slow is
    /// not a snapshot — the operator switched apps mid-walk and the result
    /// describes a window that had already gone to the background. The elements
    /// read after the switch may not match the ones read before it.
    let focusChangedDuringWalk: Bool
}

enum AccessibilitySnapshotError: Error {
    case accessibilityPermissionNotGranted
    case noFrontmostApplication
    case noFocusedWindow
}

enum AccessibilityTreeWalker {

    /// Converts a frame from Accessibility coordinates (origin at the TOP-LEFT
    /// of the primary display, y growing downward) into AppKit coordinates
    /// (origin at the BOTTOM-LEFT of the primary display, y growing upward).
    ///
    /// Both systems describe the same pixel; they disagree only about which
    /// way is down. Skipping this conversion does not crash — it silently
    /// mirrors every frame vertically, which is why it is unit tested.
    /// Ask an Electron app to build its accessibility tree.
    ///
    /// Electron gates tree construction behind `AXManualAccessibility` so that
    /// the cost is only paid when an assistive client actually asks. Until it is
    /// set, the app answers with a near-empty tree — which reads exactly like an
    /// app with no accessibility support, and is why our first Electron
    /// measurements were wrong.
    ///
    /// **Set it blind.** The attribute deliberately does not appear in
    /// `AXUIElementCopyAttributeNames` or Accessibility Inspector, so probing for
    /// it first will always say unsupported. A failure here is information, not
    /// an error: native apps have no such attribute and return
    /// `kAXErrorAttributeUnsupported`, which tells us the app was never gated.
    ///
    /// Deliberately NOT `AXEnhancedUserInterface`, which is Chrome's equivalent
    /// switch and is documented to break window positioning for window managers.
    @discardableResult
    static func requestManualAccessibility(from applicationElement: AXUIElement) -> AXError {
        AXUIElementSetAttributeValue(
            applicationElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
    }

    static func convertAccessibilityFrameToAppKitFrame(
        _ accessibilityFrame: CGRect,
        primaryDisplayHeightInPoints: CGFloat
    ) -> CGRect {
        let appKitOriginY = primaryDisplayHeightInPoints
            - accessibilityFrame.origin.y
            - accessibilityFrame.height

        return CGRect(
            x: accessibilityFrame.origin.x,
            y: appKitOriginY,
            width: accessibilityFrame.width,
            height: accessibilityFrame.height
        )
    }

    /// Renders the tree as an indented text outline, two spaces per level.
    static func serializeTreeToText(_ rootNode: AccessibilityElementNode) -> String {
        var lines: [String] = []
        appendSerializedLines(for: rootNode, into: &lines)
        return lines.joined(separator: "\n")
    }

    private static func appendSerializedLines(
        for node: AccessibilityElementNode,
        into lines: inout [String]
    ) {
        let indentation = String(repeating: "  ", count: node.depth)
        let titleFragment = node.title.map { " \"\($0)\"" } ?? ""
        let descriptionFragment = node.elementDescription.map { " desc=\"\($0)\"" } ?? ""
        // A text area's AXValue is the entire document. Xcode with a file open
        // would emit thousands of lines from one node, break the one-line-per-node
        // contract, and turn "tree size" into a measurement of that text view.
        // Truncated, but the true length is kept so nothing is hidden.
        let valueFragment = node.value.map { rawValue -> String in
            let singleLine = rawValue.replacingOccurrences(of: "\n", with: "\\n")
            guard singleLine.count > 100 else { return " = \"\(singleLine)\"" }
            return " = \"\(singleLine.prefix(100))…\" (\(rawValue.count) chars)"
        } ?? ""
        let frameFragment = String(
            format: "(%.0f, %.0f, %.0f, %.0f)",
            node.frameInAppKitCoordinates.origin.x,
            node.frameInAppKitCoordinates.origin.y,
            node.frameInAppKitCoordinates.width,
            node.frameInAppKitCoordinates.height
        )

        // Appended only when non-empty, so trees without actions serialise
        // exactly as before and the existing serialiser test still holds.
        let actionsFragment = node.publishedActionNames.isEmpty
            ? ""
            : " [" + node.publishedActionNames.joined(separator: ",") + "]"

        lines.append(indentation + node.role + titleFragment + descriptionFragment + valueFragment + " " + frameFragment + actionsFragment)

        for childNode in node.children {
            appendSerializedLines(for: childNode, into: &lines)
        }
    }

    /// Walks the focused window of the frontmost application.
    ///
    /// Every attribute read below is synchronous inter-process communication
    /// with the target app. That is why each element gets a messaging timeout:
    /// a beachballing app would otherwise block this process indefinitely.
    ///
    /// ponytail: runs on the calling thread and blocks it for the whole walk.
    /// Fine for the dump runner; move to a background actor if the overlay
    /// ever needs to walk while the UI stays responsive.
    static func snapshotFocusedWindow(
        maximumDepth: Int = 120,
        maximumNodeCount: Int = 2000
    ) throws -> AccessibilityWindowSnapshot {
        guard AXIsProcessTrusted() else {
            throw AccessibilitySnapshotError.accessibilityPermissionNotGranted
        }

        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            throw AccessibilitySnapshotError.noFrontmostApplication
        }

        // Setting the timeout on one element applies ONLY to that element. The SDK
        // header is explicit: "Setting the timeout on another accessibility object
        // sets it only for that object." Every child we create while walking is a
        // fresh object, so a per-element timeout would cover 2 of ~177 reads and
        // leave the rest on the process default. The system-wide object is the
        // documented way to set it for every request this process makes.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)

        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        // A native app has no such attribute and answers kAXErrorAttributeUnsupported
        // (-25205) — that is the "you were never gated" reply, not a failure. Only an
        // app that accepted it was building its tree on demand, and only that app
        // needs a moment to build one, so nothing else pays for this.
        // --ax-no-manual isolates the two variables: this session found a huge
        // Electron result and needs to know whether it came from the attribute or
        // from raising the depth budget.
        let manualAccessibilityResult = CommandLine.arguments.contains("--ax-no-manual")
            ? AXError.attributeUnsupported
            : requestManualAccessibility(from: applicationElement)
        let wasGatedApp = manualAccessibilityResult == .success

        // A gated app has to *construct* its tree after saying yes, and it does not
        // announce when it is done. Measured 2026-09-09: Cursor accepts the
        // attribute and still has no focused window 250 ms later, so a single sleep
        // reads as "this app has no window" — the same silent-zero mistake in a new
        // costume. Retry until the window appears instead of guessing a duration.
        var focusedWindowElement = copyElementAttribute(
            from: applicationElement,
            attribute: kAXFocusedWindowAttribute
        )
        if wasGatedApp {
            var attemptsRemaining = 20   // 20 x 100 ms = 2 s ceiling
            while focusedWindowElement == nil, attemptsRemaining > 0 {
                Thread.sleep(forTimeInterval: 0.1)
                focusedWindowElement = copyElementAttribute(
                    from: applicationElement,
                    attribute: kAXFocusedWindowAttribute
                )
                attemptsRemaining -= 1
            }
            print("🔓 AXManualAccessibility accepted by \(frontmostApplication.localizedName ?? "?") — window after \((20 - attemptsRemaining) * 100) ms")
        } else {
            print("🔒 not gated (AXError \(manualAccessibilityResult.rawValue)) — native app, tree was always there")
        }

        // AXFocusedWindow is not universal. Fall back through the other two window
        // attributes before concluding there is no window, and print what the app
        // actually publishes so a failure names its own cause instead of guessing.
        if focusedWindowElement == nil {
            focusedWindowElement = copyElementAttribute(
                from: applicationElement,
                attribute: kAXMainWindowAttribute
            )
            if focusedWindowElement != nil { print("   ↳ no AXFocusedWindow; used AXMainWindow") }
        }
        if focusedWindowElement == nil {
            var windowsValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                applicationElement, kAXWindowsAttribute as CFString, &windowsValue
            ) == .success,
               let windows = windowsValue as? [AXUIElement], let first = windows.first {
                focusedWindowElement = first
                print("   ↳ no AXFocusedWindow/AXMainWindow; used AXWindows[0] of \(windows.count)")
            }
        }
        if focusedWindowElement == nil {
            var names: CFArray?
            AXUIElementCopyAttributeNames(applicationElement, &names)
            print("   ↳ application element publishes: \((names as? [String] ?? []).joined(separator: ", "))")
        }

        guard let focusedWindowElement else {
            throw AccessibilitySnapshotError.noFocusedWindow
        }

        // NSScreen.screens[0] is always the display whose origin is (0, 0) —
        // the one AX measures every other display relative to.
        let primaryDisplayHeightInPoints = NSScreen.screens.first?.frame.height ?? 0

        var budget = AccessibilityWalkBudget(
            maximumDepth: maximumDepth,
            maximumNodeCount: maximumNodeCount
        )
        var deepestLevelReached = 0
        var timedOutNodePaths: [String] = []
        var nodesWithoutReadableFrame = 0
        var subtreesLostToFailedReads = 0

        let walkStartedAt = Date()
        let rootNode = buildNode(
            from: focusedWindowElement,
            depth: 0,
            primaryDisplayHeightInPoints: primaryDisplayHeightInPoints,
            budget: &budget,
            deepestLevelReached: &deepestLevelReached,
            timedOutNodePaths: &timedOutNodePaths,
            nodesWithoutReadableFrame: &nodesWithoutReadableFrame,
            subtreesLostToFailedReads: &subtreesLostToFailedReads
        )
        let walkDurationInSeconds = Date().timeIntervalSince(walkStartedAt)

        // The tree is a live system, not a frozen image. On a slow app the walk
        // outlives the user's attention, so we check whether the ground moved.
        let focusChangedDuringWalk =
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                != frontmostApplication.processIdentifier

        return AccessibilityWindowSnapshot(
            rootNode: rootNode,
            applicationName: frontmostApplication.localizedName ?? "unknown",
            bundleIdentifier: frontmostApplication.bundleIdentifier ?? "unknown",
            walkDurationInSeconds: walkDurationInSeconds,
            nodeCount: budget.nodesVisited,
            deepestLevelReached: deepestLevelReached,
            wasTruncatedByBudget: budget.wasTruncated,
            timedOutNodePaths: timedOutNodePaths,
            nodesWithoutReadableFrame: nodesWithoutReadableFrame,
            subtreesLostToFailedReads: subtreesLostToFailedReads,
            focusChangedDuringWalk: focusChangedDuringWalk
        )
    }

    // MARK: - Batched reads

    /// The seven attributes every node needs, asked for in one call.
    ///
    /// The walker used to make nine separate cross-process round trips per node:
    /// five strings, position, size, children, and the action list. Measured
    /// 2026-09-09 with `scripts/ax-read-benchmark.swift`, batching is worth ~2.5x
    /// — and notably NOT 9x. Collapsing round trips does not divide the cost,
    /// because the expense is the target app answering, not the transport. That
    /// is also why the gain is nearly identical across very different apps.
    ///
    /// `AXActionNames` is a separate API rather than an attribute, so it cannot
    /// join the batch. Nine trips become two.
    private static let batchedAttributeNames: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
        kAXValueAttribute, kAXDescriptionAttribute, "AXFrame", kAXChildrenAttribute
    ]

    private struct BatchedNodeRead {
        var role: String?
        var subrole: String?
        var title: String?
        var value: String?
        var elementDescription: String?
        var frame: CGRect?
        var children: [AXUIElement] = []
        var childReadFailed = false
        var frameDidTimeOut = false
    }

    /// A failed entry inside a batched result comes back as an `AXValue` wrapping
    /// an `AXError`, not as a missing element — so "the app has no children" and
    /// "the children read failed" are still distinguishable, which the walker
    /// depends on. Returns nil only when the batch call itself failed, so the
    /// caller can fall back to individual reads.
    private static func batchedRead(from element: AXUIElement) -> BatchedNodeRead? {
        var rawValues: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            element,
            batchedAttributeNames as CFArray,
            AXCopyMultipleAttributeOptions(),   // never .stopOnError: one bad attribute must not lose the rest
            &rawValues
        )
        guard result == .success,
              let values = rawValues as? [AnyObject],
              values.count == batchedAttributeNames.count else {
            return nil
        }

        func errorCode(at index: Int) -> AXError? {
            let entry = values[index]
            guard CFGetTypeID(entry) == AXValueGetTypeID() else { return nil }
            let axValue = entry as! AXValue
            guard AXValueGetType(axValue) == .axError else { return nil }
            var code = AXError.success
            guard AXValueGetValue(axValue, .axError, &code) else { return nil }
            return code
        }

        func string(at index: Int) -> String? {
            guard errorCode(at: index) == nil,
                  let text = values[index] as? String, !text.isEmpty else { return nil }
            return text
        }

        var read = BatchedNodeRead()
        read.role = string(at: 0)
        read.subrole = string(at: 1)
        read.title = string(at: 2)
        read.value = string(at: 3)
        read.elementDescription = string(at: 4)

        if errorCode(at: 5) == nil, CFGetTypeID(values[5]) == AXValueGetTypeID() {
            let axValue = values[5] as! AXValue
            var rect = CGRect.zero
            if AXValueGetType(axValue) == .cgRect, AXValueGetValue(axValue, .cgRect, &rect) {
                read.frame = rect
            }
        } else if errorCode(at: 5) == .cannotComplete {
            read.frameDidTimeOut = true
        }

        if let childError = errorCode(at: 6) {
            // Same rule as the unbatched path: these two mean "genuinely empty".
            read.childReadFailed = !(childError == .noValue || childError == .attributeUnsupported)
        } else if let kids = values[6] as? [AXUIElement] {
            read.children = kids
        }

        return read
    }

    private static func buildNode(
        from element: AXUIElement,
        depth: Int,
        primaryDisplayHeightInPoints: CGFloat,
        budget: inout AccessibilityWalkBudget,
        deepestLevelReached: inout Int,
        timedOutNodePaths: inout [String],
        nodesWithoutReadableFrame: inout Int,
        subtreesLostToFailedReads: inout Int
    ) -> AccessibilityElementNode? {
        guard budget.claimSlot(atDepth: depth) else { return nil }

        deepestLevelReached = max(deepestLevelReached, depth)

        // One batched call for all seven attributes; the individual reads remain as
        // the fallback for any app that refuses the batched API.
        let batched = batchedRead(from: element)

        let role = batched?.role
            ?? copyStringAttribute(from: element, attribute: kAXRoleAttribute)
            ?? "AXUnknown"
        let subrole = batched?.subrole ?? copyStringAttribute(from: element, attribute: kAXSubroleAttribute)
        let title = batched?.title ?? copyStringAttribute(from: element, attribute: kAXTitleAttribute)
        let value = batched?.value ?? copyStringAttribute(from: element, attribute: kAXValueAttribute)
        let elementDescription = batched?.elementDescription
            ?? copyStringAttribute(from: element, attribute: kAXDescriptionAttribute)

        // AXFrame is not an SDK constant and not every app publishes it, so fall
        // back to position + size rather than reporting a frameless node.
        let frameReadResult: (frame: CGRect?, didTimeOut: Bool)
        if let batched, batched.frame != nil {
            frameReadResult = (batched.frame, false)
        } else if let batched, batched.frameDidTimeOut {
            frameReadResult = (nil, true)
        } else {
            frameReadResult = copyFrame(from: element)
        }

        if frameReadResult.didTimeOut {
            timedOutNodePaths.append("\(role) at depth \(depth)")
        } else if frameReadResult.frame == nil {
            nodesWithoutReadableFrame += 1
        }

        let appKitFrame = convertAccessibilityFrameToAppKitFrame(
            frameReadResult.frame ?? .zero,
            primaryDisplayHeightInPoints: primaryDisplayHeightInPoints
        )

        var childNodes: [AccessibilityElementNode] = []
        let childReadResult = batched.map { (children: $0.children, readFailed: $0.childReadFailed) }
            ?? copyChildElements(from: element)
        if childReadResult.readFailed {
            subtreesLostToFailedReads += 1
        }

        for childElement in childReadResult.children {
            guard let childNode = buildNode(
                from: childElement,
                depth: depth + 1,
                primaryDisplayHeightInPoints: primaryDisplayHeightInPoints,
                budget: &budget,
                deepestLevelReached: &deepestLevelReached,
                timedOutNodePaths: &timedOutNodePaths,
                nodesWithoutReadableFrame: &nodesWithoutReadableFrame,
                subtreesLostToFailedReads: &subtreesLostToFailedReads
            ) else { break }

            childNodes.append(childNode)
        }

        // Skip the action read where it cannot change the answer.
        //
        // `isActionable` requires a displayName AND a non-zero frame AND a
        // published action. A node failing either of the first two can never be
        // actionable, so its action list is bought and discarded. Measured
        // 2026-09-09: AXUIElementCopyActionNames is a separate API that cannot
        // join the batched read and costs 1.45 ms/node in Mail — 46% of the
        // per-node total, which is exactly why batching the other seven
        // attributes only bought 1.37x.
        let couldEverBeActionable = (title ?? elementDescription ?? value) != nil
            && appKitFrame.width > 0 && appKitFrame.height > 0
        let publishedActionNames = couldEverBeActionable
            ? copyActionNames(from: element)
            : []

        return AccessibilityElementNode(
            role: role,
            subrole: subrole,
            title: title,
            value: value,
            elementDescription: elementDescription,
            frameInAppKitCoordinates: appKitFrame,
            depth: depth,
            children: childNodes,
            publishedActionNames: publishedActionNames,
            accessibilityElement: element
        )
    }

    /// Asks an element which actions it publishes — "AXPress", "AXShowMenu",
    /// "AXScrollToVisible" and so on.
    ///
    /// This is the only authority on what an element can do. Roles are untyped
    /// conventions an app chose for itself: an AXButton is not guaranteed to be
    /// pressable, and a non-button may well be.
    static func copyActionNames(from element: AXUIElement) -> [String] {
        var actionNamesValue: CFArray?
        guard AXUIElementCopyActionNames(element, &actionNamesValue) == .success,
              let actionNames = actionNamesValue as? [String] else {
            return []
        }
        return actionNames
    }

    private static func copyStringAttribute(from element: AXUIElement, attribute: String) -> String? {
        var attributeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &attributeValue) == .success,
              let stringValue = attributeValue as? String,
              !stringValue.isEmpty else {
            return nil
        }
        return stringValue
    }

    private static func copyElementAttribute(from element: AXUIElement, attribute: String) -> AXUIElement? {
        var attributeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &attributeValue) == .success,
              let attributeValue,
              CFGetTypeID(attributeValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (attributeValue as! AXUIElement)
    }

    /// Reads an element's children, and says whether the read itself failed.
    ///
    /// Returning a bare empty array for both "no children" and "the read failed"
    /// makes a stalled app indistinguishable from a genuinely shallow one — the
    /// same wrong-lesson failure the budget's truncation flag exists to prevent,
    /// except this one silently drops an entire subtree.
    private static func copyChildElements(
        from element: AXUIElement
    ) -> (children: [AXUIElement], readFailed: Bool) {
        var attributeValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &attributeValue)

        // kAXErrorNoValue and kAXErrorAttributeUnsupported both mean "genuinely
        // has no children", which is not a failure.
        if result == .noValue || result == .attributeUnsupported {
            return ([], false)
        }
        guard result == .success, let childElements = attributeValue as? [AXUIElement] else {
            return ([], true)
        }
        return (childElements, false)
    }

    /// Reads an element's frame, and reports *why* it failed when it does.
    ///
    /// A frame read fails for two unrelated reasons: the target app did not
    /// answer in time (AXError.cannotComplete, i.e. our messaging timeout
    /// fired), or the element genuinely publishes no position — plenty of
    /// AXGroups do. Reporting both as one number would make a healthy app look
    /// unreliable, so the caller gets to tell them apart.
    private static func copyFrame(from element: AXUIElement) -> (frame: CGRect?, didTimeOut: Bool) {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?

        let positionResult = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        let sizeResult = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        let didTimeOut = positionResult == .cannotComplete || sizeResult == .cannotComplete

        guard positionResult == .success,
              sizeResult == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return (nil, didTimeOut)
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return (nil, didTimeOut)
        }

        return (CGRect(origin: position, size: size), false)
    }
}

extension AccessibilityElementNode {
    /// Every node in this subtree, including this one, as a flat list.
    /// The overlay draws one box per entry.
    func flattenedDescendants() -> [AccessibilityElementNode] {
        [self] + children.flatMap { $0.flattenedDescendants() }
    }
}
