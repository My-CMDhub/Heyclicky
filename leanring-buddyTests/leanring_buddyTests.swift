//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
import CoreGraphics
import ApplicationServices
@testable import Clicky

struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = await WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = await WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = await WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func bestDisplayIndexPrefersLargestOverlap() async throws {
        let windowFrame = CGRect(x: 900, y: 100, width: 500, height: 400)
        let displays = [
            CGRect(x: 0, y: 0, width: 800, height: 600),
            CGRect(x: 800, y: 0, width: 800, height: 600)
        ]

        let bestIndex = await CompanionScreenCaptureUtility.bestDisplayIndex(
            for: windowFrame,
            among: displays
        )

        #expect(bestIndex == 1)
    }

    @Test func bestDisplayIndexReturnsNilWhenNoDisplayOverlaps() async throws {
        let windowFrame = CGRect(x: 2000, y: 100, width: 200, height: 200)
        let displays = [
            CGRect(x: 0, y: 0, width: 800, height: 600),
            CGRect(x: 800, y: 0, width: 800, height: 600)
        ]

        let bestIndex = await CompanionScreenCaptureUtility.bestDisplayIndex(
            for: windowFrame,
            among: displays
        )

        #expect(bestIndex == nil)
    }

    @Test func accessibilityFrameConvertsToAppKitFrameOnPrimaryDisplay() async throws {
        // A button 180pt down from the top of a 900pt-tall primary display,
        // 24pt tall. Its AppKit origin is its BOTTOM edge: 900 - 180 - 24.
        let accessibilityFrame = CGRect(x: 620, y: 180, width: 52, height: 24)

        let appKitFrame = AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(
            accessibilityFrame,
            primaryDisplayHeightInPoints: 900
        )

        #expect(appKitFrame == CGRect(x: 620, y: 696, width: 52, height: 24))
    }

    @Test func accessibilityFrameConvertsToAppKitFrameOnDisplayAbovePrimary() async throws {
        // A display stacked ABOVE the primary one has negative AX y values,
        // because AX counts down from the primary display's top-left corner.
        let accessibilityFrame = CGRect(x: 100, y: -1080, width: 52, height: 24)

        let appKitFrame = AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(
            accessibilityFrame,
            primaryDisplayHeightInPoints: 900
        )

        #expect(appKitFrame == CGRect(x: 100, y: 1956, width: 52, height: 24))
    }

    @Test func serializedTreeIndentsChildrenByDepth() async throws {
        let buttonNode = AccessibilityElementNode(
            role: "AXButton",
            subrole: nil,
            title: "Run",
            value: nil,
            frameInAppKitCoordinates: CGRect(x: 10, y: 20, width: 30, height: 12),
            depth: 1,
            children: []
        )
        let windowNode = AccessibilityElementNode(
            role: "AXWindow",
            subrole: nil,
            title: "Settings",
            value: nil,
            frameInAppKitCoordinates: CGRect(x: 0, y: 0, width: 100, height: 50),
            depth: 0,
            children: [buttonNode]
        )

        let serializedTree = AccessibilityTreeWalker.serializeTreeToText(windowNode)

        #expect(serializedTree == """
        AXWindow "Settings" (0, 0, 100, 50)
          AXButton "Run" (10, 20, 30, 12)
        """)
    }

    @Test func walkBudgetStopsAtNodeLimitAndRecordsTruncation() async throws {
        var budget = AccessibilityWalkBudget(maximumDepth: 10, maximumNodeCount: 2)

        // #expect hands the receiver to its macro-generated closure by value,
        // so a mutating call has to happen before the assertion, not inside it.
        let firstSlotClaimed = budget.claimSlot(atDepth: 0)
        let secondSlotClaimed = budget.claimSlot(atDepth: 1)
        let thirdSlotClaimed = budget.claimSlot(atDepth: 2)

        #expect(firstSlotClaimed)
        #expect(secondSlotClaimed)
        #expect(thirdSlotClaimed == false)

        #expect(budget.nodesVisited == 2)
        #expect(budget.wasTruncated)
    }

    @Test func walkBudgetStopsBelowDepthLimitWithoutSpendingNodes() async throws {
        var budget = AccessibilityWalkBudget(maximumDepth: 1, maximumNodeCount: 100)

        let firstSlotClaimed = budget.claimSlot(atDepth: 0)
        let secondSlotClaimed = budget.claimSlot(atDepth: 1)

        #expect(firstSlotClaimed)
        #expect(secondSlotClaimed == false)

        #expect(budget.nodesVisited == 1)
        #expect(budget.wasTruncated)
    }

    @Test func flattenedDescendantsIncludesEveryNodeInTheSubtree() async throws {
        let leafNode = AccessibilityElementNode(
            role: "AXButton", subrole: nil, title: "Run", value: nil,
            frameInAppKitCoordinates: .zero, depth: 2, children: []
        )
        let groupNode = AccessibilityElementNode(
            role: "AXGroup", subrole: nil, title: nil, value: nil,
            frameInAppKitCoordinates: .zero, depth: 1, children: [leafNode]
        )
        let windowNode = AccessibilityElementNode(
            role: "AXWindow", subrole: nil, title: "Settings", value: nil,
            frameInAppKitCoordinates: .zero, depth: 0, children: [groupNode]
        )

        let flattenedNodes = windowNode.flattenedDescendants()

        #expect(flattenedNodes.count == 3)
        #expect(flattenedNodes.map(\.role) == ["AXWindow", "AXGroup", "AXButton"])
    }

    @Test func resolverFindsAUniqueTitleMatch() async throws {
        let accessibilityRow = AccessibilityElementNode(
            role: "AXRow", subrole: nil, title: "Accessibility", value: nil,
            frameInAppKitCoordinates: CGRect(x: 0, y: 100, width: 200, height: 28),
            depth: 1, children: []
        )
        let windowNode = AccessibilityElementNode(
            role: "AXWindow", subrole: nil, title: "System Settings", value: nil,
            frameInAppKitCoordinates: CGRect(x: 0, y: 0, width: 800, height: 600),
            depth: 0, children: [accessibilityRow]
        )

        let intent = ElementActionIntent(role: "AXRow", title: "Accessibility", action: .press)
        let resolution = ElementActionIntentResolver.resolve(intent, inTreeRootedAt: windowNode)

        guard case .resolved(let matchedNode) = resolution else {
            Issue.record("expected a unique match, got \(resolution)")
            return
        }
        #expect(matchedNode.role == "AXRow")
    }

    @Test func resolverRefusesAnAmbiguousTitleMatch() async throws {
        func rowTitled(_ title: String) -> AccessibilityElementNode {
            AccessibilityElementNode(
                role: "AXRow", subrole: nil, title: title, value: nil,
                frameInAppKitCoordinates: CGRect(x: 0, y: 100, width: 200, height: 28),
                depth: 1, children: []
            )
        }
        let windowNode = AccessibilityElementNode(
            role: "AXWindow", subrole: nil, title: "System Settings", value: nil,
            frameInAppKitCoordinates: CGRect(x: 0, y: 0, width: 800, height: 600),
            depth: 0, children: [rowTitled("General"), rowTitled("General")]
        )

        let intent = ElementActionIntent(role: "AXRow", title: "General", action: .press)
        let resolution = ElementActionIntentResolver.resolve(intent, inTreeRootedAt: windowNode)

        #expect(resolution == .ambiguous(matchCount: 2))
    }

    private func nodeForSafetyTest(
        role: String = "AXRow",
        title: String = "Accessibility",
        frame: CGRect = CGRect(x: 0, y: 100, width: 200, height: 28),
        actions: [String] = [kAXPressAction]
    ) -> AccessibilityElementNode {
        AccessibilityElementNode(
            role: role, subrole: nil, title: title, value: nil,
            frameInAppKitCoordinates: frame, depth: 1, children: [],
            publishedActionNames: actions
        )
    }

    @Test func safetyKernelRefusesAZeroAreaFrame() async throws {
        let decision = ActionSafetyKernel.evaluate(
            intent: ElementActionIntent(role: "AXRow", title: "Privacy & Security", action: .press),
            resolvedNode: nodeForSafetyTest(title: "Privacy & Security", frame: .zero),
            matchCount: 1,
            visibleBounds: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        #expect(decision == .refuse(reason: "listed but not reachable: element has a zero-area frame"))
    }

    @Test func safetyKernelRefusesAnElementScrolledOutOfView() async throws {
        // Real element, measured 2026-09-08: named, 459x38, publishes AXPress,
        // and sitting below the visible pane at y = -66.
        let decision = ActionSafetyKernel.evaluate(
            intent: ElementActionIntent(role: "AXButton", title: "Transfer or Reset", action: .press),
            resolvedNode: nodeForSafetyTest(
                role: "AXButton",
                title: "Transfer or Reset",
                frame: CGRect(x: 354, y: -66, width: 459, height: 38)
            ),
            matchCount: 1,
            visibleBounds: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        #expect(decision == .refuse(reason: "listed but not reachable: element lies outside the visible bounds"))
    }

    @Test func safetyKernelRefusesAnActionTheElementDoesNotPublish() async throws {
        let decision = ActionSafetyKernel.evaluate(
            intent: ElementActionIntent(role: "AXStaticText", title: "Wi-Fi", action: .press),
            resolvedNode: nodeForSafetyTest(role: "AXStaticText", title: "Wi-Fi", actions: []),
            matchCount: 1,
            visibleBounds: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        #expect(decision == .refuse(reason: "element does not publish AXPress"))
    }

    @Test func safetyKernelRefusesAnAmbiguousMatch() async throws {
        let decision = ActionSafetyKernel.evaluate(
            intent: ElementActionIntent(role: "AXRow", title: "General", action: .press),
            resolvedNode: nodeForSafetyTest(title: "General"),
            matchCount: 3,
            visibleBounds: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        #expect(decision == .refuse(reason: "3 elements match that title"))
    }

    @Test func safetyKernelAllowsANavigationalPress() async throws {
        let decision = ActionSafetyKernel.evaluate(
            intent: ElementActionIntent(role: "AXRow", title: "Accessibility", action: .press),
            resolvedNode: nodeForSafetyTest(),
            matchCount: 1,
            visibleBounds: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        #expect(decision == .allow)
    }

    @Test func safetyKernelAsksBeforeSomethingDestructive() async throws {
        let decision = ActionSafetyKernel.evaluate(
            intent: ElementActionIntent(role: "AXButton", title: "Delete Account", action: .press),
            resolvedNode: nodeForSafetyTest(role: "AXButton", title: "Delete Account"),
            matchCount: 1,
            visibleBounds: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        #expect(decision == .requireConfirmation(reason: "title suggests a destructive action: delete"))
    }

    @Test func safetyKernelAsksWhenItDoesNotRecogniseTheRole() async throws {
        let decision = ActionSafetyKernel.evaluate(
            intent: ElementActionIntent(role: "AXDisclosureTriangle", title: "More", action: .press),
            resolvedNode: nodeForSafetyTest(role: "AXDisclosureTriangle", title: "More"),
            matchCount: 1,
            visibleBounds: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        #expect(decision == .requireConfirmation(reason: "unrecognised role AXDisclosureTriangle"))
    }

    // MARK: - SettleClock
    //
    // The debounce rule only. Mocking AXObserverCreate would test the mock, so
    // observer behaviour is proven by running --ax-task and reading the report.

    @Test func settleClockWaitsForQuietAfterTheLastEventNotTheFirst() async throws {
        var clock = SettleClock(quietPeriodInSeconds: 0.25, gracePeriodInSeconds: 0.4, ceilingInSeconds: 3.0)
        clock.recordEvent(named: "AXLayoutChanged", atSeconds: 0.05)
        clock.recordEvent(named: "AXValueChanged", atSeconds: 0.06)
        clock.recordEvent(named: "AXLayoutChanged", atSeconds: 0.30)

        // 0.25 s after the FIRST event, but only 0.01 s after the last one.
        let duringTheBurst = clock.verdict(atSeconds: 0.31)
        #expect(duringTheBurst == .keepWaiting)

        let afterTheBurst = clock.verdict(atSeconds: 0.56)
        #expect(afterTheBurst == .settled(quietSinceSeconds: 0.30))
        #expect(clock.eventCount == 3)
        #expect(clock.eventCountsByName["AXLayoutChanged"] == 2)
    }

    @Test func settleClockFallsBackToPollingWhenTheAppPostsNothing() async throws {
        let clock = SettleClock(quietPeriodInSeconds: 0.25, gracePeriodInSeconds: 0.4, ceilingInSeconds: 3.0)

        let beforeGraceExpires = clock.verdict(atSeconds: 0.39)
        #expect(beforeGraceExpires == .keepWaiting)

        // Silence is not stillness: an app with a thin AX implementation posts
        // nothing at all, and the observer cannot tell that from a settled app.
        let afterGraceExpires = clock.verdict(atSeconds: 0.40)
        #expect(afterGraceExpires == .noNotificationsArrived)
    }

    @Test func settleClockHitsTheCeilingWhenEventsNeverStop() async throws {
        var clock = SettleClock(quietPeriodInSeconds: 0.25, gracePeriodInSeconds: 0.4, ceilingInSeconds: 3.0)
        for step in 1...30 {
            // Division, not multiplication: 30 * 0.1 is 3.0000000000000004 and
            // the equality below would fail on a rounding artefact.
            clock.recordEvent(named: "AXValueChanged", atSeconds: Double(step) / 10.0)
        }

        let atTheCeiling = clock.verdict(atSeconds: 3.0)
        #expect(atTheCeiling == .hitCeiling)
        #expect(clock.firstEventAtSeconds == 0.1)

        // And a ceiling never beats real quiet: an app that stops at the buzzer
        // has settled, not timed out.
        let quietAtTheBuzzer = clock.verdict(atSeconds: 3.25)
        #expect(quietAtTheBuzzer == .settled(quietSinceSeconds: 3.0))
    }

    // MARK: - Phase 4: reachability, pure geometry only
    //
    // AppKit coordinates, y growing UPWARD. Visible bounds stand in for the
    // window frame. Performing a real AXScroll*ByPage is proven by --ax-task,
    // never by a mock: mocking cross-process AX would test the mock.

    private var visibleWindowBounds: CGRect { CGRect(x: 0, y: 0, width: 800, height: 600) }

    @Test func alreadyVisibleElementNeedsNoScroll() async throws {
        let onScreen = CGRect(x: 100, y: 200, width: 120, height: 32)
        #expect(ElementReachability.direction(forTargetFrame: onScreen, visibleBounds: visibleWindowBounds) == nil)
    }

    @Test func directionFollowsWhichEdgeTheTargetIsBeyond() async throws {
        // Above the window: larger y in AppKit coordinates. Page UP.
        let above = CGRect(x: 100, y: 700, width: 120, height: 32)
        #expect(ElementReachability.direction(forTargetFrame: above, visibleBounds: visibleWindowBounds) == .up)

        // Below: the shape actually measured on System Settings 2026-09-08,
        // AXButton desc="Transfer or Reset" (354, -66, 459, 38). Page DOWN.
        let below = CGRect(x: 354, y: -66, width: 459, height: 38)
        #expect(ElementReachability.direction(forTargetFrame: below, visibleBounds: visibleWindowBounds) == .down)

        let toTheRight = CGRect(x: 900, y: 200, width: 120, height: 32)
        #expect(ElementReachability.direction(forTargetFrame: toTheRight, visibleBounds: visibleWindowBounds) == .right)

        let toTheLeft = CGRect(x: -300, y: 200, width: 120, height: 32)
        #expect(ElementReachability.direction(forTargetFrame: toTheLeft, visibleBounds: visibleWindowBounds) == .left)
    }

    @Test func reachableWinsOverEveryOtherStopCondition() async throws {
        // The last page can land the target AND hit the end of the range at
        // once. If "stopped moving" were checked first, a successful scroll
        // would be reported as a failure.
        let landed = CGRect(x: 100, y: 100, width: 120, height: 32)
        let outcome = ElementReachability.outcome(
            previousFrame: CGRect(x: 100, y: -400, width: 120, height: 32),
            currentFrame: landed,
            visibleBounds: visibleWindowBounds,
            pagesSpent: 3,
            maximumPages: 6
        )
        #expect(outcome == .becameReachable(afterPages: 3))
    }

    @Test func frameThatStoppedMovingEndsTheScrollEarly() async throws {
        // A page that changes nothing means the container is at the end of its
        // range. Stop, rather than spending the other four pages proving it.
        let stuck = CGRect(x: 354, y: -66, width: 459, height: 38)
        let outcome = ElementReachability.outcome(
            previousFrame: stuck,
            currentFrame: stuck,
            visibleBounds: visibleWindowBounds,
            pagesSpent: 2,
            maximumPages: 6
        )
        #expect(outcome == .scrollRangeExhausted(afterPages: 2))
        #expect(outcome?.pagesSpent == 2)
    }

    @Test func stillMovingBelowBudgetKeepsPaging() async throws {
        let outcome = ElementReachability.outcome(
            previousFrame: CGRect(x: 354, y: -400, width: 459, height: 38),
            currentFrame: CGRect(x: 354, y: -66, width: 459, height: 38),
            visibleBounds: visibleWindowBounds,
            pagesSpent: 1,
            maximumPages: 6
        )
        #expect(outcome == nil)
    }

    @Test func budgetExhaustedIsReportedWithItsPageCount() async throws {
        let outcome = ElementReachability.outcome(
            previousFrame: CGRect(x: 354, y: -900, width: 459, height: 38),
            currentFrame: CGRect(x: 354, y: -600, width: 459, height: 38),
            visibleBounds: visibleWindowBounds,
            pagesSpent: 6,
            maximumPages: 6
        )
        #expect(outcome == .stillUnreachable(afterPages: 6))
    }

}

// MARK: - Wall-clock guard

@Test func budgetStopsWhenItRunsOutOfTime() async throws {
    // The node and depth caps bound a tree's shape. Neither bounds a walk against
    // an app that has stopped answering, where one read can block for the whole
    // messaging timeout. This is the only limit that does.
    var budget = AccessibilityWalkBudget(
        maximumDepth: 1000, maximumNodeCount: 1_000_000, timeLimitInSeconds: 0.05
    )
    let firstClaim = budget.claimSlot(atDepth: 0)
    #expect(firstClaim)

    Thread.sleep(forTimeInterval: 0.08)

    let claimAfterDeadline = budget.claimSlot(atDepth: 0)
    #expect(claimAfterDeadline == false)

    let reasons = budget.stopReasons
    #expect(reasons == [.timeLimit])
}

@Test func budgetNamesWhichLimitStoppedIt() async throws {
    // "It stopped" and "it stopped because the app went unresponsive" are
    // different facts. A single boolean flattens them, and this project has
    // already spent a day reading a truncated count as a measurement.
    var depthBudget = AccessibilityWalkBudget(maximumDepth: 2, maximumNodeCount: 100)
    _ = depthBudget.claimSlot(atDepth: 5)
    let depthReasons = depthBudget.stopReasons
    #expect(depthReasons == [.depthLimit])

    var nodeBudget = AccessibilityWalkBudget(maximumDepth: 100, maximumNodeCount: 1)
    _ = nodeBudget.claimSlot(atDepth: 0)
    _ = nodeBudget.claimSlot(atDepth: 0)
    let nodeReasons = nodeBudget.stopReasons
    #expect(nodeReasons == [.nodeLimit])
}

@Test func budgetThatFinishesReportsNoReason() async throws {
    var budget = AccessibilityWalkBudget(maximumDepth: 10, maximumNodeCount: 10)
    let claimed = budget.claimSlot(atDepth: 0)
    #expect(claimed)
    let reasons = budget.stopReasons
    #expect(reasons.isEmpty)
    #expect(budget.wasTruncated == false)
}
