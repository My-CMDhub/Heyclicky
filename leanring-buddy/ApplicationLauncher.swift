//
//  ApplicationLauncher.swift
//  leanring-buddy
//
//  The `launch` verb's machine half: resolve an INSTALLED application by
//  identity, start it, and wait until the app itself says it is in front.
//
//  Why this exists: the harness could not start an app, so planner tests ran
//  `open` from outside it — unaudited and unguarded — and `focus` answers
//  `notFound` for an app that is not running.
//

import AppKit
import ApplicationServices
import Foundation

enum ApplicationLauncher {

    /// ~3.2x the slowest cold readiness measured 2026-09-11 (System Settings,
    /// 1,547 ms) — the same calibration rule as the walk deadline.
    static let launchReadinessDeadlineInSeconds: TimeInterval = 5.0
    static let pollIntervalInMicroseconds: useconds_t = 100_000
    static let messagingTimeoutInSeconds: Float = 0.5

    /// Where a name may resolve. Never a path, never a document — a path can
    /// name a script or an installer, which is what "opening always asks" is for.
    static var searchDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    // MARK: - Resolution

    /// Every `<name>.app` in `directories`, exact and case-insensitive. No
    /// prefix, nothing fuzzy. More than one result is two apps, not a
    /// first-wins guess — the caller refuses it as ambiguous.
    static func matchApplications(
        named name: String,
        in directories: [URL],
        listing: (URL) -> [String]
    ) -> [URL] {
        let wanted = name + ".app"
        return directories.flatMap { directory in
            listing(directory)
                .filter { $0.caseInsensitiveCompare(wanted) == .orderedSame }
                .map { directory.appendingPathComponent($0, isDirectory: true) }
        }
    }

    enum Resolution {
        case resolved(url: URL, bundleIdentifier: String)
        case notFound
        case ambiguous([URL])
    }

    /// By bundle identifier and by exact name, together: a query that names two
    /// different bundles one each way is ambiguous, not whichever was asked first.
    /// Exact, case-insensitive name matches among running applications. Pure, so
    /// "a prefix never matches" is a test rather than a hope.
    static func runningMatches(named query: String, among running: [(name: String?, bundleURL: URL?)]) -> [URL] {
        running.compactMap { entry in
            guard let name = entry.name, let url = entry.bundleURL,
                  name.caseInsensitiveCompare(query) == .orderedSame else { return nil }
            return url
        }
    }

    static func resolve(_ query: String) -> Resolution {
        var candidates = matchApplications(named: query, in: searchDirectories) {
            (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []
        }
        if let byIdentifier = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) {
            candidates.append(byIdentifier)
        }
        // A name also reaches an app that is already running with a Dock
        // presence. Measured 2026-09-11: `launch "Finder"` came back notFound —
        // Finder lives in /System/Library/CoreServices, which is deliberately not
        // searched because it also holds loginwindow, the Dock and SystemUIServer.
        // Running regular apps add nothing a person could not already see.
        candidates += runningMatches(named: query, among: AccessibilityWindows.runningApplications().map {
            (name: $0.application.localizedName, bundleURL: $0.application.bundleURL)
        })
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }

