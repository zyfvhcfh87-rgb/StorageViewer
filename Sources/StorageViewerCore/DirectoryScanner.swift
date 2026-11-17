import Darwin
import Foundation

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
        ParallelScanner(progress: progress, isCancelled: isCancelled).run(url: url, displayName: displayName)
    }
}

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
    /// Set when a folder listing ran out of file handles. The worker opens `resumePath` later.
    var resumePath: String?
    var resumeNames: [String]?
    var attachTo: Int?
}

private final class WorkQueue: @unchecked Sendable {
    private let cond = NSCondition()
    private var jobs: [ScanJob] = []
    private var running = 0
    private var accept = true
    private var nextID = 0

    /// Takes ownership of `fd`. Returns nil when the scan is stopping; the fd is closed.
    func push(fd: Int32, name: String, depth: Int) -> Int? {
        cond.lock()
        defer { cond.unlock() }
        guard accept else {
            close(fd)
            return nil
        }
        let id = nextID
        nextID += 1
        jobs.append(ScanJob(id: id, fd: fd, name: name, depth: depth))
        cond.signal()
        return id
    }

    /// Low priority: file-handle jobs are drained first, which closes folders and frees a slot.
    func pushResume(path: String, names: [String], depth: Int, attachTo: Int) {
        cond.lock()
        defer { cond.unlock() }
        guard accept else { return }
        jobs.insert(
            ScanJob(
                id: -1,
                fd: -1,
                name: "",
                depth: depth,
                resumePath: path,
                resumeNames: names,
                attachTo: attachTo
            ),
            at: 0
        )
        cond.signal()
    }

    /// True when another worker can close a folder. False when waiting would stall the scan.
    func waitForClose() -> Bool {
        cond.lock()
        defer { cond.unlock() }
        guard accept else { return false }
        let help = running > 1 || jobs.contains(where: { $0.fd >= 0 })
        if !help { return false }
        cond.wait()
        return accept
    }

    func noteClosed() {
        cond.lock()
        cond.broadcast()
        cond.unlock()
    }

    func pop() -> ScanJob? {
        cond.lock()
        defer { cond.unlock() }
        while jobs.isEmpty && running > 0 && accept {
            cond.wait()
        }
        guard accept, !jobs.isEmpty else { return nil }
        running += 1
        return jobs.removeLast()
    }

    func complete() {
        cond.lock()
        running -= 1
        if running == 0 && jobs.isEmpty {
            cond.broadcast()
        }
        cond.unlock()
    }

    func stop() {
        cond.lock()
        accept = false
        let leftover = jobs
        jobs.removeAll(keepingCapacity: true)
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
    let hard = limit.rlim_max
    // RLIM_INFINITY is (1<<63)-1. Swift does not import that macro.
    let target: rlim_t = hard >= rlim_t(Int64.max) ? 65_536 : hard
    if limit.rlim_cur >= target { return }
    limit.rlim_cur = target
    _ = setrlimit(RLIMIT_NOFILE, &limit)
}

private final class ScanStats: @unchecked Sendable {
    private let lock = NSLock()
    private var files = 0
    private var bytes: Int64 = 0
    private var skipped = 0
    private var lastReport = Date.distantPast

