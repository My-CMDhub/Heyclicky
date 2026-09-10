//
//  EscalationLadder.swift
//  leanring-buddy
//
//  Phase 4: what the harness hands back when a NAME did not resolve.
//
//  The ladder is structure → targeted crop → full vision, and the important
//  thing about this file is which of those three it does NOT do. There is no
//  model here, no network call, no prompt. `notFound` and `ambiguous` are the
//  two answers a tree walk cannot improve on its own, so escalation produces
//  **the smallest picture that would let somebody else decide**, the structural
//  candidates inside that picture, and — for each candidate — a point that
//  provably picks it out. A caller outside looks at the image and re-issues the
//  same intent with that point as `nearPoint`, which `ElementActionIntent` has
//  accepted since Phase 2 and which nothing has ever produced. This is the
//  producer.
//
//  So the tree stays a local index and never becomes a prompt payload: the
//  image is what travels, and the frames stay here to aim with.
//
//  The crop happens at CAPTURE time (`SCStreamConfiguration.sourceRect`), not
//  after. Capturing the display and cropping the CGImage would throw away
//  exactly the resolution that makes a crop worth taking — the case for this
//  rung is sharpness, not bytes.
//

import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit

enum EscalationLadder {

    /// Which rung answered.
    ///
    /// `none` is the rung the ladder starts on and the one this file never
    /// returns: it means structure resolved the name, so no image is taken at
    /// all. On the wire it is represented by the **absence** of an `escalation`
    /// block, and `HarnessPolicy.decode` refuses it as a forced `tier` for the
    /// same reason — "force the rung that takes no picture" is not a request.
    enum Tier: String, CaseIterable {
        case none
        case element
        case window
        case display
    }

    /// How much context to keep around a candidate's own frame. A button
    /// cropped to its exact rectangle is unreadable — a caller needs to see
    /// what is beside it to tell two of them apart.
    static let candidatePaddingInPoints: CGFloat = 24

    /// Neither dimension of the returned image may exceed this. A 6K display at
    /// 2x is 12,000 px wide, and ScreenCaptureKit will happily try.
    static let maximumCaptureDimensionInPixels = 4096

    /// Same as `CompanionScreenCaptureUtility`, so the two paths' bytes are
    /// comparable.
    static let jpegCompressionFactor = 0.92

    static let maximumStoredImages = 10

    /// A hard bound on the blocking wait below. See `captureSynchronously`.
    static let captureDeadlineInSeconds = 10.0

    // MARK: - Coordinate conversion (pure)

