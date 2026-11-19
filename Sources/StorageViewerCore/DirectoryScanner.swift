import Darwin
import Foundation
import os

public struct ScanProgress: Sendable {
    public var filesSeen: Int
    public var bytesCounted: Int64
    public var skippedCount: Int

    public init(filesSeen: Int, bytesCounted: Int64, skippedCount: Int) {
        self.filesSeen = filesSeen
        self.bytesCounted = bytesCounted
        self.skippedCount = skippedCount
    }
}

public struct ScanOutcome: Sendable {
    public var root: FileNode?
    public var filesSeen: Int
    public var bytesCounted: Int64
    public var skippedCount: Int
    public var cancelled: Bool
    public var rootDenied: Bool
    public var missing: Bool

    public init(
        root: FileNode?,
        filesSeen: Int,
        bytesCounted: Int64,
        skippedCount: Int,
        cancelled: Bool,
        rootDenied: Bool,
        missing: Bool
    ) {
        self.root = root
        self.filesSeen = filesSeen
        self.bytesCounted = bytesCounted
        self.skippedCount = skippedCount
        self.cancelled = cancelled
        self.rootDenied = rootDenied
        self.missing = missing
    }
}

/// Logical file sizes. A folder's size is the sum of its children.
/// Symlinks are not followed. Other volumes are not entered.
/// Items macOS refuses to read are skipped and counted.
///
/// Directories are listed with `getattrlistbulk` and opened with `openat`
/// from the parent, on a small pool of workers.
public enum DirectoryScanner {
    public static func scan(
        url: URL,
        displayName: String,
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> ScanOutcome {
        scan(url: url, displayName: displayName, deferDirectoryOpens: false, inlineResume: false, progress: progress, isCancelled: isCancelled)
    }

    /// Test-only entry point. `deferDirectoryOpens` makes every child-directory open fail
    /// like EMFILE; `inlineResume` services each resume job on the publishing worker at the
    /// moment it is queued — the earliest point another worker could run it.
    static func scan(
        url: URL,
        displayName: String,
        deferDirectoryOpens: Bool,
        inlineResume: Bool,
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> ScanOutcome {
        ParallelScanner(
            progress: progress,
            isCancelled: isCancelled,
            deferDirectoryOpens: deferDirectoryOpens,
            inlineResume: inlineResume
        ).run(url: url, displayName: displayName)
    }
}

/// Monotonic per-scan counter ensuring UUIDs never collide across scans or copied subtrees.
private let scanSequence = OSAllocatedUnfairLock(initialState: UInt64(0))

private struct ListedFile {
    var name: String
    var byteSize: Int64
    var category: FileCategory
    var identity: FileIdentity?
}

private struct MountedFolder {
    var name: String
    var identity: FileIdentity?
}

private struct DirRecord {
    var name: String
    var denied: Bool
    var files: [ListedFile]
    var childIDs: [Int]
    var mounts: [MountedFolder]
    var skipped: Int
    var identity: FileIdentity?
}

private struct ScanJob {
    var id: Int
    var fd: Int32
    var name: String
    var depth: Int
    var identity: FileIdentity?
    /// Set when a folder listing ran out of file handles. The worker opens `resumePath` later.
    var resumePath: String?
    var resumeNames: [String]?
    var attachTo: Int?

    var isResume: Bool { resumePath != nil }
}

private final class WorkQueue: @unchecked Sendable {
    private let cond = NSCondition()
    private var fdJobs: [ScanJob] = []
    private var resumeJobs: [ScanJob] = []
    private var runningFdWorkers = 0
    private var runningResumeWorkers = 0
    private var heldResumeParents = 0
    private var accept = true
    private var nextID = 0

    /// Takes ownership of `fd`. Returns nil when the scan is stopping; the fd is closed.
    func push(fd: Int32, name: String, depth: Int, identity: FileIdentity? = nil) -> Int? {
        cond.lock()
        guard accept else {
            cond.unlock()
            close(fd)
            return nil
        }
        let id = nextID
        nextID += 1
        fdJobs.append(ScanJob(id: id, fd: fd, name: name, depth: depth, identity: identity))
        cond.signal()
        cond.unlock()
        return id
    }

    /// Lower priority than open-fd jobs: draining fd jobs first closes handles and frees slots.
    /// Returns false when the scan is stopping and the job was dropped.
    @discardableResult
    func pushResume(path: String, names: [String], depth: Int, attachTo: Int) -> Bool {
        cond.lock()
        guard accept else {
            cond.unlock()
            return false
        }
        resumeJobs.append(ScanJob(
            id: -1,
            fd: -1,
            name: "",
            depth: depth,
            resumePath: path,
            resumeNames: names,
            attachTo: attachTo
        ))
        cond.signal()
        cond.unlock()
        return true
    }

    /// True when another job can still close a folder. False when waiting would stall the scan.
    func waitForClose() -> Bool {
        cond.lock()
        defer { cond.unlock() }
        guard accept else { return false }
        let canFreeFD = runningFdWorkers > 0 || !fdJobs.isEmpty || heldResumeParents > 0
        if !canFreeFD { return false }
        _ = cond.wait(until: Date(timeIntervalSinceNow: 0.05))
        return accept
    }

    func noteClosed() {
        cond.lock()
        cond.broadcast()
        cond.unlock()
    }

    func noteResumeParentOpened() {
        cond.lock()
        heldResumeParents += 1
        cond.unlock()
    }

    func noteResumeParentClosed() {
        cond.lock()
        heldResumeParents -= 1
        cond.broadcast()
        cond.unlock()
    }

    func pop() -> ScanJob? {
        cond.lock()
        defer { cond.unlock() }
        while fdJobs.isEmpty && resumeJobs.isEmpty && (runningFdWorkers + runningResumeWorkers) > 0 && accept {
            cond.wait()
        }
        guard accept else { return nil }
        if let job = fdJobs.popLast() {
            runningFdWorkers += 1
            return job
        }
        if let job = resumeJobs.popLast() {
            runningResumeWorkers += 1
            return job
        }
        return nil
    }

    func complete(wasResume: Bool) {
        cond.lock()
        if wasResume {
            runningResumeWorkers -= 1
        } else {
            runningFdWorkers -= 1
        }
        let allIdle = (runningFdWorkers + runningResumeWorkers) == 0 && fdJobs.isEmpty && resumeJobs.isEmpty
        let noMoreFdWork = !wasResume && runningFdWorkers == 0 && fdJobs.isEmpty
        if allIdle || noMoreFdWork {
            cond.broadcast()
        }
        cond.unlock()
    }

    func stop() {
        cond.lock()
        accept = false
        let leftover = fdJobs
        fdJobs.removeAll(keepingCapacity: true)
        resumeJobs.removeAll(keepingCapacity: true)
        cond.broadcast()
        cond.unlock()
        for job in leftover where job.fd >= 0 {
            close(job.fd)
        }
    }
}

/// A double-clicked app inherits launchd's soft limit of 256. One wide folder can pass that.
private func raiseOpenFileLimit() {
    var limit = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }

    var maxPerProc: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let kernelCap: rlim_t
    if sysctlbyname("kern.maxfilesperproc", &maxPerProc, &size, nil, 0) == 0, maxPerProc > 0 {
        kernelCap = rlim_t(maxPerProc)
    } else {
        kernelCap = rlim_t(OPEN_MAX)
    }

    // RLIM_INFINITY is (1<<63)-1. Swift does not import that macro.
    let hard = limit.rlim_max
    let hardCap: rlim_t = hard >= rlim_t(Int64.max) ? kernelCap : min(hard, kernelCap)
    let target = min(hardCap, 65_536)
    guard limit.rlim_cur < target else { return }

    limit.rlim_cur = target
    if setrlimit(RLIMIT_NOFILE, &limit) != 0 {
        let fallback = min(hardCap, rlim_t(OPEN_MAX))
        if limit.rlim_cur < fallback {
            limit.rlim_cur = fallback
            _ = setrlimit(RLIMIT_NOFILE, &limit)
        }
    }
}

private final class ScanStats: Sendable {
    private struct State {
        var files = 0
        var bytes: Int64 = 0
        var skipped = 0
        var lastReportNanos: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private static let reportIntervalNanos: UInt64 = 80_000_000

