import Foundation
import os
import UniformTypeIdentifiers

/// Extensibility hook for a future phase: wraps a statically linked, code-signed command-line tool
/// shipped inside the app bundle (`Contents/MacOS/<name>`), e.g. `oxipng` or `ffmpeg`.
///
/// It is **not registered** in `EngineRegistry.standard` because this release bundles no binaries.
/// To enable one, copy the signed binary into the app (Build Phases → Copy Files → Executables) and add:
///
/// ```swift
/// BundledToolEngine(
///     identifier: "oxipng", displayName: "oxipng", executableName: "oxipng",
///     sourceTypes: [.png], targets: [.png], fidelity: .lossless,
///     arguments: { input, output, _, options in
///         ["-o", "max", "--strip", options.stripMetadata ? "all" : "safe", "--out", output.path, input.path]
///     }
/// )
/// ```
///
/// Child processes inherit the App Sandbox, so a bundled tool cannot reach the network either.
struct BundledToolEngine: ConversionEngineProtocol {
    let identifier: String
    let displayName: String
    let executableName: String
    let sourceTypes: [UTType]
    let targets: [SupportedFormat]
    let fidelity: Fidelity
    let arguments: @Sendable (_ input: URL, _ output: URL, _ target: SupportedFormat, _ options: ConversionOptions) -> [String]

    var executableURL: URL? { Bundle.main.url(forAuxiliaryExecutable: executableName) }

    func supportedTargets(for sourceType: UTType) -> [SupportedFormat] {
        guard executableURL != nil, sourceTypes.contains(where: { sourceType.conforms(to: $0) }) else { return [] }
        return targets
    }

    func convert(_ request: ConversionRequest, progress: @escaping ProgressHandler) async throws -> ConversionOutput {
        let start = ContinuousClock.now
        guard let executableURL else { throw ConversionError.encoderUnavailable(displayName) }
        guard let pathExtension = request.target.fileExtension else {
            throw ConversionError.unsupportedConversion(from: request.sourceType, to: request.target)
        }
        let outputURL = FileStorageService.uniqueURL(in: request.outputDirectory, baseName: request.baseName, pathExtension: pathExtension)

        // The tool only ever sees synthetic names in a private staging folder: user file names can
        // contain ':' or '%d' that tools like ffmpeg would treat as protocols or patterns.
        let staging = request.outputDirectory.appending(path: ".tool-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let inputExtension = request.sourceURL.pathExtension.filter { $0.isLetter || $0.isNumber }.prefix(8)
        let stagedInput = staging.appending(path: inputExtension.isEmpty ? "input" : "input.\(inputExtension)")
        let stagedOutput = staging.appending(path: "output.\(pathExtension)")
        try FileManager.default.createSymbolicLink(at: stagedInput, withDestinationURL: request.sourceURL)

        // stderr is drained continuously into a bounded ring buffer: no pipe deadlock, no unbounded
        // disk or memory use however much the tool prints.
        let errorPipe = Pipe()
        let stderrTail = BoundedBuffer(capacity: 16 * 1024)
        errorPipe.fileHandleForReading.readabilityHandler = { handle in stderrTail.append(handle.availableData) }

        let box = ProcessBox()
        box.process.executableURL = executableURL
        box.process.arguments = arguments(stagedInput, stagedOutput, request.target, request.options)
        box.process.currentDirectoryURL = staging
        // Minimal, explicit environment: nothing (DYLD_*, proxies, tokens…) leaks in from the parent.
        box.process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TMPDIR": staging.path]
        box.process.standardInput = FileHandle.nullDevice
        box.process.standardOutput = FileHandle.nullDevice
        box.process.standardError = errorPipe

        let status: Int32
        do {
            status = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    box.process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                    do { try box.launch() } catch { continuation.resume(throwing: error) }
                }
            } onCancel: {
                box.terminate()
            }
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try Task.checkCancellation()
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        guard status == 0 else {
            let message = String(decoding: stderrTail.contents.suffix(2_000), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ConversionError.engineFailure("\(displayName) exited with status \(status). \(message)")
        }
        guard FileManager.default.fileExists(atPath: stagedOutput.path) else {
            throw ConversionError.engineFailure("\(displayName) did not produce an output file.")
        }
        try FileManager.default.moveItem(at: stagedOutput, to: outputURL)
        progress(1)
        return try OutputBuilder.make(url: outputURL, fidelity: fidelity, engineName: displayName, startedAt: start)
    }
}

/// `Process` is not `Sendable`. All access to its run state goes through `lock`, so a cancel that
/// races with launch either prevents the launch or terminates the running process — never neither.
private final class ProcessBox: @unchecked Sendable {
    private enum State { case idle, running, cancelled }
    let process = Process()
    private let lock = OSAllocatedUnfairLock(initialState: State.idle)

    func launch() throws {
        try lock.withLock { state in
            guard state == .idle else { throw CancellationError() }
            try process.run()
            state = .running
        }
    }

    func terminate() {
        lock.withLock { state in
            if state == .running, process.isRunning { process.terminate() }
            state = .cancelled
        }
    }
}

/// Keeps only the last `capacity` bytes written to it. Thread-safe.
final class BoundedBuffer: Sendable {
    private let storage: OSAllocatedUnfairLock<Data>
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        storage = OSAllocatedUnfairLock(initialState: Data())
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        storage.withLock { data in
            data.append(chunk.suffix(capacity))
            if data.count > capacity { data = Data(data.suffix(capacity)) }
        }
    }

    var contents: Data { storage.withLock { $0 } }
}
