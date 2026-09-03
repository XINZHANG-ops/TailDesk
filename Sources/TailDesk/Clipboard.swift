import Foundation
#if os(macOS)
import AppKit
#endif

enum ClipboardContent: Codable, Equatable {
    case text(String)
    case file(name: String, data: Data)
    case folder(name: String, entries: [ClipboardFolderEntry])
}

struct ClipboardFolderEntry: Codable, Equatable {
    let path: String
    let isDirectory: Bool
    let data: Data?
    let permissions: Int?
}

private enum ClipboardPath {
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 1_024 &&
            URL(fileURLWithPath: name).lastPathComponent == name
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4_096 && !path.hasPrefix("/") &&
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }
}

enum ClipboardCodec {
    static let maximumTextSize = 1 * 1_024 * 1_024
    private static let maximumLegacyFileSize = 16 * 1_024 * 1_024

    static func encode(_ content: ClipboardContent) throws -> Data {
        try validate(content)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(content)
    }

    static func decode(_ data: Data) throws -> ClipboardContent {
        let content = try PropertyListDecoder().decode(ClipboardContent.self, from: data)
        try validate(content)
        return content
    }

    private static func validate(_ content: ClipboardContent) throws {
        switch content {
        case .text(let text) where text.utf8.count > maximumTextSize:
            throw ClipboardError.textTooLarge
        case .file(let name, let data):
            guard ClipboardPath.isSafeName(name) else { throw ClipboardError.invalidFileName }
            guard data.count <= maximumLegacyFileSize else { throw ClipboardError.legacyPayloadTooLarge }
        case .folder(let name, let entries):
            guard ClipboardPath.isSafeName(name) else { throw ClipboardError.invalidFolder }
            var totalSize = 0
            for entry in entries {
                guard ClipboardPath.isSafeRelativePath(entry.path),
                      entry.permissions.map({ 0...0o7777 ~= $0 }) ?? true,
                      entry.isDirectory == (entry.data == nil) else {
                    throw ClipboardError.invalidFolder
                }
                totalSize += entry.data?.count ?? 0
                guard totalSize <= maximumLegacyFileSize else { throw ClipboardError.legacyPayloadTooLarge }
            }
        default:
            break
        }
    }
}

struct ClipboardTransferStart: Codable, Equatable {
    let id: UUID
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let permissions: Int?
    let streamsUnknownSize: Bool?
}

struct ClipboardTransferItem: Codable, Equatable {
    let id: UUID
    let path: String
    let isDirectory: Bool
    let size: UInt64
    let permissions: Int?
}

enum ClipboardTransferPacketKind: UInt8 {
    case start = 1
    case item = 2
    case chunk = 3
    case finish = 4
    case cancel = 5
}

enum ClipboardTransferCodec {
    static let maximumChunkSize = 1 * 1_024 * 1_024
    private static let identifierSize = 36
    private static let packetPrefix = Data([0x54, 0x44, 0x43, 0x02])

    static func packet(_ kind: ClipboardTransferPacketKind, payload: Data) -> Data {
        packetPrefix + Data([kind.rawValue]) + payload
    }

    static func unpack(_ data: Data) -> (ClipboardTransferPacketKind, Data)? {
        guard data.count >= packetPrefix.count + 1,
              data.starts(with: packetPrefix),
              let kind = ClipboardTransferPacketKind(rawValue: data[packetPrefix.count]) else { return nil }
        return (kind, Data(data.dropFirst(packetPrefix.count + 1)))
    }

    static func encodeStart(_ value: ClipboardTransferStart) throws -> Data {
        guard ClipboardPath.isSafeName(value.name), validPermissions(value.permissions),
              value.isDirectory || value.streamsUnknownSize != true else {
            throw ClipboardError.invalidTransfer
        }
        return try JSONEncoder().encode(value)
    }

    static func decodeStart(_ data: Data) throws -> ClipboardTransferStart {
        let value = try JSONDecoder().decode(ClipboardTransferStart.self, from: data)
        _ = try encodeStart(value)
        return value
    }

    static func encodeItem(_ value: ClipboardTransferItem) throws -> Data {
        guard ClipboardPath.isSafeRelativePath(value.path),
              !value.isDirectory || value.size == 0,
              validPermissions(value.permissions) else { throw ClipboardError.invalidTransfer }
        return try JSONEncoder().encode(value)
    }

