//
//  ElementReachability.swift
//  leanring-buddy
//
//  Making a listed-but-off-screen element reachable, so the safety kernel's
//  "outside the visible bounds" refusal has an answer other than giving up.
//
//  The obvious API does not exist here. `AXScrollToVisible` — ask the element
//  to show itself — is published by ZERO of System Settings' 177 nodes
//  (counted 2026-09-08 in /private/tmp/jarvis-ax-dump/tree.txt). What exists is
//  a page-at-a-time verb on the two AXScrollArea containers. So the action is
//  performed on a *different element* than the intent names, it is coarse, and
//  it needs a loop:
//
//      find the scrolling ancestor → page it → re-read the target's frame → repeat
//
//  The re-read is the load-bearing part. A cached AccessibilityElementNode's
//  frame is stale the instant the container moves, and deciding from a stale
//  frame is the same class of error as deciding from a pre-action snapshot.
//

import AppKit
import ApplicationServices
import Foundation

// MARK: - Pure geometry

/// The four page verbs, as strings, because they are not in the SDK.
///
/// `AXActionConstants.h` declares AXPress, AXShowMenu, AXPick and friends —
/// and nothing for scrolling. These names are an untyped convention apps agree
/// on, exactly like roles are. Ask the element what it publishes; never assume.
enum ScrollPageDirection: String, Equatable {
    case up = "AXScrollUpByPage"
    case down = "AXScrollDownByPage"
    case left = "AXScrollLeftByPage"
    case right = "AXScrollRightByPage"

    var accessibilityActionName: String { rawValue }

    /// Wheel delta for the synthetic fallback. Negative reveals content below,
    /// matching what `AXScrollDownByPage` claims to do.
    var syntheticWheelDelta: Int32 {
        switch self {
        case .down:  return -40
        case .up:    return  40
        case .right: return -40
        case .left:  return  40
        }
    }
}

enum ReachabilityOutcome: Equatable {
    case becameReachable(afterPages: Int)
    /// The frame stopped moving between pages — the container is at the end of
    /// its range. Stop here rather than spending the rest of the budget proving
    /// the same thing five more times.
    case scrollRangeExhausted(afterPages: Int)
    case stillUnreachable(afterPages: Int)
    /// The container accepted the verb in its action list but refused to run it.
    /// Distinct from `stillUnreachable`: nothing moved because the call failed,
    /// not because the range ran out. Collapsing the two hides the cause — the
    /// same mistake as returning a failed read as an empty result.
    case scrollActionFailed(axError: Int32, afterPages: Int)
    case noScrollableAncestor
    /// The target's name no longer resolves after a page. Honest third answer:
    /// we did not reach it, and we also cannot say it is still there.
    case targetVanished(afterPages: Int)

    var pagesSpent: Int {
        switch self {
        case .becameReachable(let pages),
             .scrollRangeExhausted(let pages),
             .stillUnreachable(let pages),
             .targetVanished(let pages):
            return pages
        case .scrollActionFailed(_, let pages):
            return pages
        case .noScrollableAncestor:
            return 0
        }
    }
}

/// Everything one attempt learned, so the report can be written from it.
struct ReachabilityAttempt {
    let outcome: ReachabilityOutcome
    let scrollContainerRole: String?
    let scrollContainerName: String?
    /// Which scroll area we actually paged. System Settings has two — a sidebar
    /// and a detail pane — and the report was unable to say which one it hit.
    let scrollContainerFrame: CGRect?
    /// What we compared the target against when calling it unreachable.
    let visibleBoundsUsed: CGRect
    /// True when the AX verb failed and a synthetic wheel event did the work.
    let usedSyntheticScroll: Bool
    let direction: ScrollPageDirection?
    let frameBefore: CGRect
    let frameAfter: CGRect
    /// One per page performed. Whether paging a container posts AX events the
    /// way pressing a button did is a measurement, not an assumption.
    let settleReports: [SettleReport]
    /// The tree from the final re-walk, so the caller can re-evaluate the
    /// kernel without paying for another walk.
    let finalRootNode: AccessibilityElementNode?
}

enum ElementReachability {

