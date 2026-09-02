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
            updateImageLayer()
        }
    }
    var displayedImage: CGImage? {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = displayedImage
            CATransaction.commit()
            updateImageLayer()
        }
    }

    private let imageLayer = CALayer()
    private let magnifier = PrecisionMagnifier(frame: CGRect(x: 0, y: 0, width: 144, height: 144))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.masksToBounds = true
        imageLayer.contentsGravity = .resize
        layer.addSublayer(imageLayer)
        isMultipleTouchEnabled = true
        magnifier.isHidden = true
        addSubview(magnifier)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))

        let move = UIPanGestureRecognizer(target: self, action: #selector(movePointer(_:)))
        move.minimumNumberOfTouches = 1
        move.maximumNumberOfTouches = 1

        let precisionClick = UILongPressGestureRecognizer(target: self, action: #selector(precisionClick(_:)))
        precisionClick.minimumPressDuration = 0.32
        precisionClick.allowableMovement = 18
        tap.require(toFail: precisionClick)
        move.require(toFail: precisionClick)

        let rightClick = UITapGestureRecognizer(target: self, action: #selector(rightClick(_:)))
        rightClick.numberOfTouchesRequired = 2
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        rightClick.require(toFail: scroll)

        for recognizer in [tap, move, precisionClick, rightClick, scroll] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }

#if DEBUG
        assert(Self.unrotated(CGPoint(x: 0, y: 1), quarterTurns: 1) == .zero)
        assert(Self.unrotated(CGPoint(x: 1, y: 1), quarterTurns: 2) == .zero)
        assert(Self.unrotated(CGPoint(x: 1, y: 0), quarterTurns: 3) == .zero)
#endif
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateImageLayer()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
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
        guard let point = normalized(sender.location(in: self)) else { return }
        if sender.state == .began || sender.state == .changed { send(.mouseMove, point) }
    }

    @objc private func precisionClick(_ sender: UILongPressGestureRecognizer) {
        guard let location = clampedToImage(sender.location(in: self)), let point = normalized(location) else {
            hideMagnifier()
            return
        }
        switch sender.state {
        case .began:
            showMagnifier(at: location, capture: true)
            send(.mouseMove, point)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .changed:
            showMagnifier(at: location, capture: false)
            send(.mouseMove, point)
        case .ended:
            send(.leftMouseDown, point)
            send(.leftMouseUp, point)
            hideMagnifier()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .cancelled, .failed:
            hideMagnifier()
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
        baseContentRect
    }

    private func clampedToImage(_ point: CGPoint) -> CGPoint? {
        guard let rect = currentImageRect else { return nil }
        return CGPoint(
            x: min(rect.maxX, max(rect.minX, point.x)),
            y: min(rect.maxY, max(rect.minY, point.y))
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

    private func showMagnifier(at point: CGPoint, capture: Bool) {
        if capture {
            magnifier.isHidden = true
            magnifier.snapshot = UIGraphicsImageRenderer(bounds: bounds).image { context in
                layer.render(in: context.cgContext)
            }
        }
        magnifier.sourcePoint = point
        let half = magnifier.bounds.width / 2
        let gap = half + 18
        let preferredY = point.y - gap
        magnifier.center = CGPoint(
            x: min(bounds.maxX - half - 8, max(bounds.minX + half + 8, point.x)),
            y: preferredY - half > bounds.minY ? preferredY : min(bounds.maxY - half - 8, point.y + gap)
        )
        magnifier.isHidden = false
        magnifier.setNeedsDisplay()
    }

    private func hideMagnifier() {
        magnifier.isHidden = true
        magnifier.snapshot = nil
    }
}

private final class PrecisionMagnifier: UIView {
    var snapshot: UIImage?
    var sourcePoint = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .black
        layer.cornerRadius = frame.width / 2
        layer.borderWidth = 4
        layer.borderColor = UIColor.white.cgColor
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ rect: CGRect) {
        guard let snapshot, let context = UIGraphicsGetCurrentContext() else { return }
        let scale: CGFloat = 3
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -sourcePoint.x, y: -sourcePoint.y)
        snapshot.draw(at: .zero)
        context.restoreGState()

        let innerFrame = UIBezierPath(ovalIn: bounds.insetBy(dx: 6, dy: 6))
        UIColor(red: 0.02, green: 0.10, blue: 0.23, alpha: 0.8).setStroke()
        innerFrame.lineWidth = 2
        innerFrame.stroke()

        let crosshair = UIBezierPath()
        crosshair.move(to: CGPoint(x: bounds.midX - 12, y: bounds.midY))
        crosshair.addLine(to: CGPoint(x: bounds.midX + 12, y: bounds.midY))
        crosshair.move(to: CGPoint(x: bounds.midX, y: bounds.midY - 12))
        crosshair.addLine(to: CGPoint(x: bounds.midX, y: bounds.midY + 12))
        UIColor.white.withAlphaComponent(0.9).setStroke()
        crosshair.lineWidth = 5
        crosshair.stroke()
        UIColor(red: 0.01, green: 0.07, blue: 0.17, alpha: 1).setStroke()
        crosshair.lineWidth = 2.5
        crosshair.stroke()
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
