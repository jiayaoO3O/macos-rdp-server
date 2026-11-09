import Foundation

/// Client-side mirror of the core validation rules so the credential editor can
/// show inline errors instantly. The core re-validates and is authoritative;
/// these strings are the single source of the Chinese messages.
enum CredentialRules {
    /// 1...64 characters, lowercase letters / digits / '.', '_', '-'.
    static func usernameError(_ raw: String) -> String? {
        let username = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if username.isEmpty { return "请输入用户名" }
        if username.count > 64 { return "用户名最多 64 个字符" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        if username.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "用户名只能使用小写字母、数字或 . _ -"
        }
        return nil
    }

    /// Non-empty and at most 4095 UTF-8 bytes (WinPR/NT-hash input bound).
    static func passwordError(_ password: String) -> String? {
        if password.isEmpty { return "请输入密码" }
        if password.utf8.count > 4095 { return "密码过长（最多 4095 字节）" }
        return nil
    }

    static func confirmError(password: String, confirm: String) -> String? {
        if confirm.isEmpty { return "请再次输入密码" }
        if password != confirm { return "两次输入的密码不一致" }
        return nil
    }

    static func portError(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed) else { return "端口必须是数字" }
        if port < 1024 || port > 65535 { return "端口需在 1024–65535 之间" }
        return nil
    }
}
