import AppKit
import SwiftUI

@main
struct LocalConvertApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var queue = ConversionQueueManager()

    var body: some Scene {
        Window("LocalConvert", id: "main") {
            ContentView(queue: queue)
                .frame(minWidth: 860, minHeight: 520)
        }
        .defaultSize(width: 1100, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { queue.addFromOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Convert") {
                Button("Convert All") { queue.convertAll() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!queue.canConvert)
                Button("Cancel All") { queue.cancelAll() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!queue.isRunning)
                Divider()
                Button("Combine Images into PDF") { queue.combineImagesIntoPDF() }
                    .disabled(queue.imageJobs.isEmpty)
                Button("Export All…") { queue.exportAll() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(queue.completedJobs.isEmpty)
                Divider()
                Toggle("Strip Metadata (EXIF / GPS)", isOn: $queue.stripMetadata)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Remove scratch files left behind by a previous session (e.g. after a crash).
        FileStorageService.purgeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        FileStorageService.purgeAll()
    }
}
