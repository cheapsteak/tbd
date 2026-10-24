/// How many columns this tree has retired from the daemon's database.
///
/// A column leaves the schema in two steps: a retirement, which deletes every
/// read and write of it and lists it in the daemon's `RetiredColumns.all`, and
/// a drop, which `RetiredColumnReconciler` makes at daemon startup once the
/// app bundle kept for rollback (`~/tbd/updates/previous/TBD.app`) no longer
/// uses it. Every build records this value in its build identity as
/// `schemaEpoch`, so the kept bundle's identity says which retirements the
/// tree it was built from had already made.
///
/// Each retirement increments it by one, in the same commit that lists the
/// column; see "Retiring a column" in `Sources/TBDDaemon/Database/CLAUDE.md`.
///
/// `write_build_identity` in `scripts/restart-bundle-lib.sh` reads the value
/// from the declaration below with a strict pattern, and stamps no build
/// identity when it cannot. Keep that declaration on one line, spelled exactly
/// as it is, with a plain decimal literal.
///
/// Design: `docs/specs/2026-10-24-column-retirement-design.md`.
public enum SchemaEpoch {
    public static let current = 1
}
