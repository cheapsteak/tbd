import Testing
@testable import TBDDaemonLib

/// Pure decision-function tests for `RemoteLaneLifecycle`
/// (`docs/specs/2026-08-16-remote-lane-archive-design.md`, "Archive" and
/// "Revive"). No fixtures, no stub provider, no `TBD_HOME` — these are plain
/// functions over a capability set and a boolean.
@Suite("RemoteLaneLifecycle")
struct RemoteLaneLifecycleTests {
    // MARK: - Archive

    @Test("archive: declares archive -> invokeVerb, regardless of isGone")
    func archiveDeclaresArchiveInvokesVerb() {
        for isGone in [false, true] {
            let plan = RemoteLaneLifecycle.archivePlan(capabilities: ["archive"], isGone: isGone)
            #expect(plan == .invokeVerb)
        }
    }

    @Test("archive: declares archive+stop -> invokeVerb, regardless of isGone")
    func archiveDeclaresArchiveAndStopInvokesVerb() {
        for isGone in [false, true] {
            let plan = RemoteLaneLifecycle.archivePlan(capabilities: ["archive", "stop"], isGone: isGone)
            #expect(plan == .invokeVerb)
        }
    }

    @Test("archive: declares archive+unarchive -> invokeVerb, regardless of isGone")
    func archiveDeclaresArchiveAndUnarchiveInvokesVerb() {
        for isGone in [false, true] {
            let plan = RemoteLaneLifecycle.archivePlan(capabilities: ["archive", "unarchive"], isGone: isGone)
            #expect(plan == .invokeVerb)
        }
    }

    @Test("archive: ordering — declaring archive wins over a gone row (not rowOnlyGone)")
    func archiveOrderingArchiveBeatsGone() {
        let plan = RemoteLaneLifecycle.archivePlan(capabilities: ["archive"], isGone: true)
        #expect(plan == .invokeVerb)
        if case .rowOnlyGone = plan {
            Issue.record("expected invokeVerb to win over rowOnlyGone when archive is declared")
        }
    }

    @Test("archive: no capabilities, gone -> rowOnlyGone")
    func archiveNoCapabilitiesGoneRowOnlyGone() {
        let plan = RemoteLaneLifecycle.archivePlan(capabilities: [], isGone: true)
        #expect(plan == .rowOnlyGone)
    }

    @Test("archive: unarchive only, gone -> rowOnlyGone")
    func archiveUnarchiveOnlyGoneRowOnlyGone() {
        let plan = RemoteLaneLifecycle.archivePlan(capabilities: ["unarchive"], isGone: true)
        #expect(plan == .rowOnlyGone)
    }

    @Test("archive: unrelated capabilities, gone -> rowOnlyGone")
    func archiveUnrelatedCapabilitiesGoneRowOnlyGone() {
        let plan = RemoteLaneLifecycle.archivePlan(capabilities: ["log", "send", "attach"], isGone: true)
        #expect(plan == .rowOnlyGone)
    }

    @Test("archive: no capabilities, not gone -> refused")
    func archiveNoCapabilitiesNotGoneRefused() {
        let plan = RemoteLaneLifecycle.archivePlan(capabilities: [], isGone: false)
        guard case .refused(let message) = plan else {
            Issue.record("expected refused, got \(plan)")
            return
        }
        #expect(message.contains("archive"))
        #expect(message.contains("docs/remote-provider-contract.md"))
    }

    @Test("archive: stop only, not gone -> refused, and stop is never the reason")
    func archiveStopOnlyNotGoneRefused() {
        let plan = RemoteLaneLifecycle.archivePlan(capabilities: ["stop"], isGone: false)
        guard case .refused(let message) = plan else {
            Issue.record("expected refused for a provider declaring only stop, got \(plan)")
            return
        }
        #expect(message.contains("archive"))
        // The single most important negative property: stop is never
        // substituted for a missing archive, and never named as if it were
        // the fix.
        #expect(!message.contains("stop"))
    }

    @Test("archive: stop only, gone -> rowOnlyGone (still not invokeVerb, stop is irrelevant)")
    func archiveStopOnlyGoneRowOnlyGone() {
        let plan = RemoteLaneLifecycle.archivePlan(capabilities: ["stop"], isGone: true)
        #expect(plan == .rowOnlyGone)
    }

    @Test("archive: unrelated capabilities, not gone -> refused")
    func archiveUnrelatedCapabilitiesNotGoneRefused() {
        let plan = RemoteLaneLifecycle.archivePlan(capabilities: ["log", "send", "attach"], isGone: false)
        guard case .refused(let message) = plan else {
            Issue.record("expected refused, got \(plan)")
            return
        }
        #expect(message.contains("archive"))
    }

    // MARK: - Revive

    @Test("revive: declares unarchive -> invokeUnarchive, regardless of providerReportsArchived")
    func reviveDeclaresUnarchiveInvokesUnarchive() {
        for archived in [false, true] {
            let plan = RemoteLaneLifecycle.revivePlan(capabilities: ["unarchive"], providerReportsArchived: archived)
            #expect(plan == .invokeUnarchive)
        }
    }

