// Saves a PNG of one app's on-screen windows only (nothing else on the screen), composited.
// Usage: swift Scripts/dev/shoot.swift <pid> <out.png>
import AppKit
import ScreenCaptureKit

let args = CommandLine.arguments
guard args.count == 3, let pid = pid_t(args[1]) else { print("usage: shoot <pid> <out.png>"); exit(2) }
let out = URL(fileURLWithPath: args[2])

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.isOnScreen && $0.frame.width > 50 }
        guard let display = content.displays.first, let first = windows.first else { print("no windows"); exit(1) }
        let union = windows.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let filter = SCContentFilter(display: display, including: windows)
        let config = SCStreamConfiguration()
        config.sourceRect = union
        config.width = Int(union.width * 2); config.height = Int(union.height * 2)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])!.write(to: out)
        print("saved \(windows.count) windows")
        exit(0)
    } catch { print("error \(error)"); exit(1) }
}
RunLoop.main.run()