    func add(
        files: Int,
        bytes: Int64,
        skipped: Int,
        progress: @escaping @Sendable (ScanProgress) -> Void,
        force: Bool = false
    ) {
        if files == 0 && bytes == 0 && skipped == 0 && !force { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let snapshot: ScanProgress? = state.withLock { current in
            current.files += files
            current.bytes = saturatingAdd(current.bytes, bytes)
            current.skipped += skipped
            let elapsed = now >= current.lastReportNanos ? (now - current.lastReportNanos) : Self.reportIntervalNanos
            guard force || current.lastReportNanos == 0 || elapsed >= Self.reportIntervalNanos else {
                return nil
            }
            current.lastReportNanos = now
            return ScanProgress(filesSeen: current.files, bytesCounted: current.bytes, skippedCount: current.skipped)
        }
        if let snapshot { progress(snapshot) }
    }
}

private final class ScanBuffer {
    let pointer: UnsafeMutableRawPointer
    let capacity: Int

    init() {
        capacity = 1024 * 1024
        pointer = .allocate(byteCount: capacity, alignment: 16)
    }

    deinit {
        pointer.deallocate()
    }
}

private func workerCount() -> Int {
    // Four workers is the knee on APFS. More threads start fighting over the same metadata.
    max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
}

private final class ParallelScanner: @unchecked Sendable {
    private let progress: @Sendable (ScanProgress) -> Void
    private let isCancelled: @Sendable () -> Bool
    private let deferDirectoryOpens: Bool
    private let inlineResume: Bool
    private let queue = WorkQueue()
    private let stats = ScanStats()
    private let recordsLock = OSAllocatedUnfairLock()
    private var records: [DirRecord?] = []
    private var rootDevice: UInt32?
    private var rootID = 0
    private let scanSalt: UInt64
    private var nextNodeID: UInt64 = 0

