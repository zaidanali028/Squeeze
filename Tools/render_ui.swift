import SwiftUI
import AppKit

@main
struct RenderUI {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let model = JobModel.shared
        render(model, to: "/tmp/squeeze-ui-empty.png")
        model.add([URL(fileURLWithPath: "/tmp/squeeze-tests/clip-1080p.mp4")])
        render(model, to: "/tmp/squeeze-ui-one.png")
        model.add([URL(fileURLWithPath: "/tmp/squeeze-tests/clip-4k.mp4")])
        render(model, to: "/tmp/squeeze-ui-two.png")
    }

    @MainActor
    static func render(_ model: JobModel, to path: String) {
        let hosting = NSHostingView(rootView: ContentView().environmentObject(model))
        hosting.frame = NSRect(x: 0, y: 0, width: 840, height: 680)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -2000, y: -2000))
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("render failed \(path)")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed \(path)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("rendered \(path)")
        window.orderOut(nil)
    }
}
