import Testing

/// Parent suite for every test suite that mutates the process-global `TBD_HOME`
/// environment variable (via `setenv`/`unsetenv`) to isolate the overlay /
/// runtime directory.
///
/// `.serialized` on a suite serializes its tests AND its descendant suites
/// relative to one another. Nesting the `TBD_HOME`-mutating suites inside this
/// parent is what prevents cross-suite races on that single shared global —
/// per-suite `.serialized` alone only orders tests *within* a suite, so two
/// sibling suites could still run concurrently and clobber each other's
/// `TBD_HOME`.
///
/// To add a new `TBD_HOME`-mutating suite, declare it inside an
/// `extension TBDHomeSerialized { ... }` so it becomes a nested (and therefore
/// serialized) child of this suite.
///
/// **Important — this domain only serializes suites WITHIN TBDDaemonTests.**
/// All test targets (TBDSharedTests, TBDDaemonTests, TBDAppTests, …) compile
/// into ONE process and Swift Testing runs suites across all targets in
/// parallel. Suites in OTHER targets cannot nest here (cross-target imports
/// are impossible), so they must never call `setenv("TBD_HOME")`. Use
/// injection seams instead:
/// - `TBDConstants.*(environment:)` — pass an explicit env dict
/// - `ThemeStore(themesDirectory:)` — override the themes directory
/// - `AppearanceSettings(userThemesDirectory:)` — override the themes lookup dir
@Suite(.serialized) enum TBDHomeSerialized {}
