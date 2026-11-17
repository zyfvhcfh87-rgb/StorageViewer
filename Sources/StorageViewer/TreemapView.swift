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
    @State private var textCache = TextCache()

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
        let key = "\(revision)\t\(query)\t" + folders.map(\.id.uuidString).joined(separator: ",")
        return hitCache.lookup(key) {
            var ids = Set<UUID>()
            for item in folders {
                ids.formUnion(NameFilter.folderHits(in: item.children, query: query))
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
            let lookup = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
            return layout.compactMap { item in
                guard let node = lookup[item.id] else { return nil }
                let tone = BlockTone(node: node)
                let pad = padded(item.rect)
                let prepared = pad.width > 16 && pad.height > 16 ? markDrawing(for: tone, in: pad) : nil
                return PlacedBlock(
                    node: node,
                    rect: item.rect,
                    tone: tone,
                    measure: LabelMeasure(node: node),
                    prepared: prepared,
                    preparedRect: pad
                )
            }
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
        for block in picture.siblings where picture.siblingOpacity > 0.4 {
            strokeAndLabel(block, opacity: picture.siblingOpacity, bright: picture.bright, in: context)
        }
        for block in picture.children where picture.childOpacity > 0.72 {
            strokeAndLabel(block, opacity: picture.childOpacity, bright: picture.bright, in: context)
        }
    }

    private func fill(_ block: PlacedBlock, opacity: CGFloat, bright: Set<UUID>?, in context: GraphicsContext) {
        let rect = padded(block.rect)
        guard rect.width > 0.4, rect.height > 0.4, opacity > 0.01 else { return }
        let dimmed = dimmed(block.node, bright: bright)
        let strength = (dimmed ? 0.16 : 1) * opacity
        let path = Path(rect)
        let tone = block.tone
        // A context copy keeps the clip local without paying for a transparency
        // layer on every block on every frame.
        var layer = context
        layer.clip(to: path)
        layer.fill(path, with: .color(Theme.color(for: block.node.category).opacity(strength)))
        if !dimmed, rect.width > 16, rect.height > 16, opacity > 0.4 {
            let mark = (tone.lightMark ? Color.white : Color.black).opacity(CGFloat(BlockPattern.markOpacity) * opacity)
            if let prepared = block.prepared, block.preparedRect.width > 0.01, block.preparedRect.height > 0.01 {
                if block.preparedRect != rect {
                    // A zoom moved this block. Reuse the geometry drawn at the settled size
                    // instead of rebuilding thousands of marks on every frame.
                    let scale = rect.width / block.preparedRect.width
                    var transform = CGAffineTransform(scaleX: scale, y: scale)
                    transform.tx = rect.minX - block.preparedRect.minX * scale
                    transform.ty = rect.minY - block.preparedRect.minY * scale
                    layer.transform = transform
                }
                paint(prepared, color: mark, into: &layer)
            } else {
                paint(markDrawing(for: tone, in: rect), color: mark, into: &layer)
            }
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
        var layer = context
        layer.clip(to: Path(rect.insetBy(dx: 2, dy: 1)))
        let ink = (selected ? Theme.onSelection : Theme.text).opacity(opacity)
        let showsSize = rect.height > 28 && rect.width > 72
        if let plate = labelPlate(in: rect, measure: block.measure, showsSize: showsSize) {
            paintLabelBacking(selected: selected, plate: plate, opacity: opacity, on: &layer)
        }
        var nameText = textCache.texts(for: block, revision: revision, in: context).name
        nameText.shading = .color(ink)
        layer.draw(
            nameText,
            at: CGPoint(x: rect.minX + 5, y: rect.minY + 9),
            anchor: .leading
        )
        if showsSize {
            var sizeText = textCache.texts(for: block, revision: revision, in: context).size
            sizeText.shading = .color(ink.opacity(0.78))
            layer.draw(
                sizeText,
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
/// The color hash is unchanged. The mask does not use the node id, so a rescan keeps it.
private struct BlockTone {
    var grain: BlockGrain
    var lightMark: Bool

    init(node: FileNode) {
        grain = BlockGrain.forName(node.name)
        lightMark = node.category == .other
    }
}

private struct MarkDrawing {
    var arcs: [(path: Path, width: CGFloat)] = []
    var fills = Path()
    var strokes: [(width: CGFloat, path: Path)] = []
}

private func markDrawing(for tone: BlockTone, in rect: CGRect) -> MarkDrawing {
    let primitives = tone.grain.pattern.primitives(in: rect, phaseX: tone.grain.phaseX, phaseY: tone.grain.phaseY)
    var drawing = MarkDrawing()
    var strokes: [CGFloat: Path] = [:]
    func addStroke(width: CGFloat, _ build: (inout Path) -> Void) {
        var piece = Path()
        build(&piece)
        var combined = strokes[width] ?? Path()
        combined.addPath(piece)
        strokes[width] = combined
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
            var path = Path()
            path.move(to: CGPoint(x: center.x + cos(start) * radius, y: center.y + sin(start) * radius))
            path.addArc(
                center: center,
                radius: radius,
                startAngle: .radians(start),
                endAngle: .radians(end),
                clockwise: false
            )
            drawing.arcs.append((path, width))
        }
    }
    drawing.strokes = strokes.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    return drawing
}

private func paint(_ drawing: MarkDrawing, color: Color, into layer: inout GraphicsContext) {
    let style = { (width: CGFloat) in
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .miter)
    }
    for arc in drawing.arcs {
        layer.stroke(arc.path, with: .color(color), style: style(arc.width))
    }
    layer.fill(drawing.fills, with: .color(color))
    for stroke in drawing.strokes {
        layer.stroke(stroke.path, with: .color(color), style: style(stroke.width))
    }
}

private final class ZoomPlayback: @unchecked Sendable {
    private var timer: Timer?
    private let duration = 0.48

    func play(_ tick: @escaping @MainActor (CGFloat) -> Bool) {
        timer?.invalidate()
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let raw = min(1, (CACurrentMediaTime() - start) / self.duration)
            let eased = 1 - pow(1 - raw, 3)
            let keep = MainActor.assumeIsolated {
                tick(CGFloat(eased))
            }
            if raw >= 1 || !keep {
                timer.invalidate()
                self.timer = nil
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
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

private final class HitCache {
    private var key = ""
    private var ids: Set<UUID> = []

    func lookup(_ key: String, make: () -> Set<UUID>) -> Set<UUID> {
        if key == self.key { return ids }
        self.key = key
        ids = make()
        return ids
    }
}

/// Resolved label text per node, so a zoom flight does not lay out every label
/// again on every frame. Cleared whenever the tree revision changes.
private final class TextCache {
    private var key = ""
    private var entries: [UUID: (name: GraphicsContext.ResolvedText, size: GraphicsContext.ResolvedText)] = [:]

    func texts(
        for block: PlacedBlock,
        revision: Int,
        in context: GraphicsContext
    ) -> (name: GraphicsContext.ResolvedText, size: GraphicsContext.ResolvedText) {
        let next = "\(revision)"
        if key != next {
            key = next
            entries.removeAll(keepingCapacity: true)
        }
        if let hit = entries[block.node.id] { return hit }
        if entries.count > 4_096 { entries.removeAll(keepingCapacity: true) }
        let resolved = (
            name: context.resolve(Text(block.node.name).font(.system(size: 10, weight: .medium))),
            size: context.resolve(Text(block.measure.sizeText).font(.system(size: 10)))
        )
        entries[block.node.id] = resolved
        return resolved
    }
}

private final class LayoutMemo {
    private var stored: [String: [PlacedBlock]] = [:]

    func blocks(owner: UUID, size: CGSize, revision: Int, make: () -> [PlacedBlock]) -> [PlacedBlock] {
        let key = "\(revision)-\(owner.uuidString)-\(Int(size.width.rounded()))-\(Int(size.height.rounded()))"
        if let hit = stored[key] { return hit }
        let made = make()
        if stored.count > 6 { stored.removeAll(keepingCapacity: true) }
        stored[key] = made
        return made
    }
}

private struct PlacedBlock {
    var node: FileNode
    var rect: CGRect
    var tone: BlockTone
    var measure: LabelMeasure
    /// Mask geometry for `preparedRect`. A zoom moves `rect`, so it is drawn through a transform.
    var prepared: MarkDrawing?
    var preparedRect: CGRect
}

private struct LabelMeasure {
    var nameWidth: CGFloat
    var nameHeight: CGFloat
    var sizeWidth: CGFloat
    var sizeHeight: CGFloat
    var sizeText: String

    init(node: FileNode) {
        let nameFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let nameBox = (node.name as NSString).size(withAttributes: [.font: nameFont])
        nameWidth = nameBox.width
        nameHeight = min(max(nameBox.height, 11), 16)
        sizeText = ByteFormat.bytes(node.byteSize)
        let sizeFont = NSFont.systemFont(ofSize: 10)
        let sizeBox = (sizeText as NSString).size(withAttributes: [.font: sizeFont])
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
private func paintLabelBacking(selected: Bool, plate: CGRect, opacity: CGFloat, on layer: inout GraphicsContext) {
    let color = selected ? Theme.selection : Theme.labelInk
    layer.fill(Path(plate), with: .color(color.opacity(opacity)))
}
