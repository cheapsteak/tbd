import Foundation
import GRDB
import SQLite3
import os

/// Marker type whose bundle locates the `TBDDaemonLib` resource bundle.
///
/// `Bundle(for:)` needs a class, and it must be a class defined in this module
/// so the bundle it reports is the one the module's binary lives in.
private final class SQLMigrationLoaderBundleMarker {}

/// One `.sql` file discovered under `Database/Migrations/`.
///
/// `identifier` is the filename stem, which is also the GRDB migration
/// identifier — `20260819143000_add_thing.sql` registers as
/// `20260819143000_add_thing`.
public struct SQLMigrationFile: Sendable, Equatable {
    public let identifier: String
    public let sql: String

    public init(identifier: String, sql: String) {
        self.identifier = identifier
        self.sql = sql
    }
}

/// A migration ready to hand to `DatabaseMigrator.registerMigration`. Produced
/// both from `.sql` files and from the inline Swift escape hatch, so the two
/// kinds can be merged into one identifier-sorted list.
public struct RegisteredMigration: Sendable {
    public let identifier: String
    public let body: @Sendable (GRDB.Database) throws -> Void

    public init(identifier: String, body: @escaping @Sendable (GRDB.Database) throws -> Void) {
        self.identifier = identifier
        self.body = body
    }
}

/// Everything the loader found in the resource bundle, plus where it found it.
public struct BundledMigrations: Sendable {
    public let directoryPath: String
    public let files: [SQLMigrationFile]
}

public enum SQLMigrationLoaderError: LocalizedError, CustomStringConvertible, Sendable {
    /// No candidate directory contained `TBD_TBDDaemonLib.bundle/Migrations`.
    case resourceBundleNotFound(searched: [String])
    /// The directory resolved but could not be enumerated or read.
    case migrationsDirectoryUnreadable(path: String, underlying: String)
    case migrationFileUnreadable(path: String, underlying: String)
    /// `grdb_migrations` holds timestamp-shaped identifiers, but the bundle
    /// yielded no `.sql` files at all — the resources are missing or truncated.
    case resourcesMissingButMigrationsApplied(applied: [String], directoryPath: String)

    public var description: String {
        switch self {
        case .resourceBundleNotFound(let searched):
            return """
                Could not locate TBD_TBDDaemonLib.bundle/Migrations. Searched, in order:
                \(searched.map { "  - \($0)" }.joined(separator: "\n"))
                The daemon cannot migrate the database without its migration resources.
                """
        case .migrationsDirectoryUnreadable(let path, let underlying):
            return "Could not read the migrations directory at \(path): \(underlying)"
        case .migrationFileUnreadable(let path, let underlying):
            return "Could not read the migration file at \(path): \(underlying)"
        case .resourcesMissingButMigrationsApplied(let applied, let directoryPath):
            return """
                The database records \(applied.count) timestamp-identified migration(s) \
                (\(applied.prefix(5).joined(separator: ", "))\(applied.count > 5 ? ", …" : "")) \
                but \(directoryPath) contains no .sql files. The migration resource bundle is \
                missing or truncated, so this build cannot know whether the schema is current. \
                Refusing to start rather than run against an under-migrated schema.
                """
        }
    }

    public var errorDescription: String? { description }
}