    init(
        progress: @escaping @Sendable (ScanProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool,
        deferDirectoryOpens: Bool = false,
        inlineResume: Bool = false
    ) {
        self.progress = progress
        self.isCancelled = isCancelled
        let sequence = scanSequence.withLock { count -> UInt64 in
            count &+= 1
            return count
        }
        self.scanSalt = (sequence &<< 32) | UInt64.random(in: 0 ... UInt64(UInt32.max))
        self.deferDirectoryOpens = deferDirectoryOpens
        self.inlineResume = inlineResume
    }

    func run(url: URL, displayName: String) -> ScanOutcome {
        raiseOpenFileLimit()
        if isCancelled() {
            return ScanOutcome(root: nil, filesSeen: 0, bytesCounted: 0, skippedCount: 0, cancelled: true, rootDenied: false, missing: false)
        }

        let rootFd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if rootFd < 0 {
            let err = errno
            return ScanOutcome(
                root: nil,
                filesSeen: 0,
                bytesCounted: 0,
                skippedCount: 0,
                cancelled: false,
                rootDenied: err != ENOENT,
                missing: err == ENOENT
            )
        }

        var info = stat()
        let rootIdentity: FileIdentity?
        if fstat(rootFd, &info) == 0 {
            rootDevice = UInt32(truncatingIfNeeded: info.st_dev)
            rootIdentity = FileIdentity(info)
        } else {
            rootIdentity = nil
        }
        guard let id = queue.push(fd: rootFd, name: displayName, depth: 0, identity: rootIdentity) else {
            return ScanOutcome(root: nil, filesSeen: 0, bytesCounted: 0, skippedCount: 0, cancelled: true, rootDenied: false, missing: false)
        }
        rootID = id

        let group = DispatchGroup()
        let workers = workerCount()
        for _ in 0..<workers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                self.worker()
                group.leave()
            }
        }
        group.wait()