    static func decodeItem(_ data: Data) throws -> ClipboardTransferItem {
        let value = try JSONDecoder().decode(ClipboardTransferItem.self, from: data)
        _ = try encodeItem(value)
        return value
    }

    static func chunk(id: UUID, data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumChunkSize else { throw ClipboardError.invalidTransfer }
        return Data(id.uuidString.utf8) + data
    }

    static func decodeChunk(_ data: Data) throws -> (UUID, Data) {
        guard data.count > identifierSize,
              data.count <= identifierSize + maximumChunkSize,
              let text = String(data: data.prefix(identifierSize), encoding: .utf8),
              let id = UUID(uuidString: text) else { throw ClipboardError.invalidTransfer }
        return (id, Data(data.dropFirst(identifierSize)))
    }

    static func finish(_ id: UUID) -> Data {
        Data(id.uuidString.utf8)
    }

    static func decodeFinish(_ data: Data) throws -> UUID {
        guard data.count == identifierSize,
              let text = String(data: data, encoding: .utf8),
              let id = UUID(uuidString: text) else { throw ClipboardError.invalidTransfer }
        return id
    }

    private static func validPermissions(_ permissions: Int?) -> Bool {
        permissions.map { 0...0o7777 ~= $0 } ?? true
    }
}

#if os(macOS)
typealias ClipboardWireSender = (Data, @escaping (Bool) -> Void) -> Void

private enum ClipboardReceipt {
    case text(String)
    case file(URL)
}

private final class ClipboardTransferGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var activeID: UUID?

    func begin(_ id: UUID) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        activeID = id
        return generation
    }

    func cancel() {
        lock.lock()
        generation &+= 1
        activeID = nil
        lock.unlock()
    }

    func cancel(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard activeID == id else { return }
        generation &+= 1
        activeID = nil
    }

    func isCurrent(_ value: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == value
    }
}

@MainActor
final class ClipboardSync {
    var onSend: ClipboardWireSender = { _, completion in completion(false) }
    var onStatus: (String, Bool) -> Void = { _, _ in }
    var onProgress: (String, Double?, Bool) -> Void = { _, _, _ in }

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastReceivedFileURL: URL?
    private let sendQueue = DispatchQueue(label: "TailDesk.ClipboardSend", qos: .utility)
    private nonisolated let transferGate = ClipboardTransferGate()
    private nonisolated let receiver = ClipboardTransferReceiver()
    private nonisolated let receiveLock = NSLock()
    private nonisolated(unsafe) var receiveEnabled = false

