import AppKit
import StorageViewerCore
import SwiftUI

enum Theme {
    static let canvas = Color(red: 0x0e / 255, green: 0x0e / 255, blue: 0x0e / 255)
    static let panel = Color(red: 0x16 / 255, green: 0x16 / 255, blue: 0x16 / 255)
    static let press = Color(red: 0x22 / 255, green: 0x22 / 255, blue: 0x22 / 255)
    static let border = Color(red: 0x2a / 255, green: 0x2a / 255, blue: 0x2a / 255)
    static let text = Color(red: 0xec / 255, green: 0xec / 255, blue: 0xec / 255)
    static let secondary = Color(red: 0x8b / 255, green: 0x8b / 255, blue: 0x8b / 255)
    static let accent = Color(red: 0x4c / 255, green: 0x8b / 255, blue: 0xf5 / 255)
    static let labelInk = Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255)
    /// Amber is the selection only. Type blocks use the category colors.
    static let selection = Color(red: 0xe8 / 255, green: 0xa2 / 255, blue: 0x3a / 255)
    static let onSelection = Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255)

    private static let codeColor = Color(red: 0x3d / 255, green: 0x7a / 255, blue: 0xe0 / 255)
    private static let imagesColor = Color(red: 0x8b / 255, green: 0x5c / 255, blue: 0xf6 / 255)
    private static let videoColor = Color(red: 0xe8 / 255, green: 0x5d / 255, blue: 0x8c / 255)
    private static let audioColor = Color(red: 0xe6 / 255, green: 0xc5 / 255, blue: 0x3a / 255)
    private static let archivesColor = Color(red: 0x2f / 255, green: 0xbf / 255, blue: 0x8a / 255)
    private static let documentsColor = Color(red: 0x3c / 255, green: 0xb8 / 255, blue: 0xd9 / 255)
    private static let otherColor = Color(red: 0x8a / 255, green: 0x8a / 255, blue: 0x8a / 255)

    static func color(for category: FileCategory) -> Color {
        switch category {
        case .code: codeColor
        case .images: imagesColor
        case .video: videoColor
        case .audio: audioColor
        case .archives: archivesColor
        case .documents: documentsColor
        case .other: otherColor
        }
    }
}

struct QuietButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Theme.accent : Theme.text)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(configuration.isPressed ? Theme.press : Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(prominent ? Theme.accent.opacity(0.85) : Theme.border, lineWidth: 1)
            )
    }
}

struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowChromeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowChromeView: NSView {
    private static let darkBackground = NSColor(srgbRed: 0x0e / 255, green: 0x0e / 255, blue: 0x0e / 255, alpha: 1)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.title = "StorageViewer"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Self.darkBackground
    }
}
