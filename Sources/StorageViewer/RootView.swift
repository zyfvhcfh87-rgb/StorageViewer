import StorageViewerCore
import SwiftUI

struct RootView: View {
    @Environment(ScanSession.self) private var session
    @FocusState private var filterFocused: Bool
    @AppStorage(FlatLayout.storageKey) private var layoutRaw = FlatLayout.foundation.rawValue

    private var layout: FlatLayout {
        FlatLayout(rawValue: layoutRaw) ?? .foundation
    }

    private var layoutBinding: Binding<FlatLayout> {
        Binding(
            get: { layout },
            set: { layoutRaw = $0.rawValue }
        )
    }

    var body: some View {
        @Bindable var bindableSession = session
        VStack(spacing: 0) {
            TopBar(layout: layoutBinding)
                .padding(.leading, 78)
                .padding(.trailing, 16)
                .frame(height: 52)
                .background(Theme.canvas)
            Rectangle().fill(Theme.chromeHairline).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas)
        .ignoresSafeArea(edges: .top)
        .preferredColorScheme(.dark)
        .background(WindowChrome())
        .onAppear {
            if FlatLayout(rawValue: layoutRaw) == nil {
                layoutRaw = FlatLayout.foundation.rawValue
            }
            NSApplication.shared.activate()
            session.consumeLaunchArgumentsIfNeeded()
        }
        .onChange(of: session.focusFilterTick) { _, _ in
            filterFocused = true
        }
        .sheet(item: $bindableSession.renameTarget) { node in
            RenameSheet(original: node.name) {
                session.renameTarget = nil
            } onSave: { name in
                let error = session.commitRename(node, to: name)
                if error == nil {
                    session.renameTarget = nil
                }
                return error
            }
        }
        .alert(
            "Couldn’t change the item",
            isPresented: Binding(
                get: { session.treeError != nil },
                set: { if !$0 { session.treeError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { session.treeError = nil }
        } message: {
            Text(session.treeError ?? "")
        }
        .onExitCommand {
            if filterFocused {
                if session.filter.isEmpty {
                    filterFocused = false
                } else {
                    session.filter = ""
                }
            } else if session.phase == .scanning {
                session.cancel()
            } else {
                session.goUp()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .empty:
            EmptyState()
        case .scanning where session.root == nil:
            DialScanView()
        case .permissionDenied:
            MessageState(
                title: "Permission denied",
                detail: "macOS refused to read this folder. Choose another one. Full Disk Access is not required."
            )
        case .missing:
            MessageState(
                title: "Folder not found",
                detail: "That path is no longer there."
            )
        case .cancelled where session.root == nil:
            MessageState(
                title: "Scan cancelled",
                detail: session.filesSeen == 0
                    ? "Nothing was counted before the scan stopped."
                    : "\(session.statusLine) before the scan stopped."
            )
        default:
            ResultsView(filterFocused: $filterFocused, layout: layout)
        }
    }
}

private struct TopBar: View {
    @Environment(ScanSession.self) private var session
    @Binding var layout: FlatLayout

    var body: some View {
        let canRescan = session.phase != .scanning && session.rootURL != nil
        HStack(spacing: 14) {
            Text("StorageViewer")
                .font(.custom("Avenir Next", size: 15).weight(.semibold))
                .tracking(-0.6)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .fixedSize()
            LayoutPicker(layout: $layout)
            OpenMenu()
            Spacer(minLength: 12)
            if session.phase != .empty, session.phase != .scanning {
                Text(session.statusLine)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.chromeMuted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            if canRescan {
                ChromeButton(title: "Scan", prominent: true) { session.rescan() }
            }
            ChromeButton(title: "Choose", prominent: !canRescan) { session.chooseFolder() }
        }
    }
}

private struct ChromeButton: View {
    var title: String
    var prominent: Bool
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Theme.chromeInk : Theme.text)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background {
                    Capsule().fill(prominent ? Theme.chromeWhite : (hovered ? Theme.chromeHover : Color.clear))
                }
                .overlay {
                    Capsule().strokeBorder(prominent ? Color.clear : Theme.chromeStroke, lineWidth: 1)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct OpenMenu: View {
    @Environment(ScanSession.self) private var session

    var body: some View {
        Menu {
            ForEach(session.startPoints) { point in
                Button(point.title) { session.startScan(point.url) }
            }
            Divider()
            Button("Choose Folder…") { session.chooseFolder() }
        } label: {
            crumb
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(session.rootURL?.path ?? "Open a folder")
    }

    private var crumb: Text {
        let mark = Text(" \(Image(systemName: "chevron.down"))")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Theme.chromeFaint)
        if let url = session.rootURL {
            let leaf = Text(session.rootTitle)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text)
            if let parent = parentTitle(for: url) {
                let head = Text(parent)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.chromeMuted)
                let slash = Text(" / ")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.chromeFaint)
                return head + slash + leaf + mark
            }
            return leaf + mark
        }
        return Text("Open")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.chromeMuted) + mark
    }

    private func parentTitle(for url: URL) -> String? {
        let parent = url.deletingLastPathComponent()
        if parent.path == "/" || parent.path == url.path { return nil }
        let name = parent.lastPathComponent
        if name.isEmpty || name == "/" { return nil }
        return name
    }
}

private struct ResultsView: View {
    @Environment(ScanSession.self) private var session
    var filterFocused: FocusState<Bool>.Binding
    var layout: FlatLayout

    var body: some View {
        VStack(spacing: 0) {
            if session.phase == .cancelled {
                Text("Scan cancelled. Showing a partial tree.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Theme.panel)
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            BreadcrumbBar()
            Rectangle().fill(Theme.border).frame(height: 1)
            CossArrangement(layout: layout) {
                map
            } list: {
                list
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            Footer(filterFocused: filterFocused)
                .frame(height: 36)
                .background(Theme.panel)
        }
    }

    @ViewBuilder
    private var list: some View {
        if let root = session.root {
            LargestListView(
                root: root,
                expanded: session.expanded,
                filter: session.filter,
                selection: session.selection,
                scrollToken: session.listScrollToken,
                revision: session.treeRevision,
                onSelect: { session.selectFromList($0) },
                onToggle: { session.toggleDisclosure($0) }
            )
        }
    }

    @ViewBuilder
    private var map: some View {
        if let current = session.current {
            TreemapView(
                folder: current,
                selection: session.selection,
                filter: session.filter,
                onSelect: { session.selectFromMap($0) },
                onZoom: { session.zoom($0) },
                onHover: { session.hover($0) },
                revision: session.treeRevision,
                contextMenu: { ItemActions.menu(for: $0, session: session) }
            )
        }
    }
}

private struct BreadcrumbBar: View {
    @Environment(ScanSession.self) private var session

    var body: some View {
        let _ = session.treeRevision
        let chain = session.chain
        HStack(spacing: 0) {
            HistoryButton(
                systemName: "chevron.left",
                label: "Back",
                enabled: session.canGoBack,
                action: { session.goBack() }
            )
            HistoryButton(
                systemName: "chevron.right",
                label: "Forward",
                enabled: session.canGoForward,
                action: { session.goForward() }
            )
            Rectangle()
                .fill(Theme.border)
                .frame(width: 1, height: 14)
                .padding(.horizontal, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(chain.enumerated()), id: \.element.id) { index, node in
                        if index > 0 {
                            Text(" / ")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondary.opacity(0.7))
                        }
                        Button {
                            session.reveal(index: index)
                        } label: {
                            Text(node.name)
                                .font(.system(size: 12, weight: index == chain.count - 1 ? .medium : .regular))
                                .foregroundStyle(index == chain.count - 1 ? Theme.text : Theme.secondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(node.name)
                    }
                }
                .padding(.trailing, 12)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("breadcrumb")
            .accessibilityValue(chain.map(\.name).joined(separator: " / "))
        }
        .padding(.leading, 8)
        .frame(height: 30)
        .background(Theme.panel)
    }
}

private struct HistoryButton: View {
    var systemName: String
    var label: String
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? Theme.text : Theme.secondary.opacity(0.35))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct Footer: View {
    @Environment(ScanSession.self) private var session
    var filterFocused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var bindableSession = session
        HStack(spacing: 12) {
            Text(session.footerText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Legend()
            FilterField(text: $bindableSession.filter, focused: filterFocused)
        }
        .padding(.horizontal, 10)
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach(FileCategory.allCases, id: \.self) { category in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Theme.color(for: category))
                        .frame(width: 8, height: 8)
                    Text(category.rawValue)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .fixedSize()
    }
}

private struct FilterField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Text("Filter")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            TextField("Names", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .focused(focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 188, height: 24)
        .background(Theme.canvas)
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(focused.wrappedValue ? Theme.accent : Theme.border, lineWidth: 1)
        )
    }
}

private struct EmptyState: View {
    @Environment(ScanSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("No folder open")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Folder size is the sum of the files inside.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .padding(.top, 4)
                .padding(.bottom, 12)
            VStack(spacing: 0) {
                ForEach(session.startPoints) { point in
                    Button {
                        session.startScan(point.url)
                    } label: {
                        HStack {
                            Text(point.title)
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Text(point.id == "home" ? "folder" : "volume")
                                .foregroundStyle(Theme.secondary)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(Theme.border).frame(height: 1)
                }
                Button {
                    session.chooseFolder()
                } label: {
                    HStack {
                        Text("Choose Folder…")
                            .foregroundStyle(Theme.accent)
                        Spacer()
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(Theme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .frame(width: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MessageState: View {
    var title: String
    var detail: String

    @Environment(ScanSession.self) private var session

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 8) {
                if session.rootURL != nil, session.phase != .missing {
                    Button("Scan") { session.rescan() }
                        .buttonStyle(QuietButtonStyle())
                }
                Button("Choose") { session.chooseFolder() }
                    .buttonStyle(QuietButtonStyle(prominent: true))
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