    func start() {
        pause()
        receiveLock.lock()
        receiveEnabled = true
        receiveLock.unlock()
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func pause() {
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        pause()
        receiveLock.lock()
        receiveEnabled = false
        receiveLock.unlock()
        transferGate.cancel()
        receiver.cancel()
    }

    nonisolated func receive(_ data: Data) {
        let packet = ClipboardTransferCodec.unpack(data)
        if let (kind, payload) = packet, kind == .cancel,
           let id = try? ClipboardTransferCodec.decodeFinish(payload) {
            transferGate.cancel(id)
        }
        receiveLock.lock()
        let enabled = receiveEnabled
        receiveLock.unlock()
        guard enabled else {
            if let (kind, payload) = packet, kind == .start,
               let metadata = try? ClipboardTransferCodec.decodeStart(payload) {
                Task { @MainActor [weak self] in self?.sendCancellation(metadata.id) }
            }
            return
        }
        receiver.receive(data, onComplete: { [weak self] receipt in
            DispatchQueue.main.async {
                switch receipt {
                case .text(let text):
                    self?.putTextOnPasteboard(text)
                case .file(let url):
                    self?.putFileOnPasteboard(url)
                    self?.onProgress(url.lastPathComponent, 1, false)
                    self?.onStatus("Clipboard item ready: \(url.lastPathComponent)", false)
                }
            }
        }, onStatus: { [weak self] message, isError in
            DispatchQueue.main.async { self?.onStatus(message, isError) }
        }, onStart: { [weak self] in
            DispatchQueue.main.async { self?.clearPasteboardForIncomingFile() }
        }, onProgress: { [weak self] name, received, total in
            let progress = total.flatMap { $0 > 0 ? Double(received) / Double($0) : 0 }
            DispatchQueue.main.async { self?.onProgress(name, progress, false) }
        }, onReject: { [weak self] id in
            DispatchQueue.main.async { self?.sendCancellation(id) }
        })
    }

    private func sendCancellation(_ id: UUID) {
        onSend(ClipboardTransferCodec.packet(.cancel, payload: ClipboardTransferCodec.finish(id))) { _ in }
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        if let value = pasteboard.pasteboardItems?.compactMap({ $0.string(forType: .fileURL) }).first,
           let first = URL(string: value), first.isFileURL {
            // ponytail: one top-level clipboard item; folders can contain any number of files.
            sendURL(first)
        } else if let text = pasteboard.string(forType: .string) {
            sendLegacy(.text(text))
        }
    }

    private func sendURL(_ url: URL) {
        let send = onSend
        let status = onStatus
        let progress = onProgress
        let gate = transferGate
        let id = UUID()
        let token = gate.begin(id)
        progress(url.lastPathComponent, nil, true)
        sendQueue.async {
            guard gate.isCurrent(token) else { return }
            do {
                status("Sending clipboard item: \(url.lastPathComponent)", false)
                try ClipboardTransferSender.send(
                    url,
                    id: id,
                    using: send,
                    isCancelled: { !gate.isCurrent(token) },
                    onProgress: { sent, total in
                        progress(url.lastPathComponent, total > 0 ? Double(sent) / Double(total) : nil, true)
                    }
                )
                progress(url.lastPathComponent, 1, true)
                status("Clipboard item sent: \(url.lastPathComponent)", false)
            } catch ClipboardError.transferCancelled {
                return
            } catch ClipboardError.transferDisconnected {
                return
            } catch {
                status(error.localizedDescription, true)
            }
        }
    }

    private func sendLegacy(_ content: ClipboardContent) {
        let send = onSend
        let status = onStatus
        let gate = transferGate
        let token = gate.begin(UUID())
        sendQueue.async {
            guard gate.isCurrent(token) else { return }
            do {
                try ClipboardTransferSender.sendData(ClipboardCodec.encode(content), using: send)
            } catch ClipboardError.transferDisconnected {
                return
            } catch {
                status(error.localizedDescription, true)
            }
        }
    }

    private func putTextOnPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }

