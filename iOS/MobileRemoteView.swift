import SwiftUI
import UIKit

func mobileRemoteContentRect(imageSize: CGSize, in bounds: CGRect, quarterTurns: Int) -> CGRect? {
    guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
    let displayedSize = quarterTurns.isMultiple(of: 2)
        ? imageSize
        : CGSize(width: imageSize.height, height: imageSize.width)
    let scale = min(bounds.width / displayedSize.width, bounds.height / displayedSize.height)
    let size = CGSize(width: displayedSize.width * scale, height: displayedSize.height * scale)
    return CGRect(
        x: bounds.midX - size.width / 2,
        y: bounds.midY - size.height / 2,
        width: size.width,
        height: size.height
    )
}

struct MobileRemoteDesktopView: UIViewRepresentable {
    let frame: CGImage?
    let isInteractive: Bool
    let rotationQuarterTurns: Int
    let sendInput: (RemoteInputEvent) -> Void
    let onPointerPositionChanged: (CGPoint) -> Void
    let onCopySuggested: () -> Void
    let onCrossDisplayEdge: (RemoteDisplayEdge, Double) -> RemoteDisplayTransition?

    func makeUIView(context: Context) -> MobileRemoteCanvas {
        let view = MobileRemoteCanvas()
        view.sendInput = sendInput
        view.onPointerPositionChanged = onPointerPositionChanged
        view.onCopySuggested = onCopySuggested
        view.onCrossDisplayEdge = onCrossDisplayEdge
        return view
    }

    func updateUIView(_ view: MobileRemoteCanvas, context: Context) {
        view.displayedImage = frame
        view.isInteractive = isInteractive
        view.rotationQuarterTurns = rotationQuarterTurns
        view.sendInput = sendInput
        view.onPointerPositionChanged = onPointerPositionChanged
        view.onCopySuggested = onCopySuggested
        view.onCrossDisplayEdge = onCrossDisplayEdge
    }
}

