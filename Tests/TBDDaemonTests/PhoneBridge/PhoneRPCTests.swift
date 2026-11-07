import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1 – the nine laptop-side phone control methods through
/// `RPCRouter.handle`, over an in-memory database and a fake bridge.
///
/// Every method is app-only, so the first two tests run all nine: each one
/// refuses every caller that is not the TBD app with no side effect at all,
/// and answers the app. The app-binary tests then run all nine against each
/// way the caller's executable can pass or fail `PhoneAppBinaryCheck`. The
/// rest pin what each method does for the app.
@Suite("PhoneRPC")
struct PhoneRPCTests {

    static let relayURL = "https://acme-relay.acme.workers.dev"
    static let loaderURL = "https://acme.github.io/loader/"

    private struct Fixture {
        let db: TBDDatabase
        let router: RPCRouter
        let fake: FakePhoneBridgeController
        let deltas: PhoneStatusDeltaCounter
    }

    /// A router built as `RPCRouterPromptHandlerTests` builds one, on which
    /// `SendHarness.AuthenticatedApp.connection` authenticates as the app, and
    /// whose app binary check sees the installed layout, where the app runs
    /// `/Applications/TBD.app`. `withBridge: false` leaves `phoneBridge` nil,
    /// as in mock mode.
    private func makeFixture(
        withBridge: Bool = true,
        processSignaller: any ProcessSignaller = SendHarness.AuthenticatedApp.Signaller(),
        binaryCheck: PhoneAppBinaryCheck = PhoneRPCTests.installedLayout
    ) async throws -> Fixture {
        let logPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-phone-rpc-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("actuations.jsonl").path
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            recordedAppIdentity: { SendHarness.AuthenticatedApp.identity },
            processSignaller: processSignaller,
            actuationLog: ActuationLog(path: logPath))
        router.phoneAppBinaryCheck = binaryCheck
        let fake = FakePhoneBridgeController()
        if withBridge {
            router.phoneBridge = fake
        }
        let deltas = PhoneStatusDeltaCounter()
        _ = router.registerSubscription { data in
            deltas.record(data)
            return true
        }
        return Fixture(db: db, router: router, fake: fake, deltas: deltas)
    }

    private static func device(
        name: String = "iPhone", pairedAt: TimeInterval = 1_800_000_000
    ) -> PhoneDevice {
        PhoneDevice(
            id: UUID(), name: name, publicKey: Data(repeating: 7, count: 32),
            roomID: UUID().uuidString, pairedAt: Date(timeIntervalSince1970: pairedAt))
    }

    /// A request for `method` with params the app would send, so a handler
    /// that read or wrote anything before checking the caller would show it.
    private static func validRequest(_ method: String, deviceID: UUID) throws -> RPCRequest {
        switch method {
        case RPCMethod.phonePairAllow, RPCMethod.phonePairDeny:
            return try RPCRequest(method: method, params: PhonePairOfferParams(offerID: UUID()))
        case RPCMethod.phoneRevoke:
            return try RPCRequest(method: method, params: PhoneRevokeParams(deviceID: deviceID))
        case RPCMethod.configSetPhoneControlEnabled:
            return try RPCRequest(method: method, params: ConfigSetPhoneControlEnabledParams(enabled: true))
        case RPCMethod.configSetPhoneRelayURL:
            return try RPCRequest(method: method, params: ConfigSetPhoneURLParams(url: relayURL))
        case RPCMethod.configSetPhoneLoaderURL:
            return try RPCRequest(method: method, params: ConfigSetPhoneURLParams(url: loaderURL))
        default:
            return RPCRequest(method: method)
        }
    }

    // MARK: - The app binary check's world

    /// Where the fixture's daemon runs from, and the candidates beside it.
    static let daemonExecutable = URL(fileURLWithPath: "/acme/tree/.build/debug/TBDDaemon")
    static let siblingAppBinary = "/acme/tree/.build/debug/TBDApp"
    static let siblingBundleBinary = "/acme/tree/.build/debug/TBD.app/Contents/MacOS/TBDApp"
    static let installedAppBinary = PhoneAppBinaryCheck.installedAppBinaryPath

    /// The file the app runs.
    static let appFile = PhoneAppBinaryCheck.FileIdentity(device: 1, inode: 1001)
    /// The build output, which the installed copy in `/Applications` does not share.
    static let buildOutputFile = PhoneAppBinaryCheck.FileIdentity(device: 1, inode: 2002)

    /// A check over a stated process table and file system: the app's pid
    /// runs `callerPath` (nil: the path cannot be read), each path in `files`
    /// exists as that file, and every other path does not exist. The
    /// candidates are the ones production derives from `daemonExecutable`.
    static func binaryCheck(
        callerPath: String?, files: [String: PhoneAppBinaryCheck.FileIdentity]
    ) -> PhoneAppBinaryCheck {
        let appPID = SendHarness.AuthenticatedApp.pid
        let candidates = PhoneAppBinaryCheck.candidatePaths(besideDaemonAt: PhoneRPCTests.daemonExecutable)
        return PhoneAppBinaryCheck(
            executablePath: { pid in pid == appPID ? callerPath : nil },
            fileIdentity: { files[$0] },
            appBinaryPaths: { candidates })
    }

    /// `scripts/restart.sh` on an install-ready tree, and `tbd update`: the
    /// app runs the cloned copy in `/Applications`, a file apart from the
    /// build output beside the daemon.
    static let installedLayout = binaryCheck(
        callerPath: installedAppBinary,
        files: [
            siblingAppBinary: buildOutputFile,
            siblingBundleBinary: buildOutputFile,
            installedAppBinary: appFile,
        ])

    /// Calls each of the nine as the app, with the params it sends, and
    /// checks that every one answers.
    private func expectEveryMethodAnswers(_ f: Fixture) async throws {
        let device = Self.device()
        try await f.db.phoneDevices.insert(device)
        for method in RPCMethod.phoneAppOnlyMethods {
            let request = try Self.validRequest(method, deviceID: device.id)
            let r = await f.router.handle(request, connection: SendHarness.AuthenticatedApp.connection)
            #expect(r.success, "\(method): \(r.error ?? "no error")")
        }
    }

    /// Calls each of the nine as the app, with the params it sends, and
    /// checks that every one is refused with `refusal` before anything
    /// happens: no bridge call, no config write, no row deleted, no delta.
    private func expectEveryMethodRefused(_ f: Fixture, with refusal: String) async throws {
        let device = Self.device()
        try await f.db.phoneDevices.insert(device)
        for method in RPCMethod.phoneAppOnlyMethods {
            let request = try Self.validRequest(method, deviceID: device.id)
            let r = await f.router.handle(request, connection: SendHarness.AuthenticatedApp.connection)
            #expect(r.success == false)
            #expect(r.error == refusal, "\(method)")
        }
        let calls = await f.fake.calls
        #expect(calls.isEmpty)
        let config = try await f.db.config.get()
        #expect(config.phoneControlEnabled == false)
        #expect(config.phoneRelayURL == nil)
        #expect(config.phoneLoaderURL == nil)
        let rows = try await f.db.phoneDevices.list()
        #expect(rows == [device])
        #expect(f.deltas.count == 0)
    }

    /// Calls `method` as the TBD app, with no params.
    private func appCall(_ f: Fixture, _ method: String) async -> RPCResponse {
        await f.router.handle(
            RPCRequest(method: method), connection: SendHarness.AuthenticatedApp.connection)
    }

    /// Calls `method` as the TBD app.
    private func appCall<P: Encodable>(
        _ f: Fixture, _ method: String, _ params: P
    ) async throws -> RPCResponse {
        let request = try RPCRequest(method: method, params: params)
        return await f.router.handle(request, connection: SendHarness.AuthenticatedApp.connection)
    }

    // MARK: - App-only

    /// Every caller but the app is refused before anything happens: no bridge
    /// call, no config write, no row deleted, no delta. Empty params are
    /// refused too, which a handler that decoded params before checking the
    /// caller would answer with a decode error instead. And an earlier case in
    /// `RPCRouter.handle` that shadowed the phone dispatch would answer without
    /// this refusal.
    @Test(arguments: RPCMethod.phoneAppOnlyMethods)
    func everyPhoneMethodRefusesANonAppCaller(method: String) async throws {
        let f = try await makeFixture()
        let device = Self.device()
        try await f.db.phoneDevices.insert(device)
        let callers: [RPCConnectionContext?] = [
            nil,
            RPCConnectionContext(peerPID: nil),
            RPCConnectionContext(peerPID: 4321),
        ]
        let requests = try [RPCRequest(method: method), Self.validRequest(method, deviceID: device.id)]
        for connection in callers {
            for request in requests {
                let r = await f.router.handle(request, connection: connection)
                #expect(r.success == false)
                #expect(
                    r.error == RPCRouter.phoneNotFromAppRefusal,
                    "\(method) from \(String(describing: connection)) with \(request.params)")
            }
        }
        let calls = await f.fake.calls
        #expect(calls.isEmpty)
        let config = try await f.db.config.get()
        #expect(config.phoneControlEnabled == false)
        #expect(config.phoneRelayURL == nil)
        #expect(config.phoneLoaderURL == nil)
        let rows = try await f.db.phoneDevices.list()
        #expect(rows == [device])
        #expect(f.deltas.count == 0)
    }

    /// The same nine answer the app, with the params it sends.
    @Test(arguments: RPCMethod.phoneAppOnlyMethods)
    func everyPhoneMethodAnswersTheApp(method: String) async throws {
        let f = try await makeFixture()
        let device = Self.device()
        try await f.db.phoneDevices.insert(device)
        let request = try Self.validRequest(method, deviceID: device.id)
        let r = await f.router.handle(request, connection: SendHarness.AuthenticatedApp.connection)
        #expect(r.success, "\(method): \(r.error ?? "no error")")
    }

    /// The recorded app's pid now holds a process that started a second
    /// later: the pid was reused. The envelope check refuses it, though its
    /// executable is the installed app.
    @Test func aReusedAppPIDIsRefused() async throws {
        let f = try await makeFixture(processSignaller: ReusedAppPIDSignaller())
        try await expectEveryMethodRefused(f, with: RPCRouter.phoneNotFromAppRefusal)
    }

    // MARK: - The app binary

    @Test func theCandidatesAreTheDaemonsSiblingItsBundleAndTheInstalledApp() {
        let candidates = PhoneAppBinaryCheck.candidatePaths(besideDaemonAt: Self.daemonExecutable)
        #expect(candidates == [Self.siblingAppBinary, Self.siblingBundleBinary, Self.installedAppBinary])
        let withoutADaemonPath = PhoneAppBinaryCheck.candidatePaths(besideDaemonAt: nil)
        #expect(withoutADaemonPath == [Self.installedAppBinary])
    }

    /// The app run straight from the build output beside the daemon.
    @Test func theAppBinaryBesideTheDaemonIsAccepted() async throws {
        let check = Self.binaryCheck(
            callerPath: Self.siblingAppBinary,
            files: [Self.siblingAppBinary: Self.appFile, Self.installedAppBinary: Self.buildOutputFile])
        let f = try await makeFixture(binaryCheck: check)
        try await expectEveryMethodAnswers(f)
    }

    /// A WIP restart: the app runs the bundle beside the daemon. The build
    /// output was rebuilt since the bundle linked it, so only the bundle
    /// matches.
    @Test func theAppBundleBesideTheDaemonIsAccepted() async throws {
        let check = Self.binaryCheck(
            callerPath: Self.siblingBundleBinary,
            files: [
                Self.siblingAppBinary: Self.buildOutputFile,
                Self.siblingBundleBinary: Self.appFile,
            ])
        let f = try await makeFixture(binaryCheck: check)
        try await expectEveryMethodAnswers(f)
    }

    /// The installed layout: the app runs `/Applications/TBD.app`, a copy
    /// that shares no inode with the build output beside the daemon.
    @Test func theInstalledAppIsAccepted() async throws {
        let f = try await makeFixture(binaryCheck: Self.installedLayout)
        try await expectEveryMethodAnswers(f)
    }

    /// The caller runs another file: one with another inode on the app's
    /// device, and one with the app's inode number on another device.
    @Test func aDifferentExecutableIsRefused() async throws {
        let strangers = [
            PhoneAppBinaryCheck.FileIdentity(device: 1, inode: 3003),
            PhoneAppBinaryCheck.FileIdentity(device: 2, inode: Self.appFile.inode),
        ]
        for stranger in strangers {
            let caller = "/acme/elsewhere/TBD.app/Contents/MacOS/TBDApp"
            let check = Self.binaryCheck(
                callerPath: caller,
                files: [
                    caller: stranger,
                    Self.siblingAppBinary: Self.buildOutputFile,
                    Self.siblingBundleBinary: Self.buildOutputFile,
                    Self.installedAppBinary: Self.appFile,
                ])
            let f = try await makeFixture(binaryCheck: check)
            try await expectEveryMethodRefused(f, with: RPCRouter.phoneNotFromAppBinaryRefusal)
        }
    }

    /// None of the candidates exists, so there is nothing to compare with.
    @Test func noAppBinaryPresentIsRefused() async throws {
        let caller = "/acme/elsewhere/TBDApp"
        let check = Self.binaryCheck(callerPath: caller, files: [caller: Self.appFile])
        let f = try await makeFixture(binaryCheck: check)
        try await expectEveryMethodRefused(f, with: RPCRouter.phoneNotFromAppBinaryRefusal)
    }

    /// `proc_pidpath` could not name the caller's executable.
    @Test func anUnreadableCallerPathIsRefused() async throws {
        let check = Self.binaryCheck(
            callerPath: nil,
            files: [
                Self.siblingAppBinary: Self.appFile,
                Self.siblingBundleBinary: Self.appFile,
                Self.installedAppBinary: Self.appFile,
            ])
        let f = try await makeFixture(binaryCheck: check)
        try await expectEveryMethodRefused(f, with: RPCRouter.phoneNotFromAppBinaryRefusal)
    }

    /// The caller's path was read but cannot be stat'ed, as when its file was
    /// removed while it runs.
    @Test func anUnstatableCallerIsRefused() async throws {
        let check = Self.binaryCheck(
            callerPath: Self.installedAppBinary,
            files: [Self.siblingAppBinary: Self.appFile, Self.siblingBundleBinary: Self.appFile])
        let f = try await makeFixture(binaryCheck: check)
        try await expectEveryMethodRefused(f, with: RPCRouter.phoneNotFromAppBinaryRefusal)
    }

    // MARK: - Settings

    @Test func setPhoneControlEnabledWritesReconcilesAndBroadcasts() async throws {
        let f = try await makeFixture()
        let r = try await appCall(
            f, RPCMethod.configSetPhoneControlEnabled, ConfigSetPhoneControlEnabledParams(enabled: true))
        #expect(r.success, "\(r.error ?? "no error")")
        let config = try await f.db.config.get()
        #expect(config.phoneControlEnabled == true)
        let calls = await f.fake.calls
        #expect(calls == ["reconcile"])
        #expect(f.deltas.count == 1)
    }

    @Test func theRelayURLIsSavedOnlyAfterACheckPasses() async throws {
        let f = try await makeFixture()
        let pasted = ConfigSetPhoneURLParams(url: "https://ACME-relay.acme.workers.dev/")
        let check = "checkRelay \(Self.relayURL)"

        // The check fails: its text comes back and nothing is saved.
        let refusal = PhoneBridgeError.unsupportedRelayAPI([2])
        await f.fake.failCheckRelay(with: refusal)
        let refused = try await appCall(f, RPCMethod.configSetPhoneRelayURL, pasted)
        #expect(refused.error == refusal.localizedDescription)
        var config = try await f.db.config.get()
        #expect(config.phoneRelayURL == nil)
        var calls = await f.fake.calls
        #expect(calls == [check])
        #expect(f.deltas.count == 0)

        // The check passes: the normalized URL is saved, then the bridge reconciles.
        await f.fake.failCheckRelay(with: nil)
        let saved = try await appCall(f, RPCMethod.configSetPhoneRelayURL, pasted)
        #expect(saved.success, "\(saved.error ?? "no error")")
        config = try await f.db.config.get()
        #expect(config.phoneRelayURL == Self.relayURL)
        calls = await f.fake.calls
        #expect(calls == [check, check, "reconcile"])
        #expect(f.deltas.count == 1)

        // Saving the same URL again checks it again ("Check Again").
        let again = try await appCall(f, RPCMethod.configSetPhoneRelayURL, pasted)
        #expect(again.success, "\(again.error ?? "no error")")
        calls = await f.fake.calls
        #expect(calls == [check, check, "reconcile", check, "reconcile"])

        // A failed check of another URL leaves the saved one in place.
        await f.fake.failCheckRelay(with: .notATBDRelay)
        let other = try await appCall(
            f, RPCMethod.configSetPhoneRelayURL, ConfigSetPhoneURLParams(url: "https://acme.example"))
        #expect(other.error == PhoneBridgeError.notATBDRelay.localizedDescription)
        config = try await f.db.config.get()
        #expect(config.phoneRelayURL == Self.relayURL)

        // Nil and blank remove the relay without a check.
        await f.fake.clearCalls()
        for url in [nil, "  "] as [String?] {
            try await f.db.config.setPhoneRelayURL(Self.relayURL)
            let cleared = try await appCall(
                f, RPCMethod.configSetPhoneRelayURL, ConfigSetPhoneURLParams(url: url))
            #expect(cleared.success, "\(cleared.error ?? "no error")")
            config = try await f.db.config.get()
            #expect(config.phoneRelayURL == nil)
        }
        calls = await f.fake.calls
        #expect(calls == ["reconcile", "reconcile"])
    }

    @Test func aPublicHTTPRelayURLIsRefusedBeforeAnyCheck() async throws {
        let f = try await makeFixture()
        let refusals: [(String, PhoneURLValidation.Failure)] = [
            ("http://acme-relay.acme.workers.dev", .unsupportedScheme),
            ("wss://acme-relay.acme.workers.dev", .unsupportedScheme),
            ("acme-relay.acme.workers.dev", .notAURL),
            ("https://acme-relay.acme.workers.dev/?room=1", .hasQuery),
        ]
        for (raw, failure) in refusals {
            let r = try await appCall(f, RPCMethod.configSetPhoneRelayURL, ConfigSetPhoneURLParams(url: raw))
            #expect(r.error == failure.localizedDescription, "\(raw)")
        }
        let calls = await f.fake.calls
        #expect(calls.isEmpty)
        let config = try await f.db.config.get()
        #expect(config.phoneRelayURL == nil)
        #expect(f.deltas.count == 0)
    }

    @Test func theLoaderURLStoresAndClears() async throws {
        let f = try await makeFixture()
        let saved = try await appCall(
            f, RPCMethod.configSetPhoneLoaderURL, ConfigSetPhoneURLParams(url: " https://ACME.github.io/loader/ "))
        #expect(saved.success, "\(saved.error ?? "no error")")
        var config = try await f.db.config.get()
        #expect(config.phoneLoaderURL == Self.loaderURL)
        #expect(f.deltas.count == 1)

        let refused = try await appCall(
            f, RPCMethod.configSetPhoneLoaderURL, ConfigSetPhoneURLParams(url: "https://acme.github.io/loader/#p=1"))
        #expect(refused.error == PhoneURLValidation.Failure.hasFragment.localizedDescription)
        config = try await f.db.config.get()
        #expect(config.phoneLoaderURL == Self.loaderURL)
        #expect(f.deltas.count == 1)

        let cleared = try await appCall(f, RPCMethod.configSetPhoneLoaderURL, ConfigSetPhoneURLParams(url: nil))
        #expect(cleared.success, "\(cleared.error ?? "no error")")
        config = try await f.db.config.get()
        #expect(config.phoneLoaderURL == nil)
        #expect(f.deltas.count == 2)

        // The loader URL is read at the next pairing; the bridge is not asked.
        let calls = await f.fake.calls
        #expect(calls.isEmpty)
    }

    // MARK: - Status and devices

    @Test func statusComesFromTheBridge() async throws {
        let f = try await makeFixture()
        let r = await appCall(f, RPCMethod.phoneStatus)
        let status = try r.decodeResult(PhoneStatusResult.self)
        #expect(status == FakePhoneBridgeController.cannedStatus)
        let calls = await f.fake.calls
        #expect(calls == ["status"])
    }

    @Test func statusWithoutABridgeSaysUnavailable() async throws {
        let f = try await makeFixture(withBridge: false)
        var status = try await appCall(f, RPCMethod.phoneStatus).decodeResult(PhoneStatusResult.self)
        #expect(status.running == false && status.problem == RPCRouter.phoneUnavailableRefusal)
        #expect(status.enabled == false && status.relayURL == nil && status.loaderURLOverride == nil)
        #expect(status.relay.state == .notSetUp)
        #expect(status.relay.bundledVersion == PhoneBridgeConstants.bundledRelayVersion)
        #expect(status.connectedDeviceIDs.isEmpty && status.pairing == nil)

        try await f.db.config.setPhoneControlEnabled(true)
        try await f.db.config.setPhoneRelayURL(Self.relayURL)
        try await f.db.config.setPhoneLoaderURL(Self.loaderURL)
        status = try await appCall(f, RPCMethod.phoneStatus).decodeResult(PhoneStatusResult.self)
        #expect(status.running == false && status.problem == RPCRouter.phoneUnavailableRefusal)
        #expect(status.enabled == true)
        #expect(status.relayURL == Self.relayURL && status.loaderURLOverride == Self.loaderURL)
        #expect(status.relay.state == .unknown)
    }

    @Test func devicesListsTheRows() async throws {
        let f = try await makeFixture(withBridge: false)
        let older = Self.device(name: "Older", pairedAt: 1_800_000_000)
        let newer = Self.device(name: "Newer", pairedAt: 1_800_000_100)
        try await f.db.phoneDevices.insert(newer)
        try await f.db.phoneDevices.insert(older)
        let result = try await appCall(f, RPCMethod.phoneDevices).decodeResult(PhoneDeviceListResult.self)
        #expect(result.devices == [older, newer])
    }

    // MARK: - Pairing and revoking

    @Test func pairingAndRevokeForwardToTheBridge() async throws {
        let f = try await makeFixture()
        let offerID = UUID()
        let deviceID = UUID()

        let started = await appCall(f, RPCMethod.phonePairStart)
        let pairing = try started.decodeResult(PhonePairingStatus.self)
        #expect(pairing == FakePhoneBridgeController.cannedPairing)

        let allowed = try await appCall(f, RPCMethod.phonePairAllow, PhonePairOfferParams(offerID: offerID))
        let device = try allowed.decodeResult(PhoneDevice.self)
        #expect(device == FakePhoneBridgeController.cannedDevice)

        let denied = try await appCall(f, RPCMethod.phonePairDeny, PhonePairOfferParams(offerID: offerID))
        #expect(denied.success, "\(denied.error ?? "no error")")
        let revoked = try await appCall(f, RPCMethod.phoneRevoke, PhoneRevokeParams(deviceID: deviceID))
        #expect(revoked.success, "\(revoked.error ?? "no error")")

        let calls = await f.fake.calls
        #expect(calls == ["pairStart", "pairAllow \(offerID)", "pairDeny \(offerID)", "revoke \(deviceID)"])
    }

    /// A bridge error comes back as the sentence its description gives, never
    /// as Swift's rendering of the enum case.
    @Test func bridgeErrorsReachTheCallerAsTheirDescription() async throws {
        let f = try await makeFixture()
        let failure = PhoneBridgeError.relayCheckFailed("the relay answered 503")
        await f.fake.failBridgeCalls(with: failure)
        let offer = PhonePairOfferParams(offerID: UUID())
        let responses = try await [
            appCall(f, RPCMethod.phonePairStart),
            appCall(f, RPCMethod.phonePairAllow, offer),
            appCall(f, RPCMethod.phonePairDeny, offer),
            appCall(f, RPCMethod.phoneRevoke, PhoneRevokeParams(deviceID: UUID())),
        ]
        for r in responses {
            #expect(r.success == false)
            #expect(r.error == failure.localizedDescription)
        }
    }

    @Test func withoutABridgeTheBridgeMethodsSayUnavailable() async throws {
        let f = try await makeFixture(withBridge: false)
        let offer = PhonePairOfferParams(offerID: UUID())
        let responses = try await [
            appCall(f, RPCMethod.phonePairStart),
            appCall(f, RPCMethod.phonePairAllow, offer),
            appCall(f, RPCMethod.phonePairDeny, offer),
            appCall(f, RPCMethod.phoneRevoke, PhoneRevokeParams(deviceID: UUID())),
            appCall(f, RPCMethod.configSetPhoneRelayURL, ConfigSetPhoneURLParams(url: Self.relayURL)),
        ]
        for r in responses {
            #expect(r.error == RPCRouter.phoneUnavailableRefusal)
        }
        var config = try await f.db.config.get()
        #expect(config.phoneRelayURL == nil)
        #expect(f.deltas.count == 0)

        // The settings that need no bridge still save.
        let enabled = try await appCall(
            f, RPCMethod.configSetPhoneControlEnabled, ConfigSetPhoneControlEnabledParams(enabled: true))
        #expect(enabled.success, "\(enabled.error ?? "no error")")
        try await f.db.config.setPhoneRelayURL(Self.relayURL)
        let cleared = try await appCall(f, RPCMethod.configSetPhoneRelayURL, ConfigSetPhoneURLParams(url: nil))
        #expect(cleared.success, "\(cleared.error ?? "no error")")
        config = try await f.db.config.get()
        #expect(config.phoneControlEnabled == true)
        #expect(config.phoneRelayURL == nil)
        #expect(f.deltas.count == 2)
    }
}

