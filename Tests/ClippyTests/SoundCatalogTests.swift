import XCTest
@testable import Clippy

@MainActor
final class SoundCatalogTests: XCTestCase {

    func testOptionsNonEmpty() {
        XCTAssertFalse(SoundCatalog.options.isEmpty)
    }

    func testDefaultIDIsAvailable() {
        XCTAssertTrue(SoundCatalog.contains(SoundCatalog.defaultID))
    }

    func testAllClassicSoundsArePresent() {
        // Every classic alert sound should be addressable as "system:<Name>".
        for sound in CaptureSound.allCases {
            XCTAssertTrue(
                SoundCatalog.contains("system:\(sound.rawValue)"),
                "catalog missing classic sound \(sound.rawValue)"
            )
        }
    }

    func testCatalogIncludesMoreThanClassics() {
        // The notification / UI sounds should expand the list well past the 14
        // classics on any standard macOS install.
        XCTAssertGreaterThan(SoundCatalog.options.count, CaptureSound.allCases.count)
    }

    func testResolvedIDFallsBackForUnknown() {
        XCTAssertEqual(SoundCatalog.resolvedID(for: "file:/does/not/exist.caf"), SoundCatalog.defaultID)
    }

    func testResolvedIDKeepsValidSelection() {
        XCTAssertEqual(SoundCatalog.resolvedID(for: "system:Tink"), "system:Tink")
    }

    func testResolveClassicIDReturnsSound() {
        XCTAssertNotNil(SoundPlayer.resolve(id: "system:Tink"))
    }

    func testPlayUnknownIDReturnsFalse() {
        XCTAssertFalse(SoundPlayer.play(id: "file:/nope.caf", volume: 0))
    }

    func testSystemGroupMatchesDiskAndResolves() {
        // Enumerate /System/Library/Sounds the same way the catalog does, then
        // subtract the curated Classic names (which take priority and dedupe the
        // System group). The catalog's System group must match exactly what is
        // left, and every System option must resolve to a real NSSound.
        let fm = FileManager.default
        let dir = "/System/Library/Sounds"
        let soundExtensions = ["aiff", "aif", "caf", "wav", "m4a", "mp3", "aifc"]
        let classicIDs = Set(CaptureSound.allCases.map { "system:\($0.rawValue)" })

        let expectedIDs = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { soundExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { "system:\(($0 as NSString).deletingPathExtension)" }
            .filter { !classicIDs.contains($0) }

        let systemOptions = SoundCatalog.options.filter { $0.group == "System" }
        XCTAssertEqual(
            systemOptions.count,
            expectedIDs.count,
            "System group count does not match enumerated /System/Library/Sounds"
        )
        XCTAssertEqual(Set(systemOptions.map(\.id)), Set(expectedIDs))

        for option in systemOptions {
            XCTAssertNotNil(
                SoundPlayer.resolve(id: option.id),
                "System sound \(option.id) did not resolve"
            )
        }
    }

    func testCoreAudioGroupsEnumeratedFromDisk() throws {
        // Independently walk the CoreAudio SystemSounds tree and confirm the
        // catalog surfaces every sound file once (after dedup with curated),
        // grouped into the expected category labels, each resolving to an NSSound.
        let fm = FileManager.default
        let coreAudioBase =
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds"
        let soundExtensions = ["aiff", "aif", "caf", "wav", "m4a", "mp3", "aifc"]

        // Walk the tree the same way the catalog does: collect every file: id
        // under coreAudioBase that lives in a known subfolder.
        let enumerator = fm.enumerator(atPath: coreAudioBase)
        var diskIDs = Set<String>()
        while let rel = enumerator?.nextObject() as? String {
            let name = (rel as NSString).lastPathComponent
            guard soundExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            diskIDs.insert("file:\(coreAudioBase)/\(rel)")
        }
        // The tree exists on a standard macOS install; if it does not, skip
        // rather than fail on a non-standard machine.
        try XCTSkipIf(diskIDs.isEmpty, "CoreAudio SystemSounds tree not present")

        // (b) Total count of file:<coreAudioBase> options equals files on disk,
        // proving no double counting after dedup with the curated highlights.
        let catalogCoreAudioIDs = SoundCatalog.options
            .map(\.id)
            .filter { $0.hasPrefix("file:\(coreAudioBase)/") }
        XCTAssertEqual(
            Set(catalogCoreAudioIDs).count,
            catalogCoreAudioIDs.count,
            "duplicate CoreAudio ids in catalog"
        )
        XCTAssertEqual(
            Set(catalogCoreAudioIDs),
            diskIDs,
            "catalog CoreAudio ids do not match the files on disk"
        )

        // (a) The expected category groups present on disk are represented.
        let groups = Set(
            SoundCatalog.options
                .filter { $0.id.hasPrefix("file:\(coreAudioBase)/") }
                .map(\.group)
        )
        for expected in ["Finder", "Dock", "System UI", "Telephony"] {
            XCTAssertTrue(groups.contains(expected), "missing CoreAudio group \(expected)")
        }

        // (c) Every CoreAudio option resolves to a real NSSound.
        for id in catalogCoreAudioIDs {
            XCTAssertNotNil(SoundPlayer.resolve(id: id), "CoreAudio sound \(id) did not resolve")
        }
    }
}