final class MobileRemoteCanvas: UIView, UIGestureRecognizerDelegate {
    var sendInput: (RemoteInputEvent) -> Void = { _ in }
    var onPointerPositionChanged: (CGPoint) -> Void = { _ in }
    var onCopySuggested: () -> Void = {}
    var onCrossDisplayEdge: (RemoteDisplayEdge, Double) -> RemoteDisplayTransition? = { _, _ in nil }
    var isInteractive = false {
        didSet {
            if oldValue && !isInteractive { cancelPrecisionInteraction() }
        }
    }
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
            refreshMagnifierSnapshot()
        }
    }

    private let imageLayer = CALayer()
    private let magnifierGuideOutlineLayer = CAShapeLayer()
    private let magnifierGuideLayer = CAShapeLayer()
    private let magnifierTargetLayer = CAShapeLayer()
    private let magnifier = PrecisionMagnifier(frame: CGRect(x: 0, y: 0, width: 176, height: 176))
    private static let precisionDragDwell: TimeInterval = 0.8
    private static let displayEdgeDwell: TimeInterval = 0.4
    private static let precisionDwellMovement: CGFloat = 3
    private var lastMagnifierRefreshTime: TimeInterval = 0
    private var lastPrecisionPoint: CGPoint?
    private var precisionDwellAnchor: CGPoint?
    private var precisionDwellWorkItem: DispatchWorkItem?
    private var precisionGestureActive = false
    private var precisionDragging = false
    private var precisionDragPoint: CGPoint?
    private var lastPrecisionRawPoint: CGPoint?
    private var lastPrecisionFingerLocation: CGPoint?
    private var precisionDragScale = CGPoint(x: 1, y: 1)
    private var pendingDisplayEdge: RemoteDisplayEdge?
    private var blockedDisplayEdge: RemoteDisplayEdge?
    private var reentryDisplayEdge: RemoteDisplayEdge?
    private var displayEdgeWorkItem: DispatchWorkItem?
    private var previousTapTime: TimeInterval = 0
    private var previousTapLocation = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.masksToBounds = true
        imageLayer.contentsGravity = .resize
        layer.addSublayer(imageLayer)
        configureMagnifierGuide()
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
        let landscapeFit = mobileRemoteContentRect(
            imageSize: CGSize(width: 1_920, height: 1_080),
            in: CGRect(x: 0, y: 0, width: 844, height: 390),
            quarterTurns: 0
        )!
        assert(abs(landscapeFit.minX - 75.3333) < 0.001 && landscapeFit.height == 390)
        assert(Self.unrotated(CGPoint(x: 0, y: 1), quarterTurns: 1) == .zero)
        assert(Self.unrotated(CGPoint(x: 1, y: 1), quarterTurns: 2) == .zero)
        assert(Self.unrotated(CGPoint(x: 1, y: 0), quarterTurns: 3) == .zero)
        assert(Self.isDoubleTap(previousTime: 1, previousLocation: .zero, time: 1.3, location: CGPoint(x: 20, y: 20)))
        assert(!Self.isDoubleTap(previousTime: 1, previousLocation: .zero, time: 1.5, location: .zero))
        assert(!Self.didMove(from: .zero, to: CGPoint(x: 0.0001, y: 0.0001)))
        assert(Self.didMove(from: .zero, to: CGPoint(x: 0.001, y: 0)))
        assert(!Self.movedBeyondPrecisionDwell(from: .zero, to: CGPoint(x: 2, y: 2)))
        assert(Self.movedBeyondPrecisionDwell(from: .zero, to: CGPoint(x: 4, y: 0)))
        assert(Self.edgeReach(0.5) == 0.5)
        assert(Self.edgeReach(0.06) == 0)
        assert(abs(Self.edgeReach(0.18) - 0.18) < 0.0001)
        assert(abs(Self.edgeReach(0.94) - 1) < 0.0001)
        assert(Self.outgoingEdge(for: CGPoint(x: 1, y: 0.5), delta: CGPoint(x: 0.01, y: 0)) == .right)
        assert(Self.movesTowardEdge(CGPoint(x: -0.01, y: 0), .left))
        assert(Self.isAtEdge(CGPoint(x: 0.985, y: 0.5), .right, threshold: 0.02))
        assert(!Self.isAtEdge(CGPoint(x: 0.97, y: 0.5), .right, threshold: 0.02))
        assert(Self.scrollDelta(for: CGPoint(x: 2, y: 3), quarterTurns: 0) == CGPoint(x: -8, y: -12))
        assert(Self.scrollDelta(for: CGPoint(x: 2, y: 3), quarterTurns: 3) == CGPoint(x: -12, y: 8))
        let phoneBounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let topLeftLens = Self.magnifierCenter(
            near: CGPoint(x: 20, y: 20),
            in: phoneBounds,
            lensSize: magnifier.bounds.size
        )
        assert(topLeftLens.x > 20 && topLeftLens.y >= 80)
        assert(Self.magnifierCenter(
            near: CGPoint(x: 195, y: 422),
            in: phoneBounds,
            lensSize: magnifier.bounds.size
        ).y < 422)
        let guide = Self.magnifierGuide(
            from: .zero,
            to: CGPoint(x: 100, y: 0),
            lensRadius: 20,
            markerRadius: 4.5
        )
        assert(guide?.start == CGPoint(x: 19, y: 0))
        assert(guide?.end == CGPoint(x: 95.5, y: 0))
        assert(PrecisionMagnifier.guideEndpoint(
            from: .zero,
            direction: CGVector(dx: 1, dy: 0),
            length: 10
        ) == CGPoint(x: 10, y: 0))
