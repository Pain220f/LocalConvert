import AppKit
import UniformTypeIdentifiers

/// `NSOpenPanel` / `NSSavePanel` wrappers. Under the App Sandbox these panels (and drag & drop) are
/// the only way the app gains access to files outside its container.
@MainActor
enum PanelService {
    static func chooseInputFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Add Files"
        panel.message = "Choose files or folders to convert. LocalConvert can only read what you select here."
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .audiovisualContent, .pdf, .folder]
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func saveDestination(suggestedName: String, contentType: UTType?) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Converted File"
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let contentType { panel.allowedContentTypes = [contentType] }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseExportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Export All"
        panel.message = "Choose a folder for the converted files."
        panel.prompt = "Export Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
