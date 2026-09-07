//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
import CoreGraphics
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

}
