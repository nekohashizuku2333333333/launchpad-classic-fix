import AppKit
import SwiftUI

enum LauncherSearchTypingIntent {
    nonisolated static func shouldBeginSearch(
        characters: String?,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let relevant = modifiers.intersection([.command, .control, .option, .shift])
        if relevant == .command { return characters?.lowercased() == "v" }
        guard relevant.intersection([.command, .control]).isEmpty,
              ![36, 48, 51, 53, 76, 117].contains(keyCode),
              let characters, !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
                && !(0xF700...0xF8FF).contains($0.value)
        }
    }
}

/// AppKit owns the editor and input method. SwiftUI only draws the old
/// Launchpad shell, including its distinct idle and editing placeholders.
struct LaunchpadSearchField: View {
    @Binding var text: String
    let placeholder: String
    let clearButtonLabel: String
    let isAvailable: Bool
    let reducesTransparency: Bool
    var usesDarkText = false
    let onInteraction: @MainActor () -> Void
    let onSubmit: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    @State private var isTextEditing = false
    @StateObject private var controller = LauncherSearchFieldController()

    private var contentColor: Color { usesDarkText ? .black : .white }

    var body: some View {
        LauncherSearchEditor(
            text: $text, isTextEditing: $isTextEditing,
            placeholder: placeholder, isAvailable: isAvailable,
            textColor: usesDarkText ? .black : .white,
            controller: controller, onSubmit: onSubmit,
            onCancel: onCancel, onInteraction: onInteraction
        )
        .background(Color.white.opacity(reducesTransparency ? 0.18 : 0.09), in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.26), lineWidth: 0.75))
        .overlay {
            if text.isEmpty && !isTextEditing {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12))
                    Text(placeholder).font(.system(size: 15))
                }
                .foregroundStyle(contentColor.opacity(0.65))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .leading) {
            if isTextEditing || !text.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12)).padding(.leading, 8)
                    .foregroundStyle(contentColor.opacity(0.65))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .leading) {
            if text.isEmpty && isTextEditing {
                Text(placeholder)
                    .font(.system(size: 15))
                    .foregroundStyle(contentColor.opacity(0.65))
                    .lineLimit(1)
                    .padding(.leading, 27)
                    .padding(.trailing, 25)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .trailing) {
            if !text.isEmpty {
                Button {
                    text = ""
                    controller.clearAndContinueEditing()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain).padding(.trailing, 7)
                .foregroundStyle(contentColor.opacity(0.65))
                .accessibilityLabel(clearButtonLabel)
                .disabled(!isAvailable)
            }
        }
        .allowsHitTesting(isAvailable)
    }
}

@MainActor
private final class LauncherSearchFieldController: ObservableObject {
    weak var field: LauncherSearchTextField?

    func clearAndContinueEditing() {
        guard let field, field.isSearchAvailable else { return }
        field.noteInteraction()
        field.stringValue = ""
        if let editor = field.currentEditor() as? NSTextView {
            editor.unmarkText()
            editor.string = ""
            editor.setSelectedRange(NSRange(location: 0, length: 0))
        }
        _ = field.focusForEditing()
    }
}

@MainActor
final class LauncherSearchTextField: NSTextField {
    private final class WeakField {
        weak var value: LauncherSearchTextField?
        init(_ value: LauncherSearchTextField) { self.value = value }
    }

    private static var fieldsByWindow: [ObjectIdentifier: WeakField] = [:]
    private weak var registeredWindow: NSWindow?
    private var pointerMonitor: Any?
    private var allowsExplicitFocus = false

    var isSearchAvailable = true
    var searchTextColor: NSColor = .white
    var onEditingChanged: (@MainActor (Bool) -> Void)?
    var onInteraction: (@MainActor () -> Void)?

    override var acceptsFirstResponder: Bool {
        isSearchAvailable && allowsExplicitFocus && super.acceptsFirstResponder
    }

    override func becomeFirstResponder() -> Bool {
        guard isSearchAvailable, allowsExplicitFocus else { return false }
        let became = super.becomeFirstResponder()
        if became { onEditingChanged?(true) }
        return became
    }

    override func mouseDown(with event: NSEvent) {
        guard isSearchAvailable else { return }
        noteInteraction()
        allowsExplicitFocus = true
        super.mouseDown(with: event)
        if currentEditor() != nil { onEditingChanged?(true) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        unregister()
        guard let window else { return }
        registeredWindow = window
        Self.fieldsByWindow[ObjectIdentifier(window)] = WeakField(self)
        // Once the shared field editor owns the mouse event, NSTextField's
        // mouseDown is bypassed. Still report caret clicks to grid selection.
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.isSearchAvailable, event.window === self.window,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            self.noteInteraction()
            return event
        }
    }

    func unregister() {
        if let registeredWindow {
            let key = ObjectIdentifier(registeredWindow)
            if Self.fieldsByWindow[key]?.value === self { Self.fieldsByWindow.removeValue(forKey: key) }
        }
        registeredWindow = nil
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
    }

    func noteInteraction() { onInteraction?() }

