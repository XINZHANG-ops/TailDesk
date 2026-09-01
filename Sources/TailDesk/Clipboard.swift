import Foundation
#if os(macOS)
import AppKit
#endif

enum ClipboardContent: Codable, Equatable {
    case text(String)
    case file(name: String, data: Data)
}

enum ClipboardCodec {
    static let maximumTextSize = 1 * 1024 * 1024
    static let maximumFileSize = 16 * 1024 * 1024

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
        default:
            break
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
            // ponytail: transfer the first regular file only; add batching when real use needs multi-file copy.
            sendFile(first as URL)
        } else if let text = pasteboard.string(forType: .string) {
            send(.text(text))
        }
    }

    private func sendFile(_ url: URL) {
        let send = onSend
        let status = onStatus
        DispatchQueue.global(qos: .utility).async {
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { throw ClipboardError.regularFilesOnly }
                guard (values.fileSize ?? 0) <= ClipboardCodec.maximumFileSize else { throw ClipboardError.fileTooLarge }
                let contents = try Data(contentsOf: url, options: .mappedIfSafe)
                send(try ClipboardCodec.encode(.file(name: url.lastPathComponent, data: contents)))
            } catch {
                status(error.localizedDescription, true)
            }
        }
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
        let fileManager = FileManager.default
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TailDesk/Transfers", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let safeName = URL(fileURLWithPath: name).lastPathComponent
        guard !safeName.isEmpty, safeName != ".", safeName != ".." else { throw ClipboardError.invalidFileName }
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
        try contents.write(to: destination, options: .atomic)
        return destination
    }
}
#endif

enum ClipboardError: LocalizedError {
    case textTooLarge
    case fileTooLarge
    case regularFilesOnly
    case invalidFileName

    var errorDescription: String? {
        switch self {
        case .textTooLarge: "Clipboard text exceeds 1 MB"
        case .fileTooLarge: "Clipboard file exceeds 16 MB"
        case .regularFilesOnly: "Clipboard sync currently supports one regular file, not folders"
        case .invalidFileName: "Clipboard file name is invalid"
        }
    }
}

enum ClipboardSelfCheck {
    static func run() {
        let values: [ClipboardContent] = [
            .text("TailDesk clipboard ✓"),
            .file(name: "example.txt", data: Data("hello".utf8))
        ]
        for value in values {
            precondition(try! ClipboardCodec.decode(ClipboardCodec.encode(value)) == value)
        }
    }
}
