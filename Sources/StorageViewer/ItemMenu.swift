import AppKit
import StorageViewerCore
import SwiftUI

struct ItemMenu: View {
    var node: FileNode
    @Environment(ScanSession.self) private var session

    var body: some View {
        let entries = ItemActions.entries(for: node, session: session)
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .separator:
                Divider()
            case .item(let title, let enabled, let destructive, let action):
                Button(role: destructive ? .destructive : nil, action: action) {
                    Text(title)
                }
                .disabled(!enabled)
            }
        }
    }
}

struct RenameSheet: View {
    var original: String
    var onCancel: () -> Void
    var onSave: (String) -> Void

    @State private var name: String
    @FocusState private var focused: Bool

    init(original: String, onCancel: @escaping () -> Void, onSave: @escaping (String) -> Void) {
        self.original = original
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: original)
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var problem: String? {
        if trimmed.isEmpty { return "The name can’t be empty." }
        if trimmed.contains("/") { return "The name can’t contain /." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .focused($focused)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Theme.canvas)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(problem == nil ? Theme.border : Theme.accent, lineWidth: 1)
                )
            Text(problem ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(problem == nil ? .clear : Theme.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { onSave(trimmed) }
                    .buttonStyle(QuietButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }
}

struct TreemapMenuCatcher: NSViewRepresentable {
    var hit: (CGPoint) -> FileNode?
    var menu: (FileNode) -> NSMenu

    func makeNSView(context: Context) -> TreemapMenuView {
        let view = TreemapMenuView()
        view.hit = hit
        view.makeMenu = menu
        return view
    }

    func updateNSView(_ view: TreemapMenuView, context: Context) {
        view.hit = hit
        view.makeMenu = menu
    }
}

final class TreemapMenuView: NSView, @unchecked Sendable {
    nonisolated(unsafe) var hit: ((CGPoint) -> FileNode?)?
    nonisolated(unsafe) var makeMenu: ((FileNode) -> NSMenu)?
    nonisolated(unsafe) private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let local = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(local) else { return event }
            let point = CGPoint(x: local.x, y: self.bounds.height - local.y)
            guard let node = self.hit?(point), let menu = self.makeMenu?(node) else { return event }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

@MainActor
enum ItemActions {
    enum Entry {
        case item(title: String, enabled: Bool, destructive: Bool, action: () -> Void)
        case separator
    }

    /// The one list both menus render. Add or reorder items here.
    static func entries(for node: FileNode, session: ScanSession) -> [Entry] {
        [
            .item(title: "Open", enabled: true, destructive: false) { session.openItem(node) },
            .item(title: "Reveal in Finder", enabled: true, destructive: false) { session.revealInFinder(node) },
            .item(title: "Rename", enabled: !node.isMount, destructive: false) { session.beginRename(node) },
            .item(title: "Copy", enabled: !node.isMount, destructive: false) { session.rememberCopy(node) },
            .item(title: "Paste", enabled: session.canPaste(onto: node), destructive: false) {
                session.paste(onto: node)
            },
            .item(title: "Duplicate", enabled: !node.isMount, destructive: false) { session.duplicate(node) },
            .separator,
            .item(title: "Move to Trash", enabled: !node.isMount, destructive: true) { session.confirmTrash(node) }
        ]
    }

    static func menu(for node: FileNode, session: ScanSession) -> NSMenu {
        let menu = NSMenu()
        for entry in entries(for: node, session: session) {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .item(let title, let enabled, _, let action):
                let item = item(title, action: action)
                item.isEnabled = enabled
                menu.addItem(item)
            }
        }
        return menu
    }

    private static func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let handler = MenuHandler(action)
        let item = NSMenuItem(title: title, action: #selector(MenuHandler.fire), keyEquivalent: "")
        item.target = handler
        item.representedObject = handler
        return item
    }
}

private final class MenuHandler: NSObject, @unchecked Sendable {
    nonisolated(unsafe) private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func fire() {
        handler()
    }
}
