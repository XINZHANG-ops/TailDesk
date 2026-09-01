import SwiftUI
import UniformTypeIdentifiers
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
    @State private var keyboardActive = false
    @State private var importingFile = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MobileRemoteDesktopView(
                frame: model.currentFrame,
                isInteractive: model.phase == .controlling,
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
                if model.phase == .controlling && verticalSizeClass == .compact {
                    HStack {
                        compactControlMenu
                        Spacer()
                    }
                    .padding(8)
                } else {
                    controlBar
                }
                Spacer()
                if model.phase == .controlling && verticalSizeClass != .compact {
                    Text("单指移动 · 点按左键 · 点按后长按拖拽 · 双指点按右键 · 双指滚动")
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
        }
        .statusBarHidden(model.phase == .controlling)
        .persistentSystemOverlays(model.phase == .controlling ? .hidden : .automatic)
        .onAppear { model.connect(to: device) }
        .onDisappear { model.disconnect() }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { model.sendFile(url) }
        }
    }

    private var compactControlMenu: some View {
        Menu {
            Section(device.name) {
                Button("键盘", systemImage: "keyboard") { keyboardActive.toggle() }
                Button("粘贴手机文本", systemImage: "doc.on.clipboard") { model.sendPhoneClipboard() }
                Button("发送文件", systemImage: "doc.badge.plus") { importingFile = true }
                if let file = model.receivedFileURL {
                    ShareLink(item: file) {
                        Label("分享收到的文件", systemImage: "square.and.arrow.up")
                    }
                }
            }
            Button("退出控制", systemImage: "xmark", role: .destructive) {
                model.disconnect()
                dismiss()
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.headline)
                .frame(width: 38, height: 38)
                .background(.black.opacity(0.55), in: Circle())
                .foregroundStyle(.white)
        }
        .accessibilityLabel("控制菜单")
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
                Button { model.sendPhoneClipboard() } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                Button { importingFile = true } label: {
                    Image(systemName: "doc.badge.plus")
                }
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
}
