//
//  AccessibilityWindows.swift
//  leanring-buddy
//
//  Which window the harness is looking at, and how to make it a different one.
//
//  Everything else in this project anchors on
//  `NSWorkspace.shared.frontmostApplication` — `snapshotFocusedWindow`,
//  `menuBarNode(for:)`, the audit line's `app` field. That is the right default
//  and a useless ceiling: the harness can only ever act on whatever the human
//  happened to leave in front. These two verbs are the aim, one tier up from
//  the element aim `ElementActionIntentResolver` already does. `windows` says
//  what could be looked at; `focus` moves the anchor.
//
//  Shaped exactly like `AccessibilityMenu`: a pure resolver over a small value
//  type (so a test can reach it without an `AXUIElement`), a `Resolution` enum
//  that carries what WAS there on a miss, and a performer that does the live
//  reads. The one thing that is *not* like the menu: an application list is
//  free. `NSWorkspace` already knows every running app, so `windows` answers
//  "what could I focus" with no AX reads at all, and pays for AX only on the
//  app whose windows were asked for.
//

import AppKit
import ApplicationServices
import Foundation

enum AccessibilityWindows {

    /// How long to wait for a Space switch to make an app's windows readable.
    /// The switch is animated, so this is bounded by the animation, not by IPC.
    static let spaceSwitchDeadlineInSeconds: TimeInterval = 2.0

    /// Same rule as every other read path here: an AX read is synchronous
    /// cross-process IPC and a busy app would otherwise block this process.
    static let messagingTimeoutInSeconds: Float = 0.5

    static let minimizedAttribute = kAXMinimizedAttribute as String
    static let mainAttribute = kAXMainAttribute as String
    static let frameAttribute = "AXFrame"

    /// How long `focus` will wait for the world to agree that it worked, and how
    /// often it asks. The deadline is hard — an app that never comes forward is
    /// a `notObserved`, never a hang.
    static let observationDeadlineInSeconds = 2.0
    static let observationPollIntervalInMicroseconds: UInt32 = 50_000

    // MARK: - Application resolution (pure)

    /// One running application, flattened to what a resolution needs. Built
    /// from `NSRunningApplication` at the boundary so the matching below is
    /// reachable from a test.
    struct ApplicationCandidate: Equatable {
        let bundleIdentifier: String?
        let localizedName: String?
        let isActive: Bool
        let isHidden: Bool

        init(bundleIdentifier: String?, localizedName: String?, isActive: Bool = false, isHidden: Bool = false) {
            self.bundleIdentifier = bundleIdentifier
            self.localizedName = localizedName
            self.isActive = isActive
            self.isHidden = isHidden
        }
    }

    /// Which field the query matched on. Reported, because "Finder matched a
    /// bundle id" and "Finder matched a name prefix" are different amounts of
    /// confidence and the caller is entitled to know which it got.
    enum ApplicationMatchTier: String, Equatable, CaseIterable {
        case bundleIdentifier
        case name
        case namePrefix
    }

    enum ApplicationResolution: Equatable {
        case resolved(index: Int, tier: ApplicationMatchTier)
        /// What WAS running, which is the half that makes a miss actionable.
        case notFound(available: [String])
        case ambiguous(matchCount: Int, tier: ApplicationMatchTier)
    }

    /// Bundle id beats name beats prefix, and the FIRST tier that matches
    /// anything is the answer.
    ///
    /// Tiering rather than one merged candidate set, because the merge is what
    /// makes a precise query ambiguous: `"Mail"` names exactly one app and is
    /// also a prefix of "MailMate". Falling through to the prefix tier only
    /// when the exact tiers found nothing means an exact name can never be
    /// out-voted by something that merely starts the same way. Two matches
    /// inside the chosen tier is still a question — never a coin flip, same
    /// rule as every other resolver here.
    static func matchApplication(
        _ query: String,
        among candidates: [ApplicationCandidate]
    ) -> ApplicationResolution {
        let wanted = query.lowercased()

        let tiers: [(ApplicationMatchTier, (ApplicationCandidate) -> Bool)] = [
            (.bundleIdentifier, { $0.bundleIdentifier?.lowercased() == wanted }),
            (.name, { $0.localizedName?.lowercased() == wanted }),
            (.namePrefix, { $0.localizedName?.lowercased().hasPrefix(wanted) ?? false })
        ]

        for (tier, matches) in tiers {
            let indices = candidates.indices.filter { matches(candidates[$0]) }
            switch indices.count {
            case 0: continue
            case 1: return .resolved(index: indices[0], tier: tier)
            default: return .ambiguous(matchCount: indices.count, tier: tier)
            }
        }
        return .notFound(available: candidates.compactMap(\.localizedName).sorted())
    }

    // MARK: - Window resolution (pure)

