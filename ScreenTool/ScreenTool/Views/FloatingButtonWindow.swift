import UIKit

/// A dedicated UIWindow that hosts the floating screenshot button.
/// Sits on top of all other windows and passes through touches not on the button.
class FloatingButtonWindow: UIWindow {

    let floatingButton = FloatingScreenshotButton()

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        backgroundColor = .clear
        windowLevel = UIWindow.Level.alert + 1
        isUserInteractionEnabled = true
        rootViewController = PassthroughViewController()
        addSubview(floatingButton)
        floatingButton.translatesAutoresizingMaskIntoConstraints = false
        // Initial position: right side, middle
        NSLayoutConstraint.activate([
            floatingButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            floatingButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            floatingButton.widthAnchor.constraint(equalToConstant: 56),
            floatingButton.heightAnchor.constraint(equalToConstant: 56)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // Pass through touches that land outside the floating button
        return hit == self || hit == rootViewController?.view ? nil : hit
    }
}

class PassthroughViewController: UIViewController {
    override func loadView() {
        view = PassthroughView()
        view.backgroundColor = .clear
    }
}

class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit == self ? nil : hit
    }
}

// MARK: - FloatingScreenshotButton

class FloatingScreenshotButton: UIButton {

    var onTap: (() -> Void)?
    private var panGesture: UIPanGestureRecognizer!
    private var positionConstraints: (trailing: NSLayoutConstraint, centerY: NSLayoutConstraint)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        layer.cornerRadius = 28
        backgroundColor = UIColor.systemBlue
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 3)

        let icon = UIImageView(image: UIImage(systemName: "photo.badge.plus"))
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26)
        ])

        addTarget(self, action: #selector(tapped), for: .touchUpInside)

        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(panGesture)
    }

    @objc private func tapped() {
        UIView.animate(withDuration: 0.1, animations: { self.transform = CGAffineTransform(scaleX: 0.9, y: 0.9) }) { _ in
            UIView.animate(withDuration: 0.1) { self.transform = .identity }
        }
        onTap?()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let superview = superview else { return }
        let translation = gesture.translation(in: superview)

        if gesture.state == .changed {
            center = CGPoint(
                x: max(28, min(superview.bounds.width - 28, center.x + translation.x)),
                y: max(28, min(superview.bounds.height - 28, center.y + translation.y))
            )
            gesture.setTranslation(.zero, in: superview)
        }

        if gesture.state == .ended {
            // Snap to nearest edge
            let midX = superview.bounds.midX
            let targetX: CGFloat = center.x < midX ? 28 : superview.bounds.width - 28
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5) {
                self.center = CGPoint(x: targetX, y: self.center.y)
            }
        }
    }
}
