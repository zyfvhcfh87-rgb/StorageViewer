import Foundation

public enum NameFilter {
    public struct Row {
        public var node: FileNode
        public var depth: Int
        public var parentSize: Int64

        public init(node: FileNode, depth: Int, parentSize: Int64) {
            self.node = node
            self.depth = depth
            self.parentSize = parentSize
        }
    }

    public static func matches(name: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return Matcher(trimmed: trimmed).matches(name)
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
            rows.reserveCapacity(children.count)
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

        let visible = hits(in: children, trimmedQuery: trimmed)
        rows.reserveCapacity(visible.count)
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
        return hits(in: nodes, trimmedQuery: trimmed)
    }

    private static func hits(in nodes: [FileNode], trimmedQuery: String) -> Set<UUID> {
        var ids = Set<UUID>()
        if trimmedQuery.isEmpty {
            func collectAll(_ node: FileNode) {
                ids.insert(node.id)
                if node.isDirectory {
                    for child in node.children {
                        collectAll(child)
                    }
                }
            }
            for node in nodes { collectAll(node) }
            return ids
        }

        let matcher = Matcher(trimmed: trimmedQuery)
        func walk(_ node: FileNode) -> Bool {
            var hit = matcher.matches(node.name)
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
        let matcher = Matcher(trimmed: trimmed)
        func subtreeMatches(_ node: FileNode) -> Bool {
            if matcher.matches(node.name) { return true }
            guard node.isDirectory else { return false }
            return node.children.contains { subtreeMatches($0) }
        }
        var ids = Set<UUID>()
        for node in nodes where subtreeMatches(node) {
            ids.insert(node.id)
        }
        return ids
    }

    /// Pre-lowercased ASCII needle for fast substring checks without ICU bridging,
    /// falling back to Unicode case + diacritic-insensitive search for non-ASCII strings.
    private struct Matcher {
        let original: String
        let asciiNeedle: [UInt8]?

        init(trimmed: String) {
            self.original = trimmed
            var bytes: [UInt8] = []
            bytes.reserveCapacity(trimmed.utf8.count)
            var isPrintableASCII = true
            for byte in trimmed.utf8 {
                if byte < 0x20 || byte > 0x7E {
                    isPrintableASCII = false
                    break
                }
                bytes.append((byte >= 0x41 && byte <= 0x5A) ? (byte &+ 32) : byte)
            }
            self.asciiNeedle = isPrintableASCII ? bytes : nil
        }

        func matches(_ name: String) -> Bool {
            guard let needle = asciiNeedle else {
                return name.range(of: original, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            let needleCount = needle.count
            guard needleCount > 0 else { return true }

            // Check if name is printable ASCII; if not, fall back so diacritic-insensitive matching works (e.g. "cafe" matches "café").
            // `withUTF8` handles both inline small strings and heap-backed strings without allocating.
            var copy = name
            let fastResult: Bool? = copy.withUTF8 { hay in
                for byte in hay where byte < 0x20 || byte > 0x7E {
                    return nil
                }
                let hayCount = hay.count
                guard hayCount >= needleCount else { return false }
                let first = needle[0]
                let limit = hayCount - needleCount
                var i = 0
                while i <= limit {
                    var b = hay[i]
                    if b >= 0x41 && b <= 0x5A { b &+= 32 }
                    if b == first {
                        var j = 1
                        while j < needleCount {
                            var hb = hay[i + j]
                            if hb >= 0x41 && hb <= 0x5A { hb &+= 32 }
                            if hb != needle[j] { break }
                            j += 1
                        }
                        if j == needleCount { return true }
                    }
                    i += 1
                }
                return false
            }

            if let fastResult {
                return fastResult
            }
            return name.range(of: original, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