    /// One window, flattened. `title` is app-written, so it arrives labelled —
    /// `.raw` compares, `.forDisplay` prints.
    struct WindowCandidate: Equatable {
        let title: UntrustedText?
        let role: String
        let subrole: String?
        let isMain: Bool
        let isMinimized: Bool
        /// AppKit coordinates. Converted at the boundary in `liveWindows`,
        /// because `nearPoint` arrives from a caller in AppKit and comparing a
        /// point in one origin against a frame in the other is silent.
        let frameInAppKitCoordinates: CGRect
        let publishedActionNames: [String]

        init(
            title: String?,
            role: String = "AXWindow",
            subrole: String? = nil,
            isMain: Bool = false,
            isMinimized: Bool = false,
            frameInAppKitCoordinates: CGRect = .zero,
            publishedActionNames: [String] = []
        ) {
            self.title = title.map(UntrustedText.init)
            self.role = role
            self.subrole = subrole
            self.isMain = isMain
            self.isMinimized = isMinimized
            self.frameInAppKitCoordinates = frameInAppKitCoordinates
            self.publishedActionNames = publishedActionNames
        }
    }

    enum WindowResolution: Equatable {
        case resolved(index: Int)
        case notFound(available: [String])
        case ambiguous(matchCount: Int)
    }

    /// Exact title first, then substring, then — only if that still leaves more
    /// than one — the point.
    ///
    /// A substring tier exists because window titles are decorated by the app
    /// ("Documents — 41 items", "index.swift — Clicky") and a caller naming the
    /// document should not have to guess the decoration. It is a second tier
    /// and not a merged one for the same reason the application tiers are
    /// separate: an exact title must never lose to a longer title that contains
    /// it.
    ///
    /// `nearPoint` narrows only by *containment*, and only when containment
    /// leaves exactly one. Never "nearest" — nearest always returns something,
    /// and something is what a wrong window raised looks like.
    static func matchWindow(
        title: String,
        nearPoint: CGPoint?,
        among candidates: [WindowCandidate]
    ) -> WindowResolution {
        let wanted = title.lowercased()

        var indices = candidates.indices.filter { candidates[$0].title?.raw.lowercased() == wanted }
        if indices.isEmpty {
            indices = candidates.indices.filter {
                candidates[$0].title?.raw.lowercased().contains(wanted) ?? false
            }
        }

        switch indices.count {
        case 0:
            return .notFound(available: candidates.compactMap { $0.title?.raw })
        case 1:
            return .resolved(index: indices[0])
        default:
            if let nearPoint {
                let containing = indices.filter {
                    candidates[$0].frameInAppKitCoordinates.contains(nearPoint)
                }
                if containing.count == 1 { return .resolved(index: containing[0]) }
            }
            // The count reported is the count a human would have to
            // disambiguate, not what survived a filter that did not decide.
            return .ambiguous(matchCount: indices.count)
        }
    }

    // MARK: - The live reads