        stats.add(files: 0, bytes: 0, skipped: 0, progress: progress, force: true)

        guard let built = build(rootID), !built.denied else {
            let cancelled = isCancelled()
            return ScanOutcome(
                root: nil,
                filesSeen: 0,
                bytesCounted: 0,
                skippedCount: 0,
                cancelled: cancelled,
                rootDenied: !cancelled,
                missing: false
            )
        }
        return ScanOutcome(
            root: built.node,
            filesSeen: built.files,
            bytesCounted: built.node.byteSize,
            skippedCount: built.skipped,
            cancelled: isCancelled(),
            rootDenied: false,
            missing: false
        )
    }

    private func worker() {
        let buffer = ScanBuffer()
        while let job = queue.pop() {
            let wasResume = job.isResume
            defer { queue.complete(wasResume: wasResume) }
            if isCancelled() {
                if job.fd >= 0 { close(job.fd) }
                queue.stop()
                break
            }
            if wasResume {
                resume(job)
            } else {
                consume(job, buffer: buffer)
            }
        }
    }

    private func consume(_ job: ScanJob, buffer: ScanBuffer) {
        defer {
            close(job.fd)
            queue.noteClosed()
        }

        let identity: FileIdentity?
        if let known = job.identity {
            identity = known
        } else {
            var info = stat()
            if fstat(job.fd, &info) == 0 {
                identity = FileIdentity(info)
                // Guard against crossing mount points when the parent's bulk listing lacked dev_t.
                if job.depth > 0, let rootDevice, UInt32(truncatingIfNeeded: info.st_dev) != rootDevice {
                    store(job, DirRecord(name: job.name, denied: false, files: [], childIDs: [], mounts: [], skipped: 0, identity: identity))
                    return
                }
            } else {
                identity = nil
            }
        }

        let listed: BulkList
        switch listWithBulk(fd: job.fd, buffer: buffer.pointer, capacity: buffer.capacity) {
        case .ok(let entries):
            if !entries.isEmpty, entries.allSatisfy({ $0.name.isEmpty && $0.kind != .denied }) {
                listed = listFallback(fd: job.fd)
            } else {
                listed = .ok(entries)
            }
        case .fallback:
            listed = listFallback(fd: job.fd)
        case .denied:
            store(job, DirRecord(name: job.name, denied: true, files: [], childIDs: [], mounts: [], skipped: 1, identity: identity))
            stats.add(files: 0, bytes: 0, skipped: 1, progress: progress)
            return
        }

        guard case .ok(let entries) = listed else {
            store(job, DirRecord(name: job.name, denied: true, files: [], childIDs: [], mounts: [], skipped: 1, identity: identity))
            stats.add(files: 0, bytes: 0, skipped: 1, progress: progress)
            return
        }

        var files: [ListedFile] = []
        var childIDs: [Int] = []
        var mounts: [MountedFolder] = []
        var deferred: [String] = []
        var skipped = 0
        var seen = 0
        var bytes: Int64 = 0
        var steps = 0
        var stoppedEarly = false
        files.reserveCapacity(entries.count)
        let childFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW

        for entry in entries {
            steps += 1
            if steps & 4095 == 0, isCancelled() {
                queue.stop()
                stoppedEarly = true
                break
            }
            switch entry.kind {
            case .denied:
                skipped += 1
            case .directory:
                if let rootDevice, let device = entry.device, device != rootDevice {
                    mounts.append(MountedFolder(name: entry.name, identity: entry.identity))
                    continue
                }
                if job.depth >= 400 {
                    skipped += 1
                    continue
                }
                if !deferred.isEmpty {
                    deferred.append(entry.name)
                    continue
                }
                let childFd = deferDirectoryOpens
                    ? Int32(-1)
                    : entry.name.withCString { openat(job.fd, $0, childFlags) }
                if childFd < 0 {
                    let err = errno
                    if deferDirectoryOpens || err == EMFILE || err == ENFILE {
                        deferred.append(entry.name)
                    } else if err != ENOENT {
                        skipped += 1
                    }
                    continue
                }
                if let childID = queue.push(fd: childFd, name: entry.name, depth: job.depth + 1, identity: entry.identity) {
                    childIDs.append(childID)
                } else {
                    stoppedEarly = true
                    break
                }
            case .file:
                let size = max(0, entry.byteSize)
                files.append(ListedFile(
                    name: entry.name,
                    byteSize: size,
                    category: FileCategory.classify(name: entry.name),
                    identity: entry.identity
                ))
                seen += 1
                bytes = saturatingAdd(bytes, size)
            }
        }

        var resumePath: String?
        if !stoppedEarly && !deferred.isEmpty {
            if let resolved = path(of: job.fd) {
                resumePath = resolved
            } else {
                skipped += deferred.count
            }
        }

        let resumePath = deferred.isEmpty ? nil : path(of: job.fd)
        if !deferred.isEmpty, resumePath == nil {
            skipped += deferred.count
        }
        // Store before publishing: a resume worker can run the moment the job is queued
        // and attaches its children to this record.
        store(job, DirRecord(
            name: job.name,
            denied: false,
            files: files,
            childIDs: childIDs,
            mounts: mounts,
            skipped: skipped,
            identity: identity
        ))
        if let resumePath {
            if inlineResume {
                resume(ScanJob(id: -1, fd: -1, name: "", depth: job.depth, resumePath: resumePath, resumeNames: deferred, attachTo: job.id))
            } else if !queue.pushResume(path: resumePath, names: deferred, depth: job.depth, attachTo: job.id) {
                addSkipped(deferred.count, to: job.id)
                stats.add(files: 0, bytes: 0, skipped: deferred.count, progress: progress)
            }
        }
        stats.add(files: seen, bytes: bytes, skipped: skipped, progress: progress)
    }

