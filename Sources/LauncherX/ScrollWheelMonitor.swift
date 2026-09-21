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
        private var didPageDuringGesture = false
        private var gestureAxis: ScrollAxis?
        private var rearmAt = Date.distantPast

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

            if now.timeIntervalSince(lastEvent) > 0.5 {
                accumulated = 0
                didPageDuringGesture = false
                gestureAxis = nil
            }

            if event.phase == .began {
                accumulated = 0
                didPageDuringGesture = false
                gestureAxis = nil
            }

            let gestureFinished = event.phase == .ended
                || event.phase == .cancelled
                || event.momentumPhase == .ended
                || event.momentumPhase == .cancelled
            if gestureFinished {
                accumulated = 0
                if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                    rearmAt = now.addingTimeInterval(0.25)
                    didPageDuringGesture = false
                    gestureAxis = nil
                }
                return
            }
            if now < rearmAt { return }

            let isTraditionalWheel = event.phase.isEmpty && event.momentumPhase.isEmpty
            if didPageDuringGesture && !isTraditionalWheel { return }

            let movement = dominantMovement(from: event)
            guard abs(movement) > 0.1 else { return }
            accumulated += movement
            guard abs(accumulated) >= (isTraditionalWheel ? 34 : 42) else { return }
            guard isTraditionalWheel ? now.timeIntervalSince(lastChange) > 0.3 : true else { return }

            onPage(accumulated > 0 ? 1 : -1)
            accumulated = 0
            lastChange = now
            didPageDuringGesture = !isTraditionalWheel
        }

        private func dominantMovement(from event: NSEvent) -> CGFloat {
            let axis: ScrollAxis
            if let lockedAxis = gestureAxis {
                axis = lockedAxis
            } else {
                axis = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? .horizontal : .vertical
                gestureAxis = axis
            }
            return axis == .horizontal ? -event.scrollingDeltaX : -event.scrollingDeltaY
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

private enum ScrollAxis {
    case horizontal
    case vertical
}

private final class MousePassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
