import Foundation
import TBDShared

/// What a provider header says about WHICH provider it is.
///
/// The one rule everything here follows: **the registry key is the
/// identity.** `RemoteProviderConfig.name` is unique by construction
/// (`RemoteProviderRegistry.loadEntries` rejects duplicates) and is what
/// every other part of TBD keys on — the mirror's primary key, an attach
/// selection, a notification's route. `ProviderDescribe.name` identifies the
/// provider's KIND, so two registry entries running the same binary against
/// different backends report the same one. Leading with the latter is how a
/// user comes to inspect one backend while believing they inspected the
/// other, and it is why `headline` is not `describe?.name ?? config.name`.
///
/// Pure and view-free so the exact strings a header renders can be asserted
/// without a view hierarchy.
enum RemoteProviderIdentityPresentation {
    struct Row: Equatable, Identifiable {
        let label: String
        let value: String
        /// Whether this row is what distinguishes two same-kind entries —
        /// used only to decide emphasis, never content.
        let isDistinguishing: Bool
        var id: String { label }

        init(label: String, value: String, isDistinguishing: Bool = false) {
            self.label = label
            self.value = value
            self.isDistinguishing = isDistinguishing
        }
    }

    /// The name a header leads with: always the registry key.
    static func headline(_ provider: RemoteProviderStatus) -> String {
        provider.config.name
    }

    /// The provider's kind, when it says anything the headline doesn't
    /// already. Nil when `describe.name` matches the registry key (nothing to
    /// add) or is missing (`describe` hasn't succeeded).
    static func kindSubtitle(_ provider: RemoteProviderStatus) -> String? {
        guard let kind = provider.describe?.name, !kind.isEmpty, kind != provider.config.name else {
            return nil
        }
        return "reports as \(kind)"
    }

    /// The identity block under the headline, most identifying first.
    ///
    /// Every row is omitted when its source is absent, so a provider that
    /// sends no `identity` still gets the two rows TBD can always derive
    /// locally — the command it runs and, when `describe` succeeded, its
    /// versions.
    static func rows(
        _ provider: RemoteProviderStatus,
        homeDirectory: String = NSHomeDirectory()
    ) -> [Row] {
        var rows: [Row] = []
        for pair in provider.describe?.identity?.displayPairs ?? [] {
            rows.append(Row(label: humanizedKey(pair.key), value: pair.value, isDistinguishing: true))
        }
        rows.append(Row(
            label: "Command",
            value: commandLine(provider.config, homeDirectory: homeDirectory),
            // The command line is the disambiguator that needs no contract
            // change: two entries of the same kind nearly always differ in
            // their flags, and when they don't, the identity pairs above are
            // the only thing that can tell them apart.
            isDistinguishing: provider.describe?.identity?.hasDisplayablePairs != true))
        if let version = versionLine(provider) {
            rows.append(Row(label: "Version", value: version))
        }
        return rows
    }

    /// The registry entry's argv as one displayable line: the executable
    /// tilde-abbreviated, the arguments redacted (the registry file is
    /// user-authored, so nothing in it is contract-guaranteed to be
    /// non-secret), and the whole thing shown verbatim otherwise.
    ///
    /// Deliberately NOT parsed. Reading an environment out of a flag list is
    /// a guess that is wrong exactly when it matters most — an entry named
    /// `…-staging` pointed by a stale flag at production — so the line is
    /// put in front of a human instead.
    static func commandLine(
        _ config: RemoteProviderConfig,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        let exec = abbreviatingHome(config.exec, homeDirectory: homeDirectory)
        let args = ProviderIdentityRedaction.redactArguments(config.args ?? [])
        return ([exec] + args).joined(separator: " ")
    }

    /// `provider_version` and the negotiated contract major, whichever are
    /// known. Nil before `describe` has ever succeeded.
    static func versionLine(_ provider: RemoteProviderStatus) -> String? {
        var parts: [String] = []
        if let version = provider.describe?.providerVersion, !version.isEmpty {
            parts.append(version)
        }
        if provider.describe != nil {
            // Absent from a daemon that predates negotiation; 1 is what every
            // emitter announced unconditionally before, per
            // `RemoteProviderStatus.contractVersion`.
            parts.append("contract v\(provider.contractVersion ?? 1)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A one-line identity for accessibility and for anywhere a block of rows
    /// doesn't fit: the registry key, then its kind when that differs, then
    /// the first identity pair.
    static func compactSummary(_ provider: RemoteProviderStatus) -> String {
        var parts = [headline(provider)]
        if let kind = kindSubtitle(provider) { parts.append(kind) }
        if let first = provider.describe?.identity?.displayPairs.first {
            parts.append("\(humanizedKey(first.key)) \(first.value)")
        }
        return parts.joined(separator: ", ")
    }

    /// `snake_case` or `kebab-case` provider key as a display label. No
    /// dictionary of known keys: the map is provider-defined, and inventing
    /// prettier names for the handful TBD happens to recognize would make
    /// every other key look second-class.
    static func humanizedKey(_ key: String) -> String {
        let words = key
            .split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let first = words.first else { return key }
        let rest = words.dropFirst()
        let capitalized = first.prefix(1).uppercased() + String(first.dropFirst())
        return ([capitalized] + rest).joined(separator: " ")
    }

    /// `NSString.abbreviatingWithTildeInPath` with the home directory
    /// injected, so a test asserts against a fixed home rather than the
    /// machine's.
    static func abbreviatingHome(_ path: String, homeDirectory: String) -> String {
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + String(path.dropFirst(home.count))
    }
}
