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

    /// Written by the target app, so they arrive labelled. See `UntrustedText`.
    let title: UntrustedText?
    let value: UntrustedText?

    /// AXDescription. System Settings' detail-pane rows are AXButtons with no
    /// title and no value — measured 2026-09-07, all 14 came back anonymous
    /// until this attribute was read.
    let elementDescription: UntrustedText?

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
    var displayName: UntrustedText? { title ?? elementDescription ?? value }

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
        // The single boundary where an app's strings enter our types, and
        // therefore the only place the label has to be applied.
        self.title = title.map(UntrustedText.init)
        self.value = value.map(UntrustedText.init)
        self.elementDescription = elementDescription.map(UntrustedText.init)
        self.frameInAppKitCoordinates = frameInAppKitCoordinates
        self.depth = depth
        self.children = children
        self.publishedActionNames = publishedActionNames
        self.accessibilityElement = accessibilityElement
    }
}

/// An `AXUIElement` in a Swift `Set`.
///
/// CF types carry their own equality and hashing, and Swift will not use them
/// for you. Measured 2026-09-09 on Chrome: without this the same "New tab"
/// button appears **four times** in one window's tree, at two different depths.
struct AccessibilityElementKey: Hashable {
    let element: AXUIElement

    static func == (lhs: AccessibilityElementKey, rhs: AccessibilityElementKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

/// Bounds a tree walk and — critically — records that it was bounded.
///
/// A truncated tree is indistinguishable from a genuinely shallow app, so a
/// silent cap would quietly teach us the wrong lesson about how AX behaves.
/// Why a walk stopped early. Three unrelated causes that a single `truncated`
/// flag would flatten into one useless bit — and the project has already paid
/// once for a boolean sitting next to a number it invalidated.
enum WalkStopReason: String, CaseIterable {
    case depthLimit = "hit the depth limit"
    case nodeLimit = "hit the node limit"
    case timeLimit = "ran out of time"
}

struct AccessibilityWalkBudget {
    let maximumDepth: Int
    let maximumNodeCount: Int

    /// The wall-clock guard, and the only one that protects against an app we do
    /// not control.
    ///
    /// Depth and node caps bound the *shape* of a tree; neither bounds a walk
    /// against a slow app, where a single read can block for the full messaging
    /// timeout.
    ///
    /// **Calibrated 2026-09-10**, having shipped as a guess. Every legitimate
    /// walk measured that day, warm and cold:
    ///
    ///     Music 89.9 ms · Calendar 96.7 ms · Cursor 111.8 ms · Claude Desktop 123.1 ms
    ///     System Settings ~360 ms · Finder 785.8 ms · Mail 1,798.6 ms
    ///
    /// Five seconds is 2.8x the slowest of those. The asymmetry decides it: too
    /// long and a person waits at a blank screen, too short and the walk stops
    /// and *says* `.timeLimit`, which is a visible instruction to raise it.
    ///
    /// It does **not** protect against an app that has stopped answering
    /// entirely — measured the same day by SIGSTOPping an app, the pre-walk
    /// reads fail on the messaging timeout and the walk never begins.
    let deadline: Date

    private(set) var nodesVisited = 0
    private(set) var stopReasons: Set<WalkStopReason> = []

    /// Kept so callers that only ask "was this complete?" still work. Anything
    /// reporting the result should print `stopReasons` instead — "it stopped" and
    /// "it stopped because the app went unresponsive" are different facts.
    var wasTruncated: Bool { !stopReasons.isEmpty }

    init(maximumDepth: Int, maximumNodeCount: Int, timeLimitInSeconds: Double = 5.0) {
        self.maximumDepth = maximumDepth
        self.maximumNodeCount = maximumNodeCount
        self.deadline = Date().addingTimeInterval(timeLimitInSeconds)
    }

    /// Returns true if a node at this depth may be visited, spending one slot.
    /// Returns false and records *which* limit stopped it.
    mutating func claimSlot(atDepth depth: Int) -> Bool {
        guard depth < maximumDepth else {
            stopReasons.insert(.depthLimit)
            return false
        }
        guard nodesVisited < maximumNodeCount else {
            stopReasons.insert(.nodeLimit)
            return false
        }
        // Checked per node rather than per subtree: a walk that blows its budget
        // does so inside one slow read, and a coarser check would sail past the
        // deadline by exactly the amount we are trying to bound.
        guard Date() < deadline else {
            stopReasons.insert(.timeLimit)
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

    /// Which limits stopped the walk. Empty means it finished.
    let walkStopReasons: Set<WalkStopReason>
    let timedOutNodePaths: [String]
    let nodesWithoutReadableFrame: Int
    let subtreesLostToFailedReads: Int

    /// Subtrees we chose not to walk because their root sits far outside the
    /// window, and how many nodes that saved.
    ///
    /// This is a deliberate omission, not a failure, so it is reported the same
    /// way truncation is: a count, never a silent absence. Structure's whole
    /// claim over vision is knowing what exists off-screen — so we still say
    /// *that* something is there and how much of it, we just do not enumerate a
    /// message list to find one button.
    let subtreesSkippedFarOffScreen: Int
    let nodesSkippedFarOffScreen: Int

    /// Containers where we asked the app which children are visible and walked
    /// that window of them instead of all 18,004.
    ///
    /// Measured 2026-09-09: Mail's message list is one `AXTable` with 18,004
    /// children that publishes `AXVisibleRows` = 11. The whole walk was that one
    /// element. Reported separately from the off-screen skip because they answer
    /// different questions — that one prunes a subtree by its *root's* frame,
    /// this one prunes a container's *children* using the app's own answer.
    let containersReducedToVisibleChildren: Int
    let childrenElidedByVisibleSubset: Int

    /// Children skipped because that exact element was already in the tree.
    ///
    /// The Accessibility graph is not a tree. Measured 2026-09-09: Chrome
    /// publishes its whole tab strip under more than one parent, so a
    /// depth-first walk enumerated every toolbar button four times — and every
    /// one of them then resolved as ambiguous, which is why nothing in Chrome
    /// was addressable.
    let duplicateElementsSkipped: Int

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

    /// The screen is locked or the saver is up, so the frontmost application is
    /// `loginwindow` and there is nothing of the user's world to read.
    case screenIsLocked
}

/// Bundle identifiers that mean "there is no user session in front of you".
///
/// Measured 2026-09-10, and it cost four measurements in a row: the machine
/// locked itself mid-session and every walk after that returned **1 node,
/// 0 actionable, 42 bytes** with a **0-byte screenshot** and no error at all —
/// for Photos, for Mail, for Finder. Plausible-looking rows in a table, all
/// describing the lock screen. This is the fifth time this project has been
/// handed a successful read of a world that was not there.
enum LockScreenGuard {
    static let bundleIdentifiers: Set<String> = ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine"]

    static func isLockScreen(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifiers.contains(bundleIdentifier)
    }
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
        // All three fragments are app-written, so all three go through the
        // same escape-and-cap. A text area's AXValue is the entire document, and
        // a title containing a newline would forge a line in this dump — one
        // node, two lines, and the count that follows becomes fiction.
        let titleFragment = node.title.map { " " + $0.forDisplay } ?? ""
        let descriptionFragment = node.elementDescription.map { " desc=" + $0.forDisplay } ?? ""
        let valueFragment = node.value.map { " = " + $0.forDisplay } ?? ""
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
        maximumNodeCount: Int = 25_000
    ) throws -> AccessibilityWindowSnapshot {
        guard AXIsProcessTrusted() else {
            throw AccessibilitySnapshotError.accessibilityPermissionNotGranted
        }

        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            throw AccessibilitySnapshotError.noFrontmostApplication
        }

        // Refuse rather than describe the lock screen. A 1-node tree is a
        // believable number, and believable is exactly the problem.
        guard !LockScreenGuard.isLockScreen(frontmostApplication.bundleIdentifier) else {
            throw AccessibilitySnapshotError.screenIsLocked
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
        var subtreesSkippedFarOffScreen = 0
        var nodesSkippedFarOffScreen = 0
        var containersReducedToVisibleChildren = 0
        var childrenElidedByVisibleSubset = 0
        var duplicateElementsSkipped = 0
        var visitedElements: Set<AccessibilityElementKey> = [
            AccessibilityElementKey(element: focusedWindowElement)
        ]

        // How far off-screen still counts as reachable.
        //
        // Measured 2026-09-09: Mail's window shows 122 elements while the tree
        // holds 4,000 — 424 subtrees are rooted outside the window, carrying
        // 3,454 descendants. Those are message-list rows, an index rather than a
        // set of targets. But "Storage Settings…" sat 130 points below the fold
        // and WAS a target, so the boundary cannot be the window edge itself.
        // One window-height of margin on every side keeps anything a scroll or
        // two away inside the tree by construction rather than by luck.
        var windowFrameValue: CFTypeRef?
        AXUIElementCopyAttributeValue(focusedWindowElement, "AXFrame" as CFString, &windowFrameValue)
        var windowRect = CGRect.zero
        if let windowFrameValue, CFGetTypeID(windowFrameValue) == AXValueGetTypeID() {
            AXValueGetValue(windowFrameValue as! AXValue, .cgRect, &windowRect)
        }
        let reachableArea: CGRect? = windowRect.isEmpty
            ? nil
            : convertAccessibilityFrameToAppKitFrame(
                windowRect, primaryDisplayHeightInPoints: primaryDisplayHeightInPoints
              ).insetBy(dx: -windowRect.width, dy: -windowRect.height)

        let walkStartedAt = Date()
        let rootNode = buildNode(
            from: focusedWindowElement,
            depth: 0,
            primaryDisplayHeightInPoints: primaryDisplayHeightInPoints,
            budget: &budget,
            deepestLevelReached: &deepestLevelReached,
            timedOutNodePaths: &timedOutNodePaths,
            nodesWithoutReadableFrame: &nodesWithoutReadableFrame,
            subtreesLostToFailedReads: &subtreesLostToFailedReads,
            reachableArea: reachableArea,
            subtreesSkippedFarOffScreen: &subtreesSkippedFarOffScreen,
            nodesSkippedFarOffScreen: &nodesSkippedFarOffScreen,
            containersReducedToVisibleChildren: &containersReducedToVisibleChildren,
            childrenElidedByVisibleSubset: &childrenElidedByVisibleSubset,
            visitedElements: &visitedElements,
            duplicateElementsSkipped: &duplicateElementsSkipped
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
            walkStopReasons: budget.stopReasons,
            timedOutNodePaths: timedOutNodePaths,
            nodesWithoutReadableFrame: nodesWithoutReadableFrame,
            subtreesLostToFailedReads: subtreesLostToFailedReads,
            subtreesSkippedFarOffScreen: subtreesSkippedFarOffScreen,
            nodesSkippedFarOffScreen: nodesSkippedFarOffScreen,
            containersReducedToVisibleChildren: containersReducedToVisibleChildren,
            childrenElidedByVisibleSubset: childrenElidedByVisibleSubset,
            duplicateElementsSkipped: duplicateElementsSkipped,
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
        subtreesLostToFailedReads: inout Int,
        reachableArea: CGRect?,
        subtreesSkippedFarOffScreen: inout Int,
        nodesSkippedFarOffScreen: inout Int,
        containersReducedToVisibleChildren: inout Int,
        childrenElidedByVisibleSubset: inout Int,
        visitedElements: inout Set<AccessibilityElementKey>,
        duplicateElementsSkipped: inout Int
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

        // Stop descending when this node sits far outside the window. A
        // zero-area frame is NOT "outside" — it is the meaningless-value case,
        // and its children may still be real, so it is excluded from this test.
        let isFarOffScreen: Bool = {
            guard let reachableArea, depth > 0,
                  appKitFrame.width > 0, appKitFrame.height > 0 else { return false }
            return !appKitFrame.intersects(reachableArea)
        }()

        if isFarOffScreen, !childReadResult.children.isEmpty {
            subtreesSkippedFarOffScreen += 1
            nodesSkippedFarOffScreen += childReadResult.children.count
        }

        // Ask the app which children are on screen, rather than reading 18,004
        // frames to find out. See `visibleChildWindow`.
        var childrenToWalk = isFarOffScreen ? [] : childReadResult.children
        if !isFarOffScreen,
           let window = visibleChildWindow(of: element, children: childReadResult.children) {
            containersReducedToVisibleChildren += 1
            childrenElidedByVisibleSubset += childReadResult.children.count - window.count
            childrenToWalk = Array(childReadResult.children[window])
        }

        // Each element once, whichever path reaches it first. Filtered here
        // rather than at the top of the recursion because returning nil for a
        // duplicate would stop the sibling loop, which reads a repeated element
        // as an exhausted budget.
        let beforeDeduplication = childrenToWalk.count
        childrenToWalk = childrenToWalk.filter {
            visitedElements.insert(AccessibilityElementKey(element: $0)).inserted
        }
        duplicateElementsSkipped += beforeDeduplication - childrenToWalk.count

        for childElement in childrenToWalk {
            guard let childNode = buildNode(
                from: childElement,
                depth: depth + 1,
                primaryDisplayHeightInPoints: primaryDisplayHeightInPoints,
                budget: &budget,
                deepestLevelReached: &deepestLevelReached,
                timedOutNodePaths: &timedOutNodePaths,
                nodesWithoutReadableFrame: &nodesWithoutReadableFrame,
                subtreesLostToFailedReads: &subtreesLostToFailedReads,
                reachableArea: reachableArea,
                subtreesSkippedFarOffScreen: &subtreesSkippedFarOffScreen,
                nodesSkippedFarOffScreen: &nodesSkippedFarOffScreen,
                containersReducedToVisibleChildren: &containersReducedToVisibleChildren,
                childrenElidedByVisibleSubset: &childrenElidedByVisibleSubset,
                visitedElements: &visitedElements,
                duplicateElementsSkipped: &duplicateElementsSkipped
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

    /// The children worth walking in a container that knows which of its own
    /// children are on screen, or nil to walk them all.
    ///
    /// Measured 2026-09-09: Mail's message list is a single `AXTable` with
    /// **18,004 children** that answers `AXVisibleRows` with **11**. Reading
    /// every row's frame to discover that 17,993 of them are off-screen was the
    /// entire 18,496-node walk. The app already knows the answer; the old
    /// traversal simply never asked.
    ///
    /// The window is the visible run **plus one screenful either side**, which is
    /// the same rule the off-screen subtree skip already uses (one window-height
    /// of margin). A target one scroll away stays in the tree; a message list
    /// stops being enumerated.
    ///
    /// Returns nil unless the saving is real: the extra attribute read costs one
    /// IPC round trip, so it is only worth asking on containers big enough to pay
    /// for it. Chromium publishes none of these attributes, so Electron apps take
    /// this path zero times and are unaffected.
    static let visibleChildAttributes = ["AXVisibleRows", "AXVisibleChildren", "AXVisibleCells"]
    static let minimumChildrenToAskForVisibleSubset = 50

    static func visibleChildWindow(
        of element: AXUIElement,
        children: [AXUIElement]
    ) -> Range<Int>? {
        guard children.count >= minimumChildrenToAskForVisibleSubset else { return nil }

        var visible: [AXUIElement] = []
        for attribute in visibleChildAttributes {
            var out: AnyObject?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success,
                  let elements = out as? [AXUIElement], !elements.isEmpty else { continue }
            visible = elements
            break
        }
        guard !visible.isEmpty, visible.count < children.count else { return nil }

        // Element identity is CFEqual, not ==. This is all local: no IPC, so the
        // nested loop costs nothing next to a single cross-process read.
        var firstVisible: Int?
        var lastVisible: Int?
        for (index, child) in children.enumerated()
        where visible.contains(where: { CFEqual($0, child) }) {
            if firstVisible == nil { firstVisible = index }
            lastVisible = index
        }

        // The app named children we cannot find in its own children list. Trust
        // the list we have and walk everything rather than guess a range.
        guard let firstVisible, let lastVisible else { return nil }

        return visibleWindowRange(
            firstVisible: firstVisible,
            lastVisible: lastVisible,
            visibleCount: visible.count,
            childCount: children.count
        )
    }

    /// The index arithmetic, separated from the cross-process read so it can be
    /// tested: margin either side, clamped to the array, and nil when the window
    /// would cover everything anyway.
    static func visibleWindowRange(
        firstVisible: Int,
        lastVisible: Int,
        visibleCount: Int,
        childCount: Int
    ) -> Range<Int>? {
        let margin = visibleCount
        let lower = max(0, firstVisible - margin)
        let upper = min(childCount, lastVisible + 1 + margin)
        guard upper > lower, upper - lower < childCount else { return nil }
        return lower..<upper
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
