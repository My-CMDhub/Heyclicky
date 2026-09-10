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

    /// menu / menus only: the path down the menu bar, e.g. ["File", "New Folder"].
    let path: [String]?

    // type only
    let text: String?
    let mode: String?
    /// `"focused"`, or absent for the ordinary name-resolved path.
    let target: String?
    let thenConfirm: Bool?
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
    case type
    case open

    /// Press a menu item by its path down the menu bar.
    case menu
    /// List what the menu bar currently offers. Read-only, and its own verb
    /// because a full listing costs 0.3-1.6 s — folding it into `snapshot`
    /// would put that on every read.
    case menus

    /// Whether this verb can change the world. The kill switch stops these and
    /// leaves the read-only pair working, so an operator who tripped it can
    /// still look at the machine and find out why.
    var isMutating: Bool {
        switch self {
        case .ping, .snapshot, .menus: return false
        case .press, .select, .type, .open, .menu: return true
        }
    }

    var elementAction: ElementAction? {
        switch self {
        case .press: return .press
        case .select: return .select
        case .type: return .type
        case .open: return .open
        // `menu` acts, but it does not resolve a name in the focused window, so
        // it does not go through the name-resolving path at all. Returning nil
        // here is what keeps the "an acting verb needs a title" rule honest —
        // a menu request carries a path instead.
        case .ping, .snapshot, .menu, .menus: return nil
        }
    }
}

/// A request we refused to even attempt. Distinct from a request we ran and
/// refused on policy — both get logged, and confusing them would hide which.
enum HarnessRequestError: Error, Equatable {
    case malformedJSON(String)
    case unknownVerb(String)
    case missingField(String)

    /// A field that is present, well-typed and not a value we recognise —
    /// `"mode":"overwrite"`, `"target":"whatever"`. Same reason `unknownVerb`
    /// exists: the near-miss is exactly the case where guessing is worst.
    case invalidField(field: String, value: String)

