import SwiftUI
import TermioShared
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

    /// The Hugeicons twin of `applyGlassSymbol`, for floating buttons whose glyph
    /// should read from the same stroke family as the tab pill and sidebar rows
    /// (the ＋ compose buttons sit right beside the pill). `boxSize` is the
    /// glyph's drawn size in points; the stroke is the shared 1.5px-on-24 recipe.
    func applyGlassIcon(_ icon: HugeIcon, boxSize: CGFloat) {
        let image = icon.strokeImage(boxSize: boxSize)
        if #available(iOS 26.0, *) {
            var config = UIButton.Configuration.glass()
            config.image = image
            config.cornerStyle = .capsule
            configuration = config
        } else {
            setImage(image, for: .normal)
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

/// The home's compact tab switcher: one centered glass capsule floating above
/// the home indicator. Hand-rolled on purpose: the app keeps each tab's
/// navigation controller alive (and terminals outside those stacks) to avoid
/// tearing down libghostty surfaces, so a system `UITabBarController` cannot
/// own this navigation hierarchy.
///
/// The geometry follows the compact iOS tab-bar language: a 64pt bar (56pt
/// items + 4pt inner inset), icon over a short label, equal-width destinations,
/// and a sliding selection capsule behind the active item. State is redundant
/// by design: the selected destination has a stronger glyph, primary ink,
/// neutral enclosure, and the accessibility selected trait. The enclosure is
/// a tint rather than a second glass layer; stacking glass on glass made the
/// active state disappear over dark terminal themes.
final class HomeTabPill: UIView, UIGestureRecognizerDelegate {
    var onSelect: ((Int) -> Void)?

    private var buttons: [UIButton] = []
    private let titles: [String]
    /// One image per tab, same stroke weight in every state — selection is carried by ink color, the
    /// grey enclosure chip, and the bolder title, not by thickening the glyph.
    private let icons: [UIImage]
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private var isDraggingSelection = false
    private var dragOriginIndex = 0
    private var dragStartCenterX: CGFloat = 0
    /// UIKit lays the visual-effect content view out after this view. Keeping
    /// the reference lets us flush that inner pass before measuring a button
    /// for the manually framed selection capsule.
    private weak var glassContentView: UIView?

    /// A quiet, neutral enclosure lets the stronger monochrome glyph carry
    /// meaning without introducing a color that doesn't belong to Termio's
    /// black/white brand. Orange remains reserved for attention status.
    private let selection: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.13)
                : UIColor.black.withAlphaComponent(0.065)
        }
        view.layer.cornerRadius = 28
        view.layer.cornerCurve = .continuous
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }()
    private var selectedIndex = 0

    init(items: [(title: String, icon: HugeIcon)]) {
        titles = items.map(\.title)
        // Larger + a touch heavier than the 21/1.5 first pass: at 21 the glyphs read small and
        // hairline in the glass pill next to the 34pt Mac toolbar weight, so lift the drawn box to
        // 24 and the stroke to 1.7 for a firmer, more legible tab icon (same in every state).
        icons = items.map { $0.icon.strokeImage(boxSize: 24, strokeWeight: 1.7) }
        super.init(frame: .zero)
        let glass = GlassChrome.makeView(interactive: true)
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.layer.cornerRadius = 32
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        addSubview(glass)

        glassContentView = glass.contentView
        glass.contentView.addSubview(selection)

        buttons = items.enumerated().map { index, item in
            var config = UIButton.Configuration.plain()
            config.image = icons[index]
            config.imagePlacement = .top
            config.imagePadding = 3
            config.attributedTitle = AttributedString(
                item.title,
                attributes: AttributeContainer([
                    .font: UIFont.systemFont(ofSize: 10, weight: .medium),
                ])
            )
            config.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12)
            let button = UIButton(configuration: config)
            button.accessibilityLabel = item.title
            button.accessibilityIdentifier = "home.tab.\(item.title.lowercased())"
            button.addAction(UIAction { [weak self] _ in
                self?.selectionFeedback.prepare()
            }, for: .touchDown)
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

        let selectionPan = UIPanGestureRecognizer(target: self, action: #selector(handleSelectionPan(_:)))
        selectionPan.delegate = self
        selectionPan.cancelsTouchesInView = true
        addGestureRecognizer(selectionPan)

        select(0, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        glassContentView?.layoutIfNeeded()
        if !isDraggingSelection {
            selection.frame = selectionFrame()
        }
    }

    private func selectionFrame() -> CGRect {
        guard buttons.indices.contains(selectedIndex) else { return .zero }
        return buttons[selectedIndex].convert(buttons[selectedIndex].bounds, to: selection.superview)
            .insetBy(dx: 0, dy: 4)
    }

    func select(_ index: Int, animated: Bool) {
        guard buttons.indices.contains(index) else { return }
        let changed = selectedIndex != index
        selectedIndex = index
        updateButtonStates(animated: animated && changed)
        if animated, changed { selectionFeedback.selectionChanged() }
        settleSelection(at: index, velocityX: 0, animated: animated)
    }

    private func updateButtonStates(animated: Bool) {
        for (i, button) in buttons.enumerated() {
            let selected = i == selectedIndex
            let update = {
                var config = button.configuration
                config?.image = self.icons[i]
                config?.baseForegroundColor = selected ? .label : .secondaryLabel
                config?.attributedTitle = AttributedString(
                    self.titles[i],
                    attributes: AttributeContainer([
                        .font: UIFont.systemFont(
                            ofSize: 10,
                            weight: selected ? .semibold : .medium
                        ),
                    ])
                )
                button.configuration = config
                if selected {
                    button.accessibilityTraits.insert(.selected)
                } else {
                    button.accessibilityTraits.remove(.selected)
                }
            }
            if animated {
                UIView.transition(
                    with: button,
                    duration: 0.18,
                    options: [
                        .transitionCrossDissolve,
                        .allowUserInteraction,
                        .beginFromCurrentState,
                    ],
                    animations: update
                )
            } else {
                update()
            }
        }
    }

    private func settleSelection(at index: Int, velocityX: CGFloat, animated: Bool) {
        glassContentView?.layoutIfNeeded()
        let targetFrame = selectionFrame(for: index)
        let distance = targetFrame.midX - selection.frame.midX
        let relativeVelocity = abs(distance) > 1
            ? max(-8, min(8, velocityX / distance))
            : 0
        let carriedMomentum = abs(velocityX) > 180

        let settle = { self.selection.frame = targetFrame }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(
                withDuration: carriedMomentum ? 0.38 : 0.32,
                delay: 0,
                usingSpringWithDamping: carriedMomentum ? 0.86 : 1,
                initialSpringVelocity: relativeVelocity,
                options: [.allowUserInteraction, .beginFromCurrentState],
                animations: settle
            )
        } else {
            settle()
        }
    }

    private func selectionFrame(for index: Int) -> CGRect {
        guard buttons.indices.contains(index) else { return .zero }
        return buttons[index].convert(buttons[index].bounds, to: selection.superview)
            .insetBy(dx: 0, dy: 4)
    }

    private func nearestIndex(to centerX: CGFloat) -> Int {
        buttons.indices.min {
            abs(selectionFrame(for: $0).midX - centerX)
                < abs(selectionFrame(for: $1).midX - centerX)
        } ?? selectedIndex
    }

    private func rubberBandedCenter(_ proposedCenter: CGFloat) -> CGFloat {
        guard let first = buttons.indices.first, let last = buttons.indices.last else {
            return proposedCenter
        }
        let lowerBound = selectionFrame(for: first).midX
        let upperBound = selectionFrame(for: last).midX
        let dimension = max(selection.bounds.width, 1)

        if proposedCenter < lowerBound {
            return lowerBound - rubberBandDistance(lowerBound - proposedCenter, dimension: dimension)
        }
        if proposedCenter > upperBound {
            return upperBound + rubberBandDistance(proposedCenter - upperBound, dimension: dimension)
        }
        return proposedCenter
    }

    private func rubberBandDistance(_ offset: CGFloat, dimension: CGFloat) -> CGFloat {
        let constant: CGFloat = 0.55
        return (offset * dimension * constant) / (dimension + constant * offset)
    }

    private func projectedCenter(from centerX: CGFloat, velocityX: CGFloat) -> CGFloat {
        // UIScrollView.DecelerationRate.fast (0.99) keeps a flick useful within
        // this short four-stop control without letting it fly across the bar.
        let decelerationRate = UIScrollView.DecelerationRate.fast.rawValue
        return centerX + (velocityX / 1000) * decelerationRate / (1 - decelerationRate)
    }

    @objc
    private func handleSelectionPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            glassContentView?.layoutIfNeeded()
            if let liveFrame = selection.layer.presentation()?.frame {
                selection.frame = liveFrame
            }
            selection.layer.removeAllAnimations()
            isDraggingSelection = true
            dragOriginIndex = selectedIndex
            dragStartCenterX = selection.center.x
            selectionFeedback.prepare()

        case .changed:
            let translationX = gesture.translation(in: self).x
            selection.center.x = rubberBandedCenter(dragStartCenterX + translationX)

            let previewIndex = nearestIndex(to: selection.center.x)
            if previewIndex != selectedIndex {
                selectedIndex = previewIndex
                updateButtonStates(animated: true)
                selectionFeedback.selectionChanged()
                selectionFeedback.prepare()
            }

        case .ended:
            let velocityX = gesture.velocity(in: self).x
            let targetIndex = nearestIndex(
                to: projectedCenter(from: selection.center.x, velocityX: velocityX)
            )
            finishSelectionPan(at: targetIndex, velocityX: velocityX, commit: true)

        case .cancelled, .failed:
            finishSelectionPan(at: dragOriginIndex, velocityX: 0, commit: false)

        default:
            break
        }
    }

    private func finishSelectionPan(at index: Int, velocityX: CGFloat, commit: Bool) {
        let changedFromPreview = selectedIndex != index
        selectedIndex = index
        updateButtonStates(animated: changedFromPreview)
        if changedFromPreview {
            selectionFeedback.selectionChanged()
        }

        isDraggingSelection = false
        settleSelection(at: index, velocityX: velocityX, animated: true)

        if commit, index != dragOriginIndex {
            onSelect?(index)
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, buttons.count > 1 else {
            return true
        }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }
}

extension HugeIcon {
    /// The glyph as a tintable template `UIImage` — a bitmap for UIKit chrome
    /// like the tab pill, where SwiftUI's `HugeIconView` can't be used
    /// directly. Same stroke recipe (1.5px-on-24 with the hairline floor,
    /// round caps); the path is inset by the stroke's half-width so round
    /// caps at the glyph's edge don't clip against the bitmap bounds.
    func strokeImage(boxSize: CGFloat, strokeWeight: CGFloat = 1.5) -> UIImage {
        let lineWidth = max(1.1, boxSize * strokeWeight / viewBox)
        let bounds = CGRect(x: 0, y: 0, width: boxSize, height: boxSize)
        let path = HugeIconShape(icon: self)
            .path(in: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
            .cgPath
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { context in
            let cg = context.cgContext
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(lineWidth)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.addPath(path)
            cg.strokePath()
        }.withRenderingMode(.alwaysTemplate)
    }
}
