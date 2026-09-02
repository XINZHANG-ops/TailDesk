import SwiftUI
import UIKit

struct MobileRemoteDesktopView: UIViewRepresentable {
    let frame: CGImage?
    let isInteractive: Bool
    let rotationQuarterTurns: Int
    let sendInput: (RemoteInputEvent) -> Void

    func makeUIView(context: Context) -> MobileRemoteCanvas {
        let view = MobileRemoteCanvas()
        view.sendInput = sendInput
        return view
    }

    func updateUIView(_ view: MobileRemoteCanvas, context: Context) {
        view.displayedImage = frame
        view.isInteractive = isInteractive
        view.rotationQuarterTurns = rotationQuarterTurns
        view.sendInput = sendInput
    }
}

final class MobileRemoteCanvas: UIView, UIGestureRecognizerDelegate {
    var sendInput: (RemoteInputEvent) -> Void = { _ in }
    var isInteractive = false
    var rotationQuarterTurns = 0 {
        didSet {
            guard rotationQuarterTurns != oldValue else { return }
            resetZoom()
        }
    }
    var displayedImage: CGImage? {
        didSet {
            let size = displayedImage.map { CGSize(width: $0.width, height: $0.height) }
            if size != imagePixelSize {
                imagePixelSize = size
                resetZoom()
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = displayedImage
            CATransaction.commit()
        }
    }

    private let imageLayer = CALayer()
    private var imagePixelSize: CGSize?
    private var zoomScale: CGFloat = 1
    private var imageOrigin = CGPoint.zero
    private var panStartOrigin = CGPoint.zero
    private var pinchStartScale: CGFloat = 1
    private var pinchAnchor = CGPoint(x: 0.5, y: 0.5)
    private var lastBoundsSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.masksToBounds = true
        imageLayer.contentsGravity = .resize
        layer.addSublayer(imageLayer)
        isMultipleTouchEnabled = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)

