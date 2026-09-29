import Foundation

/// Stable (process-independent) 64-bit FNV-1a hash. `String.hashValue` is
/// randomized per launch, so it cannot key anything persisted.
enum StableHash {
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

/// Persistent, bounded LRU cache of clip embeddings (ROADMAP INT-02). Lives in a
/// single binary file, NOT the clip database.
///
/// File layout, all little-endian:
/// - header (20 bytes): magic "CLEM", format version u32, embedding revision i32,
///   maximum dimension u32, record count u32
/// - per record, least recently used first: clip id i64, text hash u64,
///   language length u8 + UTF-8 bytes, dimension u32, `dimension` x Float32 bit patterns
///
/// Records are keyed by clip id and validated by the stable text hash; the
/// language space is stored with each vector. Loading is lazy and corruption
/// tolerant: any malformed, truncated, oversized, or wrong-revision file
/// yields an empty cache. Saves are debounced, run off the calling thread,
/// and are atomic (temp file + rename). Vectors derive from clip text, so the
/// file is created with 0600 permissions and never leaves the machine.
final class EmbeddingCache {
    /// One cached vector.
    struct Entry {
        var textHash: UInt64
        var language: String
        var vector: [Float]
        var tick: UInt64
    }

    /// Default location: `~/Library/Caches/Clippy/embeddings-v1.bin`.
    static var defaultFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clippy", isDirectory: true)
            .appendingPathComponent("embeddings-v1.bin")
    }

    private static let magic: [UInt8] = Array("CLEM".utf8)
    private static let formatVersion: UInt32 = 1
    private static let headerSize = 20
    private static let maxDimension: UInt32 = 8192

    /// `nil` keeps the cache purely in memory (tests, previews).
    private let fileURL: URL?
    private let capacity: Int
    private let maxFileBytes: Int
    private let revision: Int
    private let saveDelay: TimeInterval
    private let saveQueue = DispatchQueue(label: "com.bytesavvy.clippy.embedding-cache", qos: .utility)

    private let lock = NSLock()
    private var entries: [Int64: Entry] = [:]
    private var tick: UInt64 = 0
    private var loaded = false
    private var dirty = false
    private var pendingSave: DispatchWorkItem?

    init(
        fileURL: URL?, revision: Int, capacity: Int = SuggestionTuning.cacheCapacity,
        maxFileBytes: Int = 32 * 1024 * 1024, saveDelay: TimeInterval = 2
    ) {
        self.fileURL = fileURL
        self.revision = revision
        self.capacity = max(1, capacity)
        self.maxFileBytes = max(Self.headerSize, maxFileBytes)
        self.saveDelay = saveDelay
    }

    // MARK: Public API

