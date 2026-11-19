import AppKit
import StorageViewerCore
import SwiftUI

struct TreemapView: View {
    var folder: FileNode
    var selection: UUID?
    var hovered: UUID?
    var filter: String
    var onSelect: (FileNode) -> Void
    var onZoom: (FileNode) -> Void
    var onHover: (FileNode?) -> Void
    var revision: Int = 0
    var contextMenu: (FileNode) -> NSMenu = { _ in NSMenu() }

    @State private var settled: FileNode?
    @State private var flight: Flight?
    @State private var progress: CGFloat = 1
    @State private var playback = ZoomPlayback()
    @State private var layouts = LayoutMemo()
    @State private var hitCache = HitCache()

    var body: some View {
        GeometryReader { geo in
            let snapshot = picture(in: geo.size)
            ZStack {
                Canvas { context, _ in
                    draw(snapshot, in: context)
                }
                if snapshot.children.isEmpty, snapshot.siblingOpacity < 0.2 {
                    Text(folder.children.isEmpty ? "This folder is empty." : "These items are 0 bytes.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .opacity(Double(1 - snapshot.siblingOpacity))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { event in
                    guard let node = hit(event.location, in: snapshot) else { return }
                    if node.isDirectory {
                        onZoom(node)
                    } else {
                        onSelect(node)
                    }
                }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    onHover(hit(location, in: snapshot))
                case .ended:
                    onHover(nil)
                }
            }
            .accessibilityIdentifier("treemap")
            .accessibilityLabel("Map of \(folder.name)")
            .background(
                TreemapMenuCatcher { [snapshot] point in
                    hit(point, in: snapshot)
                } menu: { node in
                    contextMenu(node)
                }
            )
        }
        .onAppear {
            if settled == nil { settled = folder }
        }
        .onDisappear {
            playback.stop()
        }
        .onChange(of: folder.id) { _, _ in
            beginFlight(to: folder)
        }
    }