/// Discovers, splits, and applies the timestamp-identified `.sql` migrations
/// that live in `Sources/TBDDaemon/Database/Migrations/` and ship in
/// `TBD_TBDDaemonLib.bundle`.
public enum SQLMigrationLoader {

    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "migrations")

    // MARK: - Inline Swift escape hatch

    /// Post-cutover migrations that need procedural Swift rather than DDL.
    ///
    /// Each entry takes a 14-digit timestamp identifier just like a `.sql`
    /// file, and merges into the same identifier-sorted list, so it lands in
    /// authoring order rather than at the end. Adding one is the exception:
    /// prefer a `.sql` file, which no other branch can conflict with.
    public static let inlineTimestampMigrations: [RegisteredMigration] = []

    // MARK: - Locating the resource bundle

    /// The name SwiftPM gives `TBDDaemonLib`'s resource bundle.
    static let resourceBundleName = "TBD_TBDDaemonLib.bundle"
    /// The subdirectory `.copy("Database/Migrations")` produces inside it.
    static let migrationsSubdirectory = "Migrations"

    /// Directories that may contain the resource bundle, most specific first.
    ///
    /// Deliberately **not** `Bundle.module`: SwiftPM's generated accessor
    /// includes a hardcoded absolute path into the building worktree's
    /// `.build`, so a relocated daemon silently reads the build tree's
    /// migrations instead of failing. Every candidate here is relative to
    /// something the running binary can see.
    static func candidateContainerURLs() -> [URL] {
        var candidates: [URL] = []
        var seen: Set<String> = []

        func add(_ url: URL?) {
            guard let url else { return }
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted {
                candidates.append(url)
            }
        }

        // 1. The executable's own directory — the daemon at `.build/debug/TBDDaemon`.
        add(Bundle.main.executableURL?.deletingLastPathComponent())
        // 2. The directory of the bundle owning this module's code.
        let markerBundleURL = Bundle(for: SQLMigrationLoaderBundleMarker.self).bundleURL
        add(markerBundleURL)
        // 3. Its parent — under the test harness the resource bundle is a
        //    SIBLING of `TBDPackageTests.xctest`, not inside it.
        add(markerBundleURL.deletingLastPathComponent())
        return candidates
    }

    /// Resolve `TBD_TBDDaemonLib.bundle/Migrations`, or throw naming every
    /// path that was searched.
    static func locateMigrationsDirectory() throws -> URL {
        var searched: [String] = []
        for container in candidateContainerURLs() {
            let candidate = container
                .appendingPathComponent(resourceBundleName)
                .appendingPathComponent(migrationsSubdirectory)
            searched.append(candidate.path)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }
        throw SQLMigrationLoaderError.resourceBundleNotFound(searched: searched)
    }

    // MARK: - Discovery

    /// Read every `.sql` file in `directory`, sorted by identifier.
    ///
    /// `.copy` preserves the directory verbatim, dotfiles included, so the
    /// `.gitkeep` that lets git track an empty directory is in the bundle too.
    /// Filtering to `.sql` is what keeps it out.
    public static func discover(in directory: URL) throws -> [SQLMigrationFile] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw SQLMigrationLoaderError.migrationsDirectoryUnreadable(
                path: directory.path, underlying: String(describing: error))
        }
        return try names
            .filter { $0.hasSuffix(".sql") }
            .sorted()
            .map { name in
                let url = directory.appendingPathComponent(name)
                let sql: String
                do {
                    sql = try String(contentsOf: url, encoding: .utf8)
                } catch {
                    throw SQLMigrationLoaderError.migrationFileUnreadable(
                        path: url.path, underlying: String(describing: error))
                }
                return SQLMigrationFile(
                    identifier: String(name.dropLast(".sql".count)), sql: sql)
            }
    }

    /// Discovery against the shipped resource bundle, performed once per
    /// process. A locator failure is cached as a failure and rethrown at every
    /// call site rather than degrading to "no migrations".
    public static let bundled: Result<BundledMigrations, SQLMigrationLoaderError> = Result {
        let directory = try locateMigrationsDirectory()
        return BundledMigrations(
            directoryPath: directory.path, files: try discover(in: directory))
    }
    .mapError { error in
        (error as? SQLMigrationLoaderError)
            ?? .migrationsDirectoryUnreadable(path: "<unresolved>", underlying: String(describing: error))
    }

    // MARK: - Merging

    /// Merge `.sql` files with inline Swift escape-hatch migrations, sorted by
    /// identifier so an inline migration interleaves by authoring time rather
    /// than landing last.
    public static func merged(
        files: [SQLMigrationFile],
        inline: [RegisteredMigration]
    ) -> [RegisteredMigration] {
        let fromFiles = files.map { file in
            RegisteredMigration(identifier: file.identifier) { db in
                try apply(sql: file.sql, identifier: file.identifier, to: db)
            }
        }
        return (fromFiles + inline).sorted { $0.identifier < $1.identifier }
    }

    /// The merged list `buildMigrator()` registers.
    ///
    /// A locator failure yields an empty list here rather than trapping, and is
    /// **not** swallowed: it is cached on `bundled` and rethrown by
    /// `verifyResourceIntegrity(_:)`, which `init(path:)` calls before it
    /// migrates. The daemon therefore refuses to start rather than quietly
    /// running an under-migrated schema.
    public static func migrationsForRegistration() -> [RegisteredMigration] {
        guard let found = try? bundled.get() else { return [] }
        return merged(files: found.files, inline: inlineTimestampMigrations)
    }

    // MARK: - Integrity

    /// A GRDB identifier produced by this scheme: 14 digits, then `_`.
    static func isTimestampIdentifier(_ identifier: String) -> Bool {
        guard identifier.count > 14 else { return false }
        let digits = identifier.prefix(14)
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        return identifier[identifier.index(identifier.startIndex, offsetBy: 14)] == "_"
    }

    /// Use the database as its own manifest.
    ///
    /// If `grdb_migrations` holds timestamp-shaped identifiers but the bundle
    /// yielded **zero** `.sql` files, the resources are missing or truncated
    /// and this build cannot tell whether the schema is current — refuse.
    ///
    /// A *partial* mismatch is deliberately fine: downgrading to an older build
    /// legitimately leaves applied identifiers with no corresponding file, and
    /// GRDB's own `hasBeenSuperseded` already covers that.
    public static func verifyResourceIntegrity(
        _ db: GRDB.Database,
        discoveredIdentifiers: [String],
        directoryPath: String
    ) throws {
        guard discoveredIdentifiers.isEmpty else { return }
        guard try db.tableExists("grdb_migrations") else { return }
        let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
        let timestamped = applied.filter(isTimestampIdentifier).sorted()
        guard !timestamped.isEmpty else { return }
        throw SQLMigrationLoaderError.resourcesMissingButMigrationsApplied(
            applied: timestamped, directoryPath: directoryPath)
    }

    /// `verifyResourceIntegrity` against the shipped bundle.
    public static func verifyResourceIntegrity(_ db: GRDB.Database) throws {
        let found = try bundled.get()
        try verifyResourceIntegrity(
            db,
            discoveredIdentifiers: found.files.map(\.identifier),
            directoryPath: found.directoryPath)
    }

    // MARK: - Splitting

    /// Split a migration file into individual statements using SQLite's own
    /// lexer, `sqlite3_complete()`.
    ///
    /// A `;` ends a statement only when the text accumulated so far is a
    /// complete statement, so semicolons inside string literals, inside `--`
    /// and `/* */` comments, and inside a `CREATE TRIGGER … BEGIN … END;` body
    /// are not boundaries.
    ///
    /// Splitting has to happen before SQLite prepares anything: `duplicate
    /// column name` is raised at *prepare* time, so a loader that handed the
    /// whole file to `execute(sql:)` and caught the error could not recover —
    /// earlier statements would already have run and the transaction would roll
    /// back.
    public static func splitStatements(_ sql: String) -> [String] {
        var statements: [String] = []
        var current = ""
        for character in sql {
            current.append(character)
            guard character == ";" else { continue }
            let complete = current.withCString { sqlite3_complete($0) != 0 }
            guard complete else { continue }
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                statements.append(trimmed)
            }
            current = ""
        }
        // A file whose last statement has no trailing semicolon still has a
        // statement here; a whitespace-only or comment-only trailer does not.
        if !strippingLeadingNoise(current).isEmpty {
            statements.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return statements
    }

    /// Drop leading whitespace and complete `--` / `/* */` comments.
    ///
    /// Only used to find where a statement actually begins — for the trailer
    /// test above and for anchoring the ADD COLUMN match below. String literals
    /// are the hard part of SQL lexing and `sqlite3_complete()` owns them;
    /// leading comments are not.
    static func strippingLeadingNoise(_ text: String) -> Substring {
        var rest = Substring(text)
        while true {
            rest = rest.drop(while: { $0.isWhitespace })
            if rest.hasPrefix("--") {
                guard let newline = rest.firstIndex(of: "\n") else { return "" }
                rest = rest[rest.index(after: newline)...]
            } else if rest.hasPrefix("/*") {
                guard let close = rest.range(of: "*/") else { return "" }
                rest = rest[close.upperBound...]
            } else {
                return rest
            }
        }
    }

    // MARK: - The ADD COLUMN guard

    /// `ALTER TABLE <ident> ADD [COLUMN] <ident>`, case-insensitive, tolerating
    /// double-quoted identifiers. Deliberately strict: anything this does not
    /// match executes unmodified, so the guard can never silently swallow a
    /// statement it did not understand.
    ///
    /// A statement that spells its column `column` (legal, not reserved) parses
    /// the keyword greedily and reads the *type* as the column name. That
    /// mis-parse only ever fails to find the column in `PRAGMA table_info`, so
    /// it falls through to executing unmodified — the safe direction.
    private static let identifierPattern = #"(?:"(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_$]*)"#
    static let addColumnRegex: NSRegularExpression = {
        let pattern = #"^ALTER\s+TABLE\s+("# + identifierPattern + #")"#
            + #"\s+ADD\s+(?:COLUMN\s+)?("# + identifierPattern + #")(?:\s|$)"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// The `(table, column)` an ADD COLUMN statement targets, or nil when the
    /// statement is not one.
    static func addColumnTarget(in statement: String) -> (table: String, column: String)? {
        let body = String(strippingLeadingNoise(statement))
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        guard let match = addColumnRegex.firstMatch(in: body, options: [], range: range),
              let tableRange = Range(match.range(at: 1), in: body),
              let columnRange = Range(match.range(at: 2), in: body) else { return nil }
        return (unquote(String(body[tableRange])), unquote(String(body[columnRange])))
    }

    private static func unquote(_ identifier: String) -> String {
        guard identifier.hasPrefix("\""), identifier.hasSuffix("\""), identifier.count >= 2 else {
            return identifier
        }
        return String(identifier.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
    }

    // MARK: - Applying

    /// Split `sql` and run each statement, skipping an `ALTER TABLE … ADD
    /// COLUMN` whose column is already present.
    public static func apply(sql: String, identifier: String, to db: GRDB.Database) throws {
        for statement in splitStatements(sql) {
            if let target = addColumnTarget(in: statement),
               try columnExists(target.column, in: target.table, db: db) {
                logger.debug(
                    """
                    migration \(identifier, privacy: .public): skipping ADD COLUMN \
                    \(target.table, privacy: .public).\(target.column, privacy: .public) \
                    (already present)
                    """
                )
                continue
            }
            try db.execute(sql: statement)
        }
    }

    static func columnExists(_ column: String, in table: String, db: GRDB.Database) throws -> Bool {
        let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(quoted))")
        let names = rows.compactMap { ($0["name"] as String?)?.lowercased() }
        return names.contains(column.lowercased())
    }
}
