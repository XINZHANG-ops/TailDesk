import AppKit
import ApplicationServices
import SwiftUI

struct RemoteDesktopView: NSViewRepresentable {
    let frame: CGImage?
    var isInteractive = true
    var onActivate: () -> Void = {}
    var onControlRevealZoneChanged: (Bool) -> Void = { _ in }
    var onCrossDisplayEdge: (RemoteDisplayEdge, Double) -> RemoteDisplayTransition? = { _, _ in nil }
    let sendInput: (RemoteInputEvent) -> Void

    func makeNSView(context: Context) -> RemoteCanvasView {
        let view = RemoteCanvasView()
        view.isInteractive = isInteractive
        view.onActivate = onActivate
        view.onControlRevealZoneChanged = onControlRevealZoneChanged
        view.onCrossDisplayEdge = onCrossDisplayEdge
        view.sendInput = sendInput
        return view
    }

    func updateNSView(_ view: RemoteCanvasView, context: Context) {
        view.displayedImage = frame
        view.isInteractive = isInteractive
        view.onActivate = onActivate
        view.onControlRevealZoneChanged = onControlRevealZoneChanged
        view.onCrossDisplayEdge = onCrossDisplayEdge
        view.sendInput = sendInput
    }
}

final class RemoteCanvasView: NSView {
    var isInteractive = true
    var onActivate: () -> Void = {}
    var onControlRevealZoneChanged: (Bool) -> Void = { _ in }
    var onCrossDisplayEdge: (RemoteDisplayEdge, Double) -> RemoteDisplayTransition? = { _, _ in nil }
    var sendInput: (RemoteInputEvent) -> Void = { _ in }
    private static let displayEdgeDwell: TimeInterval = 0.4
    private var suppressNextMouseUp = false
    private var wasInControlRevealZone = false
    private var dragPoint: CGPoint?
    private var lastDragLocation: CGPoint?
    private var dragScale = CGPoint(x: 1, y: 1)
    private var dragFlags: UInt8 = 0
    private var pendingDisplayEdge: RemoteDisplayEdge?
    private var blockedDisplayEdge: RemoteDisplayEdge?
    private var reentryDisplayEdge: RemoteDisplayEdge?
    private var displayEdgeWorkItem: DispatchWorkItem?
    var displayedImage: CGImage? {
        didSet {
            layer?.contents = displayedImage
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { isInteractive }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseMoved],
            owner: self
        ))
#if DEBUG
        assert(Self.outgoingEdge(for: CGPoint(x: 1, y: 0.5), delta: CGPoint(x: 0.01, y: 0)) == .right)
        assert(Self.movesTowardEdge(CGPoint(x: -0.01, y: 0), .left))