    private func beginFlight(to destination: FileNode) {
        let origin = flight?.to ?? settled ?? destination
        guard origin.id != destination.id else {
            settled = destination
            flight = nil
            return
        }
        let mode = ZoomMode.between(origin, destination)
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            progress = 0
            flight = Flight(from: origin, to: destination, mode: mode)
        }
        let target = destination.id
        playback.play { [destination] eased in
            guard flight?.to.id == target else { return false }
            progress = eased
            if eased >= 1 {
                settled = destination
                flight = nil
            }
            return true
        }
    }

    private func picture(in size: CGSize) -> TreemapPicture {
        let canvas = CGRect(origin: .zero, size: size)
        let bright = brightIDs()
        guard size.width > 1, size.height > 1 else {
            return TreemapPicture(siblings: [], children: [], plate: nil, plateOpacity: 0, siblingOpacity: 0, childOpacity: 1)
        }
        guard let flight else {
            return finish(TreemapPicture(
                siblings: [],
                children: blocks(folder.children, owner: folder.id, in: canvas),
                plate: nil,
                plateOpacity: 0,
                siblingOpacity: 0,
                childOpacity: 1
            ), bright: bright)
        }
        let t = min(1, max(0, progress))
        switch flight.mode {
        case .crossfade:
            return finish(TreemapPicture(
                siblings: blocks(flight.from.children, owner: flight.from.id, in: canvas),
                children: blocks(flight.to.children, owner: flight.to.id, in: canvas),
                plate: nil,
                plateOpacity: 0,
                siblingOpacity: 1 - t,
                childOpacity: t
            ), bright: bright)
        case .zoomIn:
            return finish(zoomPicture(parent: flight.from, child: flight.to, t: t, canvas: canvas), bright: bright)
        case .zoomOut:
            return finish(zoomPicture(parent: flight.to, child: flight.from, t: 1 - t, canvas: canvas), bright: bright)
        }
    }

    private func finish(_ shot: TreemapPicture, bright: Set<UUID>?) -> TreemapPicture {
        var shot = shot
        shot.bright = bright
        return shot
    }

    /// Folders whose blocks are on screen. A block stays bright when a nested name matches.
    private func brightIDs() -> Set<UUID>? {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let folders: [FileNode]
        if let flight {
            switch flight.mode {
            case .zoomIn:
                folders = [flight.from]
            case .zoomOut:
                folders = [flight.to]
            case .crossfade:
                folders = [flight.from, flight.to]
            }
        } else {
            folders = [folder]
        }
        let key = HitKey(revision: revision, query: query, folderIDs: folders.map(\.id))
        return hitCache.lookup(key) {
            var ids = Set<UUID>()
            for item in folders {
                ids.formUnion(NameFilter.hits(in: item.children, query: query))
            }
            return ids
        }
    }

    private func zoomPicture(parent: FileNode, child: FileNode, t: CGFloat, canvas: CGRect) -> TreemapPicture {
        let parentBlocks = blocks(parent.children, owner: parent.id, in: canvas)
        guard let focus = parentBlocks.first(where: { $0.node.id == child.id })?.rect else {
            return TreemapPicture(
                siblings: parentBlocks,
                children: blocks(child.children, owner: child.id, in: canvas),
                plate: nil,
                plateOpacity: 0,
                siblingOpacity: 1 - t,
                childOpacity: t
            )
        }
        let siblings = parentBlocks.filter { $0.node.id != child.id }
        let nested = blocks(child.children, owner: child.id, in: canvas).map { block in
            var moved = block
            moved.rect = mapIntoFocus(block.rect, focus: focus, canvas: canvas.size, t: t)
            return moved
        }
        let plate = lerpRect(focus, canvas, t)
        let childOpacity = fadeIn(t)
        return TreemapPicture(
            siblings: siblings,
            children: nested,
            plate: plate,
            plateColor: Theme.color(for: child.category),
            plateOpacity: Double(1 - t),
            siblingOpacity: 1 - t,
            childOpacity: childOpacity
        )
    }

    private func blocks(_ nodes: [FileNode], owner: UUID, in canvas: CGRect) -> [PlacedBlock] {
        layouts.blocks(owner: owner, size: canvas.size, revision: revision) {
            let layout = TreemapLayout.layout(nodes: nodes, in: canvas)
            var lookup: [UUID: FileNode] = [:]
            lookup.reserveCapacity(nodes.count)
            for node in nodes {
                lookup[node.id] = node
            }
            var result: [PlacedBlock] = []
            result.reserveCapacity(layout.count)
            for item in layout {
                guard let node = lookup[item.id] else { continue }
                let tone = BlockTone(node: node)
                let pad = padded(item.rect)
                let prepared = pad.width > 16 && pad.height > 16 ? markDrawing(for: tone, in: pad) : nil
                let measure = pad.width > 44 && pad.height > 14 ? LabelMeasure(node: node) : nil
                result.append(PlacedBlock(
                    node: node,
                    rect: item.rect,
                    tone: tone,
                    measure: measure,
                    prepared: prepared,
                    preparedRect: pad
                ))
            }
            return result
        }
    }

    private func draw(_ picture: TreemapPicture, in context: GraphicsContext) {
        for block in picture.siblings {
            fill(block, opacity: picture.siblingOpacity, bright: picture.bright, in: context)
        }
        if let plate = picture.plate, picture.plateOpacity > 0.01, let color = picture.plateColor {
            let rect = padded(plate)
            let path = Path(roundedRect: rect, cornerRadius: min(2, rect.height / 2))
            context.fill(path, with: .color(color.opacity(picture.plateOpacity)))
        }
        for block in picture.children {
            fill(block, opacity: picture.childOpacity, bright: picture.bright, in: context)
        }
        if picture.siblingOpacity > 0.4 {
            for block in picture.siblings {
                strokeAndLabel(block, opacity: picture.siblingOpacity, bright: picture.bright, in: context)
            }
        }
        if picture.childOpacity > 0.72 {
            for block in picture.children {
                strokeAndLabel(block, opacity: picture.childOpacity, bright: picture.bright, in: context)
            }
        }
    }

    private func fill(_ block: PlacedBlock, opacity: CGFloat, bright: Set<UUID>?, in context: GraphicsContext) {
        let rect = padded(block.rect)
        guard rect.width > 0.4, rect.height > 0.4, opacity > 0.01 else { return }
        let dimmed = dimmed(block.node, bright: bright)
        let strength = (dimmed ? 0.16 : 1) * opacity
        let path = Path(rect)
        context.fill(path, with: .color(Theme.color(for: block.node.category).opacity(strength)))
        if !dimmed, rect.width > 16, rect.height > 16, opacity > 0.4 {
            var clipped = context
            clipped.clip(to: path)
            let mark = (block.tone.lightMark ? Color.white : Color.black).opacity(CGFloat(BlockPattern.markOpacity) * opacity)
            paint(marks(for: block, in: rect), color: mark, into: &clipped)
        }
    }

    private func strokeAndLabel(_ block: PlacedBlock, opacity: CGFloat, bright: Set<UUID>?, in context: GraphicsContext) {
        let rect = padded(block.rect)
        guard rect.width > 2, rect.height > 2 else { return }
        let dimmed = dimmed(block.node, bright: bright)
        if block.node.id == hovered, block.node.id != selection, !dimmed {
            context.stroke(
                Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 1),
                with: .color(Theme.text.opacity(0.45 * opacity)),
                lineWidth: 1
            )
        }
        let selected = block.node.id == selection
        if selected {
            context.stroke(
                Path(rect.insetBy(dx: 1, dy: 1)),
                with: .color(Theme.selection.opacity(opacity)),
                lineWidth: 2
            )
        }
        guard !dimmed, rect.width > 44, rect.height > 14, opacity > 0.8 else { return }
        let measure = block.measure ?? LabelMeasure(node: block.node)
        var clipped = context
        clipped.clip(to: Path(rect.insetBy(dx: 2, dy: 1)))
        let ink = (selected ? Theme.onSelection : Theme.text).opacity(opacity)
        let showsSize = rect.height > 28 && rect.width > 72
        if let plate = labelPlate(in: rect, measure: measure, showsSize: showsSize) {
            paintLabelBacking(selected: selected, plate: plate, opacity: opacity, on: &clipped)
        }
        clipped.draw(
            Text(block.node.name).font(.system(size: 10, weight: .medium)).foregroundColor(ink),
            at: CGPoint(x: rect.minX + 5, y: rect.minY + 9),
            anchor: .leading
        )
        if showsSize {
            clipped.draw(
                Text(measure.sizeText).font(.system(size: 10)).foregroundColor(ink.opacity(0.78)),
                at: CGPoint(x: rect.minX + 5, y: rect.minY + 21),
                anchor: .leading
            )
        }
    }

    private func dimmed(_ node: FileNode, bright: Set<UUID>?) -> Bool {
        guard let bright else { return false }
        return !bright.contains(node.id)
    }

    private func hit(_ point: CGPoint, in picture: TreemapPicture) -> FileNode? {
        if picture.childOpacity > 0.35, let node = picture.children.last(where: { $0.rect.contains(point) })?.node {
            return node
        }
        if picture.siblingOpacity > 0.35, let node = picture.siblings.last(where: { $0.rect.contains(point) })?.node {
            return node
        }
        return picture.children.last(where: { $0.rect.contains(point) })?.node
    }

    private func padded(_ rect: CGRect) -> CGRect {
        let inset: CGFloat = rect.width > 12 && rect.height > 12 ? 2 : (rect.width > 5 && rect.height > 5 ? 1 : 0)
        guard inset > 0 else { return rect }
        return rect.insetBy(dx: inset, dy: inset)
    }
}