    /// Opens folders that were deferred when the process was out of file handles.
    private func resume(_ job: ScanJob) {
        guard let path = job.resumePath, let names = job.resumeNames, let parentID = job.attachTo else { return }
        let childFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        var pending = names
        var tries = 0
        while !pending.isEmpty {
            if isCancelled() {
                queue.stop()
                return
            }
            let parent = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            if parent < 0 {
                let err = errno
                if (err == EMFILE || err == ENFILE), tries < 64, queue.waitForClose() {
                    tries += 1
                    continue
                }
                addSkipped(pending.count, to: parentID)
                stats.add(files: 0, bytes: 0, skipped: pending.count, progress: progress)
                return
            }
            queue.noteResumeParentOpened()

            var opened: [Int] = []
            var rest: [String] = []
            var skipped = 0
            var cancelledMidLoop = false
            for (index, name) in pending.enumerated() {
                if index & 255 == 0, isCancelled() {
                    queue.stop()
                    cancelledMidLoop = true
                    break
                }
                let childFd = name.withCString { openat(parent, $0, childFlags) }
                if childFd < 0 {
                    let err = errno
                    if err == EMFILE || err == ENFILE {
                        rest = Array(pending[index...])
                        break
                    }
                    if err != ENOENT {
                        skipped += 1
                    }
                    continue
                }
                if let childID = queue.push(fd: childFd, name: name, depth: job.depth + 1) {
                    opened.append(childID)
                } else {
                    cancelledMidLoop = true
                    break
                }
            }
            close(parent)
            queue.noteResumeParentClosed()

            if !opened.isEmpty { addChildren(opened, to: parentID) }
            if skipped > 0 {
                addSkipped(skipped, to: parentID)
                stats.add(files: 0, bytes: 0, skipped: skipped, progress: progress)
            }
            if cancelledMidLoop || rest.isEmpty { return }
            if !opened.isEmpty {
                if !queue.pushResume(path: path, names: rest, depth: job.depth, attachTo: parentID) {
                    addSkipped(rest.count, to: parentID)
                    stats.add(files: 0, bytes: 0, skipped: rest.count, progress: progress)
                }
                return
            }
            pending = rest
            tries += 1
            if tries < 64, queue.waitForClose() { continue }
            addSkipped(pending.count, to: parentID)
            stats.add(files: 0, bytes: 0, skipped: pending.count, progress: progress)
            return
        }
    }

