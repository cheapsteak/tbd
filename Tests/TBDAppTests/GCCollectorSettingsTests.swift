import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The Settings toggles for the four opt-in orphan-GC collectors: the setter
/// writes through the injected closure (the same RPC `tbd gc <collector>`
/// uses), a failed write leaves the mirror alone and alerts, and the loader
/// maps the daemon's `Config` fields into `AppState`.
///
/// Every `AppState` here runs over its own throwaway `UserDefaults` suite —
/// `.standard` on this unbundled executable is the developer's real
/// `TBDApp.plist`.
@MainActor
@Suite("GC collector settings")
struct GCCollectorSettingsTests {
    private func withAppState(_ body: (AppState) async -> Void) async {
        let name = "tbd-gc-collector-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let state = AppState(userDefaults: defaults)
        // Keep any config read off a real daemon.
        state.configFetcher = { @MainActor in Config() }
        await body(state)
        defaults.removePersistentDomain(forName: name)
    }

    @Test func everyCollectorStartsAtItsShippedDefault() async {
        let shipped: [GCCollector: Bool] = [
            .orphanProcesses: Config.gcOrphanProcessesEnabledDefault,
            .profileDirs: Config.gcProfileDirsEnabledDefault,
            .retainedTranscripts: Config.gcRetainedTranscriptsEnabledDefault,
            .hangStacks: Config.gcHangStacksEnabledDefault,
        ]
        await withAppState { state in
            for collector in GCCollector.allCases {
                #expect(collector.mapping.shippedDefault == shipped[collector])
                #expect(state.gcCollectorEnabled(collector) == shipped[collector])
            }
        }
    }

    @Test(arguments: GCCollector.allCases)
    func settingOnWritesTrueAndUpdatesOnlyThatMirror(_ collector: GCCollector) async {
        await withAppState { state in
            var written: [(GCCollector, Bool)] = []
            state.gcCollectorSetter = { @MainActor c, enabled in written.append((c, enabled)) }

            await state.setGCCollectorEnabled(collector, true)

            #expect(written.count == 1)
            #expect(written.first?.0 == collector)
            #expect(written.first?.1 == true)
            for other in GCCollector.allCases where other != collector {
                #expect(state.gcCollectorEnabled(other) == other.mapping.shippedDefault)
            }
            #expect(state.gcCollectorEnabled(collector))
            #expect(state.alertMessage == nil)
        }
    }

    @Test(arguments: GCCollector.allCases)
    func settingOffWritesFalseAndUpdatesMirror(_ collector: GCCollector) async {
        await withAppState { state in
            var written: [(GCCollector, Bool)] = []
            state.gcCollectorSetter = { @MainActor c, enabled in written.append((c, enabled)) }
            await state.setGCCollectorEnabled(collector, true)
            written.removeAll()

            await state.setGCCollectorEnabled(collector, false)

            #expect(written.count == 1)
            #expect(written.first?.0 == collector)
            #expect(written.first?.1 == false)
            #expect(!state.gcCollectorEnabled(collector))
        }
    }

    @Test(arguments: GCCollector.allCases)
    func failedSetLeavesMirrorUnchangedAndAlerts(_ collector: GCCollector) async {
        struct Rejected: Error {}
        await withAppState { state in
            state.gcCollectorSetter = { @MainActor _, _ in throw Rejected() }

            let before = state.gcCollectorEnabled(collector)

            await state.setGCCollectorEnabled(collector, !before)

            #expect(state.gcCollectorEnabled(collector) == before)
            #expect(state.alertIsError)
            #expect(state.alertMessage != nil)
        }
    }