/// Type color for one block, plus a mask taken from the name.
/// The mask does not use the node id, so a rescan keeps it.
private struct BlockTone {
    var grain: BlockGrain
    var lightMark: Bool

    init(node: FileNode) {
        grain = BlockGrain.forName(node.name)
        lightMark = node.category == .other
    }
}

private struct MarkDrawing {
    var fills = Path()
    var strokes: [(width: CGFloat, path: Path)] = []
}

private func markDrawing(for tone: BlockTone, in rect: CGRect) -> MarkDrawing {
    let primitives = tone.grain.pattern.primitives(in: rect, phaseX: tone.grain.phaseX, phaseY: tone.grain.phaseY)
    var drawing = MarkDrawing()
    var strokes: [CGFloat: Path] = [:]

    func addStroke(width: CGFloat, _ build: (inout Path) -> Void) {
        build(&strokes[width, default: Path()])
    }

    for primitive in primitives {
        switch primitive {
        case .fillEllipse(let rect):
            drawing.fills.addEllipse(in: rect)
        case .strokeEllipse(let rect, let width):
            addStroke(width: width) { path in
                path.addEllipse(in: rect)
            }
        case .strokeRect(let rect, let width):
            addStroke(width: width) { path in
                path.addRect(rect)
            }
        case .stroke(let points, let width, let closed):
            guard points.count >= 2 else { continue }
            addStroke(width: width) { path in
                path.move(to: points[0])
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
                if closed { path.closeSubpath() }
            }
        case .strokeArc(let center, let radius, let start, let end, let width):
            addStroke(width: width) { path in
                path.move(to: CGPoint(x: center.x + cos(start) * radius, y: center.y + sin(start) * radius))
                path.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .radians(start),
                    endAngle: .radians(end),
                    clockwise: false
                )
            }
        }
    }
    drawing.strokes = strokes.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    return drawing
}

