import Foundation

protocol AIConversationStore {
    func load() throws -> AIArchive
    func save(_ archive: AIArchive) throws
}

/// Uses Trio's existing atomic Disk/JSONCoding persistence. Only the AI archive can be written.
final class DiskAIConversationStore: AIConversationStore {
    private let directory: Disk.Directory
    private let path: String

    init(directory: Disk.Directory = .applicationSupport, path: String = "ai/assistant-v1.json") {
        self.directory = directory
        self.path = path
    }

    func load() throws -> AIArchive {
        guard Disk.exists(path, in: directory) else { return AIArchive() }
        do {
            let archive = try Disk.retrieve(path, from: directory, as: AIArchive.self, decoder: JSONCoding.decoder)
            guard archive.version == 1 else { throw AIError.persistence }
            return archive
        } catch { throw AIError.persistence }
    }

    func save(_ archive: AIArchive) throws {
        do {
            try Disk.save(archive, to: directory, as: path, encoder: JSONCoding.encoder)
            let url = try Disk.url(for: path, in: directory)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
            var resourceURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try resourceURL.setResourceValues(values)
        } catch { throw AIError.persistence }
    }
}