    var code: String {
        switch self {
        case .malformedJSON: return "malformedJSON"
        case .unknownVerb: return "unknownVerb"
        case .missingField: return "missingField"
        case .invalidField: return "invalidField"
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
        case .invalidField(let field, let value):
            return "field \"\(field)\" does not accept \"\(value)\""
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

    // type only. Defaulted so every existing construction still reads the same.
    var text: String = ""
    var mode: TypeMode = .insert
    /// Aim at whatever holds keyboard focus instead of resolving a name.
    var aimAtFocus: Bool = false
    var thenConfirm: Bool = false

    /// menu / menus only.
    var path: [String] = []
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

        // "focused" is the only value `target` takes. Anything else is a typo
        // that would otherwise be silently treated as "resolve by name" and aim
        // somewhere the caller did not ask for.
        var aimAtFocus = false
        if let target = raw.target {
            guard target == "focused" else {
                return .failure(.invalidField(field: "target", value: target))
            }
            aimAtFocus = true
        }

        // A name is what an acting verb aims with — unless it is aiming by focus,
        // which is the whole point of the focus target.
        if verb.elementAction != nil, !aimAtFocus, (raw.title ?? "").isEmpty {
            return .failure(.missingField("title"))
        }

        // A menu path is that verb's whole aim, so an empty one is a missing
        // field rather than "the menu bar itself".
        let path = raw.path ?? []
        if verb == .menu, path.isEmpty {
            return .failure(.missingField("path"))
        }

        var mode = TypeMode.insert
        if verb == .type {
            guard !(raw.text ?? "").isEmpty else {
                return .failure(.missingField("text"))
            }
            if let requestedMode = raw.mode {
                guard let parsed = TypeMode(rawValue: requestedMode) else {
                    return .failure(.invalidField(field: "mode", value: requestedMode))
                }
                mode = parsed
            }
        }

        return .success(HarnessRequest(
            id: raw.id ?? "",
            verb: verb,
            // The audit line's `target` is the title, and for a menu the path
            // IS the target. One joined string keeps the log readable without
            // a second field only two verbs would ever set.
            title: (verb == .menu || verb == .menus) && !path.isEmpty
                ? path.joined(separator: " > ")
                : (raw.title ?? ""),
            role: raw.role,
            withinNamed: raw.withinNamed,
            nearPoint: raw.nearPoint?.cgPoint,
            requestedDryRun: raw.dryRun,
            confirmed: raw.confirmed ?? false,
            text: raw.text ?? "",
            mode: mode,
            aimAtFocus: aimAtFocus,
            thenConfirm: raw.thenConfirm ?? false,
            path: path
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
    /// `app` and `session` are the two fields that make an old log readable.
    /// Without `app` a line does not say which program it acted on; without
    /// `session` two runs of the harness interleave in one file and a stale
    /// binary's lines look like this one's.
    static func auditLine(
        at timestamp: Date,
        id: String,
        verb: String,
        target: String?,
        app: String?,
        session: String,
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
            "app": app ?? NSNull(),
            "session": session,
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

// MARK: - Observability
//
// The constraint here is that a healthy run costs one array append. Nothing
// polls, nothing times, nothing is written until something is actually wrong —
// because a diagnostic that runs all the time is a diagnostic nobody leaves on.

/// Last-N, and nothing else. Used for the request/response summaries and for
/// the walk durations the slow-walk rule needs a median of.
struct RingBuffer<Element> {
    let capacity: Int
    private(set) var elements: [Element] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func append(_ element: Element) {
        elements.append(element)
        if elements.count > capacity {
            elements.removeFirst(elements.count - capacity)
        }
    }
}

/// Exactly three things are worth waking up for. Each is computed from data the
/// response already carries — no extra reads, no extra clock.
enum HarnessAnomaly: String, Equatable, CaseIterable {
    /// The kernel said the world would change, the write said `.success`, and
    /// the second walk saw nothing. This is the signature of every silent
    /// failure this project has measured.
    case notObservedAfterAllow = "verification notObserved after the kernel allowed"

    /// Any error that is not one of the ordinary refusals. Those are the
    /// harness working; anything else is the harness surprised.
    case unexpectedError = "response error is not an ordinary refusal"

    /// The kernel refused on a security ground — a secure field, or a label
    /// that is not a label. Something tried to do a thing it should not, which
    /// is the one refusal worth twenty requests of context.
    case securityRefusal = "the kernel refused on a security ground"

    /// The walk took more than 3x the recent median. "It went sloppy" is
    /// usually this, and it is invisible in a single line.
    case walkFarSlowerThanRecentMedian = "walk took more than 3x the median of recent walks"
}

enum HarnessObservability {

    /// The refusals that mean the harness is doing its job. An error outside
    /// this set is the interesting kind.
    ///
    /// `invalidField` is here for the same reason `missingField` is: a caller
    /// typing `"mode":"overwrite"` is a bad request, not a sick machine.
    ///
    /// `kernelRefused` is deliberately NOT here. A hard refusal — a secure
    /// field, a non-text role — is rare and is exactly the moment you want the
    /// last twenty requests on disk, because something asked this machine to do
    /// a thing it will not do.
    static let ordinaryRefusalCodes: Set<String> = [
        "killSwitch", "confirmationRequired", "notFound", "ambiguous",
        "dryRun", "unknownVerb", "malformedJSON", "missingField", "invalidField",
        // A kernel refusal is the policy working, and the audit line already
        // says which rule fired. Only a refusal on SECURITY grounds is worth a
        // dump — see `kernelReason` below.
        "kernelRefused"
    ]

    /// Below this many samples the median is noise, and a cold start would fire
    /// the slow-walk rule on the first real walk of the day.
    static let minimumWalkSamples = 5
    static let slowWalkMultiplier = 3

    static func median(of values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// nil when nothing is wrong. Checked in order of how much each one tells
    /// you: a silent failed write first, an unexpected error next, a slow walk
    /// last.
    static func anomaly(
        kernelDecision: String?,
        kernelReason: String? = nil,
        verificationStatus: String?,
        errorCode: String?,
        walkMilliseconds: Int?,
        recentWalkMilliseconds: [Int]
    ) -> HarnessAnomaly? {
        if verificationStatus == "notObserved", kernelDecision == "allow" {
            return .notObservedAfterAllow
        }
        if let kernelReason, ActionSafetyKernel.isSecurityRefusal(reason: kernelReason) {
            return .securityRefusal
        }
        if let errorCode, !ordinaryRefusalCodes.contains(errorCode) {
            return .unexpectedError
        }
        if let walkMilliseconds,
           recentWalkMilliseconds.count >= minimumWalkSamples,
           let median = median(of: recentWalkMilliseconds),
           median > 0,
           walkMilliseconds > median * slowWalkMultiplier {
            return .walkFarSlowerThanRecentMedian
        }
        return nil
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
    static var rotatedAuditLogURL: URL { supportDirectory.appendingPathComponent("harness-audit.log.1") }

    /// This log lives on the owner's machine and nothing prunes it. 5 MB is
    /// roughly 20,000 audit lines — far more history than any question about
    /// "what happened just now" needs, and one rotation keeps twice that.
    static let auditLogRotationBytes = 5 * 1024 * 1024
    static let maximumAnomalyDumps = 5

    /// One per app launch. Two runs of the harness append to the same file, and
    /// without this their lines are indistinguishable — including a stale
    /// binary's, which this project has already been fooled by once.
    static let sessionIdentifier = String(UUID().uuidString.prefix(8))

    private let globalDryRun: Bool
    private var listeningDescriptor: Int32 = -1

    /// The last 20 request/response summaries, **without** the `elements` array
    /// — that array is the large part of a snapshot and the part that says the
    /// least about a failure. Written out only when an anomaly trips, so the
    /// healthy path costs one array append.
    private var flightRecorder = RingBuffer<[String: Any]>(capacity: 20)

    /// Walk durations, **kept per app**.
    ///
    /// Measured 2026-09-10 with the first version of this, which kept one
    /// buffer: ten walks of TextEdit (5-12 ms) followed by one of System
    /// Settings (152 ms) fired the slow-walk rule and wrote a dump. Nothing was
    /// wrong — System Settings is 20x TextEdit's window and always has been.
    /// A cross-app median measures which app you switched to, and an anomaly
    /// rule that fires on an app switch is one that gets switched off.
    private var recentWalkMillisecondsByApp: [String: RingBuffer<Int>] = [:]

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
                app: Self.frontmostBundleIdentifier(), session: Self.sessionIdentifier,
                dryRun: globalDryRun, confirmed: false,
                kernel: "n/a", outcome: error.code,
                milliseconds: elapsedMilliseconds(since: startedAt)
            ))
            return observe(
                ["ok": false, "id": "", "error": error.code, "message": error.message],
                verb: "?", startedAt: startedAt
            )

        case .success(let request):
            var response = execute(request, startedAt: startedAt)
            response["id"] = request.id
            response["provenance"] = Self.provenanceNote
            return observe(response, verb: request.verb.rawValue, startedAt: startedAt)
        }
    }

    /// The whole observability slice, in one place on the way out.
    ///
    /// Every input is already in the response — no second walk, no extra clock,
    /// no state kept beyond two ring buffers.
    private func observe(
        _ response: [String: Any],
        verb: String,
        startedAt: Date
    ) -> [String: Any] {
        var summary = response
        // The elements array is most of a snapshot's bytes and none of its
        // diagnostic value. Everything else stays.
        summary["elements"] = nil
        summary["_verb"] = verb
        summary["_at"] = HarnessPolicy.auditTimestampFormatter.string(from: startedAt)

        let walkMilliseconds = response["walkMilliseconds"] as? Int
        let walkedApp = (response["bundleIdentifier"] as? String) ?? "unknown"
        var recentWalks = recentWalkMillisecondsByApp[walkedApp] ?? RingBuffer<Int>(capacity: 20)

        let anomaly = HarnessObservability.anomaly(
            kernelDecision: (response["kernel"] as? [String: Any])?["decision"] as? String,
            kernelReason: (response["kernel"] as? [String: Any])?["reason"] as? String,
            verificationStatus: (response["verification"] as? [String: Any])?["status"] as? String,
            errorCode: response["error"] as? String,
            walkMilliseconds: walkMilliseconds,
            recentWalkMilliseconds: recentWalks.elements
        )

        flightRecorder.append(summary)
        // Appended *after* the check, so a walk is never compared against itself.
        if let walkMilliseconds {
            recentWalks.append(walkMilliseconds)
            recentWalkMillisecondsByApp[walkedApp] = recentWalks
        }

        guard let anomaly else { return response }

        var annotated = response
        if let dumpPath = writeAnomalyDump(anomaly, walkedApp: walkedApp, recentWalks: recentWalks.elements) {
            annotated["anomaly"] = ["rule": anomaly.rawValue, "dump": dumpPath]
            // One audit line naming the rule, so the log alone tells you a dump
            // exists and what to look for in it.
            appendAudit(HarnessPolicy.auditLine(
                at: Date(), id: (response["id"] as? String) ?? "", verb: verb,
                target: anomaly.rawValue,
                app: Self.frontmostBundleIdentifier(), session: Self.sessionIdentifier,
                dryRun: globalDryRun, confirmed: false,
                kernel: "n/a", outcome: "anomaly",
                milliseconds: elapsedMilliseconds(since: startedAt)
            ))
        }
        return annotated
    }

    /// Writes the ring buffer out, keeping at most five files. Returns the path
    /// so the response and the audit line can name it.
    private func writeAnomalyDump(
        _ anomaly: HarnessAnomaly,
        walkedApp: String,
        recentWalks: [Int]
    ) -> String? {
        let timestamp = HarnessPolicy.auditTimestampFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = Self.supportDirectory
            .appendingPathComponent("harness-anomaly-\(timestamp).json")

        let payload: [String: Any] = [
            "rule": anomaly.rawValue,
            "session": Self.sessionIdentifier,
            "app": Self.frontmostBundleIdentifier() ?? NSNull(),
            // The samples the slow-walk rule was comparing against, and which
            // app they belong to — a median is meaningless without both.
            "walkedApp": walkedApp,
            "recentWalkMilliseconds": recentWalks,
            "requests": flightRecorder.elements
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }

        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        guard (try? data.write(to: url)) != nil else { return nil }
        pruneAnomalyDumps()
        return url.path
    }

    private func pruneAnomalyDumps() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.supportDirectory, includingPropertiesForKeys: nil
        )) ?? []
        // Named by ISO timestamp, so lexicographic order is chronological.
        let dumps = contents
            .filter { $0.lastPathComponent.hasPrefix("harness-anomaly-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard dumps.count > Self.maximumAnomalyDumps else { return }
        for stale in dumps.prefix(dumps.count - Self.maximumAnomalyDumps) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    /// Which app a line refers to. Clicky is `LSUIElement`, so it never takes
    /// focus itself — the frontmost app is the one being acted on.
    static func frontmostBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
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

        case .press, .select, .type, .open:
            return actResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .menu:
            return menuResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .menus:
            return menusResponse(request, dryRun: dryRun, startedAt: startedAt)
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
        response["bundleIdentifier"] = snapshot.bundleIdentifier
        // Carried on every acting response, not just snapshot, because the
        // slow-walk anomaly rule has nothing else to compare.
        response["walkMilliseconds"] = Int(snapshot.walkDurationInSeconds * 1000)

        let intent = ElementActionIntent(
            role: request.role,
            title: request.title,
            action: action,
            nearPoint: request.nearPoint,
            withinNamed: request.withinNamed
        )

        let resolvedNode: AccessibilityElementNode
        if request.aimAtFocus {
            // The OS says what has focus. No name is involved, which is the
            // point: the fields most worth typing into are anonymous.
            guard let focusedNode = AccessibilityTypePerformer.focusedNode() else {
                response["resolution"] = ["status": "noFocusedElement", "matchCount": 0]
                response["ok"] = false
                response["error"] = "noFocusedElement"
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: "noFocusedElement", startedAt: startedAt)
                return response
            }
            resolvedNode = focusedNode
            response["resolution"] = ["status": "focused", "matchCount": 1]
        } else {
            switch ElementActionIntentResolver.resolve(intent, inTreeRootedAt: rootNode) {
            case .resolved(let node):
                resolvedNode = node
                response["resolution"] = ["status": "resolved", "matchCount": 1]
            case .notFound:
                response["resolution"] = ["status": "notFound", "matchCount": 0]
                response["ok"] = false
                response["error"] = "notFound"
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: "notFound", startedAt: startedAt)
                return response
            case .ambiguous(let matchCount):
                response["resolution"] = ["status": "ambiguous", "matchCount": matchCount]
                response["ok"] = false
                response["error"] = "ambiguous"
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: "ambiguous", startedAt: startedAt)
                return response
            }
        }
        response["resolved"] = Self.summarise(resolvedNode)

        // What the element itself says about being typed into. Four reads on
        // one element — never a per-node cost — and skipped entirely for a
        // secure field, which is refused on its subrole alone.
        var typingContext: ActionSafetyKernel.TypingContext?
        if request.verb == .type, resolvedNode.subrole != ActionSafetyKernel.secureFieldSubrole {
            let element = resolvedNode.accessibilityElement
            let settable = element.map(AccessibilityTypePerformer.settableAttributes) ?? []
            let currentValue = element.flatMap(AccessibilityTypePerformer.stringValue) ?? ""
            typingContext = ActionSafetyKernel.TypingContext(
                mode: request.mode,
                settableAttributes: settable,
                currentValueLength: currentValue.count,
                aimedByFocus: request.aimAtFocus
            )
            response["field"] = [
                "settableAttributes": settable.sorted(),
                "valueLength": currentValue.count,
                "mode": request.mode.rawValue
            ]
        }

        let decision = ActionSafetyKernel.evaluate(
            intent: intent,
            resolvedNode: resolvedNode,
            matchCount: 1,
            visibleBounds: rootNode.frameInAppKitCoordinates,
            typing: typingContext
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
        case .press, .open, .menu:
            guard let element = resolvedNode.accessibilityElement else {
                response["ok"] = false
                response["error"] = "noLiveElement"
                audit(request, dryRun: dryRun, kernel: described.decision, outcome: "noLiveElement", startedAt: startedAt)
                return response
            }
            let result = AccessibilityActionPerformer.perform(
                action.accessibilityActionName ?? kAXPressAction, on: element
            )
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

        case .type:
            guard let element = resolvedNode.accessibilityElement else {
                response["ok"] = false
                response["error"] = "noLiveElement"
                audit(request, dryRun: dryRun, kernel: described.decision, outcome: "noLiveElement", startedAt: startedAt)
                return response
            }

            let outcome = AccessibilityTypePerformer.type(request.text, mode: request.mode, into: element)

            // For typing, the read-back IS the evidence — the text is the
            // effect. The fingerprint below says whether the app *reacted*,
            // which is a different question, and they are reported separately
            // on purpose.
            let containsWhatWeWrote = outcome.valueAfter?.contains(request.text) ?? false
            response["performed"] = [
                "status": outcome.error == .success ? "sent" : "failed",
                "attributeWritten": outcome.attributeWritten,
                "axErrorRawValue": outcome.error.rawValue,
                "milliseconds": outcome.milliseconds,
                "valueLengthBefore": outcome.valueLengthBefore,
                "valueLengthAfter": outcome.valueAfter?.count ?? NSNull(),
                // App-written text going into a log and a response: escaped and
                // capped, like every other name this harness prints.
                "valueAfter": outcome.valueAfter.map { UntrustedText($0).forDisplay } ?? NSNull(),
                "readBackContainsText": containsWhatWeWrote
            ]
            // `.success` on a write that changed nothing has been measured three
            // times in this repo. The field's own text is what decides here.
            performedOK = outcome.error == .success && containsWhatWeWrote

            if request.thenConfirm {
                // A missing AXConfirm is never a failure of the type — measured
                // 2026-09-10, System Settings' search filtered live with no
                // confirm at all.
                let publishesConfirm = resolvedNode.publishedActionNames.contains(kAXConfirmAction)
                if publishesConfirm {
                    let confirmResult = AccessibilityActionPerformer.perform(kAXConfirmAction, on: element)
                    response["confirm"] = [
                        "published": true,
                        "axErrorRawValue": confirmResult.error.rawValue,
                        "milliseconds": confirmResult.milliseconds
                    ]
                } else {
                    response["confirm"] = ["published": false]
                }
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
            // For a press or a select the fingerprint is the only evidence there
            // is. For a type it is the *second* piece: the text is the effect,
            // and the field already read it back. An app that accepted the text
            // and did not otherwise move is a real, ordinary outcome — so the
            // two are reported separately rather than collapsed into one verdict.
            if request.verb == .type {
                response["ok"] = true
                response["verificationNote"] =
                    "the field read back the text; the window's named elements did not change"
            } else {
                response["ok"] = false
                response["error"] = "notVerified"
            }
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "notObserved", startedAt: startedAt)
        case .couldNotReadWindow:
            response["verification"] = ["status": "couldNotReadWindow"]
            response["ok"] = false
            response["error"] = "notVerified"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "couldNotReadWindow", startedAt: startedAt)
        }

