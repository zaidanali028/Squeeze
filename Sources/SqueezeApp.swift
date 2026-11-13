import SwiftUI
import AppKit
import UserNotifications

@main
struct SqueezeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = JobModel.shared

    var body: some Scene {
        Window("Squeeze", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 840, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Videos…") {
                    let panel = NSOpenPanel()
                    panel.title = "Choose videos"
                    panel.prompt = "Add"
                    panel.allowsMultipleSelection = true
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = true
                    if panel.runModal() == .OK {
                        model.add(panel.urls)
                    }
                }
                .keyboardShortcut("o")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSRegisterServicesProvider(self, "Squeeze")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        Engine.log("OPEN FILES \(urls.map(\.lastPathComponent).joined(separator: ", "))")
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            JobModel.shared.add(urls)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Engine.log("OPEN URLS \(urls.map(\.lastPathComponent).joined(separator: ", "))")
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            JobModel.shared.add(urls)
        }
    }

    @objc func squeezeFiles(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let urls = pboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            return
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            JobModel.shared.add(urls)
        }
    }
}
