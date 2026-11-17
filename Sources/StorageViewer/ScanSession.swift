import AppKit
import Observation
import StorageViewerCore
import SwiftUI

struct StartPoint: Identifiable, Equatable {
    var id: String
    var title: String
    var url: URL
}

@MainActor
@Observable
final class ScanSession {
    var phase: Phase = .empty
    var root: FileNode?
    var rootURL: URL?
    var rootTitle = "Open"
    var filesSeen = 0
    var bytesCounted: Int64 = 0
    var skippedCount = 0
    var navigation: [UUID] = []
    var expanded: Set<UUID> = []
    var selection: UUID?
    var hoveredID: UUID?
    var filter = ""
    var listScrollToken = 0
    var focusFilterTick = 0
    var startPoints: [StartPoint] = []
    var copiedNode: FileNode?
    var treeRevision = 0
    var renameTarget: FileNode?
    var treeError: String?

    private var readyFile: String?

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    private var history = FolderHistory<BrowsePlace>()
    private var generation = 0
    private var cancelFlag = CancellationFlag()
    private var didConsumeLaunch = false

    enum Phase: Equatable {
        case empty
        case scanning
        case ready
        case cancelled
        case permissionDenied
        case missing
    }

    init() {
        startPoints = Self.makeStartPoints()
    }

    var canGoUp: Bool { chain.count > 1 }

    var chain: [FileNode] {
        guard let root else { return [] }
        var nodes = [root]
        var current = root
        for id in navigation.dropFirst() {
            guard let next = current.children.first(where: { $0.id == id }) else { break }
            nodes.append(next)
            current = next
        }
        return nodes
    }

    var current: FileNode? { chain.last }

    var statusLine: String {
        var parts = ["\(ByteFormat.count(filesSeen)) files", ByteFormat.bytes(bytesCounted)]
        if skippedCount > 0 {
            parts.append("\(ByteFormat.count(skippedCount)) unreadable")
        }
        return parts.joined(separator: "  ·  ")
    }

