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
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard LauncherKeyboardCommand.isQuit(
                characters: event.charactersIgnoringModifiers,
                modifierFlags: event.modifierFlags
            ) else { return event }
            Task { @MainActor in NSApp.terminate(nil) }
            return nil
        }
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
            NSApp.unhide(nil)
            LauncherWindowPresentation.configureChrome(of: launcherWindow)
            launcherWindow.contentView?.layoutSubtreeIfNeeded()
            launcherWindow.displayIfNeeded()
            model.maximizeLauncherWindow()
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
