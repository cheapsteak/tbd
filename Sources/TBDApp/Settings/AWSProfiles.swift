import Foundation

/// Discovery of locally-configured AWS named profiles by reading the two
/// canonical config files. Pure file I/O — no shell-out to `aws-cli` and no
/// AWS SDK dependency. Used to seed the typeahead suggestions in the
/// Bedrock add-profile sheet.
///
/// File format reference:
/// https://docs.aws.amazon.com/sdkref/latest/guide/file-format.html
///
/// `~/.aws/config` uses `[profile NAME]` headers (and a bare `[default]`),
/// `~/.aws/credentials` uses bare `[NAME]` headers. `[sso-session ...]`,
/// `[services ...]`, and `[plugins ...]` are NOT profiles and are skipped.
enum AWSProfiles {
    /// Read both config files (if present) and return a sorted, deduped
    /// list of profile names. Returns an empty array if neither file exists
    /// or no profile sections are found.
    static func discover(
        configPath: String? = nil,
        credentialsPath: String? = nil
    ) -> [String] {
        let home = NSHomeDirectory()
        let configFile = configPath ?? "\(home)/.aws/config"
        let credsFile = credentialsPath ?? "\(home)/.aws/credentials"

        var names = Set<String>()
        names.formUnion(parseConfig(at: configFile))
        names.formUnion(parseCredentials(at: credsFile))
        return names.sorted()
    }

    /// Parse a `~/.aws/config`-style file. Recognizes `[default]` and
    /// `[profile NAME]` headers; ignores `[sso-session ...]`,
    /// `[services ...]`, `[plugins ...]`, and any other non-profile sections.
    static func parseConfig(at path: String) -> [String] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var names: [String] = []
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[") && line.hasSuffix("]") else { continue }
            let inner = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner == "default" {
                names.append("default")
            } else if inner.hasPrefix("profile ") {
                let name = String(inner.dropFirst("profile ".count)).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { names.append(name) }
            }
            // [sso-session …], [services …], [plugins …], anything else → skip
        }
        return names
    }

    /// Parse a `~/.aws/credentials`-style file. Every `[NAME]` is a profile.
    static func parseCredentials(at path: String) -> [String] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var names: [String] = []
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[") && line.hasSuffix("]") else { continue }
            let inner = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty { names.append(inner) }
        }
        return names
    }
}