    /// Which way to page, given where the target is relative to what is on
    /// screen. `nil` means it is already visible and nothing should be scrolled.
    ///
    /// AppKit coordinates: y grows UPWARD, so a frame above the visible region
    /// has the LARGER y. Measured 2026-09-08, the scrolled-out button read
    /// `(354, -66, 459, 38)` — negative y, i.e. below the bottom edge, i.e. page
    /// down. Getting this backwards is silent: it scrolls away from the target
    /// and reports "still unreachable".
    static func direction(
        forTargetFrame targetFrame: CGRect,
        visibleBounds: CGRect
    ) -> ScrollPageDirection? {
        guard !targetFrame.intersects(visibleBounds) else { return nil }

        let overshootAbove = targetFrame.maxY - visibleBounds.maxY
        let overshootBelow = visibleBounds.minY - targetFrame.minY
        let overshootRight = targetFrame.maxX - visibleBounds.maxX
        let overshootLeft = visibleBounds.minX - targetFrame.minX

        let verticalOvershoot = max(overshootAbove, overshootBelow)
        let horizontalOvershoot = max(overshootRight, overshootLeft)
        guard max(verticalOvershoot, horizontalOvershoot) > 0 else { return nil }

        if verticalOvershoot >= horizontalOvershoot {
            return overshootAbove >= overshootBelow ? .up : .down
        }
        return overshootRight >= overshootLeft ? .right : .left
    }

    /// The stop rule, with no AX in it. `nil` means keep paging.
    ///
    /// Order matters: reachable beats stopped-moving, because the last page can
    /// both land the target and hit the end of the range at once.
    static func outcome(
        previousFrame: CGRect,
        currentFrame: CGRect,
        visibleBounds: CGRect,
        pagesSpent: Int,
        maximumPages: Int
    ) -> ReachabilityOutcome? {
        if currentFrame.intersects(visibleBounds) {
            return .becameReachable(afterPages: pagesSpent)
        }
        if currentFrame == previousFrame {
            return .scrollRangeExhausted(afterPages: pagesSpent)
        }
        if pagesSpent >= maximumPages {
            return .stillUnreachable(afterPages: pagesSpent)
        }
        return nil
    }

    // MARK: - AX plumbing

