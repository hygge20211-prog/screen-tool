import AppKit

protocol LassoOverlayDelegate: AnyObject {
    func lassoDidConfirm(path: NSBezierPath, canvasSize: NSSize, scale: CGFloat)
    func lassoDidCancel()
}

// MARK: - Panel

class LassoOverlayPanel: NSPanel {

    weak var lassoDelegate: LassoOverlayDelegate?
    private let targetScreen: NSScreen
    private let content: LassoContentView

    init(screen: NSScreen, backgroundCGImage: CGImage, mode: CaptureMode) {
        self.targetScreen = screen
        self.content = LassoContentView(backgroundCGImage: backgroundCGImage,
                                        scale: screen.backingScaleFactor,
                                        mode: mode)

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        contentView = content

        content.onConfirm = { [weak self] path in
            guard let self else { return }
            self.lassoDelegate?.lassoDidConfirm(
                path: path,
                canvasSize: self.content.bounds.size,
                scale: self.targetScreen.backingScaleFactor
            )
        }
        content.onCancel = { [weak self] in
            self?.lassoDelegate?.lassoDidCancel()
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Drawing View

class LassoContentView: NSView {

    var onConfirm: ((NSBezierPath) -> Void)?
    var onCancel: (() -> Void)?

    private let backgroundCGImage: CGImage
    private let scale: CGFloat
    private var mode: CaptureMode
    /// Where the background image is drawn (nil = fill the whole view, used for
    /// screen capture). For re-cropping an existing image it's an aspect-fit rect.
    var imageRect: NSRect?
    private var bgRect: NSRect { imageRect ?? bounds }
    private var points: [NSPoint] = []   // polygon vertices / freehand-lasso trail
    private var rectStart: NSPoint?      // rectangle mode: drag anchor
    private var rectEnd: NSPoint?        // rectangle mode: opposite corner
    private var cursor: NSPoint?         // live mouse position, for the rubber-band edge
    private var isDragging = false       // true while a freehand drag stroke is in progress
    private let snapRadius: CGFloat = 14  // cursor within this of the start point → snap-close

    private lazy var backgroundNSImage: NSImage = {
        NSImage(cgImage: backgroundCGImage, size: NSSize(
            width: CGFloat(backgroundCGImage.width) / scale,
            height: CGFloat(backgroundCGImage.height) / scale
        ))
    }()

    // Toolbar
    private var modeSelector: NSSegmentedControl!
    private var confirmBtn: NSButton!
    private var clearBtn: NSButton!
    private var cancelBtn: NSButton!
    private var hintLabel: NSTextField!

    private let modeOrder: [CaptureMode] = [.freeform, .rectangle]

    init(backgroundCGImage: CGImage, scale: CGFloat, mode: CaptureMode) {
        self.backgroundCGImage = backgroundCGImage
        self.scale = scale
        self.mode = mode
        super.init(frame: .zero)
        buildToolbar()
    }

    private var hintText: String {
        switch mode {
        case .freeform:  return "单击加顶点 / 按住拖动自由勾勒（可混用）→ 双击 · 回到起点 · 「确认截图」闭合　·　⌫ 撤销　Esc 取消"
        case .rectangle: return "按住拖动画出矩形 → 点「确认截图」截取　·　Esc 取消"
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true } // y increases downward – matches CGDisplayCreateImage

    // MARK: - Toolbar

    private func buildToolbar() {
        cancelBtn  = makeBtn("取消",    #selector(cancel))
        clearBtn   = makeBtn("重画",    #selector(clear))
        confirmBtn = makeBtn("确认截图 ✓", #selector(confirm))
        confirmBtn.bezelColor = .systemBlue
        confirmBtn.contentTintColor = .white
        confirmBtn.isEnabled = false
        clearBtn.isEnabled = false

        // Shape picker lives inside the capture overlay so the user switches
        // rectangle / polygon / lasso while capturing.
        modeSelector = NSSegmentedControl(labels: ["多边形 / 套索", "矩形"],
                                          trackingMode: .selectOne,
                                          target: self, action: #selector(modeChanged))
        modeSelector.selectedSegment = modeOrder.firstIndex(of: mode) ?? 0
        modeSelector.controlSize = .large

        hintLabel = NSTextField(labelWithString: hintText)
        hintLabel.font = .systemFont(ofSize: 14, weight: .medium)
        hintLabel.textColor = .white
        hintLabel.alignment = .center
        hintLabel.isBezeled = false
        hintLabel.drawsBackground = false
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let controls: [NSView] = [modeSelector, cancelBtn, clearBtn, confirmBtn, hintLabel]
        for control in controls {
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
        }

        NSLayoutConstraint.activate([
            modeSelector.centerXAnchor.constraint(equalTo: centerXAnchor),
            modeSelector.topAnchor.constraint(equalTo: topAnchor, constant: 22),

            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.topAnchor.constraint(equalTo: modeSelector.bottomAnchor, constant: 12),

            cancelBtn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -36),
            cancelBtn.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -150),

            clearBtn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -36),
            clearBtn.centerXAnchor.constraint(equalTo: centerXAnchor),

            confirmBtn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -36),
            confirmBtn.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 150)
        ])
    }

    private func makeBtn(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .large
        return b
    }

    @objc private func modeChanged() {
        let idx = modeSelector.selectedSegment
        guard modeOrder.indices.contains(idx) else { return }
        mode = modeOrder[idx]
        clear()                        // discard the in-progress selection
        hintLabel.stringValue = hintText
    }

    // MARK: - Mouse Tracking (per mode)

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        cursor = pt
        switch mode {
        case .rectangle:
            rectStart = pt; rectEnd = pt
        case .freeform:
            if event.clickCount >= 2 { confirm(); return }   // double-click finishes
            if nearStart(pt) { confirm(); return }            // click the start to close
            isDragging = false
            points.append(pt)                                 // a click = one vertex
        }
        updateButtons()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        cursor = pt
        switch mode {
        case .rectangle: rectEnd = pt
        case .freeform:  isDragging = true; points.append(pt)  // trace a freehand trail
        }
        updateButtons()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        switch mode {
        case .rectangle:
            rectEnd = pt
        case .freeform:
            // A freehand stroke released near the start auto-closes the loop.
            if isDragging, let last = points.last, nearStart(last) { confirm() }
        }
        isDragging = false
        updateButtons()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        if !points.isEmpty { needsDisplay = true }
    }

    /// True when `pt` is within the snap radius of the start vertex and a closeable loop exists.
    private func nearStart(_ pt: NSPoint) -> Bool {
        guard points.count >= 3, let first = points.first else { return false }
        return hypot(pt.x - first.x, pt.y - first.y) <= snapRadius
    }

    // Ensure mouseMoved is delivered across the whole overlay for the rubber-band edge.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func updateButtons() {
        switch mode {
        case .rectangle:
            confirmBtn.isEnabled = currentRect != nil
            clearBtn.isEnabled = rectStart != nil
        case .freeform:
            confirmBtn.isEnabled = points.count >= 3   // need at least a triangle
            clearBtn.isEnabled = !points.isEmpty
        }
    }

    /// The rectangle (in view points) for rectangle mode, or nil if too small.
    private var currentRect: NSRect? {
        guard let a = rectStart, let b = rectEnd else { return nil }
        let r = NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
                       width: abs(a.x - b.x), height: abs(a.y - b.y))
        return (r.width > 1 && r.height > 1) ? r : nil
    }

