import Foundation
import PerchKit

/// Accumulates per-file token totals across polls.
///
/// Cumulative usage needs every record in a log, but a session log reaches tens
/// of megabytes and Perch polls every two seconds. Re-reading whole files at
/// that rate is wasteful, so each file is read once and then only its newly
/// appended bytes are parsed.
final class UsageLedger: @unchecked Sendable {
    private struct Entry {
        var offset: UInt64
        var usage: TokenUsage
        /// Responses already counted, so a repeated record cannot be counted
        /// twice. Claude Code writes one `assistant` record per content block
        /// and every copy repeats the *whole* response's usage — summing them
        /// naively inflated this machine's totals by 1.84×.
        var counted: Set<String> = []
    }

    private var entries: [URL: Entry] = [:]
    private let lock = NSLock()

    /// Fold any newly appended records into the running total for `url`.
    ///
    /// `accumulate` is called for each new record and mutates the file's total.
    /// Returns the total after the update.
    /// - Parameter identify: a stable id for the record's underlying API
    ///   response. Records sharing an id are counted once. Returning `nil`
    ///   counts the record unconditionally.
    func update(
        _ url: URL,
        identify: ([String: Any]) -> String? = { _ in nil },
        accumulate: (inout TokenUsage, [String: Any]) -> Void
    ) -> TokenUsage {
        lock.lock()
        var entry = entries[url] ?? Entry(offset: 0, usage: TokenUsage())
        lock.unlock()

        // A truncated or replaced file must be re-read from the start rather
        // than resuming past its new end.
        if let size = try? FileManager.default
            .attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? UInt64,
            size < entry.offset {
            entry = Entry(offset: 0, usage: TokenUsage())
        }

        var usage = entry.usage
        var counted = entry.counted
        let newOffset = JSONLReader.forEachObject(of: url, from: entry.offset) { record in
            if let id = identify(record) {
                guard counted.insert(id).inserted else { return }
            }
            accumulate(&usage, record)
        }

        let updated = Entry(offset: newOffset, usage: usage, counted: counted)
        lock.lock()
        entries[url] = updated
        lock.unlock()
        return usage
    }

    /// Drop files that no longer exist, so the ledger does not grow forever.
    func prune(keeping live: Set<URL>) {
        lock.lock()
        entries = entries.filter { live.contains($0.key) }
        lock.unlock()
    }
}
