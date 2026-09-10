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

    /// Roles that publish `AXOpen`. Measured 2026-09-10 on Finder: the file row
    /// publishes only the hover pair, the `AXCell` inside it publishes `AXOpen`.
    /// Deliberately empty: **opening always asks a human.**
    ///
    /// `AXOpen` does not navigate, it *launches whatever the thing is* — a
    /// document, an installer, a script, an application. Double-clicking an
    /// unknown file is how malware runs, and no verification undoes it. So there
    /// is no role for which this kernel calls it ordinary, and every open lands
    /// on `requireConfirmation`.
    ///
    /// The role census that settled it, measured 2026-09-10 on one Finder window
    /// (1,467 nodes): **AXTextField 446 publish AXOpen and all 446 are named**
    /// (the file list), AXCell 11 and **none named** (the sidebar — unreachable
    /// by name anyway), AXStaticText 5 (the path bar). An earlier reading of
    /// mine generalised from the sidebar's anonymous cells and had the roles
    /// backwards; naming the majority role here would only have decided which
    /// launches happen without asking.
    static let navigationalOpenRoles: Set<String> = []

    /// Roles a menu path resolves to. A menu bar item is the top level ("File"),
    /// a menu item is everything below it.
    static let navigationalMenuRoles: Set<String> = ["AXMenuItem", "AXMenuBarItem"]

    /// The one refusal in this kernel that has no confirmed path past it.
    static let secureFieldSubrole = "AXSecureTextField"

    static func navigationalRoles(for action: ElementAction) -> Set<String> {
        switch action {
        case .press: return navigationalPressRoles
        case .select: return navigationalSelectRoles
        case .type: return typeableRoles
        case .open: return navigationalOpenRoles
        case .menu: return navigationalMenuRoles
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
            || reason.hasPrefix(secureFieldCaptureRefusalPrefix)
            || reason.hasPrefix(irreversibleRefusalPrefix)
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

    /// Refusal reasons as constants, so the probe can classify a decision by
    /// identity rather than by re-typing the sentence and silently missing.
    static let zeroAreaRefusalReason = "listed but not reachable: element has a zero-area frame"
    static let outsideBoundsRefusalReason = "listed but not reachable: element lies outside the visible bounds"

    /// The name is the whole identity we act on, and the app wrote it. A label
    /// that is empty, document-length, or carries a newline is not a control's
    /// name — it is content that arrived in a name-shaped field, and letting it
    /// name an action is how app-controlled text becomes an instruction.
    static let implausibleNameRefusalReason = "listed but not usable as a target: the element's name is not a plain label"

    /// Pressing a disabled menu item returns `.success` and does nothing —
    /// measured 2026-09-10 on Finder's "New Folder", which reads
    /// `AXEnabled == false` while focus is in the sidebar. Asking the item
    /// first is what makes `AXError 0` mean anything at all on this path.
    static func menuItemDisabledRefusalReason(name: String) -> String {
        "menu item \(name) is disabled (AXEnabled false) — pressing it would return success and do nothing"
    }

    /// The second refusal with no confirmed path past it, and the only one that
    /// is about the *world* rather than about us.
    ///
    /// Everything else destructive escalates to a question, because a question
    /// has an answer: a human looks at it and decides. These do not, because by
    /// the time anyone could look the thing is already gone. Emptying the bin
    /// has no undo, an erase has no undo, and money that has left an account is
    /// not a state this agent can restore. So the human does not *approve* these
    /// — the human does them, in the app, with their own hands.
    ///
    /// Owner's ruling 2026-09-10, asked for in exactly those terms. It is a real
    /// capability given up: the agent cannot empty a bin even when asked twice.
    /// That is the point — `confirmed: true` records that someone took
    /// responsibility, and no one can take responsibility for a thing they
    /// cannot inspect first.
    ///
    /// Disjoint from `destructiveTitleKeywords` by construction (there is a test),
    /// because a word in both lists would read as "asks a human" while behaving
    /// as "refuses", and the weaker line is the one someone would believe.
    static let irreversibleTitleKeywords = [
        // Emptying the bin. No undo, in any locale spelling.
        "empty trash", "empty bin",
        // Finder's Option-Command-Delete, and the word every app reaches for
        // when it means "not to the bin".
        "delete immediately", "permanently",
        // "Erase All Content and Settings", "Erase Disk", "Erase Free Space".
        // Yes, this also refuses a drawing app's "Eraser" — a false positive
        // here costs one manual click and an argument about it costs a disk.
        "erase",
        // Money. Distinct from the rest only in that the loss is someone
        // else's problem to reverse, and usually cannot be.
        "buy", "pay", "purchase"
    ]

    static let irreversibleRefusalPrefix = "refusing an irreversible action"

    static func irreversibleRefusalReason(keyword: String) -> String {
        "\(irreversibleRefusalPrefix): the title contains \"\(keyword)\" — this has no undo, "
            + "so it has no confirmed path past it either; a human does this one themselves"
    }

    /// Words that make an action worth *asking* about regardless of role — all
    /// of them reversible, or at least inspectable before the fact.
    static let destructiveTitleKeywords = [
        "delete", "remove", "send", "reset",
        // Menu-bar words. This check has always mattered; on a menu bar it
        // matters most, because "Move to Bin" and "Quit" are two items away
        // from anything. "Move to Bin" is spelled out rather than adding
        // "bin", which is a substring of "Combine All Windows".
        //
        // Deliberately NOT here: "close". Closing a window is the ordinary
        // inverse of opening one — it is what makes a menu test reversible —
        // and adding it would put a question in front of every window close.
        "trash", "quit", "empty", "eject", "log out", "shut down",
        "move to bin"
    ]

    /// Focus: the only verb here that is not evaluated by `evaluate`.
    ///
    /// It has no `ElementActionIntent`, no published action to require and no
    /// role to recognise — the target is a window, not a control — so running
    /// it through the main path would mean inventing an intent to satisfy
    /// checks that do not apply to it. Two rules do apply, and they are the two
    /// that are about *us* rather than about the action:
    ///
    ///   - more than one window matching is a question, never a coin flip, for
    ///     the same reason it is everywhere else in this kernel;
    ///   - a title is app-written text, and a name that is not a plain label is
    ///     content that arrived in a name-shaped field.
    ///
    /// Nothing else. Focus destroys nothing, and its inverse is one click on
    /// the app the caller was told it came from — a kernel that asked a human
    /// to confirm bringing a window forward would make the harness unusable,
    /// and an operator who has to answer a pointless question ten times a
    /// minute stops reading the question.
    static func evaluateFocus(windowTitle: UntrustedText?, matchCount: Int) -> SafetyDecision {
        guard matchCount == 1 else {
            return .refuse(reason: "\(matchCount) windows match that title")
        }
        if let windowTitle, !windowTitle.isPlausibleControlLabel {
            return .refuse(reason: implausibleNameRefusalReason)
        }
        return .allow
    }

    static let secureFieldCaptureRefusalPrefix = "refusing to capture a region containing a secure field"

    /// Whether a region may be photographed.
    ///
    /// One rule: **this agent does not photograph password fields.** A crop
    /// taken to disambiguate a button is still a picture of everything else in
    /// the rectangle, and a screenshot of a field mid-entry is a credential
    /// leak that no later refusal undoes — the file is already on disk.
    ///
    /// Like the typing refusal, `confirmed: true` cannot lift this. That is
    /// automatic rather than argued: `HarnessPolicy.executability` has no
    /// confirmed branch for `.refuse` at all. It is stated here because a
    /// reader of this function should not have to go and check.
    ///
    /// Note what is NOT checked: the field's value. The kernel decides on the
    /// subrole alone and never reads the text it is protecting.
    static func evaluateCapture(elementsInRegion: [AccessibilityElementNode]) -> SafetyDecision {
        if elementsInRegion.contains(where: { $0.subrole == secureFieldSubrole }) {
            return .refuse(reason: "\(secureFieldCaptureRefusalPrefix) (subrole \(secureFieldSubrole))")
        }
        return .allow
    }

    static func evaluate(
        intent: ElementActionIntent,
        resolvedNode: AccessibilityElementNode,
        matchCount: Int,
        visibleBounds: CGRect,
        typing: TypingContext? = nil,
        menuItemEnabled: Bool? = nil
    ) -> SafetyDecision {
        // Order matters. Every refusal is checked before any permission.

        // Before everything, including whether the element is even reachable:
        // a password field is refused on sight. There is no state of the world
        // and no `confirmed: true` that makes this an allow, so it is not a
        // question. It is one of exactly two rules this kernel may not be
        // argued out of — see `irreversibleTitleKeywords` for the other.
        if case .type = intent.action,
           let subrole = resolvedNode.subrole, subrole == secureFieldSubrole {
            return .refuse(reason: secureFieldRefusalReason(subrole: subrole))
        }

        // The other rule with no confirmed path past it, and it is checked here
        // — above reachability, above the menu-enabled check — because those
        // are all reasons an action *cannot* run right now, and this is a reason
        // it may never run at all.
        //
        // The ordering is not cosmetic. Measured 2026-09-10: Finder's
        // "Empty Bin…" is `AXEnabled false` while the bin is empty, so the
        // disabled check answered first and the caller was told the item was
        // disabled. That is an invitation to try again in a minute. A refusal
        // that has no path must not read like a temporary one.
        //
        // The same title may also match both keyword lists ("Empty Trash"
        // contains "trash"), so the stronger answer has to be the one reached.
        if intent.action.irreversibleNamesAreRefused,
           typing?.aimedByFocus != true,
           let name = resolvedNode.displayName {
            let lowercased = name.raw.lowercased()
            if let matchedKeyword = irreversibleTitleKeywords.first(where: { lowercased.contains($0) }) {
                return .refuse(reason: irreversibleRefusalReason(keyword: matchedKeyword))
            }
        }

        guard matchCount == 1 else {
            return .refuse(reason: "\(matchCount) elements match that title")
        }

        // Both frame checks are about one thing: is this element drawn where a
        // human could reach it. That question only has an answer for something
        // in a window.
        //
        // Measured 2026-09-10 over the harness, Finder, both menus closed:
        //
        //     AXMenuBarItem  "File"               (113, 876, 43, 24)   drawn
        //     AXMenuItem     "New Finder Window"  (  0,   0,  0,  0)   not drawn
        //     AXMenuItem     "Close Window"       (  0,   0,  0,  0)   not drawn
        //
        // The bar item has a real rectangle because it is on screen. The item
        // inside the closed menu is the project's third failure category, not a
        // failed read: AXFrame *succeeds* and answers with a degenerate value,
        // exactly like the sidebar rows that read (0, 0, 0, 0) in 2026-09-07.
        // So the zero-area refusal would refuse every menu item in every app,
        // and it would be right about the frame and wrong about the world.
        //
        // So the frame checks do not run on the menu path — stated as a
        // property of the verb (`targetHasAnOnScreenFrame`), not silently
        // skipped. Everything else the kernel does still applies, and the
        // destructive-word escalation applies harder: a menu bar is where
        // "Empty Trash" and "Quit" live.
        let frame = resolvedNode.frameInAppKitCoordinates
        if intent.action.targetHasAnOnScreenFrame {
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

        // The one fact a menu item publishes that decides everything, and the
        // one an AXError cannot tell you afterwards.
        if case .menu = intent.action {
            // No answer means nobody asked, which is our bug and not a
            // question for a human — same rule as a missing typing context.
            guard let menuItemEnabled else {
                return .refuse(reason: "no enabled state was read for this menu item")
            }
            guard menuItemEnabled else {
                return .refuse(reason: menuItemDisabledRefusalReason(
                    name: resolvedNode.displayName?.forDisplay ?? "?"
                ))
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
