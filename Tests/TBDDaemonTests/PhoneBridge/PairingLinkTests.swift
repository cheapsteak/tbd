import Foundation
import Testing

@testable import TBDDaemonLib

/// `phone/test-vectors/pairing-link.json`.
struct PairingLinkFile: Decodable {
    struct Valid: Decodable {
        let description: String
        let link: PairingLink
        let url: String
        let canonical: Bool
    }

    struct Invalid: Decodable {
        let description: String
        let url: String
        let error: String
        let field: String?
    }

    let loaderURL: String
    let now: Double
    let base64url: Base64URLVectors
    let valid: [Valid]
    let invalid: [Invalid]
}

@Suite("Phone channel: pairing link")
struct PairingLinkTests {
    private static let loaderURL = URL(string: "https://acme-loader.github.io/")!

    @Test func validVectors() throws {
        let file = try PhoneTestVectors.load("pairing-link.json", as: PairingLinkFile.self)
        let now = Date(timeIntervalSince1970: file.now)
        let loaderURL = try #require(URL(string: file.loaderURL))
        #expect(file.valid.count == 9)
        for c in file.valid {
            let url = try #require(URL(string: c.url), "\(c.description)")
            #expect(try PairingLink.parse(url, now: now) == c.link, "\(c.description)")
            if c.canonical {
                #expect(c.link.url(loaderURL: loaderURL).absoluteString == c.url, "\(c.description)")
            }
        }
    }

    @Test func invalidVectors() throws {
        let file = try PhoneTestVectors.load("pairing-link.json", as: PairingLinkFile.self)
        let now = Date(timeIntervalSince1970: file.now)
        #expect(file.invalid.count == 41)
        for c in file.invalid {
            let url = try #require(URL(string: c.url), "\(c.description)")
            do {
                let link = try PairingLink.parse(url, now: now)
                Issue.record("\(c.description): parsed to \(link), expected \(c.error)")
            } catch let error as PairingLinkError {
                #expect(error.code == c.error, "\(c.description)")
                if c.error == "badField" {
                    let field = try #require(c.field, "\(c.description)")
                    #expect(error == .badField(field), "\(c.description)")
                }
            }
        }
    }

    @Test func roundTripsRandomKeys() throws {
        let link = Self.link(exp: 2_000_000_000)
        let parsed = try PairingLink.parse(
            link.url(loaderURL: Self.loaderURL),
            now: Date(timeIntervalSince1970: 1_999_999_999)
        )
        #expect(parsed == link)
    }

    @Test func replacesAnExistingFragment() throws {
        let link = Self.link(exp: 2_000_000_000)
        let loaderURL = try #require(URL(string: "https://acme-loader.github.io/#old"))
        let url = link.url(loaderURL: loaderURL)
        #expect(url.absoluteString.hasPrefix("https://acme-loader.github.io/#p="))
        #expect(try PairingLink.parse(url, now: Date(timeIntervalSince1970: 1_999_999_999)) == link)
    }

    @Test func expiresAtExp() throws {
        let link = Self.link(exp: 1_800_000_300)
        let url = link.url(loaderURL: Self.loaderURL)
        #expect(try PairingLink.parse(url, now: Date(timeIntervalSince1970: 1_800_000_299)) == link)
        #expect(throws: PairingLinkError.expired) {
            _ = try PairingLink.parse(url, now: Date(timeIntervalSince1970: 1_800_000_300))
        }
    }

    /// The loader's `TextDecoder` drops one leading byte order mark and
    /// `JSON.parse` refuses a second, which `JSONDecoder` would skip.
    @Test func refusesASecondByteOrderMark() throws {
        let link = Self.link(exp: 2_000_000_000)
        let now = Date(timeIntervalSince1970: 1_999_999_999)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(link)
        let mark = Data([0xEF, 0xBB, 0xBF])
        let oneMark = try #require(URL(string: "https://acme-loader.github.io/#p=" + Base64URL.encode(mark + json)))
        let twoMarks = try #require(
            URL(string: "https://acme-loader.github.io/#p=" + Base64URL.encode(mark + mark + json))
        )
        #expect(try PairingLink.parse(oneMark, now: now) == link)
        #expect(throws: PairingLinkError.badJSON) {
            _ = try PairingLink.parse(twoMarks, now: now)
        }
    }

    /// No vector pins the relay host's 253-byte limit, so this checks both
    /// sides of it.
    @Test func relayHostIsAtMost253Bytes() throws {
        let now = Date(timeIntervalSince1970: 1_999_999_999)
        let longestHost = String(repeating: "a.", count: 126) + "a"
        var link = Self.link(exp: 2_000_000_000)
        link.relay = "https://" + longestHost
        #expect(try PairingLink.parse(link.url(loaderURL: Self.loaderURL), now: now) == link)
        link.relay = "https://" + longestHost + "a"
        let tooLong = link.url(loaderURL: Self.loaderURL)
        #expect(throws: PairingLinkError.badField("relay")) {
            _ = try PairingLink.parse(tooLong, now: now)
        }
    }

    /// A valid link with fresh random 32-byte room, secret and key.
    private static func link(exp: Int) -> PairingLink {
        PairingLink(
            v: PairingLink.currentVersion,
            relay: "https://acme-relay.acme.workers.dev",
            room: randomKey(),
            secret: randomKey(),
            key: randomKey(),
            name: "Acme Mini",
            exp: exp
        )
    }

    private static func randomKey() -> String {
        Base64URL.encode(PhoneTestVectors.randomBytes(32))
    }
}