    private func putFileOnPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        lastChangeCount = pasteboard.changeCount
        lastReceivedFileURL = url
    }

    @discardableResult
    func restoreLastReceivedFile() -> Bool {
        guard let url = lastReceivedFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return false }
        putFileOnPasteboard(url)
        onStatus("Clipboard item restored: \(url.lastPathComponent)", false)
        return true
    }

    private func clearPasteboardForIncomingFile() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        lastChangeCount = pasteboard.changeCount
        onStatus("Receiving clipboard item; paste will be ready when transfer finishes", false)
    }

    fileprivate nonisolated static func saveReceivedFile(name: String, contents: Data) throws -> URL {
        let destination = try ClipboardStorage.destination(for: name)
        try contents.write(to: destination, options: .atomic)
        return destination
    }

    fileprivate nonisolated static func saveReceivedFolder(name: String, entries: [ClipboardFolderEntry]) throws -> URL {
        let fileManager = FileManager.default
        let destination = try ClipboardStorage.destination(for: name)
        do {
            try restoreFolder(entries, at: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    nonisolated fileprivate static func restoreFolder(_ entries: [ClipboardFolderEntry], at destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var permissions: [(URL, Int)] = []
        for entry in entries {
            let item = destination.appendingPathComponent(entry.path)
            guard item.standardizedFileURL.path.hasPrefix(destination.standardizedFileURL.path + "/") else {
                throw ClipboardError.invalidFolder
            }
            if entry.isDirectory {
                try fileManager.createDirectory(at: item, withIntermediateDirectories: true)
            } else if let data = entry.data {
                try fileManager.createDirectory(at: item.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: item, options: .atomic)
            }
            if let mode = entry.permissions { permissions.append((item, mode)) }
        }
        for (item, mode) in permissions.reversed() {
            try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: item.path)
        }
    }
}

private enum ClipboardTransferSender {
    static func send(
        _ url: URL,
        id: UUID = UUID(),
        using wireSend: @escaping ClipboardWireSender,
        isCancelled: () -> Bool = { false },
        onProgress: (UInt64, UInt64) -> Void = { _, _ in }
    ) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw ClipboardError.unsupportedItem }
        let isDirectory = values.isDirectory == true
        guard isDirectory || values.isRegularFile == true else { throw ClipboardError.unsupportedItem }
        guard !isCancelled() else { throw ClipboardError.transferCancelled }

        let start = ClipboardTransferStart(
            id: id,
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            size: isDirectory ? try folderSize(url, isCancelled: isCancelled) : UInt64(values.fileSize ?? 0),
            permissions: permissions(at: url),
            streamsUnknownSize: nil
        )
        guard !isCancelled() else { throw ClipboardError.transferCancelled }
        try sendPacket(.start, payload: ClipboardTransferCodec.encodeStart(start), using: wireSend)
        var sent: UInt64 = 0
        let didSend: (Int) -> Void = { count in
            sent += UInt64(count)
            onProgress(min(sent, start.size), start.size)
        }
        onProgress(0, start.size)
        do {
            if isDirectory {
                try sendFolder(url, id: id, using: wireSend, isCancelled: isCancelled, didSend: didSend)
            } else {
                try sendFile(url, id: id, using: wireSend, isCancelled: isCancelled, didSend: didSend)
            }
            guard !isCancelled() else { throw ClipboardError.transferCancelled }
            try sendPacket(.finish, payload: ClipboardTransferCodec.finish(id), using: wireSend)
        } catch {
            try? sendPacket(.cancel, payload: ClipboardTransferCodec.finish(id), using: wireSend)
            throw error
        }
    }

    fileprivate static func sendPacket(
        _ kind: ClipboardTransferPacketKind,
        payload: @autoclosure () throws -> Data,
        using wireSend: @escaping ClipboardWireSender
    ) throws {
        try sendData(ClipboardTransferCodec.packet(kind, payload: payload()), using: wireSend)
    }

    fileprivate static func sendData(
        _ data: @autoclosure () throws -> Data,
        using wireSend: @escaping ClipboardWireSender
    ) throws {
        let data = try data()
        let semaphore = DispatchSemaphore(value: 0)
        var succeeded = false
        wireSend(data) {
            succeeded = $0
            semaphore.signal()
        }
        semaphore.wait()
        guard succeeded else { throw ClipboardError.transferDisconnected }
    }

    private static func folderSize(_ url: URL, isCancelled: () -> Bool) throws -> UInt64 {
        var total: UInt64 = 0
        try enumerate(url) { _, _, values in
            guard !isCancelled() else { throw ClipboardError.transferCancelled }
            guard values.isSymbolicLink != true else { throw ClipboardError.unsupportedItem }
            if values.isRegularFile == true {
                let (sum, overflow) = total.addingReportingOverflow(UInt64(values.fileSize ?? 0))
                guard !overflow else { throw ClipboardError.invalidTransfer }
                total = sum
            } else if values.isDirectory != true {
                throw ClipboardError.unsupportedItem
            }
        }
        return total
    }

    private static func sendFolder(
        _ url: URL,
        id: UUID,
        using wireSend: @escaping ClipboardWireSender,
        isCancelled: () -> Bool,
        didSend: (Int) -> Void
    ) throws {
        try enumerate(url) { item, path, values in
            guard !isCancelled() else { throw ClipboardError.transferCancelled }
            guard values.isSymbolicLink != true else { throw ClipboardError.unsupportedItem }
            let isDirectory = values.isDirectory == true
            guard isDirectory || values.isRegularFile == true else { throw ClipboardError.unsupportedItem }
            let metadata = ClipboardTransferItem(
                id: id,
                path: path,
                isDirectory: isDirectory,
                size: isDirectory ? 0 : UInt64(values.fileSize ?? 0),
                permissions: permissions(at: item)
            )
            try sendPacket(.item, payload: ClipboardTransferCodec.encodeItem(metadata), using: wireSend)
            if !isDirectory {
                try sendFile(item, id: id, using: wireSend, isCancelled: isCancelled, didSend: didSend)
            }
        }
    }

    private static func sendFile(
        _ url: URL,
        id: UUID,
        using wireSend: @escaping ClipboardWireSender,
        isCancelled: () -> Bool,
        didSend: (Int) -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            guard !isCancelled() else { throw ClipboardError.transferCancelled }
            let data = try handle.read(upToCount: ClipboardTransferCodec.maximumChunkSize) ?? Data()
            guard !data.isEmpty else { return }
            try sendPacket(.chunk, payload: ClipboardTransferCodec.chunk(id: id, data: data), using: wireSend)
            didSend(data.count)
        }
    }

    private static func enumerate(
        _ root: URL,
        body: (URL, String, URLResourceValues) throws -> Void
    ) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let rootPath = root.standardizedFileURL.path
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { throw ClipboardError.invalidFolder }

        while let item = enumerator.nextObject() as? URL {
            if let enumerationError { throw enumerationError }
            let itemPath = item.standardizedFileURL.path
            guard itemPath.hasPrefix(rootPath + "/") else { throw ClipboardError.invalidFolder }
            let relativePath = String(itemPath.dropFirst(rootPath.count + 1))
            guard ClipboardPath.isSafeRelativePath(relativePath) else { throw ClipboardError.invalidFolder }
            try body(item, relativePath, item.resourceValues(forKeys: keys))
        }
        if let enumerationError { throw enumerationError }
    }

    private static func permissions(at url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }
}

