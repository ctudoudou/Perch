import Foundation

/// Reads the tail of a JSONL file without loading the whole thing. Session logs
/// grow to megabytes; the notch only ever needs the last handful of records.
enum JSONLReader {
    /// Read up to `maxBytes` from the end of the file and return complete JSON
    /// lines found there, oldest first. The first (likely partial) line is dropped
    /// unless the read covered the whole file.
    static func tailLines(of url: URL, maxBytes: Int = 256 * 1024) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return [] }
        let readSize = min(UInt64(maxBytes), size)
        let coversWholeFile = readSize == size
        try? handle.seek(toOffset: size - readSize)

        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }

        var lines = data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
        if !coversWholeFile, !lines.isEmpty {
            lines.removeFirst()
        }
        return lines
    }

    /// Decode tail lines into loosely-typed dictionaries, skipping malformed ones.
    static func tailObjects(of url: URL, maxBytes: Int = 256 * 1024) -> [[String: Any]] {
        tailLines(of: url, maxBytes: maxBytes).compactMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
    }
}

extension [String: Any] {
    func string(_ key: String) -> String? { self[key] as? String }
    func int(_ key: String) -> Int? {
        if let i = self[key] as? Int { return i }
        if let d = self[key] as? Double { return Int(d) }
        return nil
    }
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func array(_ key: String) -> [Any]? { self[key] as? [Any] }
}

enum Timestamps {
    /// Session logs use fractional-second ISO 8601; some records omit the fraction.
    static func parse(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatters = Self.threadLocal
        return formatters.withFraction.date(from: raw) ?? formatters.plain.date(from: raw)
    }

    /// `ISO8601DateFormatter` is not `Sendable` and allocating one per record is
    /// measurably slow on large logs, so each parsing thread keeps its own pair.
    private final class Formatters {
        let withFraction: ISO8601DateFormatter
        let plain = ISO8601DateFormatter()

        init() {
            withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        }
    }

    private static let key = "perch.timestamp.formatters"

    private static var threadLocal: Formatters {
        let storage = Thread.current.threadDictionary
        if let existing = storage[key] as? Formatters { return existing }
        let created = Formatters()
        storage[key] = created
        return created
    }
}

extension String {
    /// Collapse whitespace and clip for display in a narrow panel.
    func condensed(to limit: Int) -> String {
        let flat = split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return flat.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension JSONLReader {
    /// Decode only the first line of a JSONL file. Codex writes its
    /// `session_meta` record first and it can be hundreds of kilobytes (it
    /// embeds the full system prompt), so it must be read from the head rather
    /// than hoping it lands inside the tail window.
    static func firstObject(of url: URL, maxBytes: Int = 2 * 1024 * 1024) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var buffer = Data()
        let newline = UInt8(ascii: "\n")

        // Read in chunks until the first newline, so a small first record does
        // not cost a multi-megabyte read.
        while buffer.count < maxBytes {
            guard
                let chunk = try? handle.read(upToCount: 64 * 1024),
                !chunk.isEmpty
            else { break }
            buffer.append(chunk)
            if let index = buffer.firstIndex(of: newline) {
                let line = buffer[buffer.startIndex ..< index]
                return try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            }
        }
        return nil
    }
}

extension JSONLReader {
    /// Scan the first `limit` records for one matching `predicate`.
    ///
    /// Used for fields written near the start of a long log, which the tail
    /// window never reaches.
    static func firstMatch(
        of url: URL,
        limit: Int,
        maxBytes: Int = 4 * 1024 * 1024,
        where predicate: ([String: Any]) -> Bool
    ) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var buffer = Data()
        var scanned = 0
        var consumed = 0
        let newline = UInt8(ascii: "\n")

        // Bounded on records, bytes AND on reaching EOF. A single record can be
        // larger than one chunk (Codex embeds the full system prompt), so the
        // outer loop must keep reading rather than assuming a chunk holds a line.
        while scanned < limit, consumed < maxBytes {
            guard
                let chunk = try? handle.read(upToCount: 128 * 1024),
                !chunk.isEmpty
            else { break }
            consumed += chunk.count
            buffer.append(chunk)

            while scanned < limit, let index = buffer.firstIndex(of: newline) {
                let line = Data(buffer[buffer.startIndex ..< index])
                buffer.removeSubrange(buffer.startIndex ... index)
                scanned += 1
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   predicate(object) {
                    return object
                }
            }
        }
        return nil
    }
}

extension JSONLReader {
    /// Stream every record in a JSONL file, oldest first, without holding the
    /// whole file in memory.
    ///
    /// Cumulative token totals require every record: Claude Code writes usage
    /// per request, and a session log reaches tens of megabytes, so a tail read
    /// sees only the last percent or two of the spend.
    static func forEachObject(
        of url: URL,
        from offset: UInt64 = 0,
        _ body: ([String: Any]) -> Void
    ) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd(), size > offset else { return offset }
        try? handle.seek(toOffset: offset)

        var buffer = Data()
        var consumed = offset
        let newline = UInt8(ascii: "\n")

        while true {
            guard
                let chunk = try? handle.read(upToCount: 1024 * 1024),
                !chunk.isEmpty
            else { break }
            buffer.append(chunk)

            while let index = buffer.firstIndex(of: newline) {
                let line = Data(buffer[buffer.startIndex ..< index])
                let lineLength = buffer.distance(from: buffer.startIndex, to: index) + 1
                buffer.removeSubrange(buffer.startIndex ... index)
                consumed += UInt64(lineLength)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    body(object)
                }
            }
        }
        // A file whose last line has no terminating newline would otherwise
        // lose that record entirely. Emit it, but do not advance the offset
        // past it: if it turns out to be a partial write, the next pass
        // re-reads it once the rest arrives.
        if !buffer.isEmpty,
           let object = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any] {
            body(object)
        }
        return consumed
    }
}
