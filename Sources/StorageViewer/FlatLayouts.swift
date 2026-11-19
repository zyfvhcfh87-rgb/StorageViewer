import StorageViewerCore
import SwiftUI

/// The four Coss arrangements. Foundation is the default. The raw value is what the next launch reads.
enum FlatLayout: String, CaseIterable, Identifiable {
    case foundation
    case products
    case ledger
    case prompt

    static let storageKey = "storageviewer.flatLayout"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .foundation: "Foundation"
        case .products: "Products"
        case .ledger: "Ledger"
        case .prompt: "Prompt"
        }
    }
}

struct LayoutPicker: View {
    @Binding var layout: FlatLayout

    var body: some View {
        Picker("Layout", selection: $layout) {
            ForEach(FlatLayout.allCases) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 300)
        .accessibilityIdentifier("layout-picker")
        .accessibilityLabel("Layout")
        .accessibilityValue(layout.title)
        .help("Layout")
    }
}

struct CossArrangement<Map: View, List: View>: View {
    @Environment(ScanSession.self) private var session
    var layout: FlatLayout
    @ViewBuilder var map: () -> Map
    @ViewBuilder var list: () -> List

    var body: some View {
        let _ = session.treeRevision
        let facts = makeFacts()
        Group {
            switch layout {
            case .foundation:
                FoundationScreen(facts: facts, map: map, list: list)
            case .products:
                ProductsScreen(facts: facts, map: map)
            case .ledger:
                LedgerScreen(facts: facts, map: map, list: list)
            case .prompt:
                PromptScreen(facts: facts, map: map) { node in
                    if session.selection == node.id, node.isDirectory {
                        session.zoom(node)
                    } else {
                        session.selectFromMap(node)
                    }
                }
            }
        }
        .accessibilityIdentifier("flat-layout")
        .accessibilityValue(layout.rawValue)
    }

    private func makeFacts() -> CossFacts {
        guard let current = session.current, let root = session.root else {
            return .empty
        }
        return CossFacts(
            current: current,
            root: root,
            selected: session.selectedNode,
            skipped: session.skippedCount,
            path: session.chain.map(\.name).joined(separator: " / "),
            includeLines: layout == .prompt
        )
    }
}

private struct PromptLine: Identifiable {
    var node: FileNode
    var size: String
    var share: String
    var hot: Bool

    var id: UUID { node.id }
    var name: String { node.name }
}

private struct CossFacts {
    var headline: String
    var sentence: String
    var note: String
    var specs: [(label: String, value: String)]
    var counted: String
    var childCount: String
    var itemsLabel: String
    var largest: String
    var skipped: String
    var caption: String
    var windowTitle: String
    var path: String
    var command: String
    var lines: [PromptLine]

    static let empty = CossFacts()

    private init() {
        headline = "—"
        sentence = "No folder open."
        note = ""
        specs = []
        counted = "—"
        childCount = "0"
        itemsLabel = "0 items"
        largest = "—"
        skipped = "0"
        caption = ""
        windowTitle = "StorageViewer"
        path = ""
        command = ""
        lines = []
    }

    init(
        current: FileNode,
        root: FileNode,
        selected: FileNode?,
        skipped: Int,
        path: String,
        includeLines: Bool
    ) {
        let subject = selected ?? current
        let parentSize = subject.parent?.byteSize ?? subject.byteSize
        let share = ByteFormat.percent(subject.byteSize, of: parentSize)
        let children = current.children
        let countText = ByteFormat.count(children.count)
        let itemsText = children.count == 1 ? "1 item" : "\(countText) items"

        headline = ByteFormat.bytes(current.byteSize)
        if let selected, selected.id != current.id {
            let of = selected.parent?.name ?? current.name
            sentence = "\(selected.name) is \(ByteFormat.bytes(selected.byteSize)), \(share) of \(of)."
            note = "\(selected.category.displayName) in \(of)."
        } else {
            sentence = "\(itemsText) in \(current.name)."
            note = "Folder size is the sum of the files inside."
        }
        specs = [
            ("Name", subject.name),
            ("Size", ByteFormat.bytes(subject.byteSize)),
            ("Share", share),
            ("Kind", subject.category.displayName)
        ]
        counted = ByteFormat.bytes(root.byteSize)
        childCount = countText
        itemsLabel = itemsText
        largest = children.first?.name ?? "—"
        self.skipped = ByteFormat.count(skipped)
        caption = "\(subject.name)  ·  \(ByteFormat.bytes(subject.byteSize))  ·  \(share)"
        windowTitle = current.name
        self.path = path
        command = subject.name

        if includeLines {
            let focus = children.firstIndex { $0.id == subject.id } ?? 0
            let start = max(0, min(focus - 3, children.count - 8))
            let window = children.dropFirst(start).prefix(8)
            lines = window.map { node in
                let parent = node.parent?.byteSize ?? current.byteSize
                return PromptLine(
                    node: node,
                    size: ByteFormat.bytes(node.byteSize),
                    share: ByteFormat.percent(node.byteSize, of: parent),
                    hot: node.id == subject.id && selected != nil
                )
            }
        } else {
            lines = []
        }
    }
}

private enum CossChrome {
    static let card = Color(red: 0x17 / 255, green: 0x17 / 255, blue: 0x17 / 255)
    static let well = Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255)
    static let display = "Avenir Next"

    static func displayFont(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom(display, size: size).weight(weight)
    }
}

