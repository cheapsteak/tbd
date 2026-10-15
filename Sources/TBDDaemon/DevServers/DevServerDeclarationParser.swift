import Foundation
import TBDShared
// Internal so TOMLKit's literal-expressible types stay out of the type
// inference of modules that import this one.
internal import TOMLKit

/// Reads a worktree's declared dev servers from its three sources, fresh on
/// every call (docs/specs/2026-10-11-dev-servers-design.md, "Declaring
/// servers"). A source that fails to parse is reported and contributes
/// nothing; it never hides servers from the other sources.
enum DevServerDeclarationParser {
    typealias Parsed = (servers: [DeclaredDevServer], errors: [DevServerParseError])

    static let launchJSONRelativePath = ".claude/launch.json"
    static let repoTOMLFileName = RepoTOML.fileName

    static func load(
        worktreePath: String,
        repoID: UUID?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DevServerDeclarations {
        var sources: [[DeclaredDevServer]] = []
        var errors: [DevServerParseError] = []
        func ingest(_ path: String, _ parse: (String) -> Parsed) {
            guard FileManager.default.fileExists(atPath: path) else { return }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                errors.append(DevServerParseError(path: path, message: "could not read the file as UTF-8"))
                return
            }
            let parsed = parse(text)
            sources.append(parsed.servers)
            errors.append(contentsOf: parsed.errors)
        }
        let root = URL(fileURLWithPath: worktreePath, isDirectory: true)
        let launchPath = root.appendingPathComponent(launchJSONRelativePath).path
        ingest(launchPath) { parseLaunchJSON($0, worktreeRoot: worktreePath, path: launchPath) }
        let repoPath = root.appendingPathComponent(repoTOMLFileName).path
        ingest(repoPath) { parseTOML($0, source: .repoTOML, path: repoPath) }
        if let repoID {
            let userPath = TBDConstants.serversConfigPath(repoID: repoID, environment: environment)
            ingest(userPath) { parseTOML($0, source: .userTOML, path: userPath) }
        }
        return DevServerDeclarations(servers: DeclaredDevServer.layered(sources), errors: errors)
    }

    // MARK: - TOML (tbd.toml, servers.toml)

