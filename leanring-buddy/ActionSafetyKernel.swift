//
//  ActionSafetyKernel.swift
//  leanring-buddy
//
//  Deterministic policy that runs before any action reaches the machine.
//  It knows nothing about models and cannot be argued out of a refusal.
//
//  The default is requireConfirmation, never allow. Anything this kernel does
//  not positively recognise becomes a question for the human.
//

import ApplicationServices
import Foundation

enum SafetyDecision: Equatable {
    case allow
    case requireConfirmation(reason: String)
    case refuse(reason: String)
}

enum ActionSafetyKernel {

    /// Roles for which a press is ordinary navigation on this machine.
    /// Deliberately short — it grows only when a measured case demands it.
    static let navigationalPressRoles: Set<String> = ["AXButton", "AXRow", "AXCell"]

    /// Roles for which writing a selection is ordinary navigation.
    ///
    /// `AXStaticText` is in here and deliberately not in the press list: a
    /// sidebar row is anonymous, so the element a planner can name is the label
    /// two levels inside it. Selecting changes what is selected — the write
    /// itself cannot activate anything else.
    static let navigationalSelectRoles: Set<String> = ["AXRow", "AXCell", "AXStaticText"]

    /// The only roles that may be typed into. Everything else is refused, not
    /// asked about: a role that does not accept text has no correct answer to
    /// "type this here", so there is nothing for a human to confirm.
    static let typeableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    /// The one refusal in this kernel that has no confirmed path past it.
    static let secureFieldSubrole = "AXSecureTextField"

    static func navigationalRoles(for action: ElementAction) -> Set<String> {
        switch action {
        case .press: return navigationalPressRoles
        case .select: return navigationalSelectRoles
        case .type: return typeableRoles
        }
    }

    /// What the kernel needs to know about a typing target that the tree walk
    /// does not carry: what the element says it will let us write, how much text
    /// is already in it, and whether we aimed at it by name or by focus.
    ///
    /// Measured on the live element, one element only — this is four extra IPC
    /// reads on the resolved target, never a per-node cost on the walk.
    struct TypingContext: Equatable {
        let mode: TypeMode
        /// The subset of `AccessibilityTypePerformer.probedAttributes` the
        /// element reported as settable. Asked, because a role is a convention.
        let settableAttributes: Set<String>
        let currentValueLength: Int
        /// True when the target came from `kAXFocusedUIElement` rather than from
        /// a name. The name checks below are then meaningless — System Settings'
        /// search field has no name at all, and the OS, not the app's text, is
        /// what identified it.
        let aimedByFocus: Bool
    }

    static func secureFieldRefusalReason(subrole: String) -> String {
        "refusing to type into a secure field (subrole \(subrole)) — the agent does not enter credentials, and this refusal has no confirmed path past it"
    }

    /// Whether a refusal says something tried to do a thing it should not, as
    /// opposed to a thing it could not.
    ///
    /// The distinction is what keeps the flight recorder useful. An off-screen
    /// or wrong-role target is the policy working normally and the audit line
    /// explains it completely. A secure field or a label that is not a label is
    /// the shape of an attempt, and that is exactly when the previous twenty
    /// requests are worth having on disk.
    static func isSecurityRefusal(reason: String) -> Bool {
        reason == implausibleNameRefusalReason
            || reason.hasPrefix("refusing to type into a secure field")
    }

    static func nonTextRoleRefusalReason(role: String) -> String {
        "role \(role) does not accept text — only \(typeableRoles.sorted().joined(separator: ", ")) may be typed into"
    }

    static func missingSettableAttributeRefusalReason(attribute: String) -> String {
        "element does not publish a settable \(attribute)"
    }

    static func replaceWouldDiscardReason(characterCount: Int) -> String {
        "replace would discard \(characterCount) characters already in the field"
    }

    /// Words that make an action worth asking about regardless of role.
    /// Refusal reasons as constants, so the probe can classify a decision by
    /// identity rather than by re-typing the sentence and silently missing.
    static let zeroAreaRefusalReason = "listed but not reachable: element has a zero-area frame"
    static let outsideBoundsRefusalReason = "listed but not reachable: element lies outside the visible bounds"

