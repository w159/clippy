import Foundation
import os

/// One 1Password item as surfaced in the sidebar (no secret value until revealed).
struct OPItem: Identifiable, Equatable {
    let id: String
    let title: String
    let category: String
    let updatedAt: String?
}

/// The type of a single field inside a 1Password item.
enum OPFieldType: String, Equatable {
    case concealed = "CONCEALED"
    case string    = "STRING"
    case otp       = "OTP"
    case url       = "URL"
    case email     = "EMAIL"
    case phone     = "PHONE"
    case date      = "DATE"
    case monthYear = "MONTH_YEAR"
    case menu      = "MENU"
    case reference = "REFERENCE"
    case unknown

    init(raw: String) {
        self = OPFieldType(rawValue: raw.uppercased()) ?? .unknown
    }

    var isConcealed: Bool { self == .concealed }
    var isOTP: Bool       { self == .otp }
}

/// A section header inside an item (the "General", "Section A" groupings).
struct OPSection: Equatable {
    let id: String
    let label: String
}

/// One field in a 1Password item. Values are never logged or persisted.
struct OPField: Identifiable, Equatable {
    let id: String
    let label: String
    let type: OPFieldType
    /// Nil for CONCEALED and OTP until explicitly fetched.
    let value: String?
    let section: OPSection?
    /// The purpose hint from op (e.g. "USERNAME", "PASSWORD", "NOTES").
    let purpose: String?
}

/// Full detail for one 1Password item, returned by `fetchItemDetail`.
struct OPItemDetail: Equatable {
    let id: String
    let title: String
    let category: String
    /// Fields in the order op returns them, preserving section grouping.
    let fields: [OPField]

    /// Field IDs grouped by section id, preserving op's order. nil key = no section.
    var sectionedFields: [(section: OPSection?, fields: [OPField])] {
        var buckets: [(OPSection?, [OPField])] = []
        var keyOrder: [String?] = []  // nil = unsectioned

        for field in fields {
            let key = field.section?.id
            if !keyOrder.contains(where: { $0 == key }) {
                keyOrder.append(key)
                buckets.append((field.section, [field]))
            } else if let idx = buckets.firstIndex(where: { $0.0?.id == key }) {
                buckets[idx].1.append(field)
            }
        }
        return buckets
    }
}

enum OnePasswordError: LocalizedError {
    case notInstalled
    case notSignedIn(String)
    case command(String)
    /// `op` did not answer within the timeout (typically the 1Password app is
    /// waiting on an unlock prompt that nobody saw).
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "The 1Password CLI (op) was not found. Install 1Password 8 and enable the command-line tool."
        case .notSignedIn(let detail):
            return "Not signed in to 1Password. \(detail)"
        case .command(let detail):
            return detail
        case .timedOut:
            return "1Password did not respond. Unlock the 1Password app and try again."
        }
    }
}

// MARK: - Command runner

/// Seam between `OnePasswordService` and the `op` binary, so the service and the
/// view model can be exercised with a scripted runner instead of a real CLI.
protocol OpCommandRunner: Sendable {
    /// True when an `op` executable can be found right now (re-probed each call).
    var isAvailable: Bool { get }

    /// Run `op` with `args`. `input`, when set, is written to the child's stdin.
    /// Secrets MUST travel through `input`, never through `args`: argv is world
    /// readable through `ps`.
    func run(_ args: [String], input: String?, timeout: TimeInterval) async -> Subprocess.Output
}

/// Production runner: spawns the real `op` via `Subprocess`.
struct SubprocessOpRunner: OpCommandRunner {
    var isAvailable: Bool { OnePasswordService.executablePath() != nil }

    func run(_ args: [String], input: String?, timeout: TimeInterval) async -> Subprocess.Output {
        guard let exe = OnePasswordService.executablePath() else {
            return Subprocess.Output(stdout: "", stderr: "op not found", exitCode: -1,
                                     launchFailed: true, timedOut: false)
        }
        return await Subprocess.run(exe, args, input: input, timeout: timeout)
    }
}

/// Wraps the 1Password `op` CLI. Clippy reads items from one vault (default
/// "Clippy") and can create new secrets there; revealing a value invokes `op`,
/// which prompts the user via the 1Password app for biometric/app unlock. No
/// secret values are persisted by Clippy.
struct OnePasswordService {
    let vault: String
    let runner: any OpCommandRunner

