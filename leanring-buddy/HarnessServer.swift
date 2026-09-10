//
//  HarnessServer.swift
//  leanring-buddy
//
//  Slice one of a callable control interface: the harness that already exists
//  as `--ax-select` and friends, reachable by something other than a human
//  holding down a countdown.
//
//  Why a Unix domain socket and not a local HTTP port: a port is a
//  machine-control surface every process on this box can reach and nothing
//  authenticates. A socket file is an ordinary file — mode 0600 in the user's
//  Application Support directory — so the kernel's own permission check is the
//  access control, and it is one we did not have to write.
//
//  Everything here is a thin shell over code that was measured elsewhere:
//  AccessibilityTreeWalker reads, ElementActionIntentResolver aims,
//  ActionSafetyKernel decides, AccessibilityActionPerformer /
//  AccessibilitySelectionPerformer act, ActionVerifier goes and looks. The new
//  parts are the transport, the audit trail, and three refusals.
//

import AppKit
import ApplicationServices
import Darwin
import Foundation

// MARK: - Wire types

/// One line in. Everything past `verb` is optional because `ping` needs none of
/// it and a missing field must be a structured refusal, never a crash.
struct HarnessRawRequest: Decodable {
    let id: String?
    let verb: String
    let title: String?
    let role: String?
    let withinNamed: String?
    let nearPoint: HarnessPoint?
    let dryRun: Bool?
    let confirmed: Bool?
}

struct HarnessPoint: Decodable {
    let x: Double
    let y: Double
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

enum HarnessVerb: String, CaseIterable {
    case ping
    case snapshot
    case press
    case select

    /// Whether this verb can change the world. The kill switch stops these and
    /// leaves the read-only pair working, so an operator who tripped it can
    /// still look at the machine and find out why.
    var isMutating: Bool {
        switch self {
        case .ping, .snapshot: return false
        case .press, .select: return true
        }
    }

    var elementAction: ElementAction? {
        switch self {
        case .press: return .press
        case .select: return .select
        case .ping, .snapshot: return nil
        }
    }
}

/// A request we refused to even attempt. Distinct from a request we ran and
/// refused on policy — both get logged, and confusing them would hide which.
enum HarnessRequestError: Error, Equatable {
    case malformedJSON(String)
    case unknownVerb(String)
    case missingField(String)

    var code: String {
        switch self {
        case .malformedJSON: return "malformedJSON"
        case .unknownVerb: return "unknownVerb"
        case .missingField: return "missingField"
        }
    }

    var message: String {
        switch self {
        case .malformedJSON(let detail):
            return "could not parse the line as JSON: \(detail)"
        case .unknownVerb(let verb):
            // Never guess. A near-miss verb that gets helpfully corrected into
            // a press is the whole failure mode this interface exists to avoid.
            return "unknown verb \"\(verb)\" — known verbs: \(HarnessVerb.allCases.map(\.rawValue).joined(separator: ", "))"
        case .missingField(let field):
            return "missing required field \"\(field)\""
        }
    }
}

/// A decoded, validated request. Having the verb as an enum and the title as a
/// non-optional for the acting verbs means the executor cannot be handed a
/// half-formed command.
struct HarnessRequest: Equatable {
    let id: String
    let verb: HarnessVerb
    let title: String
    let role: String?
    let withinNamed: String?
    let nearPoint: CGPoint?
    let requestedDryRun: Bool?
    let confirmed: Bool
}

// MARK: - Pure decision logic
//
// Everything in this section is a pure function of its arguments, which is the
// half of this file a unit test can honestly prove. The cross-process half is
// proven by running it — see the transcript, not the tests.

enum HarnessPolicy {

