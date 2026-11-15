import AppKit
import SwiftUI

@main
struct StorageViewerApp: App {
    @State private var session = ScanSession()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1140, height: 740)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose Folder…") { session.chooseFolder() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Go") {
                Button("Back") { session.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!session.canGoBack)
                Button("Forward") { session.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!session.canGoForward)
                Button("Enclosing Folder") { session.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!session.canGoUp)
                Button("Filter Names") { session.focusFilterTick += 1 }
                    .keyboardShortcut("f")
                Divider()
                Button("Cancel Scan") { session.cancel() }
                    .keyboardShortcut(".")
                    .disabled(session.phase != .scanning)
            }
        }
    }
}
