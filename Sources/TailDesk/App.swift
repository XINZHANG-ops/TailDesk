import AppKit
import CoreImage.CIFilterBuiltins
import Darwin
import ServiceManagement
import SwiftUI

@main
struct TailDeskApp: App {
    @StateObject private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--login-item-status") {
            switch SMAppService.mainApp.status {
            case .notRegistered: print("not registered")
            case .enabled: print("enabled")
            case .requiresApproval: print("requires approval")
            case .notFound: print("not found")
            @unknown default: print("unknown")
            }
            exit(EXIT_SUCCESS)
        }
        if CommandLine.arguments.contains("--self-check") {
            ProtocolSelfCheck.run()
            AudioSelfCheck.run()
            ClipboardSelfCheck.run()
            TailscaleCLI.selfCheck()
            CaptureSelfCheck.run()
            VideoSelfCheck.run()
            InputSelfCheck.run()
            NetworkingSelfCheck.run()
            SessionSelfCheck.run()
            print("TailDesk protocol self-check passed")
            exit(EXIT_SUCCESS)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
    }
}

private enum SidebarItem: Hashable {
    case host
    case viewer
    case device(String)
    case phone
    case permissions
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var selection: SidebarItem? = .host
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var previewTask: Task<Void, Never>?
    @State private var immersive = false
    @State private var edgeControlsVisible = false
    @State private var edgeControlsHideTask: Task<Void, Never>?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                Section("模式") {
                    Label("被控端", systemImage: "display")
                        .tag(SidebarItem.host)
                    Label("控制端", systemImage: "cursorarrow")
                        .tag(SidebarItem.viewer)
                }

