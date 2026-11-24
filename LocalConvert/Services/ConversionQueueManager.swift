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
    /// Short description of background file work (importing a folder, exporting), for the status bar.
    private(set) var activity: String?

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

    /// A file accepted for conversion, found by the background scan.
    struct Candidate: Sendable {
        let url: URL
        let type: UTType
        let category: MediaCategory
        let bytes: Int64
        let targets: [SupportedFormat]
        let compressionTargets: [SupportedFormat]
    }

    /// Scans dropped/selected items (expanding folders) off the main actor, then adds jobs.
    func add(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        activity = "Scanning \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")…"
        defer { activity = nil }
        let registry = self.registry
        let (candidates, rejected) = await Task.detached(priority: .userInitiated) {
            Self.scan(urls, registry: registry)
        }.value

        for candidate in candidates where !jobs.contains(where: { $0.sourceURLs == [candidate.url] }) {
            jobs.append(ConversionJob(sourceURLs: [candidate.url], sourceType: candidate.type, category: candidate.category,
                                      originalBytes: candidate.bytes, availableTargets: candidate.targets,
                                      compressionTargets: candidate.compressionTargets))
        }
        if !rejected.isEmpty {
            let list = rejected.prefix(8).joined(separator: ", ") + (rejected.count > 8 ? " …" : "")
            notice = Notice(title: "Some files were skipped",
                            message: "\(rejected.count) file(s) are not a supported image, audio, video or PDF type: \(list)")
        }
    }

    nonisolated private static func scan(_ urls: [URL], registry: EngineRegistry) -> ([Candidate], [String]) {
        var accepted: [Candidate] = []
        var rejected: [String] = []
        for url in expand(urls) {
            guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType,
                  let category = MediaCategory(type: type)
            else { rejected.append(url.lastPathComponent); continue }
            let targets = registry.targets(for: type)
            guard !targets.isEmpty else { rejected.append(url.lastPathComponent); continue }
            let bytes = (try? FileStorageService.byteCount(at: url)) ?? 0
            accepted.append(Candidate(url: url, type: type, category: category, bytes: bytes, targets: targets,
                                      compressionTargets: registry.compressionTargets(for: type)))
        }
        return (accepted, rejected)
    }

    func addFromOpenPanel() {
        let urls = PanelService.chooseInputFiles()
        Task { await add(urls) }
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
            availableTargets: [.pdf],
            compressionTargets: [.pdfCompressed]
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

    /// Title for the primary action, reflecting what the pending jobs will do.
    var runAllTitle: String {
        let modes = Set(jobs.filter { $0.status.canStart }.map(\.mode))
        if modes == [.compressSize] { return "Compress All" }
        if modes == [.convertFormat] { return "Convert All" }
        return "Run All"
    }

    func applySettingsToAll(from job: ConversionJob) {
        for other in jobs where other !== job { other.adoptSettings(from: job) }
    }

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
            options: job.options(stripMetadata: stripMetadata),
            outputDirectory: directory
        )
        let scoped = job.sourceURLs.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }

        do {
            var output = try await engine.convert(request) { fraction in
                Task { @MainActor in job.updateProgress(fraction) }
            }
            output.targetMaxBytes = request.options.targetMaxBytes
            // Safety net: a size limit is a hard promise, whatever the engine did.
            if let limit = request.options.targetMaxBytes, output.byteCount > limit {
                try? FileManager.default.removeItem(at: output.url)
                throw ConversionError.cannotMeetTargetSize(
                    smallestAchievable: output.byteCount, target: limit,
                    suggestion: "Try a size-efficient format or allow downscaling.")
            }
            job.finish(with: output)
        } catch is CancellationError {
            job.status = .cancelled
        } catch {
            job.status = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
        }
    }

    // MARK: - Export

    func save(_ job: ConversionJob) async {
        guard let output = job.output,
              let destination = PanelService.saveDestination(
                suggestedName: output.url.lastPathComponent,
                contentType: output.isDirectory ? nil : job.target.contentType)
        else { return }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        activity = "Saving \(destination.lastPathComponent)…"
        defer { activity = nil }
        let storage = self.storage
        let item = output.url
        do {
            // Copying a multi-GB video must not block the main thread.
            try await Task.detached(priority: .userInitiated) { try storage.export(item, to: destination) }.value
        } catch {
            notice = Notice(title: "Export failed", message: error.localizedDescription)
        }
    }

    func exportAll() async {
        let outputs = completedJobs.compactMap { job in job.output.map { (job.displayName, $0.url, $0.isDirectory) } }
        guard !outputs.isEmpty, let folder = PanelService.chooseExportFolder() else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        activity = "Exporting \(outputs.count) item(s)…"
        defer { activity = nil }
        let storage = self.storage
        let failures = await Task.detached(priority: .userInitiated) { () -> [String] in
            var failures: [String] = []
            for (name, url, isDirectory) in outputs {
                let destination = FileStorageService.uniqueURL(
                    in: folder, baseName: url.deletingPathExtension().lastPathComponent,
                    pathExtension: isDirectory ? nil : url.pathExtension)
                do { try storage.export(url, to: destination) } catch { failures.append(name) }
            }
            return failures
        }.value
        notice = failures.isEmpty
            ? Notice(title: "Export complete", message: "\(outputs.count) item(s) saved to “\(folder.lastPathComponent)”.")
            : Notice(title: "Some exports failed", message: failures.joined(separator: ", "))
    }

    // MARK: - Helpers

    /// Expands dropped folders into their files (recursively, hidden files skipped).
    nonisolated private static func expand(_ urls: [URL], limit: Int = 5_000) -> [URL] {
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
