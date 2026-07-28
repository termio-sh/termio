import UIKit

/// Makes the iOS on-screen keyboard auto-repeat its delete key over the
/// terminal, and accelerates a sustained hold.
///
/// Why it's needed: the software keyboard only keeps calling `deleteBackward`
/// on hold while it believes the `UITextInput` document still has text to the
/// left of the caret. A terminal has no such document — the wrapper presents an
/// empty one at rest — so holding delete fires exactly once and stops (a
/// hardware keyboard doesn't care: its repeat is an OS-level key-event stream,
/// no document required). We therefore hand the keyboard a large, static
/// *phantom* document with the caret parked far from the start: there is always
/// "more to delete", so iOS keeps firing on hold.
///
/// Second problem: iOS drops its own repeat cadence to ~3/s after ~20 reps (its
/// word-delete phase), which feels sluggish when we only delete one character
/// per call. We can't raise that rate, so we ACCELERATE instead — the longer
/// the key is held, the more backspaces each call emits — matching the "faster
/// the longer you hold" feel of a native text field without abandoning
/// character-delete semantics.
///
/// This type owns only the policy and state; the `UITextInput` overrides that
/// feed it live on the view (UIKit calls them there). `now` is injected so the
/// acceleration is deterministic and unit-testable.
struct SoftwareKeyboardDeleteRepeat {
    /// The phantom document's fixed length. Large enough that the caret can
    /// walk left for a very long hold without ever reaching the start.
    static let documentLength = 1 << 20

    /// The caret position shown to the keyboard, parked at the end so there is
    /// always content to its left.
    private(set) var caret = documentLength

    /// Reps in the current hold and when the last arrived; a gap resets the
    /// streak so a fresh hold starts gentle.
    private var streak = 0
    private var lastDeleteTime: CFTimeInterval = 0

    /// A gap (in seconds) longer than this ends the current hold.
    private static let holdGap: CFTimeInterval = 0.5
    /// Follow iOS 1:1 for this many reps before ramping.
    private static let rampAfter = 12
    /// Add one backspace per this many reps past `rampAfter`.
    private static let rampEvery = 4
    /// Never emit more than this many backspaces for a single call.
    private static let burstCap = 6

    /// iOS moved the caret during deletion — clamp it into the phantom document.
    mutating func moveCaret(to index: Int) {
        caret = min(max(index, 0), Self.documentLength)
    }

    /// Real text was typed (or an IME took over) — the next hold starts gentle.
    mutating func reset() {
        streak = 0
    }

    /// One `deleteBackward` arrived at `now`; returns how many backspaces to
    /// send for it.
    mutating func backspaceCount(now: CFTimeInterval) -> Int {
        if now - lastDeleteTime > Self.holdGap { streak = 0 }
        lastDeleteTime = now
        streak += 1
        guard streak > Self.rampAfter else { return 1 }
        return min((streak - Self.rampAfter) / Self.rampEvery + 1, Self.burstCap)
    }
}

/// Positions in the phantom document above. Kept distinct from the wrapper's
/// own position type so the view's overrides can tell "our" geometry from the
/// real (IME) one with a simple cast.
final class PhantomTextPosition: UITextPosition {
    let index: Int
    init(_ index: Int) {
        self.index = index
        super.init()
    }
}

final class PhantomTextRange: UITextRange {
    private let from: PhantomTextPosition
    private let to: PhantomTextPosition

    init(start: PhantomTextPosition, end: PhantomTextPosition) {
        self.from = start
        self.to = end
        super.init()
    }

    override var start: UITextPosition { from }
    override var end: UITextPosition { to }
    override var isEmpty: Bool { from.index == to.index }
    var length: Int { to.index - from.index }
}
