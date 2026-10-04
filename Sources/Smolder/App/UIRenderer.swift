import SwiftUI

/// Offscreen rendering of the panel with demo data, for documentation screenshots.
@MainActor
enum UIRenderer {
    static func render(monitor: Monitor, to directory: URL) {
        if let i = CommandLine.arguments.firstIndex(of: "--lang"), i + 1 < CommandLine.arguments.count {
            Localization.shared.apply(languageCode: CommandLine.arguments[i + 1])
        }
        monitor.loadDemo()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            write(MenuPanel(showsControls: false).environmentObject(monitor), scheme: scheme, to: directory.appendingPathComponent("panel-\(suffix).png"))
        }
    }

    private static func write<V: View>(_ view: V, scheme: ColorScheme, to url: URL) {
        let content = view
            .environment(\.colorScheme, scheme)
            .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