    /// Pages the target's nearest scrolling ancestor until the target's freshly
    /// re-read frame intersects `visibleBounds`, or a stop rule fires.
    ///
    /// ponytail: the direction is chosen ONCE, not re-chosen per page. A page is
    /// coarse enough to overshoot, and re-choosing would let an overshoot
    /// oscillate until the budget ran out instead of terminating on
    /// scrollRangeExhausted. Re-choose only if a measured run shows overshoot
    /// actually happening.
    @MainActor
    static func makeReachable(
        node: AccessibilityElementNode,
        within rootNode: AccessibilityElementNode,
        visibleBounds: CGRect,
        processIdentifier: pid_t,
        maximumPages: Int = 6
    ) -> ReachabilityAttempt {
        let startingFrame = node.frameInAppKitCoordinates

        // Declared above `attempt`, which captures it: every exit path must be
        // able to report which tier actually moved the container.
        var usedSyntheticScroll = false
        func attempt(
            _ outcome: ReachabilityOutcome,
            container: AccessibilityElementNode? = nil,
            direction: ScrollPageDirection? = nil,
            frameAfter: CGRect? = nil,
            settleReports: [SettleReport] = [],
            finalRootNode: AccessibilityElementNode? = nil
        ) -> ReachabilityAttempt {
            ReachabilityAttempt(
                outcome: outcome,
                scrollContainerRole: container?.role,
                scrollContainerName: container?.displayName,
                scrollContainerFrame: container?.frameInAppKitCoordinates,
                visibleBoundsUsed: visibleBounds,
                usedSyntheticScroll: usedSyntheticScroll,
                direction: direction,
                frameBefore: startingFrame,
                frameAfter: frameAfter ?? startingFrame,
                settleReports: settleReports,
                finalRootNode: finalRootNode
            )
        }

        guard let chosenDirection = direction(
            forTargetFrame: startingFrame,
            visibleBounds: visibleBounds
        ) else {
            return attempt(.becameReachable(afterPages: 0))
        }

        guard let chain = ancestorChain(to: node, from: rootNode),
              let container = chain.dropLast().last(where: {
                  $0.publishedActionNames.contains(chosenDirection.accessibilityActionName)
              }),
              let containerElement = container.accessibilityElement else {
            return attempt(.noScrollableAncestor, direction: chosenDirection)
        }

        // The identity we re-resolve by. A frame is what changes; the name is
        // what stays put.
        guard let targetName = node.displayName else {
            return attempt(.noScrollableAncestor, container: container, direction: chosenDirection)
        }
        let reresolveIntent = ElementActionIntent(
            role: node.role,
            title: targetName,
            action: .press
        )

        var previousFrame = startingFrame
        var pagesSpent = 0
        var settleReports: [SettleReport] = []
        var latestRootNode: AccessibilityElementNode? = rootNode

        // Tier 2 aims with the same rectangle AX gave us; only the verb drops.
        let primaryDisplayHeight = NSScreen.screens.first?.frame.height ?? 0
        let containerCentre = SyntheticScroller.topLeftCentre(
            ofAppKitFrame: container.frameInAppKitCoordinates,
            primaryDisplayHeightInPoints: primaryDisplayHeight
        )

        while true {
            var performResult: AXError = .success
            let settleReport = WindowSettleObserver.waitForSettle(
                processIdentifier: processIdentifier,
                performWhileArmed: {
                    performResult = AccessibilityActionPerformer.perform(
                        chosenDirection.accessibilityActionName,
                        on: containerElement
                    ).error

                    // The AX verb is published but not implemented here. Escalate
                    // rather than report a failure we already know how to answer.
                    if performResult != .success {
                        usedSyntheticScroll = true
                        SyntheticScroller.scroll(
                            atTopLeftPoint: containerCentre,
                            wheelDelta: chosenDirection.syntheticWheelDelta
                        )
                        performResult = .success
                    }
                },
                pollFallback: { (settled: false, pollCount: 0) }
            )
            settleReports.append(settleReport)
            pagesSpent += 1

            guard performResult == .success else {
                return attempt(
                    .scrollActionFailed(axError: performResult.rawValue, afterPages: pagesSpent),
                    container: container,
                    direction: chosenDirection,
                    frameAfter: previousFrame,
                    settleReports: settleReports,
                    finalRootNode: latestRootNode
                )
            }

            // Re-walk and re-resolve. Reusing `node` here would read a frame
            // captured before the container moved, which is exactly the bug
            // this loop exists to avoid.
            guard let freshSnapshot = try? AccessibilityTreeWalker.snapshotFocusedWindow(),
                  let freshRootNode = freshSnapshot.rootNode else {
                return attempt(
                    .stillUnreachable(afterPages: pagesSpent),
                    container: container,
                    direction: chosenDirection,
                    frameAfter: previousFrame,
                    settleReports: settleReports,
                    finalRootNode: latestRootNode
                )
            }
            latestRootNode = freshRootNode

            guard case .resolved(let freshNode) = ElementActionIntentResolver.resolve(
                reresolveIntent,
                inTreeRootedAt: freshRootNode
            ) else {
                return attempt(
                    .targetVanished(afterPages: pagesSpent),
                    container: container,
                    direction: chosenDirection,
                    frameAfter: previousFrame,
                    settleReports: settleReports,
                    finalRootNode: freshRootNode
                )
            }

            let currentFrame = freshNode.frameInAppKitCoordinates
            if let decided = outcome(
                previousFrame: previousFrame,
                currentFrame: currentFrame,
                visibleBounds: visibleBounds,
                pagesSpent: pagesSpent,
                maximumPages: maximumPages
            ) {
                return attempt(
                    decided,
                    container: container,
                    direction: chosenDirection,
                    frameAfter: currentFrame,
                    settleReports: settleReports,
                    finalRootNode: freshRootNode
                )
            }
            previousFrame = currentFrame
        }
    }

    /// Root-to-target path, so we can walk *up* from a target in a tree that
    /// only has downward links. Identity is role + name + frame: the kernel has
    /// already refused anything ambiguous by the time we get here.
    static func ancestorChain(
        to target: AccessibilityElementNode,
        from node: AccessibilityElementNode
    ) -> [AccessibilityElementNode]? {
        if node.role == target.role,
           node.displayName == target.displayName,
           node.frameInAppKitCoordinates == target.frameInAppKitCoordinates {
            return [node]
        }
        for child in node.children {
            if let tail = ancestorChain(to: target, from: child) {
                return [node] + tail
            }
        }
        return nil
    }
}