    func consumeLaunchArgumentsIfNeeded() {
        guard !didConsumeLaunch else { return }
        didConsumeLaunch = true
        let args = CommandLine.arguments
        readyFile = value(after: "--ready-file", in: args)
        if let path = value(after: "--scan", in: args) {
            startScan(URL(fileURLWithPath: path))
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to measure"
        panel.directoryURL = rootURL ?? FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startScan(url)
    }

    func rescan() {
        guard let rootURL else { return }
        startScan(rootURL)
    }

    func startScan(_ url: URL) {
        cancelFlag.cancel()
        let flag = CancellationFlag()
        cancelFlag = flag
        generation += 1
        let generation = generation
        let displayName = Self.displayName(for: url)

        phase = .scanning
        root = nil
        rootURL = url
        rootTitle = displayName
        navigation = []
        expanded = []
        selection = nil
        hoveredID = nil
        hoveredNode = nil
        copiedNode = nil
        renameTarget = nil
        filesSeen = 0
        bytesCounted = 0
        skippedCount = 0
        history.clear()
        startPoints = Self.makeStartPoints()

        let pipe = ProgressPipe { [weak self] progress in
            guard let self, self.generation == generation else { return }
            self.filesSeen = progress.filesSeen
            self.bytesCounted = progress.bytesCounted
            self.skippedCount = progress.skippedCount
        }

        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                DirectoryScanner.scan(
                    url: url,
                    displayName: displayName,
                    progress: { pipe.send($0) },
                    isCancelled: { flag.isCancelled }
                )
            }.value
            guard self.generation == generation else { return }
            self.apply(outcome)
        }
    }

    func cancel() {
        guard phase == .scanning else { return }
        cancelFlag.cancel()
    }

    static let browse = Animation.spring(response: 0.46, dampingFraction: 0.9)

    func goBack() {
        guard let restored = history.back() else { return }
        show(restored)
    }

    func goForward() {
        guard let restored = history.forward() else { return }
        show(restored)
    }

    func goUp() {
        let nodes = chain
        guard nodes.count > 1 else { return }
        let previous = navigation
        withAnimation(Self.browse) {
            if let leaving = nodes.last {
                expanded.remove(leaving.id)
            }
            navigation = nodes.dropLast().map(\.id)
            selection = nil
            hoveredID = nil
            noteNavigation(from: previous)
        }
    }

    func reveal(index: Int) {
        let nodes = chain
        guard index >= 0, index < nodes.count else { return }
        let previous = navigation
        withAnimation(Self.browse) {
            for node in nodes.dropFirst(index + 1) {
                expanded.remove(node.id)
            }
            navigation = nodes.prefix(index + 1).map(\.id)
            selection = nil
            hoveredID = nil
            noteNavigation(from: previous)
        }
    }

    func zoom(_ node: FileNode) {
        guard node.isDirectory, !node.isMount else {
            selectFromMap(node.id)
            return
        }
        let path = node.pathFromRoot()
        let previous = navigation
        withAnimation(Self.browse) {
            for folder in path where folder.isDirectory {
                expanded.insert(folder.id)
            }
            navigation = path.map(\.id)
            selection = node.id
            hoveredID = nil
            hoveredNode = nil
            listScrollToken += 1
            noteNavigation(from: previous)
        }
    }

    func toggleDisclosure(_ node: FileNode) {
        guard node.isDirectory, !node.isMount else { return }
        let previous = navigation
        withAnimation(Self.browse) {
            if expanded.contains(node.id) {
                expanded.remove(node.id)
                if currentIsInside(node.id), let parent = node.parent {
                    navigation = parent.pathFromRoot().map(\.id)
                }
            } else {
                let path = node.pathFromRoot()
                for folder in path where folder.isDirectory {
                    expanded.insert(folder.id)
                }
                navigation = path.map(\.id)
                selection = node.id
                listScrollToken += 1
            }
            hoveredID = nil
            hoveredNode = nil
            noteNavigation(from: previous)
        }
    }

    func selectFromList(_ id: UUID) {
        selection = id
    }

    func selectFromMap(_ id: UUID) {
        selection = id
        listScrollToken += 1
    }

    func hover(_ node: FileNode?) {
        hoveredID = node?.id
        hoveredNode = node
    }

    func canPaste(onto node: FileNode) -> Bool {
        guard let copiedNode else { return false }
        return TreeEditor.canPaste(copiedNode, onto: node)
    }

    func openItem(_ node: FileNode) {
        guard let rootURL else { return }
        let url = TreeEditor.url(of: node, rootURL: rootURL)
        if !NSWorkspace.shared.open(url) {
            treeError = "macOS didn’t open “\(node.name)”."
        }
    }

    func revealInFinder(_ node: FileNode) {
        guard let rootURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([TreeEditor.url(of: node, rootURL: rootURL)])
    }

    func rememberCopy(_ node: FileNode) {
        copiedNode = node
    }

    func beginRename(_ node: FileNode) {
        renameTarget = node
    }

    func commitRename(_ node: FileNode, to name: String) {
        perform {
            try TreeEditor.rename(node, to: name, rootURL: try requireRootURL())
            refreshTree()
        }
    }

    func paste(onto node: FileNode) {
        guard let copiedNode else { return }
        copy {
            try TreeEditor.preparePaste(copiedNode, onto: node, rootURL: try self.requireRootURL())
        }
    }

    func duplicate(_ node: FileNode) {
        copy {
            try TreeEditor.prepareDuplicate(node, rootURL: try self.requireRootURL())
        }
    }

    /// The copy and the scan of the result can take a while, so they run off the main actor.
    private func copy(_ prepare: @escaping @MainActor () throws -> TreeEditor.CopyWork) {
        let generation = generation
        Task { @MainActor in
            do {
                let work = try prepare()
                let created = try await Task.detached(priority: .userInitiated) {
                    try TreeEditor.performCopy(work)
                }.value
                guard self.generation == generation else { return }
                TreeEditor.attachCopy(created, to: work)
                revealCreated(created)
            } catch {
                treeError = error.localizedDescription
            }
        }
    }

    func confirmTrash(_ node: FileNode) {
        let alert = NSAlert()
        alert.messageText = "Move “\(node.name)” to the Trash?"
        alert.informativeText = "You can put it back from the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let zoomedInside = chain.contains { $0.id == node.id }
        let fallback = node.parent?.pathFromRoot().map(\.id) ?? []
        let dropCopy = copiedNode.map { node.contains($0) } ?? false
        let previous = navigation
        perform {
            try TreeEditor.trash(node, rootURL: try requireRootURL())
            if dropCopy { copiedNode = nil }
            if zoomedInside, let root {
                navigation = fallback.isEmpty ? [root.id] : fallback
            }
            expanded.remove(node.id)
            if selection == node.id { selection = nil }
            refreshTree()
            noteNavigation(from: previous)
        }
    }

    private func revealCreated(_ node: FileNode) {
        if let parent = node.parent { expanded.insert(parent.id) }
        selection = node.id
        listScrollToken += 1
        refreshTree()
    }

    private func refreshTree() {
        guard let root else { return }
        bytesCounted = root.byteSize
        filesSeen = countFiles(root)
        treeRevision += 1
    }

    private func countFiles(_ node: FileNode) -> Int {
        if !node.isDirectory { return 1 }
        return node.children.reduce(0) { $0 + countFiles($1) }
    }

    private func requireRootURL() throws -> URL {
        guard let rootURL else { throw TreeEditError.missingItem }
        return rootURL
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            treeError = error.localizedDescription
        }
    }

    private weak var hoveredNode: FileNode?

    var footerText: String {
        if let node = hoveredNode {
            let kind = node.isDirectory ? "folder" : node.category.rawValue
            return "\(node.name)  ·  \(ByteFormat.bytes(node.byteSize))  ·  \(kind)"
        }
        if let rootURL {
            return rootURL.path
        }
        return "Logical size. Folders add up their contents."
    }

    private func apply(_ outcome: ScanOutcome) {
        filesSeen = outcome.filesSeen
        bytesCounted = outcome.bytesCounted
        skippedCount = outcome.skippedCount
        root = outcome.root
        if let root {
            navigation = [root.id]
        } else {
            navigation = []
        }
        expanded = []
        selection = nil
        hoveredID = nil
        hoveredNode = nil
        if root != nil {
            history.reset(to: place)
        } else {
            history.clear()
        }
        if outcome.cancelled {
            phase = .cancelled
        } else if outcome.missing {
            phase = .missing
        } else if outcome.rootDenied || outcome.root == nil {
            phase = .permissionDenied
        } else {
            phase = .ready
        }
        writeReadyFile(outcome)
    }

    private func writeReadyFile(_ outcome: ScanOutcome) {
        guard let readyFile else { return }
        var lines: [String] = []
        let phaseName: String
        switch phase {
        case .ready: phaseName = "ready"
        case .cancelled: phaseName = "cancelled"
        case .permissionDenied: phaseName = "permissionDenied"
        case .missing: phaseName = "missing"
        case .empty: phaseName = "empty"
        case .scanning: phaseName = "scanning"
        }
        lines.append("phase\t\(phaseName)")
        lines.append("files\t\(outcome.filesSeen)")
        lines.append("bytes\t\(outcome.bytesCounted)")
        lines.append("skipped\t\(outcome.skippedCount)")
        if let root = outcome.root {
            lines.append("root\t\(root.byteSize)\t\(sanitized(root.name))")
            for child in root.children {
                let kind = child.isDirectory ? "dir" : "file"
                lines.append("child\t\(child.byteSize)\t\(kind)\t\(child.category.rawValue)\t\(sanitized(child.name))")
            }
        }
        let data = lines.joined(separator: "\n").appending("\n").data(using: .utf8)
        try? data?.write(to: URL(fileURLWithPath: readyFile), options: .atomic)
    }

    private struct BrowsePlace: Equatable {
        var path: [UUID]
        var expanded: Set<UUID>
        var selection: UUID?
    }

    private var place: BrowsePlace {
        BrowsePlace(path: navigation, expanded: expanded, selection: selection)
    }

    private func noteNavigation(from previous: [UUID]) {
        guard navigation != previous else { return }
        history.push(place)
    }

    private func show(_ place: BrowsePlace) {
        withAnimation(Self.browse) {
            navigation = place.path
            expanded = place.expanded
            selection = place.selection
            hoveredID = nil
            hoveredNode = nil
            listScrollToken += 1
        }
    }

    private func currentIsInside(_ id: UUID) -> Bool {
        var cursor = current
        while let node = cursor {
            if node.id == id { return true }
            cursor = node.parent
        }
        return false
    }

    private func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static func displayName(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        if url.standardizedFileURL.path == home.path { return "Home" }
        if let values = try? url.resourceValues(forKeys: [.isVolumeKey, .volumeNameKey]),
           values.isVolume == true,
           let name = values.volumeName,
           !name.isEmpty {
            return name
        }
        let last = url.lastPathComponent
        if !last.isEmpty { return last }
        return (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Volume"
    }

    private static func makeStartPoints() -> [StartPoint] {
        var points = [
            StartPoint(
                id: "home",
                title: "Home",
                url: FileManager.default.homeDirectoryForCurrentUser
            )
        ]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        for volume in volumes {
            let name = (try? volume.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? ""
            let title = name.isEmpty ? (volume.lastPathComponent.isEmpty ? "Volume" : volume.lastPathComponent) : name
            points.append(StartPoint(id: volume.path, title: title, url: volume))
        }
        return points
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class ProgressPipe: @unchecked Sendable {
    private let handler: @MainActor (ScanProgress) -> Void

    init(handler: @escaping @MainActor (ScanProgress) -> Void) {
        self.handler = handler
    }

    func send(_ progress: ScanProgress) {
        let handler = handler
        Task { @MainActor in
            handler(progress)
        }
    }
}
