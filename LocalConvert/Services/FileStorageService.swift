import Darwin
import Foundation
import os

/// Owns every byte the app writes on its own: an isolated scratch directory inside the sandbox
/// container's temporary folder, exact byte measurement and atomic export to user-chosen locations.
struct FileStorageService: Sendable {
    /// `<container>/tmp/LocalConvert`. Holds one folder per session (one per queue manager).
    static let rootDirectory: URL = FileManager.default.temporaryDirectory
        .appending(path: "LocalConvert", directoryHint: .isDirectory)
    static let lockFileName = ".session.lock"

    /// Session folders created by this process, removed at quit.
    private static let ownSessions = OSAllocatedUnfairLock<[URL]>(initialState: [])

    let sessionDirectory: URL
    /// Held for the lifetime of the session so other instances never purge it.
    private let lock: SessionLock

    init() {
        sessionDirectory = Self.rootDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        lock = SessionLock(url: sessionDirectory.appending(path: Self.lockFileName))
        let directory = sessionDirectory
        Self.ownSessions.withLock { $0.append(directory) }
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

    /// Launch-time cleanup: removes session folders left by instances that are no longer running.
    /// A folder whose lock is still held belongs to a live instance (another window of the app,
    /// an Xcode test host…) and is left alone.
    static func purgeStaleSessions() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil) else { return }
        let own = ownSessions.withLock { Set($0.map(\.standardizedFileURL)) }
        for entry in entries where !own.contains(entry.standardizedFileURL) {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDirectory || !SessionLock.isHeld(at: entry.appending(path: lockFileName)) {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    /// Quit-time cleanup: removes only this process's sessions.
    static func removeOwnSessions() {
        let sessions = ownSessions.withLock { sessions in
            defer { sessions.removeAll() }
            return sessions
        }
        for session in sessions { try? FileManager.default.removeItem(at: session) }
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

/// An exclusive `flock` held on a lock file for as long as this object lives.
final class SessionLock: Sendable {
    private let descriptor: Int32

    init(url: URL) {
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            descriptor = -1
        } else {
            descriptor = fd
        }
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }   // closing releases the flock
    }

    /// Whether some live process holds the lock at `url`. A missing lock file counts as not held.
    static func isHeld(at url: URL) -> Bool {
        let fd = open(url.path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN)
        return false
    }
}
