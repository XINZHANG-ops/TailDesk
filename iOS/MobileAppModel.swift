import Foundation
import SwiftUI
import UIKit

struct SavedMac: Codable, Hashable, Identifiable {
    let host: String
    var id: String { host }
    var name: String { host.split(separator: ".").first.map(String.init) ?? host }
}

enum MobileSessionPhase: Equatable {
    case idle
    case connecting
    case previewing
    case controlling
    case failed
}

@MainActor
final class MobileAppModel: ObservableObject {
    @Published private(set) var devices: [SavedMac] = []
    @Published private(set) var phase: MobileSessionPhase = .idle
    @Published private(set) var currentFrame: CGImage?
    @Published private(set) var status = "等待连接"
    @Published private(set) var statusIsError = false
    @Published private(set) var receivedFileURL: URL?

    private let storageKey = "TailDesk.savedMacs"
    private var client: ViewerClient?
    private var decoder: H264Decoder?
    private var audioPlayer: RemoteAudioPlayer?
    private var timeoutTask: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([SavedMac].self, from: data) {
            devices = saved
        }
    }

    @discardableResult
    func importDevices(from url: URL) -> Int {
        let imported = TailDeskImport.hosts(from: url).map { SavedMac(host: $0) }
        guard !imported.isEmpty else {
            setStatus("这个二维码不是 TailDesk 设备列表", isError: true)
            return 0
        }
        devices = Array(Set(devices + imported)).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persistDevices()
        setStatus("已导入 \(imported.count) 台 Mac", isError: false)
        return imported.count
    }

    func removeDevices(at offsets: IndexSet) {
        devices.remove(atOffsets: offsets)
        persistDevices()
    }

    func connect(to device: SavedMac) {
        disconnect()
        let decoder = H264Decoder()
        let audioPlayer = RemoteAudioPlayer()
        let client = ViewerClient()
        self.decoder = decoder
        self.audioPlayer = audioPlayer
        self.client = client
        phase = .connecting
        currentFrame = nil
        receivedFileURL = nil
        setStatus("正在连接 \(device.name)", isError: false)

        decoder.onFrame = { [weak self] frame in
            Task { @MainActor in self?.currentFrame = frame }
        }
        client.onStatus = { [weak self] message, isError in
            Task { @MainActor in self?.setStatus(message, isError: isError) }
        }
        client.onAuthenticated = { [weak self, weak client] in
            Task { @MainActor in
                guard let self, let client, self.client === client else { return }
                self.timeoutTask?.cancel()
                self.phase = .previewing
                self.setStatus("预览已连接", isError: false)
            }
        }
        client.onConnectionEnded = { [weak self, weak client] message in
            Task { @MainActor in
                guard let self, let client, self.client === client else { return }
                self.timeoutTask?.cancel()
                self.client = nil
                self.decoder = nil
                self.audioPlayer?.stop()
                self.audioPlayer = nil
                self.currentFrame = nil
                self.phase = .failed
                self.setStatus(message ?? "远程连接已结束", isError: true)
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
        client.onClipboard = { [weak self] data in
            Task { @MainActor in self?.receiveClipboard(data) }
        }
        client.connect(host: device.host)

        timeoutTask = Task { [weak self, weak client] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, let client, self.client === client, self.phase == .connecting else { return }
            self.disconnect(endingIn: .failed)
            self.setStatus("连接超时；确认 iPhone 的 Tailscale 已连接，并且 Mac 上的 TailDesk 正在运行", isError: true)
        }
    }

    func beginControl() {
        guard phase == .previewing, currentFrame != nil else { return }
        phase = .controlling
        setStatus("远程控制中", isError: false)
    }

    func disconnect() {
        disconnect(endingIn: .idle)
        setStatus("等待连接", isError: false)
    }

    func sendInput(_ event: RemoteInputEvent) {
        guard phase == .controlling else { return }
        client?.sendInput(event)
    }

    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        sendInput(RemoteInputEvent(kind: .text, text: text))
    }

    func sendKey(_ keyCode: UInt16) {
        sendInput(RemoteInputEvent(kind: .keyDown, keyCode: keyCode))
        sendInput(RemoteInputEvent(kind: .keyUp, keyCode: keyCode))
    }

    func sendPhoneClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            setStatus("iPhone 剪贴板里没有文本", isError: true)
            return
        }
        sendClipboard(.text(text))
    }

    private func sendClipboard(_ content: ClipboardContent) {
        do {
            client?.sendClipboard(try ClipboardCodec.encode(content))
            setStatus("已发送到远端剪贴板", isError: false)
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func receiveClipboard(_ data: Data) {
        do {
            switch try ClipboardCodec.decode(data) {
            case .text(let text):
                UIPasteboard.general.string = text
                setStatus("远端文本已放入 iPhone 剪贴板", isError: false)
            case .file(let name, let contents):
                receivedFileURL = try saveReceivedFile(name: name, contents: contents)
                setStatus("已收到文件 \(name)", isError: false)
            }
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func saveReceivedFile(name: String, contents: Data) throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TailDesk Transfers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = URL(fileURLWithPath: name).lastPathComponent
        guard !safeName.isEmpty, safeName != ".", safeName != ".." else { throw ClipboardError.invalidFileName }
        var destination = directory.appendingPathComponent(safeName)
        let original = destination
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let stem = original.deletingPathExtension().lastPathComponent
            let ext = original.pathExtension
            destination = directory.appendingPathComponent("\(stem) \(suffix)" + (ext.isEmpty ? "" : ".\(ext)"))
            suffix += 1
        }
        try contents.write(to: destination, options: .atomic)
        return destination
    }

    private func disconnect(endingIn phase: MobileSessionPhase) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let oldClient = client
        client = nil
        oldClient?.onStatus = { _, _ in }
        oldClient?.onConnectionEnded = { _ in }
        oldClient?.cancel()
        decoder = nil
        audioPlayer?.stop()
        audioPlayer = nil
        currentFrame = nil
        self.phase = phase
    }

    private func persistDevices() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func setStatus(_ message: String, isError: Bool) {
        status = message
        statusIsError = isError
    }
}
