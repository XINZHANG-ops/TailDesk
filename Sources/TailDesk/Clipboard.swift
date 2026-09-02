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

enum ClipboardCodec {
    static let maximumTextSize = 1 * 1024 * 1024
    static let maximumFileSize = 16 * 1024 * 1024
    static let maximumFolderItemCount = 2_048

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
        case .file(_, let data) where data.count > maximumFileSize:
            throw ClipboardError.fileTooLarge
        case .folder(let name, let entries):
            guard isSafeName(name), entries.count <= maximumFolderItemCount else {
                throw ClipboardError.invalidFolder
            }
            var totalSize = 0
            for entry in entries {
                guard isSafeRelativePath(entry.path),
                      entry.permissions.map({ 0...0o7777 ~= $0 }) ?? true,
                      entry.isDirectory == (entry.data == nil) else {
                    throw ClipboardError.invalidFolder
                }
                totalSize += entry.data?.count ?? 0
                guard totalSize <= maximumFileSize else { throw ClipboardError.fileTooLarge }
            }
        default:
            break
        }
    }

    private static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && URL(fileURLWithPath: name).lastPathComponent == name
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && path.count <= 4_096 && !path.hasPrefix("/") &&
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }
}

#if os(macOS)
@MainActor
final class ClipboardSync {
    var onSend: (Data) -> Void = { _ in }
    var onStatus: (String, Bool) -> Void = { _, _ in }

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    func start() {
        stop()
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func receive(_ data: Data) {
        let status = onStatus
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                switch try ClipboardCodec.decode(data) {
                case .text(let text):
                    Task { @MainActor in self?.putTextOnPasteboard(text) }
                case .file(let name, let contents):
                    let url = try Self.saveReceivedFile(name: name, contents: contents)
                    Task { @MainActor in
                        self?.putFileOnPasteboard(url)
                        status("Clipboard file ready: \(url.lastPathComponent)", false)
                    }
                case .folder(let name, let entries):
                    let url = try Self.saveReceivedFolder(name: name, entries: entries)
                    Task { @MainActor in
                        self?.putFileOnPasteboard(url)
                        status("Clipboard folder ready: \(url.lastPathComponent)", false)
                    }
                }
            } catch {
                status(error.localizedDescription, true)
            }
        }
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL], let first = urls.first {
            // ponytail: transfer the first file or folder only; add batching when real use needs multi-item copy.
            sendURL(first as URL)
        } else if let text = pasteboard.string(forType: .string) {
            send(.text(text))
        }
    }

    private func sendURL(_ url: URL) {
        let send = onSend
        let status = onStatus
        DispatchQueue.global(qos: .utility).async {
            do {
                send(try ClipboardCodec.encode(Self.content(at: url)))
            } catch {
                status(error.localizedDescription, true)
            }
        }
    }

    nonisolated fileprivate static func content(at url: URL) throws -> ClipboardContent {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw ClipboardError.unsupportedItem }
        if values.isRegularFile == true {
            guard (values.fileSize ?? 0) <= ClipboardCodec.maximumFileSize else { throw ClipboardError.fileTooLarge }
            return .file(name: url.lastPathComponent, data: try Data(contentsOf: url, options: .mappedIfSafe))
        }
        guard values.isDirectory == true else { throw ClipboardError.unsupportedItem }

        let fileManager = FileManager.default
        let rootPath = url.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { throw ClipboardError.invalidFolder }

        var entries: [ClipboardFolderEntry] = []
        var totalSize = 0
        while let item = enumerator.nextObject() as? URL {
            if let enumerationError { throw enumerationError }
            guard entries.count < ClipboardCodec.maximumFolderItemCount else { throw ClipboardError.tooManyItems }
            let itemPath = item.standardizedFileURL.path
            guard itemPath.hasPrefix(rootPath + "/") else { throw ClipboardError.invalidFolder }
            let relativePath = String(itemPath.dropFirst(rootPath.count + 1))
            let itemValues = try item.resourceValues(forKeys: Set(keys))
            guard itemValues.isSymbolicLink != true else { throw ClipboardError.unsupportedItem }
            let permissions = (try? fileManager.attributesOfItem(atPath: itemPath)[.posixPermissions] as? NSNumber)?.intValue

            if itemValues.isDirectory == true {
                entries.append(ClipboardFolderEntry(path: relativePath, isDirectory: true, data: nil, permissions: permissions))
            } else if itemValues.isRegularFile == true {
                totalSize += itemValues.fileSize ?? 0
                guard totalSize <= ClipboardCodec.maximumFileSize else { throw ClipboardError.fileTooLarge }
                let data = try Data(contentsOf: item, options: .mappedIfSafe)
                totalSize += data.count - (itemValues.fileSize ?? 0)
                guard totalSize <= ClipboardCodec.maximumFileSize else { throw ClipboardError.fileTooLarge }
                entries.append(ClipboardFolderEntry(path: relativePath, isDirectory: false, data: data, permissions: permissions))
            } else {
                throw ClipboardError.unsupportedItem
            }
        }
        if let enumerationError { throw enumerationError }
        return .folder(name: url.lastPathComponent, entries: entries)
    }

    private func send(_ content: ClipboardContent) {
        do {
            onSend(try ClipboardCodec.encode(content))
        } catch {
            onStatus(error.localizedDescription, true)
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
    }

    private nonisolated static func saveReceivedFile(name: String, contents: Data) throws -> URL {
        let destination = try receivedDestination(for: name)
        try contents.write(to: destination, options: .atomic)
        return destination
    }

    private nonisolated static func saveReceivedFolder(name: String, entries: [ClipboardFolderEntry]) throws -> URL {
        let fileManager = FileManager.default
        let destination = try receivedDestination(for: name)
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

    private nonisolated static func receivedDestination(for name: String) throws -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TailDesk/Transfers", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let safeName = URL(fileURLWithPath: name).lastPathComponent
        guard !safeName.isEmpty, safeName != ".", safeName != "..", safeName == name else { throw ClipboardError.invalidFileName }
        let original = URL(fileURLWithPath: safeName)
        let fileExtension = original.pathExtension
        let stem = original.deletingPathExtension().lastPathComponent
        var destination = directory.appendingPathComponent(safeName)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            let candidate = "\(stem) \(suffix)" + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
            destination = directory.appendingPathComponent(candidate)
            suffix += 1
        }
        return destination
    }
}
#endif

