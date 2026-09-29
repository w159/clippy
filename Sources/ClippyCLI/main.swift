import ClippyCLICore
import Foundation

/// Runtime failures with an exit code.
enum CLIError: Error {
    case runtime(String)
    case notFound(String)
    case withheld
}

let cliVersion = "1.0"

/// Writes to stderr.
func fail(_ message: String) {
    FileHandle.standardError.write(Data(("clippy: " + message + "\n").utf8))
}

/// Prints `object` as pretty, sorted JSON.
func printJSON(_ object: Any) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    print(String(decoding: data, as: UTF8.self))
}

/// One clip as a JSON-safe dictionary. Text is included only for text clips; sensitive clips never reach here.
func summary(_ clip: CLIClip, includeText: Bool) -> [String: Any] {
    var dict: [String: Any] = [
        "id": clip.id, "kind": clip.kind,
        "createdAt": ISO8601DateFormatter().string(from: clip.createdAt),
    ]
    if let app = clip.sourceApp { dict["sourceApp"] = app }
    if let title = clip.title { dict["title"] = title }
    if clip.kind == "text" { dict["text"] = includeText ? clip.text : String(clip.text.prefix(120)) }
    if let path = clip.filePath { dict["path"] = path }
    if let size = clip.byteSize { dict["bytes"] = size }
    return dict
}

func plainLine(_ clip: CLIClip) -> String {
    let body = clip.kind == "text"
        ? String(clip.text.prefix(100)).replacingOccurrences(of: "\n", with: " ")
        : "[\(clip.kind)] \(clip.filePath ?? clip.title ?? "")"
    return "\(clip.id)\t\(ISO8601DateFormatter().string(from: clip.createdAt))\t\(body)"
}

func runAdd(_ text: String, mode: CLIOutputMode) throws {
    let url = ClippyURLBuilder.addURL(text: text)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", url]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CLIError.runtime("could not hand the clip to Clippy (is it installed?)") }
    if mode == .json { printJSON(["status": "sent", "bytes": text.utf8.count]) }
    else { print("Sent to Clippy (\(text.utf8.count) bytes). The app may ask you to allow it.") }
}

func execute(_ invocation: CLIInvocation) throws {
    let mode = invocation.output
    switch invocation.command {
    case .help: print(CLIArguments.usage)
    case .version: print("clippy \(cliVersion)")
    case .add(let text): try runAdd(text, mode: mode)
    case .search(let query, let limit):
        let clips = try ClipReader(databasePath: invocation.databasePath).search(query, limit: limit)
        if mode == .json { printJSON(clips.map { summary($0, includeText: false) }) } else { clips.forEach { print(plainLine($0)) } }
    case .list(let limit, let kind):
        let clips = try ClipReader(databasePath: invocation.databasePath).list(limit: limit, kind: kind)
        if mode == .json { printJSON(clips.map { summary($0, includeText: false) }) } else { clips.forEach { print(plainLine($0)) } }
    case .get(let identifier):
        let reader = try ClipReader(databasePath: invocation.databasePath)
        guard let clip = try reader.clip(id: identifier) else { throw CLIError.notFound("no clip with id \(identifier)") }
        if reader.flags.isSensitive(contentKey: clip.contentKey) { throw CLIError.withheld }
        if mode == .json { printJSON(summary(clip, includeText: true)) }
        else if clip.kind == "text" { print(clip.text, terminator: clip.text.hasSuffix("\n") ? "" : "\n") }
        else { print(plainLine(clip)) }
    case .stats:
        let stats = try ClipReader(databasePath: invocation.databasePath).stats()
        if mode == .json { printJSON(["total": stats.total, "byKind": stats.byKind, "sensitiveWithheld": stats.sensitive]) }
        else {
            print("total: \(stats.total)")
            for (kind, count) in stats.byKind.sorted(by: { $0.key < $1.key }) { print("\(kind): \(count)") }
            print("sensitive (withheld): \(stats.sensitive)")
        }
    }
}

switch CLIArguments.parse(Array(CommandLine.arguments.dropFirst())) {
case .failure(let error):
    fail("\(CLIArguments.describe(error))\nTry 'clippy --help'.")
    exit(2)
case .success(let invocation):
    do {
        try execute(invocation)
    } catch CLIError.notFound(let message) {
        fail(message); exit(3)
    } catch CLIError.withheld {
        fail("clip is marked sensitive and is withheld"); exit(4)
    } catch CLIError.runtime(let message) {
        fail(message); exit(1)
    } catch {
        fail("\(error)"); exit(1)
    }
}
