import AppKit
import DeskMateCore
import Foundation
import SwiftUI

/// Arguments of `DeskMate --render-snapshot`.
struct SnapshotRequest {
    struct Problem: Error { let message: String }

    var output: URL
    var dark = false
    var size = CGSize(width: 980, height: 720)

    static func parse(_ arguments: [String]) -> Result<SnapshotRequest, Problem> {
        var path: String?
        var request = SnapshotRequest(output: URL(fileURLWithPath: "/"))
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--appearance":
                index += 1
                guard index < arguments.count, ["light", "dark"].contains(arguments[index]) else {
                    return .failure(Problem(message: "--appearance needs light or dark"))
                }
                request.dark = arguments[index] == "dark"
            case "--size":
                index += 1
                let parts = index < arguments.count ? arguments[index].split(separator: "x").compactMap { Double($0) } : []
                guard parts.count == 2, parts.allSatisfy({ $0 >= 200 && $0 <= 4000 }) else {
                    return .failure(Problem(message: "--size needs WIDTHxHEIGHT, e.g. 980x720"))
                }
                request.size = CGSize(width: parts[0], height: parts[1])
            default:
                guard path == nil, !argument.hasPrefix("--") else {
                    return .failure(Problem(message: "unexpected argument \(argument)"))
                }
                path = argument
            }
            index += 1
        }
        guard let path else { return .failure(Problem(message: "--render-snapshot needs an output file, e.g. .scratch/snap.png")) }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension.lowercased() == "png", url.pathComponents.contains(".scratch") else {
            return .failure(Problem(message: "snapshot output must be a .png inside a .scratch directory"))
        }
        request.output = url
        return .success(request)
    }
}

/// Development snapshot: hosts the real RootView with a real controller (empty conversation, real readiness,
/// no generation) in a window and writes what AppKit draws. It is a debugging aid, not acceptance evidence.
@MainActor
enum SnapshotRenderer {
    static func render(_ request: SnapshotRequest) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: request.dark ? .darkAqua : .aqua)

        let controller = ConversationController(engine: SystemModelEngine())
        let host = NSHostingView(rootView: RootView(controller: controller).tint(Color.dmAccent))
        // Keep the window at the requested size, as a user-sized window would be, whatever the content asks for.
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: request.size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.setContentSize(request.size)
        window.orderFrontRegardless()

        // Let SwiftUI, the text view and the readiness refresh settle.
        for _ in 0..<20 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        // The theme frame includes the title bar and toolbar, like a real screenshot.
        let frameView = host.superview ?? host
        let bounds = frameView.bounds
        guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: bounds) else {
            print("error: could not create a bitmap for the window content")
            return 1
        }
        frameView.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            print("error: could not encode PNG")
            return 1
        }
        do {
            try FileManager.default.createDirectory(at: request.output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: request.output)
        } catch {
            print("error: could not write snapshot: \(error.localizedDescription)")
            return 1
        }
        print("wrote \(request.output.path) (\(Int(bounds.width))x\(Int(bounds.height)) pt, \(request.dark ? "dark" : "light")); development snapshot, not acceptance evidence")
        return 0
    }
}
