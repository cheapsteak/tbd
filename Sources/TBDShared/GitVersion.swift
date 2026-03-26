import Foundation

public enum GitVersion {
    public static let info: (hash: String, message: String) = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["log", "-1", "--format=%h %s"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let space = output.firstIndex(of: " ") {
                return (String(output[..<space]), String(output[output.index(after: space)...]))
            }
            return (output, "")
        } catch {
            return ("unknown", "")
        }
    }()
}