    /// Timeout for read operations (list/get). Long enough for a biometric unlock,
    /// short enough that the view never spins indefinitely.
    static let readTimeout: TimeInterval = 20
    /// Timeout for `op signin`, which waits on the 1Password app's approval prompt.
    static let signInTimeout: TimeInterval = 60

    init(vault: String, runner: any OpCommandRunner = SubprocessOpRunner()) {
        self.vault = vault.isEmpty ? "Clippy" : vault
        self.runner = runner
    }

    /// Resolve the op executable. GUI apps receive a stripped PATH, so common
    /// install locations are probed first, then PATH is consulted via /usr/bin/env.
    static func executablePath() -> String? {
        // A GUI app launched from Finder gets a stripped PATH, so a `/usr/bin/env op`
        // fallback cannot find op. findBinary checks well-known prefixes, then probes
        // a login shell's PATH (`which op`) which sees the user's real environment.
        let hardcoded = ["/opt/homebrew/bin/op", "/usr/local/bin/op", "/usr/bin/op"]
        return Subprocess.findBinary(named: "op", candidates: hardcoded)
    }

    /// How long a positive/negative install probe is trusted before the next read
    /// re-probes. Short, so installing `op` while the app runs is picked up.
    static let installProbeTTL: TimeInterval = 15
    private static let probeResult = OSAllocatedUnfairLock<(value: Bool, at: Date)?>(initialState: nil)

    /// Whether the `op` CLI is installed. Cached briefly (the settings UI reads this
    /// several times per render), then re-probed. Use `refreshInstalled()` to force it.
    static var isInstalled: Bool {
        if let cached = probeResult.withLock({ $0 }), Date().timeIntervalSince(cached.at) < installProbeTTL {
            return cached.value
        }
        return refreshInstalled()
    }

    /// Re-probe the filesystem/login shell now and update the cache.
    @discardableResult
    static func refreshInstalled() -> Bool {
        let found = executablePath() != nil
        probeResult.withLock { $0 = (found, Date()) }
        return found
    }

