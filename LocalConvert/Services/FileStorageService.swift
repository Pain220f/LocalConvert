import Foundation

/// Owns every byte the app writes on its own: an isolated scratch directory inside the sandbox
/// container's temporary folder, exact byte measurement and atomic export to user-chosen locations.
struct FileStorageService: Sendable {
    /// `<container>/tmp/LocalConvert`. Purged at launch and on quit.
    static let rootDirectory: URL = FileManager.default.temporaryDirectory
        .appending(path: "LocalConvert", directoryHint: .isDirectory)

    let sessionDirectory: URL

    init() {
        sessionDirectory = Self.rootDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    /// Fresh, empty directory for one job. Previous output for the same job is discarded.
    func makeJobDirectory(for id: UUID) throws -> URL {
        let directory = sessionDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func discardJobDirectory(for id: UUID) {
        try? FileManager.default.removeItem(at: sessionDirectory.appending(path: id.uuidString, directoryHint: .isDirectory))
    }

    static func purgeAll() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    // MARK: - Measurement

    /// Exact logical size in bytes. Directories are summed recursively.
    static func byteCount(at url: URL) throws -> Int64 {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values.isDirectory == true else { return Int64(values.fileSize ?? 0) }

        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        for case let file as URL in enumerator {
            let fileValues = try file.resourceValues(forKeys: Set(keys))
            if fileValues.isRegularFile == true { total += Int64(fileValues.fileSize ?? 0) }
        }
        return total
    }

    static func fileCount(at url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var count = 0
        for case let file as URL in enumerator where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            count += 1
        }
        return count
    }

    // MARK: - Naming

    /// `name.ext`, then `name 2.ext`, `name 3.ext`, … until free. `pathExtension == nil` names a folder.
    static func uniqueURL(in directory: URL, baseName: String, pathExtension: String?) -> URL {
        let fileManager = FileManager.default
        func candidate(_ index: Int) -> URL {
            let name = index == 1 ? baseName : "\(baseName) \(index)"
            let url = directory.appending(path: name, directoryHint: pathExtension == nil ? .isDirectory : .notDirectory)
            return pathExtension.map { url.appendingPathExtension($0) } ?? url
        }
        var index = 1
        while fileManager.fileExists(atPath: candidate(index).path) { index += 1 }
        return candidate(index)
    }

    // MARK: - Export

    /// Copies a finished output to a user-chosen destination.
    ///
    /// When the destination exists it is replaced atomically with `replaceItemAt`, so a failure never
    /// leaves a half-written file in place of the user's original. New destinations are copied and
    /// removed again if the copy fails.
    func export(_ item: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            let staging = sessionDirectory
                .appending(path: "staging-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: staging) }
            let stagedItem = staging.appending(path: item.lastPathComponent)
            try fileManager.copyItem(at: item, to: stagedItem)
            _ = try fileManager.replaceItemAt(destination, withItemAt: stagedItem)
        } else {
            do {
                try fileManager.copyItem(at: item, to: destination)
            } catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
        }
    }
}
