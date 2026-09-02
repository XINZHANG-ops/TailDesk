import AVFoundation
import Speech
import SwiftUI
import VisionKit

@MainActor
private enum MobileInterfaceOrientation {
    static var current: UIInterfaceOrientation? { activeScene?.interfaceOrientation }

    static func request(_ orientations: UIInterfaceOrientationMask) {
        activeScene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}

@main
struct TailDeskMobileApp: App {
    @StateObject private var model = MobileAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MobileRootView(model: model)
                .onOpenURL { _ = model.importDevices(from: $0) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.resumeVideo() }
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

private enum CompactControlAxis {
    case horizontal
    case vertical
}

private struct CompactControlPlacement {
    let axis: CompactControlAxis
    let center: CGPoint
}

private func compactControlPlacement(
    contentRect: CGRect?,
    in bounds: CGRect,
    safeArea: EdgeInsets,
    preferTrailing: Bool
) -> CompactControlPlacement {
    let sideCenterY = min(
        bounds.maxY - safeArea.bottom - 78,
        bounds.minY + safeArea.top + 78
    )
    guard let contentRect else {
        return CompactControlPlacement(
            axis: .vertical,
            center: CGPoint(x: preferTrailing ? bounds.maxX - 28 : bounds.minX + 28, y: sideCenterY)
        )
    }

    enum Edge { case leading, trailing, top, bottom }
    let leadingSpace = max(0, contentRect.minX - bounds.minX - safeArea.leading)
    let trailingSpace = max(0, bounds.maxX - safeArea.trailing - contentRect.maxX)
    let candidates: [(Edge, CGFloat)] = preferTrailing
        ? [(.trailing, trailingSpace), (.leading, leadingSpace), (.bottom, bounds.maxY - contentRect.maxY), (.top, contentRect.minY)]
        : [(.leading, leadingSpace), (.trailing, trailingSpace), (.bottom, bounds.maxY - contentRect.maxY), (.top, contentRect.minY)]
    let best = candidates.dropFirst().reduce(candidates[0]) { $1.1 > $0.1 ? $1 : $0 }

    guard best.1 >= 48 else {
        return CompactControlPlacement(
            axis: .vertical,
            center: CGPoint(
                x: preferTrailing ? bounds.maxX - safeArea.trailing - 28 : bounds.minX + safeArea.leading + 28,
                y: sideCenterY
            )
        )
    }

    switch best.0 {
    case .leading:
        return CompactControlPlacement(
            axis: .vertical,
            center: CGPoint(x: bounds.minX + safeArea.leading + best.1 / 2, y: sideCenterY)
        )
    case .trailing:
        return CompactControlPlacement(
            axis: .vertical,
            center: CGPoint(x: bounds.maxX - safeArea.trailing - best.1 / 2, y: sideCenterY)
        )
    case .top, .bottom:
        let sideInset: CGFloat = 78
        return CompactControlPlacement(
            axis: .horizontal,
            center: CGPoint(
                x: preferTrailing ? bounds.maxX - sideInset : bounds.minX + sideInset,
                y: best.0 == .top ? bounds.minY + best.1 / 2 : bounds.maxY - best.1 / 2
            )
        )
    }
}

private struct RemoteSessionView: View {
    @ObservedObject var model: MobileAppModel
    let device: SavedMac
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage("TailDesk.dictationLocale") private var dictationLocale = "zh-CN"
    @StateObject private var dictation = VoiceDictation()
    @State private var keyboardActive = false
    @State private var rotationQuarterTurns = 0
    @State private var compactMenuVisible = false
    @State private var quickCopyVisible = false
    @State private var quickCopyDismissTask: Task<Void, Never>?
    @State private var interfaceOrientationBeforeKeyboard: UIInterfaceOrientation?
    @State private var rotationBeforeKeyboard: Int?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MobileRemoteDesktopView(
                frame: model.currentFrame,
                isInteractive: model.phase == .controlling,
                rotationQuarterTurns: rotationQuarterTurns,
                sendInput: model.sendInput,
                onCopySuggested: showQuickCopy
            )
            .ignoresSafeArea(.container)

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

