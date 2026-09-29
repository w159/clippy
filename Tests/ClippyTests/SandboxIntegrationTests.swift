import XCTest
import Darwin
@testable import Clippy

/// Runs the real `/usr/bin/sandbox-exec` with a generated profile.
final class SandboxIntegrationTests: XCTestCase {

    private var scratch = ""

    override func setUpWithError() throws {
        try XCTSkipIf(!SandboxRunner.preflight().isAvailable, "sandbox-exec unavailable")
        scratch = try SandboxRunner.makeScratchDirectory()
    }

    override func tearDown() {
        if !scratch.isEmpty { try? FileManager.default.removeItem(atPath: scratch) }
    }

    private func run(_ script: String, network: Bool = false, sandboxed: Bool = true) throws -> Int32 {
        let process = Process()
        if sandboxed {
            let profile = SandboxProfile.make(options: .init(scratchDirectory: scratch, allowNetwork: network))
            process.executableURL = URL(fileURLWithPath: SandboxRunner.executablePath)
            process.arguments = SandboxRunner.wrappedArguments(profile: profile, executable: "/bin/sh",
                                                               arguments: ["-c", script])
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
        }
        process.currentDirectoryURL = URL(fileURLWithPath: scratch)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testScratchWriteSucceeds() throws {
        XCTAssertEqual(try run("echo ok > '\(scratch)/out.txt'"), 0)
        XCTAssertEqual(try String(contentsOfFile: scratch + "/out.txt", encoding: .utf8), "ok\n")
    }

    func testWriteOutsideScratchIsDenied() throws {
        let outside = NSHomeDirectory() + "/.clippy-sandbox-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: outside) }
        XCTAssertNotEqual(try run("echo no > '\(outside)'"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside))
    }

    func testNetworkConnectIsDeniedByDefaultButAllowedWhenRequested() throws {
        // A local listener: connect() succeeds against its backlog without accept().
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 4), 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        XCTAssertEqual(named, 0)
        let port = UInt16(bigEndian: addr.sin_port)

        let probe = "/usr/bin/nc -z -w 2 127.0.0.1 \(port)"
        XCTAssertEqual(try run(probe, sandboxed: false), 0, "control: unsandboxed connect must work")
        XCTAssertNotEqual(try run(probe), 0, "sandboxed connect must be denied")
        XCTAssertEqual(try run(probe, network: true), 0, "allowNetwork lifts the denial")
    }

    /// A scratch directory whose NAME is a Seatbelt injection payload. If escaping
    /// failed, the profile would grant network or reset to allow-default.
    func testHostileScratchPathCannotWidenTheSandbox() throws {
        let hostileName = "x\") (allow network*) (allow file-write*) (deny default (with none) \""
        let hostile = try SandboxRunner.makeScratchDirectory() + "/" + hostileName
        try FileManager.default.createDirectory(atPath: hostile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: hostile) }
        let canonical = SandboxRunner.canonicalPath(hostile)

        let listener = try LocalListener()
        let outside = NSHomeDirectory() + "/.clippy-sandbox-hostile-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: outside) }

        func run(_ script: String) throws -> Int32 {
            let profile = SandboxProfile.make(options: .init(scratchDirectory: canonical))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: SandboxRunner.executablePath)
            // $0 = hostile dir, $1 = outside path, $2 = port; no shell quoting of payloads.
            process.arguments = SandboxRunner.wrappedArguments(
                profile: profile, executable: "/bin/sh",
                arguments: ["-c", script, canonical, outside, String(listener.port)])
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        XCTAssertEqual(try run("echo ok > \"$0/f\""), 0, "escaped path must still be writable")
        XCTAssertNotEqual(try run("echo no > \"$1\""), 0, "write outside scratch must stay denied")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside))
        XCTAssertNotEqual(try run("/usr/bin/nc -z -w 2 127.0.0.1 \"$2\""), 0, "network must stay denied")
    }
}

/// A bound, listening loopback TCP socket on an ephemeral port.
private final class LocalListener {
    let port: UInt16
    private let fd: Int32

    init() throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, size) }
        }
        guard bound == 0, listen(sock, 4) == 0 else { close(sock); throw POSIXError(.EADDRNOTAVAIL) }
        var len = size
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        fd = sock
        port = UInt16(bigEndian: addr.sin_port)
    }

    deinit { close(fd) }
}