enum ClipboardError: LocalizedError {
    case textTooLarge
    case fileTooLarge
    case tooManyItems
    case unsupportedItem
    case invalidFolder
    case invalidFileName

    var errorDescription: String? {
        switch self {
        case .textTooLarge: "Clipboard text exceeds 1 MB"
        case .fileTooLarge: "Clipboard transfer exceeds 16 MB"
        case .tooManyItems: "Clipboard folder contains more than 2,048 items"
        case .unsupportedItem: "Clipboard folders cannot contain symbolic links or special files"
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
        try! Data("folder round trip".utf8).write(to: sourceFile)
        let captured = try! ClipboardSync.content(at: source)
        guard case .folder(_, let capturedEntries) = try! ClipboardCodec.decode(ClipboardCodec.encode(captured)) else {
            preconditionFailure("Folder clipboard content did not round-trip")
        }
        let restored = testRoot.appendingPathComponent("restored")
        try! ClipboardSync.restoreFolder(capturedEntries, at: restored)
        precondition(try! Data(contentsOf: restored.appendingPathComponent("nested/file.txt")) == Data("folder round trip".utf8))
        var isDirectory: ObjCBool = false
        precondition(fileManager.fileExists(atPath: restored.appendingPathComponent("empty").path, isDirectory: &isDirectory) && isDirectory.boolValue)
#endif
    }
}