private final class ClipboardTransferReceiver: @unchecked Sendable {
    private final class Incoming {
        let metadata: ClipboardTransferStart
        let stagingURL: URL
        var handle: FileHandle?
        var currentURL: URL?
        var currentRemaining: UInt64
        var currentPermissions: Int?
        var received: UInt64 = 0
        var declared: UInt64
        let expected: UInt64?
        var capacityBudget: UInt64
        var deferredDirectoryPermissions: [(URL, Int)] = []

        init(metadata: ClipboardTransferStart, stagingURL: URL, handle: FileHandle?, capacityBudget: UInt64) {
            self.metadata = metadata
            self.stagingURL = stagingURL
            self.handle = handle
            self.currentURL = metadata.isDirectory ? nil : stagingURL
            self.currentRemaining = metadata.isDirectory ? 0 : metadata.size
            self.currentPermissions = metadata.isDirectory ? nil : metadata.permissions
            self.declared = metadata.isDirectory ? 0 : metadata.size
            self.expected = metadata.streamsUnknownSize == true ? nil : metadata.size
            self.capacityBudget = capacityBudget
        }
    }

    private static let diskReserve: UInt64 = 512 * 1_024 * 1_024
    private let queue = DispatchQueue(label: "TailDesk.ClipboardReceive", qos: .utility)
    private let directory: URL
    private var incoming: Incoming?

    init(directory: URL = ClipboardStorage.defaultDirectory) {
        self.directory = directory
        ClipboardStorage.removeStaleTransfers(in: directory)
    }

    func cancel() {
        queue.async { self.cleanup() }
    }

    func receive(
        _ data: Data,
        onComplete: @escaping (ClipboardReceipt) -> Void,
        onStatus: @escaping (String, Bool) -> Void,
        onStart: @escaping () -> Void = {},
        onProgress: @escaping (String, UInt64, UInt64?) -> Void = { _, _, _ in },
        onReject: @escaping (UUID) -> Void = { _ in }
    ) {
        queue.async {
            var packetID: UUID?
            do {
                guard let (kind, payload) = ClipboardTransferCodec.unpack(data) else {
                    onComplete(try self.receiveLegacy(data))
                    return
                }
                switch kind {
                case .start:
                    let metadata = try ClipboardTransferCodec.decodeStart(payload)
                    packetID = metadata.id
                    try self.start(metadata)
                    onStart()
                    onProgress(
                        metadata.name,
                        0,
                        metadata.streamsUnknownSize == true ? nil : metadata.size
                    )
                    onStatus("Receiving clipboard item: \(metadata.name)", false)
                case .item:
                    let item = try ClipboardTransferCodec.decodeItem(payload)
                    packetID = item.id
                    try self.add(item)
                case .chunk:
                    let (id, data) = try ClipboardTransferCodec.decodeChunk(payload)
                    packetID = id
                    let progress = try self.write(data, id: id)
                    onProgress(progress.name, progress.received, progress.total)
                case .finish:
                    let id = try ClipboardTransferCodec.decodeFinish(payload)
                    packetID = id
                    onComplete(.file(try self.finish(id)))
                case .cancel:
                    let id = try ClipboardTransferCodec.decodeFinish(payload)
                    self.cancel(id)
                }
            } catch {
                self.cleanup()
                if let packetID { onReject(packetID) }
                onStatus(error.localizedDescription, true)
            }
        }
    }

