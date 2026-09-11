//
//  AccessibilityStatusItems.swift
//  leanring-buddy
//
//  The right-hand side of the menu bar: status icons, read from every process
//  that owns one.
//

import AppKit
import ApplicationServices

/// Status items are NOT in any app's `kAXMenuBar`. Measured 2026-09-12: each
/// owning process publishes its own under the application element's
/// `AXExtrasMenuBar` — an `AXMenuBar` whose children are `AXMenuBarItem`s. So
/// there is no single place to read; the list is a sweep over running processes.
enum AccessibilityStatusItems {

    static let extrasMenuBarAttribute = "AXExtrasMenuBar"
    static let identifierAttribute = "AXIdentifier"
    static let messagingTimeoutInSeconds: Float = 0.5

    /// One item, without its live handle — the half a unit test can build.
    /// Names are app-written: `.raw` compares, `.forDisplay` prints.
    struct Descriptor: Equatable {
        let ownerName: String?
        let ownerBundleIdentifier: String?
        let ownerProcessIdentifier: pid_t
        let identifier: String?
        let title: UntrustedText?
        let elementDescription: UntrustedText?
        let value: UntrustedText?
        let isEnabled: Bool
        /// AppKit coordinates, converted like `liveWindows`. Never gated on:
        /// a full-screen Space slides the bar to y=-67 and `AXPress` still works.
        let frameInAppKitCoordinates: CGRect
        let publishedActionNames: [String]
        /// Cursor / Wispr / TextInputMenuAgent items carry one `AXMenu` child,
        /// readable while closed; Control Centre's carry none.
        let hasMenu: Bool

        init(
            ownerName: String?,
            ownerBundleIdentifier: String?,
            ownerProcessIdentifier: pid_t = 0,
            identifier: String?,
            title: String?,
            elementDescription: String?,
            value: String? = nil,
            isEnabled: Bool = true,
            frameInAppKitCoordinates: CGRect = .zero,
            publishedActionNames: [String] = [kAXPressAction as String],
            hasMenu: Bool = false
        ) {
            // Empty strings become nil, same rule as `WindowCandidate.title`.
            func present(_ text: String?) -> String? { (text?.isEmpty == false) ? text : nil }
            self.ownerName = present(ownerName)
            self.ownerBundleIdentifier = present(ownerBundleIdentifier)
            self.ownerProcessIdentifier = ownerProcessIdentifier
            self.identifier = present(identifier)
            self.title = present(title).map(UntrustedText.init)
            self.elementDescription = present(elementDescription).map(UntrustedText.init)
            self.value = present(value).map(UntrustedText.init)
            self.isEnabled = isEnabled
            self.frameInAppKitCoordinates = frameInAppKitCoordinates
            self.publishedActionNames = publishedActionNames
            self.hasMenu = hasMenu
        }

        /// The best name for a listing: identifier, then title, then
        /// description, then the owner — anonymous items are only named by
        /// the process that owns them.
        var bestName: String {
            identifier ?? title?.raw ?? elementDescription?.raw ?? "<owner: \(ownerName ?? ownerBundleIdentifier ?? "pid \(ownerProcessIdentifier)")>"
        }
    }

    /// A descriptor plus the live handle the press needs.
    struct Item {
        let descriptor: Descriptor
        let element: AXUIElement
    }

    // MARK: - Matching (pure)

    enum MatchTier: String {
        case identifier, name, owner
    }

    enum Resolution: Equatable {
        case resolved(index: Int, tier: MatchTier)
        case ambiguous(matchCount: Int, tier: MatchTier)
        case notFound(available: [String])
    }

    /// Tiers in order, first tier with any match wins, more than one in a tier
    /// is ambiguous — `AccessibilityWindows.matchApplication`'s rule. Exact and
    /// case-insensitive only: System Settings publishes "Wi‑Fi" with U+2011, and
    /// ASCII "Wi-Fi" is `notFound` by design (CLAUDE.md, names match exactly).
    static func match(_ query: String, among candidates: [Descriptor]) -> Resolution {
        let wanted = query.lowercased()
        let tiers: [(MatchTier, (Descriptor) -> Bool)] = [
            (.identifier, { $0.identifier?.lowercased() == wanted }),
            (.name, { $0.title?.raw.lowercased() == wanted || $0.elementDescription?.raw.lowercased() == wanted }),
            (.owner, { $0.ownerBundleIdentifier?.lowercased() == wanted || $0.ownerName?.lowercased() == wanted })
        ]
        for (tier, matches) in tiers {
            let indices = candidates.indices.filter { matches(candidates[$0]) }
            switch indices.count {
            case 0: continue
            case 1: return .resolved(index: indices[0], tier: tier)
            default: return .ambiguous(matchCount: indices.count, tier: tier)
            }
        }
        return .notFound(available: candidates.map(\.bestName).sorted())
    }

