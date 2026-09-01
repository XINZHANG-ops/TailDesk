import AppKit
import ApplicationServices
import SwiftUI

struct RemoteDesktopView: NSViewRepresentable {
    let frame: CGImage?
    var isInteractive = true
    var onActivate: () -> Void = {}
    let sendInput: (RemoteInputEvent) -> Void

    func makeNSView(context: Context) -> RemoteCanvasView {
        let view = RemoteCanvasView()
        view.isInteractive = isInteractive
        view.onActivate = onActivate
        view.sendInput = sendInput
        return view
    }

    func updateNSView(_ view: RemoteCanvasView, context: Context) {
        view.displayedImage = frame
        view.isInteractive = isInteractive
        view.onActivate = onActivate
        view.sendInput = sendInput
    }
}

final class RemoteCanvasView: NSView {
    var isInteractive = true
    var onActivate: () -> Void = {}
    var sendInput: (RemoteInputEvent) -> Void = { _ in }
    private var suppressNextMouseUp = false
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
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else {
            suppressNextMouseUp = true
            onActivate()
            return
        }
        window?.makeFirstResponder(self)
        sendMouse(.leftMouseDown, event)
    }

    override func mouseUp(with event: NSEvent) {
        if suppressNextMouseUp {
            suppressNextMouseUp = false
        } else if isInteractive {
            sendMouse(.leftMouseUp, event)
        }
    }
    override func mouseMoved(with event: NSEvent) { if isInteractive { sendMouse(.mouseMove, event) } }
    override func mouseDragged(with event: NSEvent) { if isInteractive { sendMouse(.leftMouseDragged, event) } }
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

    override func keyDown(with event: NSEvent) {
        guard isInteractive else { return }
        sendInput(RemoteInputEvent(kind: .keyDown, keyCode: event.keyCode, flags: modifierFlags(event)))
    }

    override func keyUp(with event: NSEvent) {
        guard isInteractive else { return }
        sendInput(RemoteInputEvent(kind: .keyUp, keyCode: event.keyCode, flags: modifierFlags(event)))
    }

    private func sendMouse(_ kind: RemoteInputEvent.Kind, _ event: NSEvent) {
        guard let point = normalizedPoint(for: event) else { return }
        sendInput(RemoteInputEvent(kind: kind, x: point.x, y: point.y, flags: modifierFlags(event)))
    }

    private func normalizedPoint(for event: NSEvent) -> CGPoint? {
        guard let displayedImage, bounds.width > 0, bounds.height > 0 else { return nil }
        let imageWidth = CGFloat(displayedImage.width)
        let imageHeight = CGFloat(displayedImage.height)
        let scale = min(bounds.width / imageWidth, bounds.height / imageHeight)
        let contentSize = CGSize(width: imageWidth * scale, height: imageHeight * scale)
        let contentRect = CGRect(
            x: (bounds.width - contentSize.width) / 2,
            y: (bounds.height - contentSize.height) / 2,
            width: contentSize.width,
            height: contentSize.height
        )
        let local = convert(event.locationInWindow, from: nil)
        guard contentRect.contains(local) else { return nil }
        return CGPoint(
            x: (local.x - contentRect.minX) / contentRect.width,
            y: 1 - (local.y - contentRect.minY) / contentRect.height
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

enum InputInjector {
    static func post(_ remote: RemoteInputEvent) {
        guard AXIsProcessTrusted(), let source = CGEventSource(stateID: .hidSystemState) else { return }
        if remote.kind == .text {
            postText(remote.text ?? "", source: source)
            return
        }
        let bounds = CGDisplayBounds(CGMainDisplayID())
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
        case .text:
            event = nil
        }
        event?.flags = flags
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

enum InputSelfCheck {
    static func run() {
        precondition(scrollUnit(for: 0) == .line)
        precondition(scrollUnit(for: RemoteModifier.preciseScroll) == .pixel)
    }
}
