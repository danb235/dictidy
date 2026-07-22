import AppKit
import Carbon.HIToolbox

/// Watches Escape both while Dictidy owns the active window and while the user is typing in
/// another app. The monitors are installed only during recording/processing, so Dictidy does not
/// observe keyboard events while it is idle.
@MainActor
final class EscapeKeyMonitor {
    var onEscape: (() -> Void)?

    private var localMonitor: Any?
    private var globalMonitor: Any?

    func start() {
        guard localMonitor == nil, globalMonitor == nil else { return }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == CGKeyCode(kVK_Escape) else { return event }
            self?.onEscape?()
            return nil
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == CGKeyCode(kVK_Escape) else { return }
            self?.onEscape?()
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }
}