#endif
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        magnifierGuideOutlineLayer.frame = bounds
        magnifierGuideLayer.frame = bounds
        magnifierTargetLayer.frame = bounds
        CATransaction.commit()
        updateImageLayer()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return isInteractive && normalized(gestureRecognizer.location(in: self)) != nil
    }

    @objc private func tap(_ sender: UITapGestureRecognizer) {
        let location = sender.location(in: self)
        guard sender.state == .ended, let point = normalized(location) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let isDouble = Self.isDoubleTap(
            previousTime: previousTapTime,
            previousLocation: previousTapLocation,
            time: now,
            location: location
        )
        let clickCount = isDouble ? 2 : 1
        send(.leftMouseDown, point, clickCount: clickCount)
        send(.leftMouseUp, point, clickCount: clickCount)
        onCopySuggested()
        previousTapTime = isDouble ? 0 : now
        previousTapLocation = location
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
        if sender.state == .ended {
            guard let point = precisionDragPoint ?? lastPrecisionPoint else {
                cancelPrecisionInteraction()
                return
            }
            precisionDwellWorkItem?.cancel()
            precisionDwellWorkItem = nil
            precisionGestureActive = false
            if precisionDragging {
                send(.leftMouseUp, point)
            } else {
                send(.leftMouseDown, point)
                send(.leftMouseUp, point)
            }
            precisionDragging = false
            precisionDwellAnchor = nil
            resetDisplayEdgeDwell()
            hideMagnifier()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onCopySuggested()
            return
        }
        if sender.state == .cancelled || sender.state == .failed {
            cancelPrecisionInteraction()
            return
        }
        guard let fingerLocation = clampedToImage(sender.location(in: self)),
              let targetLocation = precisionTarget(for: fingerLocation),
              let point = normalized(targetLocation) else {
            cancelPrecisionInteraction()
            return
        }
        switch sender.state {
        case .began:
            precisionGestureActive = true
            precisionDragging = false
            lastPrecisionFingerLocation = fingerLocation
            showMagnifier(at: targetLocation, near: fingerLocation)
            sendPrecisionMove(point)
            schedulePrecisionDragLock(at: targetLocation)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .changed:
            lastPrecisionFingerLocation = fingerLocation
            if precisionDragging {
                let update = updatePrecisionDrag(rawPoint: point)
                showMagnifier(at: localPoint(for: update.point) ?? targetLocation, near: fingerLocation)
                sendPrecisionDrag(update.point)
                updateDisplayEdgeDwell(for: update.point, delta: update.delta)
            } else {
                showMagnifier(at: targetLocation, near: fingerLocation)
                sendPrecisionMove(point)
                if Self.movedBeyondPrecisionDwell(from: precisionDwellAnchor, to: targetLocation) {
                    schedulePrecisionDragLock(at: targetLocation)
                }
            }
        default: break
        }
    }

    private func schedulePrecisionDragLock(at location: CGPoint) {
        precisionDwellWorkItem?.cancel()
        precisionDwellAnchor = location
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.precisionGestureActive, !self.precisionDragging,
                  let point = self.lastPrecisionPoint else { return }
            self.precisionDragging = true
            self.precisionDragPoint = point
            self.lastPrecisionRawPoint = point
            self.precisionDragScale = CGPoint(x: 1, y: 1)
            self.magnifier.dragLocked = true
            self.magnifier.setNeedsDisplay()
            self.send(.leftMouseDown, point)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        precisionDwellWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.precisionDragDwell, execute: workItem)
    }

    private func cancelPrecisionInteraction() {
        precisionDwellWorkItem?.cancel()
        precisionDwellWorkItem = nil
        displayEdgeWorkItem?.cancel()
        if precisionDragging, let point = precisionDragPoint ?? lastPrecisionPoint { send(.leftMouseUp, point) }
        precisionGestureActive = false
        precisionDragging = false
        precisionDwellAnchor = nil
        resetDisplayEdgeDwell()
        hideMagnifier()
    }

    private func sendPrecisionMove(_ point: CGPoint) {
        guard Self.didMove(from: lastPrecisionPoint, to: point) else { return }
        send(.mouseMove, point)
        lastPrecisionPoint = point
    }

    private func sendPrecisionDrag(_ point: CGPoint) {
        guard Self.didMove(from: lastPrecisionPoint, to: point) else { return }
        send(.leftMouseDragged, point)
        lastPrecisionPoint = point
    }

    private func updatePrecisionDrag(rawPoint: CGPoint) -> (point: CGPoint, delta: CGPoint) {
        guard let previousRawPoint = lastPrecisionRawPoint else {
            lastPrecisionRawPoint = rawPoint
            precisionDragPoint = rawPoint
            return (rawPoint, .zero)
        }
        var delta = CGPoint(
            x: (rawPoint.x - previousRawPoint.x) * precisionDragScale.x,
            y: (rawPoint.y - previousRawPoint.y) * precisionDragScale.y
        )
        let previousDragPoint = precisionDragPoint ?? previousRawPoint
        if let reentryDisplayEdge,
           Self.isAtEdge(previousDragPoint, reentryDisplayEdge, threshold: 0.05),
           Self.movesTowardEdge(delta, reentryDisplayEdge) {
            if reentryDisplayEdge == .left || reentryDisplayEdge == .right {
                precisionDragScale.x *= -1
                delta.x *= -1
            } else {
                precisionDragScale.y *= -1
                delta.y *= -1
            }
        }
        let point = CGPoint(
            x: min(1, max(0, previousDragPoint.x + delta.x)),
            y: min(1, max(0, previousDragPoint.y + delta.y))
        )
        if let reentryDisplayEdge, !Self.isAtEdge(point, reentryDisplayEdge, threshold: 0.05) {
            self.reentryDisplayEdge = nil
        }
        lastPrecisionRawPoint = rawPoint
        precisionDragPoint = point
        return (point, delta)
    }

    private func updateDisplayEdgeDwell(for point: CGPoint, delta: CGPoint) {
        if let blockedDisplayEdge, !Self.isAtEdge(point, blockedDisplayEdge, threshold: 0.05) {
            self.blockedDisplayEdge = nil
        }
        if let pendingDisplayEdge,
           Self.isAtEdge(point, pendingDisplayEdge, threshold: 0.02) {
            return
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
            guard let self, self.precisionDragging, self.pendingDisplayEdge == edge else { return }
            self.pendingDisplayEdge = nil
            self.displayEdgeWorkItem = nil
            guard let transition = self.onCrossDisplayEdge(edge, position) else {
                self.blockedDisplayEdge = edge
                return
            }
            let newPoint = CGPoint(x: transition.x, y: transition.y)
            self.precisionDragPoint = newPoint
            self.lastPrecisionPoint = newPoint
            self.blockedDisplayEdge = nil
            self.reentryDisplayEdge = edge.opposite
            self.send(.leftMouseDragged, newPoint)
            if let finger = self.lastPrecisionFingerLocation,
               let target = self.localPoint(for: newPoint) {
                self.showMagnifier(at: target, near: finger)
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        displayEdgeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayEdgeDwell, execute: workItem)
    }

    private func resetDisplayEdgeDwell() {
        displayEdgeWorkItem?.cancel()
        displayEdgeWorkItem = nil
        pendingDisplayEdge = nil
        blockedDisplayEdge = nil
        reentryDisplayEdge = nil
        precisionDragPoint = nil
        lastPrecisionRawPoint = nil
        lastPrecisionFingerLocation = nil
        precisionDragScale = CGPoint(x: 1, y: 1)
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

    private static func didMove(from previous: CGPoint?, to point: CGPoint) -> Bool {
        guard let previous else { return true }
        let dx = point.x - previous.x
        let dy = point.y - previous.y
        return dx * dx + dy * dy >= 0.000_000_25
    }

    private static func movedBeyondPrecisionDwell(from anchor: CGPoint?, to point: CGPoint) -> Bool {
        guard let anchor else { return true }
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        return dx * dx + dy * dy >= precisionDwellMovement * precisionDwellMovement
    }

    private func precisionTarget(for fingerPoint: CGPoint) -> CGPoint? {
        guard let rect = currentImageRect else { return nil }
        return CGPoint(
            x: rect.minX + Self.edgeReach((fingerPoint.x - rect.minX) / rect.width) * rect.width,
            y: rect.minY + Self.edgeReach((fingerPoint.y - rect.minY) / rect.height) * rect.height
        )
    }

    private static func edgeReach(_ value: CGFloat) -> CGFloat {
        let value = min(1, max(0, value))
        let directStart: CGFloat = 0.18
        let fingerReach: CGFloat = 0.06
        if value >= directStart && value <= 1 - directStart { return value }
        if value > 0.5 { return 1 - edgeReach(1 - value) }
        if value <= fingerReach { return 0 }
        let width = directStart - fingerReach
        let t = (value - fingerReach) / width
        let t2 = t * t
        let t3 = t2 * t
        return directStart * (-2 * t3 + 3 * t2) + width * (t3 - t2)
    }

    @objc private func scroll(_ sender: UIPanGestureRecognizer) {
        guard sender.state == .changed else { return }
        let translation = sender.translation(in: self)
        sender.setTranslation(.zero, in: self)
        let delta = Self.scrollDelta(for: translation, quarterTurns: rotationQuarterTurns)
        sendInput(RemoteInputEvent(
            kind: .scroll,
            flags: RemoteModifier.preciseScroll,
            deltaX: delta.x,
            deltaY: delta.y
        ))
    }

    private static func scrollDelta(for translation: CGPoint, quarterTurns: Int) -> CGPoint {
        let unrotated = switch quarterTurns % 4 {
        case 1: CGPoint(x: -translation.y, y: translation.x)
        case 2: CGPoint(x: -translation.x, y: -translation.y)
        case 3: CGPoint(x: translation.y, y: -translation.x)
        default: translation
        }
        return CGPoint(x: -unrotated.x * 4, y: -unrotated.y * 4)
    }

    private func send(_ kind: RemoteInputEvent.Kind, _ point: CGPoint, clickCount: Int? = nil) {
        onPointerPositionChanged(point)
        sendInput(RemoteInputEvent(kind: kind, x: point.x, y: point.y, clickCount: clickCount))
    }

    private static func isDoubleTap(
        previousTime: TimeInterval,
        previousLocation: CGPoint,
        time: TimeInterval,
        location: CGPoint
    ) -> Bool {
        let dx = location.x - previousLocation.x
        let dy = location.y - previousLocation.y
        return previousTime > 0 && time - previousTime <= 0.4 && dx * dx + dy * dy <= 44 * 44
    }

    private func normalized(_ point: CGPoint) -> CGPoint? {
        guard let content = currentImageRect,
              content.width > 0,
              content.height > 0,
              point.x >= content.minX,
              point.x <= content.maxX,
              point.y >= content.minY,
              point.y <= content.maxY else { return nil }
        return Self.unrotated(CGPoint(
            x: (point.x - content.minX) / content.width,
            y: (point.y - content.minY) / content.height
        ), quarterTurns: rotationQuarterTurns)
    }

    private var baseContentRect: CGRect? {
        guard let displayedImage else { return nil }
        return mobileRemoteContentRect(
            imageSize: CGSize(width: displayedImage.width, height: displayedImage.height),
            in: bounds,
            quarterTurns: rotationQuarterTurns
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

    private func localPoint(for normalizedPoint: CGPoint) -> CGPoint? {
        guard let rect = currentImageRect else { return nil }
        let rotated = switch rotationQuarterTurns % 4 {
        case 1: CGPoint(x: normalizedPoint.y, y: 1 - normalizedPoint.x)
        case 2: CGPoint(x: 1 - normalizedPoint.x, y: 1 - normalizedPoint.y)
        case 3: CGPoint(x: 1 - normalizedPoint.y, y: normalizedPoint.x)
        default: normalizedPoint
        }
        return CGPoint(
            x: rect.minX + rotated.x * rect.width,
            y: rect.minY + rotated.y * rect.height
        )
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

    private func showMagnifier(at point: CGPoint, near fingerPoint: CGPoint) {
        let firstFrame = magnifier.isHidden
        magnifier.sourcePoint = point
        magnifier.center = Self.magnifierCenter(
            near: fingerPoint,
            in: bounds,
            lensSize: magnifier.bounds.size
        )
        magnifier.guideDirection = CGVector(
            dx: point.x - magnifier.center.x,
            dy: point.y - magnifier.center.y
        )
        updateMagnifierGuide(to: point)
        refreshMagnifierSnapshot(force: firstFrame)
        magnifier.isHidden = false
        magnifier.setNeedsDisplay()
    }

    private static func magnifierCenter(near finger: CGPoint, in bounds: CGRect, lensSize: CGSize) -> CGPoint {
        let padding: CGFloat = 8
        let clearance: CGFloat = 36
        let half = CGPoint(x: lensSize.width / 2, y: lensSize.height / 2)
        let minX = bounds.minX + half.x + padding
        let maxX = bounds.maxX - half.x - padding
        let minY = bounds.minY + half.y + padding
        let maxY = bounds.maxY - half.y - padding
        let clamp: (CGPoint) -> CGPoint = { point in
            CGPoint(
                x: min(maxX, max(minX, point.x)),
                y: min(maxY, max(minY, point.y))
            )
        }
        let verticalOffset = half.y + clearance
        if finger.y - verticalOffset >= minY {
            return clamp(CGPoint(x: finger.x, y: finger.y - verticalOffset))
        }
        let horizontalOffset = half.x + clearance
        let side = bounds.midX < finger.x ? -horizontalOffset : horizontalOffset
        if (side > 0 && finger.x + side <= maxX) || (side < 0 && finger.x + side >= minX) {
            return clamp(CGPoint(x: finger.x + side, y: finger.y))
        }
        if finger.y + verticalOffset <= maxY {
            return clamp(CGPoint(x: finger.x, y: finger.y + verticalOffset))
        }
        return clamp(CGPoint(x: finger.x - side, y: finger.y))
    }

    private func configureMagnifierGuide() {
        for shapeLayer in [magnifierGuideOutlineLayer, magnifierGuideLayer, magnifierTargetLayer] {
            shapeLayer.contentsScale = traitCollection.displayScale
            shapeLayer.lineCap = .round
            shapeLayer.lineJoin = .round
            shapeLayer.shadowColor = UIColor.black.cgColor
            shapeLayer.shadowOpacity = 0.65
            shapeLayer.shadowRadius = 1
            shapeLayer.shadowOffset = .zero
            shapeLayer.isHidden = true
            layer.addSublayer(shapeLayer)
        }
        magnifierGuideOutlineLayer.fillColor = UIColor.clear.cgColor
        magnifierGuideOutlineLayer.strokeColor = PrecisionMagnifier.guideOutlineColor.cgColor
        magnifierGuideOutlineLayer.lineCap = .butt
        magnifierGuideOutlineLayer.lineWidth = PrecisionMagnifier.guideOutlineWidth
        magnifierGuideOutlineLayer.lineDashPattern = PrecisionMagnifier.guideDash.map { NSNumber(value: Double($0)) }
        magnifierGuideOutlineLayer.shadowOpacity = 0
        magnifierGuideLayer.fillColor = UIColor.clear.cgColor
        magnifierGuideLayer.strokeColor = PrecisionMagnifier.guideColor.cgColor
        magnifierGuideLayer.lineCap = .butt
        magnifierGuideLayer.lineWidth = PrecisionMagnifier.guideWidth
        magnifierGuideLayer.lineDashPattern = PrecisionMagnifier.guideDash.map { NSNumber(value: Double($0)) }
        magnifierGuideLayer.shadowOpacity = 0
        magnifierTargetLayer.fillColor = PrecisionMagnifier.guideOutlineColor.cgColor
        magnifierTargetLayer.strokeColor = PrecisionMagnifier.accentColor.cgColor
        magnifierTargetLayer.lineWidth = 1.5
        magnifierTargetLayer.shadowOpacity = 0
    }

    private func updateMagnifierGuide(to target: CGPoint) {
        let markerRadius: CGFloat = 4.5
        let markerPath = UIBezierPath(ovalIn: CGRect(
            x: target.x - markerRadius,
            y: target.y - markerRadius,
            width: markerRadius * 2,
            height: markerRadius * 2
        ))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        magnifierTargetLayer.path = markerPath.cgPath
        magnifierTargetLayer.isHidden = false
        if let guide = Self.magnifierGuide(
            from: magnifier.center,
            to: target,
            lensRadius: magnifier.bounds.width / 2,
            markerRadius: markerRadius
        ) {
            let path = UIBezierPath()
            path.move(to: guide.start)
            path.addLine(to: guide.end)
            magnifierGuideOutlineLayer.path = path.cgPath
            magnifierGuideOutlineLayer.isHidden = false
            magnifierGuideLayer.path = path.cgPath
            magnifierGuideLayer.isHidden = false
        } else {
            magnifierGuideOutlineLayer.path = nil
            magnifierGuideOutlineLayer.isHidden = true
            magnifierGuideLayer.path = nil
            magnifierGuideLayer.isHidden = true
        }
        CATransaction.commit()
    }

    private static func magnifierGuide(
        from lensCenter: CGPoint,
        to target: CGPoint,
        lensRadius: CGFloat,
        markerRadius: CGFloat
    ) -> (start: CGPoint, end: CGPoint)? {
        let dx = target.x - lensCenter.x
        let dy = target.y - lensCenter.y
        let distance = hypot(dx, dy)
        let startDistance = max(0, lensRadius - 1)
        guard distance > startDistance + markerRadius else { return nil }
        let unitX = dx / distance
        let unitY = dy / distance
        return (
            CGPoint(x: lensCenter.x + unitX * startDistance, y: lensCenter.y + unitY * startDistance),
            CGPoint(x: target.x - unitX * markerRadius, y: target.y - unitY * markerRadius)
        )
    }

    private func refreshMagnifierSnapshot(force: Bool = false) {
        guard force || !magnifier.isHidden else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastMagnifierRefreshTime >= 1.0 / 60,
              currentImageRect != nil else { return }
        let lensSize = magnifier.bounds.size
        magnifier.crosshairPoint = CGPoint(x: lensSize.width / 2, y: lensSize.height / 2)
        magnifier.snapshot = UIGraphicsImageRenderer(size: lensSize).image { context in
            context.cgContext.translateBy(x: lensSize.width / 2, y: lensSize.height / 2)
            context.cgContext.scaleBy(x: PrecisionMagnifier.magnification, y: PrecisionMagnifier.magnification)
            context.cgContext.translateBy(x: -magnifier.sourcePoint.x, y: -magnifier.sourcePoint.y)
            context.cgContext.translateBy(x: imageLayer.position.x, y: imageLayer.position.y)
            context.cgContext.concatenate(imageLayer.affineTransform())
            context.cgContext.translateBy(x: -imageLayer.bounds.midX, y: -imageLayer.bounds.midY)
            imageLayer.render(in: context.cgContext)
        }
        magnifier.setNeedsDisplay()
        lastMagnifierRefreshTime = now
    }

    private func hideMagnifier() {
        magnifier.isHidden = true
        magnifier.snapshot = nil
        magnifier.guideDirection = .zero
        magnifier.dragLocked = false
        magnifierGuideOutlineLayer.isHidden = true
        magnifierGuideOutlineLayer.path = nil
        magnifierGuideLayer.isHidden = true
        magnifierGuideLayer.path = nil
        magnifierTargetLayer.isHidden = true
        magnifierTargetLayer.path = nil
        lastMagnifierRefreshTime = 0
        lastPrecisionPoint = nil
    }
}

private final class PrecisionMagnifier: UIView {
    static let magnification: CGFloat = 3
    static let guideWidth: CGFloat = 1.75
    static let guideOutlineWidth: CGFloat = 3.5
    static let guideDash: [CGFloat] = [5, 3]
    static let chromeColor = UIColor(red: 0.025, green: 0.07, blue: 0.15, alpha: 0.96)
    static let accentColor = UIColor(red: 0.38, green: 0.88, blue: 1, alpha: 1)
    static let guideOutlineColor = UIColor.white.withAlphaComponent(0.92)
    static let guideColor = accentColor
    var snapshot: UIImage?
    var sourcePoint = CGPoint.zero
    var crosshairPoint = CGPoint(x: 88, y: 88)
    var guideDirection = CGVector.zero
    var dragLocked = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = Self.chromeColor
        layer.cornerRadius = frame.width / 2
        layer.borderWidth = 2
        layer.borderColor = Self.accentColor.cgColor
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ rect: CGRect) {
        guard let snapshot else { return }
        snapshot.draw(in: bounds)

        if let guideEnd = Self.guideEndpoint(
            from: crosshairPoint,
            direction: guideDirection,
            length: max(bounds.width, bounds.height)
        ) {
            let guide = UIBezierPath()
            guide.move(to: crosshairPoint)
            guide.addLine(to: guideEnd)
            guide.setLineDash(Self.guideDash, count: Self.guideDash.count, phase: 0)
            guide.lineCapStyle = .butt
            Self.guideOutlineColor.setStroke()
            guide.lineWidth = Self.guideOutlineWidth
            guide.stroke()
            Self.guideColor.setStroke()
            guide.lineWidth = Self.guideWidth
            guide.stroke()
        }

        if dragLocked {
            let lockRing = UIBezierPath(ovalIn: CGRect(
                x: crosshairPoint.x - 18,
                y: crosshairPoint.y - 18,
                width: 36,
                height: 36
            ))
            Self.accentColor.setStroke()
            lockRing.lineWidth = 2.5
            lockRing.stroke()
        }

        let crosshair = UIBezierPath()
        crosshair.move(to: CGPoint(x: crosshairPoint.x - 12, y: crosshairPoint.y))
        crosshair.addLine(to: CGPoint(x: crosshairPoint.x + 12, y: crosshairPoint.y))
        crosshair.move(to: CGPoint(x: crosshairPoint.x, y: crosshairPoint.y - 12))
        crosshair.addLine(to: CGPoint(x: crosshairPoint.x, y: crosshairPoint.y + 12))
        Self.guideOutlineColor.setStroke()
        crosshair.lineWidth = 5
        crosshair.stroke()
        Self.accentColor.setStroke()
        crosshair.lineWidth = 2.5
        crosshair.stroke()
    }

    static func guideEndpoint(
        from origin: CGPoint,
        direction: CGVector,
        length: CGFloat
    ) -> CGPoint? {
        let magnitude = hypot(direction.dx, direction.dy)
        guard magnitude > 0 else { return nil }
        return CGPoint(
            x: origin.x + direction.dx / magnitude * length,
            y: origin.y + direction.dy / magnitude * length
        )
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
            assert(Self.deleteRepeatCount(streak: 8) == 3)
            assert(Self.deleteRepeatCount(streak: 18) == 6)
            assert(Self.deleteRepeatCount(streak: 30) == 10)
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
            streak >= 30 ? 10 : (streak >= 18 ? 6 : (streak >= 8 ? 3 : 1))
        }
    }
}
