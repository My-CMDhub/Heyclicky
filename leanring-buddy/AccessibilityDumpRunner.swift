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

    /// A run that could not read anything must still leave a file behind.
    ///
    /// Measured 2026-09-10: with the machine locked, four dump runs in a row
    /// printed to a console nobody was reading and wrote nothing at all, so the
    /// harness saw an empty directory and the operator saw "no result" — which
    /// looks exactly like a hang, a crash, or a stale binary. A refusal is a
    /// result and has to be written down like one.
    static func writeFailure(_ reason: String, to fileName: String = "metrics.txt") {
        let text = "RUN FAILED — \(reason)\nnothing was measured; this file exists so the absence is not silent"
        print("\n" + text)
        for directory in ["/private/tmp/jarvis-ax-dump", "/private/tmp/jarvis-ax-action"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? text.write(to: url.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        }
    }

    /// Why the window could not be read, in words rather than a nil.
    static func describeSnapshotFailure() -> String {
        do {
            _ = try AccessibilityTreeWalker.snapshotFocusedWindow()
            return "the window read succeeded on retry — the first failure was transient"
        } catch AccessibilitySnapshotError.screenIsLocked {
            return "THE SCREEN IS LOCKED. Nothing here describes the user's world; unlock and rerun."
        } catch AccessibilitySnapshotError.accessibilityPermissionNotGranted {
            return "Accessibility permission is not granted to this build"
        } catch AccessibilitySnapshotError.noFrontmostApplication {
            return "no frontmost application"
        } catch AccessibilitySnapshotError.noFocusedWindow {
            return "the frontmost application has no focused window"
        } catch {
            return "\(error)"
        }
    }


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
            writeFailure(describeSnapshotFailure())
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

            guard let actionName = intent.action.accessibilityActionName else {
                report.append("\(intent.title): this runner performs actions, and that intent is a property write")
                continue
            }
            let performResult = AccessibilityActionPerformer.perform(
                actionName,
                on: element
            ).error
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
                // The escaped form, because this set is both the diff
                // fingerprint and the text printed in the report.
                // ponytail: names longer than 100 chars collide only if they
                // share a prefix *and* a length; raise the cap if that shows up.
                .compactMap { $0.displayName?.forDisplay }
        )
    }

    /// Every name in the tree — the fingerprint to diff when the thing that
    /// changed is not a button.
    ///
    /// Measured 2026-09-10, and it cost a wrong conclusion: selecting a Finder
    /// sidebar row navigated the window (219 nodes before, 99 after) while the
    /// *pressable* set barely moved, so the verifier reported "nothing changed"
    /// about a window that had visibly changed folder. Finder has ~12 pressable
    /// elements and hundreds of files, because files are selected and
    /// double-clicked, never pressed. A fingerprint has to cover what the action
    /// can move.
    static func namedElementFingerprint(in rootNode: AccessibilityElementNode) -> Set<String> {
        Set(rootNode.flattenedDescendants().compactMap { $0.displayName?.forDisplay })
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

        // Loud, first, and phrased as a verdict — not a `true` sitting under the
        // number it invalidates. Measured 2026-09-09: Claude Desktop read as 46
        // nodes / 9 actionable for an entire session of surveys, checkpoints and a
        // retraction, with `truncated by budget true` printed under it every time.
        // Raising the depth gave 1,684 nodes and 917 actionable. Nobody read the flag.
        let truncationBanner = snapshot.wasTruncatedByBudget
            ? """
              ⚠️  TRUNCATED — every count below is a floor, not a measurement.
                  The walk stopped at depth \(snapshot.deepestLevelReached) / \(snapshot.nodeCount) nodes
                  because it \(snapshot.walkStopReasons.map(\.rawValue).sorted().joined(separator: " and ")) — OUR limit, not the end of the app's tree.
                  Do not compare this app to an untruncated one.

              """
            : ""

        let metricsText = """
        \(truncationBanner)application            \(snapshot.applicationName) (\(snapshot.bundleIdentifier))

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
        skipped far off-screen \(snapshot.subtreesSkippedFarOffScreen) subtrees, \(snapshot.nodesSkippedFarOffScreen) direct children not walked
        visible-subset window  \(snapshot.containersReducedToVisibleChildren) containers, \(snapshot.childrenElidedByVisibleSubset) children elided
        duplicate elements     \(snapshot.duplicateElementsSkipped) skipped (already in the tree by another path)
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
            writeFailure(describeSnapshotFailure())
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

            let intent = ElementActionIntent(role: node.role, title: name.raw, action: .press)
            let matchCount: Int
            switch ElementActionIntentResolver.resolve(intent, inTreeRootedAt: rootNode) {
            case .resolved:
                matchCount = 1
            case .ambiguous(let count):
                matchCount = count
                ambiguous += 1
                ambiguousNames.insert(name.forDisplay)
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
        // What WOULD separate the elements that share a name? Refusing ambiguity
        // is correct and it is also the resolver's ceiling — 19 of Mail's 42
        // pressable elements and 76 of Chrome's 158 are refused for a shared
        // name. Before designing an identifier, measure which one would work.
        if !ambiguousNames.isEmpty {
            let named = pressableNodes.filter { $0.displayName != nil }
            let groups = Dictionary(grouping: named) { $0.displayName!.raw }
                .filter { $0.value.count > 1 }

            var separatedByAncestorName = 0
            var separatedByRolePath = 0
            var separatedByFrame = 0
            var nestedDuplicates = 0
            var separatedByNeither = 0
            var nestedExamples: Set<String> = []

            for (_, siblings) in groups {
                let ancestorNames = siblings.map { node -> String in
                    guard let chain = ElementReachability.ancestorChain(to: node, from: rootNode)
                    else { return "(no chain)" }
                    return chain.dropLast().reversed()
                        .compactMap { $0.displayName?.raw }.first ?? "(unnamed ancestors)"
                }
                let rolePaths = siblings.map { node -> String in
                    guard let chain = ElementReachability.ancestorChain(to: node, from: rootNode)
                    else { return "(no chain)" }
                    return chain.map(\.role).joined(separator: "/")
                }

                // Disjoint frames are what makes a pointed-at location able to
                // choose between them — the mechanism `nearPoint` uses.
                let frames = siblings.map(\.frameInAppKitCoordinates)
                let framesAreDisjoint = frames.enumerated().allSatisfy { index, frame in
                    frames.enumerated().allSatisfy { otherIndex, other in
                        index == otherIndex || !frame.intersects(other)
                    }
                }

                // Is this one control counted twice? A wrapper and the label
                // inside it can carry the same name and nearly the same frame,
                // and nothing about that is an identity problem — it is one
                // target that appears in the tree at two depths.
                let nested = siblings.contains { outer in
                    siblings.contains { inner in
                        inner.depth > outer.depth
                            && (ElementReachability.ancestorChain(to: inner, from: outer)?.count ?? 0) > 1
                    }
                }
                if nested {
                    nestedDuplicates += 1
                    if let outer = siblings.min(by: { $0.depth < $1.depth }),
                       let inner = siblings.max(by: { $0.depth < $1.depth }) {
                        nestedExamples.insert("\(outer.role)>\(inner.role)")
                    }
                    continue
                }

                if Set(ancestorNames).count == siblings.count {
                    separatedByAncestorName += 1
                } else if Set(rolePaths).count == siblings.count {
                    separatedByRolePath += 1
                } else if framesAreDisjoint {
                    separatedByFrame += 1
                } else {
                    separatedByNeither += 1
                }
            }

            report.append("")
            report.append("IDENTITY — what would separate the \(groups.count) names shared by more than one element?")
            report.append("  nearest named ancestor \(separatedByAncestorName)")
            report.append("  role path from window  \(separatedByRolePath)   (ancestors are unnamed, roles differ)")
            report.append("  a pointed-at location  \(separatedByFrame)   (nothing structural separates them; frames are disjoint)")
            report.append("  nothing                \(separatedByNeither)   (overlapping frames too — needs a sibling index)")
            report.append("  not an identity problem \(nestedDuplicates)   (one control at two depths: \(nestedExamples.sorted().prefix(4).joined(separator: ", ")))")
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

    // MARK: - Phase 4: selecting, for the apps whose navigation cannot be pressed

    /// One end-to-end selection: resolve a name, walk up to something the app
    /// says is selectable, let the kernel decide, write, and verify by looking.
    ///
    ///     open -a Clicky.app --args --ax-select Accessibility
    static func runSelect() async {
        let wanted: String = {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: "--ax-select"),
                  arguments.indices.contains(index + 1),
                  !arguments[index + 1].hasPrefix("--") else { return "Accessibility" }
            return arguments[index + 1]
        }()

        for remainingSeconds in stride(from: 5, through: 1, by: -1) {
            print("🧪 J.A.R.V.I.S.: focus the window — selecting \(wanted) in \(remainingSeconds)")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        var report: [String] = ["SELECT \(wanted)"]

        guard let snapshot = try? AccessibilityTreeWalker.snapshotFocusedWindow(),
              let rootNode = snapshot.rootNode else {
            writeFailure(describeSnapshotFailure())
            NSApplication.shared.terminate(nil)
            return
        }
        report.append("window: \(snapshot.applicationName)   nodes: \(snapshot.nodeCount)")

        let intent = ElementActionIntent(role: nil, title: wanted, action: .select)
        let resolution = ElementActionIntentResolver.resolve(intent, inTreeRootedAt: rootNode)

        let resolvedNode: AccessibilityElementNode
        switch resolution {
        case .resolved(let node):
            resolvedNode = node
        case .notFound:
            report.append("resolve: NOT FOUND")
            finishSelect(report)
            return
        case .ambiguous(let count):
            report.append("resolve: AMBIGUOUS — \(count) elements are named that")
            finishSelect(report)
            return
        }

        let frame = resolvedNode.frameInAppKitCoordinates
        report.append("resolved: \(resolvedNode.role) \(resolvedNode.displayName?.forDisplay ?? "(unnamed)") \(frame)")

        switch ActionSafetyKernel.evaluate(
            intent: intent,
            resolvedNode: resolvedNode,
            matchCount: 1,
            visibleBounds: rootNode.frameInAppKitCoordinates
        ) {
        case .refuse(let reason):
            report.append("kernel: REFUSED — \(reason)")
            finishSelect(report)
            return
        case .requireConfirmation(let reason):
            report.append("kernel: would ask a human — \(reason). Proceeding: this is an instrumented run.")
        case .allow:
            report.append("kernel: allow")
        }

        guard let chain = ElementReachability.ancestorChain(to: resolvedNode, from: rootNode) else {
            report.append("no ancestor chain — cannot look upward for something selectable")
            finishSelect(report)
            return
        }
        report.append("chain: " + chain.map(\.role).joined(separator: " > "))

        let namesBefore = namedElementFingerprint(in: rootNode)
        let outcome = AccessibilitySelectionPerformer.select(chainFromRoot: chain)

        switch outcome {
        case .selected(let path, let levelsUp, let milliseconds, let readBackTrue):
            let selectedRole = chain[chain.count - 1 - levelsUp].role
            report.append("write: \(path.rawValue) — target \(selectedRole), \(levelsUp) level(s) above the named element, \(milliseconds) ms")
            report.append("read back: AXSelected is \(readBackTrue ? "true" : "NOT true — the write was accepted and ignored")")
        case .alreadySelected(let path, let levelsUp):
            report.append("write: skipped — \(path.rawValue) already is exactly this element, \(levelsUp) level(s) up; nothing written, nothing to verify")
            finishSelect(report)
            return
        case .writeFailed(let error, let levelsUp, let milliseconds):
            report.append("write: FAILED AXError \(error.rawValue) at \(levelsUp) level(s) up after \(milliseconds) ms")
            finishSelect(report)
            return
        case .noSelectableAncestor(let levels):
            report.append("write: nothing in \(levels) levels publishes a settable AXSelected")
            finishSelect(report)
            return
        case .noLiveElement:
            report.append("write: no live element — this tree came from a test, not a walk")
            finishSelect(report)
            return
        }

        // The read-back says the attribute took. Only a second walk says the app
        // did anything about it.
        let verification = ActionVerifier.verify { laterSnapshot in
            guard let laterRoot = laterSnapshot.rootNode else { return false }
            return namedElementFingerprint(in: laterRoot) != namesBefore
        }
        switch verification {
        case .confirmed(let milliseconds):
            report.append("verified: the world changed after \(milliseconds) ms")
            if let laterSnapshot = try? AccessibilityTreeWalker.snapshotFocusedWindow(),
               let laterRoot = laterSnapshot.rootNode {
                let appeared = namedElementFingerprint(in: laterRoot).subtracting(namesBefore).sorted()
                report.append("  appeared: \(appeared.isEmpty ? "(none)" : appeared.prefix(8).joined(separator: ", "))")
            }
        case .windowGone(let milliseconds):
            report.append("verified: the focused window closed after \(milliseconds) ms — the app reacted")
        case .notObserved(let milliseconds):
            report.append("verified: NOTHING CHANGED in \(milliseconds) ms — the write landed and the app ignored it")
        case .couldNotReadWindow:
            report.append("verified: could not read the window afterwards")
        }

        // The immediate read-back can be false while the app is still applying
        // the change. Ask again once the world has settled, so "accepted and
        // ignored" is not confused with "not yet".
        if case .selected(_, let levelsUp, _, _) = outcome,
           let element = chain[chain.count - 1 - levelsUp].accessibilityElement {
            let settled = AccessibilitySelectionPerformer.readsBackSelected(element)
            report.append("settled read-back: AXSelected is \(settled ? "true" : "still not true")")
        }

        finishSelect(report)
    }

    private static func finishSelect(_ report: [String]) {
        let text = report.joined(separator: "\n")
        print("\n" + text)
        let outputDirectory = URL(fileURLWithPath: "/private/tmp/jarvis-ax-action", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try? text.write(to: outputDirectory.appendingPathComponent("select.txt"), atomically: true, encoding: .utf8)
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Phase 3: a two-step workflow that survives a wait

    /// Presses a target, waits for the app to settle, then presses a target that
    /// **only exists after the first press**. The second step is the whole point:
    /// anything that can be resolved before acting is a one-step task in disguise.
    ///
    /// The intents are hardcoded, exactly as Phase 2's were. There is no planner
    /// and no model in this loop.
    static func runTask() async {
        for remainingSeconds in stride(from: 5, through: 1, by: -1) {
            print("🧪 J.A.R.V.I.S.: focus System Settings (General pane) — \(remainingSeconds)")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // Step one is measured, not guessed: --ax-probe confirmed on 2026-09-08
        // that System Settings publishes AXPress on this AXButton and that
        // pressing it navigates. Step two is a guess about what lives inside
        // General > About, which this run exists to correct — which is why the
        // appeared-set is printed whether or not it resolves.
        let stepOneIntent = ElementActionIntent(role: "AXButton", title: "About", action: .press)
        // Measured, no longer a guess: the 2026-09-08 run showed step one
        // produces exactly four pressable buttons — Details…, Display Settings…,
        // Storage Settings…, System Report…. This one navigates *within*
        // System Settings; System Report… launches System Information and would
        // move the focused window out from under the verifier.
        let stepTwoIntent = ElementActionIntent(role: "AXButton", title: "Storage Settings…", action: .press)

        guard let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            print("❌ no frontmost application")
            NSApplication.shared.terminate(nil)
            return
        }

        guard let snapshot = try? AccessibilityTreeWalker.snapshotFocusedWindow(),
              let rootNode = snapshot.rootNode else {
            writeFailure(describeSnapshotFailure())
            NSApplication.shared.terminate(nil)
            return
        }

        var report: [String] = []
        report.append("window: \(snapshot.applicationName) (\(snapshot.bundleIdentifier)), \(snapshot.nodeCount) nodes, walk \(String(format: "%.1f", snapshot.walkDurationInSeconds * 1000)) ms")

        let namesBeforeStepOne = pressableElementNames(in: rootNode)
        report.append("")
        report.append("PRESSABLE BEFORE STEP ONE (\(namesBeforeStepOne.count))")
        report.append("  " + (namesBeforeStepOne.sorted().joined(separator: ", ")))

        // ---- Step one -------------------------------------------------------
        report.append("")
        report.append("STEP ONE — press \"\(stepOneIntent.title)\"")
        var stepOnePerformed = false
        let firstSettleStartedAt = Date()
        let firstSettleReport = WindowSettleObserver.waitForSettle(
            processIdentifier: processIdentifier,
            performWhileArmed: {
                stepOnePerformed = performIfAllowed(
                    stepOneIntent, inTreeRootedAt: rootNode, into: &report
                )
            },
            pollFallback: { pollForChange(from: namesBeforeStepOne) }
        )
        guard stepOnePerformed else {
            finishTask(report, terminate: true)
            return
        }
        let firstSettleWallClockMilliseconds = Int(Date().timeIntervalSince(firstSettleStartedAt) * 1000)

        // ---- Re-observe ONCE ------------------------------------------------
        guard let afterSnapshot = try? AccessibilityTreeWalker.snapshotFocusedWindow(),
              let afterRootNode = afterSnapshot.rootNode else {
            report.append("❌ could not re-read the window after step one")
            finishTask(report, terminate: true)
            return
        }

        let namesAfterStepOne = pressableElementNames(in: afterRootNode)
        let appeared = namesAfterStepOne.subtracting(namesBeforeStepOne).sorted()
        let disappeared = namesBeforeStepOne.subtracting(namesAfterStepOne).sorted()

        report.append("")
        report.append("WHAT STEP ONE PRODUCED  (re-walk cost \(String(format: "%.1f", afterSnapshot.walkDurationInSeconds * 1000)) ms)")
        report.append("  appeared (\(appeared.count)):    \(appeared.isEmpty ? "(none)" : appeared.joined(separator: ", "))")
        report.append("  disappeared (\(disappeared.count)): \(disappeared.isEmpty ? "(none)" : disappeared.joined(separator: ", "))")
        if appeared.isEmpty && disappeared.isEmpty {
            report.append("  ⚠️  the pressable set is identical — step one changed nothing we can see")
        }

        // ---- Step two -------------------------------------------------------
        report.append("")
        report.append("STEP TWO — press \"\(stepTwoIntent.title)\" (exists only after step one)")

        // Phase 4: the kernel's "outside the visible bounds" refusal is the one
        // refusal with an answer — the element is real, named and pressable, it
        // is merely scrolled away. Compared against the CONSTANT, never a
        // retyped sentence: a typo here would silently scroll on a destructive
        // confirmation instead.
        var treeForStepTwo = afterRootNode
        var namesBeforeStepTwo = namesAfterStepOne

        let precheck = kernelDecision(stepTwoIntent, inTreeRootedAt: treeForStepTwo)
        if case .refuse(let reason) = precheck.decision,
           reason == ActionSafetyKernel.outsideBoundsRefusalReason,
           let unreachableNode = precheck.node {
            report.append("  REFUSED — \(reason)")
            report.append("  → answering the refusal: page its scrolling ancestor")

            let attempt = ElementReachability.makeReachable(
                node: unreachableNode,
                within: treeForStepTwo,
                visibleBounds: treeForStepTwo.frameInAppKitCoordinates,
                processIdentifier: processIdentifier
            )
            report.append(contentsOf: describe(attempt))

            // Re-evaluate FROM SCRATCH on a fresh tree. Scrolling changed one
            // input to the kernel; it granted no permission.
            if let scrolledRootNode = attempt.finalRootNode {
                treeForStepTwo = scrolledRootNode
                namesBeforeStepTwo = pressableElementNames(in: scrolledRootNode)
            }
            let recheck = kernelDecision(stepTwoIntent, inTreeRootedAt: treeForStepTwo)
            report.append("  KERNEL RE-EVALUATION (fresh tree, fresh resolve)")
            report.append("    \(describe(recheck.decision))")
        }

        var secondSettleReport: SettleReport?
        var secondSettleWallClockMilliseconds = 0

        var stepTwoPerformed = false
        let secondSettleStartedAt = Date()
        let secondReport = WindowSettleObserver.waitForSettle(
            processIdentifier: processIdentifier,
            performWhileArmed: {
                stepTwoPerformed = performIfAllowed(
                    stepTwoIntent, inTreeRootedAt: treeForStepTwo, into: &report
                )
            },
            pollFallback: { pollForChange(from: namesBeforeStepTwo) }
        )

        if stepTwoPerformed {
            secondSettleReport = secondReport
            secondSettleWallClockMilliseconds = Int(Date().timeIntervalSince(secondSettleStartedAt) * 1000)

            if let finalSnapshot = try? AccessibilityTreeWalker.snapshotFocusedWindow(),
               let finalRootNode = finalSnapshot.rootNode {
                // Diffed against the tree step two actually acted on, which is
                // the post-scroll one when a scroll happened. Diffing against
                // the pre-scroll set would credit the scroll's own changes to
                // the press.
                let namesAfterStepTwo = pressableElementNames(in: finalRootNode)
                let appearedTwo = namesAfterStepTwo.subtracting(namesBeforeStepTwo).sorted()
                let disappearedTwo = namesBeforeStepTwo.subtracting(namesAfterStepTwo).sorted()
                if namesAfterStepTwo == namesBeforeStepTwo {
                    report.append("  VERIFY: the pressable set did not change — treat step two as FAILED")
                } else {
                    report.append("  VERIFY: confirmed, the tree moved")
                    report.append("    appeared:    \(appearedTwo.isEmpty ? "(none)" : appearedTwo.joined(separator: ", "))")
                    report.append("    disappeared: \(disappearedTwo.isEmpty ? "(none)" : disappearedTwo.joined(separator: ", "))")
                }
            } else {
                report.append("  VERIFY: could not re-read the window")
            }
        } else {
            report.append("  → nothing was pressed. The appeared-set above is what step two should have named.")
        }

        // ---- The number this phase must produce ------------------------------
        report.append("")
        report.append("SETTLE REPORT — step one")
        report.append(contentsOf: describe(firstSettleReport, wallClockMilliseconds: firstSettleWallClockMilliseconds))

        if let secondSettleReport {
            report.append("")
            report.append("SETTLE REPORT — step two")
            report.append(contentsOf: describe(secondSettleReport, wallClockMilliseconds: secondSettleWallClockMilliseconds))
        }

        report.append("")
        report.append("WAITING, THREE WAYS (step one)")
        report.append("  fixed sleep(1.0)       1000 ms, 0 walks, correctness unknown — it is a guess")
        report.append("  AXObserver + debounce  \(firstSettleWallClockMilliseconds) ms, \(firstSettleReport.pollCount) walks, settled=\(firstSettleReport.settled)")

        finishTask(report, terminate: true)
    }

    /// Resolve → safety kernel, with no side effect on the machine.
    ///
    /// Split out of `performIfAllowed` so a caller can inspect *why* the kernel
    /// refused before deciding whether that refusal has an answer — a scroll
    /// answers "outside the visible bounds" and nothing else.
    private static func kernelDecision(
        _ intent: ElementActionIntent,
        inTreeRootedAt rootNode: AccessibilityElementNode
    ) -> (decision: SafetyDecision, node: AccessibilityElementNode?) {
        switch ElementActionIntentResolver.resolve(intent, inTreeRootedAt: rootNode) {
        case .notFound:
            return (.refuse(reason: "not found in the tree"), nil)
        case .ambiguous(let count):
            return (.refuse(reason: "\(count) elements match that name"), nil)
        case .resolved(let resolvedNode):
            return (
                ActionSafetyKernel.evaluate(
                    intent: intent,
                    resolvedNode: resolvedNode,
                    matchCount: 1,
                    visibleBounds: rootNode.frameInAppKitCoordinates
                ),
                resolvedNode
            )
        }
    }

    /// Resolve → safety kernel → perform, in that order, appending the reasoning.
    /// Returns whether the action actually reached the machine.
    private static func performIfAllowed(
        _ intent: ElementActionIntent,
        inTreeRootedAt rootNode: AccessibilityElementNode,
        into report: inout [String]
    ) -> Bool {
        let evaluation = kernelDecision(intent, inTreeRootedAt: rootNode)
        switch evaluation.decision {
        case .refuse(let reason):
            report.append("  \(intent.title): REFUSED — \(reason)")
            return false
        case .requireConfirmation(let reason):
            report.append("  \(intent.title): WOULD ASK FIRST — \(reason)")
            return false
        case .allow:
            break
        }

        guard let element = evaluation.node?.accessibilityElement else {
            report.append("  \(intent.title): resolved node carries no live element")
            return false
        }

        guard let actionName = intent.action.accessibilityActionName else {
            report.append("step one is a property write; this runner performs actions")
            return false
        }
        let performResult = AccessibilityActionPerformer.perform(
            actionName,
            on: element
        ).error
        guard performResult == .success else {
            report.append("  \(intent.title): PERFORM FAILED — AXError \(performResult.rawValue)")
            return false
        }

        report.append("  \(intent.title): ALLOWED and PERFORMED")
        return true
    }

    /// The poll path, unchanged, used only when the observer heard nothing.
    /// `expectation` runs once per walk, so counting calls counts walks.
    private static func pollForChange(
        from namesBefore: Set<String>,
        timeoutInSeconds: Double = 3.0
    ) -> (settled: Bool, pollCount: Int) {
        var pollCount = 0
        let outcome = ActionVerifier.verify(
            expectation: { snapshot in
                pollCount += 1
                guard let rootNode = snapshot.rootNode else { return false }
                return pressableElementNames(in: rootNode) != namesBefore
            },
            timeoutInSeconds: timeoutInSeconds
        )

        if case .confirmed = outcome {
            return (true, pollCount)
        }
        return (false, pollCount)
    }

    private static func describe(_ decision: SafetyDecision) -> String {
        switch decision {
        case .allow:
            return "ALLOW"
        case .requireConfirmation(let reason):
            return "WOULD ASK FIRST — \(reason)"
        case .refuse(let reason):
            return "REFUSED — \(reason)"
        }
    }

    private static func rectangleText(_ rectangle: CGRect) -> String {
        String(
            format: "(%.0f, %.0f, %.0f, %.0f)",
            rectangle.origin.x, rectangle.origin.y, rectangle.width, rectangle.height
        )
    }

    private static func describe(_ attempt: ReachabilityAttempt) -> [String] {
        var lines: [String] = []
        lines.append("  SCROLL ATTEMPT")
        lines.append("    scrollable ancestor  \(attempt.scrollContainerRole ?? "(none found)")\(attempt.scrollContainerName.map { " " + $0 } ?? "")")
        lines.append("    container frame      \(attempt.scrollContainerFrame.map(rectangleText) ?? "(none)")")
        lines.append("    visible bounds       \(rectangleText(attempt.visibleBoundsUsed))")
        lines.append("    direction            \(attempt.direction?.accessibilityActionName ?? "(none — already visible)")")
        lines.append("    pages spent          \(attempt.outcome.pagesSpent)")
        lines.append("    target frame before  \(rectangleText(attempt.frameBefore))")
        lines.append("    target frame after   \(rectangleText(attempt.frameAfter))")
        lines.append("    scrolled by          \(attempt.usedSyntheticScroll ? "synthetic wheel event (AX verb failed)" : "AX action")")
        lines.append("    outcome              \(attempt.outcome)")
        for (index, settleReport) in attempt.settleReports.enumerated() {
            lines.append("    SETTLE — page \(index + 1)")
            lines.append(contentsOf: describe(settleReport, wallClockMilliseconds: settleReport.millisecondsToQuiet)
                .map { "  " + $0 })
        }
        return lines
    }

    private static func describe(
        _ settleReport: SettleReport,
        wallClockMilliseconds: Int
    ) -> [String] {
        var lines: [String] = []
        lines.append("  settled                \(settleReport.settled) — \(settleReport.outcomeDescription)")
        lines.append("  wall clock             \(wallClockMilliseconds) ms")
        lines.append("  first notification     \(settleReport.millisecondsToFirstNotification.map { "\($0) ms" } ?? "(none arrived)")")
        lines.append("  quiet at               \(settleReport.millisecondsToQuiet) ms")
        lines.append("  notifications          \(settleReport.notificationCount)")
        for (name, count) in settleReport.notificationsByName.sorted(by: { $0.value > $1.value }) {
            lines.append("      \(name)  \(count)")
        }
        lines.append("  accepted by the app    \(settleReport.acceptedNotificationNames.isEmpty ? "(none)" : settleReport.acceptedNotificationNames.joined(separator: ", "))")
        lines.append("  refused by the app     \(settleReport.refusedNotificationNames.isEmpty ? "(none)" : settleReport.refusedNotificationNames.joined(separator: ", "))")
        lines.append("  fell back to polling   \(settleReport.fellBackToPolling)")
        lines.append("  tree walks spent       \(settleReport.pollCount)")
        return lines
    }

    private static func finishTask(_ report: [String], terminate: Bool) {
        let reportText = report.joined(separator: "\n")
        print("\n" + reportText)

        let outputDirectory = URL(fileURLWithPath: "/private/tmp/jarvis-ax-action", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try? reportText.write(
            to: outputDirectory.appendingPathComponent("task.txt"),
            atomically: true,
            encoding: .utf8
        )

        if terminate {
            NSApplication.shared.terminate(nil)
        }
    }

}
