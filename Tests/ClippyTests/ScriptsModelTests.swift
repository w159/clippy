import XCTest
@testable import Clippy

/// Lossy decode, quarantine, dirty check, argument parsing, store features.
@MainActor
final class ScriptsModelTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("clippy-scripts-\(UUID().uuidString).json")
    }

    private func cleanup(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.contains(stem) || name.hasPrefix("scripts.quarantine-") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private let good = """
    {"id":"6EF30786-2E8D-4A00-8355-5341539447C6","name":"ok","interpreter":"zsh","body":"echo hi",
     "feedsClipboard":false,"outputToClipboard":false,"createdAt":"2026-06-12T03:20:43Z","updatedAt":"2026-06-12T03:20:43Z"}
    """

    func testLossyDecodeKeepsGoodEntriesAndReportsBadOnes() throws {
        let json = "[\(good), {\"name\": 5}, 7, \(good)]"
        let result = try Script.decodeLossy(Data(json.utf8))
        XCTAssertEqual(result.scripts.count, 1)
        XCTAssertEqual(result.rejected.count, 3, "bad object, bad scalar, and the duplicate id")
        XCTAssertEqual(result.scripts[0].timeoutSeconds, Script.defaultTimeoutSeconds, "new fields default")
        XCTAssertThrowsError(try Script.decodeLossy(Data("{}".utf8)))
    }

    func testStoreQuarantinesBadEntryInsteadOfLosingEverything() throws {
        let url = tempURL()
        defer { cleanup(url) }
        try "[\(good), {\"id\": \"nope\"}]".write(to: url, atomically: true, encoding: .utf8)
        let store = ScriptStore(fileURL: url, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertEqual(store.scripts.map(\.name), ["ok"])
        XCTAssertNotNil(store.quarantineNotice)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix("scripts.quarantine-") })
        XCTAssertEqual(ScriptStore(fileURL: url, defaults: UserDefaults(suiteName: UUID().uuidString)!).scripts.count, 1)
    }

    func testDirtyCheckCoversEveryEditableField() {
        let base = Script(name: "n", body: "b")
        let mutations: [(String, (inout Script) -> Void)] = [
            ("name", { $0.name = "x" }), ("interpreter", { $0.interpreter = .bash }), ("body", { $0.body = "x" }),
            ("feeds", { $0.feedsClipboard = true }), ("output", { $0.outputToClipboard = true }),
            ("enabled", { $0.isEnabled = false }), ("args", { $0.arguments = ["a"] }),
            ("cwd", { $0.workingDirectory = "/tmp" }), ("env", { $0.environment = ["A": "1"] }),
            ("custom", { $0.customInterpreterPath = "/bin/sh" }), ("timeout", { $0.timeoutSeconds = 5 }),
            ("confirm", { $0.confirmBeforeRun = true }), ("stdin", { $0.stdinText = "x" }),
        ]
        for (label, mutate) in mutations {
            var changed = base
            mutate(&changed)
            XCTAssertTrue(changed.hasEditableChanges(comparedTo: base), "\(label) must make the script dirty")
        }
        var bookkeeping = base
        bookkeeping.updatedAt = Date(timeIntervalSince1970: 1)
        bookkeeping.sortOrder = 9
        XCTAssertFalse(bookkeeping.hasEditableChanges(comparedTo: base))
        XCTAssertFalse(Script(name: "").isDirtyDraft)
        XCTAssertTrue(Script(name: "", isEnabled: false).isDirtyDraft)
    }

    func testCodableRoundTripKeepsNewFields() throws {
        // Whole-second dates: the on-disk format is ISO 8601 without fractions.
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let script = Script(name: "r", createdAt: stamp, updatedAt: stamp, arguments: ["a b"], workingDirectory: "/tmp", environment: ["K": "v"],
                            customInterpreterPath: "/bin/sh", timeoutSeconds: 7, confirmBeforeRun: true, stdinText: "in")
        let data = try Script.makeEncoder().encode([script])
        XCTAssertEqual(try Script.decodeLossy(data).scripts, [script])
    }

    func testArgumentParsingHandlesQuotesAndRoundTrips() {
        XCTAssertEqual(ScriptArguments.split(#"a "b c" 'd e' f\ g ''"#), ["a", "b c", "d e", "f g", ""])
        let args = ["plain", "two words", "it's", ""]
        XCTAssertEqual(ScriptArguments.split(ScriptArguments.join(args)), args)
        XCTAssertEqual(ScriptArguments.parseEnvironment("A=1\n# c\nbad line\n1X=no\nB=x=y"), ["A": "1", "B": "x=y"])
    }

    func testStableOrderKeepsEqualSortOrdersInInputOrder() {
        let scripts = ["c", "a", "b"].map { Script(name: $0, sortOrder: 0) }
        XCTAssertEqual(ScriptStore.ordered(scripts).map(\.name), ["c", "a", "b"])
    }

    func testSearchMatchesBodiesAndDuplicateAndImportAreDisabled() throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = ScriptStore(fileURL: url, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.add(Script(name: "Alpha", body: "rm -rf build"))
        store.add(Script(name: "Beta", body: "echo hi"))
        XCTAssertEqual(store.search("RM -RF").map(\.name), ["Alpha"])
        XCTAssertEqual(store.search("").count, 2)

        let copy = try XCTUnwrap(store.duplicate(id: store.scripts[0].id))
        XCTAssertFalse(copy.isEnabled)
        XCTAssertEqual(store.scripts.map(\.name), ["Alpha", "Alpha copy", "Beta"])

        let exported = try store.exportJSON(ids: [store.scripts[2].id])
        let result = try store.importJSON(exported)
        XCTAssertEqual(result, ScriptStore.ImportResult(imported: 1, rejected: 0))
        XCTAssertFalse(store.scripts.last!.isEnabled)
        XCTAssertEqual(Set(store.scripts.map(\.id)).count, store.scripts.count, "imports get fresh ids")
    }

    func testHistoryIsCappedPerScriptAndNeverPersistsOutput() throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = ScriptStore(fileURL: url, defaults: UserDefaults(suiteName: UUID().uuidString)!, persistHistory: true)
        let id = UUID(), other = UUID()
        store.recordRun(scriptID: other, startedAt: Date(),
                        result: ScriptResult(stdout: "x", stderr: "", exitCode: 0, durationMs: 1, timedOut: false))
        for index in 0..<30 {
            store.recordRun(scriptID: id, startedAt: Date(),
                            result: ScriptResult(stdout: "secret-\(index)", stderr: "", exitCode: 1, durationMs: index, timedOut: false))
        }
        XCTAssertEqual(store.history(for: id).count, ScriptStore.historyLimit)
        XCTAssertEqual(store.history(for: id).first?.durationMs, 29, "newest first")
        XCTAssertEqual(store.history(for: other).count, 1)
        let onDisk = try String(contentsOf: url.deletingPathExtension().appendingPathExtension("history.json"), encoding: .utf8)
        XCTAssertFalse(onDisk.contains("secret-"), "output must never reach disk")
        let reloaded = ScriptStore(fileURL: url, defaults: UserDefaults(suiteName: UUID().uuidString)!, persistHistory: true)
        XCTAssertEqual(reloaded.history(for: id).count, ScriptStore.historyLimit)
        XCTAssertNil(reloaded.history(for: id).first?.stdout)
    }
}