/// The recorded app's pid, now held by a process that started a second after
/// the recorded one: the same pid and command line, a different process. Inert
/// on the signalling half, like `SendHarness.AuthenticatedApp.Signaller`.
private struct ReusedAppPIDSignaller: ProcessSignaller {
    func isAlive(_ pid: Int32) -> Bool { true }
    func startTime(_ pid: Int32) -> Date? {
        SendHarness.AuthenticatedApp.startedAt.addingTimeInterval(1)
    }
    func commandLine(_ pid: Int32) -> String? { SendHarness.AuthenticatedApp.commandLine }
    func stat(_ pid: Int32) -> String? { nil }
    func children(ofServerPID serverPID: Int32) -> [Int32] { [] }
    func terminate(_ pid: Int32) {}
    func forceKill(_ pid: Int32) {}
}

/// Records each bridge call by name and answers with canned values.
private actor FakePhoneBridgeController: PhoneBridgeControlling {
    static let cannedStatus = PhoneStatusResult(
        enabled: true, relayURL: PhoneRPCTests.relayURL, loaderURLOverride: nil, running: true,
        problem: nil,
        relay: PhoneRelayStatus(state: .connected, version: "1.0.0", bundledVersion: "1.0.0"),
        connectedDeviceIDs: [], pairing: nil)
    static let cannedPairing = PhonePairingStatus(
        offerID: UUID(), link: "https://acme.github.io/loader/#p=acme",
        expiresAt: Date(timeIntervalSince1970: 1_800_000_300), state: .waitingForPhone)
    static let cannedDevice = PhoneDevice(
        id: UUID(), name: "iPhone", publicKey: Data(repeating: 9, count: 32),
        roomID: "acme-room", pairedAt: Date(timeIntervalSince1970: 1_800_000_000))

    private(set) var calls: [String] = []
    private var checkRelayFailure: PhoneBridgeError?
    private var bridgeCallFailure: PhoneBridgeError?

    func failCheckRelay(with error: PhoneBridgeError?) { checkRelayFailure = error }
    /// Makes `pairStart`, `pairAllow`, `pairDeny` and `revoke` throw `error`.
    func failBridgeCalls(with error: PhoneBridgeError?) { bridgeCallFailure = error }
    func clearCalls() { calls = [] }

    func reconcile() async { calls.append("reconcile") }

    func checkRelay(_ url: URL) async throws -> PhoneRelayInfo {
        calls.append("checkRelay \(url.absoluteString)")
        if let checkRelayFailure { throw checkRelayFailure }
        return PhoneRelayInfo(name: "tbd-relay", version: "1.0.0", api: [1])
    }

    func status() async -> PhoneStatusResult {
        calls.append("status")
        return Self.cannedStatus
    }

    func pairStart() async throws -> PhonePairingStatus {
        calls.append("pairStart")
        if let bridgeCallFailure { throw bridgeCallFailure }
        return Self.cannedPairing
    }

    func pairAllow(offerID: UUID) async throws -> PhoneDevice {
        calls.append("pairAllow \(offerID)")
        if let bridgeCallFailure { throw bridgeCallFailure }
        return Self.cannedDevice
    }

    func pairDeny(offerID: UUID) async throws {
        calls.append("pairDeny \(offerID)")
        if let bridgeCallFailure { throw bridgeCallFailure }
    }

    func revoke(deviceID: UUID) async throws {
        calls.append("revoke \(deviceID)")
        if let bridgeCallFailure { throw bridgeCallFailure }
    }
}

/// Counts the `.phoneStatusChanged` deltas the router broadcasts. A
/// lock-guarded class, because a subscriber callback is synchronous.
private final class PhoneStatusDeltaCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func record(_ data: Data) {
        guard let delta = try? JSONDecoder().decode(StateDelta.self, from: data),
              case .phoneStatusChanged = delta else { return }
        lock.lock(); defer { lock.unlock() }
        storage += 1
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
