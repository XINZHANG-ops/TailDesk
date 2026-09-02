import AVFoundation
import Speech
import SwiftUI
import VisionKit

@main
struct TailDeskMobileApp: App {
    @StateObject private var model = MobileAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MobileRootView(model: model)
                .onOpenURL { _ = model.importDevices(from: $0) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.disconnect() }
                }
        }
    }
}

private struct MobileRootView: View {
    @ObservedObject var model: MobileAppModel
    @State private var selectedDevice: SavedMac?
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            List {
                Section("Mac 设备") {
                    ForEach(model.devices) { device in
                        Button {
                            selectedDevice = device
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.name)
                                    Text(device.host)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "laptopcomputer")
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete(perform: model.removeDevices)
                }

                Section("添加设备") {
                    Label("在 Mac TailDesk 中打开“连接 iPhone”", systemImage: "macbook")
                    Button {
                        scanning = true
                    } label: {
                        Label("扫描 Mac 二维码", systemImage: "qrcode.viewfinder")
                    }
                }

                Section {
                    Label(model.status, systemImage: model.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.statusIsError ? .red : .secondary)
                }
            }
            .navigationTitle("TailDesk")
            .overlay {
                if model.devices.isEmpty {
                    ContentUnavailableView(
                        "还没有 Mac",
                        systemImage: "qrcode",
                        description: Text("先扫描 Mac 上的 TailDesk 二维码；不需要输入 IP 或配对密钥。")
                    )
                    .background(.background)
                }
            }
        }
        .fullScreenCover(item: $selectedDevice) { device in
            RemoteSessionView(model: model, device: device)
        }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScannerView(isPresented: $scanning) { url in
                        _ = model.importDevices(from: url)
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("扫描 Mac 二维码")
                    .navigationBarTitleDisplayMode(.inline)
                } else {
                    ContentUnavailableView(
                        "无法使用相机扫描",
                        systemImage: "camera.fill",
                        description: Text("可以改用系统相机扫描 Mac 上的二维码。")
                    )
                }
            }
        }
    }
}

private struct QRScannerView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onURL: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, onURL: onURL)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .fast,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var isPresented: Binding<Bool>
        let onURL: (URL) -> Void

        init(isPresented: Binding<Bool>, onURL: @escaping (URL) -> Void) {
            self.isPresented = isPresented
            self.onURL = onURL
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let value = barcode.payloadStringValue,
                      let url = URL(string: value),
                      !TailDeskImport.hosts(from: url).isEmpty else { continue }
                dataScanner.stopScanning()
                onURL(url)
                isPresented.wrappedValue = false
                return
            }
        }
    }
}

private struct RemoteSessionView: View {
    @ObservedObject var model: MobileAppModel
    let device: SavedMac
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage("TailDesk.dictationLocale") private var dictationLocale = "zh-CN"
    @StateObject private var dictation = VoiceDictation()
    @State private var keyboardActive = false
    @State private var rotationQuarterTurns = 0
    @State private var compactMenuVisible = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MobileRemoteDesktopView(
                frame: model.currentFrame,
                isInteractive: model.phase == .controlling,
                rotationQuarterTurns: rotationQuarterTurns,
                sendInput: model.sendInput
            )
            .ignoresSafeArea()