                Section("在线设备") {
                    if model.macDevices.isEmpty && !model.isRefreshingDevices {
                        Text("没有发现其他 Mac")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.macDevices) { device in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text(device.address)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "laptopcomputer")
                        }
                        .tag(SidebarItem.device(device.id))
                        .disabled(model.isBeingControlled)
                    }

                    Button {
                        model.refreshDevices()
                    } label: {
                        if model.isRefreshingDevices {
                            Label("正在刷新", systemImage: "arrow.clockwise")
                        } else {
                            Label("刷新设备", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(model.isRefreshingDevices || model.isConnecting || model.isConnected)
                }

                if isControlSelection, let device = selectedDevice {
                    Section("远程控制") {
                        if model.isConnecting {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("正在载入 \(device.name) 预览")
                            }
                        } else if model.isConnected {
                            Button {
                                leaveRemoteSession()
                            } label: {
                                Label("关闭预览", systemImage: "xmark.circle")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                        }

                        Label("进入控制后同步剪贴板", systemImage: "doc.on.clipboard")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        statusView
                    }
                }

                Section("选项") {
                    Label("连接 iPhone", systemImage: "iphone")
                        .tag(SidebarItem.phone)
                    Label("权限与状态", systemImage: "lock.shield")
                        .tag(SidebarItem.permissions)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("TailDesk")
            .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
        } detail: {
            Group {
                switch selection ?? .host {
                case .host:
                    hostView
                case .viewer, .device:
                    viewerView
                case .phone:
                    phoneView
                case .permissions:
                    permissionsView
                }
            }
            .padding(immersive ? 0 : 20)
        }
        .onAppear { model.startAutomatically() }
        .onChange(of: selection) { _, selection in
            previewTask?.cancel()
            switch selection {
            case .host:
                leaveRemoteSession(selecting: .host)
            case .viewer, .phone, .permissions:
                if model.isConnecting || model.isConnected { leaveRemoteSession(selecting: selection) }
            case .device(let id):
                guard !model.isBeingControlled else {
                    self.selection = .host
                    return
                }
                previewTask = Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    if !model.connectViewer(to: id) { self.selection = .host }
                }
            default:
                break
            }
        }
        .onChange(of: model.isConnected) { _, connected in
            if !connected && immersive {
                immersive = false
                columnVisibility = .all
            }
        }
        .onDisappear { previewTask?.cancel() }
    }

    private var hostView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("被控端")
                .font(.title2.bold())
            Label(
                model.isHosting ? "已自动开放远程连接" : "正在启动远程连接",
                systemImage: model.isHosting ? "checkmark.circle.fill" : "clock"
            )
            .foregroundStyle(model.isHosting ? .green : .secondary)

            Text("Tailscale 地址：\(model.tailscaleAddress):47821")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            Text("TailDesk 会在登录时启动，仅允许同一 Tailscale 用户的 Mac 连接。只有控制端连入后才会捕获屏幕。")
                .font(.callout)
                .foregroundStyle(.secondary)

            if model.isBeingControlled {
                Label("本机正在被控制。为防止循环控制，此时不能再控制其他 Mac。", systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("屏幕录制权限") { model.requestScreenPermission() }
                Button("辅助功能权限") { model.requestAccessibilityPermission() }
            }

            if let warning = model.launchAtLoginWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Spacer()
            statusView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var viewerView: some View {
        Group {
            if immersive && model.isConnected {
                ZStack {
                    RemoteDesktopView(
                        frame: model.currentFrame,
                        onControlRevealZoneChanged: setEdgeControlsActive
                    ) { event in
                        model.sendInput(event)
                    }
                    .background(Color.black)

                    VStack {
                        if edgeControlsVisible {
                            HStack(spacing: 8) {
                                exitControlButton
                                if model.remoteDisplays.count > 1 {
                                    displayPicker
                                }
                            }
                            .onHover(perform: setEdgeControlsActive)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        Spacer()
                    }
                    .padding(.top, 4)
                    .animation(.snappy(duration: 0.2), value: edgeControlsVisible)
                }
            } else if model.isConnected {
                devicePreview
            } else if model.isConnecting {
                ContentUnavailableView {
                    Label("正在连接预览", systemImage: "display")
                } description: {
                    Text("\(selectedDevice?.name ?? "远程 Mac") · 最多等待 5 秒")
                } actions: {
                    ProgressView()
                }
            } else if model.isBeingControlled {
                ContentUnavailableView(
                    "本机正在被控制",
                    systemImage: "exclamationmark.shield",
                    description: Text("为防止循环控制，请先结束当前被控会话。")
                )
            } else if let device = selectedDevice {
                ContentUnavailableView(
                    model.statusIsError ? "无法预览 \(device.name)" : "选择 \(device.name)",
                    systemImage: model.statusIsError ? "exclamationmark.triangle" : "display",
                    description: Text(model.statusIsError ? model.status : "点击设备后会自动载入只读预览。")
                )
            } else {
                ContentUnavailableView(
                    "选择设备",
                    systemImage: "laptopcomputer",
                    description: Text("选择左侧的一台在线 Mac，TailDesk 会自动载入预览。")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var devicePreview: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.title2)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedDevice?.name ?? "远程 Mac")
                        .font(.headline)
                    Label("实时预览 · 只读", systemImage: "eye.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if model.remoteDisplays.count > 1 {
                    displayPicker
                }

                Button(action: enterControl) {
                    Label("进入控制", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.currentFrame == nil)
            }

            ZStack {
                RemoteDesktopView(
                    frame: model.currentFrame,
                    isInteractive: false,
                    onActivate: enterControl
                ) { _ in }
                .background(Color.black)

                if model.currentFrame == nil {
                    ProgressView("正在等待画面")
                        .tint(.white)
                        .foregroundStyle(.white)
                        .padding()
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Button(action: enterControl) {
                        Label("点击进入控制", systemImage: "hand.tap.fill")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(previewAspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.primary.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.15), radius: 16, y: 8)

            Text("预览不会向对方发送鼠标或键盘操作")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 1100, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }

    private var previewAspectRatio: CGFloat {
        guard let frame = model.currentFrame, frame.height > 0 else { return 16 / 10 }
        return CGFloat(frame.width) / CGFloat(frame.height)
    }

    private var displayPicker: some View {
        HStack(spacing: 5) {
            ForEach(model.remoteDisplays) { display in
                let selected = model.selectedRemoteDisplayID == display.id
                Button {
                    model.selectRemoteDisplay(display.id)
                } label: {
                    Label(display.name, systemImage: display.isMain ? "display" : "rectangle.on.rectangle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(selected ? .white : .cyan)
                        .padding(.horizontal, 9)
                        .frame(height: 30)
                        .background(selected ? Color.blue.opacity(0.78) : .white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(selected ? .cyan.opacity(0.9) : .white.opacity(0.14), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color(red: 0.025, green: 0.07, blue: 0.15).opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.cyan.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
        .fixedSize()
        .accessibilityLabel("远端显示器")
    }

    private var exitControlButton: some View {
        Button {
            leaveRemoteSession()
        } label: {
            Label("退出", systemImage: "xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(.red.opacity(0.68), in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(.red.opacity(0.9), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private var permissionsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("权限与状态")
                .font(.title2.bold())

            GroupBox("macOS 权限") {
                HStack {
                    Button("屏幕录制权限") { model.requestScreenPermission() }
                    Button("辅助功能权限") { model.requestAccessibilityPermission() }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            GroupBox("自动启动") {
                HStack {
                    Label(
                        model.launchAtLoginWarning ?? "TailDesk 已设置为登录时自动启动",
                        systemImage: model.launchAtLoginWarning == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(model.launchAtLoginWarning == nil ? .green : .orange)
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            GroupBox("连接") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tailscale 地址：\(model.tailscaleAddress):47821")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    statusView
                }
                .padding(.vertical, 4)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var phoneView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接 iPhone")
                .font(.title2.bold())

            Text("先让 iPhone 登录同一个 Tailscale，然后在 iPhone TailDesk 中扫描。也可以使用系统相机。二维码只包含在线 Mac 的 MagicDNS 设备名，不包含密码或 Tailscale 密钥。")
                .foregroundStyle(.secondary)

            if let url = model.phoneImportURL {
                QRCodeView(text: url.absoluteString)
                    .frame(width: 220, height: 220)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))

                Label("扫描后 TailDesk 会自动保存设备列表", systemImage: "checkmark.shield")
                    .foregroundStyle(.green)
            } else if model.isRefreshingDevices {
                ProgressView("正在生成设备二维码")
            } else {
                ContentUnavailableView(
                    "无法生成二维码",
                    systemImage: "qrcode",
                    description: Text("确认 Tailscale 已连接，然后刷新设备。")
                )
            }

            Button("刷新二维码") { model.refreshDevices() }
                .disabled(model.isRefreshingDevices)

            Spacer()
            statusView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var selectedDevice: TailnetMac? {
        let id: String?
        if case .device(let selectedID) = selection {
            id = selectedID
        } else {
            id = model.selectedDeviceID
        }
        return model.macDevices.first { $0.id == id }
    }

    private var isControlSelection: Bool {
        switch selection {
        case .viewer, .device: true
        default: false
        }
    }

    private var statusView: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.statusIsError ? Color.red : Color.green)
                .frame(width: 8, height: 8)
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func enterControl() {
        guard model.currentFrame != nil, model.beginControl() else { return }
        edgeControlsVisible = false
        immersive = true
        columnVisibility = .detailOnly
    }

    private func setEdgeControlsActive(_ active: Bool) {
        edgeControlsHideTask?.cancel()
        if active {
            edgeControlsVisible = true
        } else {
            edgeControlsHideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 650_000_000)
                guard !Task.isCancelled else { return }
                edgeControlsVisible = false
            }
        }
    }

    private func leaveRemoteSession(selecting item: SidebarItem? = nil) {
        let destination = item ?? selection
        previewTask?.cancel()
        model.disconnectViewerAndResumeHosting()
        if destination == .viewer { model.selectedDeviceID = nil }
        edgeControlsHideTask?.cancel()
        edgeControlsVisible = false
        immersive = false
        columnVisibility = .all
        if selection != destination { selection = destination }
    }
}

private struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
        }
    }

    private static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)) else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: output.extent)
    }
}
