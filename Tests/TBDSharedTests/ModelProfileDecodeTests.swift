import Foundation
import Testing
@testable import TBDShared

@Suite("ModelProfile decoding")
struct ModelProfileDecodeTests {

    /// An unknown kind must degrade to .oauth, and must NOT take sibling
    /// profiles down with it — the list decodes as one array, so a throw
    /// would lose every profile rather than one row.
    @Test func unknownKindDegradesAndPreservesSiblings() throws {
        let json = """
        [
          {"id":"11111111-1111-1111-1111-111111111111","name":"future",
           "kind":"somethingNew","envOverrides":{},
           "createdAt":0,"sortOrder":0},
          {"id":"22222222-2222-2222-2222-222222222222","name":"normal",
           "kind":"apiKey","envOverrides":{},
           "createdAt":0,"sortOrder":0}
        ]
        """
        let profiles = try JSONDecoder().decode([ModelProfile].self,
                                                from: Data(json.utf8))
        #expect(profiles.count == 2)
        #expect(profiles[0].kind == .oauth)
        #expect(profiles[1].kind == .apiKey)
    }

    @Test func oauthTokenKindRoundTrips() throws {
        let profile = ModelProfile(name: "Acme (token)", kind: .oauthToken)
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ModelProfile.self, from: data)
        #expect(decoded.kind == .oauthToken)
        #expect(decoded.kindLabel == "Token")
    }

    /// The snapshot is a regenerating JSON blob: JSON written before the
    /// organizationID field existed must still decode, with nil.
    @Test func snapshotWithoutOrganizationIDDecodesToNil() throws {
        let json = """
        {"buckets":[],"lastAttemptAt":0,"status":"ok","statusKind":"ok"}
        """
        let snapshot = try JSONDecoder().decode(ProfileUsageSnapshot.self,
                                                from: Data(json.utf8))
        #expect(snapshot.organizationID == nil)
    }

    @Test func snapshotRoundTripsOrganizationID() throws {
        let snapshot = ProfileUsageSnapshot(
            buckets: [], lastAttemptAt: Date(), status: "ok",
            statusKind: .ok, organizationID: "org_abc123")
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ProfileUsageSnapshot.self, from: data)
        #expect(decoded.organizationID == "org_abc123")
    }
}