private func paint(_ drawing: MarkDrawing, color: Color, into context: inout GraphicsContext) {
    if !drawing.fills.isEmpty {
        context.fill(drawing.fills, with: .color(color))
    }
    for stroke in drawing.strokes {
        context.stroke(
            stroke.path,
            with: .color(color),
            style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .miter)
        )
    }
}

private func marks(for block: PlacedBlock, in rect: CGRect) -> MarkDrawing {
    if let prepared = block.prepared, block.preparedRect == rect {
        return prepared
    }
    return markDrawing(for: block.tone, in: rect)
}

@MainActor
private final class ZoomPlayback {
    nonisolated(unsafe) private var timer: Timer?
    private let duration = 0.48

    func play(_ tick: @escaping @MainActor (CGFloat) -> Bool) {
        stop()
        let start = CACurrentMediaTime()
        let duration = duration
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            let raw = min(1, (CACurrentMediaTime() - start) / duration)
            let eased = 1 - pow(1 - raw, 3)
            let keep = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                let shouldContinue = tick(CGFloat(eased))
                if raw >= 1 || !shouldContinue {
                    self.timer = nil
                    return false
                }
                return true
            }
            if raw >= 1 || !keep {
                timer.invalidate()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}

private struct Flight {
    var from: FileNode
    var to: FileNode
    var mode: ZoomMode
}

private enum ZoomMode {
    case zoomIn
    case zoomOut
    case crossfade

    static func between(_ from: FileNode, _ to: FileNode) -> ZoomMode {
        if from.children.contains(where: { $0.id == to.id }) { return .zoomIn }
        if to.children.contains(where: { $0.id == from.id }) { return .zoomOut }
        return .crossfade
    }
}

private struct HitKey: Equatable {
    var revision: Int
    var query: String
    var folderIDs: [UUID]
}

private final class HitCache {
    private var key: HitKey?
    private var ids: Set<UUID> = []

    func lookup(_ key: HitKey, make: () -> Set<UUID>) -> Set<UUID> {
        if key == self.key { return ids }
        self.key = key
        ids = make()
        return ids
    }
}

private struct LayoutKey: Hashable {
    var owner: UUID
    var width: Int
    var height: Int
    var revision: Int
}

private final class LayoutMemo {
    private var stored: [LayoutKey: [PlacedBlock]] = [:]
    private var order: [LayoutKey] = []
    private let capacity = 8

    func blocks(owner: UUID, size: CGSize, revision: Int, make: () -> [PlacedBlock]) -> [PlacedBlock] {
        let key = LayoutKey(
            owner: owner,
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded()),
            revision: revision
        )
        if let hit = stored[key] { return hit }
        let made = make()
        if stored.count >= capacity, !order.isEmpty {
            let evicted = order.removeFirst()
            stored.removeValue(forKey: evicted)
        }
        stored[key] = made
        order.append(key)
        return made
    }
}

private struct PlacedBlock {
    var node: FileNode
    var rect: CGRect
    var tone: BlockTone
    var measure: LabelMeasure?
    /// Mask geometry for `preparedRect`. Unused while a zoom has moved `rect`.
    var prepared: MarkDrawing?
    var preparedRect: CGRect
}

