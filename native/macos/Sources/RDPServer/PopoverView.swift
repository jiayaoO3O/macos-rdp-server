import SwiftUI

/// Root of the status-item popover. Exactly 360 pt wide; the hosting controller
/// reports the intrinsic height and NSPopover resizes to it.
struct PopoverView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.showCredentials {
                CredentialsEditorView(model: model)
            } else {
                PopoverMainView(model: model)
            }
        }
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.16), value: model.showCredentials)
    }
}

struct PopoverMainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(model: model)
            if let message = model.bannerText {
                ErrorBanner(message: message,
                            onOpenLogs: { model.openLogs() },
                            onCopy: {
                                copyToPasteboard(message)
                                model.showToast("错误信息已复制")
                            })
            }
            if model.snapshot.needsRestart && !model.snapshot.state.isBusy {
                RestartBanner(model: model)
            }
            Divider()
            VStack(alignment: .leading, spacing: 13) {
                ConnectionSection(model: model)
                Divider()
                CaptureSection(model: model)
                Divider()
                PermissionSection(model: model)
                Divider()
                AccountSection(model: model)
                Divider()
                AdvancedSection(model: model)
            }
            .padding(14)
            if let toast = model.toast {
                ToastBar(text: toast)
            }
        }
    }
}

// MARK: - Header

struct HeaderView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "display")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("RDP 远程桌面")
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 6, height: 6)
                    Text(model.snapshot.state.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if model.snapshot.isBusy {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                            .frame(width: 12, height: 12)
                    }
                }
            }
            Spacer(minLength: 6)
            Button {
                Task { await model.toggleService() }
            } label: {
                HStack(spacing: 5) {
                    if model.isWorking {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.65)
                            .frame(width: 11, height: 11)
                    }
                    Text(model.toggleTitle)
                        .font(.system(size: 11.5, weight: .medium))
                }
                .frame(minWidth: 46)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(model.snapshot.state.isRunning ? .red : .accentColor)
            .disabled(model.isToggleDisabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var stateColor: Color {
        switch model.snapshot.state {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .error: return .red
        case .disabled: return Color(nsColor: .tertiaryLabelColor)
        }
    }
}

// MARK: - Banners

struct ErrorBanner: View {
    let message: String
    let onOpenLogs: () -> Void
    let onCopy: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 10.5))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                // Selectable so the user can copy just the failing detail.
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button("复制", action: onCopy)
                .buttonStyle(.borderless)
                .font(.system(size: 10.5))
            Button("打开日志", action: onOpenLogs)
                .buttonStyle(.borderless)
                .font(.system(size: 10.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

struct RestartBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
            Text("设置已保存，重启服务后生效")
                .font(.system(size: 10.5))
            Spacer(minLength: 4)
            Button("立即重启") {
                Task { await model.restartService() }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10.5))
            .disabled(model.isWorking)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

struct ToastBar: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Sections

struct ConnectionSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("连接地址")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.snapshot.displayAddress)
                    .font(.system(size: 16.5, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(model.snapshot.state.isRunning ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                Button {
                    model.copyAddress()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text(model.snapshot.state.isRunning
                 ? "用 Windows App 或 mstsc 连接此地址，用户名 \(model.snapshot.principalDisplay)。"
                 : "启用服务后监听此地址，用户名 \(model.snapshot.principalDisplay)。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
                .padding(.vertical, 1)
            HStack(spacing: 8) {
                Toggle(isOn: lanBinding) {
                    Text("允许局域网访问")
                        .font(.system(size: 12))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(model.isWorking)
                Spacer(minLength: 0)
                Text(model.snapshot.allowLAN ? "仅限可信私有网络" : "当前仅本机可连")
                    .font(.system(size: 10))
                    .foregroundStyle(model.snapshot.allowLAN ? Color.orange : Color.secondary)
            }
            Text(lanHint)
                .font(.system(size: 10))
                .foregroundStyle(model.snapshot.allowLAN ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lanBinding: Binding<Bool> {
        Binding(
            get: { model.snapshot.allowLAN },
            set: { newValue in
                Task { await model.setAllowLAN(newValue) }
            }
        )
    }

    private var lanHint: String {
        if model.snapshot.allowLAN {
            return "同一局域网 / Tailscale 内的设备可访问 \(model.snapshot.displayAddress)。仅限可信私有网络，不要暴露到公网。"
        }
        return "当前仅本机可连；Windows 客户端连接请打开「局域网访问」。"
    }
}

struct CaptureSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                SectionHeader("桌面采集")
                Spacer(minLength: 4)
                Circle()
                    .fill(agentColor)
                    .frame(width: 6, height: 6)
                Text(model.snapshot.agentState.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(agentColor)
            }
            HStack(spacing: 5) {
                Text(model.snapshot.permissionSummary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(model.snapshot.permissions.allGranted ? Color.secondary : Color.orange)
                if let detail = model.snapshot.agentDetail, !detail.isEmpty {
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var agentColor: Color {
        switch model.snapshot.agentState {
        case .waiting: return Color(nsColor: .tertiaryLabelColor)
        case .capturing: return .green
        case .failed: return .red
        }
    }
}

struct PermissionSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader("权限")
            PermissionRow(name: "屏幕录制",
                          granted: model.snapshot.permissions.screenRecording,
                          pane: .screenRecording,
                          model: model)
            PermissionRow(name: "辅助功能",
                          granted: model.snapshot.permissions.accessibility,
                          pane: .accessibility,
                          model: model)
            // The core does not expose a Full Disk Access probe, so this row is
            // informational only: no fake "检测" status, just the settings link.
            PermissionRow(name: "完全磁盘访问",
                          granted: nil,
                          pane: .fullDiskAccess,
                          model: model)
            Text("首次授权会为 RDPAgent 弹出系统权限窗口；授权后需重启采集才会生效。完全磁盘访问为可选项：从桌面/下载等受保护目录复制文件到 Windows 时需要。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PermissionRow: View {
    let name: String
    /// nil means "not detected": informational row, settings link only.
    let granted: Bool?
    let pane: UIPrivacyPane
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(iconColor)
                Text(name)
                    .font(.system(size: 12))
                Spacer(minLength: 4)
                Text(statusText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(statusColor)
            }
            if granted != true {
                HStack(spacing: 12) {
                    if granted == false {
                        Button("请求权限") {
                            Task { await model.requestPermissions() }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10.5))
                    }
                    Button("打开系统设置") {
                        model.openPrivacySettings(pane)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5))
                }
                .padding(.leading, 18)
            }
        }
    }

    private var iconName: String {
        guard let granted else { return "info.circle" }
        return granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var iconColor: Color {
        guard let granted else { return Color(nsColor: .tertiaryLabelColor) }
        return granted ? .green : .orange
    }

    private var statusText: String {
        guard let granted else { return "可选" }
        return granted ? "已授权" : "未授权"
    }

    private var statusColor: Color {
        guard let granted else { return Color.secondary }
        return granted ? .green : .orange
    }
}

struct AccountSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader("账号")
            HStack(spacing: 8) {
                Text(model.snapshot.principalDisplay)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Button("修改用户名和密码") {
                    model.beginCredentialEdit()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10.5))
            }
        }
    }
}

struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}