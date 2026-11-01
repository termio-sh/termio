import UIKit

/// The one spring the app moves with. Critically damped — stiffness 800,
/// damping 2·√800 ≈ 56.57, unit mass — so it settles in about 0.45 s with no
/// overshoot, from whatever velocity a gesture hands it. Every slide, drawer
/// and sheet shares it, so nothing on screen moves on a timing of its own.
///
/// Under Reduce Motion there is no movement at all: the end state is applied
/// at once and the completion runs. Callers that want a cross-fade there
/// instead keep their own branch for it.
enum Motion {
    private static let stiffness: CGFloat = 800
    private static let damping: CGFloat = 2 * stiffness.squareRoot()

    /// `velocity` is in fractions of the remaining travel per second, the unit
    /// `UISpringTimingParameters` takes: a flick keeps its speed, a release at
    /// rest starts from zero.
    @discardableResult
    static func animate(
        velocity: CGFloat = 0,
        _ animations: @escaping () -> Void,
        completion: (() -> Void)? = nil
    ) -> UIViewPropertyAnimator? {
        guard !UIAccessibility.isReduceMotionEnabled else {
            animations()
            completion?()
            return nil
        }
        let timing = UISpringTimingParameters(
            mass: 1, stiffness: stiffness, damping: damping,
            initialVelocity: CGVector(dx: velocity, dy: velocity))
        // The spring's own settle time governs; the duration is ignored.
        let animator = UIViewPropertyAnimator(duration: 0, timingParameters: timing)
        animator.isInterruptible = true
        animator.isUserInteractionEnabled = true
        animator.addAnimations(animations)
        if let completion {
            animator.addCompletion { position in
                if position == .end { completion() }
            }
        }
        animator.startAnimation()
        return animator
    }
}
