import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ServiceManagement

enum SessionState: Equatable {
    case idle
    case available
    case dialing
    case previewing
    case controlling
    case beingControlled

    var isViewerConnected: Bool { self == .previewing || self == .controlling }
    var allowsOutgoingConnection: Bool { self != .beingControlled }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var macDevices: [TailnetMac] = []
    @Published var selectedDeviceID: String?
    @Published var isRefreshingDevices = false
    @Published var status = "Ready"
    @Published var statusIsError = false
    @Published var isHosting = false
    @Published private(set) var sessionState: SessionState = .idle
    @Published var currentFrame: CGImage?
    @Published private(set) var remoteDisplays: [RemoteDisplay] = []
    @Published private(set) var selectedRemoteDisplayID: UInt32?
    @Published var launchAtLoginWarning: String?
    @Published var phoneImportURL: URL?

    let tailscaleAddress = localTailscaleIPv4() ?? "Not detected"

    private var hostServer: HostServer?
    private var captureSession: ScreenCaptureSession?
    private var viewerClient: ViewerClient?
    private var decoder: H264Decoder?
    private var audioPlayer: RemoteAudioPlayer?
    private var hostClipboardSync: ClipboardSync?
    private var viewerClipboardSync: ClipboardSync?

    var isConnected: Bool { sessionState.isViewerConnected }
    var isConnecting: Bool { sessionState == .dialing }
    var isControlling: Bool { sessionState == .controlling }
    var isBeingControlled: Bool { sessionState == .beingControlled }

    func startAutomatically() {
        configureLaunchAtLogin()
        refreshDevices()
        startHosting()
    }

