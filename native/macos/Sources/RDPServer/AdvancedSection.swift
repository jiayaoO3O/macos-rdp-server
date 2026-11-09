import SwiftUI

/// 高级 section: port, stuck-key release, logs, quit. Collapsed by default so
/// the common case stays short. The LAN toggle lives in the main area (it is the
/// primary connect path for Windows clients). All mutable state lives in
/// AppModel because the CLT-only toolchain has no SwiftUIMacros plugin.
struct AdvancedSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        DisclosureGroup(isExpanded: expandedBinding) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Text("端口")
                        .font(.system(size: 12))
                    TextField("3389", text: portBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 66)
                        .controlSize(.small)
                        .onSubmit { applyPort() }
                    Button("应用") { applyPort() }
                        .controlSize(.small)
                        .disabled(model.isWorking || model.snapshot.state.isBusy)
                    Spacer(minLength: 0)
                    Text("1024–65535")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if let portError = model.portError {
                    Text(portError)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if model.snapshot.legacyLaunchAgentInstalled {
                    Text("检测到旧版后台代理（LaunchAgent），建议卸载后改用 App 管理（见 docs/STATUS-2026-11-08.md）。")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                HStack(spacing: 8) {
                    Button {
                        model.openLogs()
                    } label: {
                        Label("打开日志", systemImage: "folder")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                    Spacer(minLength: 0)
                    Button("退出") { model.quit() }
                        .controlSize(.small)
                }
            }
            .padding(.top, 8)
            .padding(.leading, 2)
        } label: {
            Text("高级")
                .font(.system(size: 12, weight: .medium))
        }
        .onAppear {
            if model.portText.isEmpty {
                model.portText = String(model.snapshot.port)
            }
        }
    }

    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { model.advancedExpanded },
            set: { model.advancedExpanded = $0 }
        )
    }

    private var portBinding: Binding<String> {
        Binding(
            get: { model.portText },
            set: { model.portText = $0 }
        )
    }

    private func applyPort() {
        if let message = CredentialRules.portError(model.portText) {
            model.portError = message
            return
        }
        guard let port = Int(model.portText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        model.portError = nil
        Task { await model.setPort(port) }
    }
}
