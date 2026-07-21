import UIKit

extension UIFont {
    /// Telegram's counter type: SF Rounded + tabular digits — every numbered
    /// badge and count label in the app draws from this one recipe.
    static func roundedCounter(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

extension UIButton {
    /// iMessage-style floating control: on iOS 26 the symbol rides a circular
    /// Liquid Glass button (the system look for controls floating over
    /// content — back, compose, close); earlier it stays the flat symbol.
    /// Only for free-floating buttons — controls inside pills, rows, or
    /// keyboards keep their plain style, matching Messages.
    func applyGlassSymbol(_ symbol: String, pointSize: CGFloat = 15) {
        if #available(iOS 26.0, *) {
            var config = UIButton.Configuration.glass()
            config.image = UIImage(systemName: symbol)
            config.cornerStyle = .capsule
            config.preferredSymbolConfigurationForImage = .init(pointSize: pointSize, weight: .semibold)
            configuration = config
        } else {
            setImage(UIImage(systemName: symbol), for: .normal)
        }
    }
}

/// A Liquid Glass surface for custom floating chrome. On iOS 26 it's a real
/// interactive `UIGlassEffect`; older systems fall back to a chrome-material
/// blur, which reads as translucent glass too.
enum GlassChrome {
    static func makeView(interactive: Bool) -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = interactive
            return UIVisualEffectView(effect: glass)
        }
        return UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    }
}

/// The home's compact tab switcher: a small glass capsule floating in the
/// bottom-LEFT corner, paired with whatever action button a tab floats
/// bottom-right. Hand-rolled on purpose: the iOS 26 system tab bar auto-sizes
/// but always owns the bottom center — the only native way to left-align the
/// group is a `.search`-role tab's detached circle, whose semantics ("select
/// the search tab") can't host a ＋ menu.
///
/// Recipe follows Telegram's TabBarComponent at its exact metrics: a 64pt bar
/// (56pt items + 4pt inner inset), icon over a semibold-10 label (icon area
/// 8pt from the top, label 8pt from the bottom), equal-width items padded
/// ~10pt, capsule radius = height/2, and — the detail that makes it read
/// finished — a sliding selection capsule behind the active item
/// (Telegram's selectionFrame, the full 56pt item).
final class HomeTabPill: UIView {
    var onSelect: ((Int) -> Void)?

