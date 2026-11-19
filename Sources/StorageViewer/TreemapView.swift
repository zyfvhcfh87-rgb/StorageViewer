import AppKit
import StorageViewerCore
import SwiftUI

struct TreemapView: View {
    var folder: FileNode
    var selection: UUID?
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
    @State private var hoveredID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let snapshot = picture(in: geo.size)
            let renderKey = BaseRenderKey(
                folderID: folder.id,
                flightFromID: flight?.from.id,
                flightToID: flight?.to.id,
                progress: progress,
                selection: selection,
                filter: filter,
                revision: revision,
                width: geo.size.width,
                height: geo.size.height
            )
            ZStack {
                BaseTreemapCanvas(
                    renderKey: renderKey,
                    snapshot: snapshot,
                    selection: selection,
                    revision: revision,
                    textCache: textCache
                )
                .equatable()
                .allowsHitTesting(false)

                HoverWaveOverlay(
                    snapshot: snapshot,
                    folderID: folder.id,
                    hovered: effectiveHovered,
                    selection: selection,
                    revision: revision,
                    reduceMotion: reduceMotion,
                    textCache: textCache
                )
                .allowsHitTesting(false)

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
                    let node = hit(location, in: snapshot)
                    let nextID = node?.id
                    if hoveredID != nextID {
                        hoveredID = nextID
                        onHover(node)
                    }
                case .ended:
                    if hoveredID != nil {
                        hoveredID = nil
                        onHover(nil)
                    }
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
            hoveredID = nil
        }
        .onChange(of: folder.id) { _, _ in
            hoveredID = nil
            beginFlight(to: folder)
        }
        .onChange(of: revision) { _, _ in
            hoveredID = nil
        }
    }

    private var effectiveHovered: UUID? {
        guard let hoveredID, hoveredID != selection else { return nil }
        return hoveredID
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
        paddedBlockRect(rect)
    }
}

private struct BaseRenderKey: Equatable {
    var folderID: UUID
    var flightFromID: UUID?
    var flightToID: UUID?
    var progress: CGFloat
    var selection: UUID?
    var filter: String
    var revision: Int
    var width: CGFloat
    var height: CGFloat
}

