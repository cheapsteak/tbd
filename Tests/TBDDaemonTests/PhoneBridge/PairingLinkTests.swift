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
        #expect(file.valid.count == 3)
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
        #expect(file.invalid.count == 20)
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
        Base64URL.encode(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    }
}