    private func store(_ job: ScanJob, _ record: DirRecord) {
        recordsLock.withLock {
            if job.id >= records.count {
                records.append(contentsOf: repeatElement(nil, count: job.id - records.count + 1))
            }
            records[job.id] = record
        }
    }

    private func addChildren(_ ids: [Int], to recordID: Int) {
        recordsLock.withLock {
            guard recordID >= 0, recordID < records.count else { return }
            records[recordID]?.childIDs.append(contentsOf: ids)
        }
    }

    private func addSkipped(_ count: Int, to recordID: Int) {
        recordsLock.withLock {
            guard recordID >= 0, recordID < records.count else { return }
            records[recordID]?.skipped += count
        }
    }

    private struct Built {
        var node: FileNode
        var files: Int
        var skipped: Int
        var denied: Bool
    }

    /// Runs on a single thread after all workers have exited; links parents and totals in one pass.
    private func build(_ id: Int) -> Built? {
        guard id >= 0, id < records.count, let record = records[id] else { return nil }
        records[id] = nil
        if record.denied {
            return Built(
                node: FileNode(id: nextIdentifier(), name: record.name, isDirectory: true, byteSize: 0, category: .other, fileID: record.identity),
                files: 0,
                skipped: max(record.skipped, 1),
                denied: true
            )
        }

        var children: [FileNode] = []
        var files = 0
        var skipped = record.skipped
        var totalBytes: Int64 = 0
        var totals = CategoryTotals()
        children.reserveCapacity(record.files.count + record.childIDs.count + record.mounts.count)

        for file in record.files {
            children.append(FileNode(
                id: nextIdentifier(),
                name: file.name,
                isDirectory: false,
                byteSize: file.byteSize,
                category: file.category,
                fileID: file.identity
            ))
            totals.add(file.category, bytes: file.byteSize)
            totalBytes = saturatingAdd(totalBytes, file.byteSize)
            files += 1
        }
        for childID in record.childIDs {
            guard let child = build(childID) else { continue }
            skipped += child.skipped
            if child.denied { continue }
            children.append(child.node)
            totals.add(child.node.categoryTotals)
            totalBytes = saturatingAdd(totalBytes, child.node.byteSize)
            files += child.files
        }
        for mount in record.mounts {
            children.append(FileNode(
                id: nextIdentifier(),
                name: mount.name,
                isDirectory: true,
                byteSize: 0,
                category: .other,
                fileID: mount.identity,
                isMount: true
            ))
        }

        let node = FileNode(
            id: nextIdentifier(),
            name: record.name,
            isDirectory: true,
            byteSize: totalBytes,
            category: totals.dominantCategory,
            children: children,
            fileID: record.identity
        )
        node.categoryTotals = totals
        node.sortChildren()
        for child in node.children {
            child.parent = node
        }
        return Built(node: node, files: files, skipped: skipped, denied: false)
    }

