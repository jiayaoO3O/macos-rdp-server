import Foundation

/// Self-signed TLS material for the Worker.
///
/// The system /usr/bin/openssl is LibreSSL: its x509 subcommand does not accept
/// -addext or -ext, so the subjectAltName extension is supplied through a
/// temporary configuration file instead. Certificates are regenerated when the
/// set of IP addresses clients may connect to changes (loopback plus the current
/// private LAN addresses).
public struct CertificateManager: Sendable {
    public let paths: ServerPaths

    public init(paths: ServerPaths) {
        self.paths = paths
    }

    /// Addresses the app wants in the certificate: 127.0.0.1 plus eligible LAN
    /// IPv4s (deduplicated, loopback first).
    public static func desiredAddresses(includeLAN: Bool) -> [String] {
        var addresses = ["127.0.0.1"]
        if includeLAN {
            for address in LANAddress.privateIPv4Addresses() where !addresses.contains(address) {
                addresses.append(address)
            }
        }
        return addresses
    }

    /// Ensures cert.pem/key.pem exist and cover the requested addresses.
    @discardableResult
    public func ensure(addresses: [String]) throws -> [String] {
        let normalized = CertificateManager.normalize(addresses)
        if let current = sanAddresses(), Set(current) == Set(normalized) {
            return normalized
        }
        return try regenerate(addresses: normalized)
    }

    @discardableResult
    public func regenerate(addresses: [String]) throws -> [String] {
        let normalized = CertificateManager.normalize(addresses)
        let configURL = paths.dataDirectory.appendingPathComponent(
            ".openssl-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).cnf")
        let keyTemporary = paths.dataDirectory.appendingPathComponent(
            ".key.pem.tmp.\(getpid()).\(UInt32.random(in: 0...UInt32.max))")
        let certificateTemporary = paths.dataDirectory.appendingPathComponent(
            ".cert.pem.tmp.\(getpid()).\(UInt32.random(in: 0...UInt32.max))")
        defer {
            SecureFile.removeIfPresent(configURL)
            SecureFile.removeIfPresent(keyTemporary)
            SecureFile.removeIfPresent(certificateTemporary)
        }

        let sanList = normalized.map { "IP:\($0)" }.joined(separator: ",")
        let config = """
        [req]
        distinguished_name = req_distinguished_name
        x509_extensions = v3_req
        prompt = no

        [req_distinguished_name]
        CN = localhost

        [v3_req]
        basicConstraints = CA:FALSE
        keyUsage = digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = \(sanList)
        """
        do {
            try SecureFile.writeString(config, to: configURL, mode: 0o600)
        } catch let error as SecureFileError {
            throw ServerError.certificate(error.description)
        }

        guard helpersAvailable else {
            throw ServerError.helperMissing("/usr/bin/openssl")
        }
        let result = ProcessRunner.run(
            executable: HelperLocator.opensslExecutable,
            arguments: [
                "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
                "-keyout", keyTemporary.path,
                "-out", certificateTemporary.path,
                "-days", "365",
                "-subj", "/CN=localhost",
                "-config", configURL.path,
            ],
            environment: ["PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory()],
            timeout: 30)
        if let launchError = result.launchError {
            throw ServerError.certificate("openssl could not be started: \(launchError)")
        }
        guard !result.timedOut else {
            throw ServerError.certificate("openssl certificate generation timed out")
        }
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ServerError.certificate("openssl certificate generation failed\(detail.isEmpty ? "" : ": " + detail)")
        }
        guard SecureFile.isRegularFile(keyTemporary), SecureFile.fileSize(at: keyTemporary) > 256,
              SecureFile.isRegularFile(certificateTemporary), SecureFile.fileSize(at: certificateTemporary) > 256 else {
            throw ServerError.certificate("openssl produced an unusable certificate")
        }
        do {
            try SecureFile.setMode(keyTemporary, mode: 0o600)
            try SecureFile.setMode(certificateTemporary, mode: 0o600)
        } catch let error as SecureFileError {
            throw ServerError.certificate(error.description)
        }
        guard rename(keyTemporary.path, paths.keyFile.path) == 0,
              rename(certificateTemporary.path, paths.certificateFile.path) == 0 else {
            throw ServerError.certificate("cannot install generated certificate: errno \(errno)")
        }
        do {
            try SecureFile.writeString(normalized.joined(separator: "\n") + "\n",
                                       to: paths.certificateAddressesFile,
                                       mode: 0o600)
        } catch let error as SecureFileError {
            throw ServerError.certificate(error.description)
        }
        return normalized
    }

    /// Addresses present in the current certificate, nil when it cannot be read.
    public func sanAddresses() -> [String]? {
        guard SecureFile.isRegularFile(paths.certificateFile),
              SecureFile.isRegularFile(paths.keyFile),
              SecureFile.fileSize(at: paths.certificateFile) > 0 else {
            return nil
        }
        let result = ProcessRunner.run(
            executable: HelperLocator.opensslExecutable,
            arguments: ["x509", "-in", paths.certificateFile.path, "-noout", "-text"],
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 10)
        guard !result.timedOut, result.exitCode == 0 else { return nil }
        let addresses = CertificateManager.parseIPAddresses(from: result.stdout)
        guard !addresses.isEmpty else { return nil }
        return addresses
    }

    /// Extracts IPv4 subjectAltName entries from "openssl x509 -text" output.
    public static func parseIPAddresses(from text: String) -> [String] {
        var results: [String] = []
        var remainder = Substring(text)
        while let range = remainder.range(of: "IP Address:") {
            let after = remainder[range.upperBound...]
            let token = after.prefix { $0.isNumber || $0 == "." }
            if !token.isEmpty, LANAddress.isValidIPv4(String(token)) {
                results.append(String(token))
            }
            remainder = after
        }
        return results
    }

    public static func normalize(_ addresses: [String]) -> [String] {
        var result: [String] = ["127.0.0.1"]
        for address in addresses where LANAddress.isValidIPv4(address) && !result.contains(address) {
            result.append(address)
        }
        return result
    }

    private var helpersAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: HelperLocator.opensslExecutable.path)
    }
}