/// Static treemap layer (fills, BlockPattern masks, selection stroke, labels).
/// Equatable on `renderKey` (which intentionally excludes `hovered`), so moving
/// the cursor or running the 60 fps hover overlay never redraws the base map.
private struct BaseTreemapCanvas: View, Equatable {
    var renderKey: BaseRenderKey
    var snapshot: TreemapPicture
    var selection: UUID?
    var revision: Int
    var textCache: TextCache

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.renderKey == rhs.renderKey
    }

    var body: some View {
        Canvas { context, _ in
            drawBase(snapshot, in: context)
        }
    }

    private func drawBase(_ picture: TreemapPicture, in context: GraphicsContext) {
        for block in picture.siblings {
            fill(block, opacity: picture.siblingOpacity, bright: picture.bright, in: context)
        }
        if let plate = picture.plate, picture.plateOpacity > 0.01, let color = picture.plateColor {
            let rect = paddedBlockRect(plate)
            let path = Path(roundedRect: rect, cornerRadius: min(2, rect.height / 2))
            context.fill(path, with: .color(color.opacity(picture.plateOpacity)))
        }
        for block in picture.children {
            fill(block, opacity: picture.childOpacity, bright: picture.bright, in: context)
        }
        if picture.siblingOpacity > 0.4 {
            for block in picture.siblings {
                strokeSelectionAndLabel(block, opacity: picture.siblingOpacity, bright: picture.bright, in: context)
            }
        }
        if picture.childOpacity > 0.72 {
            for block in picture.children {
                strokeSelectionAndLabel(block, opacity: picture.childOpacity, bright: picture.bright, in: context)
            }
        }
    }

    private func fill(_ block: PlacedBlock, opacity: CGFloat, bright: Set<UUID>?, in context: GraphicsContext) {
        let rect = paddedBlockRect(block.rect)
        guard rect.width > 0.4, rect.height > 0.4, opacity > 0.01 else { return }
        let dimmed = isBlockDimmed(block.node, bright: bright)
        let strength = (dimmed ? 0.16 : 1) * opacity
        let path = Path(rect)
        let tone = block.tone
        var layer = context
        layer.clip(to: path)
        layer.fill(path, with: .color(Theme.color(for: block.node.category).opacity(strength)))
        if !dimmed, rect.width > 16, rect.height > 16, opacity > 0.4 {
            let mark = (tone.lightMark ? Color.white : Color.black).opacity(CGFloat(BlockPattern.markOpacity) * opacity)
            if let prepared = block.prepared, block.preparedRect.width > 0.01, block.preparedRect.height > 0.01 {
                if block.preparedRect != rect {
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

    private func strokeSelectionAndLabel(
        _ block: PlacedBlock,
        opacity: CGFloat,
        bright: Set<UUID>?,
        in context: GraphicsContext
    ) {
        let rect = paddedBlockRect(block.rect)
        guard rect.width > 2, rect.height > 2 else { return }
        let dimmed = isBlockDimmed(block.node, bright: bright)
        let selected = block.node.id == selection
        if selected {
            context.stroke(
                Path(rect.insetBy(dx: 1, dy: 1)),
                with: .color(Theme.selection.opacity(opacity)),
                lineWidth: 2
            )
        }
        drawBlockLabel(
            block,
            rect: rect,
            selected: selected,
            dimmed: dimmed,
            opacity: opacity,
            revision: revision,
            textCache: textCache,
            in: context
        )
    }
}

/// Lightweight overlay that animates ONLY the hovered block (and any smoothly fading trail)
/// at 60 fps using zero-blur vector ribbons, then replays that block's label on top.
/// Unmounts `TimelineView` completely when idle for 0% CPU at rest.
private struct HoverWaveOverlay: View {
    var snapshot: TreemapPicture
    var folderID: UUID
    var hovered: UUID?
    var selection: UUID?
    var revision: Int
    var reduceMotion: Bool
    var textCache: TextCache

    @State private var animator = HoverAnimator()
    @State private var running = false

    var body: some View {
        ZStack {
            Color.clear
            if reduceMotion {
                if let hovered {
                    Canvas { context, _ in
                        drawStaticHover(id: hovered, in: context)
                    }
                }
            } else if running {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { context, _ in
                        animator.advance(to: now)
                        drawAnimatedHovers(at: now, in: context)
                        if animator.isIdle {
                            DispatchQueue.main.async {
                                if animator.isIdle {
                                    running = false
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { syncTarget() }
        .onDisappear {
            animator.reset()
            running = false
        }
        .onChange(of: folderID) { _, _ in
            animator.reset()
            running = false
        }
        .onChange(of: hovered) { _, _ in
            syncTarget()
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced {
                running = false
            } else {
                syncTarget()
            }
        }
    }

    private func syncTarget() {
        let now = Date().timeIntervalSinceReferenceDate
        animator.setHovered(hovered, at: now)
        if !reduceMotion, (hovered != nil || !animator.isIdle) {
            running = true
        }
    }

    private func drawStaticHover(id: UUID, in context: GraphicsContext) {
        if snapshot.siblingOpacity > 0.4,
           let block = snapshot.siblings.first(where: { $0.node.id == id }) {
            paintHoverAndLabel(block, opacity: snapshot.siblingOpacity, intensity: 1, elapsed: 0, animate: false, in: context)
        }
        if snapshot.childOpacity > 0.72,
           let block = snapshot.children.first(where: { $0.node.id == id }) {
            paintHoverAndLabel(block, opacity: snapshot.childOpacity, intensity: 1, elapsed: 0, animate: false, in: context)
        }
    }

    private func drawAnimatedHovers(at now: Double, in context: GraphicsContext) {
        let ids = animator.activeIDs
        guard !ids.isEmpty else { return }
        if snapshot.siblingOpacity > 0.4 {
            for id in ids {
                guard let state = animator.state(for: id, at: now),
                      let block = snapshot.siblings.first(where: { $0.node.id == id })
                else { continue }
                paintHoverAndLabel(
                    block,
                    opacity: snapshot.siblingOpacity,
                    intensity: state.intensity,
                    elapsed: state.elapsed,
                    animate: true,
                    in: context
                )
            }
        }
        if snapshot.childOpacity > 0.72 {
            for id in ids {
                guard let state = animator.state(for: id, at: now),
                      let block = snapshot.children.first(where: { $0.node.id == id })
                else { continue }
                paintHoverAndLabel(
                    block,
                    opacity: snapshot.childOpacity,
                    intensity: state.intensity,
                    elapsed: state.elapsed,
                    animate: true,
                    in: context
                )
            }
        }
    }

    private func paintHoverAndLabel(
        _ block: PlacedBlock,
        opacity: CGFloat,
        intensity: CGFloat,
        elapsed: Double,
        animate: Bool,
        in context: GraphicsContext
    ) {
        guard block.node.id != selection else { return }
        let dimmed = isBlockDimmed(block.node, bright: snapshot.bright)
        guard !dimmed else { return }
        let rect = paddedBlockRect(block.rect)
        guard rect.width > 2, rect.height > 2 else { return }
        paintHover(
            block: block,
            rect: rect,
            intensity: intensity,
            elapsed: elapsed,
            animate: animate,
            opacity: opacity,
            in: context
        )
        drawBlockLabel(
            block,
            rect: rect,
            selected: false,
            dimmed: false,
            opacity: opacity,
            revision: revision,
            textCache: textCache,
            in: context
        )
    }

    /// Zero-blur, pure-vector COSS hover surface + soft feathered inward-flowing waves.
    /// Uses layered translucent ribbons with `.plusLighter` blend mode directly on the context
    /// (zero offscreen bitmaps, zero Gaussian blur filters -> sub-millisecond 60 fps).
    private func paintHover(
        block: PlacedBlock,
        rect: CGRect,
        intensity: CGFloat,
        elapsed: Double,
        animate: Bool,
        opacity: CGFloat,
        in context: GraphicsContext
    ) {
        let alpha = intensity * opacity
        guard alpha > 0.01 else { return }

        let minDim = min(rect.width, rect.height)
        let lightScale = hoverLightScale(for: block.node.category)
        let rimPulse = animate ? HoverWaveField.rimPulse(elapsed: elapsed) : 0
        let clipPath = Path(rect)

        var clipped = context
        clipped.clip(to: clipPath)

        // 1. Subtle COSS top-down surface sheen (rich saturation, no milky washout).
        let tinyShimmer: CGFloat = (animate && minDim < HoverWaveField.minimumWaveDimension) ? 0.04 * rimPulse : 0
        let sheen = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [
                .init(color: Color.white.opacity((0.08 + tinyShimmer) * lightScale * alpha), location: 0.0),
                .init(color: Color.white.opacity((0.02 + tinyShimmer * 0.5) * lightScale * alpha), location: 0.45),
                .init(color: Color.black.opacity(0.03 * alpha), location: 1.0),
            ]),
            startPoint: CGPoint(x: rect.midX, y: rect.minY),
            endPoint: CGPoint(x: rect.midX, y: rect.maxY)
        )
        clipped.fill(clipPath, with: sheen)

        // 2. Feathered inner perimeter glow (3 clipped concentric ribbons, zero blur).
        if minDim > 8 {
            var edgeAdditive = clipped
            edgeAdditive.blendMode = .plusLighter
            let outerW = min(14.0, max(4.0, minDim * 0.12))
            let midW = min(7.0, max(2.4, minDim * 0.06))
            let innerW = min(3.0, max(1.4, minDim * 0.025))
            let pulseBoost = 1.0 + 0.4 * rimPulse
            edgeAdditive.stroke(clipPath, with: .color(Color.white.opacity(0.045 * pulseBoost * lightScale * alpha)), lineWidth: outerW)
            edgeAdditive.stroke(clipPath, with: .color(Color.white.opacity(0.065 * pulseBoost * lightScale * alpha)), lineWidth: midW)
            edgeAdditive.stroke(clipPath, with: .color(Color.white.opacity(0.085 * pulseBoost * lightScale * alpha)), lineWidth: innerW)
        }

        // 3. Staggered organic waves flowing smoothly inward from the walls toward the center.
        if animate, minDim >= HoverWaveField.minimumWaveDimension {
            paintHoverWaves(
                rect: rect,
                minDim: minDim,
                elapsed: elapsed,
                lightScale: lightScale,
                alpha: alpha,
                in: &clipped
            )
        }

        // 4. Crisp COSS translucent hairline rim + subtle top-edge specular sheen.
        paintHoverRim(rect: rect, rimPulse: rimPulse, alpha: alpha, in: &clipped)
    }

    private func paintHoverWaves(
        rect: CGRect,
        minDim: CGFloat,
        elapsed: Double,
        lightScale: CGFloat,
        alpha: CGFloat,
        in context: inout GraphicsContext
    ) {
        let waves = HoverWaveField.activeWaves(elapsed: elapsed)
        guard !waves.isEmpty else { return }

        let segments = minDim > 220 ? 56 : 44
        let troughOuterW = min(14.0, max(4.5, minDim * 0.068))
        let troughCoreW = min(7.0, max(2.4, minDim * 0.034))
        let swellOuterW = min(20.0, max(6.0, minDim * 0.095))
        let swellMidW = min(12.0, max(3.8, minDim * 0.058))
        let swellInnerW = min(6.0, max(2.2, minDim * 0.030))
        let crestW = min(2.6, max(1.2, minDim * 0.014))

        var additive = context
        additive.blendMode = .plusLighter

        for wave in waves {
            let env = wave.envelope * alpha
            guard env > 0.006 else { continue }

            // Soft recessed trough trailing slightly behind the wave crest.
            let troughProgress = max(0, wave.progress - 0.055)
            let troughSample = HoverWaveField.sampleForProgress(troughProgress, index: wave.index)
            let troughPoints = HoverWaveField.contourPoints(
                in: rect,
                sample: troughSample,
                elapsed: elapsed,
                segments: segments,
                rippleMultiplier: 0.90
            )
            if let troughPath = smoothClosedPath(troughPoints) {
                context.stroke(
                    troughPath,
                    with: .color(Color.black.opacity(0.035 * env)),
                    style: StrokeStyle(lineWidth: troughOuterW, lineCap: .round, lineJoin: .round)
                )
                context.stroke(
                    troughPath,
                    with: .color(Color.black.opacity(0.045 * env)),
                    style: StrokeStyle(lineWidth: troughCoreW, lineCap: .round, lineJoin: .round)
                )
            }

            // Feathered luminous swell + directionally lit leading crest (soft Gaussian cross-section).
            let points = HoverWaveField.contourPoints(
                in: rect,
                sample: wave,
                elapsed: elapsed,
                segments: segments
            )
            guard let crestPath = smoothClosedPath(points) else { continue }
            let lum = env * lightScale
            additive.stroke(
                crestPath,
                with: .color(Color.white.opacity(0.030 * lum)),
                style: StrokeStyle(lineWidth: swellOuterW, lineCap: .round, lineJoin: .round)
            )
            additive.stroke(
                crestPath,
                with: .color(Color.white.opacity(0.045 * lum)),
                style: StrokeStyle(lineWidth: swellMidW, lineCap: .round, lineJoin: .round)
            )
            additive.stroke(
                crestPath,
                with: .color(Color.white.opacity(0.060 * lum)),
                style: StrokeStyle(lineWidth: swellInnerW, lineCap: .round, lineJoin: .round)
            )
            let crestShading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [
                    Color.white.opacity(0.14 * lum),
                    Color.white.opacity(0.06 * lum),
                ]),
                startPoint: CGPoint(x: rect.minX, y: rect.minY),
                endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            additive.stroke(
                crestPath,
                with: crestShading,
                style: StrokeStyle(lineWidth: crestW, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func paintHoverRim(rect: CGRect, rimPulse: CGFloat, alpha: CGFloat, in context: inout GraphicsContext) {
        let rimRect = rect.insetBy(dx: 0.5, dy: 0.5)
        if rimRect.width > 1, rimRect.height > 1 {
            let rimAlpha = (0.48 + 0.10 * rimPulse) * alpha
            context.stroke(
                Path(roundedRect: rimRect, cornerRadius: min(1.5, rimRect.height / 2)),
                with: .color(Color.white.opacity(rimAlpha)),
                lineWidth: 1
            )
        }
        guard rect.width > 12, rect.height > 8 else { return }
        var topLine = Path()
        topLine.move(to: CGPoint(x: rect.minX + 1, y: rect.minY + 1))
        topLine.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.minY + 1))
        let specular = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [
                .init(color: Color.white.opacity(0.0), location: 0.0),
                .init(color: Color.white.opacity(0.34 * alpha), location: 0.20),
                .init(color: Color.white.opacity(0.46 * alpha), location: 0.50),
                .init(color: Color.white.opacity(0.34 * alpha), location: 0.80),
                .init(color: Color.white.opacity(0.0), location: 1.0),
            ]),
            startPoint: CGPoint(x: rect.minX, y: rect.minY + 1),
            endPoint: CGPoint(x: rect.maxX, y: rect.minY + 1)
        )
        context.stroke(topLine, with: specular, lineWidth: 1)
    }

    private func hoverLightScale(for category: FileCategory) -> CGFloat {
        switch category {
        case .audio: return 0.78
        case .archives, .documents: return 0.90
        case .code, .images, .video, .other: return 1.0
        }
    }
}

private func paddedBlockRect(_ rect: CGRect) -> CGRect {
    let inset: CGFloat = rect.width > 12 && rect.height > 12 ? 2 : (rect.width > 5 && rect.height > 5 ? 1 : 0)
    guard inset > 0 else { return rect }
    return rect.insetBy(dx: inset, dy: inset)
}

private func isBlockDimmed(_ node: FileNode, bright: Set<UUID>?) -> Bool {
    guard let bright else { return false }
    return !bright.contains(node.id)
}

@MainActor
private func drawBlockLabel(
    _ block: PlacedBlock,
    rect: CGRect,
    selected: Bool,
    dimmed: Bool,
    opacity: CGFloat,
    revision: Int,
    textCache: TextCache,
    in context: GraphicsContext
) {
    guard !dimmed, rect.width > 44, rect.height > 14, opacity > 0.8 else { return }
    let measure = block.measure ?? LabelMeasure(node: block.node)
    var layer = context
    layer.clip(to: Path(rect.insetBy(dx: 2, dy: 1)))
    let ink = (selected ? Theme.onSelection : Theme.text).opacity(opacity)
    let showsSize = rect.height > 28 && rect.width > 72
    if let plate = labelPlate(in: rect, measure: measure, showsSize: showsSize) {
        paintLabelBacking(selected: selected, plate: plate, opacity: opacity, on: &layer)
    }
    var nameText = textCache.texts(for: block, measure: measure, revision: revision, in: context).name
    nameText.shading = .color(ink)
    layer.draw(
        nameText,
        at: CGPoint(x: rect.minX + 5, y: rect.minY + 9),
        anchor: .leading
    )
    if showsSize {
        var sizeText = textCache.texts(for: block, measure: measure, revision: revision, in: context).size
        sizeText.shading = .color(ink.opacity(0.78))
        layer.draw(
            sizeText,
            at: CGPoint(x: rect.minX + 5, y: rect.minY + 21),
            anchor: .leading
        )
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

/// Resolved label text per node, so a zoom flight does not lay out every label
/// again on every frame. Cleared whenever the tree revision changes.
private final class TextCache {
    private var key = ""
    private var entries: [UUID: (name: GraphicsContext.ResolvedText, size: GraphicsContext.ResolvedText)] = [:]

    func texts(
        for block: PlacedBlock,
        measure: LabelMeasure,
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
            size: context.resolve(Text(measure.sizeText).font(.system(size: 10)))
        )
        entries[block.node.id] = resolved
        return resolved
    }
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
    /// Mask geometry for `preparedRect`. A zoom moves `rect`, so it is drawn through a transform.
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

/// Reference wrapper around `HoverTrailState` so `Canvas` can advance smooth hover trails
/// at 60 fps without triggering SwiftUI state-mutation warnings during view evaluation.
@MainActor
private final class HoverAnimator {
    private var trail = HoverTrailState()

    var isIdle: Bool { trail.isIdle }
    var activeIDs: [UUID] { Array(trail.entries.keys) }

    func setHovered(_ id: UUID?, at now: Double) {
        trail.setHovered(id, at: now)
    }

    func advance(to now: Double) {
        trail.advance(to: now)
    }

    func reset() {
        trail.reset()
    }

    func state(for id: UUID, at now: Double) -> (intensity: CGFloat, elapsed: Double)? {
        trail.state(for: id, at: now)
    }
}

/// Closed C1-smooth curve passing through midpoints between consecutive samples.
private func smoothClosedPath(_ points: [CGPoint]) -> Path? {
    let count = points.count
    guard count >= 3 else { return nil }
    var path = Path()
    let last = points[count - 1]
    let first = points[0]
    path.move(to: CGPoint(x: (last.x + first.x) * 0.5, y: (last.y + first.y) * 0.5))
    for i in 0..<count {
        let current = points[i]
        let next = points[(i + 1) % count]
        let mid = CGPoint(x: (current.x + next.x) * 0.5, y: (current.y + next.y) * 0.5)
        path.addQuadCurve(to: mid, control: current)
    }
    path.closeSubpath()
    return path
}
