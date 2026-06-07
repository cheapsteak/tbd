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
@Suite(.serialized) enum TBDHomeSerialized {}