        guard !unique.isEmpty else { return .notFound }
        guard unique.count == 1, let url = unique.first else { return .ambiguous(unique) }
        // The kernel decides on the bundle's OWN identifier, never the query.
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else {
            return .notFound
        }
        return .resolved(url: url, bundleIdentifier: bundleIdentifier)
    }

    // MARK: - Readiness (pure)

    /// One poll of the launched app, read from the app element itself.
    ///
    /// Measured 2026-09-11: a launching app answers `AXFrontmost` with -25204
    /// ("not answering yet") before it answers `true`. The system-wide
    /// `kAXFocusedApplication` read returned -25212 with Claude Desktop in front
    /// and -25204 for ~1.3 s during a launch, and `isFinishedLaunching` lagged a
    /// readable window by 500 ms — neither is used.
    struct ReadinessSample: Equatable {
        var frontmost: Bool?
        var frontmostError: Int32?
        var window: Bool
        var windowError: Int32? = nil
    }

    enum LaunchStatus: String {
        case ready
        /// Came forward, no window by the deadline. Some apps are windowless.
        case frontmostNoWindow
        /// Never came forward by the deadline.
        case notReady
    }

    /// An error is "not answering yet", never "no".
    static func isFrontmost(_ sample: ReadinessSample) -> Bool {
        sample.frontmostError == nil && sample.frontmost == true
    }

    /// nil means keep polling. At the deadline it always answers.
    /// A readable window without frontmost is still `notReady`: that is an app
    /// that launched behind something, and a planner acting "in front" would miss.
    static func status(frontmostSeen: Bool, windowSeen: Bool, deadlinePassed: Bool) -> LaunchStatus? {
        if frontmostSeen, windowSeen { return .ready }
        guard deadlinePassed else { return nil }
        return frontmostSeen ? .frontmostNoWindow : .notReady
    }

    // MARK: - Perform

    /// Every millisecond figure is measured from the moment `openApplication`
    /// was called, so the numbers line up with the calibration table.
    struct LaunchOutcome {
        /// Set when no process came back at all; the readiness fields are then empty.
        var launchError: String?
        var processMilliseconds: Int?
        var frontmostMilliseconds: Int?
        var windowMilliseconds: Int?
        var lastFrontmostError: Int32?
        var lastWindowError: Int32?
        var status: LaunchStatus = .notReady
    }

    /// Box for the completion handler's result across the blocking wait.
    private final class LaunchBox: @unchecked Sendable {
        var application: NSRunningApplication?
        var error: Error?
    }

    /// Blocks the calling thread (the main thread, inside `DispatchQueue.main.sync`)
    /// for up to the deadline plus one poll's reads.
    ///
    /// The completion handler is called on a background queue, so waiting on a
    /// semaphore here cannot deadlock it. If a future SDK delivers it via the
    /// main queue instead, this returns `launchError` at the deadline rather
    /// than wedging the harness — the same bound `captureSynchronously` keeps.
    static func launchAndWait(_ url: URL) -> LaunchOutcome {
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(launchReadinessDeadlineInSeconds)
        func elapsed() -> Int { Int(Date().timeIntervalSince(startedAt) * 1000) }

        var outcome = LaunchOutcome()
        let box = LaunchBox()
        let semaphore = DispatchSemaphore(value: 0)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        // Called for an app that is already running too — that is what activates it.
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            box.application = application
            box.error = error
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + launchReadinessDeadlineInSeconds) == .success else {
            outcome.launchError = "openApplication did not call back within \(launchReadinessDeadlineInSeconds) s"
            return outcome
        }
        guard let application = box.application else {
            outcome.launchError = box.error.map { String(describing: $0) }
                ?? "openApplication returned neither an application nor an error"
            return outcome
        }
        outcome.processMilliseconds = elapsed()

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, messagingTimeoutInSeconds)

        while true {
            let sample = readSample(
                applicationElement,
                readFrontmost: outcome.frontmostMilliseconds == nil,
                readWindow: outcome.windowMilliseconds == nil
            )
            if let code = sample.frontmostError { outcome.lastFrontmostError = code }
            if let code = sample.windowError { outcome.lastWindowError = code }
            if outcome.frontmostMilliseconds == nil, isFrontmost(sample) { outcome.frontmostMilliseconds = elapsed() }
            if outcome.windowMilliseconds == nil, sample.window { outcome.windowMilliseconds = elapsed() }

            if let status = status(
                frontmostSeen: outcome.frontmostMilliseconds != nil,
                windowSeen: outcome.windowMilliseconds != nil,
                deadlinePassed: Date() >= deadline
            ) {
                outcome.status = status
                return outcome
            }
            usleep(pollIntervalInMicroseconds)
        }
    }

    /// Only the reads still needed. A read already answered is not repeated —
    /// each one can cost the full messaging timeout against a busy launch.
    private static func readSample(
        _ element: AXUIElement,
        readFrontmost: Bool,
        readWindow: Bool
    ) -> ReadinessSample {
        var sample = ReadinessSample(frontmost: nil, frontmostError: nil, window: false)

        if readFrontmost {
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(element, kAXFrontmostAttribute as CFString, &value)
            if error == .success { sample.frontmost = value as? Bool } else { sample.frontmostError = error.rawValue }
        }

        if readWindow {
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value)
            if error == .success, value != nil {
                sample.window = true
            } else {
                sample.windowError = error.rawValue
                // -25204 means the app is not answering; a kAXWindows read would
                // only spend another timeout finding that out.
                if error != .cannotComplete {
                    var windows: AnyObject?
                    if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
                       let list = windows as? [AXUIElement], !list.isEmpty {
                        sample.window = true
                    }
                }
            }
        }
        return sample
    }
}