    static func parseTOML(_ text: String, source: DevServerSource, path: String) -> Parsed {
        let table: TOMLTable
        do {
            table = try TOMLTable(string: text)
        } catch let error as TOMLParseError {
            return ([], [DevServerParseError(path: path, message: error.debugDescription)])
        } catch {
            return ([], [DevServerParseError(path: path, message: String(describing: error))])
        }
        guard let serversValue = table["servers"] else { return ([], []) }
        guard let serversTable = serversValue.table else {
            return ([], [DevServerParseError(
                path: path, message: "`servers` must be a table of [servers.<name>] sections")])
        }
        var servers: [DeclaredDevServer] = []
        var errors: [DevServerParseError] = []
        func fail(_ message: String) { errors.append(DevServerParseError(path: path, message: message)) }

        // TOMLKit hands keys back sorted; servers keep the file's order.
        let order = tomlServerOrder(text)
        let names = serversTable.keys.sorted { lhs, rhs in
            switch (order[lhs], order[rhs]) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs < rhs
            }
        }
        for name in names {
            guard DeclaredDevServer.isValidName(name) else {
                fail("server name \"\(name)\" must use only lowercase letters, digits and -")
                continue
            }
            guard let entry = serversTable[name]?.table else {
                fail("[servers.\(name)] must be a table")
                continue
            }
            guard let command = entry["command"]?.string,
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                fail("[servers.\(name)] needs a non-empty `command` string")
                continue
            }
            func optionalString(_ key: String) -> String? {
                guard let value = entry[key] else { return nil }
                guard let string = value.string else {
                    fail("[servers.\(name)] `\(key)` must be a string; ignored")
                    return nil
                }
                return string
            }
            var server = DeclaredDevServer(name: name, command: command, source: source)
            server.label = optionalString("label")
            server.stop = optionalString("stop")
            server.status = optionalString("status")
            if let cwd = optionalString("cwd") {
                guard isContainedRelativePath(cwd) else {
                    fail("[servers.\(name)] `cwd` must be a path inside the worktree, relative to its root")
                    continue
                }
                server.cwd = cwd.isEmpty || cwd == "." ? nil : cwd
            }
            if let envValue = entry["env"] {
                if let envTable = envValue.table {
                    for key in envTable.keys {
                        guard isValidEnvironmentKey(key) else {
                            fail("[servers.\(name)] env key \"\(key)\" is not a valid variable name; ignored")
                            continue
                        }
                        if let value = envTable[key]?.string {
                            server.env[key] = value
                        } else {
                            fail("[servers.\(name)] env.\(key) must be a string; ignored")
                        }
                    }
                } else {
                    fail("[servers.\(name)] `env` must be a table; ignored")
                }
            }
            servers.append(server)
        }
        return (servers, errors)
    }

    /// Each server name's rank by where the file first names it: a
    /// `[servers.<name>]` header, a key inside `[servers]`, or a top-level
    /// `servers.<name>` dotted key. A line scan, not a parse — the parse has
    /// already succeeded, and a name this misses sorts after the found ones.
    static func tomlServerOrder(_ text: String) -> [String: Int] {
        var order: [String: Int] = [:]
        func note(_ name: Substring) {
            let key = String(name)
            if order[key] == nil { order[key] = order.count }
        }
        func isBlank(_ c: Character) -> Bool { c == " " || c == "\t" }
        /// The bare or quoted key `s` starts with.
        func firstKey(_ s: Substring) -> Substring? {
            var rest = s.drop(while: isBlank)
            if rest.first == "\"" || rest.first == "'" {
                let quote = rest.removeFirst()
                guard let end = rest.firstIndex(of: quote) else { return nil }
                return rest[..<end]
            }
            let key = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            return key.isEmpty ? nil : key
        }
        /// What follows `servers` in `s`, blanks skipped; nil when `s` does
        /// not start with `servers`.
        func afterServers(_ s: Substring) -> Substring? {
            let trimmed = s.drop(while: isBlank)
            guard trimmed.hasPrefix("servers") else { return nil }
            return trimmed.dropFirst("servers".count).drop(while: isBlank)
        }
        /// `servers.<key>` → `<key>`.
        func serverKey(_ s: Substring) -> Substring? {
            guard let rest = afterServers(s), rest.first == "." else { return nil }
            return firstKey(rest.dropFirst())
        }
        enum Table { case root, servers, other }
        var table = Table.root
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.drop(while: isBlank)
            if line.hasPrefix("[") {
                let header = line.drop { $0 == "[" }
                if let name = serverKey(header) {
                    note(name)
                    table = .other
                } else if afterServers(header)?.first == "]" {
                    table = .servers
                } else {
                    table = .other
                }
                continue
            }
            switch table {
            case .servers:
                if let name = firstKey(line) { note(name) }
            case .root:
                if let name = serverKey(line) { note(name) }
            case .other:
                break
            }
        }
        return order
    }

    // MARK: - .claude/launch.json

    static func parseLaunchJSON(_ text: String, worktreeRoot: String, path: String) -> Parsed {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(stripJSONComments(text).utf8))
        } catch {
            return ([], [DevServerParseError(path: path, message: "not valid JSON: \(error.localizedDescription)")])
        }
        guard let top = object as? [String: Any] else {
            return ([], [DevServerParseError(path: path, message: "the top level must be an object")])
        }
        guard let rawConfigurations = top["configurations"] else { return ([], []) }
        guard let configurations = rawConfigurations as? [Any] else {
            return ([], [DevServerParseError(path: path, message: "`configurations` must be an array")])
        }
        var servers: [DeclaredDevServer] = []
        var errors: [DevServerParseError] = []
        var seen = Set<String>()
        func fail(_ message: String) { errors.append(DevServerParseError(path: path, message: message)) }
        func substitute(_ value: String) -> String {
            value.replacingOccurrences(of: "${workspaceFolder}", with: worktreeRoot)
        }

        for (index, element) in configurations.enumerated() {
            guard let config = element as? [String: Any] else {
                fail("configurations[\(index)] must be an object")
                continue
            }
            guard let rawName = config["name"] as? String, !rawName.isEmpty else {
                fail("configurations[\(index)] has no `name`")
                continue
            }
            let name = slug(rawName)
            guard !name.isEmpty else {
                fail("configurations[\(index)] name \"\(rawName)\" has no letters or digits")
                continue
            }
            guard seen.insert(name).inserted else {
                fail("configurations[\(index)] \"\(rawName)\" repeats the server name \"\(name)\"; ignored")
                continue
            }
            func strings(_ key: String) -> [String] {
                ((config[key] as? [Any]) ?? []).compactMap { $0 as? String }.map(substitute)
            }
            // VS Code's order: runtime, its arguments, the program, the
            // program's arguments. Without a `runtimeExecutable` the runtime
            // is `node`.
            let executable = (config["runtimeExecutable"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let program = (config["program"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard executable != nil || program != nil else {
                fail("configurations[\(index)] \"\(rawName)\" has neither `runtimeExecutable` nor `program`")
                continue
            }
            var parts: [String] = [substitute(executable ?? "node")]
            parts += strings("runtimeArgs")
            if let program { parts.append(substitute(program)) }
            parts += strings("args")
            var server = DeclaredDevServer(
                name: name, command: parts.map(shellQuote).joined(separator: " "), source: .launchJSON)
            if rawName != name { server.label = rawName }
            if let rawCwd = config["cwd"] as? String {
                guard let relative = relativeCwd(substitute(rawCwd), worktreeRoot: worktreeRoot) else {
                    fail("configurations[\(index)] \"\(rawName)\" `cwd` is outside the worktree")
                    continue
                }
                server.cwd = relative.isEmpty ? nil : relative
            }
            if let env = config["env"] as? [String: Any] {
                for key in env.keys.sorted() {
                    guard isValidEnvironmentKey(key) else {
                        fail("""
                            configurations[\(index)] "\(rawName)" env key "\(key)" is not a valid variable \
                            name; ignored
                            """)
                        continue
                    }
                    if let value = env[key] as? String {
                        server.env[key] = substitute(value)
                    } else {
                        fail("configurations[\(index)] \"\(rawName)\" env.\(key) must be a string; ignored")
                    }
                }
            }
            servers.append(server)
        }
        return (servers, errors)
    }

    // MARK: - Helpers

    /// A shell identifier, `[A-Za-z_][A-Za-z0-9_]*`: the only names a
    /// server's environment can carry through `sh` and tmux's `-e`.
    static func isValidEnvironmentKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first else { return false }
        func isLetterOrUnderscore(_ c: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(c) || ("A"..."Z").contains(c) || c == "_"
        }
        return isLetterOrUnderscore(first)
            && key.unicodeScalars.allSatisfy { isLetterOrUnderscore($0) || ("0"..."9").contains($0) }
    }

    static func resolvedCwd(_ server: DeclaredDevServer, worktreePath: String) -> String {
        guard let cwd = server.cwd, !cwd.isEmpty, cwd != "." else { return worktreePath }
        return URL(fileURLWithPath: worktreePath, isDirectory: true)
            .appendingPathComponent(cwd).standardizedFileURL.path
    }

    /// True for a relative path that never climbs above its starting point.
    static func isContainedRelativePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/") else { return false }
        var depth = 0
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                depth -= 1
                if depth < 0 { return false }
            default:
                depth += 1
            }
        }
        return true
    }

    /// `path` relative to `worktreeRoot`: "" for the root itself, nil when
    /// the path leaves the worktree.
    static func relativeCwd(_ path: String, worktreeRoot: String) -> String? {
        guard path.hasPrefix("/") else { return isContainedRelativePath(path) ? path : nil }
        let root = URL(fileURLWithPath: worktreeRoot).standardizedFileURL.path
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        if target == root { return "" }
        guard target.hasPrefix(root + "/") else { return nil }
        return String(target.dropFirst(root.count + 1))
    }

    /// "Web App" → "web-app": lowercase, runs of anything outside [a-z0-9]
    /// collapse to one `-`, no leading or trailing `-`.
    static func slug(_ name: String) -> String {
        var result = String.UnicodeScalarView()
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingDash && !result.isEmpty { result.append("-") }
                pendingDash = false
                result.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return String(result)
    }

    private static let shellSafe = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-")

    static func shellQuote(_ argument: String) -> String {
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy({ shellSafe.contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// JSON with comments → JSON: drops `//` and `/* */` comments and
    /// trailing commas, leaving string contents untouched.
    static func stripJSONComments(_ text: String) -> String {
        let chars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        var inString = false
        while index < chars.count {
            let c = chars[index]
            if inString {
                out.append(c)
                if c == "\\", index + 1 < chars.count {
                    out.append(chars[index + 1]); index += 2; continue
                }
                if c == "\"" { inString = false }
                index += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); index += 1; continue }
            if c == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            }
            if c == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                index += 2
                while index + 1 < chars.count, !(chars[index] == "*" && chars[index + 1] == "/") { index += 1 }
                index += 2
                continue
            }
            out.append(c)
            index += 1
        }
        return removeTrailingCommas(String(out))
    }

    private static func removeTrailingCommas(_ text: String) -> String {
        let chars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        var inString = false
        while index < chars.count {
            let c = chars[index]
            if inString {
                out.append(c)
                if c == "\\", index + 1 < chars.count {
                    out.append(chars[index + 1]); index += 2; continue
                }
                if c == "\"" { inString = false }
                index += 1
                continue
            }
            if c == "\"" { inString = true }
            if c == "," {
                var next = index + 1
                while next < chars.count, chars[next].properties.isWhitespace { next += 1 }
                if next < chars.count, chars[next] == "}" || chars[next] == "]" {
                    index += 1
                    continue
                }
            }
            out.append(c)
            index += 1
        }
        return String(out)
    }
}
