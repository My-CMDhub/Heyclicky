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

    private static func writeArtefacts(for snapshot: AccessibilityWindowSnapshot) async throws {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let treeText = snapshot.rootNode.map(AccessibilityTreeWalker.serializeTreeToText) ?? "(no root node)"
        let treeURL = outputDirectory.appendingPathComponent("tree.txt")
        try treeText.write(to: treeURL, atomically: true, encoding: .utf8)

        let serializedByteCount = treeText.data(using: .utf8)?.count ?? 0
        let estimatedTextTokens = treeText.count / 4

        let screenCaptures = (try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()) ?? []
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
        let estimatedVisionTokens = screenshotPixelCount / 750

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
        addressable elements   \(snapshot.nodeCount)

        SCREENSHOT PATH
        screenshot size        \(screenshotByteCount) bytes
        screenshot pixels      \(screenshotPixelCount) (\(decodedScreenshot?.pixelsWide ?? 0)x\(decodedScreenshot?.pixelsHigh ?? 0), requested \(requestedPixelCount))
        estimated vision tokens \(estimatedVisionTokens)
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
}
