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
        return name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
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
        var ids = Set<UUID>()
        func walk(_ node: FileNode) -> Bool {
            var hit = matches(name: node.name, query: query)
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
}