    private var buttons: [UIButton] = []
    /// The tab symbols, kept to pick each tab's own selection animation.
    private let symbols: [String]
    /// The sliding selected-item capsule. Telegram's is the system liquid
    /// lens (private API, warps the content below); the public equivalent is
    /// an interactive `UIGlassEffect` — real refraction, not a flat fill —
    /// resting on a faint tint like their lens's restingBackgroundColor.
    /// Pre-26 falls back to the flat current-chat-pill fill.
    private let selection: UIView = {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            glass.tintColor = UIColor.label.withAlphaComponent(0.08)
            let view = UIVisualEffectView(effect: glass)
            view.layer.cornerRadius = 28
            view.clipsToBounds = true
            return view
        }
        let view = UIView()
        view.backgroundColor = UIColor.label.withAlphaComponent(0.08)
        view.layer.cornerRadius = 28
        return view
    }()
    private var selectedIndex = 0

    init(items: [(title: String, symbol: String)]) {
        symbols = items.map(\.symbol)
        super.init(frame: .zero)
        let glass = GlassChrome.makeView(interactive: true)
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.layer.cornerRadius = 32
        glass.clipsToBounds = true
        addSubview(glass)

        glass.contentView.addSubview(selection)

        buttons = items.enumerated().map { index, item in
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: item.symbol)
            config.imagePlacement = .top
            config.imagePadding = 3
            // ~17pt matches the drawn area of Telegram's ~28px tab icons;
            // 20pt SF symbols read oversized next to them.
            config.preferredSymbolConfigurationForImage = .init(pointSize: 17, weight: .medium)
            config.attributedTitle = AttributedString(
                item.title,
                attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 10, weight: .semibold)])
            )
            config.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12)
            let button = UIButton(configuration: config)
            button.addAction(UIAction { [weak self] _ in
                self?.select(index, animated: true)
                self?.onSelect?(index)
            }, for: .touchUpInside)
            return button
        }

        let stack = UIStackView(arrangedSubviews: buttons)
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -4),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            heightAnchor.constraint(equalToConstant: 64),
        ])
        select(0, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        selection.frame = selectionFrame()
    }

    private func selectionFrame() -> CGRect {
        guard buttons.indices.contains(selectedIndex) else { return .zero }
        return buttons[selectedIndex].convert(buttons[selectedIndex].bounds, to: selection.superview)
            .insetBy(dx: 0, dy: 4)
    }

    func select(_ index: Int, animated: Bool) {
        let changed = selectedIndex != index
        selectedIndex = index
        for (i, button) in buttons.enumerated() {
            // The active tab gets the accent, like Telegram's
            // selectedTextColor — crossfaded, never snapped.
            let target: UIColor = i == index ? tintColor : .secondaryLabel
            if animated, button.tintColor != target {
                UIView.transition(
                    with: button, duration: 0.22,
                    options: [.transitionCrossDissolve, .allowUserInteraction]
                ) { button.tintColor = target }
            } else {
                button.tintColor = target
            }
        }
        // Telegram rests each tab icon on the last frame of a hand-animated
        // 48pt Lottie and replays it once on every select. Same idea, hand-
        // keyed in Core Animation per icon — in-place character moves with
        // overshoot, never a size pop.
        if animated, changed, buttons.indices.contains(index) {
            playSelectionAnimation(on: buttons[index], symbol: symbols[index])
        }
        layoutIfNeeded()
        let settle = { self.selection.frame = self.selectionFrame() }
        if animated {
            UIView.animate(withDuration: 0.35, delay: 0,
                           usingSpringWithDamping: 0.8, initialSpringVelocity: 0.2,
                           options: .curveEaseOut, animations: settle)
        } else {
            settle()
        }
    }

    /// The character set: the gear engages with a springy quarter-turn, the
    /// bubbles rock against each other like a conversation, the folder does
    /// a small hop-and-tip as if opening. All one-shot and size-stable.
    private func playSelectionAnimation(on button: UIButton, symbol: String) {
        guard let layer = button.imageView?.layer else { return }
        layer.removeAnimation(forKey: "tabSelect")
        let animation: CAAnimation
        switch symbol {
        case "gearshape":
            // A quarter turn lands on gearshape's 8-tooth symmetry, so the
            // snap back to the model value after the spring is invisible.
            let spin = CASpringAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = CGFloat.pi / 2
            spin.mass = 1
            spin.stiffness = 170
            spin.damping = 13
            spin.initialVelocity = 4
            spin.duration = spin.settlingDuration
            animation = spin
        case "bubble.left.and.bubble.right":
            animation = Self.characterMove(
                rotationDegrees: [0, 8, -6, 3, 0],
                x: [0, 1.2, -1.2, 0.4, 0],
                y: [0, 0, 0, 0, 0],
                duration: 0.55
            )
        default: // the folder, and any future tab without its own move
            animation = Self.characterMove(
                rotationDegrees: [0, -7, 3, -1, 0],
                x: [0, 0, 0, 0, 0],
                y: [0, -2.5, 0.3, -0.6, 0],
                duration: 0.5
            )
        }
        layer.add(animation, forKey: "tabSelect")
    }

    /// A grouped in-place keyframe move (tilt + nudge), eased per segment —
    /// the hand-keyed stand-in for Telegram's per-icon Lottie files.
    private static func characterMove(
        rotationDegrees: [CGFloat], x: [CGFloat], y: [CGFloat], duration: CFTimeInterval
    ) -> CAAnimation {
        func keyframes(_ keyPath: String, _ values: [CGFloat]) -> CAKeyframeAnimation {
            let anim = CAKeyframeAnimation(keyPath: keyPath)
            anim.values = values
            anim.timingFunctions = Array(
                repeating: CAMediaTimingFunction(name: .easeInEaseOut),
                count: max(values.count - 1, 1)
            )
            return anim
        }
        let group = CAAnimationGroup()
        group.animations = [
            keyframes("transform.rotation.z", rotationDegrees.map { $0 * .pi / 180 }),
            keyframes("transform.translation.x", x),
            keyframes("transform.translation.y", y),
        ]
        group.duration = duration
        return group
    }
}
