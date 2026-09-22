import AppKit
import SwiftUI

@main
@MainActor
enum LauncherXApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = LauncherAppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    private let model = LauncherModel()
    private var launcherWindow: LauncherWindow?
    private var isWaitingForInitialContent = false
    private var initialRevealTask: Task<Void, Never>?
    private var keyDownMonitor: Any?
    private var automaticUpdateController: AutomaticUpdateController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.accessory)
        installKeyboardMonitor()
        requestLauncherPresentation()
        let updateController = AutomaticUpdateController()
        automaticUpdateController = updateController
        updateController.checkAtLaunch()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        requestLauncherPresentation()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        initialRevealTask?.cancel()
        initialRevealTask = nil
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        model.shutdown()
        automaticUpdateController = nil
    }

    private func installKeyboardMonitor() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            if event.type == .keyDown, LauncherKeyboardCommand.isQuit(
                characters: event.charactersIgnoringModifiers,
                modifierFlags: event.modifierFlags
            ) {
                Task { @MainActor in NSApp.terminate(nil) }
                return nil
            }
            guard let self, self.handleLauncherKeyboardEvent(event) else { return event }
            return nil
        }
    }

    private func handleLauncherKeyboardEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.type == .flagsChanged, !modifiers.contains(.option) {
            model.setOptionKeyPressed(false)
            return false
        }
        guard let window = launcherWindow, event.window === window,
              window.isKeyWindow, window.isVisible, window.attachedSheet == nil,
              NSApp.modalWindow == nil,
              !model.isDismissing, !model.showLauncherSettings,
              model.pendingDeleteApp == nil, model.errorMessage == nil else { return false }

        let editor = window.firstResponder as? NSTextView
        if let editor {
            // Folder titles and IME marked text retain their native editing,
            // confirmation, Escape and candidate-navigation behavior.
            guard model.openGroupID == nil, !editor.hasMarkedText() else { return false }
        }
        if event.type == .flagsChanged {
            model.setOptionKeyPressed(
                modifiers.contains(.option) && modifiers.intersection([.command, .control]).isEmpty
            )
            return false
        }
        if modifiers == .command, event.keyCode == 123 || event.keyCode == 124 {
            model.navigateVisiblePages(by: event.keyCode == 123 ? -1 : 1)
            return true
        }
        if editor == nil, model.openGroupID == nil,
           LauncherSearchTextField.beginTyping(in: window, with: event) {
            return true
        }
        guard modifiers.isEmpty else { return false }
        if let direction = LauncherKeyboardCommand.selectionDirection(keyCode: event.keyCode) {
            // With a search caret, Left/Right edit text until Up/Down selects
            // a result. Typing again resets selection and restores caret use.
            if editor != nil, model.selectedEntryID == nil,
               event.keyCode == 123 || event.keyCode == 124 { return false }
            return model.moveKeyboardSelection(direction)
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            return model.activateKeyboardSelection()
        }
        if event.keyCode == 53 { return model.handleEscape() }
        return false
    }

    private func requestLauncherPresentation() {
        guard !isWaitingForInitialContent else { return }
        isWaitingForInitialContent = true
        model.whenInitialContentIsReady { [weak self] in
            guard let self else { return }
            self.isWaitingForInitialContent = false
            self.presentLauncher()
        }
    }

    private func presentLauncher() {
        if let launcherWindow {
            guard initialRevealTask == nil else { return }
            initialRevealTask = Task { @MainActor [weak self, weak launcherWindow] in
                guard let self, let launcherWindow else { return }
                await self.model.prepareForPresentation()
                guard !Task.isCancelled else { return }
                self.initialRevealTask = nil
                NSApp.unhide(nil)
                LauncherWindowPresentation.configureChrome(of: launcherWindow)
                self.model.maximizeLauncherWindow()
                launcherWindow.contentView?.layoutSubtreeIfNeeded()
                launcherWindow.displayIfNeeded()
            }
            return
        }

        let initialFrame = NSScreen.main?.frame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let window = LauncherWindow(
            contentRect: initialFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        LauncherWindowPresentation.configureChrome(of: window)
        window.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(model)
                .environmentObject(model.folderPager)
                .frame(minWidth: 760, minHeight: 540)
        )
        LauncherWindowPresentation.configureChrome(of: window)
        launcherWindow = window
        model.registerLauncherWindow(window)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = .normal
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        initialRevealTask = Task { @MainActor [weak self, weak window] in
            await Task.yield()
            await Task.yield()
            do {
                try await Task.sleep(for: .milliseconds(34))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, let window else { return }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            window.ignoresMouseEvents = false
            self.initialRevealTask = nil
            self.model.markInitialWindowFrameReady()
            self.model.maximizeLauncherWindow()
        }
    }
}