    private func op(_ args: [String], input: String? = nil,
                    timeout: TimeInterval = OnePasswordService.readTimeout) async throws -> String {
        guard runner.isAvailable else { throw OnePasswordError.notInstalled }
        let result = await runner.run(args, input: input, timeout: timeout)
        if result.timedOut { throw OnePasswordError.timedOut }
        guard result.succeeded else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = stderr.lowercased()
            let signInHints = ["sign in", "signed in", "authorization", "no accounts configured",
                               "session expired", "authenticate"]
            if signInHints.contains(where: lower.contains) {
                throw OnePasswordError.notSignedIn(stderr)
            }
            throw OnePasswordError.command(stderr.isEmpty
                ? "op exited with code \(result.exitCode)"
                : stderr)
        }
        return result.stdout
    }

    // MARK: - Operations

    /// Probe the current session (`op whoami`). Throws `notSignedIn` when there is none.
    func whoami() async throws {
        _ = try await op(["whoami", "--format", "json"])
    }

    /// Ask the 1Password app to authorize this CLI (`op signin`), then confirm the
    /// session with `op whoami`. With desktop-app integration this raises the
    /// app's approval prompt; the shell-export output of `op signin` is discarded.
    func signIn() async throws {
        _ = try await op(["signin"], timeout: Self.signInTimeout)
        try await whoami()
    }

    func listItems() async throws -> [OPItem] {
        let json = try await op(["item", "list", "--vault", vault, "--format", "json"])
        return Self.parseItems(Data(json.utf8))
    }

    /// Fetch full item detail including all fields. Prompts via the 1Password app.
    func fetchItemDetail(itemID: String) async throws -> OPItemDetail {
        let json = try await op(["item", "get", itemID, "--vault", vault, "--format", "json"])
        guard let detail = Self.parseItemDetail(Data(json.utf8)) else {
            throw OnePasswordError.command("Could not read item fields.")
        }
        return detail
    }

    /// Fetch the current TOTP code for a field on demand (never cached).
    /// Uses `op item get <id> --otp` which returns only the raw TOTP token.
    func fetchTOTP(itemID: String) async throws -> String {
        let raw = try await op(["item", "get", itemID, "--otp"])
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            throw OnePasswordError.command("No TOTP code returned.")
        }
        return code
    }

    /// Reveal the primary concealed value of an item (prompts via the 1Password app).
    /// Kept for backward compatibility with the create-flow copy action.
    func revealValue(itemID: String) async throws -> String {
        let json = try await op(["item", "get", itemID, "--vault", vault, "--format", "json"])
        guard let value = Self.parsePrimaryValue(Data(json.utf8)) else {
            throw OnePasswordError.command("That item has no readable secret field.")
        }
        return value
    }

    /// Create a new Password item in the Clippy vault.
    ///
    /// The secret is delivered as a JSON item template on stdin, never as an
    /// `password=<value>` assignment argument, because argv is readable by any local
    /// process through `ps`.
    func createSecret(title: String, value: String) async throws {
        let template = Self.itemTemplate(title: title, value: value)
        _ = try await op(["item", "create", "--vault", vault], input: template)
    }

    /// JSON item template for `op item create` on stdin (Password category).
    static func itemTemplate(title: String, value: String) -> String {
        let object: [String: Any] = [
            "title": title,
            "category": "PASSWORD",
            "fields": [[
                "id": "password",
                "type": "CONCEALED",
                "purpose": "PASSWORD",
                "label": "password",
                "value": value,
            ] as [String: Any]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Parsing (pure, tested)

    static func parseItems(_ data: Data) -> [OPItem] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { obj in
            guard let id = obj["id"] as? String, let title = obj["title"] as? String else { return nil }
            let category = (obj["category"] as? String) ?? "ITEM"
            let updated = obj["updated_at"] as? String ?? obj["last_edited_at"] as? String
            return OPItem(id: id, title: title, category: category, updatedAt: updated)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Parse the full JSON object returned by `op item get --format json` into
    /// an OPItemDetail. Preserves field and section order as returned by op.
    /// Field values for CONCEALED and OTP types are retained here because the
    /// caller already authenticated via the 1Password app; the caller is
    /// responsible for never logging or persisting these values.
    static func parseItemDetail(_ data: Data) -> OPItemDetail? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let title = obj["title"] as? String else { return nil }

        let category = (obj["category"] as? String) ?? "ITEM"

        // Build a section lookup keyed by section id.
        var sectionByID: [String: OPSection] = [:]
        if let secs = obj["sections"] as? [[String: Any]] {
            for sectionEntry in secs {
                guard let sid = sectionEntry["id"] as? String else { continue }
                let label = (sectionEntry["label"] as? String) ?? sid
                sectionByID[sid] = OPSection(id: sid, label: label)
            }
        }

        let rawFields = (obj["fields"] as? [[String: Any]]) ?? []
        let fields: [OPField] = rawFields.compactMap { rawField in
            guard let fid = rawField["id"] as? String else { return nil }
            let label   = (rawField["label"] as? String) ?? fid
            let typeRaw = (rawField["type"] as? String) ?? "STRING"
            let fieldType = OPFieldType(raw: typeRaw)
            let value   = (rawField["value"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let purpose = rawField["purpose"] as? String

            // Section reference is a nested object: {"id": "...", "label": "..."}
            var section: OPSection?
            if let sRef = rawField["section"] as? [String: Any], let sID = sRef["id"] as? String {
                // Prefer the top-level sections array for canonical label; fall back
                // to the inline label on the field's section ref.
                if let known = sectionByID[sID] {
                    section = known
                } else {
                    let sLabel = (sRef["label"] as? String) ?? sID
                    section = OPSection(id: sID, label: sLabel)
                }
            }

            return OPField(id: fid, label: label, type: fieldType,
                           value: value, section: section, purpose: purpose)
        }

        return OPItemDetail(id: id, title: title, category: category, fields: fields)
    }

    /// The credential value: prefer a CONCEALED field labelled/ided "password",
    /// then any non-empty concealed field, then any non-empty field value.
    static func parsePrimaryValue(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fields = obj["fields"] as? [[String: Any]] else { return nil }

        func value(_ field: [String: Any]) -> String? {
            (field["value"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func isConcealed(_ field: [String: Any]) -> Bool {
            (field["type"] as? String)?.uppercased() == "CONCEALED"
        }
        func isPassword(_ field: [String: Any]) -> Bool {
            let id = (field["id"] as? String)?.lowercased()
            let label = (field["label"] as? String)?.lowercased()
            return id == "password" || label == "password"
        }

        if let field = fields.first(where: { isConcealed($0) && isPassword($0) }), let credential = value(field) { return credential }
        if let field = fields.first(where: { isConcealed($0) && value($0) != nil }), let credential = value(field) { return credential }
        if let field = fields.first(where: { value($0) != nil }), let credential = value(field) { return credential }
        return nil
    }
}