    // MARK: - Security (pure)

    /// A credential manager's status item is refused like a secure field: its
    /// dropdown IS the password list.
    static let secureOwnerBundleIdentifiers: Set<String> = ["com.apple.Passwords.MenuBarExtra"]

    static func isSecure(_ descriptor: Descriptor) -> Bool {
        descriptor.ownerBundleIdentifier.map(secureOwnerBundleIdentifiers.contains) ?? false
    }

    // MARK: - The live read

    /// Batched per child, like `AccessibilityMenu.liveChildren`.
    static let batchedAttributes: [String] = [
        kAXRoleAttribute as String, kAXTitleAttribute as String, kAXDescriptionAttribute as String,
        kAXValueAttribute as String, identifierAttribute, AccessibilityMenu.enabledAttribute,
        AccessibilityWindows.frameAttribute, kAXChildrenAttribute as String
    ]

    /// Every status item on the machine, from every `.regular`/`.accessory`
    /// process. Measured 2026-09-12: 25-40 ms per process regardless of answer,
    /// and the 23 `.prohibited` processes held none — skipping them is the
    /// only cut that costs nothing.
    static func readAll() -> (items: [Item], processesAsked: Int, processesAnswered: Int, milliseconds: Int) {
        let startedAt = Date()
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeoutInSeconds)
        let primaryDisplayHeight = NSScreen.screens.first?.frame.height ?? 0

        var items: [Item] = []
        var asked = 0
        var answered = 0
        for application in NSWorkspace.shared.runningApplications
        where application.activationPolicy == .regular || application.activationPolicy == .accessory {
            asked += 1
            let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
            var barValue: AnyObject?
            guard AXUIElementCopyAttributeValue(applicationElement, extrasMenuBarAttribute as CFString, &barValue) == .success,
                  let barValue, CFGetTypeID(barValue) == AXUIElementGetTypeID() else { continue }
            var childrenValue: AnyObject?
            guard AXUIElementCopyAttributeValue(barValue as! AXUIElement, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let children = childrenValue as? [AXUIElement] else { continue }
            answered += 1

            for child in children {
                var rawValues: CFArray?
                let batchResult = AXUIElementCopyMultipleAttributeValues(
                    child, batchedAttributes as CFArray, AXCopyMultipleAttributeOptions(), &rawValues
                )
                let values = (batchResult == .success ? rawValues as? [AnyObject] : nil) ?? []
                func entry(_ index: Int) -> AnyObject? {
                    guard index < values.count else { return nil }
                    let value = values[index]
                    // A failed attribute is an AXValue wrapping an AXError, not a gap.
                    if CFGetTypeID(value) == AXValueGetTypeID(),
                       AXValueGetType(value as! AXValue) == .axError { return nil }
                    return value
                }
                guard (entry(0) as? String) == AccessibilityMenu.menuBarItemRole else { continue }

                var frame = CGRect.zero
                if let frameValue = entry(6), CFGetTypeID(frameValue) == AXValueGetTypeID() {
                    var rect = CGRect.zero
                    if AXValueGetValue(frameValue as! AXValue, .cgRect, &rect) { frame = rect }
                }

                items.append(Item(
                    descriptor: Descriptor(
                        ownerName: application.localizedName,
                        ownerBundleIdentifier: application.bundleIdentifier,
                        ownerProcessIdentifier: application.processIdentifier,
                        identifier: entry(4) as? String,
                        title: entry(1) as? String,
                        elementDescription: entry(2) as? String,
                        value: entry(3) as? String,
                        isEnabled: (entry(5) as? Bool) ?? true,
                        frameInAppKitCoordinates: AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(
                            frame, primaryDisplayHeightInPoints: primaryDisplayHeight
                        ),
                        publishedActionNames: AccessibilityTreeWalker.copyActionNames(from: child),
                        hasMenu: !((entry(7) as? [AXUIElement]) ?? []).isEmpty
                    ),
                    element: child
                ))
            }
        }
        return (items, asked, answered, Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    /// `AXSelected` on the item. Measured 2026-09-12 on Cursor's status menu:
    /// the only thing the press moved — false -> true while the menu is open.
    static func isSelected(_ element: AXUIElement) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedAttribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    /// The item's live child count — one of the things a press can move.
    static func childCount(of element: AXUIElement) -> Int {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return 0 }
        return (value as? [AXUIElement])?.count ?? 0
    }
}
