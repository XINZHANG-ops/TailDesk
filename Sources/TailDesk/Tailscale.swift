import Foundation

struct TailnetMac: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let address: String
}

enum TailscaleCLI {
    static func onlineMacs() throws -> [TailnetMac] {
        try decodeStatus(run(["status", "--json"])).onlineMacs
    }

    static func deviceSnapshot() throws -> (onlineMacs: [TailnetMac], phoneImportURL: URL?) {
        let status = try decodeStatus(run(["status", "--json"]))
        return (status.onlineMacs, TailDeskImport.url(hosts: status.onlineMacNamesIncludingSelf))
    }

    static func selfUserID() throws -> UInt64 {
        try decodeStatus(run(["status", "--json"])).selfNode.userID
    }

    static func userID(for address: String) throws -> UInt64 {
        try JSONDecoder().decode(Whois.self, from: run(["whois", "--json", address])).node.user
    }

    static func selfCheck() {
        let fixture = Data(#"""
        {
          "Self":{"HostName":"Local Mac","DNSName":"local.example.ts.net.","TailscaleIPs":["100.64.0.1"],"OS":"macOS","Online":true,"UserID":7},
          "Peer":{
            "a":{"HostName":"online-mac","DNSName":"online-mac.example.ts.net.","TailscaleIPs":["100.64.0.2"],"OS":"macOS","Online":true,"UserID":7},
            "b":{"HostName":"offline-mac","TailscaleIPs":["100.64.0.3"],"OS":"macOS","Online":false,"UserID":7},
            "c":{"HostName":"windows","TailscaleIPs":["100.64.0.4"],"OS":"windows","Online":true,"UserID":7}
          }
        }
        """#.utf8)
        let devices = try! decodeStatus(fixture).onlineMacs
        precondition(devices == [TailnetMac(id: "100.64.0.2", name: "online-mac", address: "100.64.0.2")])
        precondition(try! decodeStatus(fixture).onlineMacNamesIncludingSelf == ["local.example.ts.net", "online-mac.example.ts.net"])
    }

    private static func run(_ arguments: [String]) throws -> Data {
        guard let executable = executableURL else { throw TailscaleError.notInstalled }
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TAILSCALE_BE_CLI"] = "1"
        process.environment = environment
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TailscaleError.commandFailed(message?.isEmpty == false ? message! : "Tailscale command failed")
        }
        return output
    }

    private static var executableURL: URL? {
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/tailscale",
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    private static func decodeStatus(_ data: Data) throws -> Status {
        try JSONDecoder().decode(Status.self, from: data)
    }
}

private struct Status: Decodable {
    let selfNode: Node
    let peers: [String: Node]?

    enum CodingKeys: String, CodingKey {
        case selfNode = "Self"
        case peers = "Peer"
    }

    var onlineMacs: [TailnetMac] {
        (peers ?? [:]).values.compactMap { peer in
            guard peer.online,
                  peer.os.caseInsensitiveCompare("macOS") == .orderedSame,
                  let address = peer.tailscaleIPs.first(where: isTailscaleIPv4) else { return nil }
            return TailnetMac(id: address, name: peer.hostName, address: address)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var onlineMacNamesIncludingSelf: [String] {
        ([selfNode] + Array((peers ?? [:]).values))
            .filter { $0.online && $0.os.caseInsensitiveCompare("macOS") == .orderedSame }
            .map { ($0.dnsName ?? $0.hostName).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

private struct Node: Decodable {
    let hostName: String
    let dnsName: String?
    let tailscaleIPs: [String]
    let os: String
    let online: Bool
    let userID: UInt64

    enum CodingKeys: String, CodingKey {
        case hostName = "HostName"
        case dnsName = "DNSName"
        case tailscaleIPs = "TailscaleIPs"
        case os = "OS"
        case online = "Online"
        case userID = "UserID"
    }
}

private struct Whois: Decodable {
    let node: WhoisNode

    enum CodingKeys: String, CodingKey { case node = "Node" }
}

private struct WhoisNode: Decodable {
    let user: UInt64

    enum CodingKeys: String, CodingKey { case user = "User" }
}

enum TailscaleError: LocalizedError {
    case notInstalled
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "Tailscale is not installed"
        case .commandFailed(let message): message
        }
    }
}

func isTailscaleIPv4(_ address: String) -> Bool {
    let parts = address.split(separator: ".").compactMap { UInt8($0) }
    return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
}
