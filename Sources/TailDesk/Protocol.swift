import Foundation

enum WireMessage: UInt8 {
    case authenticationResult = 2
    case videoConfiguration = 3
    case videoFrame = 4
    case input = 5
    case clipboard = 6
    case audioFrame = 7
}

enum SessionResult: UInt8 {
    case accepted = 1
    case identityRejected = 2
    case busy = 3
    case simultaneousConflict = 4
}

enum WireProtocolError: LocalizedError {
    case invalidMessage
    case messageTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidMessage: "Invalid protocol message"
        case .messageTooLarge: "Protocol message is too large"
        }
    }
}

enum WireCodec {
    static let maximumPayloadSize = 32 * 1024 * 1024

    static func frame(_ type: WireMessage, payload: Data = Data()) -> Data {
        var result = Data([type.rawValue])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(payload)
        return result
    }
}

final class WireParser {
    private var buffer = Data()

    func append(_ data: Data) throws -> [(WireMessage, Data)] {
        buffer.append(data)
        var messages: [(WireMessage, Data)] = []

        while buffer.count >= 5 {
            guard let type = WireMessage(rawValue: buffer[buffer.startIndex]) else {
                throw WireProtocolError.invalidMessage
            }
            let length = buffer.dropFirst().prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length <= WireCodec.maximumPayloadSize else {
                throw WireProtocolError.messageTooLarge
            }
            guard buffer.count >= 5 + length else { break }

            let payload = Data(buffer.dropFirst(5).prefix(length))
            buffer.removeFirst(5 + length)
            messages.append((type, payload))
        }
        return messages
    }
}

struct RemoteInputEvent: Codable {
    enum Kind: String, Codable {
        case mouseMove
        case leftMouseDown
        case leftMouseUp
        case leftMouseDragged
        case rightMouseDown
        case rightMouseUp
        case rightMouseDragged
        case scroll
        case keyDown
        case keyUp
        case text
    }

    var kind: Kind
    var x: Double = 0
    var y: Double = 0
    var keyCode: UInt16 = 0
    var flags: UInt8 = 0
    var deltaX: Double = 0
    var deltaY: Double = 0
    var text: String?
    var clickCount: Int?
}

enum RemoteModifier {
    static let shift: UInt8 = 1 << 0
    static let control: UInt8 = 1 << 1
    static let option: UInt8 = 1 << 2
    static let command: UInt8 = 1 << 3
    static let capsLock: UInt8 = 1 << 4
    static let preciseScroll: UInt8 = 1 << 7
}

enum TailDeskImport {
    static func url(hosts: [String]) -> URL? {
        let hosts = normalized(hosts)
        guard !hosts.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "taildesk"
        components.host = "import"
        components.queryItems = hosts.map { URLQueryItem(name: "host", value: $0) }
        return components.url
    }

    static func hosts(from url: URL) -> [String] {
        guard url.scheme?.lowercased() == "taildesk", url.host?.lowercased() == "import" else { return [] }
        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .filter { $0.name == "host" }
            .compactMap(\.value) ?? []
        return normalized(values)
    }

    private static func normalized(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        return hosts.compactMap { raw in
            var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if host.hasSuffix(".") { host.removeLast() }
            guard isValid(host), seen.insert(host).inserted else { return nil }
            return host
        }
    }

    private static func isValid(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253,
              host.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.").inverted) == nil else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-"
        }
    }
}

enum ProtocolSelfCheck {
    static func run() {
        let payload = Data((0..<255).map(UInt8.init))
        let framed = WireCodec.frame(.videoFrame, payload: payload)
        let parser = WireParser()
        var messages: [(WireMessage, Data)] = []
        for byte in framed {
            messages.append(contentsOf: try! parser.append(Data([byte])))
        }
        precondition(messages.count == 1)
        precondition(messages[0].0 == .videoFrame)
        precondition(messages[0].1 == payload)

        let backToBack = WireCodec.frame(.authenticationResult, payload: Data([1])) + framed
        let pair = try! WireParser().append(backToBack)
        precondition(pair.count == 2)
        precondition(pair[0].0 == .authenticationResult)
        precondition(pair[1].0 == .videoFrame && pair[1].1 == payload)
        precondition(SessionResult(rawValue: 1) == .accepted)
        precondition(SessionResult(rawValue: 4) == .simultaneousConflict)

        let importURL = TailDeskImport.url(hosts: ["Mac-One", " mac-two ", "mac-one"])!
        precondition(TailDeskImport.hosts(from: importURL) == ["mac-one", "mac-two"])
        precondition(TailDeskImport.hosts(from: URL(string: "taildesk://import?host=not%20valid")!).isEmpty)

        let textEvent = RemoteInputEvent(kind: .text, text: "中文 input")
        let decodedEvent = try! JSONDecoder().decode(RemoteInputEvent.self, from: JSONEncoder().encode(textEvent))
        precondition(decodedEvent.kind == .text && decodedEvent.text == "中文 input")
        let doubleClick = RemoteInputEvent(kind: .leftMouseDown, clickCount: 2)
        let decodedClick = try! JSONDecoder().decode(RemoteInputEvent.self, from: JSONEncoder().encode(doubleClick))
        precondition(decodedClick.clickCount == 2)
        precondition(WireMessage(rawValue: 7) == .audioFrame)
    }
}
