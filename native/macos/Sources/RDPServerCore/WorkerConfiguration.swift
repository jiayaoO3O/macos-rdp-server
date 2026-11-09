import Foundation

/// Worker configuration, mirroring internal/config/config.go one-to-one.
///
/// The Go loader rejects unknown fields and requires absolute credential paths
/// inside the private data directory, so the JSON written here must match the
/// struct exactly.
public struct ServerConfiguration: Codable, Equatable, Sendable {
    public var address: String
    public var allowLAN: Bool
    public var port: Int
    public var account: String
    public var enabled: Bool
    public var testPattern: Bool
    public var clipboard: Bool
    public var certificate: String
    public var key: String
    public var sam: String

    public enum CodingKeys: String, CodingKey {
        case address
        case allowLAN = "allow_lan"
        case port
        case account
        case enabled
        case testPattern = "test_pattern"
        case clipboard
        case certificate
        case key
        case sam
    }

    public static let defaultPort = 3389

    public init(address: String,
                allowLAN: Bool,
                port: Int,
                account: String,
                enabled: Bool,
                testPattern: Bool,
                clipboard: Bool,
                certificate: String,
                key: String,
                sam: String) {
        self.address = address
        self.allowLAN = allowLAN
        self.port = port
        self.account = account
        self.enabled = enabled
        self.testPattern = testPattern
        self.clipboard = clipboard
        self.certificate = certificate
        self.key = key
        self.sam = sam
    }

    /// Product defaults for the menu bar app: loopback, live desktop (no test
    /// pattern) and clipboard enabled.
    public static func defaults(for paths: ServerPaths) -> ServerConfiguration {
        ServerConfiguration(
            address: "127.0.0.1",
            allowLAN: false,
            port: ServerConfiguration.defaultPort,
            account: "",
            enabled: true,
            testPattern: false,
            clipboard: true,
            certificate: paths.certificateFile.path,
            key: paths.keyFile.path,
            sam: paths.samFile.path)
    }

    public var addressMode: AddressMode {
        if address == "auto" || (address != "127.0.0.1" && allowLAN) {
            return .lan
        }
        return .loopback
    }

    public mutating func applyAddressMode(_ mode: AddressMode) {
        switch mode {
        case .loopback:
            address = "127.0.0.1"
            allowLAN = false
        case .lan:
            address = "auto"
            allowLAN = true
        }
    }

    /// Mirrors the Go validation rules that the app can influence. Returns a
    /// user-facing message or nil when the configuration is startable.
    public func validationError() -> String? {
        if port < 1024 || port > 65535 {
            return "port must be 1024...65535"
        }
        if address == "auto" {
            if !allowLAN { return "address auto requires allow_lan=true" }
        } else if address == "127.0.0.1" {
            // loopback is always allowed
        } else if allowLAN, LANAddress.isPrivateIPv4(address) {
            // explicit private LAN address (legacy configuration)
        } else {
            return "address must be 127.0.0.1 or an explicitly enabled private IPv4"
        }
        if !account.isEmpty {
            if let error = CredentialsManager.validateAccount(account) {
                return error.description
            }
        }
        for path in [certificate, key, sam] where !path.hasPrefix("/") {
            return "credential paths must be absolute"
        }
        return nil
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}

/// Reads and writes config.json atomically with 0600 permissions.
public struct ConfigurationStore: Sendable {
    public let paths: ServerPaths

    public init(paths: ServerPaths) {
        self.paths = paths
    }

    public enum StoreError: Error, CustomStringConvertible, Sendable {
        case invalid(String)
        case writeFailed(String)

        public var description: String {
            switch self {
            case .invalid(let message): return message
            case .writeFailed(let message): return message
            }
        }
    }

    public func exists() -> Bool {
        SecureFile.exists(paths.configFile)
    }

    public func loadData() -> Data? {
        try? SecureFile.readData(at: paths.configFile)
    }

    public func loadIfPresent() throws -> ServerConfiguration? {
        guard SecureFile.exists(paths.configFile) else { return nil }
        let data = try SecureFile.readData(at: paths.configFile)
        do {
            return try JSONDecoder().decode(ServerConfiguration.self, from: data)
        } catch {
            throw StoreError.invalid("configuration file is not valid JSON: \(error.localizedDescription)")
        }
    }

    public func loadOrDefault() throws -> ServerConfiguration {
        var configuration = try loadIfPresent() ?? ServerConfiguration.defaults(for: paths)
        // Fill in paths/account that the app owns even if the file predates them.
        if configuration.certificate.isEmpty { configuration.certificate = paths.certificateFile.path }
        if configuration.key.isEmpty { configuration.key = paths.keyFile.path }
        if configuration.sam.isEmpty { configuration.sam = paths.samFile.path }
        if configuration.port == 0 { configuration.port = ServerConfiguration.defaultPort }
        return configuration
    }

    public func save(_ configuration: ServerConfiguration) throws {
        if let error = configuration.validationError() {
            throw StoreError.invalid(error)
        }
        do {
            let data = try configuration.jsonData()
            try SecureFile.writeAtomically(data, to: paths.configFile, mode: 0o600)
        } catch let error as SecureFileError {
            throw StoreError.writeFailed(error.description)
        }
    }
}