    /// Every regular application currently running.
    ///
    /// `.regular` only: agents and UI-element apps (Clicky itself among them)
    /// have no windows to focus and would only pad the list a caller reads to
    /// find out what it could ask for. The lock screen is excluded by the same
    /// guard the walker uses — `loginwindow` is a regular app with a believable,
    /// wrong answer.
    static func runningApplications() -> [(application: NSRunningApplication, candidate: ApplicationCandidate)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { !LockScreenGuard.isLockScreen($0.bundleIdentifier) }
            .map { application in
                (application, ApplicationCandidate(
                    bundleIdentifier: application.bundleIdentifier,
                    localizedName: application.localizedName,
                    isActive: application.isActive,
                    isHidden: application.isHidden
                ))
            }
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    /// `kAXWindows` off the application element, each window flattened.
    ///
    /// The element handle travels beside the value type so the performer can act
    /// on the resolved one without a second lookup — the same split as
    /// `AccessibilityMenu.Node.element`.
    /// What `kAXWindows` answered, and — separately — whether it answered at all.
    ///
    /// The list and the error are two facts, and collapsing them is a defect
    /// this project has already paid for once: `copyChildElements` returning
    /// `[]` for both "no children" and "the read failed" reported a shallow app
    /// and dropped a whole subtree. Measured 2026-09-10 the moment this verb
    /// first ran: Xcode, Cursor, Chrome and TextEdit each came back **0 windows
    /// with `ok: true`** while plainly having windows open. Zero is a believable
    /// number, which is exactly why it has to carry its own evidence.
    struct WindowRead {
        var windows: [(element: AXUIElement, candidate: WindowCandidate)] = []
        /// `.success` with an empty list means the app really has no windows.
        /// Anything else means we do not know.
        var error: AXError = .success
        var readSucceeded: Bool { error == .success }
    }

    static func liveWindows(for application: NSRunningApplication) -> WindowRead {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeoutInSeconds)

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(
            applicationElement, kAXWindowsAttribute as CFString, &value
        )
        guard error == .success, let windows = value as? [AXUIElement] else {
            // `kAXErrorNoValue` and `kAXErrorAttributeUnsupported` are the app
            // saying "genuinely nothing"; every other code is a failure to read
            // and must not be laundered into an empty list.
            let genuinelyEmpty = (error == .noValue || error == .attributeUnsupported)
            return WindowRead(windows: [], error: genuinelyEmpty ? .success : error)
        }
        let primaryDisplayHeight = NSScreen.screens.first?.frame.height ?? 0

        let candidates = windows.map { window in
            var accessibilityFrame = CGRect.zero
            if let frameValue = copyValue(window, frameAttribute),
               CFGetTypeID(frameValue) == AXValueGetTypeID() {
                var rect = CGRect.zero
                if AXValueGetValue(frameValue as! AXValue, .cgRect, &rect) { accessibilityFrame = rect }
            }

            let title = copyValue(window, kAXTitleAttribute as String) as? String
            return (window, WindowCandidate(
                title: (title?.isEmpty == false) ? title : nil,
                role: (copyValue(window, kAXRoleAttribute as String) as? String) ?? "AXUnknown",
                subrole: copyValue(window, kAXSubroleAttribute as String) as? String,
                isMain: (copyValue(window, mainAttribute) as? Bool) ?? false,
                isMinimized: (copyValue(window, minimizedAttribute) as? Bool) ?? false,
                // AX answers in top-left origin, AppKit reads bottom-left. This
                // is the boundary, and skipping it mirrors every frame
                // vertically without raising a thing.
                frameInAppKitCoordinates: AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(
                    accessibilityFrame, primaryDisplayHeightInPoints: primaryDisplayHeight
                ),
                publishedActionNames: AccessibilityTreeWalker.copyActionNames(from: window)
            ))
        }
        return WindowRead(windows: candidates, error: .success)
    }

