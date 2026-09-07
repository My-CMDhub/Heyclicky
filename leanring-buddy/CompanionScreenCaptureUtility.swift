//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ApplicationServices
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {

    private static let appBundleIdentifier = Bundle.main.bundleIdentifier

    /// Captures the display that contains the focused window first when possible.
    /// Falls back to all visible displays when focus cannot be resolved safely.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == appBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        if let focusedDisplayIndex = focusedDisplayIndex(in: content),
           let focusedDisplay = content.displays[safe: focusedDisplayIndex] {
            print("🎯 Capture mode: focused display first (\(focusedDisplay.displayID))")
            if let capture = try await captureDisplay(
                focusedDisplay,
                displayIndex: focusedDisplayIndex,
                totalDisplayCount: content.displays.count,
                displayLookup: nsScreenByDisplayID,
                excludingWindows: ownAppWindows,
                mouseLocation: mouseLocation,
                labelMode: .focused
            ) {
                return [capture]
            }

            print("🎯 Capture mode: focused display capture failed, falling back")
        }

        print("🎯 Capture mode: fallback all displays")

        // Sort displays so the cursor screen is always first on fallback.
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            if let capture = try await captureDisplay(
                display,
                displayIndex: displayIndex,
                totalDisplayCount: sortedDisplays.count,
                displayLookup: nsScreenByDisplayID,
                excludingWindows: ownAppWindows,
                mouseLocation: mouseLocation,
                labelMode: .fallback
            ) {
                capturedScreens.append(capture)
            }
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    static func bestDisplayIndex(for windowFrame: CGRect, among displayFrames: [CGRect]) -> Int? {
        var bestIndex: Int?
        var bestIntersectionArea: CGFloat = 0

        for (index, displayFrame) in displayFrames.enumerated() {
            let intersection = displayFrame.intersection(windowFrame)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
                continue
            }

            let area = intersection.width * intersection.height
            if area > bestIntersectionArea {
                bestIntersectionArea = area
                bestIndex = index
            }
        }

        return bestIndex
    }

    private enum CaptureLabelMode {
        case focused
        case fallback
    }

    private static func captureDisplay(
        _ display: SCDisplay,
        displayIndex: Int,
        totalDisplayCount: Int,
        displayLookup: [CGDirectDisplayID: NSScreen],
        excludingWindows: [SCWindow],
        mouseLocation: CGPoint,
        labelMode: CaptureLabelMode
    ) async throws -> CompanionScreenCapture? {
        let displayFrame = displayLookup[display.displayID]?.frame
            ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                      width: CGFloat(display.width), height: CGFloat(display.height))
        let isCursorScreen = displayFrame.contains(mouseLocation)

        let filter = SCContentFilter(display: display, excludingWindows: excludingWindows)

        let configuration = SCStreamConfiguration()
        let maxDimension = 1920
        let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
        if display.width >= display.height {
            configuration.width = maxDimension
            configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
        } else {
            configuration.height = maxDimension
            configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
        }

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            return nil
        }

        let screenLabel: String
        switch labelMode {
        case .focused:
            screenLabel = "focused screen (active window)"
        case .fallback:
            if totalDisplayCount == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(totalDisplayCount) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(totalDisplayCount) — secondary screen"
            }
        }

        return CompanionScreenCapture(
            imageData: jpegData,
            label: screenLabel,
            isCursorScreen: isCursorScreen,
            displayWidthInPoints: Int(displayFrame.width),
            displayHeightInPoints: Int(displayFrame.height),
            displayFrame: displayFrame,
            screenshotWidthInPixels: configuration.width,
            screenshotHeightInPixels: configuration.height
        )
    }

    private static func focusedDisplayIndex(in content: SCShareableContent) -> Int? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              let frontmostBundleIdentifier = frontmostApplication.bundleIdentifier,
              frontmostBundleIdentifier != appBundleIdentifier,
              let focusedWindowFrame = focusedWindowFrame(for: frontmostApplication.processIdentifier) else {
            return nil
        }

        let displayFrames = content.displays.map(\.frame)
        let focusedDisplayIndex = bestDisplayIndex(for: focusedWindowFrame, among: displayFrames)

        if let focusedDisplayIndex {
            print("🎯 Focused window frame: \(focusedWindowFrame.debugDescription)")
            print("🎯 Frontmost app: \(frontmostBundleIdentifier)")
            print("🎯 Focused display index: \(focusedDisplayIndex)")
        }

        return focusedDisplayIndex
    }

    private static func focusedWindowFrame(for processID: pid_t) -> CGRect? {
        let application = AXUIElementCreateApplication(processID)

        var focusedWindowValue: AnyObject?
        let focusedWindowResult = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )

        guard focusedWindowResult == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let focusedWindow = focusedWindowValue as! AXUIElement

        var positionValue: AnyObject?
        var sizeValue: AnyObject?

        guard AXUIElementCopyAttributeValue(focusedWindow, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(focusedWindow, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue

        var position = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return nil
        }

        let windowFrame = CGRect(origin: position, size: size)
        guard !windowFrame.isNull, windowFrame.width > 0, windowFrame.height > 0 else {
            return nil
        }

        return windowFrame
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