    private func receiveLegacy(_ data: Data) throws -> ClipboardReceipt {
        switch try ClipboardCodec.decode(data) {
        case .text(let text):
            return .text(text)
        case .file(let name, let contents):
            return .file(try ClipboardSync.saveReceivedFile(name: name, contents: contents))
        case .folder(let name, let entries):
            return .file(try ClipboardSync.saveReceivedFolder(name: name, entries: entries))
        }
    }

    private func start(_ metadata: ClipboardTransferStart) throws {
        cleanup()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        guard let capacity, capacity > 0 else { throw ClipboardError.cannotCheckDiskSpace }
        let announcedSize = metadata.streamsUnknownSize == true ? 0 : metadata.size
        let (required, overflow) = announcedSize.addingReportingOverflow(Self.diskReserve)
        guard !overflow, required <= UInt64(capacity) else { throw ClipboardError.insufficientDiskSpace }
        let capacityBudget = UInt64(capacity) - Self.diskReserve

        let staging = directory.appendingPathComponent(".incoming-\(metadata.id.uuidString)")
        guard !fileManager.fileExists(atPath: staging.path) else { throw ClipboardError.invalidTransfer }
        if metadata.isDirectory {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            let transfer = Incoming(
                metadata: metadata,
                stagingURL: staging,
                handle: nil,
                capacityBudget: capacityBudget
            )
            try prepareDirectory(staging, permissions: metadata.permissions, transfer: transfer)
            incoming = transfer
        } else {
            guard fileManager.createFile(atPath: staging.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: staging) else { throw ClipboardError.cannotSaveTransfer }
            incoming = Incoming(
                metadata: metadata,
                stagingURL: staging,
                handle: handle,
                capacityBudget: capacityBudget
            )
        }
    }

    private func add(_ item: ClipboardTransferItem) throws {
        guard let incoming, incoming.metadata.id == item.id, incoming.metadata.isDirectory,
              incoming.currentRemaining == 0 else { throw ClipboardError.invalidTransfer }
        try finishCurrentFile(incoming)

        let url = incoming.stagingURL.appendingPathComponent(item.path)
        guard url.standardizedFileURL.path.hasPrefix(incoming.stagingURL.standardizedFileURL.path + "/"),
              !FileManager.default.fileExists(atPath: url.path) else { throw ClipboardError.invalidTransfer }
        if item.isDirectory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try prepareDirectory(url, permissions: item.permissions, transfer: incoming)
            return
        }