    static func decode(line: String) -> Result<HarnessRequest, HarnessRequestError> {
        guard let data = line.data(using: .utf8) else {
            return .failure(.malformedJSON("not valid UTF-8"))
        }

        let raw: HarnessRawRequest
        do {
            raw = try JSONDecoder().decode(HarnessRawRequest.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            return .failure(.missingField(key.stringValue))
        } catch {
            return .failure(.malformedJSON(String(describing: error).prefix(200).description))
        }

        guard let verb = HarnessVerb(rawValue: raw.verb) else {
            return .failure(.unknownVerb(raw.verb))
        }

        if verb.elementAction != nil, (raw.title ?? "").isEmpty {
            return .failure(.missingField("title"))
        }

        return .success(HarnessRequest(
            id: raw.id ?? "",
            verb: verb,
            title: raw.title ?? "",
            role: raw.role,
            withinNamed: raw.withinNamed,
            nearPoint: raw.nearPoint?.cgPoint,
            requestedDryRun: raw.dryRun,
            confirmed: raw.confirmed ?? false
        ))
    }

    /// A request may turn a dry run **on**; it may never turn one off.
    ///
    /// `--harness-dry-run` is an operator's switch on their own machine. If a
    /// caller could clear it, it would not be a switch, it would be a default —
    /// and the caller is the party this whole interface exists to constrain.
    static func effectiveDryRun(requested: Bool?, globalDefault: Bool) -> Bool {
        globalDefault || (requested ?? false)
    }

    static let killSwitchReason =
        "harness kill switch is present (HARNESS_DISABLED) — mutating verbs are refused; ping and snapshot still work"

    /// nil when the verb may proceed.
    static func killSwitchRefusal(verb: HarnessVerb, killSwitchPresent: Bool) -> String? {
        (killSwitchPresent && verb.isMutating) ? killSwitchReason : nil
    }

    /// Whether a kernel decision may be executed over a socket.
    ///
    /// `requireConfirmation` is the kernel asking a human. There is no human on
    /// the other end of this socket, so it is returned as a refusal-to-proceed.
    /// A caller may re-issue with `"confirmed": true` — that does not make the
    /// kernel's answer different, it records that someone took responsibility
    /// for it, which is why the audit line carries the flag.
    static func executability(
        of decision: SafetyDecision,
        confirmed: Bool
    ) -> (executable: Bool, reason: String?) {
        switch decision {
        case .allow:
            return (true, nil)
        case .requireConfirmation(let reason):
            return confirmed
                ? (true, "confirmed by caller: \(reason)")
                : (false, "requires confirmation: \(reason) — re-issue with \"confirmed\": true")
        case .refuse(let reason):
            return (false, "refused: \(reason)")
        }
    }

    static func describe(_ decision: SafetyDecision) -> (decision: String, reason: String?) {
        switch decision {
        case .allow: return ("allow", nil)
        case .requireConfirmation(let reason): return ("requireConfirmation", reason)
        case .refuse(let reason): return ("refuse", reason)
        }
    }

    static let auditTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// One request, one line, JSON — so the log is greppable and a title
    /// carrying a newline cannot forge a second record.
    ///
    /// `title` is app-facing text a caller supplied; JSON encoding escapes it,
    /// which is the same reason `UntrustedText.forDisplay` exists.
    static func auditLine(
        at timestamp: Date,
        id: String,
        verb: String,
        target: String?,
        dryRun: Bool,
        confirmed: Bool,
        kernel: String,
        outcome: String,
        milliseconds: Int
    ) -> String {
        let fields: [String: Any] = [
            "timestamp": auditTimestampFormatter.string(from: timestamp),
            "id": id,
            "verb": verb,
            "target": target ?? NSNull(),
            "dryRun": dryRun,
            "confirmed": confirmed,
            "kernel": kernel,
            "outcome": outcome,
            "ms": milliseconds
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"timestamp\":\"\(auditTimestampFormatter.string(from: timestamp))\",\"outcome\":\"auditEncodingFailed\"}"
        }
        return text
    }
}

// MARK: - Server

@MainActor
final class HarnessServer {

    static let provenanceNote = "element names are written by the target app and are untrusted"

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Clicky", isDirectory: true)
    }
    static var socketURL: URL { supportDirectory.appendingPathComponent("harness.sock") }
    static var killSwitchURL: URL { supportDirectory.appendingPathComponent("HARNESS_DISABLED") }
    static var auditLogURL: URL { supportDirectory.appendingPathComponent("harness-audit.log") }

    private let globalDryRun: Bool
    private var listeningDescriptor: Int32 = -1

    init(globalDryRun: Bool) {
        self.globalDryRun = globalDryRun
    }