private struct SpecList: View {
    var rows: [(label: String, value: String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.label)
                        .foregroundStyle(Theme.secondary)
                    Spacer(minLength: 12)
                    Text(row.value)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1)
                }
                .padding(.vertical, 9)
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.border).frame(height: 1)
                }
            }
        }
    }
}

private struct FoundationScreen<Map: View, List: View>: View {
    private enum Pane {
        case map
        case log
    }

    var facts: CossFacts
    @ViewBuilder var map: () -> Map
    @ViewBuilder var list: () -> List

    @State private var pane: Pane = .map

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("THIS FOLDER")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(Theme.secondary)
                Text(facts.headline + ".")
                    .font(CossChrome.displayFont(46))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .padding(.top, 12)
                Text(facts.sentence)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                Text(facts.note)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                Spacer(minLength: 16)
                SpecList(rows: facts.specs)
            }
            .padding(.init(top: 28, leading: 26, bottom: 22, trailing: 22))
            .frame(width: 312)

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    chip("Map", selected: pane == .map) { pane = .map }
                    chip("Log", selected: pane == .log) { pane = .log }
                    Spacer()
                    Text(facts.itemsLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 46)
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(spacing: 0) {
                    if pane == .map {
                        map()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(CossChrome.well)
                        Rectangle().fill(Theme.border).frame(width: 1)
                        list()
                            .frame(width: 360)
                            .background(Theme.panel)
                    } else {
                        list()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Theme.panel)
                    }
                }
            }
            .background(CossChrome.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .padding(.init(top: 16, leading: 0, bottom: 16, trailing: 16))
        }
        .accessibilityIdentifier("coss-foundation")
        .accessibilityLabel("Foundation")
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.text : Theme.secondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(selected ? Theme.press : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ProductsScreen<Map: View>: View {
    var facts: CossFacts
    @ViewBuilder var map: () -> Map

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Folders.")
                        .font(CossChrome.displayFont(28))
                        .foregroundStyle(Theme.text)
                    Text("Area is the byte size. Amber marks the selection.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(facts.counted)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.text)
                    Text(facts.itemsLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.init(top: 22, leading: 22, bottom: 14, trailing: 22))
            map()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CossChrome.well)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )
                .padding(.init(top: 0, leading: 16, bottom: 16, trailing: 16))
        }
        .accessibilityIdentifier("coss-products")
        .accessibilityLabel("Products")
    }
}

private struct LedgerScreen<Map: View, List: View>: View {
    var facts: CossFacts
    @ViewBuilder var map: () -> Map
    @ViewBuilder var list: () -> List

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                stat("Counted", facts.counted, leadingBorder: false)
                stat("Items", facts.childCount, leadingBorder: true)
                stat("Largest", facts.largest, leadingBorder: true)
                stat("Skipped", facts.skipped, leadingBorder: true)
            }
            .background(CossChrome.card)
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 0) {
                list()
                    .frame(width: 420)
                    .background(Theme.panel)
                Rectangle().fill(Theme.border).frame(width: 1)
                VStack(spacing: 0) {
                    Text(facts.caption)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                    Rectangle().fill(Theme.border).frame(height: 1)
                    map()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(CossChrome.well)
            }
        }
        .accessibilityIdentifier("coss-ledger")
        .accessibilityLabel("Ledger")
    }

    private func stat(_ label: String, _ value: String, leadingBorder: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Theme.secondary)
            Text(value)
                .font(CossChrome.displayFont(22))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if leadingBorder {
                Rectangle().fill(Theme.border).frame(width: 1)
            }
        }
    }
}

private struct PromptScreen<Map: View>: View {
    var facts: CossFacts
    @ViewBuilder var map: () -> Map
    var onActivateLine: (FileNode) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                Text("This folder.")
                    .font(CossChrome.displayFont(28))
                    .foregroundStyle(Theme.text)
                Text(facts.note)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                SpecList(rows: promptRows)
                Spacer(minLength: 0)
            }
            .frame(width: 286)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        light(Color(red: 1, green: 0.373, blue: 0.341))
                        light(Color(red: 0.996, green: 0.737, blue: 0.180))
                        light(Color(red: 0.157, green: 0.784, blue: 0.251))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(facts.windowTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text(facts.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(height: 52)
                Rectangle().fill(Theme.border).frame(height: 1)
                map()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CossChrome.well)
                Rectangle().fill(Theme.border).frame(height: 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("›  open \(facts.command)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                    ForEach(facts.lines) { line in
                        Button {
                            onActivateLine(line.node)
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(line.hot ? Theme.selection : Theme.secondary.opacity(0.7))
                                    .frame(width: 6, height: 6)
                                Text(line.name)
                                    .foregroundStyle(line.hot ? Theme.text : Theme.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(line.size)
                                    .foregroundStyle(line.hot ? Theme.text : Theme.secondary)
                                Text(line.share)
                                    .foregroundStyle(Theme.secondary)
                                    .frame(width: 52, alignment: .trailing)
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(spacing: 8) {
                    Text("›")
                        .foregroundStyle(Theme.text)
                    Text(facts.command)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                    Rectangle()
                        .fill(Theme.text.opacity(0.85))
                        .frame(width: 7, height: 14)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 16)
                .frame(height: 36)
            }
            .background(CossChrome.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
        }
        .padding(18)
        .accessibilityIdentifier("coss-prompt")
        .accessibilityLabel("Prompt")
    }

    private var promptRows: [(label: String, value: String)] {
        [
            ("Items", facts.childCount),
            ("Counted", facts.counted)
        ] + facts.specs
    }

    private func light(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 10, height: 10)
    }
}
