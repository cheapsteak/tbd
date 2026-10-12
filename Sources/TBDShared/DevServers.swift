import Darwin
import Foundation

// Dev servers: repo-declared, TBD-run, file-reported.
// docs/specs/2026-10-11-dev-servers-design.md

/// One named, absolute URL a running server can be reached at.
public struct DevServerEndpoint: Codable, Sendable, Equatable {
    public var name: String
    public var url: String
    public init(name: String, url: String) { self.name = name; self.url = url }
}

/// Which file declared a server. Later sources replace earlier ones by name.
public enum DevServerSource: String, Codable, Sendable, Equatable, CaseIterable {
    case launchJSON = "launch.json"
    case repoTOML = "tbd.toml"
    case userTOML = "servers.toml"
}

/// A server as a repo (or its user) declared it.
public struct DeclaredDevServer: Codable, Sendable, Equatable {
    public var name: String
    /// Run with `sh -c`.
    public var command: String
    /// Relative to the worktree root; nil means the root itself.
    public var cwd: String?
    public var env: [String: String]
    public var label: String?
    /// Replaces the process-group kill when present.
    public var stop: String?
    /// Exit 0 means running. Never parsed for URLs.
    public var status: String?
    public var source: DevServerSource

    public init(name: String, command: String, cwd: String? = nil, env: [String: String] = [:],
                label: String? = nil, stop: String? = nil, status: String? = nil,
                source: DevServerSource) {
        self.name = name; self.command = command; self.cwd = cwd; self.env = env
        self.label = label; self.stop = stop; self.status = status; self.source = source
    }

    public var displayLabel: String { label ?? name }

    /// Lowercase letters, digits and `-`, non-empty.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
    }

    /// Layers sources by name: a server in a later source replaces the
    /// same-named server from an earlier one as a whole and takes its
    /// position; servers with other names are kept from every source, in
    /// order of first appearance.
    public static func layered(_ sources: [[DeclaredDevServer]]) -> [DeclaredDevServer] {
        var order: [String] = []
        var byName: [String: DeclaredDevServer] = [:]
        for source in sources {
            for server in source {
                if byName[server.name] == nil { order.append(server.name) }
                byName[server.name] = server
            }
        }
        return order.compactMap { byName[$0] }
    }
}

/// A declaration source that failed to parse, or one entry in it that did.
public struct DevServerParseError: Codable, Sendable, Equatable {
    public var path: String
    public var message: String
    public init(path: String, message: String) { self.path = path; self.message = message }
}

/// A worktree's declared servers after layering, plus every parse error.
public struct DevServerDeclarations: Sendable, Equatable {
    public var servers: [DeclaredDevServer]
    public var errors: [DevServerParseError]
    public init(servers: [DeclaredDevServer], errors: [DevServerParseError]) {
        self.servers = servers; self.errors = errors
    }
}

/// The running file: how a server tells TBD it is up and where it is.
/// Never carries a command, and TBD executes nothing read from one.
public struct DevServerRunningFile: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    /// Absolute worktree path; attributes the file to a worktree.
    public var root: String
    public var server: String
    /// First endpoint is the server's main URL.
    public var endpoints: [DevServerEndpoint]
    public var pid: Int32
    /// Unix seconds.
    public var startTime: Double

    public init(version: Int = DevServerRunningFile.currentVersion, root: String, server: String,
                endpoints: [DevServerEndpoint], pid: Int32, startTime: Double) {
        self.version = version; self.root = root; self.server = server
        self.endpoints = endpoints; self.pid = pid; self.startTime = startTime
    }
}

public struct DevServerRunningFileEntry: Sendable, Equatable {
    public var path: String
    public var file: DevServerRunningFile
    public var modifiedAt: Date?
    public init(path: String, file: DevServerRunningFile, modifiedAt: Date?) {
        self.path = path; self.file = file; self.modifiedAt = modifiedAt
    }
}

/// A file in the directory that was not a usable running file.
public struct DevServerRunningFileDiagnostic: Codable, Sendable, Equatable {
    public var path: String
    public var problem: String
    public init(path: String, problem: String) { self.path = path; self.problem = problem }
}