    @discardableResult
    func focusForEditing() -> Bool {
        guard isSearchAvailable, let window else { return false }
        allowsExplicitFocus = true
        guard currentEditor() != nil || window.makeFirstResponder(self) else {
            allowsExplicitFocus = false
            return false
        }
        if let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = searchTextColor
        }
        onEditingChanged?(true)
        return true
    }

    func finishEditing() {
        if let window, let editor = currentEditor(), window.firstResponder === editor {
            window.makeFirstResponder(nil)
        }
        allowsExplicitFocus = false
        onEditingChanged?(false)
    }

    func didEndEditing() {
        allowsExplicitFocus = false
        onEditingChanged?(false)
    }

    static func beginTyping(in window: NSWindow, with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              LauncherSearchTypingIntent.shouldBeginSearch(
                characters: event.charactersIgnoringModifiers,
                keyCode: event.keyCode, modifiers: event.modifierFlags
              ),
              window.isKeyWindow, window.isVisible, window.attachedSheet == nil,
              NSApp.modalWindow == nil,
              let field = fieldsByWindow[ObjectIdentifier(window)]?.value,
              field.window === window, field.isSearchAvailable else { return false }
        if let editor = window.firstResponder as? NSTextView,
           field.currentEditor() !== editor { return false }
        field.noteInteraction()
        guard field.focusForEditing(), let editor = field.currentEditor() as? NSTextView else { return false }
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
            editor.paste(nil)
        } else {
            // Deliver the original key event to NSTextInputContext through
            // AppKit, preserving dead keys, composed characters and IME text.
            editor.keyDown(with: event)
        }
        return true
    }
}

@MainActor
private final class LauncherSearchContainer: NSView {
    let field = LauncherSearchTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.isSelectable = true
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.textColor = .white
        field.alignment = .left
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 25),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -25),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        field.noteInteraction()
        _ = field.focusForEditing()
    }
}

private struct LauncherSearchEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isTextEditing: Bool
    let placeholder: String
    let isAvailable: Bool
    let textColor: NSColor
    let controller: LauncherSearchFieldController
    let onSubmit: @MainActor () -> Void
    let onCancel: @MainActor () -> Void
    let onInteraction: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> LauncherSearchContainer {
        let container = LauncherSearchContainer()
        let field = container.field
        controller.field = field
        context.coordinator.field = field
        field.delegate = context.coordinator
        field.onInteraction = { [weak coordinator = context.coordinator] in coordinator?.parent.onInteraction() }
        field.onEditingChanged = { [weak coordinator = context.coordinator] editing in coordinator?.setEditing(editing) }
        return container
    }

    func updateNSView(_ container: LauncherSearchContainer, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.isUpdatingView = true
        defer { coordinator.isUpdatingView = false }
        let field = container.field
        field.isSearchAvailable = isAvailable
        field.searchTextColor = textColor
        field.textColor = textColor
        if let editor = field.currentEditor() as? NSTextView { editor.insertionPointColor = textColor }
        field.setAccessibilityLabel(placeholder)
        if !isAvailable { field.finishEditing() }
        // NSTextField hides its placeholder under the active field editor.
        // The shell draws both idle and editing placeholders without taking
        // text input or pointer events away from that native editor.
        field.placeholderAttributedString = nil
        let isExplicitExternalClear = text.isEmpty && !coordinator.lastModelText.isEmpty
        coordinator.lastModelText = text
        guard field.stringValue != text else { return }
        if let editor = field.currentEditor() as? NSTextView {
            // An unchanged empty binding can coexist with preedit text. Only
            // a real nonempty-to-empty model change is an external clear;
            // ordinary redraws must never discard an input method's text.
            if editor.hasMarkedText(), !isExplicitExternalClear { return }
            let selection = editor.selectedRange()
            if editor.hasMarkedText() { editor.unmarkText() }
            field.stringValue = text
            editor.string = text
            let count = (text as NSString).length
            let location = min(selection.location, count)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, count - location)))
        } else {
            field.stringValue = text
        }
    }

    static func dismantleNSView(_ container: LauncherSearchContainer, coordinator: Coordinator) {
        container.field.finishEditing()
        container.field.unregister()
        container.field.delegate = nil
        container.field.onEditingChanged = nil
        container.field.onInteraction = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LauncherSearchEditor
        weak var field: LauncherSearchTextField?
        var isUpdatingView = false
        var lastModelText = ""

        init(parent: LauncherSearchEditor) { self.parent = parent }

        func setEditing(_ editing: Bool) {
            guard parent.isTextEditing != editing else { return }
            if isUpdatingView {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let field = self.field,
                          (field.currentEditor() != nil) == editing else { return }
                    self.parent.isTextEditing = editing
                }
            } else {
                parent.isTextEditing = editing
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) { setEditing(true) }

        func controlTextDidEndEditing(_ notification: Notification) { field?.didEndEditing() }

        func controlTextDidChange(_ notification: Notification) {
            guard !isUpdatingView, let field else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
            lastModelText = parent.text
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}