    /// AppKit global (bottom-left origin, y growing **up**, spanning every
    /// display) → the rect `SCStreamConfiguration.sourceRect` wants: Core
    /// Graphics, top-left origin, y growing **down**, relative to this
    /// display's own origin.
    ///
    /// This is invariant number one in CLAUDE.md, and it fails silently: get it
    /// wrong and the crop is mirrored vertically about the display's centre,
    /// which on a full-screen window looks almost right and on a toolbar button
    /// photographs the status bar. Named and unit-tested for that reason —
    /// `AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame` is the
    /// same boundary in the other direction.
    ///
    /// Both inputs are AppKit, so the display's height arrives as part of its
    /// frame and no separate primary-display height is needed: the top edge of
    /// the display is `displayFrame.maxY`, and the distance DOWN from there to
    /// the rect's top edge is `displayFrame.maxY - rect.maxY`.
    static func sourceRect(
        forAppKitRect rect: CGRect,
        onDisplayWithAppKitFrame displayFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: rect.minX - displayFrame.minX,
            y: displayFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - Region maths (pure)

    /// The union of the candidates' frames, padded. Zero-area frames are
    /// dropped first: a scrolled-out sidebar row reads `(0, 0, 0, 0)` with a
    /// perfectly good name, and one of those in the union drags the region to
    /// the corner of the screen.
    static func region(forCandidateFrames frames: [CGRect]) -> CGRect? {
        let usable = frames.filter { $0.width > 0 && $0.height > 0 }
        guard var union = usable.first else { return nil }
        for frame in usable.dropFirst() { union = union.union(frame) }
        return union.insetBy(dx: -candidatePaddingInPoints, dy: -candidatePaddingInPoints)
    }

    // MARK: - Tier choice (pure)

    /// Which rung to take, and one sentence naming the condition that decided
    /// it.
    ///
    /// "Usable window" is three separate conditions — a root node exists, its
    /// frame has area, and it has at least one actionable descendant — and the
    /// reason says which one failed, because "fell through to display" is not a
    /// finding and "the focused window publishes 0 actionable elements" is.
    static func chooseTier(
        forcedTier: Tier?,
        candidateFrames: [CGRect],
        windowFrame: CGRect?,
        windowActionableCount: Int
    ) -> (tier: Tier, reason: String) {
        if let forcedTier {
            return (forcedTier, "the caller asked for the \(forcedTier.rawValue) tier")
        }

        if let candidateRegion = region(forCandidateFrames: candidateFrames) {
            return (.element, "\(candidateFrames.count) element(s) matched that name; the region is the union "
                + "of their frames padded \(Int(candidatePaddingInPoints)) pt "
                + "(\(Int(candidateRegion.width))x\(Int(candidateRegion.height)) pt)")
        }

        guard let windowFrame else {
            return (.display, "no element matched and there is no focused-window root node to crop to")
        }
        guard windowFrame.width > 0, windowFrame.height > 0 else {
            return (.display, "no element matched and the focused window's frame has zero area")
        }
        guard windowActionableCount > 0 else {
            return (.display, "no element matched and the focused window publishes 0 actionable "
                + "descendants, so cropping to it would photograph a window nothing can be done in")
        }
        return (.window, "no element matched; the focused window is usable "
            + "(\(Int(windowFrame.width))x\(Int(windowFrame.height)) pt, \(windowActionableCount) actionable descendants)")
    }

    // MARK: - The separating point (pure)
    //
    // This is the half that closes the loop. A picture and a list of names is
    // not enough on its own — the caller has to be able to say WHICH one, and
    // the only field the intent has for that is `nearPoint`, which narrows by
    // containment and only when containment leaves exactly one. So a suggested
    // point is only worth returning if re-issuing with it would actually
    // resolve, and that is a property this code can check rather than hope for.

    /// Every cell of the arrangement the other candidates cut this frame into,
    /// centre first, then nearest-to-centre outwards.
    ///
    /// A grid does not work here and the arithmetic says why. Measured
    /// 2026-09-10, the two Finder windows both titled "Recent" —
    /// (289, 300, 920, 436) and (260, 329, 920, 436) — are separated only by
    /// 29 pt strips along two edges, while a 5x5 grid inset 10% insets by
    /// **92 pt horizontally**. It steps straight over the answer and reports
    /// that no point separates them, which is false.
    ///
    /// The exact version is no more code. These rectangles are axis-aligned, so
    /// the region "inside this frame and outside every other" is a union of
    /// rectangles whose edges are drawn from this frame's edges and the other
    /// frames' edges — nowhere else. Cut the frame at every one of those
    /// coordinates and take the midpoint of each interval, and the cross
    /// product visits every cell exactly once. If a separating point exists at
    /// all, one of these is it; if none of them separates, none exists.
    static func searchPoints(in frame: CGRect, avoiding others: [CGRect]) -> [CGPoint] {
        // Written out rather than chained: the one-line `map` over a range with
        // two subscripts and a divide made the type checker give up.
        func midpoints(from low: CGFloat, to high: CGFloat, cutAt cuts: [CGFloat]) -> [CGFloat] {
            var edges: [CGFloat] = [low, high]
            for cut in cuts where cut > low && cut < high {
                edges.append(cut)
            }
            edges.sort()
            var result: [CGFloat] = []
            var index = 0
            while index < edges.count - 1 {
                let midpoint: CGFloat = (edges[index] + edges[index + 1]) / 2
                result.append(midpoint)
                index += 1
            }
            return result
        }

        let xs = midpoints(from: frame.minX, to: frame.maxX,
                           cutAt: others.flatMap { [$0.minX, $0.maxX] })
        let ys = midpoints(from: frame.minY, to: frame.maxY,
                           cutAt: others.flatMap { [$0.minY, $0.maxY] })

        let centre = CGPoint(x: frame.midX, y: frame.midY)
        var cells: [CGPoint] = []
        for y in ys { for x in xs { cells.append(CGPoint(x: x, y: y)) } }

        // Nearest the centre first, so the point handed back is the one a human
        // looking at the crop would also have pointed at.
        func squaredDistanceFromCentre(_ point: CGPoint) -> CGFloat {
            let dx: CGFloat = point.x - centre.x
            let dy: CGFloat = point.y - centre.y
            return dx * dx + dy * dy
        }
        cells.sort { squaredDistanceFromCentre($0) < squaredDistanceFromCentre($1) }
        return [centre] + cells
    }

    /// A point inside `frames[index]` and inside no other candidate, or nil.
    ///
    /// **Never a fallback to "nearest".** Nearest always returns something, and
    /// something is what a wrong click looks like — the same rule
    /// `ElementActionIntentResolver` and `AccessibilityWindows.matchWindow`
    /// already follow. Measured 2026-09-10, two Finder windows both titled
    /// "Recent" at (289, 300, 920, 436) and (260, 329, 920, 436): each one's
    /// centre lies inside the other, and the only regions that separate them
    /// are 29 pt strips along two edges — which `searchPoints` finds and a grid
    /// does not. When nothing separates a candidate (one frame wholly inside
    /// another), the answer is nil, and the caller learns from
    /// `separable: false` that a point will not settle this one.
    static func separatingPoint(forCandidateAt index: Int, among frames: [CGRect]) -> CGPoint? {
        guard frames.indices.contains(index) else { return nil }
        let frame = frames[index]
        guard frame.width > 0, frame.height > 0 else { return nil }

        let others = frames.enumerated().filter { $0.offset != index }.map(\.element)
        for point in searchPoints(in: frame, avoiding: others) where frame.contains(point) {
            if frames.filter({ $0.contains(point) }).count == 1 { return point }
        }
        return nil
    }

    // MARK: - Candidates (pure)

    /// Every node whose published name equals `title`, and whose role matches
    /// when one was asked for.
    ///
    /// Deliberately the same rule as `ElementActionIntentResolver` — `.raw`
    /// equality, optional role — so the candidates shown are the ones that
    /// caused the `ambiguous`. Its own collector is private and carries an
    /// ancestor chain this path has no use for.
    static func namedCandidates(
        in rootNode: AccessibilityElementNode,
        title: String,
        role: String?
    ) -> [AccessibilityElementNode] {
        rootNode.flattenedDescendants().filter { node in
            node.displayName?.raw == title && (role == nil || node.role == role)
        }
    }

    // MARK: - Displays

    /// A display, as AppKit describes it. Gathered on the main thread because
    /// `NSScreen` may only be read there, then carried into the capture.
    struct DisplayInfo {
        let displayID: CGDirectDisplayID
        /// AppKit: bottom-left origin, global.
        let appKitFrame: CGRect
        let backingScaleFactor: CGFloat
    }

    @MainActor
    static func displays() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let identifier = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID else { return nil }
            return DisplayInfo(
                displayID: identifier,
                appKitFrame: screen.frame,
                backingScaleFactor: screen.backingScaleFactor
            )
        }
    }

    /// The display holding most of the region, by intersection area — the same
    /// question `CompanionScreenCaptureUtility` already answers for the
    /// companion flow, so it is asked there rather than answered twice.
    @MainActor
    static func display(holding region: CGRect, among displays: [DisplayInfo]) -> DisplayInfo? {
        if let index = CompanionScreenCaptureUtility.bestDisplayIndex(
            for: region, among: displays.map(\.appKitFrame)
        ) {
            return displays[index]
        }
        return nil
    }

    /// The requested pixel size for a region, at the display's own scale,
    /// shrunk proportionally if either edge would exceed the cap.
    static func pixelSize(
        forRegion region: CGRect,
        backingScaleFactor: CGFloat
    ) -> (width: Int, height: Int) {
        let widthInPixels = region.width * backingScaleFactor
        let heightInPixels = region.height * backingScaleFactor
        let cap = CGFloat(maximumCaptureDimensionInPixels)
        let shrink = min(1.0, cap / max(widthInPixels, heightInPixels, 1))
        return (
            max(1, Int((widthInPixels * shrink).rounded())),
            max(1, Int((heightInPixels * shrink).rounded()))
        )
    }

    // MARK: - Capture

    struct CaptureOutcome {
        let jpeg: Data
        /// What was actually captured — the request clipped to the display.
        let region: CGRect
        let pixelWidth: Int
        let pixelHeight: Int
        let milliseconds: Int
    }

    enum CaptureFailure: Error, CustomStringConvertible {
        case noDisplay
        case regionOffScreen
        case captureFailed(String)
        case encodingFailed
        case timedOut

        var description: String {
            switch self {
            case .noDisplay: return "no display is available to capture"
            case .regionOffScreen: return "the region does not intersect any display"
            case .captureFailed(let detail): return "ScreenCaptureKit failed: \(detail)"
            case .encodingFailed: return "the captured image could not be encoded as JPEG"
            case .timedOut: return "the capture did not return within \(Int(captureDeadlineInSeconds))s"
            }
        }
    }

    /// One region, one display, cropped by the capture itself.
    ///
    /// Our own windows are excluded exactly as the companion path excludes
    /// them: the agent must never photograph its own overlay and then reason
    /// about what it drew.
    static func captureRegion(
        _ region: CGRect,
        on display: DisplayInfo,
        excludingBundleIdentifier: String?
    ) async throws -> CaptureOutcome {
        let startedAt = Date()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureFailure.captureFailed(String(describing: error))
        }
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.displayID })
                ?? content.displays.first else {
            throw CaptureFailure.noDisplay
        }

        let clipped = region.intersection(display.appKitFrame)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
            throw CaptureFailure.regionOffScreen
        }

        let ownWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == excludingBundleIdentifier
        }
        let filter = SCContentFilter(display: scDisplay, excludingWindows: ownWindows)

        let configuration = SCStreamConfiguration()
        // The crop, done by the capture. `sourceRect` is CG display-relative;
        // `clipped` is AppKit global. That conversion is the one line in this
        // file that fails silently, so it is a named, tested function.
        configuration.sourceRect = sourceRect(
            forAppKitRect: clipped, onDisplayWithAppKitFrame: display.appKitFrame
        )
        let size = pixelSize(forRegion: clipped, backingScaleFactor: display.backingScaleFactor)
        configuration.width = size.width
        configuration.height = size.height

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration
            )
        } catch {
            throw CaptureFailure.captureFailed(String(describing: error))
        }

        guard let jpeg = NSBitmapImageRep(cgImage: image)
                .representation(using: .jpeg, properties: [.compressionFactor: jpegCompressionFactor]) else {
            throw CaptureFailure.encodingFailed
        }

        return CaptureOutcome(
            jpeg: jpeg,
            region: clipped,
            // What came back, not what was asked for — the two have disagreed
            // before, and reporting the request as the result is how a
            // measurement of nothing reads as a measurement.
            pixelWidth: image.width,
            pixelHeight: image.height,
            milliseconds: Int(Date().timeIntervalSince(startedAt) * 1000)
        )
    }

    /// Box for one value handed back across the blocking wait below.
    private final class OutcomeBox: @unchecked Sendable {
        var result: Result<CaptureOutcome, Error>?
    }

    /// The synchronous face of an asynchronous API, because a harness request
    /// is served synchronously on the main thread (`DispatchQueue.main.sync` in
    /// `HarnessServer.serve`).
    ///
    /// The work runs on a **detached** task, so nothing it awaits is scheduled
    /// back onto the main actor we are blocking — ScreenCaptureKit answers on
    /// its own queue. The deadline exists because that reasoning is not
    /// something a unit test can prove: if some future SDK version does need
    /// the main run loop, this returns `timedOut` after 10 s instead of wedging
    /// the harness forever. A wrong answer that says so beats a hang.
    ///
    /// Pumping the run loop instead was considered and rejected for the reason
    /// `AccessibilityWindows.focus` records: it would let a second socket
    /// request land inside this one.
    @MainActor
    static func captureSynchronously(
        region: CGRect,
        on display: DisplayInfo,
        excludingBundleIdentifier: String?
    ) -> Result<CaptureOutcome, Error> {
        let box = OutcomeBox()
        let semaphore = DispatchSemaphore(value: 0)

        Task.detached {
            do {
                box.result = .success(try await captureRegion(
                    region, on: display, excludingBundleIdentifier: excludingBundleIdentifier
                ))
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + captureDeadlineInSeconds) == .success,
              let result = box.result else {
            return .failure(CaptureFailure.timedOut)
        }
        return result
    }

    // MARK: - Storage

    /// Where an escalation image lands.
    ///
    /// The image is written to disk and the response carries the **path**, not
    /// the bytes. A 150 KB base64 blob inline would land in every audit line
    /// and, worse, in the flight recorder's twenty-request ring — the diagnostic
    /// that has to stay cheap enough to leave on.
    ///
    /// A caller on the far side of a network will need base64 instead, and that
    /// is deliberately deferred: the socket is a local file with mode 0600, so
    /// a local path is a capability the caller already has.
    @MainActor
    static var imageDirectory: URL {
        HarnessServer.supportDirectory.appendingPathComponent("escalation", isDirectory: true)
    }

    @MainActor
    static func writeImage(_ data: Data) -> URL? {
        let timestamp = HarnessPolicy.auditTimestampFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = imageDirectory.appendingPathComponent("escalation-\(timestamp).jpg")
        try? FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        guard (try? data.write(to: url)) != nil else { return nil }
        pruneImages()
        return url
    }

    /// Newest ten, exactly like `pruneAnomalyDumps`: named by ISO timestamp, so
    /// lexicographic order is chronological.
    @MainActor
    static func pruneImages() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: imageDirectory, includingPropertiesForKeys: nil
        )) ?? []
        let images = contents
            .filter { $0.lastPathComponent.hasPrefix("escalation-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard images.count > maximumStoredImages else { return }
        for stale in images.prefix(images.count - maximumStoredImages) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