    @Test func loaderMapsEachConfigFieldToItsMirror() async {
        await withAppState { state in
            var config = Config()
            config.gcOrphanProcessesEnabled = true
            config.gcProfileDirsEnabled = false
            config.gcRetainedTranscriptsEnabled = true
            config.gcHangStacksEnabled = false
            state.configFetcher = { @MainActor in config }

            await state.loadGCConfig()

            #expect(state.gcOrphanProcessesEnabled)
            #expect(!state.gcProfileDirsEnabled)
            #expect(state.gcRetainedTranscriptsEnabled)
            #expect(!state.gcHangStacksEnabled)

            config.gcOrphanProcessesEnabled = false
            config.gcProfileDirsEnabled = true
            config.gcRetainedTranscriptsEnabled = false
            config.gcHangStacksEnabled = true
            state.configFetcher = { @MainActor in config }

            await state.loadGCConfig()

            #expect(!state.gcOrphanProcessesEnabled)
            #expect(state.gcProfileDirsEnabled)
            #expect(!state.gcRetainedTranscriptsEnabled)
            #expect(state.gcHangStacksEnabled)
        }
    }

    /// Two config-change deltas can start overlapping loads. The first
    /// load's fetch is held until the second load has finished; when it then
    /// returns its older snapshot it must apply nothing. Without the load
    /// generation the first load would apply last and leave the mirrors at
    /// the older snapshot, failing every expectation below.
    @Test func aStaleLoadThatFinishesLastIsIgnored() async {
        await withAppState { state in
            // Hang-stack stays off in both so the shared writer's cap is
            // never armed by this test.
            var older = Config()
            older.gcOrphanProcessesEnabled = true
            older.gcProfileDirsEnabled = false
            older.gcRetainedTranscriptsEnabled = true
            older.gcHangStacksEnabled = false
            var newer = Config()
            newer.gcOrphanProcessesEnabled = false
            newer.gcProfileDirsEnabled = true
            newer.gcRetainedTranscriptsEnabled = false
            newer.gcHangStacksEnabled = false

            let (firstFetchStarted, signalFirstFetchStarted) = AsyncStream<Void>.makeStream()
            let (releaseFirstFetch, openReleaseFirstFetch) = AsyncStream<Void>.makeStream()
            var calls = 0
            state.configFetcher = { @MainActor in
                calls += 1
                guard calls == 1 else { return newer }
                signalFirstFetchStarted.yield()
                for await _ in releaseFirstFetch { break }
                return older
            }

            let first = Task { await state.loadGCConfig() }
            for await _ in firstFetchStarted { break }

            await state.loadGCConfig()
            #expect(!state.gcOrphanProcessesEnabled)
            #expect(state.gcProfileDirsEnabled)

            openReleaseFirstFetch.yield()
            openReleaseFirstFetch.finish()
            await first.value

            #expect(calls == 2)
            #expect(!state.gcOrphanProcessesEnabled)
            #expect(state.gcProfileDirsEnabled)
            #expect(!state.gcRetainedTranscriptsEnabled)
        }
    }

    @Test func failedLoadKeepsTheLastValue() async {
        struct Down: Error {}
        await withAppState { state in
            state.gcOrphanProcessesEnabled = true
            state.configFetcher = { @MainActor in throw Down() }

            await state.loadGCConfig()

            #expect(state.gcOrphanProcessesEnabled)
        }
    }

    @Test func captionNamesTheCleanupSwitchOnlyWhileItIsOff() {
        for collector in GCCollector.allCases {
            let on = GeneralSettingsTab.gcCollectorCaption(collector, cleanupEnabled: true)
            let off = GeneralSettingsTab.gcCollectorCaption(collector, cleanupEnabled: false)
            #expect(on == collector.caption)
            #expect(off == "\(collector.caption) Requires automatic cleanup to be on.")
        }
    }

    @Test func captionAndHelpFollowTheShippedDefaultConstant() {
        for collector in GCCollector.allCases {
            let shipped = collector.mapping.shippedDefault
            #expect(collector.caption.hasSuffix(shipped ? "On by default." : "Off by default."))
            #expect(collector.help.contains(shipped ? "(default on)" : "(default off)"))
            #expect(collector.help.hasSuffix("Same switch as \(collector.mapping.cliCommand)."))
            #expect(!collector.help.contains("`"))
        }
    }
}