    func startHosting() {
        guard hostServer == nil else { return }
        let server = HostServer()
        let clipboard = ClipboardSync()
        hostServer = server
        hostClipboardSync = clipboard

        server.onStatus = statusHandler
        server.onYieldToIncoming = { [weak self, weak server] in
            Task { @MainActor in
                guard let self, let server, self.hostServer === server else { return }
                self.disconnectViewer()
                self.setStatus("Simultaneous connection resolved: this Mac will be controlled", isError: false)
            }
        }
        server.onControllerConnected = { [weak self, weak server] connected in
            Task { @MainActor in
                guard let self, let server, self.hostServer === server else { return }
                if connected {
                    self.disconnectViewer()
                    self.sessionState = .beingControlled
                    self.startCapture()
                } else {
                    if self.sessionState == .beingControlled { self.sessionState = .available }
                    self.stopCapture()
                }
            }
        }
        server.onInput = { [weak self, weak server] event in
            if event.kind == .selectDisplay, let displayID = event.displayID {
                Task { @MainActor in
                    guard let self, let capture = self.captureSession else { return }
                    do {
                        try await capture.selectDisplay(displayID)
                        if capture.displayID == displayID, let list = capture.displayList {
                            server?.sendDisplayList(list)
                        }
                    } catch {
                        guard self.captureSession === capture else { return }
                        self.setStatus(error.localizedDescription, isError: true)
                    }
                }
            } else if event.kind == .requestDisplayList {
                Task { @MainActor in
                    for _ in 0..<20 {
                        guard let self, let capture = self.captureSession else { return }
                        if let list = capture.displayList {
                            server?.sendDisplayList(list)
                            return
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            } else if event.kind != .requestKeyFrame {
                InputInjector.post(event)
            } else {
                Task { @MainActor in self?.captureSession?.requestKeyFrame() }
            }
        }
        server.onClipboard = { [weak clipboard] data in
            Task { @MainActor in clipboard?.receive(data) }
        }
        clipboard.onSend = { [weak server] data in server?.sendClipboard(data) }
        clipboard.onStatus = statusHandler

        do {
            try server.start()
            clipboard.start()
            isHosting = true
            if sessionState == .idle { sessionState = .available }
            status = "Available automatically over Tailscale"
            statusIsError = false
        } catch {
            setStatus(error.localizedDescription, isError: true)
            stopHosting()
        }
    }

    func stopHosting() {
        hostClipboardSync?.stop()
        hostClipboardSync = nil
        stopCapture(updateStatus: false)
        hostServer?.stop()
        hostServer = nil
        isHosting = false
        if sessionState == .available || sessionState == .beingControlled { sessionState = .idle }
    }

    @discardableResult
    func connectViewer(to deviceID: String) -> Bool {
        guard sessionState.allowsOutgoingConnection else {
            setStatus("This Mac is being controlled and cannot control another Mac", isError: true)
            return false
        }
        guard let device = macDevices.first(where: { $0.id == deviceID }) else {
            setStatus("Select an online Mac", isError: true)
            return false
        }
        if selectedDeviceID == deviceID, viewerClient != nil { return true }

        disconnectViewer()
        selectedDeviceID = deviceID
        let decoder = H264Decoder()
        let audioPlayer = RemoteAudioPlayer()
        let client = ViewerClient()
        let clipboard = ClipboardSync()
        self.decoder = decoder
        self.audioPlayer = audioPlayer
        viewerClient = client
        viewerClipboardSync = clipboard
        sessionState = .dialing
        remoteDisplays = []
        selectedRemoteDisplayID = nil
        hostServer?.setOutgoingTarget(device.address)

        decoder.onFrame = { [weak self] frame in
            Task { @MainActor in self?.currentFrame = frame }
        }
        client.onStatus = statusHandler
        client.onAuthenticated = { [weak self, weak client] in
            Task { @MainActor in
                guard let self, let client, self.viewerClient === client else { return }
                self.sessionState = .previewing
            }
        }
        client.onConnectionEnded = { [weak self, weak client] message in
            Task { @MainActor in
                guard let self, let client, self.viewerClient === client else { return }
                let wasConnected = self.isConnected
                self.disconnectViewer()
                self.setStatus(
                    message ?? (wasConnected ? "Remote session ended" : "Preview connection ended"),
                    isError: message != nil
                )
            }
        }
        client.onVideoConfiguration = { [weak self, weak decoder] data in
            do {
                try decoder?.configure(data)
            } catch {
                Task { @MainActor in self?.setStatus(error.localizedDescription, isError: true) }
            }
        }
        client.onVideoFrame = { [weak decoder] data in decoder?.decode(data) }
        client.onAudioFrame = { [weak audioPlayer] data in audioPlayer?.enqueue(data) }
        audioPlayer.onError = { [weak self] error in
            Task { @MainActor in self?.setStatus(error.localizedDescription, isError: true) }
        }
        client.onClipboard = { [weak self, weak clipboard] data in
            Task { @MainActor in
                guard let self, self.sessionState == .controlling else { return }
                clipboard?.receive(data)
            }
        }
        client.onDisplayList = { [weak self, weak client] list in
            Task { @MainActor in
                guard let self, let client, self.viewerClient === client else { return }
                self.remoteDisplays = list.displays
                self.selectedRemoteDisplayID = list.selectedDisplayID
            }
        }
        clipboard.onSend = { [weak client] data in client?.sendClipboard(data) }
        clipboard.onStatus = statusHandler
        client.connect(host: device.address)
        status = "Connecting to \(device.name)"
        statusIsError = false
        Task { [weak self, weak client] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, let client,
                  self.viewerClient === client,
                  self.sessionState == .dialing else { return }
            self.disconnectViewer()
            self.setStatus("Preview timed out; TailDesk may be unavailable or busy", isError: true)
        }
        return true
    }

    func refreshDevices() {
        isRefreshingDevices = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try TailscaleCLI.deviceSnapshot() }
            }.value
            isRefreshingDevices = false
            switch result {
            case .success(let snapshot):
                let devices = snapshot.onlineMacs
                macDevices = devices
                phoneImportURL = snapshot.phoneImportURL
                if !devices.contains(where: { $0.id == selectedDeviceID }) {
                    selectedDeviceID = devices.first?.id
                }
                setStatus(devices.isEmpty ? "No other online Macs found" : "Found \(devices.count) online Mac(s)", isError: false)
            case .failure(let error):
                macDevices = []
                phoneImportURL = nil
                selectedDeviceID = nil
                setStatus(error.localizedDescription, isError: true)
            }
        }
    }

    func disconnectViewer() {
        let hadViewerSession = sessionState == .dialing || sessionState.isViewerConnected
        viewerClipboardSync?.stop()
        viewerClipboardSync = nil
        let client = viewerClient
        viewerClient = nil
        client?.onStatus = { _, _ in }
        client?.onConnectionEnded = { _ in }
        client?.cancel()
        hostServer?.setOutgoingTarget(nil)
        decoder = nil
        audioPlayer?.stop()
        audioPlayer = nil
        currentFrame = nil
        remoteDisplays = []
        selectedRemoteDisplayID = nil
        if sessionState == .dialing || sessionState.isViewerConnected {
            sessionState = isHosting ? .available : .idle
        }
        if hadViewerSession { setStatus("Ready", isError: false) }
    }

