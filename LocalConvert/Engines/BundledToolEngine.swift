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
///     arguments: { input, output, _ in ["-o", "max", "--strip", "safe", "--out", output.path, input.path] }
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
    let arguments: @Sendable (_ input: URL, _ output: URL, _ target: SupportedFormat) -> [String]

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

        let box = ProcessBox()
        box.process.executableURL = executableURL
        box.process.arguments = arguments(request.sourceURL, outputURL, request.target)
        box.process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        box.process.standardError = errorPipe

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try box.process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            box.process.terminate()
        }
        try Task.checkCancellation()
        guard status == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ConversionError.engineFailure("\(displayName) exited with status \(status). \(message)")
        }
        progress(1)
        return try OutputBuilder.make(url: outputURL, fidelity: fidelity, engineName: displayName, startedAt: start)
    }
}

/// `Process` is not `Sendable`; it is only touched from the continuation and the cancel handler.
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
}
