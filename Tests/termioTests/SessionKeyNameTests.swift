import XCTest
@testable import termio

/// `termio sessions send --key <name>` exists because a key's bytes are not a
/// property of the key: Up is `ESC [ A` in normal cursor mode and `ESC O A` in
/// application mode, and ctrl-c is `0x03` or `CSI 99;5u` depending on whether the
/// program turned on the kitty keyboard protocol. Naming the key hands that choice
/// to Ghostty's encoder. These tests pin the two halves that would quietly rot:
/// the vocabulary a caller may type, and the refusal to guess when they typo it.
final class SessionKeyNameTests: XCTestCase {
    // MARK: - The vocabulary

    func testNamesTheSpecialKeysCallersActuallyPress() {
        // kVK_Escape, kVK_ANSI_Tab, kVK_UpArrow, kVK_ForwardDelete, kVK_F2.
        XCTAssertEqual(SessionKeyPress.parse("escape")?.keycode, 0x35)
        XCTAssertEqual(SessionKeyPress.parse("tab")?.keycode, 0x30)
        XCTAssertEqual(SessionKeyPress.parse("up")?.keycode, 0x7E)
        XCTAssertEqual(SessionKeyPress.parse("delete")?.keycode, 0x75)
        XCTAssertEqual(SessionKeyPress.parse("f2")?.keycode, 0x78)
    }

    func testEnterIsTheSameKeypressSendAppendsItself() {
        // `--key enter` and the implicit submit must be one mechanism, or the two
        // drift and only one of them survives a mode change.
        XCTAssertEqual(SessionKeyPress.parse("enter"), .return)
        XCTAssertEqual(SessionKeyPress.parse("return"), .return)
    }

    func testBackspaceAndDeleteAreDifferentKeys() {
        // kVK_Delete (backspace) vs kVK_ForwardDelete. macOS names them the other
        // way round from every terminal, which is exactly how they get swapped.
        XCTAssertEqual(SessionKeyPress.parse("backspace")?.keycode, 0x33)
        XCTAssertEqual(SessionKeyPress.parse("delete")?.keycode, 0x75)
    }

    func testNamesAreCaseInsensitiveAndTrimmed() {
        XCTAssertEqual(SessionKeyPress.parse("ESCAPE"), SessionKeyPress.parse("escape"))
        XCTAssertEqual(SessionKeyPress.parse("  Escape "), SessionKeyPress.parse("escape"))
    }

    func testSpaceIsPrintableNotSpecial() {
        // The only printable key with a spelled-out name: `--key space` types a
        // space, `--key ctrl-space` is the NUL chord.
        let space = SessionKeyPress.parse("space")
        XCTAssertEqual(space?.keycode, 0x31)
        XCTAssertEqual(space?.text, " ")
        XCTAssertEqual(SessionKeyPress.parse("ctrl-space")?.text, nil)
    }

    // MARK: - Both dialects

    func testTmuxAndKittyModifierSpellingsAgree() {
        // A caller must never have to guess which dialect this CLI speaks.
        XCTAssertEqual(SessionKeyPress.parse("c-c"), SessionKeyPress.parse("ctrl-c"))
        XCTAssertEqual(SessionKeyPress.parse("s-tab"), SessionKeyPress.parse("shift-tab"))
        XCTAssertEqual(SessionKeyPress.parse("m-b"), SessionKeyPress.parse("alt-b"))
        XCTAssertEqual(SessionKeyPress.parse("ctrl+c"), SessionKeyPress.parse("ctrl-c"))
        XCTAssertEqual(SessionKeyPress.parse("cmd-c"), SessionKeyPress.parse("super-c"))
    }

    func testChordsCarryModifiersAndNoText() {
        // A chord's bytes come from the encoder, so the event carries the physical
        // key and the modifier — never pre-typed text that would be inserted as-is.
        let interrupt = SessionKeyPress.parse("ctrl-c")
        XCTAssertEqual(interrupt?.keycode, 0x08)
        XCTAssertEqual(interrupt?.modifiers, .control)
        XCTAssertEqual(interrupt?.unshiftedCodepoint, UInt32(UnicodeScalar("c").value))
        XCTAssertNil(interrupt?.text)
    }

    func testStackedModifiers() {
        XCTAssertEqual(SessionKeyPress.parse("ctrl-shift-t")?.modifiers, [.control, .shift])
        XCTAssertEqual(SessionKeyPress.parse("c-m-x")?.modifiers, [.control, .option])
    }

