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

    /// windows / focus only: which application, by bundle identifier or name.
    /// Absent means the frontmost one, which is what every other verb assumes.
    let app: String?

    // type only
    let text: String?
    let mode: String?
    /// `"focused"`, or absent for the ordinary name-resolved path.
    let target: String?
    let thenConfirm: Bool?

    /// look only: force a rung of the escalation ladder instead of choosing one.
    let tier: String?
    /// press / select / open / type: on a `notFound` or `ambiguous`, come back
    /// with the picture rather than only the offer of one.
    let escalate: Bool?
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

    /// What windows an application has, and what applications are running.
    /// Read-only, and the applications half costs no AX reads at all.
    case windows
    /// Point the harness at a different window. Every other verb anchors on
    /// whatever the human left in front; this is how a caller moves that anchor.
    case focus

    /// The smallest picture that would let a caller decide, plus the structural
    /// candidates inside it. Read-only — it takes a photograph and changes
    /// nothing — so it survives the kill switch, exactly like `snapshot`.
    case look

    /// Whether this verb can change the world. The kill switch stops these and
    /// leaves the read-only pair working, so an operator who tripped it can
    /// still look at the machine and find out why.
    var isMutating: Bool {
        switch self {
        case .ping, .snapshot, .menus, .windows, .look: return false
        case .press, .select, .type, .open, .menu, .focus: return true
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
        //
        // `focus` acts too, and is nil here for the same reason: its target is a
        // window, not a named element inside one, so it never enters the
        // name-resolving path and its kernel check is `evaluateFocus`.
        //
        // `look` is nil for a third reason: it does not act at all. It resolves
        // a name only to find out how many things carry it.
        case .ping, .snapshot, .menu, .menus, .windows, .focus, .look: return nil
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

    /// windows / focus only. nil means the frontmost application.
    var app: String? = nil

    /// look only. nil means "choose the rung".
    var tier: EscalationLadder.Tier? = nil
    /// Acting verbs only: whether a failed resolution should pay for a capture.
    var escalate: Bool = false
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

        // `focus` aims with either half: an app (bring Finder forward), a title
        // (raise that window in whatever is already frontmost), or both.
        // Neither is not a default — it is a request to focus nothing.
        if verb == .focus, (raw.app ?? "").isEmpty, (raw.title ?? "").isEmpty {
            return .failure(.missingField("app"))
        }

        // A forced rung, validated the same way `mode` and `target` are: a
        // typo'd tier would otherwise be silently ignored and the caller would
        // get a rung it did not ask for, which is the whole failure mode this
        // interface refuses to have. `"none"` is rejected too — it is the rung
        // that takes no picture, so forcing it is not a request.
        var tier: EscalationLadder.Tier?
        if let requestedTier = raw.tier {
            guard let parsed = EscalationLadder.Tier(rawValue: requestedTier), parsed != .none else {
                return .failure(.invalidField(field: "tier", value: requestedTier))
            }
            tier = parsed
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
            path: path,
            app: (raw.app?.isEmpty == false) ? raw.app : nil,
            tier: tier,
            escalate: raw.escalate ?? false
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
        "kernelRefused",
        // An app with no ordinary on-screen window — measured 2026-09-11,
        // Finder showing only its desktop — is not listed by ScreenCaptureKit,
        // so the one-app capture refuses. Explained and safe; three dumps of it
        // in one session were a recorder filing the expected as a surprise.
        "applicationNotCapturable"
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

    /// How long the same rule, on the same app, stops writing another file.
    ///
    /// Measured on this machine 2026-09-10: five dumps on disk, all
    /// `response error is not an ordinary refusal`, all System Settings, all
    /// inside **1.7 seconds** — 125 KB describing one cause, and between them
    /// they filled the entire five-file budget, so any *different* anomaly in
    /// that session had nowhere to land. A recorder that evicts its own
    /// variety is worse than a smaller one. The recurrence is not lost: the
    /// audit line still fires every time, as `anomalySuppressed`.
    static let anomalyDumpSuppressionInSeconds: TimeInterval = 60

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

    /// Last time a dump was written, keyed by rule and app. Two entries, not a
    /// ring — the whole point is that repetition is cheap to recognise.
    private var lastAnomalyDumpAt: [String: Date] = [:]

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

        // Same rule, same app, within the window: record that it happened and
        // do not spend 25 KB saying it again. The ring buffer behind a second
        // dump is nearly the same twenty requests anyway.
        let app = Self.frontmostBundleIdentifier() ?? "unknown"
        let dumpKey = "\(anomaly.rawValue)|\(app)"
        let now = Date()
        let suppressed = lastAnomalyDumpAt[dumpKey].map {
            now.timeIntervalSince($0) < Self.anomalyDumpSuppressionInSeconds
        } ?? false

        var annotated = response
        var outcome = "anomalyNotWritten"
        if suppressed {
            outcome = "anomalySuppressed"
            annotated["anomaly"] = [
                "rule": anomaly.rawValue,
                "dump": NSNull(),
                "suppressed": "same rule and app dumped within the last \(Int(Self.anomalyDumpSuppressionInSeconds))s"
            ]
        } else if let dumpPath = writeAnomalyDump(
            anomaly, walkedApp: walkedApp, recentWalks: recentWalks.elements
        ) {
            lastAnomalyDumpAt[dumpKey] = now
            outcome = "anomaly"
            annotated["anomaly"] = ["rule": anomaly.rawValue, "dump": dumpPath]
        }

        // One audit line naming the rule, on every anomaly including a
        // suppressed one — otherwise the log would say a recurring problem
        // stopped happening the moment we stopped writing files about it.
        appendAudit(HarnessPolicy.auditLine(
            at: now, id: (response["id"] as? String) ?? "", verb: verb,
            target: anomaly.rawValue,
            app: Self.frontmostBundleIdentifier(), session: Self.sessionIdentifier,
            dryRun: globalDryRun, confirmed: false,
            kernel: "n/a", outcome: outcome,
            milliseconds: elapsedMilliseconds(since: startedAt)
        ))
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

        case .windows:
            return windowsResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .focus:
            return focusResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .look:
            return lookResponse(request, dryRun: dryRun, startedAt: startedAt)
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
                // The two answers a tree walk cannot improve on its own are the
                // two that get a rung offered. Everything else here is a
                // decision the harness already made.
                attachEscalation(to: &response, request: request, rootNode: rootNode)
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: "notFound", startedAt: startedAt)
                return response
            case .ambiguous(let matchCount):
                response["resolution"] = ["status": "ambiguous", "matchCount": matchCount]
                response["ok"] = false
                response["error"] = "ambiguous"
                attachEscalation(to: &response, request: request, rootNode: rootNode)
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

    // MARK: windows / focus

    // Both window verbs report their timing as `focusMilliseconds`, never as
    // `walkMilliseconds` — for the reason spelled out in full above
    // `// MARK: menu / menus`. A window-list read is a third population and
    // `observe` keys the slow-walk median on `walkMilliseconds` alone.

    /// The application both verbs act on: the one named, or the frontmost.
    /// Returns nil having already filled in the refusal and written the audit
    /// line, exactly like `menuBar(for:)`.
    private func targetApplication(
        for request: HarnessRequest,
        dryRun: Bool,
        startedAt: Date,
        into response: inout [String: Any]
    ) -> NSRunningApplication? {

        func fail(_ code: String, _ message: String, extra: [String: Any] = [:]) {
            response["ok"] = false
            response["error"] = code
            response["message"] = message
            for (key, value) in extra { response[key] = value }
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: code, startedAt: startedAt)
        }

        // Same guard the walker and the menu path have. A locked screen makes
        // loginwindow frontmost, and its one window is a believable, wrong
        // answer that this project has already recorded as data three times.
        guard !LockScreenGuard.isLockScreen(Self.frontmostBundleIdentifier()) else {
            fail("screenIsLocked", "the screen is locked — there are no windows of the user's to read or raise")
            return nil
        }

        let candidates = AccessibilityWindows.runningApplications()

        guard let query = request.app else {
            guard let frontmost = NSWorkspace.shared.frontmostApplication else {
                fail("noFrontmostApplication", "nothing is frontmost")
                return nil
            }
            return frontmost
        }

        switch AccessibilityWindows.matchApplication(query, among: candidates.map(\.candidate)) {
        case .resolved(let index, let tier):
            response["applicationMatchedOn"] = tier.rawValue
            return candidates[index].application
        case .notFound(let available):
            fail(
                "notFound",
                "no running application matches \(UntrustedText(query).forDisplay)",
                // What WAS running. Without it a miss is not actionable — the
                // caller cannot tell a typo from an app that is not open.
                extra: ["available": available.map { UntrustedText($0).forDisplay }]
            )
            return nil
        case .ambiguous(let matchCount, let tier):
            fail(
                "ambiguous",
                "\(matchCount) running applications match \(UntrustedText(query).forDisplay) on \(tier.rawValue)",
                extra: ["matchCount": matchCount]
            )
            return nil
        }
    }

    /// The wire form of one running application. `NSWorkspace` only — no AX
    /// reads, so this list is nearly free, and it is how a caller finds out what
    /// it could focus in the first place.
    private static func summariseApplication(
        _ candidate: AccessibilityWindows.ApplicationCandidate
    ) -> [String: Any] {
        [
            "name": (candidate.localizedName ?? NSNull()) as Any,
            "bundleIdentifier": (candidate.bundleIdentifier ?? NSNull()) as Any,
            "active": candidate.isActive,
            "hidden": candidate.isHidden
        ]
    }

    /// The wire form of one window. Frames are already AppKit — converted in
    /// `liveWindows`, at the one boundary where AX's top-left origin meets
    /// AppKit's bottom-left.
    private static func summariseWindow(
        _ candidate: AccessibilityWindows.WindowCandidate
    ) -> [String: Any] {
        let frame = candidate.frameInAppKitCoordinates
        return [
            // Raw, because JSON encoding is the escaping — same rule as
            // `summarise`. The plausibility flag travels beside it.
            "title": (candidate.title?.raw ?? NSNull()) as Any,
            "titleIsPlausibleLabel": candidate.title?.isPlausibleControlLabel ?? false,
            "role": candidate.role,
            "subrole": (candidate.subrole ?? NSNull()) as Any,
            "frame": ["x": frame.origin.x, "y": frame.origin.y, "w": frame.size.width, "h": frame.size.height],
            "main": candidate.isMain,
            "minimized": candidate.isMinimized,
            "actions": candidate.publishedActionNames
        ]
    }

    private func windowsResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = [:]
        guard let application = targetApplication(
            for: request, dryRun: dryRun, startedAt: startedAt, into: &response
        ) else { return response }

        response["application"] = application.localizedName ?? "unknown"
        response["bundleIdentifier"] = application.bundleIdentifier ?? "unknown"

        let readStartedAt = Date()
        let read = AccessibilityWindows.liveWindows(for: application)
        response["focusMilliseconds"] = Int(Date().timeIntervalSince(readStartedAt) * 1000)

        response["windowCount"] = read.windows.count
        response["windows"] = read.windows.map { Self.summariseWindow($0.candidate) }
        response["applications"] = AccessibilityWindows.runningApplications()
            .map { Self.summariseApplication($0.candidate) }

        // A count of zero is only a fact if the read worked. This is the one
        // field that separates "this app has no windows" from "this app did not
        // answer", and without it both print as `windowCount: 0`.
        response["windowListRead"] = read.readSucceeded ? "ok" : "failed"
        response["windowListErrorRawValue"] = read.error.rawValue
        // Zero windows from a *successful* read is still not "this app has no
        // windows" — kAXWindows is Space-scoped, measured 2026-09-10. Say so
        // where the count is, not in a footnote.
        if read.readSucceeded, read.windows.isEmpty, !application.isActive {
            response["warning"] = "ZERO IS NOT A MEASUREMENT — \(application.localizedName ?? "this app") "
                + "is not the active application, and kAXWindows only lists windows on the active Space. "
                + "Focus the app and read again before concluding it has no windows."
        }
        if !read.readSucceeded {
            response["warning"] = "WINDOW COUNT IS NOT A MEASUREMENT — "
                + "kAXWindows failed with AXError \(read.error.rawValue); the list below is empty "
                + "because the read did not answer, not because the app has no windows"
        }
        response["ok"] = read.readSucceeded
        if !read.readSucceeded { response["error"] = "windowListUnreadable" }
        audit(
            request, dryRun: dryRun, kernel: "n/a",
            outcome: read.readSucceeded ? "ok" : "windowListUnreadable", startedAt: startedAt
        )
        return response
    }

    private func focusResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = [
            "dryRun": dryRun, "confirmed": request.confirmed,
            "app": (request.app ?? NSNull()) as Any,
            "title": request.title.isEmpty ? NSNull() : request.title
        ]

        // Captured BEFORE anything moves. Focus is the one verb the human can
        // undo trivially, and this is what tells them how.
        if let previous = AccessibilityWindows.previousApplication() {
            response["previousApplication"] = [
                "name": (previous.name ?? NSNull()) as Any,
                "bundleIdentifier": (previous.bundleIdentifier ?? NSNull()) as Any
            ]
        }

        guard let application = targetApplication(
            for: request, dryRun: dryRun, startedAt: startedAt, into: &response
        ) else { return response }

        response["application"] = application.localizedName ?? "unknown"
        response["bundleIdentifier"] = application.bundleIdentifier ?? "unknown"

        // A title-less focus is an app activation, and reading the window list
        // is then only worth it to say which window ends up in front — which
        // the observation tier reports anyway. So it is read either way, once.
        let readStartedAt = Date()
        var read = AccessibilityWindows.liveWindows(for: application)

        // A window on another Space is invisible to kAXWindows, so resolving a
        // title against an empty list would report `notFound` for a window that
        // is merely elsewhere. Bringing the app forward IS the app-level half of
        // this verb — the half the kernel allows unconditionally — so doing it
        // first is the verb's own order, not an escalation past a decision.
        if !request.title.isEmpty, read.windows.isEmpty, !application.isActive {
            let attempt = AccessibilityWindows.activateAndWaitForWindows(application)
            read = attempt.read
            response["activatedToReadWindows"] = [
                "activated": attempt.activated,
                "milliseconds": attempt.milliseconds,
                "windowsThenVisible": attempt.read.windows.count
            ]
        }
        response["focusMilliseconds"] = Int(Date().timeIntervalSince(readStartedAt) * 1000)
        response["windowCount"] = read.windows.count
        response["windowListRead"] = read.readSucceeded ? "ok" : "failed"

        // A title we cannot look for is not a title that is missing. Reporting
        // `notFound` here would tell the caller the window does not exist, on
        // the strength of a read that never happened.
        if !request.title.isEmpty, !read.readSucceeded {
            response["ok"] = false
            response["error"] = "windowListUnreadable"
            response["message"] = "kAXWindows failed with AXError \(read.error.rawValue) — "
                + "cannot tell whether that window exists"
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "windowListUnreadable", startedAt: startedAt)
            return response
        }

        var resolvedWindow: (element: AXUIElement, candidate: AccessibilityWindows.WindowCandidate)?
        var matchCount = 1
        var kernelTitle: UntrustedText?

        if !request.title.isEmpty {
            switch AccessibilityWindows.matchWindow(
                title: request.title, nearPoint: request.nearPoint,
                among: read.windows.map(\.candidate)
            ) {
            case .resolved(let index):
                resolvedWindow = read.windows[index]
                kernelTitle = read.windows[index].candidate.title
                response["resolution"] = [
                    "status": "resolved", "matchCount": 1,
                    "title": (read.windows[index].candidate.title?.raw ?? NSNull()) as Any
                ]
            case .notFound(let available):
                response["resolution"] = [
                    "status": "notFound",
                    "available": available.map { UntrustedText($0).forDisplay }
                ]
                response["ok"] = false
                response["error"] = "notFound"
                attachFocusEscalation(
                    to: &response, request: request,
                    windows: read.windows.map(\.candidate), application: application
                )
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: "notFound", startedAt: startedAt)
                return response
            case .ambiguous(let count):
                // Not returned here: the kernel is the thing that refuses an
                // ambiguous target, in this verb as in every other.
                matchCount = count
                kernelTitle = UntrustedText(request.title)
                response["resolution"] = ["status": "ambiguous", "matchCount": count]
            }
        }

        let decision = ActionSafetyKernel.evaluateFocus(windowTitle: kernelTitle, matchCount: matchCount)
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
            // An ambiguous window title is precisely what a picture settles, so
            // this verb gets the ladder too — built from the window list, which
            // is the candidate set it resolves against.
            if matchCount != 1 {
                attachFocusEscalation(
                    to: &response, request: request,
                    windows: read.windows.map(\.candidate), application: application
                )
            }
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

        let outcome = AccessibilityWindows.focus(application: application, window: resolvedWindow)

        // Every step separately. A raise that was never published, a raise that
        // returned 0, and a window that actually came forward are three
        // different facts, and collapsing them into one boolean is how a write
        // that did nothing gets reported as a success.
        response["performed"] = [
            "unminimized": outcome.unminimized,
            "unminimizeErrorRawValue": (outcome.unminimizeErrorRawValue.map { Int($0) } ?? NSNull()) as Any,
            "raisePublished": outcome.raisePublished,
            "axErrorRawValue": (outcome.raiseErrorRawValue.map { Int($0) } ?? NSNull()) as Any,
            "milliseconds": (outcome.raiseMilliseconds ?? NSNull()) as Any,
            "activated": outcome.activated
        ]
        response["verification"] = [
            "status": outcome.observed ? "confirmed" : "notObserved",
            "readBackMain": (outcome.readBackMain ?? NSNull()) as Any,
            "observed": outcome.observed,
            "milliseconds": outcome.observedMilliseconds,
            "observedApplication": (outcome.observedApplication ?? NSNull()) as Any,
            "observedWindowTitle": (outcome.observedWindowTitle?.raw ?? NSNull()) as Any
        ]

        response["ok"] = outcome.observed
        if !outcome.observed { response["error"] = "notVerified" }
        audit(request, dryRun: dryRun, kernel: described.decision,
              outcome: outcome.observed ? "confirmed" : "notObserved", startedAt: startedAt)
        return response
    }

    // MARK: look / escalation

    // Capture timing is reported as `captureMilliseconds` and NEVER as
    // `walkMilliseconds` — for exactly the reason spelled out in full above
    // `// MARK: menu / menus`. A capture is a fourth population (fixed ~344 ms,
    // measured 2026-09-08) and `observe` keys its per-app slow-walk median on
    // `walkMilliseconds` alone. A `look` still reports the *tree walk* it did as
    // `walkMilliseconds`, because that one really is a window walk of the same
    // window every other verb measures.
    //
    // The secure-field inspection before a capture is `inspectMilliseconds`,
    // for the same reason: it walks every window of the app that touches the
    // region — one or several, background ones included — so it is a fifth
    // population, and a multi-window total in `walkMilliseconds` would poison
    // the per-app median.

    /// Which rung, over what rectangle, showing what.
    private struct EscalationPlan {
        let tier: EscalationLadder.Tier
        let reason: String
        let region: CGRect
        /// Which resolver these candidates — and therefore these suggested
        /// points — belong to.
        ///
        /// Measured 2026-09-10, and it is a trap that returned a plausible
        /// wrong answer: `press` resolves names in the focused window's tree,
        /// where "Recent" matched one AXWindow and two sidebar AXStaticTexts,
        /// so the separating point was computed against those three. `focus`
        /// resolves the same word against the app's **window list**, where
        /// "Recent" matched two windows — and that point sits inside both.
        /// Re-issuing it came straight back ambiguous. A separating point is
        /// only valid within the candidate set it was computed from, so the
        /// set has to travel with it.
        let resolver: String
        /// What a caller would have to choose between.
        let candidates: [AccessibilityElementNode]
        /// The one application a capture may photograph, and whose windows the
        /// secure-field check walks first. Nil when none could be named — and
        /// then nothing is photographed, never the whole display instead.
        let application: NSRunningApplication?
    }

    /// The rectangle a display tier would cover: the display holding the
    /// window, else the one holding the cursor, else the first one.
    private static func fallbackDisplayFrame(
        forWindowFrame windowFrame: CGRect?,
        among displays: [EscalationLadder.DisplayInfo]
    ) -> CGRect? {
        if let windowFrame, windowFrame.width > 0, windowFrame.height > 0,
           let display = EscalationLadder.display(holding: windowFrame, among: displays) {
            return display.appKitFrame
        }
        let cursor = NSEvent.mouseLocation
        return displays.first(where: { $0.appKitFrame.contains(cursor) })?.appKitFrame
            ?? displays.first?.appKitFrame
    }

    private func escalationPlan(
        forcedTier: EscalationLadder.Tier?,
        title: String,
        role: String?,
        rootNode: AccessibilityElementNode?,
        application: NSRunningApplication?
    ) -> EscalationPlan? {
        let displays = EscalationLadder.displays()
        let allNodes = rootNode?.flattenedDescendants() ?? []
        let candidates = (rootNode.map { root in
            title.isEmpty ? [] : EscalationLadder.namedCandidates(in: root, title: title, role: role)
        }) ?? []

        let choice = EscalationLadder.chooseTier(
            forcedTier: forcedTier,
            candidateFrames: candidates.map(\.frameInAppKitCoordinates),
            windowFrame: rootNode?.frameInAppKitCoordinates,
            windowActionableCount: allNodes.filter(\.isActionable).count
        )

        let region: CGRect?
        switch choice.tier {
        case .element:
            region = EscalationLadder.region(forCandidateFrames: candidates.map(\.frameInAppKitCoordinates))
        case .window:
            region = rootNode?.frameInAppKitCoordinates
        case .display, .none:
            region = Self.fallbackDisplayFrame(
                forWindowFrame: rootNode?.frameInAppKitCoordinates, among: displays
            )
        }
        guard let region, region.width > 0, region.height > 0 else { return nil }

        let inRegion = allNodes.filter { $0.frameInAppKitCoordinates.intersects(region) }
        return EscalationPlan(
            tier: choice.tier,
            reason: choice.reason,
            region: region,
            resolver: "elementName",
            // On the window and display rungs nothing was named, so the useful
            // list is what a caller could name instead.
            candidates: choice.tier == .element ? candidates : inRegion.filter(\.isActionable),
            application: application
        )
    }

    /// How many candidates a payload will describe.
    ///
    /// The window and display rungs answer "what could you have named instead",
    /// which on a rich app is everything actionable — measured 2026-09-10,
    /// Claude Desktop's window returned **110**. That is a large response, and
    /// the separating-point search is quadratic in it: each candidate cuts its
    /// frame at every other candidate's edges, so 110 candidates build a
    /// 221x221 arrangement each, 5.4 million points across the list. Forty is
    /// past the point where a caller reads them anyway.
    static let maximumCandidates = 40

    /// Hang the ladder off a failed `focus`, free unless the caller asked to pay.
    private func attachFocusEscalation(
        to response: inout [String: Any],
        request: HarnessRequest,
        windows: [AccessibilityWindows.WindowCandidate],
        application: NSRunningApplication
    ) {
        guard let plan = windowEscalationPlan(
            title: request.title, windows: windows, application: application
        ) else { return }
        let result = escalationPayload(plan: plan, capture: request.escalate)
        var payload = result.payload
        payload["available"] = true
        if !request.escalate {
            payload["hint"] = "re-issue with \"escalate\": true for an image and candidate points"
        }
        response["escalation"] = payload
    }

    /// The same ladder, built from an app's **window list** instead of a window's
    /// element tree — the candidate set `focus` actually resolves against.
    ///
    /// Windows are turned into `AccessibilityElementNode`s rather than given a
    /// parallel summariser: they have a role, a name, a frame and a published
    /// action list, which is everything the candidate machinery reads.
    private func windowEscalationPlan(
        title: String,
        windows: [AccessibilityWindows.WindowCandidate],
        application: NSRunningApplication
    ) -> EscalationPlan? {
        func node(_ candidate: AccessibilityWindows.WindowCandidate) -> AccessibilityElementNode {
            AccessibilityElementNode(
                role: candidate.role, subrole: candidate.subrole,
                title: candidate.title?.raw, value: nil,
                frameInAppKitCoordinates: candidate.frameInAppKitCoordinates,
                depth: 0, children: [],
                publishedActionNames: candidate.publishedActionNames
            )
        }

        let lowercased = title.lowercased()
        let matching = windows.filter { $0.title?.raw.lowercased() == lowercased }
        let shown = matching.isEmpty ? windows : matching
        let candidates = shown.map(node)
        guard let region = EscalationLadder.region(
            forCandidateFrames: candidates.map(\.frameInAppKitCoordinates)
        ) else { return nil }

        return EscalationPlan(
            tier: .element,
            reason: matching.isEmpty
                ? "no window matched that title; the region is the union of the app's \(windows.count) window(s)"
                : "\(matching.count) window(s) matched that title; the region is the union of their frames padded",
            region: region,
            resolver: "windowTitle",
            candidates: candidates,
            // The resolved app. `focus` has already brought it forward when its
            // windows were Space-hidden, so a capture can walk them — and a
            // window read that still fails is a refusal, not a pass.
            application: application
        )
    }

    /// The candidate list, each entry carrying a point that provably picks it
    /// out — or saying that no point does.
    ///
    /// Plausibly-named candidates come first, because a name is the only thing
    /// a caller can re-issue the intent with; an anonymous element in this list
    /// is context, not an option.
    private static func summariseCandidates(_ all: [AccessibilityElementNode]) -> [[String: Any]] {
        let named = all.filter { $0.displayName?.isPlausibleControlLabel == true }
        let anonymous = all.filter { $0.displayName?.isPlausibleControlLabel != true }
        let nodes = Array((named + anonymous).prefix(maximumCandidates))
        let frames = nodes.map(\.frameInAppKitCoordinates)
        return nodes.indices.map { index in
            var entry = summarise(nodes[index])
            entry["index"] = index
            let point = EscalationLadder.separatingPoint(forCandidateAt: index, among: frames)
            entry["suggestedPoint"] = point.map { ["x": $0.x, "y": $0.y] } ?? NSNull()
            // Never omitted, and never a "nearest" fallback: `false` is the
            // answer that stops a caller re-issuing a point that will only come
            // back ambiguous again.
            entry["separable"] = point != nil
            return entry
        }
    }

    /// The whole payload, shared by `look` (where it is the response) and the
    /// acting verbs (where it hangs under `escalation`).
    private func escalationPayload(
        plan: EscalationPlan,
        capture: Bool
    ) -> (payload: [String: Any], errorCode: String?) {
        var payload: [String: Any] = [
            "tier": plan.tier.rawValue,
            "reason": plan.reason,
            // A suggested point below is only re-issuable to the verb that
            // resolves this way. See `EscalationPlan.resolver`.
            "resolver": plan.resolver
        ]

        guard capture else {
            // The free half, and it is free in bytes as well as in time: which
            // rung and why, nothing else. A capture costs ~344 ms (measured
            // 2026-09-08), so making every `notFound` pay for one silently
            // would turn a 12 ms refusal into a 350 ms one for callers that
            // never wanted a picture — and a candidate list here would put a
            // whole window's actionable elements into every failed press.
            payload["hint"] = "re-issue with \"escalate\": true for an image and candidate points"
            return (payload, nil)
        }

        payload["region"] = [
            "x": plan.region.origin.x, "y": plan.region.origin.y,
            "w": plan.region.size.width, "h": plan.region.size.height
        ]
        // The true total, always — the list below may be shorter. A count that
        // silently equalled the list length would be the truncation defect this
        // project already paid for once, in a new place.
        payload["candidateCount"] = plan.candidates.count
        let listed = Self.summariseCandidates(plan.candidates)
        payload["candidates"] = listed
        if listed.count < plan.candidates.count {
            payload["candidatesTruncated"] = true
            payload["warning"] = "THIS LIST IS A FLOOR, NOT A MEASUREMENT — showing \(listed.count) "
                + "of \(plan.candidates.count) candidates, named ones first"
        }

        // Inspect first, then photograph — and the camera may only see what was
        // inspected. Every window of the one app the capture includes that
        // touches the region is walked here, before the shutter; a refusal that
        // arrives once the JPEG is on disk is not a refusal. There is no path
        // below that photographs without a complete check.
        guard let application = plan.application else {
            payload["message"] = "no application to restrict the capture to, and a display-wide capture is never taken"
            return (payload, "captureFailed")
        }
        let inspectStartedAt = Date()
        let inspection = EscalationLadder.inspectForCapture(region: plan.region, of: application)
        payload["inspectMilliseconds"] = Int(Date().timeIntervalSince(inspectStartedAt) * 1000)
        // How many windows were walked. "complete" beside 0 is legitimate only
        // when no window of the app touches the region — worth being able to see.
        payload["inspectedWindows"] = inspection.windows.count
        payload["secureFieldCheck"] = inspection.incompleteReason ?? "complete"
        let decision = ActionSafetyKernel.evaluateCapture(inspection)
        let described = HarnessPolicy.describe(decision)
        let executability = HarnessPolicy.executability(of: decision, confirmed: false)
        payload["kernel"] = [
            "decision": described.decision,
            "reason": (described.reason ?? NSNull()) as Any,
            "executable": executability.executable,
            "note": (executability.reason ?? NSNull()) as Any
        ]
        guard executability.executable else {
            return (payload, "kernelRefused")
        }

        // Safe to photograph, and nothing to photograph: refuse before the
        // shutter rather than return `ok: true` and a blank image.
        guard inspection.containsDrawableWindow else {
            payload["message"] = "none of this app's windows in the region is a real window (Finder's desktop "
                + "draws nothing in a one-app capture), so the image would be blank"
            return (payload, "applicationNotCapturable")
        }

        let displays = EscalationLadder.displays()
        guard let display = EscalationLadder.display(holding: plan.region, among: displays) else {
            payload["message"] = EscalationLadder.CaptureFailure.regionOffScreen.description
            return (payload, "captureFailed")
        }

        switch EscalationLadder.captureSynchronously(
            region: plan.region, on: display,
            processIdentifier: application.processIdentifier
        ) {
        case .failure(let error):
            payload["message"] = String(describing: error)
            if let failure = error as? EscalationLadder.CaptureFailure,
               case .applicationNotListed = failure {
                return (payload, "applicationNotCapturable")
            }
            return (payload, "captureFailed")

        case .success(let outcome):
            guard let url = EscalationLadder.writeImage(outcome.jpeg) else {
                payload["message"] = "the image could not be written to \(EscalationLadder.imageDirectory.path)"
                return (payload, "captureFailed")
            }
            payload["imagePath"] = url.path
            payload["imageBytes"] = outcome.jpeg.count
            payload["imagePixels"] = ["w": outcome.pixelWidth, "h": outcome.pixelHeight]
            // What was actually photographed, which is the request clipped to
            // the display — not the request.
            payload["region"] = [
                "x": outcome.region.origin.x, "y": outcome.region.origin.y,
                "w": outcome.region.size.width, "h": outcome.region.size.height
            ]
            // The case for a crop is sharpness, not cost, so the resolution is
            // in the response rather than left to be inferred from two numbers.
            // Points per pixel: 0.5 is a Retina display captured at full scale,
            // 1.0 is one pixel per point, and anything above 1 means the 4096
            // cap shrank it.
            payload["pointsPerPixel"] = outcome.pixelWidth > 0
                ? outcome.region.width / CGFloat(outcome.pixelWidth) : 0
            // One estimator in this project, and it is the one that reproduces
            // Anthropic's published table.
            payload["estimatedVisualTokens"] = AccessibilityDumpRunner.estimatedVisualTokens(
                width: outcome.pixelWidth, height: outcome.pixelHeight, usesHighResolutionTier: false
            )
            payload["captureMilliseconds"] = outcome.milliseconds
            return (payload, nil)
        }
    }

    /// Hangs an escalation block under a failed acting verb.
    ///
    /// Always the announcement — which rung would be chosen and why — because
    /// the tree is already in hand and that costs nothing. The picture only
    /// when the caller asked for it.
    private func attachEscalation(
        to response: inout [String: Any],
        request: HarnessRequest,
        rootNode: AccessibilityElementNode
    ) {
        // The frontmost app — the same cached value `snapshotFocusedWindow`
        // read moments ago in this request, so the app walked is the app shot.
        guard let plan = escalationPlan(
            forcedTier: request.tier, title: request.title, role: request.role, rootNode: rootNode,
            application: NSWorkspace.shared.frontmostApplication
        ) else { return }

        let result = escalationPayload(plan: plan, capture: request.escalate)
        var block = result.payload
        block["available"] = true
        // The top-level error stays `notFound`/`ambiguous` — that is what the
        // caller asked for and did not get. A capture that then also failed is
        // a second, separate fact and says so where it happened.
        if let code = result.errorCode { block["error"] = code }
        response["escalation"] = block
    }

    private func lookResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = [
            "title": request.title.isEmpty ? NSNull() : request.title,
            "requestedTier": (request.tier?.rawValue ?? NSNull()) as Any
        ]

        func fail(_ code: String, _ message: String) -> [String: Any] {
            response["ok"] = false
            response["error"] = code
            response["message"] = message
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: code, startedAt: startedAt)
            return response
        }

        // Same guard the walker, the menu path and the window path have. A
        // locked screen is the one thing this verb must never photograph — and
        // it is the failure this project recorded as data three times before
        // anyone read the app name.
        guard !LockScreenGuard.isLockScreen(Self.frontmostBundleIdentifier()) else {
            return fail("screenIsLocked", "the screen is locked — there is nothing of the user's to photograph")
        }

        // A failed walk is not fatal here: the display rung needs no tree at
        // all, and "I could not read the window, here is the screen" is a more
        // useful answer than a refusal. Why it failed still travels.
        var rootNode: AccessibilityElementNode?
        do {
            let snapshot = try AccessibilityTreeWalker.snapshotFocusedWindow()
            rootNode = snapshot.rootNode
            response["application"] = snapshot.applicationName
            response["bundleIdentifier"] = snapshot.bundleIdentifier
            response["walkMilliseconds"] = Int(snapshot.walkDurationInSeconds * 1000)
        } catch {
            response["snapshotError"] = Self.errorCode(for: error)
            response["application"] = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
            response["bundleIdentifier"] = Self.frontmostBundleIdentifier() ?? "unknown"
        }

        guard let plan = escalationPlan(
            forcedTier: request.tier, title: request.title, role: request.role, rootNode: rootNode,
            application: NSWorkspace.shared.frontmostApplication
        ) else {
            return fail(
                "notFound",
                request.tier == .element
                    ? "nothing matched that name, so there is no element region to crop to"
                    : "no rectangle to capture: neither a window frame nor a display frame was readable"
            )
        }

        let result = escalationPayload(plan: plan, capture: true)
        for (key, value) in result.payload { response[key] = value }
        response["ok"] = result.errorCode == nil
        if let code = result.errorCode { response["error"] = code }
        audit(
            request, dryRun: dryRun,
            kernel: (result.payload["kernel"] as? [String: Any])?["decision"] as? String ?? "n/a",
            outcome: result.errorCode ?? "ok", startedAt: startedAt
        )
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
            // A focus request may name only an app, and a mutating verb whose
            // audit line does not say what it acted on is half a record.
            target: request.title.isEmpty
                ? (request.aimAtFocus ? "<focused>" : request.app)
                : request.title,
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
