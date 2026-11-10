import Foundation
import Darwin

/// Identity of the Worker process spawned by this app.
///
/// The app writes one lease immediately after `Process.run()` and removes it on
/// stop/exit. If the app crashes or is SIGKILLed, the next start uses the lease
/// (and a command-line scan as a fallback) to terminate the old Worker before
/// spawning a replacement. The start time plus executable path guard against
/// PID reuse; only a process with the exact identity is signalled.
struct WorkerLease: Codable, Equatable, Sendable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executablePath: String

    static func capture(pid: Int32) -> WorkerLease? {
        guard let info = processInfo(pid: pid), info.pbi_uid == geteuid() else {
            return nil
        }
        guard let path = executablePath(pid: pid) else { return nil }
        return WorkerLease(pid: pid,
                           startSeconds: info.pbi_start_tvsec,
                           startMicroseconds: info.pbi_start_tvusec,
                           executablePath: path)
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SecureFileError.io("worker lease is not valid UTF-8")
        }
        try SecureFile.writeString(text + "\n", to: url, mode: 0o600)
    }

    static func read(from url: URL) -> WorkerLease? {
        guard SecureFile.isOwnedRegularFile(url, mode: 0o600),
              let text = try? SecureFile.readString(at: url, maxBytes: 4096),
              let data = text.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(WorkerLease.self, from: data)
    }

    /// True when this exact process (PID + start time) still exists.
    func isRunning() -> Bool {
        guard let info = Self.processInfo(pid: pid) else { return false }
        return info.pbi_start_tvsec == startSeconds
            && info.pbi_start_tvusec == startMicroseconds
            && info.pbi_uid == geteuid()
    }

    static func processInfo(pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return info
    }

    static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        return path.hasPrefix("/") ? path : nil
    }
}

/// Stops Workers left behind by an app crash/SIGKILL before a new start.
///
/// The primary source is `<data>/worker.lease`. A read-only `/bin/ps` scan is
/// the fallback for a Worker started before leases existed or when the lease
/// could not be written. The scan only accepts processes whose executable is
/// named `rdp-worker`, whose UID is ours, and whose command line contains the
/// exact `-config <our config.json>` argument.
enum StaleWorkerCleanup {
    struct Outcome: Equatable, Sendable {
        let found: Int
        let forced: Int
        let remaining: [Int32]

        var succeeded: Bool { remaining.isEmpty }
    }

    static func run(leaseURL: URL,
                    configPath: String,
                    graceSeconds: Double,
                    logger: (String) -> Void) -> Outcome {
        var identities: [Int32: WorkerLease] = [:]
        let leaseURLExists = SecureFile.exists(leaseURL)

        if let lease = WorkerLease.read(from: leaseURL) {
            if lease.isRunning(), WorkerLease.executablePath(pid: lease.pid) == lease.executablePath {
                identities[lease.pid] = lease
                logger("event=stale_worker_detected source=lease pid=\(lease.pid)")
            } else {
                logger("event=stale_worker_skipped source=lease reason=identity_mismatch")
            }
        } else if leaseURLExists {
            logger("event=stale_worker_skipped source=lease reason=unreadable")
        }

        if let scanned = scan(configPath: configPath) {
            for lease in scanned where identities[lease.pid] == nil {
                identities[lease.pid] = lease
                logger("event=stale_worker_detected source=scan pid=\(lease.pid)")
            }
        } else {
            logger("event=stale_worker_scan_failed")
        }

        if identities.isEmpty {
            if leaseURLExists { SecureFile.removeIfPresent(leaseURL) }
            return Outcome(found: 0, forced: 0, remaining: [])
        }

        var remaining = identities.values.sorted { $0.pid < $1.pid }
        for lease in remaining {
            _ = kill(lease.pid, SIGTERM)
        }
        remaining = waitWhileRunning(remaining, timeout: graceSeconds)

        var forced = 0
        if !remaining.isEmpty {
            for lease in remaining {
                if lease.isRunning() {
                    _ = kill(lease.pid, SIGKILL)
                    forced += 1
                }
            }
            remaining = waitWhileRunning(remaining, timeout: 2)
        }

        if !remaining.isEmpty {
            logger("event=stale_worker_still_running count=\(remaining.count)")
        } else {
            // Keep the lease when a process survived SIGKILL so the next
            // attempt still has the exact identity to retry.
            SecureFile.removeIfPresent(leaseURL)
        }
        logger("event=stale_worker_terminated count=\(identities.count) forced=\(forced) remaining=\(remaining.count)")
        return Outcome(found: identities.count, forced: forced,
                       remaining: remaining.map(\.pid))
    }

    private static func waitWhileRunning(_ leases: [WorkerLease], timeout: Double) -> [WorkerLease] {
        let deadline = Date().addingTimeInterval(timeout)
        var remaining = leases
        while !remaining.isEmpty && Date() < deadline {
            remaining.removeAll { !$0.isRunning() }
            if remaining.isEmpty { break }
            usleep(50_000)
        }
        return remaining
    }

    /// Returns verified Worker identities using the exact config path argument.
    /// `nil` means the process listing itself failed (the lease path still works).
    static func scan(configPath: String) -> [WorkerLease]? {
        let result = ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/ps"),
                                       arguments: ["-axww", "-o", "pid=,command="],
                                       timeout: 5)
        guard result.launchError == nil, result.exitCode == 0 else { return nil }
        let marker = "-config \(configPath)"
        var found: [WorkerLease] = []
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: " "),
                  let pid = Int32(trimmed[..<separator]) else {
                continue
            }
            let command = String(trimmed[trimmed.index(after: separator)...])
            guard let range = command.range(of: marker) else { continue }
            let tail = command[range.upperBound...]
            guard tail.isEmpty || tail.first == " " else { continue }
            guard let lease = WorkerLease.capture(pid: pid) else { continue }
            guard URL(fileURLWithPath: lease.executablePath).lastPathComponent == "rdp-worker" else {
                continue
            }
            if !found.contains(where: { $0.pid == pid }) { found.append(lease) }
        }
        return found
    }
}