#endif
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else {
            suppressNextMouseUp = true
            onActivate()
            return
        }
        window?.makeFirstResponder(self)
        let local = convert(event.locationInWindow, from: nil)
        guard let point = normalizedPoint(for: local) else { return }
        dragPoint = point
        lastDragLocation = local
        dragScale = CGPoint(x: 1, y: 1)
        dragFlags = modifierFlags(event)
        sendInput(RemoteInputEvent(
            kind: .leftMouseDown,
            x: point.x,
            y: point.y,
            flags: dragFlags,
            clickCount: event.clickCount
        ))
    }

    override func mouseUp(with event: NSEvent) {
        if suppressNextMouseUp {
            suppressNextMouseUp = false
        } else if isInteractive {
            let point = dragPoint ?? normalizedPoint(for: convert(event.locationInWindow, from: nil))
            if let point {
                sendInput(RemoteInputEvent(
                    kind: .leftMouseUp,
                    x: point.x,
                    y: point.y,
                    flags: modifierFlags(event),
                    clickCount: event.clickCount
                ))
            }
        }
        resetDrag()
    }
    override func mouseMoved(with event: NSEvent) {
        guard isInteractive else { return }
        let local = convert(event.locationInWindow, from: nil)
        let inControlRevealZone = shouldRevealControls(at: local, contentRect: remoteContentRect, in: bounds)
        if inControlRevealZone != wasInControlRevealZone {
            wasInControlRevealZone = inControlRevealZone
            onControlRevealZoneChanged(inControlRevealZone)
        }
        sendMouse(.mouseMove, event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteractive,
              let contentRect = remoteContentRect,
              var point = dragPoint,
              let previousLocation = lastDragLocation else { return }
        let location = convert(event.locationInWindow, from: nil)
        var delta = CGPoint(
            x: (location.x - previousLocation.x) / contentRect.width * dragScale.x,
            y: -(location.y - previousLocation.y) / contentRect.height * dragScale.y
        )
        if let reentryDisplayEdge,
           Self.isAtEdge(point, reentryDisplayEdge, threshold: 0.05),
           Self.movesTowardEdge(delta, reentryDisplayEdge) {
            if reentryDisplayEdge == .left || reentryDisplayEdge == .right {
                dragScale.x *= -1
                delta.x *= -1
            } else {
                dragScale.y *= -1
                delta.y *= -1
            }
        }
        point.x = min(1, max(0, point.x + delta.x))
        point.y = min(1, max(0, point.y + delta.y))
        if let reentryDisplayEdge, !Self.isAtEdge(point, reentryDisplayEdge, threshold: 0.05) {
            self.reentryDisplayEdge = nil
        }
        dragPoint = point
        lastDragLocation = location
        dragFlags = modifierFlags(event)
        sendInput(RemoteInputEvent(kind: .leftMouseDragged, x: point.x, y: point.y, flags: dragFlags))
        updateDisplayEdgeDwell(for: point, delta: delta)
    }
    override func rightMouseDown(with event: NSEvent) { if isInteractive { sendMouse(.rightMouseDown, event) } }
    override func rightMouseUp(with event: NSEvent) { if isInteractive { sendMouse(.rightMouseUp, event) } }
    override func rightMouseDragged(with event: NSEvent) { if isInteractive { sendMouse(.rightMouseDragged, event) } }

    override func scrollWheel(with event: NSEvent) {
        guard isInteractive else { return }
        var flags = modifierFlags(event)
        if event.hasPreciseScrollingDeltas { flags |= RemoteModifier.preciseScroll }
        sendInput(RemoteInputEvent(
            kind: .scroll,
            flags: flags,
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY
        ))
    }

    override func swipe(with event: NSEvent) {
        guard isInteractive,
              let keyCode = remoteSwipeShortcut(deltaX: event.deltaX, deltaY: event.deltaY) else {
            super.swipe(with: event)
            return
        }
        sendInput(RemoteInputEvent(kind: .keyDown, keyCode: keyCode, flags: RemoteModifier.control))
        sendInput(RemoteInputEvent(kind: .keyUp, keyCode: keyCode, flags: RemoteModifier.control))
    }

    override func keyDown(with event: NSEvent) {
        guard isInteractive else { return }
        sendInput(RemoteInputEvent(kind: .keyDown, keyCode: event.keyCode, flags: modifierFlags(event)))
    }

    override func keyUp(with event: NSEvent) {
        guard isInteractive else { return }
        sendInput(RemoteInputEvent(kind: .keyUp, keyCode: event.keyCode, flags: modifierFlags(event)))
    }

    private func sendMouse(_ kind: RemoteInputEvent.Kind, _ event: NSEvent) {
        guard let point = normalizedPoint(for: convert(event.locationInWindow, from: nil)) else { return }
        sendInput(RemoteInputEvent(
            kind: kind,
            x: point.x,
            y: point.y,
            flags: modifierFlags(event),
            clickCount: mouseClickCount(kind, event.clickCount)
        ))
    }

    private func normalizedPoint(for local: CGPoint) -> CGPoint? {
        guard let contentRect = remoteContentRect else { return nil }
        guard contentRect.contains(local) else { return nil }
        return CGPoint(
            x: (local.x - contentRect.minX) / contentRect.width,
            y: 1 - (local.y - contentRect.minY) / contentRect.height
        )
    }

    private func updateDisplayEdgeDwell(for point: CGPoint, delta: CGPoint) {
        if let blockedDisplayEdge, !Self.isAtEdge(point, blockedDisplayEdge, threshold: 0.05) {
            self.blockedDisplayEdge = nil
        }
        guard let edge = Self.outgoingEdge(for: point, delta: delta), edge != blockedDisplayEdge else {
            displayEdgeWorkItem?.cancel()
            displayEdgeWorkItem = nil
            pendingDisplayEdge = nil
            return
        }
        guard pendingDisplayEdge != edge else { return }
        displayEdgeWorkItem?.cancel()
        pendingDisplayEdge = edge
        let position = edge == .left || edge == .right ? point.y : point.x
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.dragPoint != nil, self.pendingDisplayEdge == edge else { return }
            self.pendingDisplayEdge = nil
            self.displayEdgeWorkItem = nil
            guard let transition = self.onCrossDisplayEdge(edge, position) else {
                self.blockedDisplayEdge = edge
                return
            }
            let newPoint = CGPoint(x: transition.x, y: transition.y)
            self.dragPoint = newPoint
            self.blockedDisplayEdge = nil
            self.reentryDisplayEdge = edge.opposite
            self.sendInput(RemoteInputEvent(
                kind: .leftMouseDragged,
                x: newPoint.x,
                y: newPoint.y,
                flags: self.dragFlags
            ))
        }
        displayEdgeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayEdgeDwell, execute: workItem)
    }

    private func resetDrag() {
        displayEdgeWorkItem?.cancel()
        displayEdgeWorkItem = nil
        pendingDisplayEdge = nil
        blockedDisplayEdge = nil
        reentryDisplayEdge = nil
        dragPoint = nil
        lastDragLocation = nil
        dragScale = CGPoint(x: 1, y: 1)
    }

    private static func outgoingEdge(for point: CGPoint, delta: CGPoint) -> RemoteDisplayEdge? {
        let horizontal: RemoteDisplayEdge? = delta.x < 0 && point.x <= 0.005
            ? .left : delta.x > 0 && point.x >= 0.995 ? .right : nil
        let vertical: RemoteDisplayEdge? = delta.y < 0 && point.y <= 0.005
            ? .top : delta.y > 0 && point.y >= 0.995 ? .bottom : nil
        if horizontal != nil && vertical != nil {
            return abs(delta.x) >= abs(delta.y) ? horizontal : vertical
        }
        return horizontal ?? vertical
    }

    private static func isAtEdge(_ point: CGPoint, _ edge: RemoteDisplayEdge, threshold: CGFloat) -> Bool {
        switch edge {
        case .left: point.x <= threshold
        case .right: point.x >= 1 - threshold
        case .top: point.y <= threshold
        case .bottom: point.y >= 1 - threshold
        }
    }

    private static func movesTowardEdge(_ delta: CGPoint, _ edge: RemoteDisplayEdge) -> Bool {
        switch edge {
        case .left: delta.x < 0
        case .right: delta.x > 0
        case .top: delta.y < 0
        case .bottom: delta.y > 0
        }
    }

    private var remoteContentRect: CGRect? {
        guard let displayedImage, bounds.width > 0, bounds.height > 0 else { return nil }
        let imageWidth = CGFloat(displayedImage.width)
        let imageHeight = CGFloat(displayedImage.height)
        let scale = min(bounds.width / imageWidth, bounds.height / imageHeight)
        let contentSize = CGSize(width: imageWidth * scale, height: imageHeight * scale)
        return CGRect(
            x: (bounds.width - contentSize.width) / 2,
            y: (bounds.height - contentSize.height) / 2,
            width: contentSize.width,
            height: contentSize.height
        )
    }

    private func modifierFlags(_ event: NSEvent) -> UInt8 {
        let flags = event.modifierFlags
        var result: UInt8 = 0
        if flags.contains(.shift) { result |= RemoteModifier.shift }
        if flags.contains(.control) { result |= RemoteModifier.control }
        if flags.contains(.option) { result |= RemoteModifier.option }
        if flags.contains(.command) { result |= RemoteModifier.command }
        if flags.contains(.capsLock) { result |= RemoteModifier.capsLock }
        return result
    }
}

