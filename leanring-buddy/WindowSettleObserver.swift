//
//  WindowSettleObserver.swift
//  leanring-buddy
//
//  Waiting for an app to finish moving, without paying for a tree walk to
//  find out.
//
//  ActionVerifier polls: it re-walks the whole window every 150 ms and asks
//  "has it changed yet?". Measured 2026-09-08, that clock is set by our sensor
//  rather than by the app — System Settings costs 361 ms per walk, so a
//  "3 s / 150 ms" budget buys about six polls, and Mail costs 27,134 ms, so the
//  loop body runs exactly once and returns 27 s later having ignored the
//  timeout entirely.
//
//  AXObserver inverts it. The app tells *us* when something moved, over the
//  same accessibility channel, and we spend zero walks while waiting. What it
//  cannot tell us is whether an app posts anything at all — silence and
//  stillness look identical from here — so the grace period below falls back
//  to the poll rather than believing a quiet app is a settled one.
//

import ApplicationServices
import Foundation

/// The evidence from one wait, not just whether it succeeded.
struct SettleReport {
    let settled: Bool
    let millisecondsToFirstNotification: Int?
    let millisecondsToQuiet: Int
    let notificationCount: Int
    let notificationsByName: [String: Int]
    let acceptedNotificationNames: [String]
    let refusedNotificationNames: [String]
    let fellBackToPolling: Bool
    let pollCount: Int
    /// Why the wait ended, in the words the operator needs to read.
    let outcomeDescription: String
}

/// The debounce rule, with no AX in it, so it can be tested.
///
/// Settled means "quiet for `quietPeriod` since the LAST notification", never
/// "a notification arrived". One pane animating in fires a burst; first arrival
/// is the start of the change, not the end of it.
struct SettleClock {
    enum Verdict: Equatable {
        case keepWaiting
        /// Quiet since this timestamp; the wait is over.
        case settled(quietSinceSeconds: Double)
        /// Nothing arrived within the grace period — the observer told us
        /// nothing, which is not the same as the app being still.
        case noNotificationsArrived
        case hitCeiling
    }

    let quietPeriodInSeconds: Double
    let gracePeriodInSeconds: Double
    let ceilingInSeconds: Double

    private(set) var eventCount = 0
    private(set) var firstEventAtSeconds: Double?
    private(set) var lastEventAtSeconds: Double?
    private(set) var eventCountsByName: [String: Int] = [:]

    init(
        quietPeriodInSeconds: Double = 0.25,
        gracePeriodInSeconds: Double = 0.4,
        ceilingInSeconds: Double = 3.0
    ) {
        self.quietPeriodInSeconds = quietPeriodInSeconds
        self.gracePeriodInSeconds = gracePeriodInSeconds
        self.ceilingInSeconds = ceilingInSeconds
    }

    mutating func recordEvent(named name: String, atSeconds timestamp: Double) {
        eventCount += 1
        eventCountsByName[name, default: 0] += 1
        if firstEventAtSeconds == nil { firstEventAtSeconds = timestamp }
        lastEventAtSeconds = max(lastEventAtSeconds ?? timestamp, timestamp)
    }

    func verdict(atSeconds now: Double) -> Verdict {
        guard let lastEventAtSeconds else {
            return now >= gracePeriodInSeconds ? .noNotificationsArrived : .keepWaiting
        }

        // Quiet wins over the ceiling: an app that goes still at exactly the
        // budget has settled, not timed out.
        if now - lastEventAtSeconds >= quietPeriodInSeconds {
            return .settled(quietSinceSeconds: lastEventAtSeconds)
        }
        return now >= ceilingInSeconds ? .hitCeiling : .keepWaiting
    }
}

/// Collects notifications from the C callback, which cannot capture Swift
/// context and so receives this object's address through `refcon`.
private final class SettleNotificationBox {
    private(set) var events: [(name: String, atSeconds: Double)] = []
    private let startedAt = Date()

    func append(name: String) {
        events.append((name, Date().timeIntervalSince(startedAt)))
    }
}

/// The `AXObserverCallback` itself. It must be a free function: a Swift closure
/// that captured anything could not be converted to a C function pointer.
private func windowSettleNotificationReceived(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notificationName: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    Unmanaged<SettleNotificationBox>.fromOpaque(refcon)
        .takeUnretainedValue()
        .append(name: notificationName as String)
}

enum WindowSettleObserver {

    /// Notifications are per-process; there is no system-wide observer.
    /// An app may refuse any of these with `kAXErrorNotificationUnsupported`,
    /// which is a fact about the app, not a failure of ours.
    static let requestedNotificationNames: [String] = [
        kAXWindowCreatedNotification,
        kAXFocusedUIElementChangedNotification,
        kAXLayoutChangedNotification,
        kAXValueChangedNotification,
        kAXUIElementDestroyedNotification
    ]

