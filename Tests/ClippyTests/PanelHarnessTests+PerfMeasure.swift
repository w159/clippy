import AppKit
import SwiftUI
import XCTest
@testable import Clippy

/// Panel timing and idle cost, printed as `PERFMEASURE <key> <value> <unit>` lines. Same gate as the rest of the
/// harness (`CLIPPY_UI_HARNESS=1`). Bounds are generous safety nets; the printed numbers are the evidence.
extension PanelHarnessTests {
    private static let perfClipCount = 5_000

    private func perfReport(_ key: String, _ value: Double, _ unit: String) {
        print("PERFMEASURE \(key) \(String(format: "%.1f", value)) \(unit)")
    }

    private func perfMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let parts = (ContinuousClock.now - start).components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    private func perfSeededStore() throws -> ClipStore {
        let db = try makeTestDatabase(self)
        let now = Date()
        try db.dbQueue.write { conn in
            for index in 0..<Self.perfClipCount {
                var clip = makeTextClip("perf clip number \(index) invoice meeting swift",
                                        createdAt: now.addingTimeInterval(-Double(index)))
                try clip.insert(conn)
            }
        }
        return ClipStore(database: db, pasteboard: NSPasteboard(name: NSPasteboard.Name("ClippyPerf-\(UUID())")))
    }

    private func perfPanelView(_ store: ClipStore) -> some View {
        ClipListView(
            store: store,
            onPaste: { _, _ in }, onPasteMany: { _, _, _ in }, onPasteFile: { _, _ in }, onPrimary: { _ in },
            onSendKeystrokes: { _ in }, onEdit: { _ in }, onClose: {}, onOpenSettings: {}
        ).clippyDesignSystem()
    }

    /// Process CPU time (user + system) in seconds.
    private func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Resident set size in megabytes from `mach_task_basic_info`.
    private func residentMegabytes() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    /// Starts `/usr/bin/sample` on this process (6 s, 1 ms interval). Never fails the test; returns nil when unavailable.
    private func perfStartSampler(outputPath: String) -> Process? {
        try? FileManager.default.removeItem(atPath: outputPath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(getpid()), "6", "1", "-mayDie", "-file", outputPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return process
        } catch {
            print("SAMPLE unavailable: \(error)")
            return nil
        }
    }

    /// Waits (at most 15 s) for the sampler, then prints the main thread call tree and the top-of-stack summary.
    private func perfFinishSampler(_ process: Process?, outputPath: String) {
        guard let process else { return }
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            print("SAMPLE unavailable: sample did not exit within 15 s")
            return
        }
        guard let text = try? String(contentsOfFile: outputPath, encoding: .utf8) else {
            print("SAMPLE unavailable: no output (exit status \(process.terminationStatus))")
            return
        }
        let lines = text.components(separatedBy: "\n")

        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        func sampleCount(_ line: String) -> Int {
            let digits = line.drop { !$0.isNumber }.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
        func isTerminator(_ line: String) -> Bool {
            line.contains("Total number in stack") || line.contains("Sort by top of stack")
        }

        guard let graph = lines.firstIndex(where: { $0.hasPrefix("Call graph:") }),
              let mainStart = lines[graph...].firstIndex(where: {
                  $0.contains("Thread_") && ($0.contains("com.apple.main-thread") || $0.contains("DispatchQueue_1"))
              })
        else {
            print("SAMPLE unavailable: main thread block not found")
            return
        }
        let mainIndent = indent(lines[mainStart])
        var printed = 0
        var cursor = mainStart
        while cursor < lines.count, printed < 400 {
            let line = lines[cursor]
            if cursor > mainStart,
               isTerminator(line) || (line.contains("Thread_") && indent(line) == mainIndent) { break }
            if cursor == mainStart || sampleCount(line) >= 8 {
                print("SAMPLE \(line)")
                printed += 1
            }
            cursor += 1
        }

        if let top = lines.firstIndex(where: { $0.contains("Sort by top of stack, same collapsed") }) {
            for line in lines[(top + 1)...].prefix(40) { print("SAMPLETOP \(line)") }
        }
    }

    func testPerfPanelOpenAndScroll() throws {
        store = try perfSeededStore()
        pump(until: "clips loaded") { !self.store.clips.isEmpty }

        LayoutProbe.shared.reset()
        let start = ContinuousClock.now
        show(perfPanelView(store), size: Self.defaultPanelSize, appearance: .aqua, panelChrome: true)
        pump(until: "first row laid out") {
            ["row.comfortable", "row.compact", "row.tile"].contains { LayoutProbe.shared.frames[$0] != nil }
        }
        let opened = perfMilliseconds(since: start)
        perfReport("panel.open.ms", opened, "ms")
        XCTAssertLessThan(opened, 10_000)

        // Walk the keyboard cursor to the last row: the list scrolls with it, one step per redraw.
        pump(until: "search field focused") { self.window.firstResponder is NSTextView }
        let rows = store.clips.count
        let samplePath = (NSTemporaryDirectory() as NSString).appendingPathComponent("clippy-scroll-sample.txt")
        let sampler = perfStartSampler(outputPath: samplePath)
        let scrollStart = ContinuousClock.now
        for _ in 0..<max(0, rows - 1) {
            press(.downArrow)
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        perfFinishSampler(sampler, outputPath: samplePath)
        let scrolled = perfMilliseconds(since: scrollStart)
        // `press` itself pumps the run loop for 10 ms (KeyboardHarness.swift:62) and the loop adds 1 ms, so
        // subtract that fixed 11 ms per press to leave the app's own cost.
        let presses = max(1, rows - 1)
        let perPress = max(0, scrolled / Double(presses) - 11)
        perfReport("scroll.ms", scrolled, "ms")
        perfReport("scroll.perpress.ms", perPress, "ms")
        print("PERFMEASURE scroll.rows \(rows) rows")
        XCTAssertLessThan(perPress, 100, "one Down Arrow must cost well under 100 ms of main-thread work")
        XCTAssertLessThan(scrolled, 120_000)
    }

    func testPerfIdleCostWithPanelHidden() throws {
        store = try perfSeededStore()
        pump(until: "clips loaded") { !self.store.clips.isEmpty }
        let db = try makeTestDatabase(self)
        let monitor = ClipboardMonitor(database: db, pasteboard: NSPasteboard(name: NSPasteboard.Name("ClippyPerfIdle-\(UUID())")))
        monitor.start()
        window?.orderOut(nil)
        pump(seconds: 1)

        let cpuBefore = processCPUSeconds()
        let wallStart = ContinuousClock.now
        pump(seconds: 5)
        let wall = perfMilliseconds(since: wallStart) / 1000
        let percent = (processCPUSeconds() - cpuBefore) / max(wall, 0.001) * 100
        perfReport("idle.cpu.percent", percent, "percent")
        perfReport("idle.rss.mb", residentMegabytes(), "MB")
        XCTAssertLessThan(percent, 50, "an idle hidden panel with the monitor polling must stay quiet")
    }
}