    func add(
        files: Int,
        bytes: Int64,
        skipped: Int,
        progress: @escaping @Sendable (ScanProgress) -> Void,
        force: Bool = false
    ) {
        if files == 0 && bytes == 0 && skipped == 0 && !force { return }
        lock.lock()
        self.files += files
        self.bytes += bytes
        self.skipped += skipped
        let now = Date()
        let due = force || now.timeIntervalSince(lastReport) > 0.08
        if due { lastReport = now }
        let snapshot = ScanProgress(filesSeen: self.files, bytesCounted: self.bytes, skippedCount: self.skipped)
        lock.unlock()
        if due { progress(snapshot) }
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
    private let queue = WorkQueue()
    private let stats = ScanStats()
    private let recordsLock = NSLock()
    private var records: [Int: DirRecord] = [:]
    private var rootDevice: UInt32 = 0
    private var rootID = 0
    private var nextNodeID: UInt64 = 0

    init(
        progress: @escaping @Sendable (ScanProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        self.progress = progress
        self.isCancelled = isCancelled
    }

    func run(url: URL, displayName: String) -> ScanOutcome {
        raiseOpenFileLimit()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return ScanOutcome(root: nil, filesSeen: 0, bytesCounted: 0, skippedCount: 0, cancelled: false, rootDenied: false, missing: true)
        }
        guard isDirectory.boolValue else {
            return ScanOutcome(root: nil, filesSeen: 0, bytesCounted: 0, skippedCount: 0, cancelled: false, rootDenied: true, missing: false)
        }
        if isCancelled() {
            return ScanOutcome(root: nil, filesSeen: 0, bytesCounted: 0, skippedCount: 0, cancelled: true, rootDenied: false, missing: false)
        }

        let rootFd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if rootFd < 0 {
            let denied = errno == EACCES || errno == EPERM
            return ScanOutcome(
                root: nil,
                filesSeen: 0,
                bytesCounted: 0,
                skippedCount: 0,
                cancelled: false,
                rootDenied: denied || errno != ENOENT,
                missing: errno == ENOENT
            )
        }
        var info = stat()
        if fstat(rootFd, &info) == 0 {
            rootDevice = UInt32(truncatingIfNeeded: info.st_dev)
        }
        guard let id = queue.push(fd: rootFd, name: displayName, depth: 0) else {
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
        built.node.linkParents()
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
            defer { queue.complete() }
            if isCancelled() {
                if job.fd >= 0 { close(job.fd) }
                queue.stop()
                break
            }
            if job.resumePath != nil {
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
        let identity = identity(of: job.fd)
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
        files.reserveCapacity(entries.count)
        let childFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW

        for entry in entries {
            steps += 1
            if steps & 4095 == 0, isCancelled() {
                queue.stop()
                break
            }
            switch entry.kind {
            case .denied:
                skipped += 1
            case .directory:
                if let device = entry.device, device != rootDevice {
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
                let childFd = entry.name.withCString { openat(job.fd, $0, childFlags) }
                if childFd < 0 {
                    if errno == EMFILE || errno == ENFILE {
                        deferred.append(entry.name)
                    } else {
                        skipped += 1
                    }
                    continue
                }
                if let childID = queue.push(fd: childFd, name: entry.name, depth: job.depth + 1) {
                    childIDs.append(childID)
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
                bytes += size
            }
        }

        if !deferred.isEmpty, let path = path(of: job.fd) {
            queue.pushResume(path: path, names: deferred, depth: job.depth, attachTo: job.id)
        } else {
            skipped += deferred.count
        }
        store(job, DirRecord(
            name: job.name,
            denied: false,
            files: files,
            childIDs: childIDs,
            mounts: mounts,
            skipped: skipped,
            identity: identity
        ))
        stats.add(files: seen, bytes: bytes, skipped: skipped, progress: progress)
    }

    /// Opens folders that were deferred when the process was out of file handles.
    private func resume(_ job: ScanJob) {
        guard let path = job.resumePath, let names = job.resumeNames, let parentID = job.attachTo else { return }
        let childFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        var tries = 0
        while true {
            if isCancelled() {
                queue.stop()
                return
            }
            let parent = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if parent < 0 {
                if errno == EMFILE || errno == ENFILE, tries < 64, queue.waitForClose() {
                    tries += 1
                    continue
                }
                noteSkipped(names.count, to: parentID)
                stats.add(files: 0, bytes: 0, skipped: names.count, progress: progress)
                return
            }

            var opened: [Int] = []
            var rest: [String] = []
            var skipped = 0
            for (index, name) in names.enumerated() {
                let childFd = name.withCString { openat(parent, $0, childFlags) }
                if childFd < 0 {
                    if errno == EMFILE || errno == ENFILE {
                        rest = Array(names[index...])
                        break
                    }
                    skipped += 1
                    continue
                }
                if let childID = queue.push(fd: childFd, name: name, depth: job.depth + 1) {
                    opened.append(childID)
                }
            }
            close(parent)
            queue.noteClosed()
            if !opened.isEmpty { addChildren(opened, to: parentID) }
            if skipped > 0 {
                noteSkipped(skipped, to: parentID)
                stats.add(files: 0, bytes: 0, skipped: skipped, progress: progress)
            }
            guard !rest.isEmpty else { return }
            if !opened.isEmpty {
                queue.pushResume(path: path, names: rest, depth: job.depth, attachTo: parentID)
                return
            }
            tries += 1
            if tries < 64, queue.waitForClose() { continue }
            noteSkipped(rest.count, to: parentID)
            stats.add(files: 0, bytes: 0, skipped: rest.count, progress: progress)
            return
        }
    }

    private func listFallback(fd: Int32) -> BulkList {
        guard let path = path(of: fd) else { return .denied }
        return listWithFileManager(URL(fileURLWithPath: path))
    }

    private func store(_ job: ScanJob, _ record: DirRecord) {
        recordsLock.lock()
        records[job.id] = record
        recordsLock.unlock()
    }

    private struct Built {
        var node: FileNode
        var files: Int
        var skipped: Int
        var denied: Bool
    }

    private func build(_ id: Int) -> Built? {
        recordsLock.lock()
        let record = records.removeValue(forKey: id)
        recordsLock.unlock()
        guard let record else { return nil }
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
            files += 1
        }
        for childID in record.childIDs {
            guard let child = build(childID) else { continue }
            skipped += child.skipped
            if child.denied { continue }
            children.append(child.node)
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

        children.sort { lhs, rhs in
            if lhs.byteSize != rhs.byteSize { return lhs.byteSize > rhs.byteSize }
            return lhs.name < rhs.name
        }
        let size = children.reduce(Int64(0)) { $0 + $1.byteSize }
        let node = FileNode(
            id: nextIdentifier(),
            name: record.name,
            isDirectory: true,
            byteSize: size,
            category: .other,
            children: children,
            fileID: record.identity
        )
        return Built(node: node, files: files, skipped: skipped, denied: false)
    }

    private func addChildren(_ ids: [Int], to recordID: Int) {
        recordsLock.lock()
        if var record = records[recordID] {
            record.childIDs.append(contentsOf: ids)
            records[recordID] = record
        }
        recordsLock.unlock()
    }

    private func noteSkipped(_ count: Int, to recordID: Int) {
        recordsLock.lock()
        if var record = records[recordID] {
            record.skipped += count
            records[recordID] = record
        }
        recordsLock.unlock()
    }

    private func identity(of fd: Int32) -> FileIdentity? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return FileIdentity(info)
    }

    private func nextIdentifier() -> UUID {
        nextNodeID += 1
        let value = nextNodeID
        return UUID(uuid: uuid_t(
            UInt8(truncatingIfNeeded: value >> 56),
            UInt8(truncatingIfNeeded: value >> 48),
            UInt8(truncatingIfNeeded: value >> 40),
            UInt8(truncatingIfNeeded: value >> 32),
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
            0, 0, 0, 0, 0, 0, 0, 1
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
            // A failure after some batches means the list is incomplete. Never
            // return a partial folder as if it were whole.
            if errno == EACCES || errno == EPERM { return .denied }
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
        let referencePointer = base.advanced(by: cursor)
        let reference = referencePointer.loadUnaligned(as: attrreference_t.self)
        cursor += MemoryLayout<attrreference_t>.size
        let nameOffset = referenceOrigin + Int(reference.attr_dataoffset)
        let nameLength = Int(reference.attr_length)
        if nameLength > 1, nameOffset >= 0, nameOffset + nameLength <= length {
            name = String(cString: base.advanced(by: nameOffset).assumingMemoryBound(to: CChar.self))
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

    // A flagged entry has no trustworthy size or type, so count it as skipped
    // instead of showing a phantom zero-byte file.
    if errorCode != 0 {
        return BulkEntry(name: name, kind: .denied, byteSize: 0, device: device, inode: inode)
    }
    if objectType == vnodeDirectory {
        return BulkEntry(name: name, kind: .directory, byteSize: 0, device: device, inode: inode)
    }
    let size = max(0, dataLength)
    return BulkEntry(name: name, kind: .file, byteSize: size, device: device, inode: inode)
}

private func path(of fd: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
    let end = buffer.firstIndex(of: 0) ?? buffer.count
    let bytes = buffer.prefix(end).map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

private func listWithFileManager(_ url: URL) -> BulkList {
    let names: [String]
    do {
        names = try FileManager.default.contentsOfDirectory(atPath: url.path)
    } catch {
        return .denied
    }

    var entries: [BulkEntry] = []
    entries.reserveCapacity(names.count)
    for name in names {
        if name == "." || name == ".." { continue }
        var info = stat()
        if lstat(url.appendingPathComponent(name).path, &info) != 0 {
            entries.append(BulkEntry(name: name, kind: .denied, byteSize: 0, device: nil, inode: nil))
            continue
        }
        let mode = info.st_mode & S_IFMT
        let inode = UInt64(info.st_ino)
        let device = UInt32(truncatingIfNeeded: info.st_dev)
        if mode == S_IFDIR {
            entries.append(BulkEntry(name: name, kind: .directory, byteSize: 0, device: device, inode: inode))
        } else {
            entries.append(BulkEntry(name: name, kind: .file, byteSize: max(0, Int64(info.st_size)), device: device, inode: inode))
        }
    }
    return .ok(entries)
}
