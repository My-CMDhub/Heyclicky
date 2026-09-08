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

            if CommandLine.arguments.contains("--ax-overlay"),
               let rootNode = snapshot.rootNode,
               let screen = NSScreen.main {
                let boxesView = AccessibilityElementBoxesView(
                    elementNodes: rootNode.flattenedDescendants(),
                    screenFrame: screen.frame
                )
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
                panel.contentView = NSHostingView(rootView: boxesView)
                panel.orderFrontRegardless()

                try? await Task.sleep(nanoseconds: 10_000_000_000)
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
            print("🧪 J.A.R.V.I.S.: focus System Settings — \(remainingSeconds)")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // UNVERIFIED ASSUMPTION: "AXRow" is the role the plan guessed for the
        // pressable System Settings sidebar element. Task 1 Step 6 — a live
        // --ax-dump run — is what actually decides between AXRow, AXCell and
        // AXStaticText. Correct both intents below after the first live run.
        let reachableIntent = ElementActionIntent(role: "AXRow", title: "Accessibility", action: .press)
        let unreachableIntent = ElementActionIntent(role: "AXRow", title: "Privacy & Security", action: .press)

        var report: [String] = []
        report.append(attempt(reachableIntent, expectingTitleToAppear: "Accessibility"))
        report.append(attempt(unreachableIntent, expectingTitleToAppear: "Privacy & Security"))

        let reportText = report.joined(separator: "\n\n")
        print(reportText)

        let outputDirectory = URL(fileURLWithPath: "/private/tmp/jarvis-ax-action", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try? reportText.write(
            to: outputDirectory.appendingPathComponent("outcome.txt"),
            atomically: true,
            encoding: .utf8
        )

        NSApplication.shared.terminate(nil)
    }

    private static func attempt(
        _ intent: ElementActionIntent,
        expectingTitleToAppear expectedTitle: String
    ) -> String {
        guard let snapshot = try? AccessibilityTreeWalker.snapshotFocusedWindow(),
              let rootNode = snapshot.rootNode else {
            return "\(intent.title): could not read the focused window"
        }

        let resolution = ElementActionIntentResolver.resolve(intent, inTreeRootedAt: rootNode)

        let resolvedNode: AccessibilityElementNode
        let matchCount: Int
        switch resolution {
        case .notFound:
            return "\(intent.title): NOT FOUND in the tree"
        case .ambiguous(let count):
            return "\(intent.title): REFUSED — \(count) elements match that title"
        case .resolved(let node):
            resolvedNode = node
            matchCount = 1
        }

        let decision = ActionSafetyKernel.evaluate(
            intent: intent,
            resolvedNode: resolvedNode,
            matchCount: matchCount
        )

        switch decision {
        case .refuse(let reason):
            return "\(intent.title): REFUSED — \(reason)"
        case .requireConfirmation(let reason):
            return "\(intent.title): WOULD ASK FIRST — \(reason)"
        case .allow:
            break
        }

        guard let element = resolvedNode.accessibilityElement else {
            return "\(intent.title): resolved node carries no live element"
        }

        let performResult = AXUIElementPerformAction(element, intent.action.accessibilityActionName as CFString)
        guard performResult == .success else {
            return "\(intent.title): PERFORM FAILED — AXError \(performResult.rawValue)"
        }

        let outcome = ActionVerifier.verify { snapshot in
            guard let root = snapshot.rootNode else { return false }
            return root.flattenedDescendants().contains { node in
                node.title == expectedTitle && node.depth > 2
            }
        }

        switch outcome {
        case .confirmed(let milliseconds):
            return "\(intent.title): PERFORMED and VERIFIED after \(milliseconds) ms"
        case .notObserved(let milliseconds):
            return "\(intent.title): PERFORMED but NOT VERIFIED after \(milliseconds) ms — treat as failure"
        case .couldNotReadWindow:
            return "\(intent.title): PERFORMED but the window could not be re-read"
        }
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
        guard let screen = NSScreen.main else { return }

        let boxesView = AccessibilityElementBoxesView(
            elementNodes: rootNode.flattenedDescendants().filter {
                $0.frameInAppKitCoordinates.width > 0 && $0.frameInAppKitCoordinates.height > 0
            },
            screenFrame: screen.frame
        )

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
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.contentView = NSHostingView(rootView: boxesView)
        panel.orderFrontRegardless()
        surveyFlashPanel = panel

        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

        panel.orderOut(nil)
        surveyFlashPanel = nil
    }

}