    private func nextIdentifier() -> UUID {
        nextNodeID &+= 1
        let hi = scanSalt
        let lo = nextNodeID
        return UUID(uuid: uuid_t(
            UInt8(truncatingIfNeeded: hi >> 56),
            UInt8(truncatingIfNeeded: hi >> 48),
            UInt8(truncatingIfNeeded: hi >> 40),
            UInt8(truncatingIfNeeded: hi >> 32),
            UInt8(truncatingIfNeeded: hi >> 24),
            UInt8(truncatingIfNeeded: hi >> 16),
            UInt8(truncatingIfNeeded: hi >> 8),
            UInt8(truncatingIfNeeded: hi),
            UInt8(truncatingIfNeeded: lo >> 56),
            UInt8(truncatingIfNeeded: lo >> 48),
            UInt8(truncatingIfNeeded: lo >> 40),
            UInt8(truncatingIfNeeded: lo >> 32),
            UInt8(truncatingIfNeeded: lo >> 24),
            UInt8(truncatingIfNeeded: lo >> 16),
            UInt8(truncatingIfNeeded: lo >> 8),
            UInt8(truncatingIfNeeded: lo)
        ))
    }
}

struct BulkEntry {
    enum Kind: Equatable {
        case file
        case directory
        case denied
    }

    var name: String
    var kind: Kind
    var byteSize: Int64
    /// Raw `dev_t`. Kept unsigned: devfs and other devices set the top bit,
    /// and a signed conversion of those values traps.
    var device: UInt32?
    var inode: UInt64?

