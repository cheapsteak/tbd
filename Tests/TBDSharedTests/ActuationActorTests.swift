import Foundation
import Testing
@testable import TBDShared

/// Tier 1. The caller-identity declaration and its transport on `RPCRequest`.
///
/// Assertions whitelist the keys a shape is allowed to carry rather than
/// blacklisting ones it must not: a blacklist passes for a row that grew an
/// unexpected key nobody named.
@Suite("Actuation actor")
struct ActuationActorTests {

    private func encodedObject(_ actor: ActuationActor) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(actor)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    @Test("daemon actor is an object carrying only its kind")
    func daemonIsObjectWithKindOnly() throws {
        let object = try encodedObject(.daemon())
        #expect(Set(object.keys) == ["kind"])
        #expect(object["kind"] as? String == "daemon")
    }

    @Test("a daemon rail names the internal subsystem")
    func daemonRail() throws {
        let object = try encodedObject(.daemon(rail: "limit-resume"))
        #expect(Set(object.keys) == ["kind", "rail"])
        #expect(object["rail"] as? String == "limit-resume")
    }

    @Test("app actor is an object, never a bare string")
    func appIsObject() throws {
        let object = try encodedObject(.app)
        #expect(Set(object.keys) == ["kind"])
        #expect(object["kind"] as? String == "app")
    }

    @Test("a session declaring both coordinates carries both")
    func sessionCarriesBothCoordinates() throws {
        let actor = try #require(
            ActuationActor.session(worktree: "WT-UUID", terminal: "TERM-UUID"))
        let object = try encodedObject(actor)
        #expect(Set(object.keys) == ["kind", "terminal", "worktree"])
        #expect(object["kind"] as? String == "session")
        #expect(object["worktree"] as? String == "WT-UUID")
        #expect(object["terminal"] as? String == "TERM-UUID")
    }

    @Test("a partial declaration carries just the declared field")
    func sessionPartialDeclaration() throws {
        let actor = try #require(ActuationActor.session(worktree: "WT-UUID", terminal: nil))
        let object = try encodedObject(actor)
        #expect(Set(object.keys) == ["kind", "worktree"])
    }

    @Test("declaring neither coordinate is not a session")
    func sessionWithNothingDeclaredIsNil() {
        #expect(ActuationActor.session(worktree: nil, terminal: nil) == nil)
        #expect(ActuationActor.session(worktree: "", terminal: "") == nil)
    }

    @Test("a session is read out of the ambient TBD environment")
    func sessionFromEnvironment() throws {
        let actor = try #require(ActuationActor.sessionFromEnvironment([
            "TBD_WORKTREE_ID": "WT", "TBD_TERMINAL_ID": "TERM", "PATH": "/usr/bin",
        ]))
        #expect(actor.kind == "session")
        #expect(actor.worktree == "WT")
        #expect(actor.terminal == "TERM")
        #expect(ActuationActor.sessionFromEnvironment(["PATH": "/usr/bin"]) == nil)
    }

    @Test("a kind reserved for later work still decodes")
    func reservedKindDecodes() throws {
        let json = #"{"kind":"supervisor","project":"acme-web"}"#
        let actor = try JSONDecoder().decode(ActuationActor.self, from: Data(json.utf8))
        #expect(actor.kind == "supervisor")
        #expect(actor.project == "acme-web")
    }

    @Test("an unknown key on a known kind is ignored rather than failing the decode")
    func unknownKeyIgnored() throws {
        let json = #"{"kind":"daemon","somethingNewer":"x"}"#
        let actor = try JSONDecoder().decode(ActuationActor.self, from: Data(json.utf8))
        #expect(actor.kind == "daemon")
    }
}

@Suite("RPCRequest actor field")
struct RPCRequestActorTests {

    @Test("an absent actor decodes as nil — the daemon records anonymous")
    func absentActorDecodesNil() throws {
        let json = #"{"method":"terminal.send","params":"{}"}"#
        let request = try JSONDecoder().decode(RPCRequest.self, from: Data(json.utf8))
        #expect(request.method == "terminal.send")
        #expect(request.actor == nil)
    }

    @Test("a declared actor rides beside method and params, not inside them")
    func actorIsTopLevel() throws {
        let request = RPCRequest(
            method: "terminal.send", params: "{}", actor: .app)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any])
        #expect(Set(object.keys) == ["actor", "method", "params"])
        let actor = try #require(object["actor"] as? [String: Any])
        #expect(actor["kind"] as? String == "app")
        // The params blob is untouched — no verb's parameter shape changes.
        #expect(object["params"] as? String == "{}")
    }

    @Test("a request with no identity omits the key entirely, so old daemons see no change")
    func undeclaredActorOmitsKey() throws {
        let request = RPCRequest(method: "terminal.send", params: "{}")
        let object = try #require(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(Set(object.keys) == ["method", "params"])
    }

    @Test("stamping fills an undeclared identity and leaves a declared one alone")
    func stampingIsNonDestructive() {
        let bare = RPCRequest(method: "terminal.send")
        #expect(bare.stamping(actor: .app).actor == .app)

        let declared = RPCRequest(method: "terminal.send", actor: .daemon())
        #expect(declared.stamping(actor: .app).actor == .daemon())

        #expect(bare.stamping(actor: nil).actor == nil)
    }
}