        let move = UIPanGestureRecognizer(target: self, action: #selector(movePointer(_:)))
        move.minimumNumberOfTouches = 1
        move.maximumNumberOfTouches = 1

        let drag = UILongPressGestureRecognizer(target: self, action: #selector(drag(_:)))
        drag.numberOfTapsRequired = 1
        drag.minimumPressDuration = 0.18
        tap.require(toFail: drag)
        move.require(toFail: drag)

        let rightClick = UITapGestureRecognizer(target: self, action: #selector(rightClick(_:)))
        rightClick.numberOfTouchesRequired = 2
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        rightClick.require(toFail: scroll)
        scroll.require(toFail: pinch)

        for recognizer in [tap, doubleTap, move, drag, rightClick, scroll, pinch] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }

#if DEBUG
        assert(Self.clampedOrigin(
            CGPoint(x: 100, y: -100),
            contentSize: CGSize(width: 200, height: 200),
            boundsSize: CGSize(width: 100, height: 100)
        ) == CGPoint(x: 0, y: -100))
        assert(Self.unrotated(CGPoint(x: 0, y: 1), quarterTurns: 1) == .zero)
        assert(Self.unrotated(CGPoint(x: 1, y: 1), quarterTurns: 2) == .zero)
        assert(Self.unrotated(CGPoint(x: 1, y: 0), quarterTurns: 3) == .zero)
#endif
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            resetZoom()
        } else {
            updateImageLayer()
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UIPinchGestureRecognizer {
            return isInteractive && displayedImage != nil
        }
        if gestureRecognizer is UILongPressGestureRecognizer, zoomScale > 1.001 {
            return false
        }
        if let pan = gestureRecognizer as? UIPanGestureRecognizer,
           pan.maximumNumberOfTouches == 1, zoomScale > 1.001 {
            return isInteractive
        }
        return isInteractive && normalized(gestureRecognizer.location(in: self)) != nil
    }

    @objc private func tap(_ sender: UITapGestureRecognizer) {
        guard sender.state == .ended, let point = normalized(sender.location(in: self)) else { return }
        send(.leftMouseDown, point)
        send(.leftMouseUp, point)
    }

    @objc private func rightClick(_ sender: UITapGestureRecognizer) {
        guard sender.state == .ended, let point = normalized(sender.location(in: self)) else { return }
        send(.rightMouseDown, point)
        send(.rightMouseUp, point)
    }

    @objc private func movePointer(_ sender: UIPanGestureRecognizer) {
        if zoomScale > 1.001 {
            switch sender.state {
            case .began:
                panStartOrigin = imageOrigin
            case .changed:
                let translation = sender.translation(in: self)
                imageOrigin = clampedOrigin(CGPoint(
                    x: panStartOrigin.x + translation.x,
                    y: panStartOrigin.y + translation.y
                ))
                updateImageLayer()
            default:
                break
            }
            return
        }
        guard let point = normalized(sender.location(in: self)) else { return }
        if sender.state == .began || sender.state == .changed { send(.mouseMove, point) }
    }

    @objc private func doubleTap(_ sender: UITapGestureRecognizer) {
        guard sender.state == .ended else { return }
        if zoomScale > 1.001 {
            resetZoom()
        } else {
            zoom(to: 2.5, around: sender.location(in: self))
        }
    }

    @objc private func pinch(_ sender: UIPinchGestureRecognizer) {
        guard let rect = currentImageRect else { return }
        let location = sender.location(in: self)
        switch sender.state {
        case .began:
            pinchStartScale = zoomScale
            pinchAnchor = CGPoint(
                x: min(1, max(0, (location.x - rect.minX) / rect.width)),
                y: min(1, max(0, (location.y - rect.minY) / rect.height))
            )
        case .changed:
            zoomScale = min(5, max(1, pinchStartScale * sender.scale))
            guard let base = baseContentRect else { return }
            let size = CGSize(width: base.width * zoomScale, height: base.height * zoomScale)
            imageOrigin = clampedOrigin(CGPoint(
                x: location.x - pinchAnchor.x * size.width,
                y: location.y - pinchAnchor.y * size.height
            ))
            updateImageLayer()
        default:
            if zoomScale < 1.01 { resetZoom() }
        }
    }

    @objc private func drag(_ sender: UILongPressGestureRecognizer) {
        guard let point = normalized(sender.location(in: self)) else { return }
        switch sender.state {
        case .began: send(.leftMouseDown, point)
        case .changed: send(.leftMouseDragged, point)
        case .ended, .cancelled: send(.leftMouseUp, point)
        default: break
        }
    }

    @objc private func scroll(_ sender: UIPanGestureRecognizer) {
        guard sender.state == .changed else { return }
        let translation = sender.translation(in: self)
        sender.setTranslation(.zero, in: self)
        sendInput(RemoteInputEvent(
            kind: .scroll,
            flags: RemoteModifier.preciseScroll,
            deltaX: translation.x * 2,
            deltaY: translation.y * 2
        ))
    }

    private func send(_ kind: RemoteInputEvent.Kind, _ point: CGPoint) {
        sendInput(RemoteInputEvent(kind: kind, x: point.x, y: point.y))
    }

    private func normalized(_ point: CGPoint) -> CGPoint? {
        guard let content = currentImageRect, content.contains(point) else { return nil }
        return Self.unrotated(CGPoint(
            x: (point.x - content.minX) / content.width,
            y: (point.y - content.minY) / content.height
        ), quarterTurns: rotationQuarterTurns)
    }

    private var baseContentRect: CGRect? {
        guard let displayedImage, bounds.width > 0, bounds.height > 0 else { return nil }
        let imageSize = rotationQuarterTurns.isMultiple(of: 2)
            ? CGSize(width: displayedImage.width, height: displayedImage.height)
            : CGSize(width: displayedImage.height, height: displayedImage.width)
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private var currentImageRect: CGRect? {
        guard let base = baseContentRect else { return nil }
        return CGRect(
            origin: imageOrigin,
            size: CGSize(width: base.width * zoomScale, height: base.height * zoomScale)
        )
    }

    private func zoom(to scale: CGFloat, around point: CGPoint) {
        guard let current = currentImageRect, let base = baseContentRect else { return }
        let anchor = CGPoint(
            x: min(1, max(0, (point.x - current.minX) / current.width)),
            y: min(1, max(0, (point.y - current.minY) / current.height))
        )
        zoomScale = min(5, max(1, scale))
        let size = CGSize(width: base.width * zoomScale, height: base.height * zoomScale)
        imageOrigin = clampedOrigin(CGPoint(
            x: point.x - anchor.x * size.width,
            y: point.y - anchor.y * size.height
        ))
        updateImageLayer()
    }

    private func resetZoom() {
        zoomScale = 1
        imageOrigin = baseContentRect?.origin ?? .zero
        updateImageLayer()
    }

    private func clampedOrigin(_ proposed: CGPoint) -> CGPoint {
        guard let base = baseContentRect else { return proposed }
        return Self.clampedOrigin(
            proposed,
            contentSize: CGSize(width: base.width * zoomScale, height: base.height * zoomScale),
            boundsSize: bounds.size
        )
    }

    private static func clampedOrigin(_ proposed: CGPoint, contentSize: CGSize, boundsSize: CGSize) -> CGPoint {
        CGPoint(
            x: contentSize.width <= boundsSize.width
                ? (boundsSize.width - contentSize.width) / 2
                : min(0, max(boundsSize.width - contentSize.width, proposed.x)),
            y: contentSize.height <= boundsSize.height
                ? (boundsSize.height - contentSize.height) / 2
                : min(0, max(boundsSize.height - contentSize.height, proposed.y))
        )
    }

    private static func unrotated(_ point: CGPoint, quarterTurns: Int) -> CGPoint {
        switch quarterTurns % 4 {
        case 1: CGPoint(x: 1 - point.y, y: point.x)
        case 2: CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 3: CGPoint(x: point.y, y: 1 - point.x)
        default: point
        }
    }

    private func updateImageLayer() {
        guard let rect = currentImageRect, let displayedImage else {
            imageLayer.setAffineTransform(.identity)
            imageLayer.frame = .zero
            return
        }
        let imageSize = CGSize(width: displayedImage.width, height: displayedImage.height)
        let displayedWidth = rotationQuarterTurns.isMultiple(of: 2) ? imageSize.width : imageSize.height
        let scale = rect.width / displayedWidth
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.bounds = CGRect(origin: .zero, size: imageSize)
        imageLayer.position = CGPoint(x: rect.midX, y: rect.midY)
        imageLayer.setAffineTransform(
            CGAffineTransform(rotationAngle: -CGFloat(rotationQuarterTurns) * .pi / 2)
                .scaledBy(x: scale, y: scale)
        )
        CATransaction.commit()
    }
}

struct RemoteKeyboardCapture: UIViewRepresentable {
    @Binding var active: Bool
    let sendText: (String) -> Void
    let sendKey: (UInt16) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(active: $active, sendText: sendText, sendKey: sendKey)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.text = " "
        field.textColor = .clear
        field.tintColor = .clear
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.smartDashesType = .no
        field.smartQuotesType = .no
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.active = $active
        if active, !field.isFirstResponder {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !active, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var active: Binding<Bool>
        let sendText: (String) -> Void
        let sendKey: (UInt16) -> Void
        private var deleteStreak = 0
        private var lastDeleteTime: TimeInterval = 0

        init(active: Binding<Bool>, sendText: @escaping (String) -> Void, sendKey: @escaping (UInt16) -> Void) {
            self.active = active
            self.sendText = sendText
            self.sendKey = sendKey
#if DEBUG
            assert(Self.deleteRepeatCount(streak: 1) == 1)
            assert(Self.deleteRepeatCount(streak: 8) == 2)
            assert(Self.deleteRepeatCount(streak: 18) == 3)
#endif
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if string.isEmpty {
                let now = ProcessInfo.processInfo.systemUptime
                let continuationWindow = deleteStreak >= 4 ? 1.5 : 0.7
                deleteStreak = now - lastDeleteTime <= continuationWindow ? deleteStreak + 1 : 1
                lastDeleteTime = now
                for _ in 0..<Self.deleteRepeatCount(streak: deleteStreak) {
                    sendKey(51) // macOS Delete
                }
            } else {
                deleteStreak = 0
                sendText(string)
            }
            return false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            sendKey(36) // macOS Return
            return false
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            deleteStreak = 0
            active.wrappedValue = false
        }

        private static func deleteRepeatCount(streak: Int) -> Int {
            streak >= 18 ? 3 : (streak >= 8 ? 2 : 1)
        }
    }
}
