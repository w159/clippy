import ClippyCLICore
import XCTest
@testable import Clippy

final class CLIArgumentsTests: XCTestCase {
    private func command(_ args: [String]) throws -> CLICommand { try CLIArguments.parse(args).get().command }

    func testCommands() throws {
        XCTAssertEqual(try command(["search", "foo", "bar"]), .search(query: "foo bar", limit: 20))
        XCTAssertEqual(try command(["search", "x", "--limit", "5"]), .search(query: "x", limit: 5))
        XCTAssertEqual(try command(["get", "12"]), .get(id: 12))
        XCTAssertEqual(try command(["add", "hello", "there"]), .add(text: "hello there"))
        XCTAssertEqual(try command(["list", "--kind", "image", "-n", "3"]), .list(limit: 3, kind: "image"))
        XCTAssertEqual(try command(["stats"]), .stats)
        XCTAssertEqual(try command(["--help"]), .help(topic: nil))
        XCTAssertEqual(try command(["help", "get"]), .help(topic: "get"))
        XCTAssertEqual(try command(["--version"]), .version)
    }

    func testOptions() throws {
        let invocation = try CLIArguments.parse(["list", "--json", "--db", "/tmp/x.sqlite"]).get()
        XCTAssertEqual(invocation.output, .json)
        XCTAssertEqual(invocation.databasePath, "/tmp/x.sqlite")
        XCTAssertEqual(try command(["add", "--", "--json"]), .add(text: "--json"))
    }

    func testErrors() {
        let cases: [([String], CLIParseError)] = [
            ([], .missingCommand),
            (["frobnicate"], .unknownCommand("frobnicate")),
            (["list", "--bogus"], .unknownOption("--bogus")),
            (["list", "--limit"], .missingValue("--limit")),
            (["list", "--limit", "0"], .invalidValue(option: "--limit", value: "0")),
            (["list", "--limit", "501"], .invalidValue(option: "--limit", value: "501")),
            (["list", "--kind", "video"], .invalidValue(option: "--kind", value: "video")),
            (["search"], .missingArgument("query")),
            (["get"], .missingArgument("id")),
            (["get", "1", "2"], .unexpectedArgument("2")),
            (["get", "-5"], .unknownOption("-5")),
            (["get", "1;rm"], .invalidValue(option: "id", value: "1;rm")),
            (["stats", "extra"], .unexpectedArgument("extra")),
            (["add", String(repeating: "a", count: CLIArguments.maxAddBytes + 1)], .textTooLarge),
        ]
        for (args, expected) in cases {
            XCTAssertEqual(CLIArguments.parse(args), .failure(expected), "\(args.map { String($0.prefix(20)) })")
        }
    }

    func testSensitiveFlagsMirrorMcpRules() {
        let data = Data(#"{"a":{"confidence":2},"b":{"confidence":0},"c":{"confidence":2,"userOverride":false},"d":{"confidence":0,"userOverride":true}}"#.utf8)
        let flags = SensitiveFlags.parse(data)
        XCTAssertTrue(flags.isSensitive(contentKey: "a"))
        XCTAssertFalse(flags.isSensitive(contentKey: "b"))
        XCTAssertFalse(flags.isSensitive(contentKey: "c"))
        XCTAssertTrue(flags.isSensitive(contentKey: "d"))
        XCTAssertFalse(flags.isSensitive(contentKey: "unknown"))
        XCTAssertTrue(SensitiveFlags.parse(Data("[1]".utf8)).isSensitive(contentKey: "anything"))
    }

    func testAddURLEncoding() {
        XCTAssertEqual(ClippyURLBuilder.addURL(text: "a&b=c d"), "clippy://add?text=a%26b%3Dc%20d")
    }

    func testCLIAddURLIsAcceptedByApp() {
        let text = "MCP and CLI writes belong to the app"
        let url = URL(string: ClippyURLBuilder.addURL(text: text))!
        XCTAssertEqual(ClippyURL.parse(url), .success(.add(text: text)))
    }
}