            if model.phase == .controlling && usesCompactControls {
                GeometryReader { geometry in
                    compactControls(in: geometry)
                }
                .ignoresSafeArea()
            } else {
                VStack {
                    controlBar
                    Spacer()
                    if model.phase == .controlling {
                        Text("单指移动 · 点按左键 · 长按精确点击 · 停稳震动后拖拽 · 双指滚动")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(8)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(.bottom, 8)
                    }
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
            quickCopyDismissTask?.cancel()
            dictation.cancel()
            restoreLayoutAfterKeyboard()
            model.disconnect()
        }
        .onChange(of: keyboardActive) { _, active in
            if !active { restoreLayoutAfterKeyboard() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshClipboardAvailability() }
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

    private func compactControls(in geometry: GeometryProxy) -> some View {
        let bounds = CGRect(origin: .zero, size: geometry.size)
        let imageSize = model.currentFrame.map { CGSize(width: $0.width, height: $0.height) }
        let contentRect = imageSize.flatMap {
            mobileRemoteContentRect(imageSize: $0, in: bounds, quarterTurns: rotationQuarterTurns)
        }
        let placement = compactControlPlacement(
            contentRect: contentRect,
            in: bounds,
            safeArea: geometry.safeAreaInsets,
            preferTrailing: rotationQuarterTurns != 0
        )
#if DEBUG
        let testPlacement = compactControlPlacement(
            contentRect: CGRect(x: 75, y: 0, width: 694, height: 390),
            in: CGRect(x: 0, y: 0, width: 844, height: 390),
            safeArea: EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 21),
            preferTrailing: false
        )
        assert(testPlacement.axis == .vertical && testPlacement.center.x > 769 && testPlacement.center.y < 100)
#endif
        return Group {
            if placement.axis == .vertical {
                VStack(spacing: 7) { compactActionButtons }
            } else {
                HStack(spacing: 7) { compactActionButtons }
            }
        }
        .padding(5)
        .background(Color(red: 0.025, green: 0.07, blue: 0.15).opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.cyan.opacity(0.24), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
        .position(placement.center)
        .animation(.snappy(duration: 0.22), value: quickCopyVisible)
        .animation(.snappy(duration: 0.22), value: model.canPaste)
    }

    @ViewBuilder private var compactActionButtons: some View {
        compactControlMenu
        if !dictation.isRecording && !keyboardActive && quickCopyVisible {
            compactActionButton("doc.on.doc.fill", color: .green, label: "复制") {
                model.copyRemoteSelection()
                quickCopyDismissTask?.cancel()
                quickCopyVisible = false
            }
            .transition(.scale.combined(with: .opacity))
        }
        if !dictation.isRecording && !keyboardActive && model.canPaste {
            compactActionButton("doc.on.clipboard.fill", color: .orange, label: "粘贴") {
                model.pasteRemoteClipboard()
            }
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var compactControlMenu: some View {
        let active = dictation.isRecording || keyboardActive
        let icon = dictation.isRecording ? "stop.fill" : (keyboardActive ? "keyboard.fill" : "ellipsis")
        let color: Color = dictation.isRecording ? .cyan : (keyboardActive ? .blue : .cyan)
        let label = dictation.isRecording ? "停止并发送语音" : (keyboardActive ? "收起键盘" : "控制菜单")
        return compactActionButton(icon, color: color, isActive: active, label: label) {
            if dictation.isRecording {
                toggleDictation()
            } else if keyboardActive {
                toggleKeyboard()
            } else {
                compactMenuVisible.toggle()
            }
        }
    }

    private func compactActionButton(
        _ systemImage: String,
        color: Color,
        isActive: Bool = false,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isActive ? .white : color)
                .frame(width: 38, height: 38)
                .background(
                    color.opacity(isActive ? 0.58 : 0.16),
                    in: RoundedRectangle(cornerRadius: 11)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(color.opacity(isActive ? 0.9 : 0.42), lineWidth: 1)
                }
        }
        .accessibilityLabel(label)
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
        Text(dictation.transcript.isEmpty ? "正在聆听（\(dictationLanguageName)）…点击停止按钮发送" : dictation.transcript)
            .font(.callout)
            .foregroundStyle(.white)
            .lineLimit(3)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(dictationAccentColor.opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.white.opacity(0.35), lineWidth: 1)
            }
    }

    private var dictationAccentColor: Color {
        Color(red: 0.15, green: 0.48, blue: 0.95)
    }

    private var compactMenuPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "rectangle.grid.2x2.fill")
                    .foregroundStyle(.cyan)
                Text(device.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                Button {
                    toggleKeyboard()
                    compactMenuVisible = false
                } label: {
                    compactMenuTile("键盘", systemImage: "keyboard.fill", color: .blue)
                }

                Button {
                    toggleDictation()
                    compactMenuVisible = false
                } label: {
                    compactMenuTile("\(dictationLanguageName)语音", systemImage: "mic.fill", color: .cyan)
                }

                Button {
                    toggleDictationLanguage()
                } label: {
                    compactMenuTile(dictationLocale == "zh-CN" ? "切换 English" : "切换中文", systemImage: "globe", color: .purple)
                }
                .disabled(dictation.isRecording)

                Button {
                    model.copyRemoteSelection()
                    compactMenuVisible = false
                } label: {
                    compactMenuTile("复制", systemImage: "doc.on.doc.fill", color: .green)
                }

                Button {
                    model.pasteRemoteClipboard()
                    compactMenuVisible = false
                } label: {
                    compactMenuTile("粘贴", systemImage: "doc.on.clipboard.fill", color: .orange)
                }

                Button {
                    toggleRotation()
                    compactMenuVisible = false
                } label: {
                    compactMenuTile(rotationQuarterTurns == 0 ? "向右旋转" : "恢复方向", systemImage: rotationQuarterTurns == 0 ? "rotate.right" : "rotate.left", color: .indigo)
                }
                .disabled(keyboardActive)

                Button(role: .destructive) {
                    model.disconnect()
                    dismiss()
                } label: {
                    compactMenuTile("退出控制", systemImage: "xmark", color: .red)
                }
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(width: 320)
        .background(Color(red: 0.025, green: 0.055, blue: 0.12).opacity(0.96), in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(.cyan.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
    }

    private func compactMenuTile(_ title: String, systemImage: String, color: Color) -> some View {
        VStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .padding(.horizontal, 6)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    private var controlBar: some View {
        HStack(spacing: 7) {
            Button {
                model.disconnect()
                dismiss()
            } label: {
                controlBarTile("xmark", color: .red)
            }
            .accessibilityLabel("退出控制")

            if model.phase == .controlling {
                Spacer(minLength: 0)

                Button { toggleKeyboard() } label: {
                    controlBarTile(keyboardActive ? "keyboard.fill" : "keyboard", color: .blue, isActive: keyboardActive)
                }
                .accessibilityLabel(keyboardActive ? "收起键盘" : "打开键盘")

                Button(action: toggleDictation) {
                    controlBarTile(dictation.isRecording ? "stop.fill" : "mic.fill", color: .cyan, isActive: dictation.isRecording)
                }
                .accessibilityLabel(dictation.isRecording ? "停止并发送语音" : "语音输入")

                Button(action: toggleDictationLanguage) {
                    Text(dictationLocale == "zh-CN" ? "中" : "EN")
                        .font(.caption.bold())
                        .foregroundStyle(.purple)
                        .frame(width: 44, height: 44)
                        .background(.purple.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(.purple.opacity(0.5), lineWidth: 1)
                        }
                }
                .disabled(dictation.isRecording)
                .accessibilityLabel("语音语言：\(dictationLanguageName)")

                Button { model.copyRemoteSelection() } label: {
                    controlBarTile("doc.on.doc.fill", color: .green)
                }
                .accessibilityLabel("复制远端所选内容")

                Button { model.pasteRemoteClipboard() } label: {
                    controlBarTile("doc.on.clipboard.fill", color: .orange)
                }
                .accessibilityLabel("粘贴远端剪贴板")

                Button(action: toggleRotation) {
                    controlBarTile(rotationQuarterTurns == 0 ? "rotate.right" : "rotate.left", color: .indigo)
                }
                .disabled(keyboardActive)
                .accessibilityLabel(rotationQuarterTurns == 0 ? "向右旋转画面" : "恢复画面方向")

            } else {
                Text(device.name)
                    .font(.callout.bold())
                    .lineLimit(1)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(8)
        .background(Color(red: 0.025, green: 0.055, blue: 0.12).opacity(0.94), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.cyan.opacity(0.3), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private func controlBarTile(_ systemImage: String, color: Color, isActive: Bool = false) -> some View {
        Image(systemName: systemImage)
            .font(.headline.weight(.semibold))
            .foregroundStyle(isActive ? .white : color)
            .frame(width: 44, height: 44)
            .background(color.opacity(isActive ? 0.72 : 0.18), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(color.opacity(isActive ? 0.9 : 0.5), lineWidth: 1)
            }
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

    private func showQuickCopy() {
        guard usesCompactControls else { return }
        quickCopyDismissTask?.cancel()
        quickCopyVisible = true
        quickCopyDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            quickCopyVisible = false
        }
    }

    private func toggleKeyboard() {
        guard !keyboardActive else {
            keyboardActive = false
            return
        }
        if rotationQuarterTurns != 0 {
            rotationBeforeKeyboard = rotationQuarterTurns
            rotationQuarterTurns = 0
        }
        if let orientation = MobileInterfaceOrientation.current, orientation.isLandscape {
            interfaceOrientationBeforeKeyboard = orientation
            MobileInterfaceOrientation.request(.portrait)
        }
        keyboardActive = true
    }

    private func restoreLayoutAfterKeyboard() {
        if let rotationBeforeKeyboard {
            rotationQuarterTurns = rotationBeforeKeyboard
            self.rotationBeforeKeyboard = nil
        }
        if let orientation = interfaceOrientationBeforeKeyboard {
            MobileInterfaceOrientation.request(orientation == .landscapeLeft ? .landscapeLeft : .landscapeRight)
            interfaceOrientationBeforeKeyboard = nil
        }
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
    private var sentCharacterCount = 0
    private var isFinalizing = false
    private var finalizationWorkItem: DispatchWorkItem?

    override init() {
        super.init()
#if DEBUG
        assert(Self.flushThreshold(for: "zh-CN") == 160)
        assert(Self.flushThreshold(for: "en-US") == 280)
        assert(Self.flushBoundary(in: "alpha beta gamma", after: 0, before: 10) == 6)
#endif
    }

    func toggle(localeIdentifier: String, sendText: @escaping (String) -> Void) {
        if isRecording {
            finish(send: true)
            return
        }
        guard !isFinalizing else { return }
        self.sendText = sendText
        self.localeIdentifier = localeIdentifier
        pendingStart = true
        transcript = ""
        sentCharacterCount = 0
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
                    guard let self, self.request === request,
                          self.isRecording || self.isFinalizing else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        if self.isRecording { self.flushStablePrefixIfNeeded() }
                        if result.isFinal {
                            if self.isRecording {
                                self.isRecording = false
                                self.isFinalizing = true
                                self.stopAudioCapture()
                            }
                            self.completeFinalization()
                            return
                        }
                    }
                    if error != nil {
                        if self.isFinalizing {
                            self.completeFinalization()
                            return
                        }
                        guard !self.transcript.isEmpty else {
                            self.fail("语音识别失败，请重试。")
                            return
                        }
                        self.isRecording = false
                        self.isFinalizing = true
                        self.stopAudioCapture()
                        self.completeFinalization()
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

    private static func flushThreshold(for localeIdentifier: String) -> Int {
        localeIdentifier == "zh-CN" ? 160 : 280
    }

    private static func holdbackCount(for localeIdentifier: String) -> Int {
        localeIdentifier == "zh-CN" ? 24 : 40
    }

    private static func flushBoundary(in text: String, after start: Int, before preferredEnd: Int) -> Int {
        let characters = Array(text)
        let end = min(characters.count, max(start, preferredEnd))
        guard end > start else { return start }
        let boundaries = Set("，。！？；,.!?; \n")
        let searchStart = max(start, end - 60)
        if let index = (searchStart..<end).reversed().first(where: { boundaries.contains(characters[$0]) }) {
            return index + 1
        }
        return end
    }

    private func flushStablePrefixIfNeeded() {
        let total = transcript.count
        guard total - sentCharacterCount >= Self.flushThreshold(for: localeIdentifier) else { return }
        let preferredEnd = total - Self.holdbackCount(for: localeIdentifier)
        sendTranscript(through: Self.flushBoundary(
            in: transcript,
            after: sentCharacterCount,
            before: preferredEnd
        ))
    }

    private func sendTranscript(through end: Int) {
        let safeStart = min(sentCharacterCount, transcript.count)
        let safeEnd = min(transcript.count, max(safeStart, end))
        guard safeEnd > safeStart else { return }
        let startIndex = transcript.index(transcript.startIndex, offsetBy: safeStart)
        let endIndex = transcript.index(transcript.startIndex, offsetBy: safeEnd)
        let text = transcript[startIndex..<endIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { sendText?(text + (localeIdentifier == "en-US" ? " " : "")) }
        sentCharacterCount = safeEnd
    }

    private func finish(send: Bool) {
        pendingStart = false
        guard send else {
            abortRecognition()
            return
        }
        guard isRecording else { return }
        isRecording = false
        isFinalizing = true
        stopAudioCapture()
        request?.endAudio()

        finalizationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.completeFinalization() }
        }
        finalizationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func stopAudioCapture() {
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private func completeFinalization() {
        guard isFinalizing else { return }
        finalizationWorkItem?.cancel()
        finalizationWorkItem = nil
        sendTranscript(through: transcript.count)
        sendText = nil
        isFinalizing = false
        recognitionTask?.cancel()
        request = nil
        recognitionTask = nil
        recognizer = nil
        restorePlaybackAudioSession()
    }

    private func abortRecognition() {
        finalizationWorkItem?.cancel()
        finalizationWorkItem = nil
        isRecording = false
        isFinalizing = false
        stopAudioCapture()
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil
        recognitionTask = nil
        recognizer = nil
        sendText = nil
        restorePlaybackAudioSession()
    }

    private func restorePlaybackAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: .mixWithOthers)
        try? session.setActive(true)
    }

    private func fail(_ message: String) {
        finish(send: false)
        errorMessage = message
    }
}