        return response
    }

    // MARK: menu / menus

    // Both menu verbs report their timing as `menuMilliseconds`, and never as
    // `walkMilliseconds`.
    //
    // The slow-walk anomaly rule keeps a per-app median of *window* walk
    // durations. A menu read is a different population entirely — Finder's
    // window walks in ~112 ms and its menu bar takes 545 ms — so a menu request
    // would both fire the rule and drag the median it is compared against,
    // which is exactly how the cross-app ring poisoned itself before it was
    // keyed per app. `observe` reads only `walkMilliseconds`, so a different
    // key is the whole fix, and menu timings stay visible in the response.

    /// The frontmost app and its menu bar, or nil having already filled in the
    /// refusal and written the audit line.
    private func menuBar(
        for request: HarnessRequest,
        dryRun: Bool,
        startedAt: Date,
        into response: inout [String: Any]
    ) -> (application: NSRunningApplication, bar: AccessibilityMenu.Node)? {

        func fail(_ code: String, _ message: String) {
            response["ok"] = false
            response["error"] = code
            response["message"] = message
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: code, startedAt: startedAt)
        }

        guard let application = NSWorkspace.shared.frontmostApplication else {
            fail("noFrontmostApplication", "nothing is frontmost")
            return nil
        }
        // Same guard the walker has. A locked screen makes loginwindow
        // frontmost, and its menu bar is a believable, wrong answer.
        guard !LockScreenGuard.isLockScreen(application.bundleIdentifier) else {
            fail("screenIsLocked", "the screen is locked — there is no menu bar of the user's to read")
            return nil
        }
        response["application"] = application.localizedName ?? "unknown"
        response["bundleIdentifier"] = application.bundleIdentifier ?? "unknown"

        guard let bar = AccessibilityMenu.menuBarNode(for: application) else {
            fail("noMenuBar", "the application publishes no AXMenuBar")
            return nil
        }
        return (application, bar)
    }

    /// The wire form of a failed path step, or nil when it resolved.
    private static func menuResolutionFailure(
        _ resolution: AccessibilityMenu.Resolution
    ) -> (code: String, payload: [String: Any])? {
        switch resolution {
        case .resolved:
            return nil
        case .notFound(let atStep, let step, let available):
            return ("notFound", [
                "status": "notFound",
                "atStep": atStep,
                "step": step,
                // What WAS at that level. Without this a miss is not actionable:
                // the caller cannot tell a typo from a menu that is not there.
                "available": available.map { UntrustedText($0).forDisplay }
            ])
        case .ambiguous(let atStep, let step, let matchCount):
            return ("ambiguous", [
                "status": "ambiguous", "atStep": atStep, "step": step, "matchCount": matchCount
            ])
        case .emptyPath:
            return ("missingField", ["status": "emptyPath"])
        }
    }

    private func menuResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = [
            "dryRun": dryRun, "confirmed": request.confirmed, "path": request.path
        ]
        guard let (application, bar) = menuBar(
            for: request, dryRun: dryRun, startedAt: startedAt, into: &response
        ) else { return response }

        // Only the path is read — six or seven levels, not the 300-item bar.
        let resolveStartedAt = Date()
        let (node, resolution) = AccessibilityMenu.resolveNode(
            path: request.path, from: bar, children: AccessibilityMenu.liveChildren
        )
        response["menuMilliseconds"] = Int(Date().timeIntervalSince(resolveStartedAt) * 1000)

        if let failure = Self.menuResolutionFailure(resolution) {
            response["resolution"] = failure.payload
            response["ok"] = false
            response["error"] = failure.code
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: failure.code, startedAt: startedAt)
            return response
        }
        guard let node else {
            response["ok"] = false
            response["error"] = "notFound"
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "notFound", startedAt: startedAt)
            return response
        }

        let resolvedNode = AccessibilityMenu.elementNode(for: node)
        response["resolution"] = [
            "status": "resolved", "matchCount": 1,
            "enabled": node.isEnabled,
            "shortcut": (node.shortcut ?? NSNull()) as Any
        ]
        response["resolved"] = Self.summarise(resolvedNode)

        let intent = ElementActionIntent(role: nil, title: node.label ?? "", action: .menu)
        let decision = ActionSafetyKernel.evaluate(
            intent: intent,
            resolvedNode: resolvedNode,
            matchCount: 1,
            // A closed menu item is not drawn, so there are no visible bounds
            // for it to be inside. `.infinite` says that honestly: the frame
            // checks do not run for `.menu`, and if they ever did again, a
            // degenerate frame would still be refused while a real one passes.
            visibleBounds: .infinite,
            menuItemEnabled: node.isEnabled
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

        guard let element = resolvedNode.accessibilityElement else {
            response["ok"] = false
            response["error"] = "noLiveElement"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "noLiveElement", startedAt: startedAt)
            return response
        }

        // Two independent baselines, because either one alone is blind here.
        // The named-element fingerprint cannot see `File > New Finder Window` —
        // two Finder windows on the same folder publish the same names — and
        // the window count cannot see anything that is not a window.
        let windowsBefore = AccessibilityMenu.windowCount(for: application)
        let namesBefore = (try? AccessibilityTreeWalker.snapshotFocusedWindow())?
            .rootNode.map(AccessibilityDumpRunner.namedElementFingerprint)
        response["windowsBefore"] = (windowsBefore ?? NSNull()) as Any

        // Pressing works with the menu **closed**, and leaves nothing open on
        // screen. Measured 2026-09-10 over this socket: File > New Finder Window
        // returned AXError 0 and took Finder from 2 AX windows to 3, and
        // `AXSelected` on all eight of Finder's menu bar items read false both
        // before and after — no menu was opened, so none had to be dismissed.
        let result = AccessibilityActionPerformer.perform(kAXPressAction, on: element)
        response["performed"] = [
            "status": result.error == .success ? "sent" : "failed",
            "axErrorRawValue": result.error.rawValue,
            "milliseconds": result.milliseconds
        ]
        guard result.error == .success else {
            response["ok"] = false
            response["error"] = "performFailed"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "performFailed", startedAt: startedAt)
            return response
        }

        let verification = ActionVerifier.verify { laterSnapshot in
            if let windowsBefore,
               AccessibilityMenu.windowCount(for: application) != windowsBefore { return true }
            guard let laterRoot = laterSnapshot.rootNode, let namesBefore else { return false }
            return AccessibilityDumpRunner.namedElementFingerprint(in: laterRoot) != namesBefore
        }

        switch verification {
        case .confirmed(let milliseconds):
            response["verification"] = [
                "status": "confirmed",
                "milliseconds": milliseconds,
                "windowsAfter": (AccessibilityMenu.windowCount(for: application) ?? NSNull()) as Any
            ]
            response["ok"] = true
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "confirmed", startedAt: startedAt)
        case .notObserved(let milliseconds):
            response["verification"] = [
                "status": "notObserved",
                "milliseconds": milliseconds,
                "windowsAfter": (AccessibilityMenu.windowCount(for: application) ?? NSNull()) as Any
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

    /// The list of what this app can currently be asked to do.
    ///
    /// A screenshot structurally cannot provide it — a closed menu shows
    /// nothing — and it is the thing a planner needs before it can plan.
    private func menusResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = ["pathPrefix": request.path]
        guard let (_, bar) = menuBar(
            for: request, dryRun: dryRun, startedAt: startedAt, into: &response
        ) else { return response }

        // The prefix genuinely scopes the read: resolve it one level at a time,
        // then enumerate from there. Never list 591 items and filter.
        var startNode = bar
        if !request.path.isEmpty {
            let (node, resolution) = AccessibilityMenu.resolveNode(
                path: request.path, from: bar, children: AccessibilityMenu.liveChildren
            )
            if let failure = Self.menuResolutionFailure(resolution) {
                response["resolution"] = failure.payload
                response["ok"] = false
                response["error"] = failure.code
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: failure.code, startedAt: startedAt)
                return response
            }
            guard let node else {
                response["ok"] = false
                response["error"] = "notFound"
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: "notFound", startedAt: startedAt)
                return response
            }
            startNode = node
        }

        let listing = AccessibilityMenu.list(
            from: startNode,
            pathSoFar: request.path,
            children: AccessibilityMenu.liveChildren,
            deadline: Date().addingTimeInterval(AccessibilityMenu.listingTimeLimitInSeconds)
        )

        // Truncation is a banner above the counts, never a flag beside them.
        if !listing.stopReasons.isEmpty {
            response["warning"] = "THESE COUNTS ARE A FLOOR, NOT A MEASUREMENT — the listing stopped early: "
                + listing.stopReasons.joined(separator: ", ")
        }
        response["listingStopReasons"] = listing.stopReasons
        response["menuMilliseconds"] = listing.milliseconds
        response["itemCount"] = listing.items.count
        response["enabledCount"] = listing.items.filter(\.isEnabled).count
        response["withShortcutCount"] = listing.items.filter { $0.shortcut != nil }.count
        // Paths are raw so a caller can feed one straight back into `menu`.
        // JSON encoding is the escaping, exactly as in `summarise`.
        response["items"] = listing.items.map {
            [
                "path": $0.path,
                "role": $0.role,
                "enabled": $0.isEnabled,
                "shortcut": $0.shortcut ?? NSNull(),
                "hasSubmenu": $0.hasSubmenu
            ] as [String: Any]
        }
        response["ok"] = true
        audit(request, dryRun: dryRun, kernel: "n/a", outcome: "ok", startedAt: startedAt)
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
            target: request.title.isEmpty ? (request.aimAtFocus ? "<focused>" : nil) : request.title,
            app: Self.frontmostBundleIdentifier(),
            session: Self.sessionIdentifier,
            dryRun: dryRun,
            confirmed: request.confirmed,
            kernel: kernel,
            outcome: outcome,
            milliseconds: elapsedMilliseconds(since: startedAt)
        ))
    }

    /// Append-only, and it rotates rather than truncates. The log is the only
    /// record that a refusal happened at all — a refused request leaves nothing
    /// else behind — so history is kept, just bounded.
    private func appendAudit(_ line: String) {
        let url = Self.auditLogURL
        let data = Data((line + "\n").utf8)
        rotateAuditLogIfLarge()
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    /// One old file, then the previous one goes. Two files is enough to answer
    /// "what happened just before this" and small enough that nobody has to
    /// think about it.
    private func rotateAuditLogIfLarge() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: Self.auditLogURL.path)
        guard let size = attributes?[.size] as? Int, size > Self.auditLogRotationBytes else { return }
        try? FileManager.default.removeItem(at: Self.rotatedAuditLogURL)
        try? FileManager.default.moveItem(at: Self.auditLogURL, to: Self.rotatedAuditLogURL)
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
