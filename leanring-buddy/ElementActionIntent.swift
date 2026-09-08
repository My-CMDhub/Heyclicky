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

    var accessibilityActionName: String {
        switch self {
        case .press:
            return kAXPressAction
        }
    }
}

struct ElementActionIntent {
    /// Optional: when given, the match must also agree on role.
    let role: String?
    let title: String
    let action: ElementAction
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
        let matchingNodes = rootNode.flattenedDescendants().filter { node in
            guard node.displayName == intent.title else { return false }
            guard let requiredRole = intent.role else { return true }
            return node.role == requiredRole
        }

        switch matchingNodes.count {
        case 0:
            return .notFound
        case 1:
            return .resolved(matchingNodes[0])
        default:
            return .ambiguous(matchCount: matchingNodes.count)
        }
    }
}
