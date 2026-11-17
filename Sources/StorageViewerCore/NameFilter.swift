import Foundation

public enum NameFilter {
    public struct Row {
        public var node: FileNode
        public var depth: Int
        public var parentSize: Int64
    }

    public static func matches(name: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return nameContains(name, query: trimmed)
    }

    /// Rows for the list. An empty query follows `expanded`. A query keeps a folder when any nested name matches, and shows that chain even if the folder is collapsed.
    public static func listedRows(
        children: [FileNode],
        expanded: Set<UUID>,
        query: String,
        parentSize: Int64
    ) -> [Row] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [Row] = []
        if trimmed.isEmpty {
            func walk(_ nodes: [FileNode], depth: Int, parentSize: Int64) {
                for node in nodes {
                    rows.append(Row(node: node, depth: depth, parentSize: parentSize))
                    guard node.isDirectory, expanded.contains(node.id) else { continue }
                    walk(node.children, depth: depth + 1, parentSize: node.byteSize)
                }
            }
            walk(children, depth: 0, parentSize: parentSize)
            return rows
        }

        let visible = hits(in: children, query: trimmed)
        func walk(_ nodes: [FileNode], depth: Int, parentSize: Int64) {
            for node in nodes where visible.contains(node.id) {
                rows.append(Row(node: node, depth: depth, parentSize: parentSize))
                guard node.isDirectory else { continue }
                walk(node.children, depth: depth + 1, parentSize: node.byteSize)
            }
        }
        walk(children, depth: 0, parentSize: parentSize)
        return rows
    }

    /// The node itself, or a nested name, matches `query`. One walk.
    public static func hits(in nodes: [FileNode], query: String) -> Set<UUID> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allIDs(in: nodes) }
        var ids = Set<UUID>()
        func walk(_ node: FileNode) -> Bool {
            var hit = nameContains(node.name, query: trimmed)
            if node.isDirectory {
                for child in node.children where walk(child) {
                    hit = true
                }
            }
            if hit { ids.insert(node.id) }
            return hit
        }
        for node in nodes {
            _ = walk(node)
        }
        return ids
    }

    /// Ids of `nodes` whose own name or any nested name matches `query`.
    /// Stops descending a folder as soon as its name matches, so a map only
    /// needs to know which blocks to keep bright, not every name below them.
    public static func folderHits(in nodes: [FileNode], query: String) -> Set<UUID> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Set(nodes.map(\.id)) }
        var ids = Set<UUID>()
        for node in nodes where subtreeMatches(node, query: trimmed) {
            ids.insert(node.id)
        }
        return ids
    }

    private static func subtreeMatches(_ node: FileNode, query: String) -> Bool {
        if nameContains(node.name, query: query) { return true }
        guard node.isDirectory else { return false }
        return node.children.contains { subtreeMatches($0, query: query) }
    }

    private static func allIDs(in nodes: [FileNode]) -> Set<UUID> {
        var ids = Set<UUID>()
        func walk(_ node: FileNode) {
            ids.insert(node.id)
            for child in node.children { walk(child) }
        }
        for node in nodes { walk(node) }
        return ids
    }

    private static func nameContains(_ name: String, query: String) -> Bool {
        name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