    /// The name is the whole identity we act on, and the app wrote it. A label
    /// that is empty, document-length, or carries a newline is not a control's
    /// name — it is content that arrived in a name-shaped field, and letting it
    /// name an action is how app-controlled text becomes an instruction.
    static let implausibleNameRefusalReason = "listed but not usable as a target: the element's name is not a plain label"

    static let destructiveTitleKeywords = [
        "delete", "remove", "erase", "send", "buy", "pay", "purchase", "reset"
    ]

    static func evaluate(
        intent: ElementActionIntent,
        resolvedNode: AccessibilityElementNode,
        matchCount: Int,
        visibleBounds: CGRect,
        typing: TypingContext? = nil
    ) -> SafetyDecision {
        // Order matters. Every refusal is checked before any permission.

        // Before everything, including whether the element is even reachable:
        // a password field is refused on sight. There is no state of the world
        // and no `confirmed: true` that makes this an allow, so it is not a
        // question — it is the one rule this kernel may not be argued out of.
        if case .type = intent.action,
           let subrole = resolvedNode.subrole, subrole == secureFieldSubrole {
            return .refuse(reason: secureFieldRefusalReason(subrole: subrole))
        }

        guard matchCount == 1 else {
            return .refuse(reason: "\(matchCount) elements match that title")
        }

        let frame = resolvedNode.frameInAppKitCoordinates
        guard frame.width > 0, frame.height > 0 else {
            return .refuse(reason: zeroAreaRefusalReason)
        }

        // Zero area is only the first disguise. Measured 2026-09-08:
        // AXButton desc="Transfer or Reset" (354, -66, 459, 38) [AXPress] is
        // named, correctly sized and pressable, and scrolled out of its pane.
        // Reachability is the relationship between the frame and what is on
        // screen, not a property of the frame alone.
        guard frame.intersects(visibleBounds) else {
            return .refuse(reason: outsideBoundsRefusalReason)
        }

        // Only an action has an action name. A property write has no entry in
        // `AXUIElementCopyActionNames` to look for, and whether the attribute is
        // settable is a question for the element at write time — a machine fact
        // the performer establishes, not a policy this kernel can decide.
        if let requiredActionName = intent.action.accessibilityActionName {
            guard resolvedNode.publishedActionNames.contains(requiredActionName) else {
                return .refuse(reason: "element does not publish \(requiredActionName)")
            }
        }

        if case .type = intent.action {
            guard typeableRoles.contains(resolvedNode.role) else {
                return .refuse(reason: nonTextRoleRefusalReason(role: resolvedNode.role))
            }
            // No context means nobody asked the element anything, which is our
            // bug and not a question for a human.
            guard let typing else {
                return .refuse(reason: "no typing context was gathered for this element")
            }
            // The role said "text field". This is the element itself agreeing.
            let required = typing.mode.settableAttributeRequired
            guard typing.settableAttributes.contains(required) else {
                return .refuse(reason: missingSettableAttributeRefusalReason(attribute: required))
            }
        }

        // A field aimed at by focus is identified by the OS, not by its name —
        // and the fields that most need typing are anonymous. Measured
        // 2026-09-10: System Settings' search field publishes no title, no
        // description and an empty value.
        if typing?.aimedByFocus != true {
            guard let name = resolvedNode.displayName, name.isPlausibleControlLabel else {
                return .refuse(reason: implausibleNameRefusalReason)
            }

            // App-written text may only ever make the decision *more* cautious.
            // A keyword here escalates to a question; nothing an app publishes can
            // turn a question into an allow.
            let lowercasedTitle = name.raw.lowercased()
            if let matchedKeyword = destructiveTitleKeywords.first(where: { lowercasedTitle.contains($0) }) {
                return .requireConfirmation(reason: "title suggests a destructive action: \(matchedKeyword)")
            }
        }

        // Overwriting a document is the worst thing this verb can do, and it is
        // silent — the old text is simply gone. Replacing an *empty* field is
        // not destruction, so it is not asked about.
        if let typing, typing.mode == .replace, typing.currentValueLength > 0 {
            return .requireConfirmation(
                reason: replaceWouldDiscardReason(characterCount: typing.currentValueLength)
            )
        }

        guard navigationalRoles(for: intent.action).contains(resolvedNode.role) else {
            return .requireConfirmation(reason: "unrecognised role \(resolvedNode.role)")
        }

        return .allow
    }
}
