import Foundation
import TBDShared

/// Isolated executable and resolver for tests whose behavior assumes a known
/// tmux version. The fixture keeps gate tests independent of the host PATH and
/// the user's saved fallback configuration.
public struct TmuxExecutableTestFixture: Sendable {
    public let root: URL
    public let executableURL: URL
    public let configurationURL: URL

    public init(version: String = "3.6") throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TmuxExecutableTestFixture-\(UUID().uuidString)", isDirectory: true)
        executableURL = root.appendingPathComponent("tmux")
        configurationURL = root.appendingPathComponent("tmux-executable-path")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let script = """
        #!/bin/sh
        printf '%s\\n' 'tmux \(version)'
        """
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }

    public var resolver: TmuxExecutableResolver {
        TmuxExecutableResolver(
            environment: ["PATH": root.path],
            configurationURL: configurationURL
        )
    }

    public func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
