import Foundation
import Network
import Darwin

private let tailDeskPort = NWEndpoint.Port(rawValue: 47_821)!

private func tailDeskTCPParameters() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: nil, tcp: tcp)
    parameters.serviceClass = .interactiveVideo
    return parameters
}

#if os(macOS)
final class HostServer {
    var onStatus: (String, Bool) -> Void = { _, _ in }
    var onControllerConnected: (Bool) -> Void = { _ in }
    var onYieldToIncoming: () -> Void = {}
    var onInput: (RemoteInputEvent) -> Void = { _ in }
    var onClipboard: (Data) -> Void = { _ in }

    private let queue = DispatchQueue(label: "TailDesk.HostServer")
    private var listener: NWListener?
    private var peer: HostPeer?
    private var ownerUserID: UInt64?
    private var outgoingTarget: String?

    func start() throws {
        ownerUserID = try TailscaleCLI.selfUserID()
        let listener = try NWListener(using: tailDeskTCPParameters(), on: tailDeskPort)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, self.listener === listener else { return }
            switch state {
            case .ready:
                self.onStatus("Available on Tailscale port \(tailDeskPort.rawValue)", false)
            case .failed(let error):
                self.onStatus("Host failed: \(error.localizedDescription)", true)
                self.stop()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        outgoingTarget = nil
        let peer = peer
        self.peer = nil
        peer?.cancel()
        let listener = listener
        self.listener = nil
        listener?.cancel()
    }

    func setOutgoingTarget(_ address: String?) {
        queue.sync { outgoingTarget = address }
    }

    func sendVideoConfiguration(_ data: Data) {
        peer?.send(.videoConfiguration, payload: data)
    }

    func sendVideoFrame(_ data: Data) {
        peer?.send(.videoFrame, payload: data)
    }

    func sendAudioFrame(_ data: Data) {
        peer?.send(.audioFrame, payload: data)
    }

    func sendClipboard(_ data: Data) {
        peer?.send(.clipboard, payload: data)
    }

    private func accept(_ connection: NWConnection) {
        guard let address = tailscaleAddress(connection.endpoint) else {
            onStatus("Rejected a non-Tailscale connection", true)
            reject(connection, with: .identityRejected)
            return
        }
        guard let ownerUserID,
              (try? TailscaleCLI.userID(for: address)) == ownerUserID else {
            onStatus("Rejected a Tailscale device owned by another user", true)
            reject(connection, with: .identityRejected)
            return
        }

        guard peer == nil else {
            reject(connection, with: .busy)
            return
        }
        if let outgoingTarget {
            guard outgoingTarget == address,
                  shouldYieldSimultaneousDial(local: localTailscaleIPv4(), remote: address) else {
                reject(connection, with: .simultaneousConflict)
                return
            }
            self.outgoingTarget = nil
            onYieldToIncoming()
        }

        let peer = HostPeer(connection: connection)
        self.peer = peer
        peer.onStatus = { [weak self, weak peer] message, isError in
            guard let self, let peer, self.peer === peer else { return }
            self.onStatus(message, isError)
        }
        peer.onControllerConnected = { [weak self, weak peer] connected in
            guard let self, let peer, self.peer === peer else { return }
            if !connected { self.peer = nil }
            self.onControllerConnected(connected)
        }
        peer.onInput = onInput
        peer.onClipboard = onClipboard
        peer.start(on: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak peer] in
            guard let self, let peer, self.peer === peer, !peer.isAuthenticated else { return }
            peer.cancel()
        }
    }

    private func reject(_ connection: NWConnection, with result: SessionResult) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(
                    content: WireCodec.frame(.authenticationResult, payload: Data([result.rawValue])),
                    completion: .contentProcessed { _ in
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                    }
                )
            case .failed, .cancelled:
                connection.stateUpdateHandler = nil
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}

private final class HostPeer {
    var onStatus: (String, Bool) -> Void = { _, _ in }
    var onControllerConnected: (Bool) -> Void = { _ in }
    var onInput: (RemoteInputEvent) -> Void = { _ in }
    var onClipboard: (Data) -> Void = { _ in }

    private let connection: NWConnection
    private let parser = WireParser()
    private var authenticated = false
    private var ended = false

    var isAuthenticated: Bool { authenticated }

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let self, !ended else { return }
                authenticated = true
                connection.send(content: WireCodec.frame(.authenticationResult, payload: Data([SessionResult.accepted.rawValue])), completion: .contentProcessed { _ in })
                onStatus("Controller authenticated by Tailscale", false)
                onControllerConnected(true)
            case .failed(let error):
                self?.onStatus("Controller connection: \(error.localizedDescription)", true)
                self?.reportDisconnected()
            case .waiting(let error):
                self?.onStatus("Controller connection waiting: \(error.localizedDescription)", true)
            case .cancelled:
                self?.onStatus("Controller disconnected", false)
                self?.reportDisconnected()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() {
        connection.cancel()
    }

    private func reportDisconnected() {
        guard !ended else { return }
        ended = true
        authenticated = false
        onControllerConnected(false)
    }

    func send(_ type: WireMessage, payload: Data) {
        guard authenticated else { return }
        connection.send(content: WireCodec.frame(type, payload: payload), completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for message in try parser.append(data) {
                        handle(message)
                    }
                } catch {
                    onStatus(error.localizedDescription, true)
                    cancel()
                    return
                }
            }
            if let error {
                onStatus(error.localizedDescription, true)
                cancel()
            } else if complete {
                cancel()
            } else {
                receive()
            }
        }
    }

    private func handle(_ message: (WireMessage, Data)) {
        guard authenticated else { return }
        switch message.0 {
        case .input:
            guard let event = try? JSONDecoder().decode(RemoteInputEvent.self, from: message.1) else { return }
            onInput(event)
        case .clipboard:
            onClipboard(message.1)
        default:
            break
        }
    }
}
#endif

