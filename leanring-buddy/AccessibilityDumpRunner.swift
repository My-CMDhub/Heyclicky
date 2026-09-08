//
//  AccessibilityDumpRunner.swift
//  leanring-buddy
//
//  Debug entry point for Phase 1. Runs headlessly via the --ax-dump launch
//  argument and terminates, so we can measure the accessibility path without
//  running xcodebuild (which would invalidate this app's TCC permissions).
//

import AppKit
import ApplicationServices
import SwiftUI

@MainActor
enum AccessibilityDumpRunner {

    /// Held across samples so the flash panel is not deallocated mid-display.
    private static var surveyFlashPanel: NSPanel?

    private static let outputDirectory = URL(
        fileURLWithPath: "/private/tmp/jarvis-ax-dump",
        isDirectory: true
    )

    static func run() async {
        // At launch the frontmost window is Xcode, not the app we want to
        // inspect. The countdown is the whole reason this is usable.
        // Check permission BEFORE the countdown. The app Xcode runs is
        // Clicky.app inside DerivedData — a different bundle identifier and
        // signing team from any released copy, so macOS treats it as an
        // entirely separate program with its own permission grant.
        guard AXIsProcessTrusted() else {
            print("❌ J.A.R.V.I.S.: this build has no Accessibility permission.")
            print("   Bundle: \(Bundle.main.bundleIdentifier ?? "unknown")")
            print("   Path:   \(Bundle.main.bundlePath)")
            print("   Granting it to a different Clicky build does not count.")
            WindowPositionManager.requestAccessibilityPermission()
            print("   Approve the prompt (or add the path above in System Settings), then run again.")
            NSApplication.shared.terminate(nil)
            return
        }

        for remainingSeconds in stride(from: 5, through: 1, by: -1) {
            print("🧪 J.A.R.V.I.S.: focus the app you want to inspect — \(remainingSeconds)")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        do {
            let snapshot = try AccessibilityTreeWalker.snapshotFocusedWindow()
            try await writeArtefacts(for: snapshot)

            if CommandLine.arguments.contains("--ax-overlay") {
                if let rootNode = snapshot.rootNode {
                    await flashElementBoxes(for: rootNode, seconds: 12)
                } else {
                    print("⚠️  --ax-overlay: no root node to draw")
                }
            }

        } catch AccessibilitySnapshotError.accessibilityPermissionNotGranted {
            print("❌ J.A.R.V.I.S.: Accessibility permission not granted.")
            print("   System Settings → Privacy & Security → Accessibility → enable this app.")
        } catch AccessibilitySnapshotError.noFrontmostApplication {
            print("❌ J.A.R.V.I.S.: no frontmost application.")
        } catch AccessibilitySnapshotError.noFocusedWindow {
            print("❌ J.A.R.V.I.S.: frontmost app has no focused window (Finder desktop or fullscreen?).")
        } catch {
            print("❌ J.A.R.V.I.S.: dump failed: \(error)")
        }

        NSApplication.shared.terminate(nil)
    }

    static func runAction() async {
        for remainingSeconds in stride(from: 5, through: 1, by: -1) {
            print("🧪 J.A.R.V.I.S.: focus System Settings (General pane) — \(remainingSeconds)")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // Measured 2026-09-08, not assumed. In System Settings AXPress exists only
        // on AXButton: sidebar rows publish AXShowDefaultUI/AXShowAlternateUI and
        // their labels publish AXShowMenu, so the app's primary navigation cannot
        // be pressed through the action API at all.
        let intents = [
            ElementActionIntent(role: "AXButton", title: "About", action: .press),
            ElementActionIntent(role: "AXButton", title: "Transfer or Reset", action: .press),
            ElementActionIntent(role: "AXStaticText", title: "Accessibility", action: .press),
            ElementActionIntent(role: "AXStaticText", title: "Privacy & Security", action: .press)
        ]

        // ONE observation, and every decision is made against it.
        //
        // The first version re-walked before each intent, which meant the press
        // changed the window and the following intents were judged against a
        // world that no longer contained them — "Transfer or Reset: NOT FOUND"
        // was our own action erasing the evidence. A planner does not get to
        // re-observe between deciding and acting, because acting is what moves
        // the ground.
        guard let snapshot = try? AccessibilityTreeWalker.snapshotFocusedWindow(),
              let rootNode = snapshot.rootNode else {
            print("❌ could not read the focused window")
            NSApplication.shared.terminate(nil)
            return
        }

        var report = ["window: \(snapshot.applicationName), \(snapshot.nodeCount) nodes", ""]
        var approvedActions: [(ElementActionIntent, AccessibilityElementNode)] = []

        for intent in intents {
            switch ElementActionIntentResolver.resolve(intent, inTreeRootedAt: rootNode) {
            case .notFound:
                report.append("\(intent.title): NOT FOUND in the tree")
            case .ambiguous(let count):
                report.append("\(intent.title): REFUSED — \(count) elements match that name")
            case .resolved(let node):
                let decision = ActionSafetyKernel.evaluate(
                    intent: intent,
                    resolvedNode: node,
                    matchCount: 1,
                    visibleBounds: rootNode.frameInAppKitCoordinates
                )
                switch decision {
                case .refuse(let reason):
                    report.append("\(intent.title): REFUSED — \(reason)")
                case .requireConfirmation(let reason):
                    report.append("\(intent.title): WOULD ASK FIRST — \(reason)")
                case .allow:
                    report.append("\(intent.title): ALLOWED")
                    approvedActions.append((intent, node))
                }
            }
        }

        report.append("")

        // What the world looks like before we touch it.
        let namesBefore = pressableElementNames(in: rootNode)

        for (intent, node) in approvedActions {
            guard let element = node.accessibilityElement else {
                report.append("\(intent.title): resolved node carries no live element")
                continue
            }

            let performResult = AXUIElementPerformAction(
                element,
                intent.action.accessibilityActionName as CFString
            )
            guard performResult == .success else {
                report.append("\(intent.title): PERFORM FAILED — AXError \(performResult.rawValue)")
                continue
            }

            report.append(contentsOf: verifyWorldChanged(from: namesBefore, forIntent: intent))
        }

        let reportText = report.joined(separator: "\n")
        print("\n" + reportText)

        let outputDirectory = URL(fileURLWithPath: "/private/tmp/jarvis-ax-action", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try? reportText.write(
            to: outputDirectory.appendingPathComponent("outcome.txt"),
            atomically: true,
            encoding: .utf8
        )

        NSApplication.shared.terminate(nil)
    }

    /// The names of everything pressable in a tree — the fingerprint we diff to
    /// decide whether an action did anything.
    private static func pressableElementNames(in rootNode: AccessibilityElementNode) -> Set<String> {
        Set(
            rootNode.flattenedDescendants()
                .filter { $0.isActionable && $0.publishedActionNames.contains(kAXPressAction) }
                .compactMap(\.displayName)
        )
    }

    /// Re-walks until the set of pressable elements differs from before, or the
    /// budget expires.
    ///
    /// The previous predicate asked whether a node's **title** matched. Zero nodes
    /// in System Settings carry a title, so it could never be satisfied — the
    /// press worked and the verifier reported failure. Comparing names via
    /// displayName, and diffing the whole set rather than hunting one label, is
    /// both correct here and app-agnostic: it asks "did the world move", which is
    /// the question, instead of "is this specific string present", which is a
    /// guess about the app.
    private static func verifyWorldChanged(
        from namesBefore: Set<String>,
        forIntent intent: ElementActionIntent,
        timeoutInSeconds: Double = 3.0
    ) -> [String] {
        let startedAt = Date()

        while Date().timeIntervalSince(startedAt) < timeoutInSeconds {
            if let snapshot = try? AccessibilityTreeWalker.snapshotFocusedWindow(),
               let rootNode = snapshot.rootNode {
                let namesAfter = pressableElementNames(in: rootNode)
                if namesAfter != namesBefore {
                    let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                    let appeared = namesAfter.subtracting(namesBefore).sorted()
                    let disappeared = namesBefore.subtracting(namesAfter).sorted()
                    return [
                        "\(intent.title): PERFORMED and VERIFIED after \(elapsed) ms",
                        "  appeared:    \(appeared.isEmpty ? "(none)" : appeared.joined(separator: ", "))",
                        "  disappeared: \(disappeared.isEmpty ? "(none)" : disappeared.joined(separator: ", "))"
                    ]
                }
            }
            Thread.sleep(forTimeInterval: 0.15)
        }

        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        return ["\(intent.title): PERFORMED but the tree did not change after \(elapsed) ms — treat as failure"]
    }

    private static func writeArtefacts(for snapshot: AccessibilityWindowSnapshot) async throws {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        // Not the node count. An element only counts if it has a name, publishes
        // an action, and occupies space — the number Phase 1 is meant to end on.
        let actionableElementCount = snapshot.rootNode?
            .flattenedDescendants()
            .filter(\.isActionable)
            .count ?? 0

        let treeText = snapshot.rootNode.map(AccessibilityTreeWalker.serializeTreeToText) ?? "(no root node)"
        let treeURL = outputDirectory.appendingPathComponent("tree.txt")
        try treeText.write(to: treeURL, atomically: true, encoding: .utf8)

        let serializedByteCount = treeText.data(using: .utf8)?.count ?? 0
        let estimatedTextTokens = treeText.count / 4

        // We had never timed the screenshot path, which left "structure is faster"
        // an assertion rather than a measurement.
        let captureStartedAt = Date()
        let screenCaptures = (try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()) ?? []
        let captureDurationInMilliseconds = Date().timeIntervalSince(captureStartedAt) * 1000
        let primaryCapture = screenCaptures.first

        let screenshotByteCount = primaryCapture?.imageData.count ?? 0

        // Measure the JPEG we would actually send, not the size we requested.
        // CompanionScreenCapture records SCStreamConfiguration's requested
        // width and height, which ScreenCaptureKit is free to not honour.
        let decodedScreenshot = primaryCapture.flatMap { NSBitmapImageRep(data: $0.imageData) }
        let screenshotPixelCount = (decodedScreenshot?.pixelsWide ?? 0)
            * (decodedScreenshot?.pixelsHigh ?? 0)
        let requestedPixelCount = (primaryCapture?.screenshotWidthInPixels ?? 0)
            * (primaryCapture?.screenshotHeightInPixels ?? 0)
        // Anthropic's documented approximation for image tokens.
        // Claude does not tokenise images by pixel count. It reads them in 28x28
        // patches, so an image costs ceil(w/28) * ceil(h/28) visual tokens, after
        // being downscaled to fit the model's resolution tier. The old
        // pixels/750 estimate was wrong in both the formula and the direction:
        // it reported 3072 tokens for this capture when the real figure on the
        // model this app actually ships with is about 1550.
        let estimatedVisionTokens = estimatedVisualTokens(
            width: decodedScreenshot?.pixelsWide ?? 0,
            height: decodedScreenshot?.pixelsHigh ?? 0,
            usesHighResolutionTier: false
        )

        let metricsText = """
        application            \(snapshot.applicationName) (\(snapshot.bundleIdentifier))

        ACCESSIBILITY PATH
        walk duration          \(String(format: "%.1f", snapshot.walkDurationInSeconds * 1000)) ms
        nodes visited          \(snapshot.nodeCount)
        deepest level reached  \(snapshot.deepestLevelReached)
        truncated by budget    \(snapshot.wasTruncatedByBudget)
        timed-out nodes        \(snapshot.timedOutNodePaths.count)
        frameless nodes        \(snapshot.nodesWithoutReadableFrame)
        serialised size        \(serializedByteCount) bytes
        estimated text tokens  \(estimatedTextTokens)
        nodes walked           \(snapshot.nodeCount)
        subtrees lost to error \(snapshot.subtreesLostToFailedReads)
        focus changed mid-walk \(snapshot.focusChangedDuringWalk)
        ACTIONABLE elements    \(actionableElementCount)

        SCREENSHOT PATH
        capture duration       \(String(format: "%.1f", captureDurationInMilliseconds)) ms
        screenshot size        \(screenshotByteCount) bytes
        screenshot pixels      \(screenshotPixelCount) (\(decodedScreenshot?.pixelsWide ?? 0)x\(decodedScreenshot?.pixelsHigh ?? 0), requested \(requestedPixelCount))
        estimated vision tokens \(estimatedVisionTokens) (standard tier, 28x28 patches)
        addressable elements   0
        """

        let metricsURL = outputDirectory.appendingPathComponent("metrics.txt")
        try metricsText.write(to: metricsURL, atomically: true, encoding: .utf8)

        print("🧪 J.A.R.V.I.S.: wrote \(treeURL.path)")
        print("🧪 J.A.R.V.I.S.: wrote \(metricsURL.path)")
        print(metricsText)

        if !snapshot.timedOutNodePaths.isEmpty {
            print("⚠️  timed out reading: \(snapshot.timedOutNodePaths.joined(separator: ", "))")
        }
    }

    /// Visual-token cost of an image, per Anthropic's documented rule.
    ///
    /// Claude views images in 28x28 pixel patches, so an image costs
    /// ceil(width / 28) * ceil(height / 28) visual tokens. Oversized images are
    /// first downscaled to fit the model's tier, preserving aspect ratio:
    ///   standard tier (Sonnet 4.6 and earlier): long edge 1568, cap 1568 tokens
    ///   high-resolution tier (Claude 4.7 and later): long edge 2576, cap 4784
    /// CompanionManager defaults to claude-sonnet-4-6, which is standard tier.
    static func estimatedVisualTokens(
        width: Int,
        height: Int,
        usesHighResolutionTier: Bool
    ) -> Int {
        guard width > 0, height > 0 else { return 0 }

        let longEdgeLimit = usesHighResolutionTier ? 2576.0 : 1568.0
        let visualTokenLimit = usesHighResolutionTier ? 4784 : 1568

        let imageWidth = Double(width)
        let imageHeight = Double(height)

        var scale = min(1.0, longEdgeLimit / max(imageWidth, imageHeight))

        func tokenCount(at scale: Double) -> Int {
            let scaledWidth = (imageWidth * scale / 28.0).rounded(.up)
            let scaledHeight = (imageHeight * scale / 28.0).rounded(.up)
            return Int(scaledWidth * scaledHeight)
        }

        // Shrink until the patch count fits the tier's cap. The closed-form
        // solution is exact before the per-axis ceiling, so at most a couple of
        // corrective steps are ever needed.
        while tokenCount(at: scale) > visualTokenLimit, scale > 0.01 {
            scale *= 0.98
        }

        return tokenCount(at: scale)
    }


    /// Walks whichever window is focused, once every few seconds, appending one
    /// CSV row per app. One run, many apps — because a conclusion drawn from a
    /// single application is a conclusion about that application.
    ///
    /// The screenshot side is deliberately not re-measured: a capture of the same
    /// display always costs the same number of visual tokens regardless of which
    /// app is in front, so it is a constant, not a variable.
    static func runSurvey(sampleCount: Int = 8, secondsBetweenSamples: Int = 6) async {
        let outputDirectory = URL(fileURLWithPath: "/private/tmp/jarvis-ax-dump", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let surveyURL = outputDirectory.appendingPathComponent("survey.csv")

        var rows = ["app,bundle,nodes,depth,truncated,walk_ms,bytes,est_tokens,actionable,pressable"]

        for sampleIndex in 1...sampleCount {
            for remaining in stride(from: secondsBetweenSamples, through: 1, by: -1) {
                print("🧪 sample \(sampleIndex)/\(sampleCount): focus an app — \(remaining)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            guard let snapshot = try? AccessibilityTreeWalker.snapshotFocusedWindow(),
                  let rootNode = snapshot.rootNode else {
                print("⚠️  sample \(sampleIndex): no readable focused window")
                rows.append("(unreadable),,,,,,,,,")
                continue
            }

            let allNodes = rootNode.flattenedDescendants()
            let serialized = AccessibilityTreeWalker.serializeTreeToText(rootNode)
            let byteCount = serialized.data(using: .utf8)?.count ?? 0
            let pressableCount = allNodes.filter {
                $0.isActionable && $0.publishedActionNames.contains(kAXPressAction)
            }.count

            let row = [
                "\"\(snapshot.applicationName)\"",
                snapshot.bundleIdentifier,
                "\(snapshot.nodeCount)",
                "\(snapshot.deepestLevelReached)",
                "\(snapshot.wasTruncatedByBudget)",
                String(format: "%.1f", snapshot.walkDurationInSeconds * 1000),
                "\(byteCount)",
                "\(serialized.count / 4)",
                "\(allNodes.filter(\.isActionable).count)",
                "\(pressableCount)"
            ].joined(separator: ",")

            rows.append(row)
            print("🧪 \(snapshot.applicationName): \(snapshot.nodeCount) nodes, \(allNodes.filter(\.isActionable).count) actionable, \(pressableCount) pressable")

            // Flash the boxes so the operator can see the sample landed, and on
            // which window, before moving to the next app.
            await flashElementBoxes(for: rootNode, seconds: 1.2)
        }

        let csv = rows.joined(separator: "\n")
        try? csv.write(to: surveyURL, atomically: true, encoding: .utf8)
        print("\n" + csv)
        print("\n🧪 wrote \(surveyURL.path)")

        NSApplication.shared.terminate(nil)
    }


    /// Draws the walked elements for a moment, then clears. Purely operator
    /// feedback: it says "this sample captured THIS window", which is the one
    /// thing a console line cannot confirm while you are switching apps.
    private static func flashElementBoxes(
        for rootNode: AccessibilityElementNode,
        seconds: Double
    ) async {
        // Only elements with real geometry. A zero-area frame would draw an
        // invisible box at the corner of the display and tell you nothing.
        let drawableNodes = rootNode.flattenedDescendants().filter {
            $0.frameInAppKitCoordinates.width > 0 && $0.frameInAppKitCoordinates.height > 0
        }
        guard !drawableNodes.isEmpty else {
            print("⚠️  overlay: no element has a non-zero frame")
            return
        }

        // NSScreen.main is "the screen with the key window". This app is
        // LSUIElement and non-activating, so it often has no key window and
        // .main comes back nil or points at the wrong display — which silently
        // skipped the whole overlay. Pick the screen the inspected window is
        // actually on, and say so if we cannot.
        let windowFrame = rootNode.frameInAppKitCoordinates
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(windowFrame) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else {
            print("⚠️  overlay: no screen available")
            return
        }

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: AccessibilityElementBoxesView(
                elementNodes: drawableNodes,
                screenFrame: screen.frame
            )
        )
        panel.orderFrontRegardless()

        // Held in a static: a local NSPanel is not retained by AppKit's window
        // list, so it could be deallocated while still ordered in.
        surveyFlashPanel = panel

        print("🟦 overlay: \(drawableNodes.count) boxes on \(Int(screen.frame.width))x\(Int(screen.frame.height)) for \(Int(seconds))s")

        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

        panel.orderOut(nil)
        surveyFlashPanel = nil
    }

    /// Asks one question about whatever window is focused, and presses nothing:
    /// **of everything on this screen that can be pressed, how much of it can the
    /// runtime actually name, judge and target?**
    ///
    /// The core of it is a round trip. For each pressable element we take the name
    /// the app gave it, feed that name back through the resolver, and check we get
    /// the same element back. A name that resolves to two elements cannot be
    /// targeted; an element with no name cannot be spoken about at all.
    ///
    /// Safe to run on any app: it performs no action.
    static func runProbe() async {
        for remainingSeconds in stride(from: 5, through: 1, by: -1) {
            print("🧪 J.A.R.V.I.S.: focus the window to audit — \(remainingSeconds)")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        guard let snapshot = try? AccessibilityTreeWalker.snapshotFocusedWindow(),
              let rootNode = snapshot.rootNode else {
            print("❌ could not read the focused window")
            NSApplication.shared.terminate(nil)
            return
        }

        let allNodes = rootNode.flattenedDescendants()
        let pressableNodes = allNodes.filter { $0.publishedActionNames.contains(kAXPressAction) }

        var unnamed = 0
        var ambiguous = 0
        var allowed = 0
        var needsConfirmation = 0
        var needsScrollFirst = 0
        var refusalsByReason: [String: Int] = [:]
        var ambiguousNames: Set<String> = []

        for node in pressableNodes {
            guard let name = node.displayName else {
                unnamed += 1
                continue
            }

            let intent = ElementActionIntent(role: node.role, title: name, action: .press)
            let matchCount: Int
            switch ElementActionIntentResolver.resolve(intent, inTreeRootedAt: rootNode) {
            case .resolved:
                matchCount = 1
            case .ambiguous(let count):
                matchCount = count
                ambiguous += 1
                ambiguousNames.insert(name)
            case .notFound:
                matchCount = 0
            }

            switch ActionSafetyKernel.evaluate(
                intent: intent,
                resolvedNode: node,
                matchCount: matchCount,
                visibleBounds: rootNode.frameInAppKitCoordinates
            ) {
            case .allow:
                allowed += 1
            case .requireConfirmation:
                needsConfirmation += 1
            case .refuse(let reason):
                // An element with a real frame that sits outside the viewport is
                // not unreachable — it is unreachable *yet*. GitHub put 79 of 118
                // pressable elements below the fold; counting those as failures
                // hides that "cannot act" and "cannot act yet" need completely
                // different responses.
                if reason == ActionSafetyKernel.outsideBoundsRefusalReason {
                    needsScrollFirst += 1
                } else {
                    let key = reason.contains("match that") ? "name is not unique" : reason
                    refusalsByReason[key, default: 0] += 1
                }
            }
        }

        let pressableCount = pressableNodes.count
        let targetable = allowed + needsConfirmation
        let percentage = pressableCount == 0 ? 0 : Int(Double(targetable) / Double(pressableCount) * 100)
        let reachablePercentage = pressableCount == 0
            ? 0
            : Int(Double(targetable + needsScrollFirst) / Double(pressableCount) * 100)

        var report: [String] = []
        report.append("window: \(snapshot.applicationName) (\(snapshot.bundleIdentifier))")
        report.append("nodes: \(snapshot.nodeCount)   actionable: \(allNodes.filter(\.isActionable).count)   pressable: \(pressableCount)")
        report.append("")
        report.append("NAMING — can the runtime say which element it means?")
        report.append("  named and unique       \(pressableCount - unnamed - ambiguous)")
        report.append("  name shared by others  \(ambiguous)")
        if !ambiguousNames.isEmpty {
            report.append("      e.g. \(ambiguousNames.sorted().prefix(4).joined(separator: ", "))")
        }
        report.append("  no name at all         \(unnamed)")
        report.append("")
        report.append("SAFETY KERNEL — dry run, nothing was pressed")
        report.append("  allow                  \(allowed)")
        report.append("  requireConfirmation    \(needsConfirmation)")
        for (reason, count) in refusalsByReason.sorted(by: { $0.value > $1.value }) {
            report.append("  refuse: \(reason)  \(count)")
        }
        report.append("")
        report.append("REACHABILITY")
        report.append("  actionable now         \(targetable)")
        report.append("  needs a scroll first   \(needsScrollFirst)   (real frame, outside the viewport)")
        report.append("  not addressable        \(pressableCount - targetable - needsScrollFirst)   (no name, ambiguous, or zero-area)")
        report.append("")
        report.append("READINESS  \(targetable) of \(pressableCount) pressable elements (\(percentage)%) actionable right now")
        report.append("           \(targetable + needsScrollFirst) of \(pressableCount) (\(reachablePercentage)%) once scrolling is a verb the runtime has")

        if snapshot.focusChangedDuringWalk {
            report.append("⚠️  focus changed during the walk — these numbers describe a moving target")
        }

        let reportText = report.joined(separator: "\n")
        print("\n" + reportText)

        let outputDirectory = URL(fileURLWithPath: "/private/tmp/jarvis-ax-action", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let fileName = "probe-\(snapshot.applicationName.replacingOccurrences(of: " ", with: "-")).txt"
        try? reportText.write(to: outputDirectory.appendingPathComponent(fileName), atomically: true, encoding: .utf8)

        // Draw what it just judged, so the screen and the numbers can be compared.
        if CommandLine.arguments.contains("--ax-overlay") {
            await flashElementBoxes(for: rootNode, seconds: 12)
        }

        NSApplication.shared.terminate(nil)
    }

}
