import AppKit
import Observation
import os
import StorageViewerCore
import SwiftUI

struct StartPoint: Identifiable, Equatable, Sendable {
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
    private(set) var navigation: [UUID] = []
    private(set) var chain: [FileNode] = []
    var expanded: Set<UUID> = []
    var selection: UUID?
    private(set) var selectedNode: FileNode?
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
    private weak var hoveredNode: FileNode?

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }
    var canGoUp: Bool { chain.count > 1 }
    var current: FileNode? { chain.last }

    private var history = FolderHistory<BrowsePlace>()
    private var generation = 0
    private var cancelFlag = CancellationFlag()
    private var didConsumeLaunch = false

    enum Phase: String, Equatable {
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

    var statusLine: String {
        var parts = ["\(ByteFormat.count(filesSeen)) files", ByteFormat.bytes(bytesCounted)]
        if skippedCount > 0 {
            parts.append("\(ByteFormat.count(skippedCount)) unreadable")
        }
        return parts.joined(separator: "  ·  ")
    }

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
        let switchingFolder = rootURL?.standardizedFileURL != url.standardizedFileURL

        phase = .scanning
        root = nil
        rootURL = url
        rootTitle = displayName
        setChain([])
        expanded = []
        setSelection(nil)
        hover(nil)
        copiedNode = nil
        renameTarget = nil
        treeError = nil
        if switchingFolder {
            filter = ""
        }
        filesSeen = 0
        bytesCounted = 0
        skippedCount = 0
        treeRevision += 1
        history.clear()

        Task {
            let points = await Task.detached(priority: .utility) {
                Self.makeStartPoints()
            }.value
            self.startPoints = points
        }

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
        guard chain.count > 1 else { return }
        let previous = navigation
        withAnimation(Self.browse) {
            if let leaving = chain.last {
                expanded.remove(leaving.id)
            }
            setChain(Array(chain.dropLast()))
            setSelection(nil)
            hover(nil)
            noteNavigation(from: previous)
        }
    }

    func reveal(index: Int) {
        guard index >= 0, index < chain.count else { return }
        let previous = navigation
        withAnimation(Self.browse) {
            for node in chain.dropFirst(index + 1) {
                expanded.remove(node.id)
            }
            setChain(Array(chain.prefix(index + 1)))
            setSelection(nil)
            hover(nil)
            noteNavigation(from: previous)
        }
    }

    func zoom(_ node: FileNode) {
        guard node.isDirectory, !node.isMount else {
            selectFromMap(node)
            return
        }
        let path = node.pathFromRoot()
        let previous = navigation
        withAnimation(Self.browse) {
            for folder in path where folder.isDirectory {
                expanded.insert(folder.id)
            }
            setChain(path)
            setSelection(node)
            hover(nil)
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
                if chain.contains(where: { $0.id == node.id }), let parent = node.parent {
                    setChain(parent.pathFromRoot())
                }
            } else {
                let path = node.pathFromRoot()
                for folder in path where folder.isDirectory {
                    expanded.insert(folder.id)
                }
                setChain(path)
                setSelection(node)
                listScrollToken += 1
            }
            hover(nil)
            noteNavigation(from: previous)
        }
    }

    func selectFromList(_ node: FileNode) {
        setSelection(node)
    }

    func selectFromMap(_ node: FileNode) {
        setSelection(node)
        listScrollToken += 1
    }

    func hover(_ node: FileNode?) {
        hoveredNode = node
        hoveredID = node?.id
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

    /// Renames `node` on disk and in the tree. Returns an error message on failure, or nil on success.
    func commitRename(_ node: FileNode, to name: String) -> String? {
        do {
            try TreeEditor.rename(node, to: name, rootURL: try requireRootURL())
            bumpTree(fileDelta: 0)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func paste(onto node: FileNode) {
        guard let copiedNode else { return }
        do {
            let (folder, plan) = try TreeEditor.preparePaste(copiedNode, onto: node, rootURL: try requireRootURL())
            runCopy(plan, into: folder)
        } catch {
            treeError = error.localizedDescription
        }
    }

    func duplicate(_ node: FileNode) {
        do {
            let (folder, plan) = try TreeEditor.prepareDuplicate(node, rootURL: try requireRootURL())
            runCopy(plan, into: folder)
        } catch {
            treeError = error.localizedDescription
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
        let fallback = node.parent?.pathFromRoot() ?? []
        let dropCopy = copiedNode.map { node.contains($0) } ?? false
        let dropSelection = selectedNode.map { node.contains($0) } ?? (selection == node.id)
        let dropHover = hoveredNode.map { node.contains($0) } ?? (hoveredID == node.id)
        let dropRename = renameTarget.map { node.contains($0) } ?? false
        let removedDirIDs = directoryIDs(in: node)
        let removedFiles = node.fileCount()
        let previous = navigation

        do {
            try TreeEditor.trash(node, rootURL: try requireRootURL())
            if dropCopy { copiedNode = nil }
            if dropSelection { setSelection(nil) }
            if dropHover { hover(nil) }
            if dropRename { renameTarget = nil }
            expanded.subtract(removedDirIDs)
            history.removeAll { place in
                place.path.contains { removedDirIDs.contains($0) }
            }
            if zoomedInside, let root {
                setChain(fallback.isEmpty ? [root] : fallback)
            }
            bumpTree(fileDelta: -removedFiles)
            if history.current?.path != navigation {
                noteNavigation(from: previous)
            }
        } catch {
            treeError = error.localizedDescription
        }
    }

    private func runCopy(_ plan: TreeEditor.CopyPlan, into folder: FileNode) {
        let generation = generation
        Task {
            do {
                let created = try await Task.detached(priority: .userInitiated) {
                    try TreeEditor.executeCopy(plan)
                }.value
                guard self.generation == generation,
                      let root = self.root,
                      folder === root || folder.parent != nil else {
                    return
                }
                TreeEditor.attachCopy(created, to: folder)
                self.expanded.insert(folder.id)
                self.setSelection(created)
                self.listScrollToken += 1
                self.bumpTree(fileDelta: created.fileCount())
            } catch {
                guard self.generation == generation else { return }
                self.treeError = error.localizedDescription
            }
        }
    }

    private func bumpTree(fileDelta: Int) {
        guard let root else { return }
        bytesCounted = root.byteSize
        filesSeen = max(0, filesSeen + fileDelta)
        treeRevision += 1
    }

    private func requireRootURL() throws -> URL {
        guard let rootURL else { throw TreeEditError.missingItem }
        return rootURL
    }

    private func apply(_ outcome: ScanOutcome) {
        filesSeen = outcome.filesSeen
        bytesCounted = outcome.bytesCounted
        skippedCount = outcome.skippedCount
        root = outcome.root
        if let root {
            setChain([root])
        } else {
            setChain([])
        }
        expanded = []
        setSelection(nil)
        hover(nil)
        treeRevision += 1
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
        var lines = [
            "phase\t\(phase.rawValue)",
            "files\t\(outcome.filesSeen)",
            "bytes\t\(outcome.bytesCounted)",
            "skipped\t\(outcome.skippedCount)"
        ]
        if let root = outcome.root {
            lines.append("root\t\(root.byteSize)\t\(sanitized(root.name))")
            for child in root.children {
                let kind = child.isDirectory ? "dir" : "file"
                lines.append("child\t\(child.byteSize)\t\(kind)\t\(child.category.rawValue)\t\(sanitized(child.name))")
            }
        }
        let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8)
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

    private func setChain(_ nodes: [FileNode]) {
        chain = nodes
        navigation = nodes.map(\.id)
    }

    private func setSelection(_ node: FileNode?) {
        selectedNode = node
        selection = node?.id
    }

    private func noteNavigation(from previous: [UUID]) {
        guard navigation != previous else { return }
        history.push(place)
    }

    private func show(_ place: BrowsePlace) {
        let resolvedChain = resolveChain(for: place.path)
        let resolvedSelection = resolveNode(id: place.selection, in: resolvedChain)
        withAnimation(Self.browse) {
            setChain(resolvedChain)
            expanded = place.expanded
            setSelection(resolvedSelection)
            hover(nil)
            listScrollToken += 1
        }
    }

    private func resolveChain(for path: [UUID]) -> [FileNode] {
        guard let root else { return [] }
        var nodes = [root]
        var cursor = root
        for id in path.dropFirst() {
            guard let next = cursor.children.first(where: { $0.id == id }) else { break }
            nodes.append(next)
            cursor = next
        }
        return nodes
    }

    private func resolveNode(id: UUID?, in chain: [FileNode]) -> FileNode? {
        guard let id, let root else { return nil }
        if let current = chain.last {
            if current.id == id { return current }
            if let child = current.children.first(where: { $0.id == id }) { return child }
        }
        if let onChain = chain.first(where: { $0.id == id }) { return onChain }
        if root.id == id { return root }
        var stack: [FileNode] = [root]
        while let candidate = stack.popLast() {
            if candidate.id == id { return candidate }
            if candidate.isDirectory {
                stack.append(contentsOf: candidate.children)
            }
        }
        return nil
    }

    private func directoryIDs(in root: FileNode) -> Set<UUID> {
        guard root.isDirectory else { return [] }
        var ids: Set<UUID> = []
        var stack: [FileNode] = [root]
        while let node = stack.popLast() {
            guard node.isDirectory else { continue }
            ids.insert(node.id)
            for child in node.children where child.isDirectory {
                stack.append(child)
            }
        }
        return ids
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

    private nonisolated static func makeStartPoints() -> [StartPoint] {
        var points = [
            StartPoint(
                id: "home",
                title: "Home",
                url: FileManager.default.homeDirectoryForCurrentUser
            )
        ]
        var seenPaths = Set<String>()
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        for volume in volumes {
            let path = volume.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { continue }
            let name = (try? volume.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? ""
            let title = name.isEmpty ? (volume.lastPathComponent.isEmpty ? "Volume" : volume.lastPathComponent) : name
            points.append(StartPoint(id: volume.path, title: title, url: volume))
        }
        return points
    }
}

private final class CancellationFlag: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    func cancel() {
        cancelled.withLock { $0 = true }
    }

    var isCancelled: Bool {
        cancelled.withLock { $0 }
    }
}

/// Coalesces progress snapshots from background workers so at most one MainActor
/// delivery is scheduled at a time and updates always arrive in order.
private final class ProgressPipe: Sendable {
    private struct State {
        var latest: ScanProgress?
        var scheduled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let handler: @MainActor @Sendable (ScanProgress) -> Void

    init(handler: @escaping @MainActor @Sendable (ScanProgress) -> Void) {
        self.handler = handler
    }

    func send(_ progress: ScanProgress) {
        let shouldSchedule = state.withLock { current -> Bool in
            current.latest = progress
            if current.scheduled { return false }
            current.scheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task { @MainActor [self] in
            self.drain()
        }
    }

    @MainActor
    private func drain() {
        while true {
            let next = state.withLock { current -> ScanProgress? in
                if let value = current.latest {
                    current.latest = nil
                    return value
                }
                current.scheduled = false
                return nil
            }
            guard let next else { return }
            handler(next)
        }
    }
}
