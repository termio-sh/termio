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
            // selectedTextColor — selection reads in color, not just weight.
            button.tintColor = i == index ? tintColor : .secondaryLabel
        }
        // Telegram plays the tab icon's selection animation on every switch;
        // the SF-symbol equivalent is a one-shot bounce.
        if animated, changed, buttons.indices.contains(index) {
            buttons[index].imageView?.addSymbolEffect(.bounce, options: .nonRepeating)
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
}