final class ViewerClient {
    var onStatus: (String, Bool) -> Void = { _, _ in }
    var onAuthenticated: () -> Void = {}
    var onConnectionEnded: (String?) -> Void = { _ in }
    var onVideoConfiguration: (Data) -> Void = { _ in }
    var onVideoFrame: (Data) -> Void = { _ in }
    var onAudioFrame: (Data) -> Void = { _ in }
    var onClipboard: (Data) -> Void = { _ in }

    private let queue = DispatchQueue(label: "TailDesk.ViewerClient")
    private let parser = WireParser()
    private var connection: NWConnection?
    private(set) var authenticated = false
    private var reportedConnectionEnd = false

    func connect(host: String) {
        cancel()
        reportedConnectionEnd = false
        guard let port = NWEndpoint.Port(rawValue: tailDeskPort.rawValue) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: tailDeskTCPParameters())
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onStatus("Connected; verifying Tailscale identity", false)
            case .failed(let error):
                let message = "Connection failed: \(error.localizedDescription)"
                self?.onStatus(message, true)
                self?.reportConnectionEnd(message)
            case .waiting(let error):
                self?.onStatus("Connection waiting: \(error.localizedDescription)", true)
            case .cancelled:
                self?.onStatus("Disconnected", false)
                self?.reportConnectionEnd(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() {
        authenticated = false
        connection?.cancel()
        connection = nil
    }

    private func reportConnectionEnd(_ message: String?) {
        guard !reportedConnectionEnd else { return }
        reportedConnectionEnd = true
        authenticated = false
        onConnectionEnded(message)
    }

    func sendInput(_ event: RemoteInputEvent) {
        guard authenticated, let data = try? JSONEncoder().encode(event) else { return }
        send(.input, payload: data)
    }

    func sendClipboard(_ data: Data) {
        guard authenticated else { return }
        send(.clipboard, payload: data)
    }

    private func send(_ type: WireMessage, payload: Data) {
        connection?.send(content: WireCodec.frame(type, payload: payload), completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for message in try parser.append(data) {
                        handle(message)
                    }
                } catch {
                    onStatus(error.localizedDescription, true)
                    reportConnectionEnd(error.localizedDescription)
                    cancel()
                    return
                }
            }
            if let error {
                onStatus(error.localizedDescription, true)
                reportConnectionEnd(error.localizedDescription)
                cancel()
            } else if complete {
                cancel()
            } else {
                receive()
            }
        }
    }

    private func handle(_ message: (WireMessage, Data)) {
        switch message.0 {
        case .authenticationResult:
            switch message.1.first.flatMap(SessionResult.init(rawValue:)) {
            case .accepted:
                authenticated = true
                onStatus("Connected and authenticated", false)
                onAuthenticated()
            case .identityRejected:
                finishRejected("Tailscale identity rejected")
            case .busy:
                finishRejected("That Mac is already being controlled")
            case .simultaneousConflict:
                finishRejected("Simultaneous connection resolved on the other Mac")
            case nil:
                finishRejected("Unsupported TailDesk session response")
            }
        case .videoConfiguration where authenticated:
            onVideoConfiguration(message.1)
        case .videoFrame where authenticated:
            onVideoFrame(message.1)
        case .audioFrame where authenticated:
            onAudioFrame(message.1)
        case .clipboard where authenticated:
            onClipboard(message.1)
        default:
            break
        }
    }

    private func finishRejected(_ message: String) {
        onStatus(message, true)
        reportConnectionEnd(message)
        cancel()
    }
}

#if os(macOS)
private func shouldYieldSimultaneousDial(local: String?, remote: String) -> Bool {
    guard let local = local.flatMap(tailscaleIPv4Number),
          let remote = tailscaleIPv4Number(remote) else { return false }
    return local < remote
}

private func tailscaleIPv4Number(_ address: String) -> UInt32? {
    let parts = address.split(separator: ".").compactMap { UInt8($0) }
    guard parts.count == 4 else { return nil }
    return parts.reduce(0) { ($0 << 8) | UInt32($1) }
}

enum NetworkingSelfCheck {
    static func run() {
        precondition(shouldYieldSimultaneousDial(local: "100.64.0.1", remote: "100.64.0.2"))
        precondition(!shouldYieldSimultaneousDial(local: "100.64.0.2", remote: "100.64.0.1"))
        precondition(!shouldYieldSimultaneousDial(local: nil, remote: "100.64.0.1"))
    }
}

private func tailscaleAddress(_ endpoint: NWEndpoint) -> String? {
    guard case .hostPort(let host, _) = endpoint else { return nil }
    let address = String(describing: host)
    return isTailscaleIPv4(address) ? address : nil
}

func localTailscaleIPv4() -> String? {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
    defer { freeifaddrs(interfaces) }

    for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let address = interface.pointee.ifa_addr,
              address.pointee.sa_family == UInt8(AF_INET) else { continue }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &buffer,
            socklen_t(buffer.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { continue }
        let value = String(cString: buffer)
        if isTailscaleIPv4(value) { return value }
    }
    return nil
}
#endif
