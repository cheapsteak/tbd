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
/// **Readers belong here too when they cannot use a seam.** A suite that only
/// *depends on* `TBD_HOME` holding still is exposed to exactly the same race:
/// production code that resolves the variable per call will answer differently
/// on either side of a mutator's window, and in the fast parallel pass a test
/// spends most of its wall time suspended, so that window is seconds wide.
/// Prefer an injection seam; nest here when the code under test reaches the
/// environment through static members that have none (`ModelProfileRPCTests`
/// and `ModelProfileKeychain` are the standing example).
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