    var identity: FileIdentity? {
        guard let device, let inode else { return nil }
        return FileIdentity(device: UInt64(device), inode: inode)
    }
}

private enum BulkList {
    case ok([BulkEntry])
    case denied
    case fallback
}

private let vnodeDirectory: UInt32 = 2

private func listWithBulk(fd: Int32, buffer: UnsafeMutableRawPointer, capacity: Int) -> BulkList {
    var attributes = attrlist()
    attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    attributes.commonattr = attrgroup_t(
        UInt32(ATTR_CMN_RETURNED_ATTRS)
            | UInt32(ATTR_CMN_NAME)
            | UInt32(ATTR_CMN_DEVID)
            | UInt32(ATTR_CMN_ERROR)
            | UInt32(ATTR_CMN_OBJTYPE)
            | UInt32(ATTR_CMN_FILEID)
    )
    attributes.fileattr = attrgroup_t(UInt32(ATTR_FILE_DATALENGTH))

    var entries: [BulkEntry] = []

    while true {
        let count = getattrlistbulk(fd, &attributes, buffer, capacity, 0)
        if count == 0 { break }
        if count < 0 {
            let err = errno
            if err == EINTR { continue }
            if !sawAny, err == EACCES || err == EPERM { return .denied }
            return .fallback
        }
        var offset = 0
        for _ in 0..<count {
            let base = buffer.advanced(by: offset)
            let length = Int(base.loadUnaligned(as: UInt32.self))
            if length < 8 || offset + length > capacity { return .fallback }
            if let entry = parseBulkEntry(base: base, length: length) {
                entries.append(entry)
            }
            offset += length
        }
    }
    return .ok(entries)
}

func parseBulkEntry(base: UnsafeMutableRawPointer, length: Int) -> BulkEntry? {
    var cursor = 4
    guard cursor + MemoryLayout<attribute_set_t>.size <= length else { return nil }
    let returned = base.advanced(by: cursor).loadUnaligned(as: attribute_set_t.self)
    cursor += MemoryLayout<attribute_set_t>.size

    var name = ""
    if returned.commonattr & UInt32(ATTR_CMN_NAME) != 0 {
        guard cursor + MemoryLayout<attrreference_t>.size <= length else { return nil }
        let referenceOrigin = cursor
        let reference = base.advanced(by: cursor).loadUnaligned(as: attrreference_t.self)
        cursor += MemoryLayout<attrreference_t>.size
        let nameOffset = referenceOrigin + Int(reference.attr_dataoffset)
        let nameLength = Int(reference.attr_length)
        if nameLength > 1, nameOffset >= 0, nameLength <= length - nameOffset {
            let raw = UnsafeBufferPointer(
                start: base.advanced(by: nameOffset).assumingMemoryBound(to: UInt8.self),
                count: nameLength
            )
            let end = raw.firstIndex(of: 0) ?? nameLength
            if end > 0 {
                name = String(decoding: raw[..<end], as: UTF8.self)
            }
        }
    }
    if name == "." || name == ".." { return nil }

    var device: UInt32?
    if returned.commonattr & UInt32(ATTR_CMN_DEVID) != 0 {
        guard cursor + 4 <= length else { return nil }
        device = base.advanced(by: cursor).loadUnaligned(as: UInt32.self)
        cursor += 4
    }

    var objectType: UInt32 = 0
    if returned.commonattr & UInt32(ATTR_CMN_OBJTYPE) != 0 {
        guard cursor + 4 <= length else { return nil }
        objectType = base.advanced(by: cursor).loadUnaligned(as: UInt32.self)
        cursor += 4
    }

    var inode: UInt64?
    if returned.commonattr & UInt32(ATTR_CMN_FILEID) != 0 {
        guard cursor + 8 <= length else { return nil }
        inode = base.advanced(by: cursor).loadUnaligned(as: UInt64.self)
        cursor += 8
    }

    var errorCode: UInt32 = 0
    if returned.commonattr & UInt32(ATTR_CMN_ERROR) != 0 {
        guard cursor + 4 <= length else { return nil }
        errorCode = base.advanced(by: cursor).loadUnaligned(as: UInt32.self)
        cursor += 4
    }

    var dataLength: Int64 = 0
    if returned.fileattr & UInt32(ATTR_FILE_DATALENGTH) != 0 {
        guard cursor + 8 <= length else { return nil }
        dataLength = base.advanced(by: cursor).loadUnaligned(as: Int64.self)
    }

    if errorCode != 0 {
        if errorCode == UInt32(ENOENT) { return nil }
        return BulkEntry(name: name, kind: .denied, byteSize: 0, device: device, inode: inode)
    }
    if objectType == vnodeDirectory {
        return BulkEntry(name: name, kind: .directory, byteSize: 0, device: device, inode: inode)
    }
    return BulkEntry(name: name, kind: .file, byteSize: max(0, dataLength), device: device, inode: inode)
}

private func path(of fd: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
    let end = buffer.firstIndex(of: 0) ?? buffer.count
    return buffer.withUnsafeBytes { raw in
        String(decoding: raw.prefix(end), as: UTF8.self)
    }
}

private func listFallback(fd: Int32) -> BulkList {
    let dupFd = dup(fd)
    guard dupFd >= 0 else { return .denied }
    guard let dir = fdopendir(dupFd) else {
        close(dupFd)
        return .denied
    }
    defer { closedir(dir) }
    rewinddir(dir)

    var entries: [BulkEntry] = []
    while true {
        errno = 0
        guard let entryPtr = readdir(dir) else {
            let err = errno
            if err == EINTR { continue }
            if err != 0 { return .denied }
            break
        }
        let nameLength = Int(entryPtr.pointee.d_namlen)
        let name = withUnsafePointer(to: entryPtr.pointee.d_name) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: nameLength) { bytes in
                String(decoding: UnsafeBufferPointer(start: bytes, count: nameLength), as: UTF8.self)
            }
        }
        if name == "." || name == ".." { continue }
        var info = stat()
        let status = name.withCString { fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if status != 0 {
            if errno == ENOENT { continue }
            entries.append(BulkEntry(name: name, kind: .denied, byteSize: 0, device: nil, inode: nil))
            continue
        }
        let mode = info.st_mode & S_IFMT
        let inode = UInt64(truncatingIfNeeded: info.st_ino)
        let device = UInt32(truncatingIfNeeded: info.st_dev)
        if mode == S_IFDIR {
            entries.append(BulkEntry(name: name, kind: .directory, byteSize: 0, device: device, inode: inode))
        } else {
            entries.append(BulkEntry(name: name, kind: .file, byteSize: max(0, Int64(info.st_size)), device: device, inode: inode))
        }
    }
    return .ok(entries)
}
