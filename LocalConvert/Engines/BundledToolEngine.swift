import Foundation
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

        // stderr goes to a file, not a Pipe: a tool that writes more than the pipe buffer (~64 KB)
        // while nobody reads would otherwise block forever and deadlock the conversion.
        let logURL = FileStorageService.rootDirectory.appending(path: "tool-\(UUID().uuidString).log")
        try FileManager.default.createDirectory(at: FileStorageService.rootDirectory, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
            throw ConversionError.writeFailed("could not create a log file for \(displayName)")
        }
        defer { try? FileManager.default.removeItem(at: logURL) }
        let log = try FileHandle(forWritingTo: logURL)

        let box = ProcessBox()
        box.process.executableURL = executableURL
        box.process.arguments = arguments(request.sourceURL, outputURL, request.target, request.options)
        box.process.standardInput = FileHandle.nullDevice
        box.process.standardOutput = FileHandle.nullDevice
        box.process.standardError = log

        let status: Int32
        do {
            status = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    box.process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                    do { try box.process.run() } catch { continuation.resume(throwing: error) }
                }
            } onCancel: {
                box.terminate()
            }
            try log.close()
            try Task.checkCancellation()
        } catch {
            try? log.close()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        guard status == 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            let tail = ((try? Data(contentsOf: logURL)) ?? Data()).suffix(2_000)
            let message = String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ConversionError.engineFailure("\(displayName) exited with status \(status). \(message)")
        }
        progress(1)
        return try OutputBuilder.make(url: outputURL, fidelity: fidelity, engineName: displayName, startedAt: start)
    }
}

/// `Process` is not `Sendable`; it is only touched from the continuation and the cancel handler.
private final class ProcessBox: @unchecked Sendable {
    let process = Process()

    /// `terminate()` raises an Objective-C exception if the process was never launched.
    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
