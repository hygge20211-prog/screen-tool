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

    init(screen: NSScreen, backgroundCGImage: CGImage) {
        self.targetScreen = screen
        self.content = LassoContentView(backgroundCGImage: backgroundCGImage, scale: screen.backingScaleFactor)

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
    private var currentPath: NSBezierPath?   // while dragging
    private var finishedPath: NSBezierPath?  // after mouse up

    private lazy var backgroundNSImage: NSImage = {
        NSImage(cgImage: backgroundCGImage, size: NSSize(
            width: CGFloat(backgroundCGImage.width) / scale,
            height: CGFloat(backgroundCGImage.height) / scale
        ))
    }()

    // Toolbar
    private var confirmBtn: NSButton!
    private var clearBtn: NSButton!
    private var cancelBtn: NSButton!
    private var hintLabel: NSTextField!

    init(backgroundCGImage: CGImage, scale: CGFloat) {
        self.backgroundCGImage = backgroundCGImage
        self.scale = scale
        super.init(frame: .zero)
        buildToolbar()
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

        hintLabel = NSTextField(labelWithString: "拖动鼠标画出选区，释放后点「确认」")
        hintLabel.font = .systemFont(ofSize: 14, weight: .medium)
        hintLabel.textColor = .white
        hintLabel.alignment = .center
        hintLabel.isBezeled = false
        hintLabel.drawsBackground = false
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        [cancelBtn, clearBtn, confirmBtn, hintLabel].forEach {
            ($0 as AnyObject).setValue(false, forKey: "translatesAutoresizingMaskIntoConstraints")
            addSubview($0 as! NSView)
        }

        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        clearBtn.translatesAutoresizingMaskIntoConstraints = false
        confirmBtn.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.topAnchor.constraint(equalTo: topAnchor, constant: 24),

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

    // MARK: - Mouse Tracking

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        currentPath = NSBezierPath()
        currentPath?.move(to: pt)
        finishedPath = nil
        updateButtons()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        currentPath?.line(to: pt)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPath?.close()
        finishedPath = currentPath
        currentPath = nil
        updateButtons()
        needsDisplay = true
    }

    private func updateButtons() {
        let hasPath = finishedPath != nil
        confirmBtn.isEnabled = hasPath
        clearBtn.isEnabled = hasPath
        hintLabel.isHidden = hasPath
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // 1. Background screenshot
        backgroundNSImage.draw(in: bounds)

        // 2. Dark veil
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(rect: bounds).fill()

        // 3. Lasso selection – clear the veil inside and draw border
        let displayPath = currentPath ?? finishedPath
        if let p = displayPath {
            NSGraphicsContext.saveGraphicsState()
            p.setClip()
            backgroundNSImage.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()

            NSColor.white.setStroke()
            p.lineWidth = 2
            let dashPattern: [CGFloat] = [8, 4]
            p.setLineDash(dashPattern, count: 2, phase: 0)
            p.stroke()

            // Highlight corner dot at start
            if let first = firstPoint(of: p) {
                let dot = NSBezierPath(ovalIn: NSRect(x: first.x - 4, y: first.y - 4, width: 8, height: 8))
                NSColor.white.setFill()
                dot.fill()
            }
        }
    }

    private func firstPoint(of path: NSBezierPath) -> NSPoint? {
        guard path.elementCount > 0 else { return nil }
        var pts = [NSPoint](repeating: .zero, count: 3)
        path.element(at: 0, associatedPoints: &pts)
        return pts[0]
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: cancel()         // Escape
        case 36, 76: confirm()    // Return / Enter
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Actions

    @objc private func confirm() {
        guard let path = finishedPath, confirmBtn.isEnabled else { return }
        onConfirm?(path)
    }

    @objc private func clear() {
        finishedPath = nil
        currentPath = nil
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
            switch element(at: i, associatedPoints: &pts) {
            case .moveTo:    path.move(to: pts[0])
            case .lineTo:    path.addLine(to: pts[0])
            case .curveTo:   path.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}
