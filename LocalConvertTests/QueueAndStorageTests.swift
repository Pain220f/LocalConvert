import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import LocalConvert

/// Records how many conversions run at the same time.
actor ConcurrencyProbe {
    private(set) var current = 0
    private(set) var peak = 0
    private(set) var finished = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func exit(completed: Bool) {
        current -= 1
        if completed { finished += 1 }
    }
}

/// Test double: "converts" an image by sleeping and copying it, honouring cancellation.
struct SlowEngine: ConversionEngineProtocol {
    let identifier = "slow"
    let displayName = "Slow"
    let delay: Duration
    let probe: ConcurrencyProbe

    func supportedTargets(for sourceType: UTType) -> [SupportedFormat] {
        sourceType.conforms(to: .image) ? [.png] : []
    }

    func convert(_ request: ConversionRequest, progress: @escaping ProgressHandler) async throws -> ConversionOutput {
        let start = ContinuousClock.now
        await probe.enter()
        do {
            try await Task.sleep(for: delay)
        } catch {
            await probe.exit(completed: false)
            throw error
        }
        await probe.exit(completed: true)
        let output = request.outputDirectory.appending(path: request.sourceURL.lastPathComponent)
        try FileManager.default.copyItem(at: request.sourceURL, to: output)
        return try OutputBuilder.make(url: output, fidelity: .bitExact, engineName: displayName, startedAt: start)
    }
}

@MainActor
func waitUntil(timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for condition")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
private func makePNGs(_ count: Int, in directory: URL) throws -> [URL] {
    try (0..<count).map { index in
        try Fixtures.write(Fixtures.gradientImage(width: 16 + index, height: 16),
                           as: .png, to: directory.appending(path: "image-\(index).png"))
    }
}

@MainActor
@Suite("Conversion queue", .serialized)
struct QueueManagerTests {
    @Test("Never runs more than maxConcurrentJobs at once and completes every job")
    func boundedConcurrency() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = ConcurrencyProbe()
        let queue = ConversionQueueManager(
            registry: EngineRegistry(engines: [SlowEngine(delay: .milliseconds(150), probe: probe)]),
            maxConcurrentJobs: 2)

        await queue.add(try makePNGs(5, in: directory))
        #expect(queue.jobs.count == 5)
        queue.convertAll()
        #expect(queue.isRunning)
        try await waitUntil { !queue.isRunning }

        #expect(queue.jobs.allSatisfy { $0.status == .completed })
        #expect(await probe.peak == 2)
        #expect(await probe.finished == 5)
        #expect(queue.totals?.before == queue.totals?.after)
        queue.clear()
    }

    @Test("Cancel stops running jobs and returns queued ones to pending")
    func cancellation() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = ConcurrencyProbe()
        let queue = ConversionQueueManager(
            registry: EngineRegistry(engines: [SlowEngine(delay: .seconds(30), probe: probe)]),
            maxConcurrentJobs: 1)

        await queue.add(try makePNGs(3, in: directory))
        queue.convertAll()
        try await waitUntil { queue.jobs.contains { if case .converting = $0.status { true } else { false } } }
        queue.cancelAll()
        try await waitUntil(timeout: .seconds(5)) { !queue.isRunning }

        #expect(await probe.finished == 0)
        #expect(queue.jobs.contains { $0.status == .cancelled })
        #expect(queue.jobs.allSatisfy { $0.status == .cancelled || $0.status == .pending })
        #expect(queue.jobs.allSatisfy { $0.output == nil })
    }

    @Test("Folders are expanded, hidden and unsupported files are skipped")
    func folderImport() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try makePNGs(2, in: nested)
        try Data("hello".utf8).write(to: nested.appending(path: "notes.txt"))
        try Data().write(to: nested.appending(path: ".hidden.png"))

        let queue = ConversionQueueManager()
        await queue.add([directory])

        #expect(queue.jobs.count == 2)
        #expect(queue.notice?.message.contains("notes.txt") == true)
        // Adding the same folder again does not duplicate jobs.
        await queue.add([directory])
        #expect(queue.jobs.count == 2)
    }

    @Test("Combining images makes one PDF job whose output has one page per image")
    func combineIntoPDF() async throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = ConversionQueueManager()
        await queue.add(try makePNGs(3, in: directory))

        queue.combineImagesIntoPDF()
        let combined = try #require(queue.jobs.last)
        #expect(combined.isCombined)
        #expect(combined.sourceURLs.count == 3)
        #expect(combined.availableTargets == [.pdf])
        #expect(combined.originalBytes == queue.jobs.dropLast().reduce(0) { $0 + $1.originalBytes })

        queue.convert(combined)
        try await waitUntil { !queue.isRunning }
        let output = try #require(combined.output)
        #expect(CGPDFDocument(output.url as CFURL)?.numberOfPages == 3)
        #expect(combined.sizeDelta?.after == output.byteCount)
    }
}

@Suite("File storage")
struct FileStorageTests {
    let storage = FileStorageService()

    @Test func exportToNewFile() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "a.bin")
        try Data([1, 2, 3]).write(to: source)
        let destination = directory.appending(path: "copy.bin")

        try storage.export(source, to: destination)
        #expect(try Data(contentsOf: destination) == Data([1, 2, 3]))
    }

    @Test func exportReplacesExistingFileAtomically() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "new.bin")
        try Data(repeating: 7, count: 1_000).write(to: source)
        let destination = directory.appending(path: "existing.bin")
        try Data("old".utf8).write(to: destination)

        try storage.export(source, to: destination)
        #expect(try Data(contentsOf: destination) == Data(repeating: 7, count: 1_000))
        #expect(FileManager.default.fileExists(atPath: source.path), "the converted output stays available")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: storage.sessionDirectory.path)) ?? []
        #expect(!leftovers.contains { $0.hasPrefix("staging-") })
    }

    @Test func exportDirectoryAndMeasureIt() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appending(path: "pages", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 10).write(to: folder.appending(path: "1.pdf"))
        try Data(count: 32).write(to: folder.appending(path: "2.pdf"))

        let destination = directory.appending(path: "exported", directoryHint: .isDirectory)
        try storage.export(folder, to: destination)
        #expect(try FileStorageService.byteCount(at: destination) == 42)
        #expect(FileStorageService.fileCount(at: destination) == 2)
    }

    @Test func uniqueNamesDoNotOverwrite() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = FileStorageService.uniqueURL(in: directory, baseName: "photo", pathExtension: "png")
        try Data().write(to: first)
        let second = FileStorageService.uniqueURL(in: directory, baseName: "photo", pathExtension: "png")
        #expect(first.lastPathComponent == "photo.png")
        #expect(second.lastPathComponent == "photo 2.png")
    }
}