    func disconnectViewerAndResumeHosting() {
        disconnectViewer()
        startHosting()
    }

    @discardableResult
    func beginControl() -> Bool {
        guard sessionState == .previewing else { return false }
        sessionState = .controlling
        viewerClipboardSync?.start()
        setStatus("Remote control active", isError: false)
        return true
    }

    func endControl() {
        guard sessionState == .controlling else { return }
        viewerClipboardSync?.stop()
        sessionState = .previewing
        setStatus("Live preview · read-only", isError: false)
    }

    func sendInput(_ event: RemoteInputEvent) {
        guard sessionState == .controlling else { return }
        var event = event
        event.displayID = selectedRemoteDisplayID
        viewerClient?.sendInput(event)
    }

    func selectRemoteDisplay(_ displayID: UInt32) {
        guard isConnected, remoteDisplays.contains(where: { $0.id == displayID }),
              selectedRemoteDisplayID != displayID else { return }
        selectedRemoteDisplayID = displayID
        currentFrame = nil
        viewerClient?.sendInput(RemoteInputEvent(kind: .selectDisplay, displayID: displayID))
    }

    func requestScreenPermission() {
        let granted = CGRequestScreenCaptureAccess()
        setStatus(granted ? "Screen recording permission granted" : "Grant Screen Recording in System Settings, then restart TailDesk", isError: !granted)
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        setStatus(granted ? "Control permission granted" : "Grant Accessibility permission in System Settings", isError: !granted)
    }

    func stopAll() {
        stopHosting()
        disconnectViewer()
    }

    private func configureLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .notRegistered || service.status == .notFound {
                try service.register()
            }
            switch service.status {
            case .enabled:
                launchAtLoginWarning = nil
            case .requiresApproval:
                launchAtLoginWarning = "Allow TailDesk in System Settings › General › Login Items to make it available after restart."
            default:
                launchAtLoginWarning = "TailDesk could not confirm launch at login. Keep it enabled in System Settings › General › Login Items."
            }
        } catch {
            launchAtLoginWarning = "Could not enable launch at login: \(error.localizedDescription)"
        }
    }

    private func startCapture() {
        if let captureSession {
            captureSession.requestKeyFrame()
            return
        }
        guard let server = hostServer else { return }

        let capture = ScreenCaptureSession()
        captureSession = capture
        capture.onStatus = statusHandler
        capture.onVideoConfiguration = { [weak server] data in server?.sendVideoConfiguration(data) }
        capture.onVideoFrame = { [weak server] data in server?.sendVideoFrame(data) }
        capture.onAudioFrame = { [weak server] data in server?.sendAudioFrame(data) }

        status = "Starting screen capture"
        statusIsError = false
        Task { [weak self, weak capture] in
            do {
                try await capture?.start()
                guard let self, let capture else { return }
                if self.captureSession !== capture {
                    capture.stop()
                }
            } catch {
                guard let self, let capture, self.captureSession === capture else { return }
                self.stopCapture(updateStatus: false)
                self.setStatus(error.localizedDescription, isError: true)
            }
        }
    }

    private func stopCapture(updateStatus: Bool = true) {
        captureSession?.stop()
        captureSession = nil
        if updateStatus, isHosting {
            status = "Available automatically over Tailscale"
            statusIsError = false
        }
    }

    private var statusHandler: (String, Bool) -> Void {
        { [weak self] message, isError in
            Task { @MainActor in self?.setStatus(message, isError: isError) }
        }
    }

    private func setStatus(_ message: String, isError: Bool) {
        status = message
        statusIsError = isError
    }
}

enum SessionSelfCheck {
    static func run() {
        precondition(!SessionState.beingControlled.allowsOutgoingConnection)
        precondition(SessionState.available.allowsOutgoingConnection)
        precondition(SessionState.previewing.isViewerConnected)
        precondition(SessionState.controlling.isViewerConnected)
        precondition(!SessionState.dialing.isViewerConnected)
    }
}
