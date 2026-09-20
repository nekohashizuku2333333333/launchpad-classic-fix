import SwiftUI
import AppKit

struct ScrollWheelMonitor: NSViewRepresentable {
    let onPage: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPage: onPage) }
    func makeNSView(context: Context) -> NSView {
        let view = MousePassthroughView(frame: .zero)
        context.coordinator.install(for: view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.onPage = onPage }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.uninstall() }

    @MainActor final class Coordinator {
        var onPage: (Int) -> Void
        private weak var view: NSView?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var lastChange = Date.distantPast
        private var lastEvent = Date.distantPast
        private var suppressUntilGestureEnd = false

        init(onPage: @escaping (Int) -> Void) { self.onPage = onPage }
        func install(for view: NSView) {
            self.view = view
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let windowNumber = view?.window?.windowNumber else { return }
                self.installMonitor(windowNumber: windowNumber)
            }
        }

        private func installMonitor(windowNumber: Int) {
            uninstall()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard event.windowNumber == windowNumber else { return event }
                Task { @MainActor [weak self] in self?.handle(event) }
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            let now = Date()
            defer { lastEvent = now }
            if now.timeIntervalSince(lastEvent) > 0.6 {
                accumulated = 0
                suppressUntilGestureEnd = false
            }

            if event.phase == .began {
                accumulated = 0
                suppressUntilGestureEnd = false
            }

            let gestureFinished = event.phase == .ended
                || event.phase == .cancelled
                || event.momentumPhase == .ended
                || event.momentumPhase == .cancelled
            if gestureFinished {
                suppressUntilGestureEnd = false
                accumulated = 0
                return
            }
            if suppressUntilGestureEnd { return }

            let movement = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                ? -event.scrollingDeltaX : -event.scrollingDeltaY
            accumulated += movement

            let isTraditionalWheel = event.phase.isEmpty && event.momentumPhase.isEmpty
            guard abs(accumulated) >= 28 else { return }
            guard isTraditionalWheel ? now.timeIntervalSince(lastChange) > 0.3 : true else { return }

            onPage(accumulated > 0 ? 1 : -1)
            accumulated = 0
            lastChange = now
            if !isTraditionalWheel { suppressUntilGestureEnd = true }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

private final class MousePassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
