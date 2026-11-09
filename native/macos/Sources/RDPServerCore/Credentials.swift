import Foundation

/// Account + NT-hash credential storage.
///
/// The NT hash is produced by the rdpctl helper reading the password from
/// stdin, so the plaintext password never touches argv, the filesystem or any
/// log line. Only the hash is persisted, in the worker's SAM format.
public struct CredentialsManager: Sendable {
    public let paths: ServerPaths
    public let helpers: HelperLocator

    public init(paths: ServerPaths, helpers: HelperLocator) {
        self.paths = paths
        self.helpers = helpers
    }

    public func samExists() -> Bool {
        SecureFile.isOwnedRegularFile(paths.samFile, mode: 0o600) && SecureFile.fileSize(at: paths.samFile) > 0
    }

    /// Bare account name from the stored SAM file, nil when absent or invalid.
    public func storedAccount() -> String? {
        guard samExists(), let text = try? SecureFile.readString(at: paths.samFile, maxBytes: 64 << 10) else {
            return nil
        }
        guard let firstLine = text.split(separator: "\n").first else { return nil }
        let fields = firstLine.split(separator: ":", omittingEmptySubsequences: false)
        guard let raw = fields.first else { return nil }
        let account = String(raw)
        guard CredentialsManager.validateAccount(account) == nil else { return nil }
        return account
    }

    public func save(account: String, password: String) throws {
        if let error = CredentialsManager.validateAccount(account) {
            throw ServerError.credentials(error.description)
        }
        if let error = CredentialsManager.validatePassword(password) {
            throw ServerError.credentials(error.description)
        }
        let hash = try hashPassword(password)
        let line = "\(account):MACRDP::\(hash):\n"
        do {
            try SecureFile.writeString(line, to: paths.samFile, mode: 0o600)
        } catch let error as SecureFileError {
            throw ServerError.credentials(error.description)
        }
    }

    /// Runs "rdpctl hash-stdin" with the password on stdin.
    public func hashPassword(_ password: String) throws -> String {
        guard helpers.rdpctlAvailable else {
            throw ServerError.helperMissing("rdpctl (run make build or use the packaged app)")
        }
        var stdin = Data(password.utf8)
        stdin.append(0x0A)
        let result = ProcessRunner.run(executable: helpers.rdpctlExecutable,
                                       arguments: ["hash-stdin"],
                                       environment: helpers.baseEnvironment,
                                       stdin: stdin,
                                       timeout: 10)
        if let launchError = result.launchError {
            throw ServerError.credentials("rdpctl could not be started: \(launchError)")
        }
        guard !result.timedOut else {
            throw ServerError.credentials("rdpctl hash-stdin timed out")
        }
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ServerError.credentials("rdpctl hash-stdin failed (status \(result.exitCode))\(detail.isEmpty ? "" : ": " + detail)")
        }
        let hash = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CredentialsManager.isValidNTHash(hash) else {
            throw ServerError.credentials("rdpctl returned an invalid NT hash")
        }
        return hash
    }

    public static func isValidNTHash(_ value: String) -> Bool {
        guard value.count == 32 else { return false }
        for scalar in value.unicodeScalars {
            let code = scalar.value
            let isDigit = code >= 48 && code <= 57
            let isLowerHex = code >= 97 && code <= 102
            guard isDigit || isLowerHex else { return false }
        }
        return true
    }

    /// Lowercase bare MACRDP principal: [a-z0-9_.-]{1,64}.
    public static func validateAccount(_ value: String) -> CredentialValidationError? {
        guard (1...64).contains(value.utf8.count) else { return .usernameInvalid }
        for scalar in value.unicodeScalars {
            let code = scalar.value
            let isLower = code >= 97 && code <= 122
            let isDigit = code >= 48 && code <= 57
            let isSeparator = code == 95 || code == 46 || code == 45
            guard isLower || isDigit || isSeparator else { return .usernameInvalid }
        }
        return nil
    }

    /// Passwords are an independent RDP test credential, never the macOS one.
    public static func validatePassword(_ value: String) -> CredentialValidationError? {
        guard !value.isEmpty else { return .passwordInvalid }
        guard !value.contains("\n") && !value.contains("\u{0}") else { return .passwordInvalid }
        guard value.utf8.count <= 4095 else { return .passwordTooLong }
        return nil
    }
}
