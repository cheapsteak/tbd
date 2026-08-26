import Foundation
import Testing
@testable import TBDApp

// Tier 1: deterministic, in-process state only.

/// Pins ``AppStateEmissionTracker/readAllTrackedProperties(of:)`` against the
/// class it measures.
///
/// That read list is what makes the object-wide emission count in
/// `AppStatePublishFrequencyTests` possible: Observation notifies only the
/// readers of a property, so a property the tracker never reads is a property
/// whose writes go uncounted — and an uncounted writer looks exactly like a
/// well-behaved one. Under `ObservableObject` this could not happen, because
/// `objectWillChange` was object-wide and needed no list.
///
/// The check reads the shape the `@Observable` macro leaves behind. The macro
/// rewrites each tracked stored property into a computed pair over storage it
/// renames with a leading underscore, and leaves `@ObservationIgnored`
/// properties as plain storage under their own name. So the underscored
/// children of a reflected `AppState` — minus the registrar the macro adds —
/// are exactly its tracked stored properties.
@MainActor
@Suite("The emission tracker reads every tracked property of AppState")
struct AppStateTrackedPropertyCoverageTests {

    /// Tracked stored property names, recovered from the macro's storage.
    private static func trackedPropertyNames(of state: AppState) -> Set<String> {
        var found: Set<String> = []
        for child in Mirror(reflecting: state).children {
            guard let label = child.label, label.hasPrefix("_") else { continue }
            if label.hasPrefix("_$") { continue }  // `_$observationRegistrar`
            found.insert(String(label.dropFirst()))
        }
        return found
    }

    @Test("the read list covers every tracked property, and nothing else")
    func readListMatchesTheClass() {
        withEmissionState { state in
            let actual = Self.trackedPropertyNames(of: state)

            // Guards the guard: if the macro ever stops using underscored
            // storage, `actual` goes empty and every comparison below passes
            // vacuously. Assert it found something first.
            #expect(actual.count > 50,
                    "expected to recover AppState's tracked storage by reflection, found \(actual.count)")

            let listed = AppStateEmissionTracker.trackedPropertyNames
            let missing = actual.subtracting(listed)
            let stale = listed.subtracting(actual)

            #expect(missing.isEmpty,
                    "tracked but uncounted — add to readAllTrackedProperties: \(missing.sorted())")
            #expect(stale.isEmpty,
                    "listed but no longer tracked — remove from readAllTrackedProperties: \(stale.sorted())")
        }
    }

    /// The other half of the audit: a property that was deliberately left
    /// unpublished under `ObservableObject` must stay untracked under
    /// `@Observable`, where the default inverted. The memo caches are the
    /// load-bearing case — tracking them would make a cache fill an observable
    /// mutation during view update — so they are asserted by name.
    @Test("the derived-worktree memo caches are not tracked")
    func memoCachesStayUntracked() {
        withEmissionState { state in
            let tracked = Self.trackedPropertyNames(of: state)
            #expect(!tracked.contains("childrenIndexCache"))
            #expect(!tracked.contains("allWorktreesCache"))
        }
    }
}

/// Pins the one toolchain behaviour every count in
/// `AppStatePublishFrequencyTests` now rests on.
///
/// Swift 6.2's `@Observable` macro drops the notification for a whole-property
/// assignment of an equal value when the property's type is `Equatable`, and
/// keeps it for everything reached through `_modify`. That is an optimisation,
/// not a language guarantee — the migration design explicitly declines to build
/// a contract on it — so it is asserted here, once, by name. If a toolchain
/// change reverts or extends it, this fails and says which half moved, instead
/// of a dozen counts drifting across the frequency file with no stated cause.
///
/// It is emphatically not a substitute for the assignment-site guard audit
/// (#667): it spares only the narrow whole-property case, and the two shapes
/// below are both live in production paths.
@MainActor
@Suite("Observation's equal-value exemption covers assignment, not mutation")
struct AppStateObservationContractTests {

    @Test("a whole-property assignment of an equal Equatable value notifies nobody")
    func equalAssignmentIsExempt() {
        withEmissionState { state in
            state.isConnected = true
            #expect(countEmissions(of: state) { state.isConnected = true } == 0)
            // Positive control: a genuine change still notifies, so the
            // assertion above cannot be passing because nothing is measured.
            #expect(countEmissions(of: state) { state.isConnected = false } == 1)
        }
    }

    @Test("an in-place mutation notifies even when the value does not change")
    func inPlaceMutationIsNotExempt() {
        withEmissionState { state in
            let terminalID = UUID()
            state.unreadTerminals = [terminalID]
            // `insert` of a member already present: the set is unchanged, but
            // it is reached through `_modify`, which never sees a
            // before-and-after pair to compare.
            #expect(countEmissions(of: state) { state.unreadTerminals.insert(terminalID) } == 1)
        }
    }
}
