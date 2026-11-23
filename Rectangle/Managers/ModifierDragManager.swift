/// ModifierDragManager.swift

import Cocoa

/// Hyprland-style window manipulation: hold the configured modifier (cmd by default),
/// then left-drag anywhere in a window to move it, or right-drag to resize it from the
/// corner nearest the pointer. Adding shift to a right-drag resizes from the nearest edge
/// instead, changing only the width or only the height.
///
/// The event tap swallows the modified mouse-down so the app underneath never sees the
/// gesture. If the button is released without dragging, the click is replayed, so a plain
/// cmd-click (opening a link in a new tab, multi-selecting in Finder) still works.
final class ModifierDragManager {

    enum Mode { case move, resizeCorner, resizeEdge }

    /// The part of the frame being dragged. `left`/`top` say which side moves on each axis;
    /// nil leaves that axis's size alone, as when dragging a single edge.
    struct Handle: Equatable {
        let left: Bool?
        let top: Bool?
    }

    private struct Session {
        let window: AccessibilityElement
        let mode: Mode
        let startPoint: CGPoint
        let startFrame: CGRect
        let handle: Handle
        let minimumSize: CGSize
        var raised = false
    }

    /// Marks the clicks we replay so the tap lets them through.
    private static let replayMarker: Int64 = 0x5245_4354 // "RECT"
    /// How far the pointer travels before a press becomes a drag.
    private static let dragThreshold: CGFloat = 4

    // Gesture state, written from the tap thread.
    private let lock = NSLock()
    private var pressedButton: CGMouseButton?
    private var pressLocation: CGPoint = .zero
    private var pressEvent: CGEvent?
    private var dragging = false

    // Main-thread state.
    private var session: Session?
    private var latestPoint: CGPoint?
    private var applyScheduled = false

    private var eventMonitor: ActiveEventMonitor?

    init() {
        toggleListening()
        Notification.Name.modifierDragWindow.onPost { [weak self] _ in self?.toggleListening() }
        Notification.Name.configImported.onPost { [weak self] _ in self?.toggleListening() }
    }

