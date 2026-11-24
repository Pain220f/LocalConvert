import Foundation
import Observation
import UniformTypeIdentifiers

/// Owns the job list and runs conversions with bounded concurrency.
///
/// UI state lives on the main actor; the heavy lifting happens inside the engines' nonisolated
/// `async` methods, which run on the cooperative thread pool via a `TaskGroup`.
@MainActor
@Observable
final class ConversionQueueManager {
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    private(set) var jobs: [ConversionJob] = []
    var stripMetadata = false
    var notice: Notice?

    let registry: EngineRegistry
    let maxConcurrentJobs: Int
    private let storage = FileStorageService()
    private var worker: Task<Void, Never>?

    init(registry: EngineRegistry = .standard,
         maxConcurrentJobs: Int = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))) {
        self.registry = registry
        self.maxConcurrentJobs = maxConcurrentJobs
    }

    // MARK: - Derived state

    var isRunning: Bool { worker != nil }
    var canConvert: Bool { jobs.contains { $0.status.canStart } }
    var completedJobs: [ConversionJob] { jobs.filter { $0.output != nil } }
    var imageJobs: [ConversionJob] { jobs.filter { $0.category == .image && !$0.isCombined } }

    var totals: SizeDelta? {
        let done = completedJobs
        guard !done.isEmpty else { return nil }
        return SizeDelta(
            before: done.reduce(0) { $0 + $1.originalBytes },
            after: done.reduce(0) { $0 + ($1.output?.byteCount ?? 0) }
        )
    }

    // MARK: - Adding & removing

    func add(_ urls: [URL]) {
        var rejected: [String] = []
        var added = 0
        for url in Self.expand(urls) {
            guard !jobs.contains(where: { $0.sourceURLs == [url] }) else { continue }
            guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType,
                  let category = MediaCategory(type: type)
            else { rejected.append(url.lastPathComponent); continue }
            let targets = registry.targets(for: type)
            guard !targets.isEmpty else { rejected.append(url.lastPathComponent); continue }
            let bytes = (try? FileStorageService.byteCount(at: url)) ?? 0
            jobs.append(ConversionJob(sourceURLs: [url], sourceType: type, category: category,
                                      originalBytes: bytes, availableTargets: targets))
            added += 1
        }
        if !rejected.isEmpty {
            let list = rejected.prefix(8).joined(separator: ", ") + (rejected.count > 8 ? " …" : "")
            notice = Notice(title: "Some files were skipped",
                            message: "\(rejected.count) file(s) are not a supported image, audio, video or PDF type: \(list)")
        }
    }

    func addFromOpenPanel() {
        add(PanelService.chooseInputFiles())
    }

    /// Adds a job that compiles every image in the list into one PDF, in list order.
    func combineImagesIntoPDF() {
        let images = imageJobs
        guard !images.isEmpty else { return }
        let urls = images.map(\.primaryURL)
        let allJPEG = images.allSatisfy { $0.sourceType.conforms(to: .jpeg) }
        jobs.append(ConversionJob(
            sourceURLs: urls,
            sourceType: allJPEG ? .jpeg : .image,
            category: .image,
            originalBytes: images.reduce(0) { $0 + $1.originalBytes },
            availableTargets: [.pdf]
        ))
    }

    func remove(_ job: ConversionJob) {
        guard !job.isBusy else { return }
        storage.discardJobDirectory(for: job.id)
        jobs.removeAll { $0.id == job.id }
    }

    func clear() {
        cancelAll()
        for job in jobs { storage.discardJobDirectory(for: job.id) }
        jobs.removeAll()
    }

    // MARK: - Running

    func convertAll() { enqueue(jobs.filter { $0.status.canStart }) }

    func convert(_ job: ConversionJob) { enqueue([job]) }

    func cancelAll() {
        worker?.cancel()
        for job in jobs where job.status == .queued { job.status = .pending }
    }

    private func enqueue(_ batch: [ConversionJob]) {
        for job in batch where job.status.canStart { job.status = .queued }
        guard worker == nil else { return }
        worker = Task {
            await drain()
            worker = nil
        }
    }

    private func drain() async {
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            while true {
                while running < maxConcurrentJobs, !Task.isCancelled,
                      let next = jobs.first(where: { $0.status == .queued }) {
                    next.status = .converting(0)
                    running += 1
                    group.addTask { await self.process(next) }
                }
                guard running > 0 else { break }
                await group.next()
                running -= 1
            }
        }
        for job in jobs where job.status == .queued { job.status = .pending }
    }

    private func process(_ job: ConversionJob) async {
        guard let engine = registry.engine(for: job.target, sourceType: job.sourceType) else {
            job.status = .failed("No engine can produce \(job.target.displayName) from this file.")
            return
        }
        let directory: URL
        do {
            directory = try storage.makeJobDirectory(for: job.id)
        } catch {
            job.status = .failed(error.localizedDescription)
            return
        }
        let request = ConversionRequest(
            sourceURLs: job.sourceURLs,
            sourceType: job.sourceType,
            target: job.target,
            options: ConversionOptions(stripMetadata: stripMetadata),
            outputDirectory: directory
        )
        let scoped = job.sourceURLs.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }

        do {
            let output = try await engine.convert(request) { fraction in
                Task { @MainActor in job.updateProgress(fraction) }
            }
            job.finish(with: output)
        } catch is CancellationError {
            job.status = .cancelled
        } catch {
            job.status = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
        }
    }

    // MARK: - Export

    func save(_ job: ConversionJob) {
        guard let output = job.output,
              let destination = PanelService.saveDestination(
                suggestedName: output.url.lastPathComponent,
                contentType: output.isDirectory ? nil : job.target.contentType)
        else { return }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        do {
            try storage.export(output.url, to: destination)
        } catch {
            notice = Notice(title: "Export failed", message: error.localizedDescription)
        }
    }

    func exportAll() {
        let done = completedJobs
        guard !done.isEmpty, let folder = PanelService.chooseExportFolder() else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        var failures: [String] = []
        for job in done {
            guard let output = job.output else { continue }
            let name = output.url.deletingPathExtension().lastPathComponent
            let ext = output.isDirectory ? nil : output.url.pathExtension
            let destination = FileStorageService.uniqueURL(in: folder, baseName: name, pathExtension: ext)
            do { try storage.export(output.url, to: destination) } catch { failures.append(job.displayName) }
        }
        notice = failures.isEmpty
            ? Notice(title: "Export complete", message: "\(done.count) item(s) saved to “\(folder.lastPathComponent)”.")
            : Notice(title: "Some exports failed", message: failures.joined(separator: ", "))
    }

    // MARK: - Helpers

    /// Expands dropped folders into their files (recursively, hidden files skipped).
    private static func expand(_ urls: [URL], limit: Int = 5_000) -> [URL] {
        var result: [URL] = []
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]))
                .map { $0.isDirectory == true && $0.isPackage != true } ?? false
            guard isDirectory else { result.append(url); continue }
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let file = enumerator?.nextObject() as? URL, result.count < limit {
                if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    result.append(file)
                }
            }
        }
        return result
    }
}
