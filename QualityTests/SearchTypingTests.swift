import AppKit

private struct SearchTypingTestFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
enum SearchTypingTests {
    static func run() throws -> Int {
        try printableKeysCanBeginNativeSearchInput()
        try onlyTheStandardPasteShortcutCanBeginSearch()
        try navigationAndControlKeysDoNotStealFocus()
        try missingCharactersDoNotCreateAnEmptySearchSession()
        try nativeCommandASelectsAndReplacesTheEntireText()
        try unrelatedShortcutsRetainNativeWindowBehavior()
        return 6
    }

    private static func printableKeysCanBeginNativeSearchInput() throws {
        let cases: [(String, UInt16, NSEvent.ModifierFlags)] = [
            ("a", 0, []),
            ("中", 0, []),
            ("輸入", 0, []),
            (" ", 49, []),
            ("A", 0, [.shift]),
            ("é", 14, [.option]),
            ("Å", 0, [.shift, .option])
        ]
        for (characters, keyCode, modifiers) in cases {
            try require(
                intent(characters, keyCode, modifiers),
                "A printable key could not hand its first event to native search/IME input: \(characters.debugDescription)"
            )
        }
    }

    private static func onlyTheStandardPasteShortcutCanBeginSearch() throws {
        try require(intent("v", 9, [.command]), "Command-V could not focus search for native paste")
        // Intent follows the active keyboard layout's character. A V key can
        // occupy a different physical position on a remapped/Dvorak keyboard.
        try require(intent("v", 0, [.command]), "Native paste incorrectly depended on the physical QWERTY V key")
        let shortcuts: [(String, UInt16, NSEvent.ModifierFlags)] = [
            ("a", 0, [.command]),
            ("f", 3, [.command]),
            ("q", 12, [.command]),
            ("x", 7, [.command]),
            ("c", 8, [.command]),
            ("a", 0, [.control]),
            ("v", 9, [.control]),
            ("v", 9, [.command, .control]),
            ("v", 9, [.command, .option]),
            ("V", 9, [.command, .shift])
        ]
        for (characters, keyCode, modifiers) in shortcuts {
            try require(
                !intent(characters, keyCode, modifiers),
                "An unrelated shortcut stole focus for search: \(characters.debugDescription), modifiers \(modifiers.rawValue)"
            )
        }
    }

    private static func navigationAndControlKeysDoNotStealFocus() throws {
        let keys: [(String, UInt16)] = [
            ("\t", 48), ("\u{7F}", 51), ("\r", 36), ("\u{03}", 76), ("\u{1B}", 53),
            ("\u{F700}", 126), ("\u{F701}", 125), ("\u{F702}", 123), ("\u{F703}", 124),
            ("\u{F704}", 122), ("\u{F728}", 117), ("\u{F729}", 115), ("\u{F72B}", 119),
            ("\u{F72C}", 116), ("\u{F72D}", 121), ("\u{F739}", 71)
        ]
        for (characters, keyCode) in keys {
            try require(!intent(characters, keyCode, []), "Navigation/control key \(keyCode) focused the search field")
            try require(!intent(characters, keyCode, [.shift]), "Shift-navigation focused search instead of preserving keyboard navigation")
        }
        for scalar in [UInt32(0), 1, 8, 10, 13, 27, 31, 127] {
            guard let value = UnicodeScalar(scalar) else { continue }
            try require(!intent(String(value), 0, []), "An ASCII control character was classified as text input")
        }
    }

    private static func missingCharactersDoNotCreateAnEmptySearchSession() throws {
        let missingCharacters: [String?] = [nil, ""]
        let modifierCases: [NSEvent.ModifierFlags] = [[], [.shift], [.option], [.command]]
        for characters in missingCharacters {
            for modifiers in modifierCases {
                try require(!intent(characters, 0, modifiers), "A key without text stole focus for an empty search")
            }
        }
        try require(!intent(nil, 9, [.command]), "A physical V key without a V character was mistaken for native paste")
    }