    /// Bring the app forward and wait for its window list to become readable.
    ///
    /// Measured 2026-09-10, and it is the seventh instance of this project's
    /// signature failure — a successful read of a meaningless value:
    ///
    ///     app     backgrounded   frontmost
    ///     Xcode        0             2
    ///     Cursor       0             1
    ///     Chrome       0             3
    ///     TextEdit     0             0     (control: really has no window)
    ///
    /// every one of them `AXError 0`. **`kAXWindows` is Space-scoped.** An app
    /// whose windows live on another macOS Space reports an empty list until
    /// that Space is active, and a user who keeps apps full-screen has almost
    /// every window in that state — confirmed by an independent witness,
    /// `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`, which saw 2 windows
    /// for the frontmost app and **0 for all seven others**. The exceptions,
    /// also measured: a *minimized* window (Mail) and Finder's desktop are
    /// listed from anywhere.
    ///
    /// So a window cannot be resolved by name until its app is in front. That
    /// is not a workaround; it is the order the OS imposes, and pretending
    /// otherwise reports `notFound` for a window that is simply elsewhere.
    static func activateAndWaitForWindows(
        _ application: NSRunningApplication
    ) -> (activated: Bool, read: WindowRead, milliseconds: Int) {
        let startedAt = Date()
        let activated = application.activate()
        let deadline = startedAt.addingTimeInterval(spaceSwitchDeadlineInSeconds)
        var read = liveWindows(for: application)
        while read.windows.isEmpty, Date() < deadline {
            usleep(observationPollIntervalInMicroseconds)
            read = liveWindows(for: application)
        }
        return (activated, read, Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    // MARK: - The focus operation

    /// Every step's outcome, kept separate.
    ///
    /// Three tiers of evidence, because each one alone has lied in this project:
    /// `AXError` was `.success` on writes that did nothing, and a read-back has
    /// been both false after a write that worked and true after one that did
    /// not. `observed` is the tier that tracks reality — it asks the OS who is
    /// frontmost rather than asking the app about itself.
    struct FocusOutcome {
        /// A minimized window cannot be raised, so this happens first when it
        /// happens at all.
        var unminimized = false
        var unminimizeErrorRawValue: Int32?

        /// Whether the window published `AXRaise` at all. False is a real
        /// answer, not a failure: activating the app alone is a partial result
        /// and saying so is more useful than performing an action the window
        /// never offered.
        var raisePublished = false
        var raiseErrorRawValue: Int32?
        var raiseMilliseconds: Int?

        var activated = false

        // Tier 2 and 3.
        var readBackMain: Bool?
        var observed = false
        var observedMilliseconds = 0
        var observedApplication: String?
        var observedWindowTitle: UntrustedText?
    }

    /// The frontmost app before anything moves — how the human undoes this.
    ///
    /// Focus is the one verb with a trivial inverse, and the inverse is only
    /// trivial if you know what it was.
    static func previousApplication() -> (name: String?, bundleIdentifier: String?)? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return (application.localizedName, application.bundleIdentifier)
    }

    /// Raise the window if there is one, activate the app, then go and look.
    ///
    /// `window` nil means "activate the app, whatever it has in front" — a
    /// legitimate ask and the reason `focus` accepts an app with no title.
    static func focus(
        application: NSRunningApplication,
        window: (element: AXUIElement, candidate: WindowCandidate)?
    ) -> FocusOutcome {
        var outcome = FocusOutcome()

        if let window {
            if window.candidate.isMinimized {
                let error = AXUIElementSetAttributeValue(
                    window.element, minimizedAttribute as CFString, kCFBooleanFalse
                )
                outcome.unminimized = error == .success
                outcome.unminimizeErrorRawValue = error.rawValue
            }

            // Ask the window what it publishes. A role is a convention and so
            // is an action name — `AXRaise` is a string an app chose to offer,
            // and performing one that was never offered is how -25206 gets
            // reported as a mystery.
            outcome.raisePublished = window.candidate.publishedActionNames.contains(kAXRaiseAction as String)
            if outcome.raisePublished {
                // Through the performer, which raises the timeout on this one
                // element first: a raise animates, and the read path's 0.5 s is
                // what turns a working action into -25204.
                let result = AccessibilityActionPerformer.perform(kAXRaiseAction as String, on: window.element)
                outcome.raiseErrorRawValue = result.error.rawValue
                outcome.raiseMilliseconds = result.milliseconds
            }
        }

        // Not `activate(options: .activateIgnoringOtherApps)` — deprecated on
        // the macOS 14 target, and the plain call is what the OS wants now.
        outcome.activated = application.activate()

        // Tier 2: ask the window about itself.
        if let window {
            outcome.readBackMain = copyValue(window.element, mainAttribute) as? Bool
        }

        // Tier 3: ask the OS, on a hard deadline.
        //
        // The window half compares **element identity**, not the title. Two
        // windows in one app can carry the same title — that is the exact case
        // `nearPoint` exists to disambiguate — and a title comparison would then
        // report `observed: true` for the wrong window coming forward. That is
        // this project's recurring failure: a read that succeeds and describes a
        // world that is not there. `AccessibilityElementKey` already wraps
        // CFEqual/CFHash for the walker's deduplication; it answers this
        // question too, and the title stays in the response for a human to read.
        let wantedProcessIdentifier = application.processIdentifier
        let wantedWindow = window.map { AccessibilityElementKey(element: $0.element) }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(observationDeadlineInSeconds)

        repeat {
            // Ask **Accessibility** who is focused, not `NSWorkspace`.
            //
            // Measured 2026-09-10, and it is the run-loop trap this project
            // already documents for AX events, in a new place. Requests execute
            // via `DispatchQueue.main.sync`, so a poll loop here **blocks the
            // main thread**. `NSWorkspace.shared.frontmostApplication` is a
            // cache refreshed by a notification delivered on that run loop, so
            // it can never change while we are looking at it: every `focus` in
            // the first live run reported `observed: false` after burning the
            // full 2,035 ms deadline, while the app had plainly come forward.
            //
            // Pumping the run loop would fix the staleness and introduce
            // re-entrancy — a second socket request could land inside this one.
            // A system-wide AX read is a live cross-process query that needs no
            // run loop at all, so it is both correct and cheaper.
            var focusedApplication: AXUIElement?
            if let value = copyValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as String),
               CFGetTypeID(value) == AXUIElementGetTypeID() {
                focusedApplication = (value as! AXUIElement)
            }
            var focusedProcessIdentifier: pid_t = -1
            if let focusedApplication {
                AXUIElementGetPid(focusedApplication, &focusedProcessIdentifier)
            }
            outcome.observedApplication = NSRunningApplication(
                processIdentifier: focusedProcessIdentifier
            )?.localizedName

            var focusedWindow: AccessibilityElementKey?
            if let focused = copyValue(applicationElement, kAXFocusedWindowAttribute as String),
               CFGetTypeID(focused) == AXUIElementGetTypeID() {
                let element = focused as! AXUIElement
                focusedWindow = AccessibilityElementKey(element: element)
                outcome.observedWindowTitle = (copyValue(element, kAXTitleAttribute as String) as? String)
                    .map(UntrustedText.init)
            } else {
                outcome.observedWindowTitle = nil
            }

            let applicationMatches = focusedProcessIdentifier == wantedProcessIdentifier
            let windowMatches = wantedWindow == nil || focusedWindow == wantedWindow
            if applicationMatches && windowMatches {
                outcome.observed = true
                break
            }
            usleep(observationPollIntervalInMicroseconds)
        } while Date() < deadline

        outcome.observedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
        return outcome
    }
}