    private func toggleListening() {
        if Defaults.modifierDragWindow.enabled {
            guard eventMonitor == nil else { return }
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                               .rightMouseDown, .rightMouseDragged, .rightMouseUp]
            eventMonitor = ActiveEventMonitor(mask: mask, filterer: { [weak self] in self?.filter($0) ?? false },
                                              handler: { _ in })
            eventMonitor?.start()
        } else {
            eventMonitor?.stop()
            eventMonitor = nil
            lock.lock()
            resetGesture()
            lock.unlock()
            DispatchQueue.main.async { self.session = nil }
        }
    }

    static var requiredModifiers: NSEvent.ModifierFlags {
        let raw = Defaults.modifierDragWindowModifiers.value
        return raw > 0 ? NSEvent.ModifierFlags(rawValue: UInt(raw)) : .command
    }

    static func modifiersMatch(_ flags: NSEvent.ModifierFlags, required: NSEvent.ModifierFlags) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
        return flags.intersection(relevant) == required.intersection(relevant)
    }

    /// Nearest corner of `frame` to `point`, in top-left-origin (AX) coordinates.
    static func nearestCorner(of frame: CGRect, to point: CGPoint) -> Handle {
        Handle(left: point.x < frame.midX, top: point.y < frame.midY)
    }

    /// Nearest edge of `frame` to `point`: a side edge resizes the width, top or bottom the height.
    static func nearestEdge(of frame: CGRect, to point: CGPoint) -> Handle {
        let distances: [(CGFloat, Handle)] = [
            (point.x - frame.minX, Handle(left: true, top: nil)),
            (frame.maxX - point.x, Handle(left: false, top: nil)),
            (point.y - frame.minY, Handle(left: nil, top: true)),
            (frame.maxY - point.y, Handle(left: nil, top: false)),
        ]
        return distances.min { $0.0 < $1.0 }!.1
    }

    /// The frame a corner resize asks for, before the window applies its own limits.
    static func resizedFrame(from start: CGRect, handle: Handle, delta: CGPoint,
                             minimumSize: CGSize) -> CGRect {
        let width = handle.left.map { max(start.width + ($0 ? -delta.x : delta.x), minimumSize.width) } ?? start.width
        let height = handle.top.map { max(start.height + ($0 ? -delta.y : delta.y), minimumSize.height) } ?? start.height
        return anchoredFrame(from: start, handle: handle, size: CGSize(width: width, height: height))
    }

    /// Places `size` so the sides opposite the handle stay where they were.
    static func anchoredFrame(from start: CGRect, handle: Handle, size: CGSize) -> CGRect {
        let x = handle.left == true ? start.maxX - size.width : start.minX
        let y = handle.top == true ? start.maxY - size.height : start.minY
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    static func mode(for type: NSEvent.EventType, flags: NSEvent.ModifierFlags,
                     required: NSEvent.ModifierFlags) -> Mode? {
        switch type {
        case .leftMouseDown:
            return modifiersMatch(flags, required: required) ? .move : nil
        case .rightMouseDown:
            if modifiersMatch(flags, required: required) { return .resizeCorner }
            if !required.contains(.shift), modifiersMatch(flags, required: required.union(.shift)) { return .resizeEdge }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Event tap (runs on the tap's thread)

    /// Returns true to swallow the event.
    private func filter(_ event: NSEvent) -> Bool {
        guard let cgEvent = event.cgEvent else { return false }
        if cgEvent.getIntegerValueField(.eventSourceUserData) == Self.replayMarker { return false }

        let button = CGMouseButton(rawValue: UInt32(cgEvent.getIntegerValueField(.mouseEventButtonNumber))) ?? .left
        let location = cgEvent.location

        lock.lock()
        defer { lock.unlock() }

        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            guard pressedButton == nil,
                  let mode = Self.mode(for: event.type, flags: event.modifierFlags, required: Self.requiredModifiers)
            else { return false }
            pressedButton = button
            pressLocation = location
            pressEvent = cgEvent.copy()
            dragging = false
            DispatchQueue.main.async { self.begin(mode: mode, at: location) }
            return true

        case .leftMouseDragged, .rightMouseDragged:
            guard pressedButton == button else { return false }
            if !dragging, hypot(location.x - pressLocation.x, location.y - pressLocation.y) >= Self.dragThreshold {
                dragging = true
            }
            if dragging {
                DispatchQueue.main.async { self.update(to: location) }
            }
            return true

        case .leftMouseUp, .rightMouseUp:
            guard pressedButton == button else { return false }
            let wasDragging = dragging
            let down = pressEvent
            let up = cgEvent.copy()
            resetGesture()
            DispatchQueue.main.async {
                self.end()
                if !wasDragging, let down, let up { Self.replay(down, up) }
            }
            return true

        default:
            return false
        }
    }

    /// Callers hold `lock`.
    private func resetGesture() {
        pressedButton = nil
        pressEvent = nil
        dragging = false
    }

    private static func replay(_ events: CGEvent...) {
        for event in events {
            event.setIntegerValueField(.eventSourceUserData, value: replayMarker)
            event.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - Window manipulation (main thread)

    private func begin(mode: Mode, at point: CGPoint) {
        session = nil
        guard let element = AccessibilityElement(point),
              let window = element.windowElement,
              window.pid != ProcessInfo.processInfo.processIdentifier,
              window.isFullScreen != true,
              window.isSheet != true,
              window.isSystemDialog != true
        else { return }
        if let bundleIdentifier = window.bundleIdentifier,
           Defaults.disabledApps.typedValue?.contains(bundleIdentifier) == true {
            return
        }
        let frame = window.frame
        guard !frame.isNull else { return }
        if mode != .move, !window.isResizable() { return }

        let handle = mode == .resizeEdge ? Self.nearestEdge(of: frame, to: point) : Self.nearestCorner(of: frame, to: point)
        let minimum = window.minimumSize ?? .zero
        session = Session(window: window, mode: mode, startPoint: point, startFrame: frame,
                          handle: handle,
                          minimumSize: CGSize(width: max(minimum.width, 64), height: max(minimum.height, 64)))
    }

    /// Drag events arrive faster than AX can apply frames, so only the newest point is applied.
    private func update(to point: CGPoint) {
        latestPoint = point
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyScheduled = false
            if let point = self.latestPoint { self.apply(point) }
        }
    }

    private func apply(_ point: CGPoint) {
        guard var session else { return }
        if !session.raised {
            session.window.raise()
            session.window.bringToFront()
            session.raised = true
            self.session = session
        }
        let delta = CGPoint(x: point.x - session.startPoint.x, y: point.y - session.startPoint.y)
        let start = session.startFrame

        switch session.mode {
        case .move:
            session.window.setPosition(CGPoint(x: start.minX + delta.x, y: start.minY + delta.y))
        case .resizeCorner, .resizeEdge:
            let handle = session.handle
            let target = Self.resizedFrame(from: start, handle: handle, delta: delta, minimumSize: session.minimumSize)
            // Apply the size first, then anchor the opposite sides using whatever size the window accepted.
            let accepted = session.window.setSize(target.size) ?? target.size
            if handle.left == true || handle.top == true {
                session.window.setPosition(Self.anchoredFrame(from: start, handle: handle, size: accepted).origin)
            }
        }
    }

    private func end() {
        // Any apply still queued finds latestPoint cleared and does nothing.
        if let point = latestPoint, session != nil {
            apply(point)
        }
        session = nil
        latestPoint = nil
    }
}