@MainActor
private struct LabelMeasure {
    private static let nameAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10, weight: .medium)
    ]
    private static let sizeAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10)
    ]

    var nameWidth: CGFloat
    var nameHeight: CGFloat
    var sizeWidth: CGFloat
    var sizeHeight: CGFloat
    var sizeText: String

    init(node: FileNode) {
        let nameBox = (node.name as NSString).size(withAttributes: Self.nameAttributes)
        nameWidth = nameBox.width
        nameHeight = min(max(nameBox.height, 11), 16)
        sizeText = ByteFormat.bytes(node.byteSize)
        let sizeBox = (sizeText as NSString).size(withAttributes: Self.sizeAttributes)
        sizeWidth = sizeBox.width
        sizeHeight = min(max(sizeBox.height, 11), 16)
    }
}

private struct TreemapPicture {
    var siblings: [PlacedBlock]
    var children: [PlacedBlock]
    var plate: CGRect?
    var plateColor: Color?
    var plateOpacity: Double
    var siblingOpacity: CGFloat
    var childOpacity: CGFloat
    var bright: Set<UUID>?

    init(
        siblings: [PlacedBlock],
        children: [PlacedBlock],
        plate: CGRect?,
        plateColor: Color? = nil,
        plateOpacity: Double,
        siblingOpacity: CGFloat,
        childOpacity: CGFloat
    ) {
        self.siblings = siblings
        self.children = children
        self.plate = plate
        self.plateColor = plateColor
        self.plateOpacity = plateOpacity
        self.siblingOpacity = siblingOpacity
        self.childOpacity = childOpacity
        self.bright = nil
    }
}

private func mapIntoFocus(_ rect: CGRect, focus: CGRect, canvas: CGSize, t: CGFloat) -> CGRect {
    let startScale = min(focus.width / canvas.width, focus.height / canvas.height)
    let startX = focus.midX - canvas.width * startScale / 2
    let startY = focus.midY - canvas.height * startScale / 2
    let scale = lerp(startScale, 1, t)
    let originX = lerp(startX, 0, t)
    let originY = lerp(startY, 0, t)
    return CGRect(
        x: originX + rect.minX * scale,
        y: originY + rect.minY * scale,
        width: rect.width * scale,
        height: rect.height * scale
    )
}

private func lerpRect(_ from: CGRect, _ to: CGRect, _ t: CGFloat) -> CGRect {
    CGRect(
        x: lerp(from.minX, to.minX, t),
        y: lerp(from.minY, to.minY, t),
        width: lerp(from.width, to.width, t),
        height: lerp(from.height, to.height, t)
    )
}

private func lerp(_ from: CGFloat, _ to: CGFloat, _ t: CGFloat) -> CGFloat {
    from + (to - from) * t
}

private func fadeIn(_ t: CGFloat) -> CGFloat {
    let x = min(1, max(0, (t - 0.05) / 0.5))
    return x * x * (3 - 2 * x)
}

/// Plate tight around the name, and the size when that second line is shown.
/// Same thresholds as the label itself: a block that skips the label never gets a plate.
private func labelPlate(in rect: CGRect, measure: LabelMeasure, showsSize: Bool) -> CGRect? {
    guard measure.nameWidth > 0.5 else { return nil }
    var textWidth = measure.nameWidth
    let top = rect.minY + 9 - measure.nameHeight / 2
    var bottom = rect.minY + 9 + measure.nameHeight / 2
    if showsSize {
        textWidth = max(textWidth, measure.sizeWidth)
        bottom = max(bottom, rect.minY + 21 + measure.sizeHeight / 2)
    }
    let padX: CGFloat = 4
    let padY: CGFloat = 2.5
    let plate = CGRect(
        x: rect.minX + 5 - padX,
        y: top - padY,
        width: textWidth + padX * 2,
        height: bottom - top + padY * 2
    )
    let fitted = plate.intersection(rect.insetBy(dx: 2, dy: 1))
    guard !fitted.isNull, !fitted.isInfinite, fitted.width > 3, fitted.height > 3 else { return nil }
    return fitted
}

/// Solid plate behind the words so the mask stops at the letters.
/// Amber only when this block is the selection. The rest of the block keeps its mask.
private func paintLabelBacking(selected: Bool, plate: CGRect, opacity: CGFloat, on context: inout GraphicsContext) {
    let color = selected ? Theme.selection : Theme.labelInk
    context.fill(Path(plate), with: .color(color.opacity(opacity)))
}