    /// Number of cached vectors (loads the file on first use).
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return entries.count
    }

    /// The cached vector for `id` when it was computed from text with `textHash`.
    func lookup(id: Int64, textHash: UInt64) -> LanguageVector? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        guard var entry = entries[id], entry.textHash == textHash else { return nil }
        tick &+= 1
        entry.tick = tick
        entries[id] = entry
        return LanguageVector(vector: entry.vector, language: entry.language)
    }

    /// Stores (or replaces) a vector, evicting least recently used entries
    /// beyond capacity, and schedules a debounced save.
    func store(id: Int64, textHash: UInt64, value: LanguageVector) {
        lock.lock()
        loadIfNeeded()
        tick &+= 1
        entries[id] = Entry(
            textHash: textHash, language: value.language, vector: value.vector, tick: tick)
        if entries.count > capacity {
            let keep = capacity * 9 / 10
            let victims = entries.sorted { $0.value.tick < $1.value.tick }.prefix(entries.count - keep)
            for (key, _) in victims { entries.removeValue(forKey: key) }
        }
        dirty = true
        scheduleSaveLocked()
        lock.unlock()
    }

    /// Writes any unsaved changes now and waits for completion.
    func flush() {
        lock.lock()
        pendingSave?.cancel()
        pendingSave = nil
        lock.unlock()
        saveQueue.sync { writeIfDirty() }
    }

    /// Drops every vector in memory AND deletes the file.
    func clear() {
        lock.lock()
        pendingSave?.cancel()
        pendingSave = nil
        entries.removeAll()
        loaded = true
        dirty = false
        lock.unlock()
        guard let fileURL else { return }
        saveQueue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }

    // MARK: Persistence

    /// Caller holds `lock`.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = readFile(fileURL) else { return }
        for record in Self.decode(data, revision: revision) {
            tick &+= 1
            entries[record.id] = Entry(
                textHash: record.hash, language: record.language, vector: record.vector, tick: tick)
        }
        // Keep the newest `capacity` records if the file holds more.
        if entries.count > capacity {
            let victims = entries.sorted { $0.value.tick < $1.value.tick }.prefix(entries.count - capacity)
            for (key, _) in victims { entries.removeValue(forKey: key) }
        }
    }

    private func readFile(_ url: URL) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber, size.intValue <= maxFileBytes,
            size.intValue >= Self.headerSize
        else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Caller holds `lock`.
    private func scheduleSaveLocked() {
        guard fileURL != nil else { return }
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writeIfDirty() }
        pendingSave = item
        saveQueue.asyncAfter(deadline: .now() + saveDelay, execute: item)
    }

    /// Runs on `saveQueue`.
    private func writeIfDirty() {
        guard let fileURL else { return }
        lock.lock()
        guard dirty else { lock.unlock(); return }
        dirty = false
        let snapshot = entries.sorted { $0.value.tick < $1.value.tick }
        lock.unlock()

        var records = snapshot.map { (id: $0.key, entry: $0.value) }
        // Size cap: drop least recently used records until the file fits.
        var size = Self.headerSize + records.reduce(0) { $0 + Self.recordSize($1.entry) }
        var drop = 0
        while size > maxFileBytes, drop < records.count {
            size -= Self.recordSize(records[drop].entry)
            drop += 1
        }
        records.removeFirst(drop)

        let data = Self.encode(records, revision: revision)
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            lock.lock(); dirty = true; lock.unlock()
            ClippyLog.warning(
                "embedding cache save failed: \(error.localizedDescription)",
                category: ClippyLog.storage)
        }
    }

    // MARK: Binary format

    private struct Record {
        var id: Int64
        var hash: UInt64
        var language: String
        var vector: [Float]
    }

    private static func recordSize(_ entry: Entry) -> Int {
        8 + 8 + 1 + entry.language.utf8.count + 4 + entry.vector.count * 4
    }

    private static func encode(_ records: [(id: Int64, entry: Entry)], revision: Int) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(headerSize + records.reduce(0) { $0 + recordSize($1.entry) })
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        let dimension = records.map { $0.entry.vector.count }.max() ?? 0
        out.append(contentsOf: magic)
        put(formatVersion)
        put(Int32(truncatingIfNeeded: revision))
        put(UInt32(dimension))
        put(UInt32(records.count))
        for (id, entry) in records {
            let language = Array(entry.language.utf8.prefix(255))
            put(id)
            put(entry.textHash)
            put(UInt8(language.count))
            out.append(contentsOf: language)
            put(UInt32(entry.vector.count))
            for value in entry.vector { put(value.bitPattern) }
        }
        return Data(out)
    }

    /// Bounds-checked decode; any inconsistency returns no records.
    private static func decode(_ data: Data, revision: Int) -> [Record] {
        var offset = 0
        func take<T: FixedWidthInteger>(_ type: T.Type) -> T? {
            let width = MemoryLayout<T>.size
            guard offset + width <= data.count else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
            offset += width
            return T(littleEndian: value)
        }
        guard data.count >= headerSize, Array(data.prefix(4)) == magic else { return [] }
        offset = 4
        guard take(UInt32.self) == formatVersion,
            let storedRevision = take(Int32.self), storedRevision == Int32(truncatingIfNeeded: revision),
            let dimension = take(UInt32.self), dimension <= maxDimension,
            let count = take(UInt32.self)
        else { return [] }
        // Every record needs at least 21 bytes; reject impossible counts before allocating.
        guard Int(count) <= (data.count - headerSize) / 21 else { return [] }

        var records: [Record] = []
        records.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let id = take(Int64.self), let hash = take(UInt64.self),
                let languageLength = take(UInt8.self),
                offset + Int(languageLength) <= data.count
            else { return [] }
            let languageBytes = data.subdata(in: offset..<(offset + Int(languageLength)))
            offset += Int(languageLength)
            guard let language = String(data: languageBytes, encoding: .utf8),
                let dim = take(UInt32.self), dim <= dimension,
                offset + Int(dim) * 4 <= data.count
            else { return [] }
            var vector = [Float](repeating: 0, count: Int(dim))
            for index in 0..<Int(dim) {
                guard let bits = take(UInt32.self) else { return [] }
                vector[index] = Float(bitPattern: bits)
            }
            records.append(Record(id: id, hash: hash, language: language, vector: vector))
        }
        return offset == data.count ? records : []
    }
}