    /// The selection path for the current mode (closed, ready to crop).
    private func selectionPath() -> NSBezierPath? {
        switch mode {
        case .rectangle:
            guard let r = currentRect else { return nil }
            return NSBezierPath(rect: r)
        case .freeform:
            guard points.count >= 3 else { return nil }
            return polygonPath(closed: true)
        }
    }

    /// Closed polygon through all committed vertices.
    private func polygonPath(closed: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for p in points.dropFirst() { path.line(to: p) }
        if closed { path.close() }
        return path
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // 1. Background screenshot
        backgroundNSImage.draw(in: bgRect)

        // 2. Dark veil
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(rect: bounds).fill()

        if mode == .rectangle {
            drawRectangleSelection()
        } else {
            drawPathSelection()
        }
    }

    private func drawRectangleSelection() {
        guard let r = currentRect else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: r).setClip()
        backgroundNSImage.draw(in: bgRect)
        NSGraphicsContext.restoreGraphicsState()

        let border = NSBezierPath(rect: r)
        border.lineWidth = 2
        var dash: [CGFloat] = [8, 4]
        border.setLineDash(&dash, count: 2, phase: 0)
        NSColor.white.setStroke()
        border.stroke()
    }

    private func drawPathSelection() {
        guard !points.isEmpty else { return }

        // Un-dim the (provisionally closed) selection so it previews while building.
        if points.count >= 2 {
            NSGraphicsContext.saveGraphicsState()
            polygonPath(closed: true).setClip()
            backgroundNSImage.draw(in: bgRect)
            NSGraphicsContext.restoreGraphicsState()
        }

        // Committed edges (solid white)
        let edges = polygonPath(closed: false)
        edges.lineWidth = 2
        NSColor.white.setStroke()
        edges.stroke()

        // Closing edge (last → first), dashed
        if points.count >= 3, let first = points.first, let last = points.last {
            let closing = NSBezierPath()
            closing.move(to: last)
            closing.line(to: first)
            closing.lineWidth = 1.5
            var dash: [CGFloat] = [6, 4]
            closing.setLineDash(&dash, count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.5).setStroke()
            closing.stroke()
        }

        // Rubber band, snap halo and vertex handles for the freeform mode.
        guard mode == .freeform else { return }

        if let c = cursor, let last = points.last {
            let rubber = NSBezierPath()
            rubber.move(to: last)
            rubber.line(to: c)
            rubber.lineWidth = 1.5
            var dash: [CGFloat] = [8, 4]
            rubber.setLineDash(&dash, count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.8).setStroke()
            rubber.stroke()
        }

        let snapping = cursor.map(nearStart) ?? false
        if snapping, let first = points.first {
            let ring = NSBezierPath(ovalIn: NSRect(x: first.x - snapRadius, y: first.y - snapRadius,
                                                   width: snapRadius * 2, height: snapRadius * 2))
            NSColor.systemBlue.withAlphaComponent(0.25).setFill()
            ring.fill()
            ring.lineWidth = 1.5
            NSColor.systemBlue.setStroke()
            ring.stroke()
        }

        for (i, p) in points.enumerated() {
            let r: CGFloat = (i == 0) ? (snapping ? 7 : 5) : 3.5
            let dot = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            (i == 0 ? NSColor.systemBlue : NSColor.white).setFill()
            dot.fill()
            dot.lineWidth = 1
            NSColor.white.setStroke()
            dot.stroke()
        }
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: cancel()              // Escape
        case 36, 76: confirm()         // Return / Enter
        case 51: removeLastPoint()     // Delete / Backspace
        default: super.keyDown(with: event)
        }
    }

    private func removeLastPoint() {
        guard !points.isEmpty else { return }
        points.removeLast()
        updateButtons()
        needsDisplay = true
    }

    // MARK: - Actions

    @objc private func confirm() {
        guard let path = selectionPath() else { return }
        onConfirm?(path)
    }

    @objc private func clear() {
        points.removeAll()
        rectStart = nil
        rectEnd = nil
        cursor = nil
        updateButtons()
        needsDisplay = true
    }

    @objc private func cancel() {
        onCancel?()
    }
}

// MARK: - NSBezierPath → CGPath (needed for pre-macOS 14 compat)

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &pts)
            switch type {
            case .moveTo:    path.move(to: pts[0])
            case .lineTo:    path.addLine(to: pts[0])
            case .curveTo:   path.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .closePath: path.closeSubpath()
            default:
                // macOS 14 added .cubicCurveTo / .quadraticCurveTo (raw values 4 / 5)
                if type.rawValue == 4 {        // cubicCurveTo: 2 control points + end
                    path.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
                } else if type.rawValue == 5 { // quadraticCurveTo: 1 control point + end
                    path.addQuadCurve(to: pts[1], control: pts[0])
                }
            }
        }
        return path
    }
}
