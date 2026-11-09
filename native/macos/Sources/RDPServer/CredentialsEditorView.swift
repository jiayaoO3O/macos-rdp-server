import SwiftUI

/// Credential editor shown inside the popover (a sheet-style page, not a separate
/// NSWindow: SwiftUI sheets inside NSPopover are unreliable on macOS 14).
/// The draft lives in AppModel so no @State macro is needed, and the password is
/// cleared as soon as the editor closes.
struct CredentialsEditorView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text("Windows App / mstsc 登录使用此账号，域固定为 MACRDP。密码是独立的 RDP 测试密码，不是 Mac 登录密码。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            labeledField("用户名") {
                TextField("例如 rdpuser", text: usernameBinding)
                    .textContentType(.username)
            }
            if let message = visibleUsernameError {
                fieldError(message)
            }

            labeledField("密码") {
                SecureField("RDP 测试密码", text: passwordBinding)
                    .onSubmit { save() }
            }
            if let message = visiblePasswordError {
                fieldError(message)
            }

            labeledField("确认密码") {
                SecureField("再次输入密码", text: confirmBinding)
                    .onSubmit { save() }
            }
            if let message = visibleConfirmError {
                fieldError(message)
            }

            if model.snapshot.state.isRunning {
                disconnectWarning
            }

            if let error = model.credentialError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .padding(.top, 1)
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button("复制") { copyToPasteboard(error) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                }
            }

            footer
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            if model.credentialUsername.isEmpty {
                model.credentialUsername = model.snapshot.account
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("修改 RDP 账号密码")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Button {
                model.cancelCredentialEdit()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.borderless)
            .disabled(model.isSavingCredentials)
        }
    }

    private var disconnectWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                Text("保存后服务会重启，当前 RDP 连接会断开。")
                    .font(.system(size: 10.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: acknowledgeBinding) {
                Text("我了解，保存后重启服务")
                    .font(.system(size: 10.5))
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.12)))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("取消") {
                model.cancelCredentialEdit()
            }
            .controlSize(.small)
            .disabled(model.isSavingCredentials)
            Button {
                save()
            } label: {
                HStack(spacing: 5) {
                    if model.isSavingCredentials {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.65)
                            .frame(width: 10, height: 10)
                    }
                    Text(model.snapshot.state.isRunning ? "保存并重启服务" : "保存")
                        .font(.system(size: 11.5, weight: .medium))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canSave || model.isSavingCredentials)
        }
    }

    @ViewBuilder
    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            content()
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .controlSize(.small)
        }
    }

    private func fieldError(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 10))
            .foregroundStyle(.red)
            .textSelection(.enabled)
    }

    private var usernameBinding: Binding<String> {
        Binding(get: { model.credentialUsername }, set: { model.credentialUsername = $0 })
    }
    private var passwordBinding: Binding<String> {
        Binding(get: { model.credentialPassword }, set: { model.credentialPassword = $0 })
    }
    private var confirmBinding: Binding<String> {
        Binding(get: { model.credentialConfirm }, set: { model.credentialConfirm = $0 })
    }
    private var acknowledgeBinding: Binding<Bool> {
        Binding(get: { model.credentialAcknowledgedDisconnect }, set: { model.credentialAcknowledgedDisconnect = $0 })
    }

    private var usernameError: String? { CredentialRules.usernameError(model.credentialUsername) }
    private var passwordError: String? { CredentialRules.passwordError(model.credentialPassword) }
    private var confirmError: String? { CredentialRules.confirmError(password: model.credentialPassword, confirm: model.credentialConfirm) }

    private var visibleUsernameError: String? {
        guard model.credentialSubmitted || !model.credentialUsername.isEmpty else { return nil }
        return usernameError
    }

    private var visiblePasswordError: String? {
        guard model.credentialSubmitted || !model.credentialPassword.isEmpty else { return nil }
        return passwordError
    }

    private var visibleConfirmError: String? {
        guard model.credentialSubmitted || !model.credentialConfirm.isEmpty else { return nil }
        return confirmError
    }

    private var canSave: Bool {
        guard usernameError == nil, passwordError == nil, confirmError == nil else { return false }
        if model.snapshot.state.isRunning && !model.credentialAcknowledgedDisconnect { return false }
        return true
    }

    private func save() {
        model.credentialSubmitted = true
        guard canSave else { return }
        Task { _ = await model.saveCredentials() }
    }
}
