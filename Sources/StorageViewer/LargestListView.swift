import StorageViewerCore
import SwiftUI

struct LargestListView: View {
    var root: FileNode
    var expanded: Set<UUID>
    var rootSize: Int64
    var filter: String
    var selection: UUID?
    var scrollToken: Int
    var revision: Int
    var onSelect: (UUID) -> Void
    var onToggle: (FileNode) -> Void

    @State private var hovered: UUID?

    var body: some View {
        let _ = revision
        let listed = NameFilter.listedRows(
            children: root.children,
            expanded: expanded,
            query: filter,
            parentSize: root.byteSize
        )
        let rows = displayRows(listed)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Contents")
                Spacer()
                Text(headerCount(listed))
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

            if rows.isEmpty {
                Text(root.children.isEmpty ? "This folder is empty." : "No matching names.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                rowView(row)
                                    .id(row.id)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .onChange(of: scrollToken) { _, _ in
                        guard let selection else { return }
                        withAnimation(.easeOut(duration: 0.22)) {
                            proxy.scrollTo(selection.uuidString, anchor: .top)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("largest-list")
    }

    private func headerCount(_ listed: [NameFilter.Row]) -> String {
        let total = root.children.count
        if filterIsEmpty {
            return "\(total)"
        }
        let matched = listed.filter { $0.depth == 0 }.count
        return "\(matched) of \(total)"
    }

    private func displayRows(_ listed: [NameFilter.Row]) -> [TreeRow] {
        var rows: [TreeRow] = []
        for row in listed {
            rows.append(TreeRow(kind: .node(row.node), depth: row.depth, parentSize: row.parentSize))
            if filterIsEmpty, row.node.isDirectory, row.node.children.isEmpty, expanded.contains(row.node.id) {
                rows.append(TreeRow(kind: .empty(row.node.id), depth: row.depth + 1, parentSize: row.node.byteSize))
            }
        }
        return rows
    }

    private var filterIsEmpty: Bool {
        filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    private func rowView(_ row: TreeRow) -> some View {
        switch row.kind {
        case .empty:
            Text("Empty")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 28 + CGFloat(row.depth) * 14)
                .frame(height: 26)
        case .node(let node):
            nodeRow(node, depth: row.depth, parentSize: row.parentSize)
        }
    }

    private func nodeRow(_ node: FileNode, depth: Int, parentSize: Int64) -> some View {
        let selected = selection == node.id
        let isOpen = expanded.contains(node.id)
        return HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * 14)
            Circle()
                .fill(selected ? Theme.onSelection : Theme.color(for: node.category))
                .frame(width: 7, height: 7)
            Text(node.name)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.onSelection : Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if node.isDirectory {
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
            Text(ByteFormat.bytes(node.byteSize))
                .font(.system(size: 12))
                .foregroundStyle(selected ? Theme.onSelection : Theme.text)
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
            Text(ByteFormat.percent(node.byteSize, of: parentSize))
                .font(.system(size: 12))
                .foregroundStyle(selected ? Theme.onSelection : Theme.secondary)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
            Text(ByteFormat.percent(node.byteSize, of: rootSize))
                .font(.system(size: 12))
                .foregroundStyle(selected ? Theme.onSelection : Theme.secondary)
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .frame(height: 26)
        .background(selected ? Theme.selection : (hovered == node.id ? Color.white.opacity(0.04) : Color.clear))
        .contentShape(Rectangle())
        .onHover { inside in
            hovered = inside ? node.id : (hovered == node.id ? nil : hovered)
        }
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onSelect(node.id) }
        }
        .contextMenu { ItemMenu(node: node) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(node.name), \(ByteFormat.bytes(node.byteSize)), \(ByteFormat.percent(node.byteSize, of: parentSize)) of folder, \(ByteFormat.percent(node.byteSize, of: rootSize)) of root")
    }
}

private struct TreeRow: Identifiable {
    enum Kind {
        case node(FileNode)
        case empty(UUID)
    }

    var kind: Kind
    var depth: Int
    var parentSize: Int64

    var id: String {
        switch kind {
        case .node(let node):
            return node.id.uuidString
        case .empty(let parent):
            return "empty-\(parent.uuidString)"
        }
    }
}
