import Foundation

enum ExecutableResolver {
    static func resolve(_ name: String, path: String?) -> String? {
        guard !name.isEmpty, !name.contains("/"), let path, !path.isEmpty else {
            return nil
        }

        for entry in path.split(separator: ":", omittingEmptySubsequences: false) {
            let directory = String(entry)
            guard !directory.isEmpty, (directory as NSString).isAbsolutePath else {
                continue
            }

            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name)
                .standardizedFileURL
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }
}
