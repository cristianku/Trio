import Foundation

protocol AILogReader {
    func read(interval: DateInterval, categories: Set<String>, warningsOnly: Bool, maxBytes: Int) async throws -> [AILogEntry]
}

/// Reads only bounded file tails off the main actor; files are never changed or retained in memory.
final class FileAILogReader: AILogReader {
    private let paths: [URL]
    private let maxScanBytes: Int

    init(paths: [URL], maxScanBytes: Int = 512000) {
        self.paths = paths
        self.maxScanBytes = maxScanBytes
    }

    func read(interval: DateInterval, categories: Set<String>, warningsOnly: Bool, maxBytes: Int) async throws -> [AILogEntry] {
        guard maxBytes > 0 else { return [] }
        let paths = paths
        let scanLimit = maxScanBytes
        let task = Task.detached(priority: .utility) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            var entries: [AILogEntry] = []
            for path in paths {
                try Task.checkCancellation()
                guard FileManager.default.fileExists(atPath: path.path) else { continue }
                let handle = try FileHandle(forReadingFrom: path)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                let offset = size > UInt64(scanLimit) ? size - UInt64(scanLimit) : 0
                try handle.seek(toOffset: offset)
                let data = try handle.read(upToCount: scanLimit) ?? Data()
                var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
                if offset > 0, !lines.isEmpty { lines.removeFirst() }
                // A concurrent writer may not have completed the final line yet.
                if data.last != 10, !lines.isEmpty { lines.removeLast() }
                for line in lines.reversed() {
                    try Task.checkCancellation()
                    guard let space = line.firstIndex(of: " "), let date = formatter.date(from: String(line[..<space])),
                          date >= interval.start, date <= interval.end,
                          let open = line.firstIndex(of: "["), let close = line[open...].firstIndex(of: "]") else { continue }
                    let category = String(line[line.index(after: open)..<close])
                    guard categories.isEmpty || categories.contains(category) else { continue }
                    guard !warningsOnly || line.contains(" - WARN:") || line.contains(" - ERR:") else { continue }
                    // Keep complete lines; cutting a secret in half would defeat redaction.
                    guard line.utf8.count <= maxBytes else { continue }
                    entries.append(.init(date: date, category: category, message: line))
                }
            }
            var bytes = 0
            return entries.sorted { $0.date > $1.date }.filter {
                let size = $0.message.utf8.count
                guard bytes + size <= maxBytes else { return false }
                bytes += size
                return true
            }
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