public struct DevServerRunningFileScan: Sendable, Equatable {
    public var entries: [DevServerRunningFileEntry]
    public var diagnostics: [DevServerRunningFileDiagnostic]
    public init(entries: [DevServerRunningFileEntry], diagnostics: [DevServerRunningFileDiagnostic]) {
        self.entries = entries; self.diagnostics = diagnostics
    }
}

public enum DevServerRunningFileProblem: LocalizedError, Sendable, Equatable {
    case malformed(String)
    case unsupportedVersion(Int)

    public var description: String {
        switch self {
        case .malformed(let detail): return "malformed: \(detail)"
        case .unsupportedVersion(let v): return "unsupported version \(v)"
        }
    }

    public var errorDescription: String? { description }
}

/// What the kernel says about a pid.
public struct DevServerProcessInfo: Sendable, Equatable {
    public var startTime: Date
    public var isZombie: Bool
    public init(startTime: Date, isZombie: Bool) { self.startTime = startTime; self.isZombie = isZombie }
}

/// Injection seam over the kernel read, so liveness is testable without real
/// processes. Production uses `.live`.
public struct DevServerProcessProbe: Sendable {
    public let info: @Sendable (Int32) -> DevServerProcessInfo?
    public init(info: @escaping @Sendable (Int32) -> DevServerProcessInfo?) { self.info = info }

    public static let live = DevServerProcessProbe(info: { DevServerProcessProbe.kernelInfo(pid: $0) })

    /// `SZOMB` from <sys/proc.h>. Spelled as a literal because the macro's
    /// import into Swift is not guaranteed.
    public static let zombieState: Int32 = 5

    /// Start time and zombie state from `sysctl(KERN_PROC_PID)` — the same
    /// read `ProcessStartTime.startTime(pid:)` makes, plus `p_stat`.
    public static func kernelInfo(pid: Int32) -> DevServerProcessInfo? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        guard started.tv_sec > 0 else { return nil }
        let date = Date(timeIntervalSince1970:
            TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
        return DevServerProcessInfo(
            startTime: date, isZombie: Int32(info.kp_proc.p_stat) == zombieState)
    }
}

public enum DevServerLiveness: Sendable, Equatable {
    case live
    case stale(String)
}

/// Reads and writes the shared running-file directory.
public struct DevServerRunningFileStore: Sendable {
    /// How far the kernel's start time may sit from the file's.
    public static let startTimeTolerance: TimeInterval = 1

    public let directory: URL

    public init(directory: URL = TBDConstants.devServersDir()) {
        self.directory = directory
    }