    private static func nativeCommandASelectsAndReplacesTheEntireText() throws {
        let fixture = try makeEditorFixture(usesLauncherWindow: true)
        defer { close(fixture) }
        let original = "Terminal 測試"
        fixture.editor.string = original
        fixture.editor.setSelectedRange(NSRange(location: original.utf16.count, length: 0))
        let event = try keyEvent(characters: "a", keyCode: 0, modifiers: [.command], window: fixture.window)
        try require(fixture.window.performKeyEquivalent(with: event), "The launcher window did not handle Command-A in its active native editor")
        try require(
            fixture.editor.selectedRange() == NSRange(location: 0, length: original.utf16.count),
            "Command-A did not select the whole search text, including its non-ASCII suffix"
        )
        fixture.editor.insertText("中文搜尋", replacementRange: NSRange(location: NSNotFound, length: 0))
        try require(fixture.editor.string == "中文搜尋", "Typing after Command-A appended to the old query instead of replacing the selected text")
    }

    private static func unrelatedShortcutsRetainNativeWindowBehavior() throws {
        let launcher = try makeEditorFixture(usesLauncherWindow: true)
        defer { close(launcher) }
        let native = try makeEditorFixture(usesLauncherWindow: false)
        defer { close(native) }
        let cases: [(String, UInt16, NSEvent.ModifierFlags)] = [
            ("\u{F702}", 123, [.command]),
            ("\u{F703}", 124, [.command]),
            ("a", 0, [.command, .option]),
            ("A", 0, [.command, .shift]),
            ("a", 0, [.command, .control]),
            ("a", 0, [.control])
        ]
        for (characters, keyCode, modifiers) in cases {
            for editor in [launcher.editor, native.editor] {
                editor.string = "Terminal"
                editor.setSelectedRange(NSRange(location: 3, length: 0))
            }
            let launcherEvent = try keyEvent(characters: characters, keyCode: keyCode, modifiers: modifiers, window: launcher.window)
            let nativeEvent = try keyEvent(characters: characters, keyCode: keyCode, modifiers: modifiers, window: native.window)
            let launcherHandled = launcher.window.performKeyEquivalent(with: launcherEvent)
            let nativeHandled = native.window.performKeyEquivalent(with: nativeEvent)
            // AppKit may legitimately handle some modified navigation keys.
            // Compare its actual response instead of requiring an arbitrary false.
            try require(
                launcherHandled == nativeHandled
                    && launcher.editor.selectedRange() == native.editor.selectedRange()
                    && launcher.editor.string == native.editor.string,
                "The text shortcut fallback intercepted native navigation or an extra-modifier shortcut"
            )
        }
    }

    private typealias EditorFixture = (window: NSWindow, editor: NSTextView)

    private static func makeEditorFixture(usesLauncherWindow: Bool) throws -> EditorFixture {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 320, height: 80)
        let window: NSWindow
        if usesLauncherWindow {
            window = LauncherWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        } else {
            window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        }
        window.isReleasedWhenClosed = false
        let editor = NSTextView(frame: frame)
        editor.isEditable = true
        editor.isSelectable = true
        editor.isRichText = false
        window.contentView = editor
        guard window.makeFirstResponder(editor), window.firstResponder === editor else {
            window.close()
            throw SearchTypingTestFailure(description: "Could not attach a native text editor to the hidden test window")
        }
        // These fixtures never order a window onscreen, activate the test app,
        // or read/write the system clipboard.
        return (window, editor)
    }

    private static func close(_ fixture: EditorFixture) {
        fixture.window.makeFirstResponder(nil)
        fixture.window.close()
    }

    private static func keyEvent(
        characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, window: NSWindow
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ) else { throw SearchTypingTestFailure(description: "Could not create a native shortcut event") }
        return event
    }

    private static func intent(_ characters: String?, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        LauncherSearchTypingIntent.shouldBeginSearch(characters: characters, keyCode: keyCode, modifiers: modifiers)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SearchTypingTestFailure(description: message) }
    }
}
