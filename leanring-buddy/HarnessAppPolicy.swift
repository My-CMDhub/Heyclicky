//
//  HarnessAppPolicy.swift
//  Clicky
//
//  Per-app policy for the harness, edited by the owner as a file:
//  ~/Library/Application Support/Clicky/harness-policy.json
//
//  { "default": "allow", "apps": { "com.apple.Terminal": "confirm" } }
//
//  Composed with the kernel's element-level decision, never instead of it.
//

import Foundation

enum HarnessAppPolicy {

    enum Verdict: String, Decodable {
        case allow, confirm, refuse
    }

    struct Policy: Decodable, Equatable {
        let defaultVerdict: Verdict
        let apps: [String: Verdict]

        enum CodingKeys: String, CodingKey {
            case defaultVerdict = "default"
            case apps
        }

        init(defaultVerdict: Verdict = .allow, apps: [String: Verdict] = [:]) {
            self.defaultVerdict = defaultVerdict
            self.apps = apps
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            defaultVerdict = try container.decodeIfPresent(Verdict.self, forKey: .defaultVerdict) ?? .allow
            // Keys are stored lower-cased so the lookup is one dictionary hit. Two
            // keys differing only in case would make the answer order-undefined,
            // so that file is refused rather than picked from.
            var lowered: [String: Verdict] = [:]
            for (key, verdict) in try container.decodeIfPresent([String: Verdict].self, forKey: .apps) ?? [:] {
                let folded = key.lowercased()
                guard lowered.updateValue(verdict, forKey: folded) == nil else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .apps, in: container,
                        debugDescription: "apps lists \"\(key)\" more than once (keys are case-insensitive)"
                    )
                }
            }
            apps = lowered
        }
    }

    enum Load: Equatable {
        case loaded(Policy, source: String)
        case missing
        /// Fail closed. A policy that fails to parse and becomes "allow" is the
        /// read-failure-returned-as-absence bug this project has hit three times.
        case unreadable(reason: String)
    }

    static func load(from url: URL) -> Load {
        // lstat, not `fileExists` — that follows symlinks, so a dangling link
        // read as "missing" and became allow. Only ENOENT is missing.
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return .missing
        } catch {
            return .unreadable(reason: "\(url.path): \(error.localizedDescription)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unreadable(reason: "\(url.path): \(error.localizedDescription)")
        }
        switch parse(data) {
        case .success(let policy): return .loaded(policy, source: "file")
        case .failure(let failure): return .unreadable(reason: "\(url.path): \(failure.reason)")
        }
    }

    static func parse(_ data: Data) -> Result<Policy, ParseFailure> {
        do {
            return .success(try JSONDecoder().decode(Policy.self, from: data))
        } catch {
            return .failure(ParseFailure(reason: String(describing: error).prefix(200).description))
        }
    }

    struct ParseFailure: Error, Equatable { let reason: String }

    /// Case-insensitive: bundle identifiers are, and `Policy` stores its keys lower-cased.
    static func verdict(for bundleIdentifier: String?, in policy: Policy) -> (Verdict, source: String) {
        if let bundleIdentifier, let listed = policy.apps[bundleIdentifier.lowercased()] {
            return (listed, "file")
        }
        return (policy.defaultVerdict, "default")
    }

    /// nil policy = no file on disk: allow, `source: "missing"`.
    static func verdict(for bundleIdentifier: String?, in policy: Policy?) -> (Verdict, source: String) {
        guard let policy else { return (.allow, "missing") }
        return verdict(for: bundleIdentifier, in: policy)
    }

    /// Policy `refuse` beats everything; a kernel refuse beats a policy
    /// `confirm`; `allow` is the kernel unchanged. `.refuse` is never
    /// executable in `HarnessPolicy.executability`, so `confirmed: true`
    /// cannot lift a policy refusal either.
    static func compose(policy: Verdict, bundleIdentifier: String?, kernel: SafetyDecision) -> SafetyDecision {
        let app = bundleIdentifier ?? "an app with no bundle identifier"
        switch (policy, kernel) {
        case (.refuse, _):
            return .refuse(reason: "app policy refuses \(app)")
        case (.confirm, .refuse):
            return kernel
        case (.confirm, .requireConfirmation(let kernelReason)):
            return .requireConfirmation(reason: "app policy requires confirmation for \(app); \(kernelReason)")
        case (.confirm, .allow):
            return .requireConfirmation(reason: "app policy requires confirmation for \(app)")
        case (.allow, _):
            return kernel
        }
    }
}