    /// Every `*.json` regular file directly in the directory, decoded.
    /// Hidden files and other extensions are skipped silently; files that do
    /// not decode are named in `diagnostics`. A missing directory is empty.
    public func scan() -> DevServerRunningFileScan {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return DevServerRunningFileScan(entries: [], diagnostics: [])
        }
        var entries: [DevServerRunningFileEntry] = []
        var diagnostics: [DevServerRunningFileDiagnostic] = []
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let path = directory.appendingPathComponent(name).path
            guard let attributes = try? fm.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            guard let data = fm.contents(atPath: path) else {
                diagnostics.append(.init(path: path, problem: "unreadable"))
                continue
            }
            switch Self.decode(data) {
            case .success(let file):
                entries.append(.init(path: path, file: file,
                                     modifiedAt: attributes[.modificationDate] as? Date))
            case .failure(let problem):
                diagnostics.append(.init(path: path, problem: problem.description))
            }
        }
        return DevServerRunningFileScan(entries: entries, diagnostics: diagnostics)
    }

    private struct VersionProbe: Decodable { let version: Int }

    /// Decodes and validates one file. Unknown fields are ignored; a higher
    /// version is `.unsupportedVersion`, never a best-effort read.
    public static func decode(_ data: Data) -> Result<DevServerRunningFile, DevServerRunningFileProblem> {
        let decoder = JSONDecoder()
        let version: Int
        do {
            version = try decoder.decode(VersionProbe.self, from: data).version
        } catch {
            return .failure(.malformed("no readable version: \(error.localizedDescription)"))
        }
        guard version <= DevServerRunningFile.currentVersion else {
            return .failure(.unsupportedVersion(version))
        }
        let file: DevServerRunningFile
        do {
            file = try decoder.decode(DevServerRunningFile.self, from: data)
        } catch {
            return .failure(.malformed(error.localizedDescription))
        }
        guard file.root.hasPrefix("/") else { return .failure(.malformed("root is not absolute")) }
        guard !file.server.isEmpty else { return .failure(.malformed("server is empty")) }
        guard !file.endpoints.isEmpty else { return .failure(.malformed("no endpoints")) }
        var seenNames: Set<String> = []
        for endpoint in file.endpoints where !seenNames.insert(endpoint.name).inserted {
            return .failure(.malformed("duplicate endpoint name \(endpoint.name)"))
        }
        for endpoint in file.endpoints {
            guard let url = URL(string: endpoint.url), url.scheme != nil, url.host != nil else {
                return .failure(.malformed("endpoint \(endpoint.name) is not an absolute URL"))
            }
        }
        return .success(file)
    }

    /// Live when a process with `pid` exists, is not a zombie, and started
    /// within one second of `startTime`. The start-time check is what makes a
    /// reused pid harmless.
    public static func liveness(of file: DevServerRunningFile, probe: DevServerProcessProbe) -> DevServerLiveness {
        guard file.pid > 0 else { return .stale("pid \(file.pid) is not a process id") }
        guard let info = probe.info(file.pid) else { return .stale("no process \(file.pid)") }
        guard !info.isZombie else { return .stale("process \(file.pid) is a zombie") }
        let delta = abs(info.startTime.timeIntervalSince1970 - file.startTime)
        guard delta <= startTimeTolerance else {
            return .stale("process \(file.pid) started \(Int(delta))s away from the recorded start")
        }
        return .live
    }

    /// Groups entries by the worktree whose path matches their `root`, both
    /// sides normalized. Entries matching no worktree are dropped.
    public static func attribute(
        _ entries: [DevServerRunningFileEntry], worktreePaths: [UUID: String]
    ) -> [UUID: [DevServerRunningFileEntry]] {
        var idByRoot: [String: UUID] = [:]
        for (id, path) in worktreePaths { idByRoot[normalizedRoot(path)] = id }
        var result: [UUID: [DevServerRunningFileEntry]] = [:]
        for entry in entries {
            guard let id = idByRoot[normalizedRoot(entry.file.root)] else { continue }
            result[id, default: []].append(entry)
        }
        return result
    }

    /// Symlinks resolved, `.`/`..` collapsed, no trailing slash. A path that
    /// no longer exists normalizes lexically.
    public static func normalizedRoot(_ path: String) -> String {
        var result = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// `<server>-<16 hex of FNV-1a(normalized root)>.json`. Deterministic so a
    /// re-report overwrites in place.
    public static func fileName(root: String, server: String) -> String {
        let safeServer = String(server.unicodeScalars.map {
            DeclaredDevServer.isValidName(String($0)) ? Character($0) : "_"
        })
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in normalizedRoot(root).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        let padded = String(repeating: "0", count: max(0, 16 - hex.count)) + hex
        return "\(safeServer)-\(padded).json"
    }

    /// Writes atomically (temp file in the same directory, then rename), then
    /// removes any other file describing the same root and server. Returns
    /// the written path.
    @discardableResult
    public func write(_ file: DevServerRunningFile) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        let final = directory.appendingPathComponent(Self.fileName(root: file.root, server: file.server))
        let temp = directory.appendingPathComponent(".\(final.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temp)
        guard Darwin.rename(temp.path, final.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        for entry in scan().entries where entry.path != final.path
            && entry.file.server == file.server
            && Self.normalizedRoot(entry.file.root) == Self.normalizedRoot(file.root) {
            try? fm.removeItem(atPath: entry.path)
        }
        return final.path
    }

    /// Deletes every file describing this root and server. Returns what it
    /// deleted.
    @discardableResult
    public func remove(root: String, server: String) -> [String] {
        let target = Self.normalizedRoot(root)
        var removed: [String] = []
        for entry in scan().entries
        where entry.file.server == server && Self.normalizedRoot(entry.file.root) == target {
            if (try? FileManager.default.removeItem(atPath: entry.path)) != nil {
                removed.append(entry.path)
            }
        }
        return removed
    }
}
