import Foundation

/// What `<home>/proxy/proxy.pid` names: the pid that bound the port, and the
/// port it bound.
struct ModelProxyPIDFileRecord: Sendable, Equatable {
    let pid: Int32
    let port: Int
}

/// Reads a proxy's pid file.
///
/// A protocol because two branches of adoption turn on it — a file that names
/// another pid, and one that names another port — and neither can be produced
/// by writing a file next to a fake HTTP listener without also deciding what
/// "missing" means. The production witness is a plain read; a test injects one
/// that answers whatever the branch needs.
protocol ModelProxyPIDFileReading: Sendable {
    /// The record at `path`, or nil for a missing file, an unreadable one, or
    /// one that is not this shape.
    func read(path: String) -> ModelProxyPIDFileRecord?
}

/// The production reader, over the real filesystem.
///
/// The format is `ProxyPIDFile.contents(pid:port:)` — `"<pid>\n<port>\n"` —
/// written atomically by the proxy after its bind. It is parsed here rather
/// than shared because that helper lives in the proxy's executable target,
/// which no library can import; the live test is what keeps the two spellings
/// honest, since it reads what the real binary writes.
struct ModelProxyPIDFile: ModelProxyPIDFileReading {
    func read(path: String) -> ModelProxyPIDFileRecord? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Self.parse(text)
    }

    /// The two lines, or nil for anything else.
    static func parse(_ text: String) -> ModelProxyPIDFileRecord? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2,
            let pid = Int32(lines[0].trimmingCharacters(in: .whitespaces)),
            let port = Int(lines[1].trimmingCharacters(in: .whitespaces))
        else {
            return nil
        }
        return ModelProxyPIDFileRecord(pid: pid, port: port)
    }
}
