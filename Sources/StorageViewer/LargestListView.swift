import StorageViewerCore
import SwiftUI

struct LargestListView: View {
    var root: FileNode
    var expanded: Set<UUID>
    var filter: String
    var selection: UUID?
    var scrollToken: Int
    var revision: Int
    var onSelect: (FileNode) -> Void
    var onToggle: (FileNode) -> Void

    @State private var cache = RowCache()

    var body: some View {
        let computed = cache.rows(root: root, revision: revision, expanded: expanded, filter: filter)
        let rootSize = root.byteSize

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Contents")
                Spacer()
                Text(headerCount(matchedTopLevel: computed.matchedTopLevel, filtered: computed.isFiltered))
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 10)
            .frame(height: 28)

            Rectangle().fill(Theme.border).frame(height: 1)

            header
                .padding(.horizontal, 10)
                .frame(height: 22)

            Rectangle().fill(Theme.border).frame(height: 1)

            if computed.rows.isEmpty {
                Text(root.children.isEmpty ? "This folder is empty." : "No matching names.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(computed.rows) { row in
                                rowView(row, rootSize: rootSize, autoExpanded: computed.autoExpanded)
                                    .id(row.id)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .onChange(of: scrollToken) { _, _ in
                        guard let selection else { return }
                        withAnimation(.easeOut(duration: 0.22)) {
                            proxy.scrollTo(TreeRow.RowID.node(selection), anchor: .top)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("largest-list")
    }

    private func headerCount(matchedTopLevel: Int, filtered: Bool) -> String {
        let total = ByteFormat.count(root.children.count)
        guard filtered else { return total }
        return "\(ByteFormat.count(matchedTopLevel)) of \(total)"
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Size")
                .frame(width: 72, alignment: .trailing)
                .help("Logical size")
            Text("Folder")
                .frame(width: 58, alignment: .trailing)
                .help("Percent of the enclosing folder")
            Text("Root")
                .frame(width: 52, alignment: .trailing)
                .help("Percent of the scanned folder")
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.secondary)
    }

    @ViewBuilder
    private func rowView(_ row: TreeRow, rootSize: Int64, autoExpanded: Set<UUID>) -> some View {
        switch row.kind {
        case .empty:
            Text("Empty")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 23 + CGFloat(row.depth) * 14)
                .frame(height: 26)
        case .node(let node):
            NodeRowView(
                node: node,
                depth: row.depth,
                parentSize: row.parentSize,
                rootSize: rootSize,
                selected: selection == node.id,
                isOpen: expanded.contains(node.id) || autoExpanded.contains(node.id),
                onSelect: onSelect,
                onToggle: onToggle
            )
        }
    }
}

private struct NodeRowView: View {
    var node: FileNode
    var depth: Int
    var parentSize: Int64
    var rootSize: Int64
    var selected: Bool
    var isOpen: Bool
    var onSelect: (FileNode) -> Void
    var onToggle: (FileNode) -> Void

    @State private var isHovered = false

    var body: some View {
        let sizeText = ByteFormat.bytes(node.byteSize)
        let folderPercent = ByteFormat.percent(node.byteSize, of: parentSize)
        let rootPercent = ByteFormat.percent(node.byteSize, of: rootSize)

        HStack(spacing: 6) {
            Circle()
                .fill(selected ? Theme.onSelection : Theme.color(for: node.category))
                .frame(width: 7, height: 7)
                .padding(.leading, CGFloat(depth) * 14)
            Text(node.name)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.onSelection : Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if node.isDirectory, !node.isMount {
                Button {
                    onToggle(node)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(selected ? Theme.onSelection : (isOpen ? Theme.text : Theme.secondary))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isOpen ? "Collapse \(node.name)" : "Expand \(node.name)")
                .help(isOpen ? "Collapse" : "Show contents")
            } else {
                Color.clear.frame(width: 18, height: 22)
            }
            Text(sizeText)
                .font(.system(size: 12))
                .foregroundStyle(selected ? Theme.onSelection : Theme.text)
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
            Text(folderPercent)
                .font(.system(size: 12))
                .foregroundStyle(selected ? Theme.onSelection : Theme.secondary)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
            Text(rootPercent)
                .font(.system(size: 12))
                .foregroundStyle(selected ? Theme.onSelection : Theme.secondary)
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(selected ? Theme.selection : (isHovered ? Color.white.opacity(0.04) : Color.clear))
        .contentShape(Rectangle())
        .onHover { inside in
            isHovered = inside
        }
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onSelect(node) }
        }
        .contextMenu { ItemMenu(node: node) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(node.name), \(sizeText), \(folderPercent) of folder, \(rootPercent) of root")
    }
}

private struct TreeRow: Identifiable {
    enum RowID: Hashable {
        case node(UUID)
        case empty(UUID)
    }

    enum Kind {
        case node(FileNode)
        case empty(UUID)
    }

    var kind: Kind
    var depth: Int
    var parentSize: Int64

    var id: RowID {
        switch kind {
        case .node(let node):
            return .node(node.id)
        case .empty(let parent):
            return .empty(parent)
        }
    }
}

private final class RowCache {
    struct Key: Equatable {
        var rootID: UUID
        var revision: Int
        var expanded: Set<UUID>
        var filter: String
    }

    struct Snapshot {
        var rows: [TreeRow]
        var matchedTopLevel: Int
        var isFiltered: Bool
        var autoExpanded: Set<UUID>
    }

    private var key: Key?
    private var snapshot = Snapshot(rows: [], matchedTopLevel: 0, isFiltered: false, autoExpanded: [])

    func rows(root: FileNode, revision: Int, expanded: Set<UUID>, filter: String) -> Snapshot {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextKey = Key(rootID: root.id, revision: revision, expanded: expanded, filter: trimmed)
        if nextKey == key { return snapshot }

        let isFiltered = !trimmed.isEmpty
        let listed = NameFilter.listedRows(
            children: root.children,
            expanded: expanded,
            query: trimmed,
            parentSize: root.byteSize
        )

        var display: [TreeRow] = []
        display.reserveCapacity(listed.count)
        var matchedTopLevel = 0
        var autoExpanded: Set<UUID> = []

        for index in listed.indices {
            let row = listed[index]
            if row.depth == 0 {
                matchedTopLevel += 1
            }
            display.append(TreeRow(kind: .node(row.node), depth: row.depth, parentSize: row.parentSize))
            if isFiltered {
                if row.node.isDirectory, index + 1 < listed.count, listed[index + 1].depth > row.depth {
                    autoExpanded.insert(row.node.id)
                }
            } else if row.node.isDirectory, row.node.children.isEmpty, expanded.contains(row.node.id) {
                display.append(TreeRow(kind: .empty(row.node.id), depth: row.depth + 1, parentSize: row.node.byteSize))
            }
        }

        key = nextKey
        snapshot = Snapshot(
            rows: display,
            matchedTopLevel: matchedTopLevel,
            isFiltered: isFiltered,
            autoExpanded: autoExpanded
        )
        return snapshot
    }
}
