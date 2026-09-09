// AX read-strategy benchmark. Run directly, no Xcode:
//
//   xcrun swiftc -O scripts/ax-read-benchmark.swift -o /tmp/axbench && /tmp/axbench Mail Finder Cursor
//
// Needs Accessibility permission for whatever process launches it (macOS assigns
// TCC to the *responsible* app, not the binary — for a shell under Claude.app,
// that is Claude.app).
//
// Measured 2026-09-09, and it corrected two overclaims:
//
//   batched vs six separate reads   ~2.5x, consistently, across Mail/Finder/Cursor.
//                                   NOT 6x. Collapsing six round trips into one
//                                   does not divide the cost by six — the batched
//                                   call still does real work.
//   Mail cold vs warm               1.33 -> 0.60 ms/node separate. Mail's famous
//                                   slowness is largely first-touch; it builds
//                                   something on first access and keeps it.
//
// Whichever strategy runs FIRST measures cold. An A/B that does not reverse its
// own order reported 14.5x for Mail, which was entirely the warm-up.

import ApplicationServices
import AppKit
import Foundation

// Does AXUIElementCopyMultipleAttributeValues actually collapse six IPC round
// trips into one? The invariants claim it takes Mail from 23 s to ~4 s. That is
// an inference from ms/node, not a measurement. This measures it.

guard AXIsProcessTrusted() else { print("no accessibility permission"); exit(1) }

let attributes = [
    kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
    kAXValueAttribute, kAXDescriptionAttribute, "AXFrame"
] as [String]

func appElement(named name: String) -> AXUIElement? {
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName == name
    }) else { return nil }
    return AXUIElementCreateApplication(app.processIdentifier)
}

func collect(_ element: AXUIElement, depth: Int, into out: inout [AXUIElement], limit: Int) {
    if out.count >= limit || depth > 40 { return }
    out.append(element)
    var childValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childValue) == .success,
          let children = childValue as? [AXUIElement] else { return }
    for child in children { collect(child, depth: depth + 1, into: &out, limit: limit) }
}

for appName in CommandLine.arguments.dropFirst() {
    guard let app = appElement(named: appName) else { print("\(appName): not running"); continue }
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2.0)

    var nodes: [AXUIElement] = []
    collect(app, depth: 0, into: &nodes, limit: 400)
    guard nodes.count > 20 else { print("\(appName): only \(nodes.count) nodes, skipping"); continue }

    // Six separate round trips per node — what the walker does today.
    let separateStart = Date()
    for node in nodes {
        for attribute in attributes {
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(node, attribute as CFString, &v)
        }
    }
    let separateMs = Date().timeIntervalSince(separateStart) * 1000

    // One batched round trip per node.
    let batchedStart = Date()
    for node in nodes {
        var values: CFArray?
        AXUIElementCopyMultipleAttributeValues(
            node, attributes as CFArray, AXCopyMultipleAttributeOptions(), &values
        )
    }
    let batchedMs = Date().timeIntervalSince(batchedStart) * 1000

    let speedup = separateMs / max(batchedMs, 0.001)
    print(String(format: "%-16s %4d nodes | separate %8.1f ms (%.2f ms/node) | batched %8.1f ms (%.2f ms/node) | %.1fx",
                 (appName as NSString).utf8String!, nodes.count,
                 separateMs, separateMs / Double(nodes.count),
                 batchedMs, batchedMs / Double(nodes.count), speedup))
}