    @Test("revive: declares archive+unarchive -> invokeUnarchive, regardless of providerReportsArchived")
    func reviveDeclaresArchiveAndUnarchiveInvokesUnarchive() {
        for archived in [false, true] {
            let plan = RemoteLaneLifecycle.revivePlan(
                capabilities: ["archive", "unarchive"],
                providerReportsArchived: archived
            )
            #expect(plan == .invokeUnarchive)
        }
    }

    @Test("revive: no capabilities, providerReportsArchived false -> rowOnly (anti-stranding)")
    func reviveNoCapabilitiesNotArchivedRowOnly() {
        let plan = RemoteLaneLifecycle.revivePlan(capabilities: [], providerReportsArchived: false)
        #expect(plan == .rowOnly)
    }

    @Test("revive: archive only, providerReportsArchived true -> refusedNoUnarchive")
    func reviveArchiveOnlyArchivedRefused() {
        let plan = RemoteLaneLifecycle.revivePlan(capabilities: ["archive"], providerReportsArchived: true)
        guard case .refusedNoUnarchive(let message) = plan else {
            Issue.record("expected refusedNoUnarchive, got \(plan)")
            return
        }
        #expect(message.contains("unarchive"))
        #expect(message.contains("docs/remote-provider-contract.md"))
    }

    @Test("revive: archive only, providerReportsArchived false -> rowOnly")
    func reviveArchiveOnlyNotArchivedRowOnly() {
        let plan = RemoteLaneLifecycle.revivePlan(capabilities: ["archive"], providerReportsArchived: false)
        #expect(plan == .rowOnly)
    }

    @Test("revive: stop only, providerReportsArchived true -> refusedNoUnarchive, and stop is never the reason")
    func reviveStopOnlyArchivedRefused() {
        let plan = RemoteLaneLifecycle.revivePlan(capabilities: ["stop"], providerReportsArchived: true)
        guard case .refusedNoUnarchive(let message) = plan else {
            Issue.record("expected refusedNoUnarchive, got \(plan)")
            return
        }
        #expect(message.contains("unarchive"))
        #expect(!message.contains("stop"))
    }

    @Test("revive: stop only, providerReportsArchived false -> rowOnly")
    func reviveStopOnlyNotArchivedRowOnly() {
        let plan = RemoteLaneLifecycle.revivePlan(capabilities: ["stop"], providerReportsArchived: false)
        #expect(plan == .rowOnly)
    }

    @Test("revive: unrelated capabilities, providerReportsArchived true -> refusedNoUnarchive")
    func reviveUnrelatedCapabilitiesArchivedRefused() {
        let plan = RemoteLaneLifecycle.revivePlan(
            capabilities: ["log", "send", "attach"],
            providerReportsArchived: true
        )
        guard case .refusedNoUnarchive(let message) = plan else {
            Issue.record("expected refusedNoUnarchive, got \(plan)")
            return
        }
        #expect(message.contains("unarchive"))
    }

    @Test("revive: unrelated capabilities, providerReportsArchived false -> rowOnly")
    func reviveUnrelatedCapabilitiesNotArchivedRowOnly() {
        let plan = RemoteLaneLifecycle.revivePlan(
            capabilities: ["log", "send", "attach"],
            providerReportsArchived: false
        )
        #expect(plan == .rowOnly)
    }

    // MARK: - Global negative property

    @Test("no plan anywhere ever invokes or references stop")
    func stopIsNeverInvokedAcrossFullPowerset() {
        // Exhaustive over the capability powerset the spec calls out, crossed
        // with every relevant boolean. Nowhere does "stop" appearing in the
        // capability set change the outcome relative to it being absent,
        // and no refusal message ever names "stop".
        let capabilitySets: [Set<String>] = [
            [],
            ["stop"],
            ["archive"],
            ["archive", "stop"],
            ["archive", "unarchive"],
            ["unarchive"],
            ["log", "send", "attach"],
        ]

        for capabilities in capabilitySets {
            let withoutStop = capabilities.subtracting(["stop"])

            for isGone in [false, true] {
                let plan = RemoteLaneLifecycle.archivePlan(capabilities: capabilities, isGone: isGone)
                let planWithoutStop = RemoteLaneLifecycle.archivePlan(capabilities: withoutStop, isGone: isGone)
                #expect(plan == planWithoutStop)
                if case .refused(let message) = plan {
                    #expect(!message.contains("stop"))
                }
            }

            for archived in [false, true] {
                let plan = RemoteLaneLifecycle.revivePlan(capabilities: capabilities, providerReportsArchived: archived)
                let planWithoutStop = RemoteLaneLifecycle.revivePlan(
                    capabilities: withoutStop,
                    providerReportsArchived: archived
                )
                #expect(plan == planWithoutStop)
                if case .refusedNoUnarchive(let message) = plan {
                    #expect(!message.contains("stop"))
                }
            }
        }
    }
}
