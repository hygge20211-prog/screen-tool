import UIKit

protocol LassoOverlayDelegate: AnyObject {
    func lassoDidConfirm(path: UIBezierPath, in size: CGSize)
    func lassoDidCancel()
}

/// Full-screen transparent overlay for drawing a freehand lasso selection
class LassoOverlayViewController: UIViewController {

    weak var delegate: LassoOverlayDelegate?

    private let canvasView = LassoCanvasView()
    private let toolbar = UIStackView()
    private let confirmButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    private let hintLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        setupCanvas()
        setupToolbar()
        setupHint()
    }

    private func setupCanvas() {
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.backgroundColor = .clear
        view.addSubview(canvasView)
        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: view.topAnchor),
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        canvasView.onPathChanged = { [weak self] _ in
            self?.updateButtons()
        }
    }

    private func setupToolbar() {
        cancelButton.setTitle("取消", for: .normal)
        clearButton.setTitle("重画", for: .normal)
        confirmButton.setTitle("确认截图", for: .normal)

        for btn in [cancelButton, clearButton, confirmButton] {
            btn.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
            btn.backgroundColor = UIColor.white.withAlphaComponent(0.9)
            btn.setTitleColor(.systemBlue, for: .normal)
            btn.layer.cornerRadius = 10
            btn.contentEdgeInsets = UIEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        }
        confirmButton.setTitleColor(.white, for: .normal)
        confirmButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.9)

        cancelButton.addTarget(self, action: #selector(didTapCancel), for: .touchUpInside)
        clearButton.addTarget(self, action: #selector(didTapClear), for: .touchUpInside)
        confirmButton.addTarget(self, action: #selector(didTapConfirm), for: .touchUpInside)

        toolbar.axis = .horizontal
        toolbar.spacing = 16
        toolbar.alignment = .center
        toolbar.distribution = .equalSpacing
        toolbar.addArrangedSubview(cancelButton)
        toolbar.addArrangedSubview(clearButton)
        toolbar.addArrangedSubview(confirmButton)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let container = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        container.layer.cornerRadius = 16
        container.clipsToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false
        container.contentView.addSubview(toolbar)
        view.addSubview(container)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.contentView.topAnchor, constant: 12),
            toolbar.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(equalTo: container.contentView.trailingAnchor, constant: -16),
            toolbar.bottomAnchor.constraint(equalTo: container.contentView.bottomAnchor, constant: -12),
            container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
        updateButtons()
    }

    private func setupHint() {
        hintLabel.text = "用手指或触控笔画出选区"
        hintLabel.font = .systemFont(ofSize: 15, weight: .medium)
        hintLabel.textColor = .white
        hintLabel.textAlignment = .center
        hintLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        hintLabel.layer.cornerRadius = 10
        hintLabel.clipsToBounds = true
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)
        NSLayoutConstraint.activate([
            hintLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintLabel.heightAnchor.constraint(equalToConstant: 36),
            hintLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.6)
        ])
    }

    private func updateButtons() {
        let hasPath = canvasView.hasPath
        confirmButton.isEnabled = hasPath
        clearButton.isEnabled = hasPath
        confirmButton.alpha = hasPath ? 1.0 : 0.5
        hintLabel.isHidden = hasPath
    }

    @objc private func didTapCancel() {
        delegate?.lassoDidCancel()
        dismiss(animated: true)
    }

    @objc private func didTapClear() {
        canvasView.clear()
        updateButtons()
    }

    @objc private func didTapConfirm() {
        guard let path = canvasView.currentPath else { return }
        delegate?.lassoDidConfirm(path: path, in: canvasView.bounds.size)
        dismiss(animated: true)
    }
}

// MARK: - LassoCanvasView

class LassoCanvasView: UIView {

    var onPathChanged: ((UIBezierPath?) -> Void)?
    private(set) var currentPath: UIBezierPath?
    private var previewPath: UIBezierPath?
    private let shapeLayer = CAShapeLayer()
    private let fillLayer = CAShapeLayer()

    var hasPath: Bool { currentPath != nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        fillLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.15).cgColor
        fillLayer.strokeColor = UIColor.clear.cgColor
        layer.addSublayer(fillLayer)

        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.strokeColor = UIColor.systemBlue.cgColor
        shapeLayer.lineWidth = 2.5
        shapeLayer.lineDashPattern = [8, 4]
        shapeLayer.lineCap = .round
        shapeLayer.lineJoin = .round
        layer.addSublayer(shapeLayer)
    }

    func clear() {
        currentPath = nil
        previewPath = nil
        shapeLayer.path = nil
        fillLayer.path = nil
        onPathChanged?(nil)
    }

    // Support both finger and Apple Pencil
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let path = UIBezierPath()
        path.move(to: touch.location(in: self))
        previewPath = path
        currentPath = nil
        updateDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        // Use coalesced touches for smoother Apple Pencil input
        let coalescedTouches = event?.coalescedTouches(for: touch) ?? [touch]
        for t in coalescedTouches {
            previewPath?.addLine(to: t.location(in: self))
        }
        updateDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        previewPath?.close()
        currentPath = previewPath
        previewPath = nil
        updateDisplay()
        onPathChanged?(currentPath)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func updateDisplay() {
        let displayPath = previewPath ?? currentPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.path = displayPath?.cgPath
        fillLayer.path = displayPath?.cgPath
        CATransaction.commit()
    }
}