    var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return "clicky-harness/1 app \(short) (\(build))"
    }

    // MARK: Lifecycle

    func start() {
        let path = Self.socketURL.path
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)

        // A socket file outlives the process that made it. Left behind by a
        // crash it is a file bind() will refuse, so the stale one goes first.
        unlink(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            print("❌ harness: socket() failed, errno \(errno)")
            return
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            print("❌ harness: socket path too long for sockaddr_un: \(path)")
            close(descriptor)
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyMemory(from: source)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            print("❌ harness: bind() failed, errno \(errno)")
            close(descriptor)
            return
        }

        // Filesystem permissions are the access control on this interface, so
        // this line is the whole security model. 0600: this user only.
        chmod(path, 0o600)

        guard listen(descriptor, 8) == 0 else {
            print("❌ harness: listen() failed, errno \(errno)")
            close(descriptor)
            return
        }

        listeningDescriptor = descriptor
        print("""

        ════════════════════════════════════════════════════════════════
        🔌 J.A.R.V.I.S. harness listening
           socket:      \(path)
           mode:        \(globalDryRun ? "DRY RUN (global --harness-dry-run)" : "live")
           kill switch: \(Self.killSwitchURL.path) \(Self.killSwitchIsPresent() ? "PRESENT — mutating verbs refused" : "(absent)")
           audit log:   \(Self.auditLogURL.path)
           try:         nc -U '\(path)'
        ════════════════════════════════════════════════════════════════

        """)

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop(on: descriptor)
        }
    }

    nonisolated private func acceptLoop(on descriptor: Int32) {
        while true {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                print("❌ harness: accept() failed, errno \(errno)")
                return
            }
            // A thread per connection, but the *work* is serialised onto the
            // main thread below, so two callers can never interleave against
            // the same app. This only stops a silent client from wedging
            // everyone else.
            Thread.detachNewThread { [weak self] in
                self?.serve(client)
            }
        }
    }

    /// The largest single request line accepted. Nothing legitimate comes close:
    /// the biggest verb carries a title, a role and a point.
    static let maximumRequestBytes = 1 << 20

    /// Newline-delimited JSON, both directions. A client that disconnects
    /// mid-line loses its own connection and nothing else.
    nonisolated private func serve(_ client: Int32) {
        defer { close(client) }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)

        while true {
            let bytesRead = read(client, &buffer, buffer.count)
            if bytesRead <= 0 { return }   // 0 = peer closed, <0 = error
            pending.append(contentsOf: buffer[0..<bytesRead])

            // A client that never sends a newline would otherwise grow this
            // buffer until the process dies. Same-user access is not a security
            // boundary here — any process running as you can already act as you
            // — but a client stuck in a loop is an ordinary bug, and a harness
            // that can be killed by one is not a harness.
            guard pending.count <= Self.maximumRequestBytes else {
                _ = writeLine(
                    "{\"ok\":false,\"error\":\"requestTooLarge\",\"message\":\"a single request line may not exceed \(Self.maximumRequestBytes) bytes\"}",
                    to: client
                )
                return
            }

            while let newlineIndex = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<newlineIndex]
                pending = pending[(newlineIndex + 1)...]
                let line = String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }

                // Everything the request does touches NSWorkspace, NSScreen and
                // a cross-process AX walk. It runs on main, and `sync` is what
                // serialises two connections against each other.
                let response = DispatchQueue.main.sync { self.respond(toLine: line) }
                guard writeLine(response, to: client) else { return }
            }
        }
    }

    nonisolated private func writeLine(_ text: String, to client: Int32) -> Bool {
        let payload = Array((text + "\n").utf8)
        var offset = 0
        while offset < payload.count {
            let written = payload.withUnsafeBytes { bytes in
                write(client, bytes.baseAddress!.advanced(by: offset), payload.count - offset)
            }
            if written <= 0 { return false }
            offset += written
        }
        return true
    }

    // MARK: Request handling

    static func killSwitchIsPresent() -> Bool {
        FileManager.default.fileExists(atPath: killSwitchURL.path)
    }

    private func respond(toLine line: String) -> String {
        let startedAt = Date()
        let object = handle(line: line, startedAt: startedAt)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"responseEncodingFailed\"}"
        }
        return text
    }

    private func handle(line: String, startedAt: Date) -> [String: Any] {
        switch HarnessPolicy.decode(line: line) {
        case .failure(let error):
            // A malformed line is still a request someone made of this machine,
            // so it is logged exactly like one that ran.
            appendAudit(HarnessPolicy.auditLine(
                at: startedAt, id: "", verb: "?", target: nil,
                dryRun: globalDryRun, confirmed: false,
                kernel: "n/a", outcome: error.code,
                milliseconds: elapsedMilliseconds(since: startedAt)
            ))
            return ["ok": false, "id": "", "error": error.code, "message": error.message]

        case .success(let request):
            var response = execute(request, startedAt: startedAt)
            response["id"] = request.id
            response["provenance"] = Self.provenanceNote
            return response
        }
    }

    private func execute(_ request: HarnessRequest, startedAt: Date) -> [String: Any] {
        let dryRun = HarnessPolicy.effectiveDryRun(
            requested: request.requestedDryRun,
            globalDefault: globalDryRun
        )

        if let killSwitchReason = HarnessPolicy.killSwitchRefusal(
            verb: request.verb,
            killSwitchPresent: Self.killSwitchIsPresent()
        ) {
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "killSwitch", startedAt: startedAt)
            return ["ok": false, "error": "killSwitch", "message": killSwitchReason]
        }

        switch request.verb {
        case .ping:
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "ok", startedAt: startedAt)
            return [
                "ok": true,
                "harness": versionString,
                "dryRun": dryRun,
                "dryRunSource": globalDryRun ? "global --harness-dry-run" : (request.requestedDryRun == true ? "request" : "none"),
                "killSwitchPresent": Self.killSwitchIsPresent(),
                "socket": Self.socketURL.path
            ]

        case .snapshot:
            return snapshotResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .press, .select:
            return actResponse(request, dryRun: dryRun, startedAt: startedAt)
        }
    }

    // MARK: snapshot

    private func snapshotResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        let snapshot: AccessibilityWindowSnapshot
        do {
            snapshot = try AccessibilityTreeWalker.snapshotFocusedWindow()
        } catch {
            let code = Self.errorCode(for: error)
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: code, startedAt: startedAt)
            return ["ok": false, "error": code, "message": String(describing: error)]
        }

        guard let rootNode = snapshot.rootNode else {
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "noRootNode", startedAt: startedAt)
            return ["ok": false, "error": "noRootNode", "message": "the walk produced no root element"]
        }

        let actionable = rootNode.flattenedDescendants().filter(\.isActionable)
        audit(request, dryRun: dryRun, kernel: "n/a", outcome: "ok", startedAt: startedAt)

        return [
            "ok": true,
            "application": snapshot.applicationName,
            "bundleIdentifier": snapshot.bundleIdentifier,
            "nodeCount": snapshot.nodeCount,
            "walkMilliseconds": Int(snapshot.walkDurationInSeconds * 1000),
            // Truncation is never hidden. An empty list is the only "these are
            // complete" this interface will ever say.
            "walkStopReasons": snapshot.walkStopReasons.map(\.rawValue).sorted(),
            "focusChangedDuringWalk": snapshot.focusChangedDuringWalk,
            "actionableCount": actionable.count,
            "elements": actionable.map(Self.summarise)
        ]
    }

    /// The wire form of an element. `name` is raw because JSON encoding is the
    /// escaping — but `nameIsPlausibleLabel` travels beside it so the caller
    /// knows whether the app published a label or a document.
    static func summarise(_ node: AccessibilityElementNode) -> [String: Any] {
        let frame = node.frameInAppKitCoordinates
        return [
            "role": node.role,
            "subrole": node.subrole ?? NSNull(),
            "name": node.displayName?.raw ?? NSNull(),
            "nameIsPlausibleLabel": node.displayName?.isPlausibleControlLabel ?? false,
            "frame": ["x": frame.origin.x, "y": frame.origin.y, "w": frame.size.width, "h": frame.size.height],
            "actions": node.publishedActionNames
        ]
    }

    // MARK: press / select

    private func actResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        guard let action = request.verb.elementAction else {
            return ["ok": false, "error": "unknownVerb", "message": "not an acting verb"]
        }

        var response: [String: Any] = ["dryRun": dryRun, "confirmed": request.confirmed]

        let snapshot: AccessibilityWindowSnapshot
        do {
            snapshot = try AccessibilityTreeWalker.snapshotFocusedWindow()
        } catch {
            let code = Self.errorCode(for: error)
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: code, startedAt: startedAt)
            response["ok"] = false
            response["error"] = code
            response["message"] = String(describing: error)
            return response
        }

        guard let rootNode = snapshot.rootNode else {
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "noRootNode", startedAt: startedAt)
            response["ok"] = false
            response["error"] = "noRootNode"
            return response
        }
        response["application"] = snapshot.applicationName

        let intent = ElementActionIntent(
            role: request.role,
            title: request.title,
            action: action,
            nearPoint: request.nearPoint,
            withinNamed: request.withinNamed
        )

        let resolvedNode: AccessibilityElementNode
        switch ElementActionIntentResolver.resolve(intent, inTreeRootedAt: rootNode) {
        case .resolved(let node):
            resolvedNode = node
            response["resolution"] = ["status": "resolved", "matchCount": 1]
        case .notFound:
            response["resolution"] = ["status": "notFound", "matchCount": 0]
            response["ok"] = false
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "notFound", startedAt: startedAt)
            return response
        case .ambiguous(let matchCount):
            response["resolution"] = ["status": "ambiguous", "matchCount": matchCount]
            response["ok"] = false
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "ambiguous", startedAt: startedAt)
            return response
        }
        response["resolved"] = Self.summarise(resolvedNode)

        let decision = ActionSafetyKernel.evaluate(
            intent: intent,
            resolvedNode: resolvedNode,
            matchCount: 1,
            visibleBounds: rootNode.frameInAppKitCoordinates
        )
        let described = HarnessPolicy.describe(decision)
        let executability = HarnessPolicy.executability(of: decision, confirmed: request.confirmed)
        response["kernel"] = [
            "decision": described.decision,
            "reason": (described.reason ?? NSNull()) as Any,
            "executable": executability.executable,
            "note": (executability.reason ?? NSNull()) as Any
        ]

        guard executability.executable else {
            response["ok"] = false
            response["error"] = described.decision == "refuse" ? "kernelRefused" : "confirmationRequired"
            audit(request, dryRun: dryRun, kernel: described.decision,
                  outcome: described.decision == "refuse" ? "kernelRefused" : "confirmationRequired",
                  startedAt: startedAt)
            return response
        }

        guard !dryRun else {
            response["ok"] = true
            response["performed"] = ["status": "skipped", "reason": "dry run — nothing was performed"]
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "dryRun", startedAt: startedAt)
            return response
        }

        // The fingerprint has to cover every name, not just pressable ones —
        // a Finder window that went 219 nodes to 99 reported "nothing changed"
        // when only pressable names were diffed.
        let namesBefore = AccessibilityDumpRunner.namedElementFingerprint(in: rootNode)

        let performedOK: Bool
        switch action {
        case .press:
            guard let element = resolvedNode.accessibilityElement else {
                response["ok"] = false
                response["error"] = "noLiveElement"
                audit(request, dryRun: dryRun, kernel: described.decision, outcome: "noLiveElement", startedAt: startedAt)
                return response
            }
            let result = AccessibilityActionPerformer.perform(kAXPressAction, on: element)
            // Print the raw code AND the clock: -25204 in 2 ms is the app
            // refusing, -25204 at 5,000 ms is our own timeout firing. Same
            // number, opposite problems.
            response["performed"] = [
                "status": result.error == .success ? "sent" : "failed",
                "axErrorRawValue": result.error.rawValue,
                "milliseconds": result.milliseconds
            ]
            performedOK = result.error == .success

        case .select:
            guard let chain = ElementReachability.ancestorChain(to: resolvedNode, from: rootNode) else {
                response["ok"] = false
                response["error"] = "noAncestorChain"
                audit(request, dryRun: dryRun, kernel: described.decision, outcome: "noAncestorChain", startedAt: startedAt)
                return response
            }
            let outcome = AccessibilitySelectionPerformer.select(chainFromRoot: chain)
            switch outcome {
            case .selected(let path, let levelsUp, let milliseconds, let readBackTrue):
                response["performed"] = [
                    "status": "sent",
                    "selectionPath": path.rawValue,
                    "levelsAboveNamedElement": levelsUp,
                    "selectedRole": chain[chain.count - 1 - levelsUp].role,
                    "milliseconds": milliseconds,
                    "readBackSelected": readBackTrue
                ]
                performedOK = true
            case .writeFailed(let error, let levelsUp, let milliseconds):
                response["performed"] = [
                    "status": "failed",
                    "axErrorRawValue": error.rawValue,
                    "levelsAboveNamedElement": levelsUp,
                    "milliseconds": milliseconds
                ]
                performedOK = false
            case .noSelectableAncestor(let levelsInspected):
                response["performed"] = ["status": "noSelectableAncestor", "levelsInspected": levelsInspected]
                performedOK = false
            case .noLiveElement:
                response["performed"] = ["status": "noLiveElement"]
                performedOK = false
            }
        }

        guard performedOK else {
            response["ok"] = false
            response["error"] = "performFailed"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "performFailed", startedAt: startedAt)
            return response
        }

        // .success only means the message was delivered. Three separate writes
        // in this repo returned .success and moved nothing, so the second walk
        // is the only tier that gets to say "it worked".
        let verification = ActionVerifier.verify { laterSnapshot in
            guard let laterRoot = laterSnapshot.rootNode else { return false }
            return AccessibilityDumpRunner.namedElementFingerprint(in: laterRoot) != namesBefore
        }

        switch verification {
        case .confirmed(let milliseconds):
            var appeared: [String] = []
            if let laterSnapshot = try? AccessibilityTreeWalker.snapshotFocusedWindow(),
               let laterRoot = laterSnapshot.rootNode {
                appeared = Array(
                    AccessibilityDumpRunner.namedElementFingerprint(in: laterRoot)
                        .subtracting(namesBefore).sorted().prefix(12)
                )
            }
            response["verification"] = [
                "status": "confirmed", "milliseconds": milliseconds, "appeared": appeared
            ]
            response["ok"] = true
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "confirmed", startedAt: startedAt)
        case .notObserved(let milliseconds):
            response["verification"] = [
                "status": "notObserved", "milliseconds": milliseconds, "appeared": [String]()
            ]
            response["ok"] = false
            response["error"] = "notVerified"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "notObserved", startedAt: startedAt)
        case .couldNotReadWindow:
            response["verification"] = ["status": "couldNotReadWindow"]
            response["ok"] = false
            response["error"] = "notVerified"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "couldNotReadWindow", startedAt: startedAt)
        }

        return response
    }

    // MARK: Audit

    private func audit(
        _ request: HarnessRequest,
        dryRun: Bool,
        kernel: String,
        outcome: String,
        startedAt: Date
    ) {
        appendAudit(HarnessPolicy.auditLine(
            at: startedAt,
            id: request.id,
            verb: request.verb.rawValue,
            target: request.title.isEmpty ? nil : request.title,
            dryRun: dryRun,
            confirmed: request.confirmed,
            kernel: kernel,
            outcome: outcome,
            milliseconds: elapsedMilliseconds(since: startedAt)
        ))
    }

    /// Append-only, and it never truncates. The log is the only record that a
    /// refusal happened at all — a refused request leaves nothing else behind.
    private func appendAudit(_ line: String) {
        let url = Self.auditLogURL
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    private func elapsedMilliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    static func errorCode(for error: Error) -> String {
        guard let snapshotError = error as? AccessibilitySnapshotError else { return "snapshotFailed" }
        switch snapshotError {
        case .accessibilityPermissionNotGranted: return "accessibilityPermissionNotGranted"
        case .noFrontmostApplication: return "noFrontmostApplication"
        case .noFocusedWindow: return "noFocusedWindow"
        case .screenIsLocked: return "screenIsLocked"
        }
    }
}
