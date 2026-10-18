import AppKit

/// FOLIO_CLICKS="x,y;x,y;…" replays left clicks at window points (top-left origin), one every 2 s
/// starting 3 s after launch. Lets UI behaviour be checked from scripts without Accessibility access.
enum UITestHook {
    @MainActor static func start() {
        guard let spec = ProcessInfo.processInfo.environment["FOLIO_CLICKS"] else { return }
        let points = spec.split(separator: ";").compactMap { pair -> CGPoint? in
            let xy = pair.split(separator: ",").compactMap { Double($0) }
            return xy.count == 2 ? CGPoint(x: xy[0], y: xy[1]) : nil
        }
        for (i, p) in points.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(i) * 2) { click(p) }
        }
    }

    @MainActor private static func click(_ p: CGPoint) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        let loc = CGPoint(x: p.x, y: w.frame.height - p.y)
        // Queue the events like real input (press, short pause, release) so tracking loops see them.
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let down = event(.leftMouseDown) { NSApp.postEvent(down, atStart: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) } }
        print("clicked", p); fflush(stdout)
    }
}