        let (declared, overflow) = incoming.declared.addingReportingOverflow(item.size)
        guard !overflow, incoming.expected.map({ declared <= $0 }) ?? true else {
            throw ClipboardError.invalidTransfer
        }
        guard item.size <= incoming.capacityBudget else { throw ClipboardError.insufficientDiskSpace }
        incoming.declared = declared
        incoming.capacityBudget -= item.size
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { throw ClipboardError.cannotSaveTransfer }
        incoming.handle = handle
        incoming.currentURL = url
        incoming.currentRemaining = item.size
        incoming.currentPermissions = item.permissions
        try finishCurrentFile(incoming)
    }

    private func write(_ data: Data, id: UUID) throws -> (name: String, received: UInt64, total: UInt64?) {
        guard let incoming, incoming.metadata.id == id, let handle = incoming.handle,
              UInt64(data.count) <= incoming.currentRemaining else { throw ClipboardError.invalidTransfer }
        try handle.write(contentsOf: data)
        incoming.currentRemaining -= UInt64(data.count)
        incoming.received += UInt64(data.count)
        try finishCurrentFile(incoming)
        return (incoming.metadata.name, incoming.received, incoming.expected)
    }

    private func finish(_ id: UUID) throws -> URL {
        guard let incoming, incoming.metadata.id == id, incoming.currentRemaining == 0,
              incoming.received == incoming.declared,
              incoming.expected.map({ incoming.received == $0 }) ?? true else {
            throw ClipboardError.invalidTransfer
        }
        try finishCurrentFile(incoming)
        for (url, mode) in incoming.deferredDirectoryPermissions.reversed() {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        let destination = try ClipboardStorage.streamingDestination(
            for: incoming.metadata.name,
            id: id,
            in: directory
        )
        do {
            try FileManager.default.moveItem(at: incoming.stagingURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            throw error
        }
        self.incoming = nil
        return destination
    }

    private func cancel(_ id: UUID) {
        guard incoming?.metadata.id == id else { return }
        cleanup()
    }

    private func finishCurrentFile(_ incoming: Incoming) throws {
        guard incoming.currentRemaining == 0, let handle = incoming.handle, let url = incoming.currentURL else { return }
        try handle.close()
        if let mode = incoming.currentPermissions {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        incoming.handle = nil
        incoming.currentURL = nil
        incoming.currentPermissions = nil
    }

    private func prepareDirectory(_ url: URL, permissions: Int?, transfer: Incoming) throws {
        guard let permissions else { return }
        let workingPermissions = permissions | 0o700
        try FileManager.default.setAttributes([.posixPermissions: workingPermissions], ofItemAtPath: url.path)
        if workingPermissions != permissions {
            transfer.deferredDirectoryPermissions.append((url, permissions))
        }
    }

    private func cleanup() {
        try? incoming?.handle?.close()
        if let stagingURL = incoming?.stagingURL { try? FileManager.default.removeItem(at: stagingURL) }
        incoming = nil
    }
}

private enum ClipboardStorage {
    static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TailDesk/Transfers", isDirectory: true)

    static func destination(for name: String, in directory: URL = defaultDirectory) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard ClipboardPath.isSafeName(name) else { throw ClipboardError.invalidFileName }
        let original = URL(fileURLWithPath: name)
        let fileExtension = original.pathExtension
        let stem = original.deletingPathExtension().lastPathComponent
        var destination = directory.appendingPathComponent(name)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            let candidate = "\(stem) \(suffix)" + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
            destination = directory.appendingPathComponent(candidate)
            suffix += 1
        }
        return destination
    }

    static func streamingDestination(for name: String, id: UUID, in directory: URL) throws -> URL {
        guard ClipboardPath.isSafeName(name) else { throw ClipboardError.invalidFileName }
        let container = directory.appendingPathComponent(".received-\(id.uuidString)", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: container.path) else {
            throw ClipboardError.invalidTransfer
        }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        return container.appendingPathComponent(name)
    }

    static func removeStaleTransfers(in directory: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in urls where url.lastPathComponent.hasPrefix(".incoming-") {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
#endif

enum ClipboardError: LocalizedError {
    case textTooLarge
    case legacyPayloadTooLarge
    case transferCancelled
    case transferDisconnected
    case cannotSaveTransfer
    case cannotCheckDiskSpace
    case insufficientDiskSpace
    case unsupportedItem
    case invalidTransfer
    case invalidFolder
    case invalidFileName

    var errorDescription: String? {
        switch self {
        case .textTooLarge: "Clipboard text exceeds 1 MB"
        case .legacyPayloadTooLarge: "Clipboard data from an older TailDesk version exceeds 16 MB"
        case .transferCancelled: "Clipboard transfer was cancelled"
        case .transferDisconnected: "Clipboard transfer stopped because the remote Mac disconnected"
        case .cannotSaveTransfer: "Clipboard transfer could not be saved"
        case .cannotCheckDiskSpace: "TailDesk could not check available disk space"
        case .insufficientDiskSpace: "The receiving Mac does not have enough free disk space"
        case .unsupportedItem: "Clipboard folders cannot contain symbolic links or special files"
        case .invalidTransfer: "Clipboard transfer data is invalid"
        case .invalidFolder: "Clipboard folder structure is invalid"
        case .invalidFileName: "Clipboard file or folder name is invalid"
        }
    }
}

enum ClipboardSelfCheck {
    static func run() {
        let values: [ClipboardContent] = [
            .text("TailDesk clipboard ✓"),
            .file(name: "example.txt", data: Data("hello".utf8)),
            .folder(name: "example", entries: [
                ClipboardFolderEntry(path: "empty", isDirectory: true, data: nil, permissions: 0o755),
                ClipboardFolderEntry(path: "nested/file.txt", isDirectory: false, data: Data("hello".utf8), permissions: 0o644)
            ])
        ]
        for value in values {
            precondition(try! ClipboardCodec.decode(ClipboardCodec.encode(value)) == value)
        }
        let unsafe = ClipboardContent.folder(name: "example", entries: [
            ClipboardFolderEntry(path: "../escape", isDirectory: false, data: Data(), permissions: 0o644)
        ])
        precondition((try? ClipboardCodec.encode(unsafe)) == nil)

#if os(macOS)
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory.appendingPathComponent("TailDesk-ClipboardSelfCheck-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: testRoot) }
        let source = testRoot.appendingPathComponent("source")
        try! fileManager.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let sourceFile = source.appendingPathComponent("nested/file.txt")
        try! fileManager.createDirectory(at: sourceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourceData = Data(repeating: 0x5a, count: ClipboardTransferCodec.maximumChunkSize + 17)
        try! sourceData.write(to: sourceFile)
        let manyFiles = source.appendingPathComponent("many-files")
        try! fileManager.createDirectory(at: manyFiles, withIntermediateDirectories: true)
        for index in 0..<2_050 {
            precondition(fileManager.createFile(atPath: manyFiles.appendingPathComponent("\(index)").path, contents: nil))
        }

        let receiver = ClipboardTransferReceiver(directory: testRoot.appendingPathComponent("received"))
        let completed = DispatchSemaphore(value: 0)
        var receivedURL: URL?
        var receiveError = false
        var didStart = false
        var sawInitialProgress = false
        var finalReceived: UInt64 = 0
        var reportedTotal: UInt64?
        var sentBytes: UInt64 = 0
        var sentTotal: UInt64 = 0
        try! ClipboardTransferSender.send(source, using: { data, completion in
            precondition(data.count <= ClipboardTransferCodec.maximumChunkSize + 128)
            let messages = try! WireParser().append(WireCodec.frame(.clipboard, payload: data))
            precondition(messages.count == 1 && messages[0].0 == .clipboard)
            receiver.receive(messages[0].1, onComplete: {
                precondition(didStart)
                if case .file(let url) = $0 { receivedURL = url }
                completed.signal()
            }, onStatus: { _, isError in
                if isError {
                    receiveError = true
                    completed.signal()
                }
            }, onStart: {
                precondition(!didStart)
                didStart = true
            }, onProgress: { name, received, total in
                precondition(name == "source")
                if received == 0 { sawInitialProgress = true }
                finalReceived = received
                reportedTotal = total
            })
            completion(true)
        }, onProgress: { sent, total in
            sentBytes = sent
            sentTotal = total
        })
        precondition(completed.wait(timeout: .now() + 5) == .success && !receiveError)
        let restored = receivedURL!
        precondition(restored.lastPathComponent == "source")
        precondition(restored.deletingLastPathComponent().lastPathComponent.hasPrefix(".received-"))
        precondition(sawInitialProgress)
        precondition(finalReceived == UInt64(sourceData.count))
        precondition(reportedTotal == UInt64(sourceData.count))
        precondition(sentBytes == UInt64(sourceData.count) && sentTotal == UInt64(sourceData.count))
        precondition(try! Data(contentsOf: restored.appendingPathComponent("nested/file.txt")) == sourceData)
        var isDirectory: ObjCBool = false
        precondition(fileManager.fileExists(atPath: restored.appendingPathComponent("empty").path, isDirectory: &isDirectory) && isDirectory.boolValue)
        precondition(fileManager.fileExists(atPath: restored.appendingPathComponent("many-files/2049").path))

        let invalidItem = ClipboardTransferItem(
            id: UUID(), path: "../escape", isDirectory: false, size: 0, permissions: 0o644
        )
        precondition((try? ClipboardTransferCodec.encodeItem(invalidItem)) == nil)
#endif
    }
}