    func testOptionAndCommandChordsAreRefusedRatherThanPressedIntoTheVoid() {
        // Verified against a live `cat -v`: `--key alt-b` puts nothing on the wire,
        // because macOS spends Option composing text and Ghostty adds a real Alt's
        // ESC prefix only under macos-option-as-alt. Command never reaches the
        // program at all. Both parse — so the caller is told which modifier is the
        // problem — and both are then refused, because a key that reports success
        // and delivers nothing is exactly what --key exists to prevent.
        XCTAssertNotNil(SessionKeyPress.parse("alt-b")?.undeliverableReason)
        XCTAssertNotNil(SessionKeyPress.parse("m-b")?.undeliverableReason)
        XCTAssertNotNil(SessionKeyPress.parse("cmd-c")?.undeliverableReason)
        // …and the refusal names the substitute that does work.
        XCTAssertEqual(SessionKeyPress.parse("alt-b")?.undeliverableReason?
            .contains("--key escape --key b"), true)
        // The modifiers that do reach the program stay pressable.
        for name in ["ctrl-c", "shift-tab", "escape", "up", "t"] {
            XCTAssertNil(SessionKeyPress.parse(name)?.undeliverableReason,
                         "'\(name)' must stay pressable")
        }
    }

    func testUnmodifiedPrintableKeyCarriesTheTextItWouldType() {
        XCTAssertEqual(SessionKeyPress.parse("t")?.text, "t")
        XCTAssertEqual(SessionKeyPress.parse("shift-t")?.text, "T")
    }

    func testSeparatorItselfIsAKeyNotAModifierSyntax() {
        // `--key -` is the minus key and `--key ctrl--` is ctrl-minus: the peel
        // must stop rather than eat the key it was meant to leave behind.
        XCTAssertEqual(SessionKeyPress.parse("-")?.keycode, 0x1B)
        XCTAssertEqual(SessionKeyPress.parse("ctrl--")?.keycode, 0x1B)
        XCTAssertEqual(SessionKeyPress.parse("ctrl--")?.modifiers, .control)
    }

    // MARK: - Failing loudly

    func testUnknownNamesResolveToNothing() {
        // The whole point. A name this parser cannot place must reach the caller as
        // an error — never fall through to being typed as literal text, which is
        // how "escpae" ends up in an agent's prompt and nobody finds out.
        for name in ["escpae", "", "   ", "ctrl-", "meta", "f13", "ctrl", "arrow-up", "ctrl-nope"] {
            XCTAssertNil(SessionKeyPress.parse(name), "'\(name)' must not resolve")
        }
    }

    func testMultiCharacterUnknownNamesAreNotTakenApart() {
        // "yes" is text a caller might mean to send; it must not become the y key.
        XCTAssertNil(SessionKeyPress.parse("yes"))
    }

    func testVocabularyErrorNamesTheKeysItRejects() {
        // The error a bad name earns has to be actionable, so the listing must stay
        // in step with what actually parses.
        for name in ["enter", "escape", "tab", "space", "backspace", "delete", "up",
                     "down", "left", "right", "home", "end", "pageup", "pagedown"]
        {
            XCTAssertTrue(SessionKeyPress.vocabulary.contains(name),
                          "'\(name)' parses but is not offered in the error")
            XCTAssertNotNil(SessionKeyPress.parse(name))
        }
        for index in 1 ... 12 {
            XCTAssertNotNil(SessionKeyPress.parse("f\(index)"))
        }
    }

    // MARK: - The wire

    func testAnyNamedKeySuppressesTheImplicitReturn() throws {
        // Naming a key is being explicit about keys; adding one the caller did not
        // ask for would submit the menu they meant to escape.
        XCTAssertTrue(try decode(#"{"op":"send"}"#).wantsEnter)
        XCTAssertFalse(try decode(#"{"op":"send","enter":false}"#).wantsEnter)
        XCTAssertFalse(try decode(#"{"op":"send","keys":["escape"]}"#).wantsEnter)
        // An empty array is not a named key — it must not change the default.
        XCTAssertTrue(try decode(#"{"op":"send","keys":[]}"#).wantsEnter)
    }

    func testKeysDecodeInTheOrderNamed() throws {
        XCTAssertEqual(try decode(#"{"op":"send","keys":["up","enter"]}"#).namedKeys,
                       ["up", "enter"])
        XCTAssertEqual(try decode(#"{"op":"send"}"#).namedKeys, [])
    }

    private func decode(_ json: String) throws -> ControlRequest {
        try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
    }
}