    /// Waits until the target process stops posting accessibility notifications.
    ///
    /// Must be called on the main thread. The observer delivers through a
    /// run-loop source, so something has to be *running* the run loop — this
    /// spins it in short slices rather than sleeping, which is the difference
    /// between a correctly registered observer and one that never fires.
    ///
    /// `pollFallback` is the escape hatch for an app that posts nothing: it is
    /// invoked only in that case, and reports whether it saw the world change
    /// and how many tree walks that cost.
    @MainActor
    static func waitForSettle(
        processIdentifier: pid_t,
        quietPeriodInSeconds: Double = 0.25,
        observerGracePeriodInSeconds: Double = 0.4,
        ceilingInSeconds: Double = 3.0,
        performWhileArmed: (() -> Void)? = nil,
        pollFallback: (() -> (settled: Bool, pollCount: Int))? = nil
    ) -> SettleReport {
        var clock = SettleClock(
            quietPeriodInSeconds: quietPeriodInSeconds,
            gracePeriodInSeconds: observerGracePeriodInSeconds,
            ceilingInSeconds: ceilingInSeconds
        )

        var observerHandle: AXObserver?
        let createResult = AXObserverCreate(
            processIdentifier,
            windowSettleNotificationReceived,
            &observerHandle
        )
        guard createResult == .success, let observer = observerHandle else {
            // No observer, but the action must still happen — otherwise a failed
            // registration silently turns the whole task into a no-op.
            performWhileArmed?()
            let fallback = pollFallback?() ?? (settled: false, pollCount: 0)
            return SettleReport(
                settled: fallback.settled,
                millisecondsToFirstNotification: nil,
                millisecondsToQuiet: 0,
                notificationCount: 0,
                notificationsByName: [:],
                acceptedNotificationNames: [],
                refusedNotificationNames: requestedNotificationNames,
                fellBackToPolling: true,
                pollCount: fallback.pollCount,
                outcomeDescription: "AXObserverCreate failed (AXError \(createResult.rawValue)) — polled instead"
            )
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let box = SettleNotificationBox()
        let refcon = Unmanaged.passUnretained(box).toOpaque()

        var acceptedNames: [String] = []
        var refusedNames: [String] = []
        for name in requestedNotificationNames {
            let addResult = AXObserverAddNotification(
                observer,
                applicationElement,
                name as CFString,
                refcon
            )
            if addResult == .success {
                acceptedNames.append(name)
            } else {
                refusedNames.append("\(name)(AXError \(addResult.rawValue))")
            }
        }

        let runLoopSource = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        // Every exit path below — settled, ceiling, fallback — comes through
        // here. A run-loop source left attached to a dead observer is a real
        // leak, and the app keeps posting into it for the rest of the session.
        defer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            for name in acceptedNames {
                AXObserverRemoveNotification(observer, applicationElement, name as CFString)
            }
        }

        // The action runs *here*, with the observer already listening. Pressing
        // first and registering afterwards races the app: a pane switch posts
        // its whole burst within milliseconds, so a late observer records zero
        // and we would read that as "this app posts nothing".
        performWhileArmed?()

        let startedAt = Date()
        var consumedEventCount = 0

        while true {
            // Run the loop, do not sleep it. Sleeping here would block the very
            // thread the callback is delivered on, and the observer would look
            // registered while never firing once.
            CFRunLoopRunInMode(.defaultMode, 0.02, true)

            while consumedEventCount < box.events.count {
                let event = box.events[consumedEventCount]
                clock.recordEvent(named: event.name, atSeconds: event.atSeconds)
                consumedEventCount += 1
            }

            let now = Date().timeIntervalSince(startedAt)
            let firstNotificationMilliseconds = clock.firstEventAtSeconds.map { Int($0 * 1000) }

            switch clock.verdict(atSeconds: now) {
            case .keepWaiting:
                continue

            case .settled(let quietSince):
                return SettleReport(
                    settled: true,
                    millisecondsToFirstNotification: firstNotificationMilliseconds,
                    millisecondsToQuiet: Int((quietSince + quietPeriodInSeconds) * 1000),
                    notificationCount: clock.eventCount,
                    notificationsByName: clock.eventCountsByName,
                    acceptedNotificationNames: acceptedNames,
                    refusedNotificationNames: refusedNames,
                    fellBackToPolling: false,
                    pollCount: 0,
                    outcomeDescription: "quiet for \(Int(quietPeriodInSeconds * 1000)) ms after the last notification"
                )

            case .noNotificationsArrived:
                let fallback = pollFallback?() ?? (settled: false, pollCount: 0)
                return SettleReport(
                    settled: fallback.settled,
                    millisecondsToFirstNotification: nil,
                    millisecondsToQuiet: Int(Date().timeIntervalSince(startedAt) * 1000),
                    notificationCount: 0,
                    notificationsByName: [:],
                    acceptedNotificationNames: acceptedNames,
                    refusedNotificationNames: refusedNames,
                    fellBackToPolling: true,
                    pollCount: fallback.pollCount,
                    outcomeDescription: "no notification within \(Int(observerGracePeriodInSeconds * 1000)) ms — fell back to polling"
                )

            case .hitCeiling:
                return SettleReport(
                    settled: false,
                    millisecondsToFirstNotification: firstNotificationMilliseconds,
                    millisecondsToQuiet: Int(now * 1000),
                    notificationCount: clock.eventCount,
                    notificationsByName: clock.eventCountsByName,
                    acceptedNotificationNames: acceptedNames,
                    refusedNotificationNames: refusedNames,
                    fellBackToPolling: false,
                    pollCount: 0,
                    outcomeDescription: "still posting notifications at the \(Int(ceilingInSeconds * 1000)) ms ceiling"
                )
            }
        }
    }
}
