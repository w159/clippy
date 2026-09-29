import XCTest
@testable import Clippy

final class AuditLogTests: XCTestCase {

    private func makeLog(now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_790_000_000) }) -> AuditLog {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-audit-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return AuditLog(directory: dir, now: now)
    }

    private func appFile(_ log: AuditLog) throws -> URL {
        try XCTUnwrap(FileManager.default.contentsOfDirectory(at: log.directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(AuditLog.appPrefix) })
    }

    private func fill(_ log: AuditLog, count: Int = 4) {
        for index in 0..<count {
            log.record(actor: "ai", action: "tool.run", detail: "step \(index)", clipIDs: [Int64(index), 99])
        }
    }

    func testChainVerifiesAndFirstLineAnchorsToGenesis() throws {
        let log = makeLog()
        fill(log)
        let report = log.verify()
        XCTAssertTrue(report.isValid, "\(report.failures)")
        XCTAssertEqual(report.entriesChecked, 4)
        XCTAssertEqual(report.filesChecked, 1)
        let first = try String(contentsOf: appFile(log), encoding: .utf8).split(separator: "\n").first!
        let entry = try JSONDecoder().decode(AuditLog.Entry.self, from: Data(first.utf8))
        XCTAssertEqual(entry.prev, AuditLog.genesis)
    }

    func testEachLineCarriesHashOfPreviousLine() throws {
        let log = makeLog()
        fill(log, count: 3)
        let lines = try String(contentsOf: appFile(log), encoding: .utf8).split(separator: "\n").map(String.init)
        let second = try JSONDecoder().decode(AuditLog.Entry.self, from: Data(lines[1].utf8))
        XCTAssertEqual(second.prev, AuditLog.sha256Hex(Data(lines[0].utf8)))
    }

    func testEditingAMiddleLineIsDetected() throws {
        let log = makeLog()
        fill(log)
        let url = try appFile(log)
        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        lines[1] = lines[1].replacingOccurrences(of: "step 1", with: "step X")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let report = log.verify()
        XCTAssertFalse(report.isValid)
        XCTAssertEqual(report.failures.first?.line, 3, "the line after the edit no longer chains")
    }

    func testDeletingALineIsDetected() throws {
        let log = makeLog()
        fill(log)
        let url = try appFile(log)
        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        lines.remove(at: 1)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(log.verify().isValid)
    }

    func testMalformedLineIsReported() throws {
        let log = makeLog()
        fill(log, count: 2)
        let url = try appFile(log)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        let report = log.verify()
        XCTAssertEqual(report.failures.map(\.reason), ["malformed line"])
    }

    func testAppendAfterReopenContinuesChain() throws {
        let log = makeLog()
        fill(log, count: 2)
        let reopened = AuditLog(directory: log.directory, now: { Date(timeIntervalSince1970: 1_790_000_100) })
        reopened.record(actor: "ai", action: "tool.run", detail: "later", clipIDs: [])
        XCTAssertTrue(reopened.verify().isValid)
        XCTAssertEqual(reopened.verify().entriesChecked, 3)
    }

    func testFilesAreOwnerOnly() throws {
        let log = makeLog()
        fill(log, count: 1)
        let attrs = try FileManager.default.attributesOfItem(atPath: appFile(log).path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testMonthlyRotationUsesSeparateFilesEachAnchoredAtGenesis() throws {
        var current = Date(timeIntervalSince1970: 1_790_000_000)
        let log = makeLog(now: { current })
        log.record(actor: "a", action: "x", detail: "", clipIDs: [])
        current = current.addingTimeInterval(40 * 86_400)
        log.record(actor: "a", action: "y", detail: "", clipIDs: [])
        let files = try FileManager.default.contentsOfDirectory(at: log.directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(log.verify().isValid)
    }

    func testMcpStreamIsVerifiedAndTamperingWithItIsDetected() throws {
        let log = makeLog()
        fill(log, count: 1)
        // A line pair in the format the Node server writes.
        func line(_ action: String, prev: String) -> String {
            #"{"ts":"2026-09-01T00:00:00.000Z","actor":"mcp","action":"\#(action)","detail":"outcome=ok","clipIDs":[7],"prev":"\#(prev)"}"#
        }
        let first = line("clippy_get_clip", prev: AuditLog.genesis)
        let second = line("clippy_list_recent", prev: AuditLog.sha256Hex(Data(first.utf8)))
        let mcp = log.directory.appendingPathComponent("mcp-audit-2026-09.jsonl")
        try "\(first)\n\(second)\n".write(to: mcp, atomically: true, encoding: .utf8)
        var report = log.verify()
        XCTAssertTrue(report.isValid, "\(report.failures)")
        XCTAssertEqual(report.filesChecked, 2)
        XCTAssertEqual(report.entriesChecked, 3)

        try "\(first.replacingOccurrences(of: "[7]", with: "[8]"))\n\(second)\n"
            .write(to: mcp, atomically: true, encoding: .utf8)
        report = log.verify()
        XCTAssertEqual(report.failures.map(\.file), ["mcp-audit-2026-09.jsonl"])
    }

    func testExportMergesStreamsAndEscapesCSV() throws {
        let log = makeLog()
        log.record(actor: "ai", action: "tool.run", detail: #"said "hi", ok"#, clipIDs: [1, 2])
        let mcp = log.directory.appendingPathComponent("mcp-audit-2026-09.jsonl")
        try #"{"ts":"2026-09-01T00:00:00.000Z","actor":"mcp","action":"clippy_get_clip","detail":"outcome=ok","clipIDs":[5],"prev":"\#(AuditLog.genesis)"}"#
            .appending("\n").write(to: mcp, atomically: true, encoding: .utf8)

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("audit-export-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        XCTAssertEqual(try log.export(to: out.appendingPathExtension("csv"), format: .csv), 2)
        let csv = try String(contentsOf: out.appendingPathExtension("csv"), encoding: .utf8)
        XCTAssertTrue(csv.contains(#""said ""hi"", ok""#))
        XCTAssertTrue(csv.contains("1;2"))
        XCTAssertTrue(csv.hasPrefix("stream,timestamp"))

        XCTAssertEqual(try log.export(to: out.appendingPathExtension("json"), format: .json), 2)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathExtension("json"))) as? [[String: Any]]
        XCTAssertEqual(Set(json?.compactMap { $0["stream"] as? String } ?? []), ["app", "mcp"])
        try? FileManager.default.removeItem(at: out.appendingPathExtension("csv"))
        try? FileManager.default.removeItem(at: out.appendingPathExtension("json"))
    }

    func testEmptyDirectoryVerifiesClean() {
        let report = makeLog().verify()
        XCTAssertTrue(report.isValid)
        XCTAssertEqual(report.filesChecked, 0)
    }
}