private func shouldRevealControls(at point: CGPoint, contentRect: CGRect?, in bounds: CGRect, edgeThreshold: CGFloat = 3) -> Bool {
    guard bounds.contains(point) else { return false }
    return contentRect?.contains(point) != true || point.y >= bounds.maxY - edgeThreshold
}

enum InputInjector {
    static func post(_ remote: RemoteInputEvent) {
        guard AXIsProcessTrusted(), let source = CGEventSource(stateID: .hidSystemState) else { return }
        if remote.kind == .text {
            postText(remote.text ?? "", source: source)
            return
        }
        var bounds = CGDisplayBounds(remote.displayID ?? CGMainDisplayID())
        if bounds.isEmpty { bounds = CGDisplayBounds(CGMainDisplayID()) }
        let point = CGPoint(
            x: bounds.minX + max(0, min(1, remote.x)) * bounds.width,
            y: bounds.minY + max(0, min(1, remote.y)) * bounds.height
        )
        let flags = cgFlags(remote.flags)
        let event: CGEvent?

        switch remote.kind {
        case .mouseMove:
            event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        case .leftMouseDown:
            event = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        case .leftMouseUp:
            event = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        case .leftMouseDragged:
            event = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)
        case .rightMouseDown:
            event = CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)
        case .rightMouseUp:
            event = CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)
        case .rightMouseDragged:
            event = CGEvent(mouseEventSource: source, mouseType: .rightMouseDragged, mouseCursorPosition: point, mouseButton: .right)
        case .scroll:
            event = CGEvent(
                scrollWheelEvent2Source: source,
                units: scrollUnit(for: remote.flags),
                wheelCount: 2,
                wheel1: Int32(remote.deltaY.rounded()),
                wheel2: Int32(remote.deltaX.rounded()),
                wheel3: 0
            )
        case .keyDown:
            event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(remote.keyCode), keyDown: true)
        case .keyUp:
            event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(remote.keyCode), keyDown: false)
        case .text, .requestKeyFrame, .requestDisplayList, .selectDisplay:
            event = nil
        }
        event?.flags = flags
        if let clickCount = remote.clickCount {
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, min(3, clickCount))))
        }
        event?.post(tap: .cghidEventTap)
    }

    private static func postText(_ text: String, source: CGEventSource) {
        guard !text.isEmpty else { return }
        let characters = Array(text.utf16)
        guard characters.count <= 256,
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        keyDown.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func cgFlags(_ remote: UInt8) -> CGEventFlags {
        var flags: CGEventFlags = []
        if remote & RemoteModifier.shift != 0 { flags.insert(.maskShift) }
        if remote & RemoteModifier.control != 0 { flags.insert(.maskControl) }
        if remote & RemoteModifier.option != 0 { flags.insert(.maskAlternate) }
        if remote & RemoteModifier.command != 0 { flags.insert(.maskCommand) }
        if remote & RemoteModifier.capsLock != 0 { flags.insert(.maskAlphaShift) }
        return flags
    }
}