            if model.phase == .connecting || model.currentFrame == nil {
                statusPanel
            } else if model.phase == .previewing {
                Button {
                    model.beginControl()
                } label: {
                    Label("点按进入控制", systemImage: "hand.tap.fill")
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
            }

            VStack {
                if model.phase == .controlling && usesCompactControls {
                    HStack {
                        if rotationQuarterTurns == 0 {
                            compactControlMenu
                            Spacer()
                        } else {
                            Spacer()
                            compactControlMenu
                        }
                    }
                    .padding(8)
                } else {
                    controlBar
                }
                Spacer()
                if model.phase == .controlling && !usesCompactControls {
                    Text("单指移动 · 点按左键 · 长按精确点击 · 双指点按右键 · 双指滚动")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(8)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(.bottom, 8)
                }
            }

            RemoteKeyboardCapture(active: $keyboardActive, sendText: model.sendText, sendKey: model.sendKey)
                .frame(width: 1, height: 1)
                .opacity(0.01)

            if compactMenuVisible && model.phase == .controlling && usesCompactControls {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { compactMenuVisible = false }

                compactMenuPanel
                    .rotationEffect(.degrees(-Double(rotationQuarterTurns) * 90))
            }

            if dictation.isRecording {
                dictationBanner
            }
        }
        .statusBarHidden(model.phase == .controlling)
        .persistentSystemOverlays(model.phase == .controlling ? .hidden : .automatic)
        .onAppear { model.connect(to: device) }
        .onDisappear {
            dictation.cancel()
            model.disconnect()
        }
        .onChange(of: model.phase) { _, phase in
            if phase != .controlling {
                dictation.cancel()
                compactMenuVisible = false
            }
        }
        .alert("语音输入", isPresented: Binding(
            get: { dictation.errorMessage != nil },
            set: { if !$0 { dictation.errorMessage = nil } }
        )) {
            Button("好") {}
        } message: {
            Text(dictation.errorMessage ?? "")
        }
    }

    private var compactControlMenu: some View {
        Button {
            if dictation.isRecording {
                toggleDictation()
            } else {
                compactMenuVisible.toggle()
            }
        } label: {
            Image(systemName: dictation.isRecording ? "stop.fill" : "ellipsis")
                .font(.headline)
                .frame(width: 38, height: 38)
                .background(dictation.isRecording ? .red.opacity(0.85) : .black.opacity(0.55), in: Circle())
                .foregroundStyle(.white)
        }
        .accessibilityLabel(dictation.isRecording ? "停止并发送语音" : "控制菜单")
        .rotationEffect(.degrees(-Double(rotationQuarterTurns) * 90))
    }

    @ViewBuilder private var dictationBanner: some View {
        if rotationQuarterTurns == 0 {
            dictationBannerContent
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        } else {
            dictationBannerContent
                .frame(width: 300)
                .rotationEffect(.degrees(-Double(rotationQuarterTurns) * 90))
                .frame(width: 80, height: 300)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private var dictationBannerContent: some View {
        Text(dictation.transcript.isEmpty ? "正在聆听（\(dictationLanguageName)）…点击红色停止按钮发送" : dictation.transcript)
            .font(.callout)
            .foregroundStyle(.white)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
    }

    private var compactMenuPanel: some View {
        VStack(spacing: 8) {
            Text(device.name)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider().overlay(.white.opacity(0.35))

            Button {
                keyboardActive.toggle()
                compactMenuVisible = false
            } label: {
                Label("键盘", systemImage: "keyboard")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                toggleDictation()
                compactMenuVisible = false
            } label: {
                Label(dictation.isRecording ? "停止并发送语音" : "语音输入（\(dictationLanguageName)）", systemImage: dictation.isRecording ? "stop.circle.fill" : "mic.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                toggleDictationLanguage()
                compactMenuVisible = false
            } label: {
                Label(dictationLocale == "zh-CN" ? "切换到 English" : "切换到中文", systemImage: "globe")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(dictation.isRecording)

            Button {
                model.sendPhoneClipboard()
                compactMenuVisible = false
            } label: {
                Label("粘贴手机文本", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                toggleRotation()
                compactMenuVisible = false
            } label: {
                Label(rotationQuarterTurns == 0 ? "向右旋转画面" : "恢复画面方向", systemImage: rotationQuarterTurns == 0 ? "rotate.right" : "rotate.left")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let file = model.receivedFileURL {
                ShareLink(item: file) {
                    Label("分享收到的文件", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Button(role: .destructive) {
                model.disconnect()
                dismiss()
            } label: {
                Label("退出控制", systemImage: "xmark")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .foregroundStyle(.white)
        .padding(14)
        .frame(width: 280)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.3), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
    }

    private var controlBar: some View {
        HStack(spacing: 10) {
            Button {
                model.disconnect()
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }

            Text(device.name)
                .font(.callout.bold())
                .lineLimit(1)

            Spacer()

            if model.phase == .controlling {
                Button { keyboardActive.toggle() } label: {
                    Image(systemName: "keyboard")
                }
                Button(action: toggleDictation) {
                    Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic.fill")
                }
                .accessibilityLabel(dictation.isRecording ? "停止并发送语音" : "语音输入")
                Button(action: toggleDictationLanguage) {
                    Text(dictationLocale == "zh-CN" ? "中" : "EN")
                        .font(.caption.bold())
                }
                .disabled(dictation.isRecording)
                .accessibilityLabel("语音语言：\(dictationLanguageName)")
                Button { model.sendPhoneClipboard() } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                Button(action: toggleRotation) {
                    Image(systemName: rotationQuarterTurns == 0 ? "rotate.right" : "rotate.left")
                }
                .accessibilityLabel(rotationQuarterTurns == 0 ? "向右旋转画面" : "恢复画面方向")
                if let file = model.receivedFileURL {
                    ShareLink(item: file) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.black.opacity(0.65))
        .foregroundStyle(.white)
        .padding(12)
        .background(.ultraThinMaterial)
    }

    private var statusPanel: some View {
        VStack(spacing: 14) {
            if model.phase == .connecting {
                ProgressView().tint(.white)
            } else if model.phase == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("重试") { model.connect(to: device) }
                    .buttonStyle(.borderedProminent)
            }
            Text(model.status)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
        }
        .padding(20)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
        .padding(24)
    }

    private func toggleDictation() {
        keyboardActive = false
        dictation.toggle(localeIdentifier: dictationLocale, sendText: model.sendText)
    }

    private func toggleRotation() {
        rotationQuarterTurns = rotationQuarterTurns == 0 ? 3 : 0
    }

    private var usesCompactControls: Bool {
        verticalSizeClass == .compact || !rotationQuarterTurns.isMultiple(of: 2)
    }

    private var dictationLanguageName: String {
        dictationLocale == "zh-CN" ? "中文" : "English"
    }

    private func toggleDictationLanguage() {
        dictationLocale = dictationLocale == "zh-CN" ? "en-US" : "zh-CN"
    }
}

@MainActor
private final class VoiceDictation: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var localeIdentifier = "zh-CN"
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var sendText: ((String) -> Void)?
    private var tapInstalled = false
    private var pendingStart = false

    override init() {
        super.init()
#if DEBUG
        assert(Self.segmentLimit(for: "zh-CN") == 36)
        assert(Self.segmentLimit(for: "en-US") == 80)
#endif
    }

    func toggle(localeIdentifier: String, sendText: @escaping (String) -> Void) {
        if isRecording {
            finish(send: true)
            return
        }
        self.sendText = sendText
        self.localeIdentifier = localeIdentifier
        pendingStart = true
        transcript = ""
        errorMessage = nil
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard self.pendingStart else { return }
                guard status == .authorized else {
                    self.fail("请在系统设置中允许 TailDesk 使用语音识别。")
                    return
                }
                AVAudioApplication.requestRecordPermission { [weak self] granted in
                    Task { @MainActor in
                        guard let self else { return }
                        guard self.pendingStart else { return }
                        guard granted else {
                            self.fail("请在系统设置中允许 TailDesk 使用麦克风。")
                            return
                        }
                        self.startRecording()
                    }
                }
            }
        }
    }

    func cancel() {
        finish(send: false)
    }

    private func startRecording() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)), recognizer.isAvailable else {
            fail("当前无法使用语音识别，请稍后重试。")
            return
        }
        self.recognizer = recognizer
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            request.addsPunctuation = true
            self.request = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                request.append(buffer)
            }
            tapInstalled = true
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.isRecording, self.request === request else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        if result.isFinal || self.transcript.count >= Self.segmentLimit(for: self.localeIdentifier) {
                            self.flushAndContinue()
                        }
                    } else if error != nil {
                        if self.transcript.isEmpty {
                            self.fail("语音识别失败，请重试。")
                        } else {
                            self.flushAndContinue()
                        }
                    }
                }
            }
            audioEngine.prepare()
            try audioEngine.start()
            pendingStart = false
            isRecording = true
        } catch {
            fail("无法启动语音输入：\(error.localizedDescription)")
        }
    }

    private static func segmentLimit(for localeIdentifier: String) -> Int {
        localeIdentifier == "zh-CN" ? 36 : 80
    }

    private func flushAndContinue() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let completion = sendText
        stopRecording()
        transcript = ""
        completion?(text + (localeIdentifier == "en-US" ? " " : ""))
        pendingStart = true
        startRecording()
    }

    private func finish(send: Bool) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let completion = sendText
        sendText = nil
        pendingStart = false
        stopRecording()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: .mixWithOthers)
        try? session.setActive(true)
        if send, !text.isEmpty { completion?(text) }
    }

    private func stopRecording() {
        isRecording = false
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil
        recognitionTask = nil
        recognizer = nil
    }

    private func fail(_ message: String) {
        finish(send: false)
        errorMessage = message
    }
}