private func scrollUnit(for flags: UInt8) -> CGScrollEventUnit {
    flags & RemoteModifier.preciseScroll == 0 ? .line : .pixel
}

private func mouseClickCount(_ kind: RemoteInputEvent.Kind, _ count: Int) -> Int? {
    switch kind {
    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
        return count
    default:
        return nil
    }
}

private func remoteSwipeShortcut(deltaX: CGFloat, deltaY: CGFloat) -> UInt16? {
    if abs(deltaY) >= abs(deltaX), deltaY != 0 { return deltaY > 0 ? 126 : 125 }
    if deltaX != 0 { return deltaX > 0 ? 124 : 123 }
    return nil
}

enum InputSelfCheck {
    static func run() {
        precondition(scrollUnit(for: 0) == .line)
        precondition(scrollUnit(for: RemoteModifier.preciseScroll) == .pixel)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let content = CGRect(x: 10, y: 0, width: 80, height: 100)
        precondition(shouldRevealControls(at: CGPoint(x: 5, y: 50), contentRect: content, in: bounds))
        precondition(shouldRevealControls(at: CGPoint(x: 50, y: 98), contentRect: content, in: bounds))
        precondition(!shouldRevealControls(at: CGPoint(x: 50, y: 50), contentRect: content, in: bounds))
        precondition(mouseClickCount(.leftMouseDown, 2) == 2)
        precondition(mouseClickCount(.mouseMove, 2) == nil)
        precondition(remoteSwipeShortcut(deltaX: 0, deltaY: 1) == 126)
        precondition(remoteSwipeShortcut(deltaX: 0, deltaY: -1) == 125)
        precondition(remoteSwipeShortcut(deltaX: 1, deltaY: 0) == 124)
        precondition(remoteSwipeShortcut(deltaX: -1, deltaY: 0) == 123)
        precondition(remoteSwipeShortcut(deltaX: 0, deltaY: 0) == nil)
    }
}
