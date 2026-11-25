import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared

// MARK: - Fixtures

private enum AccountRowFixture {
    typealias Presentation = ProfileUsagePresentation.BucketPresentation

    /// A fixed clock, so reset phrases are deterministic.
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let utc = TimeZone(identifier: "UTC")!

    static func presentation(kind: String, percent: Double, resetsIn: TimeInterval) -> Presentation {
        let bucket = ClaudeUsageLimitBucket(kind: kind, percent: percent, severity: "normal",
                                            resetsAt: now.addingTimeInterval(resetsIn))
        return ProfileUsagePresentation.bucketPresentation(bucket, now: now, timeZone: utc)
    }

    static func session40() -> Presentation {
        presentation(kind: "session", percent: 40, resetsIn: 2 * 3600)
    }

    static func weekly16() -> Presentation {
        presentation(kind: "weekly_all", percent: 16, resetsIn: 3 * 24 * 3600)
    }

    static func bars(ageNote: String? = nil) -> ProfileUsagePresentation.MenuUsage {
        .bars(session: session40(), weekly: weekly16(), ageNote: ageNote)
    }
}

// MARK: - AccountMenuRow

@MainActor
@Suite("AccountMenuRow")
struct AccountMenuRowTests {
    private typealias Fix = AccountRowFixture
    private typealias Row = AccountMenuRow
    private typealias MenuUsage = ProfileUsagePresentation.MenuUsage

    /// Every attachment in the title, in order. Each takes one character.
    private func attachments(_ title: NSAttributedString) -> [NSTextAttachment] {
        var found: [NSTextAttachment] = []
        for index in 0..<title.length {
            let value = title.attribute(.attachment, at: index, effectiveRange: nil)
            if let attachment = value as? NSTextAttachment {
                found.append(attachment)
            }
        }
        return found
    }

    @Test func namePlusSpacerIsEqualAcrossRows() throws {
        let usage = Fix.bars()
        let names = ["A", "Personal", "A much longer account name"]
        let rows: [(name: String, usage: MenuUsage)] = names.map { (name: $0, usage: usage) }
        let column = Row.nameColumnWidth(rows)
        #expect(column == Row.nameWidth("A much longer account name"))
        #expect(column > Row.nameWidth("A"))

        for name in names {
            let spacerWidth = Row.spacerWidth(name: name, nameColumnWidth: column)
            #expect(Row.nameWidth(name) + spacerWidth == column + 22)

            // The title's spacer carries that width.
            let title = try #require(Row.attributedTitle(name: name, usage: usage,
                                                         nameColumnWidth: column))
            let spacer = try #require(attachments(title).first)
            #expect(spacer.bounds.width == spacerWidth)
        }
    }

    @Test func nameColumnIgnoresRowsWithoutUsage() {
        let longName = "An extremely long account name that shows no usage"
        let rows: [(name: String, usage: MenuUsage)] = [
            (name: "Work", usage: Fix.bars()),
            (name: longName, usage: MenuUsage.none),
        ]
        #expect(Row.nameColumnWidth(rows) == Row.nameWidth("Work"))

        // A row with a note takes part in the column.
        let withNote = rows + [(name: longName, usage: MenuUsage.note("needs re-login"))]
        #expect(Row.nameColumnWidth(withNote) == Row.nameWidth(longName))

        let nothing: [(name: String, usage: MenuUsage)] = [(name: longName, usage: MenuUsage.none)]
        #expect(Row.nameColumnWidth(nothing) == 0)
    }

    @Test func barsTitleCarriesSpacerThenBarsImage() throws {
        let column = Row.nameWidth("Work")
        let title = try #require(Row.attributedTitle(name: "Work", usage: Fix.bars(),
                                                     nameColumnWidth: column))
        #expect(title.string.hasPrefix("Work"))

        let found = attachments(title)
        #expect(found.count == 2)
        let spacer = try #require(found.first)
        let bars = try #require(found.last)
        #expect(spacer.bounds.width == Row.nameGap)
        #expect(spacer.image?.size != UsageBarsMenuImage.size)
        #expect(bars.image?.size == UsageBarsMenuImage.size)
        #expect(bars.bounds.size == UsageBarsMenuImage.size)

        // The name is in the menu font with no color of its own, so the menu
        // can recolor it under the highlight.
        let font = title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let color = title.attribute(.foregroundColor, at: 0, effectiveRange: nil)
        #expect(font == NSFont.menuFont(ofSize: 0))
        #expect(color == nil)
    }

    @Test func rowWithoutSessionHasSameImageWidth() throws {
        let usage = MenuUsage.bars(session: nil, weekly: Fix.weekly16(), ageNote: nil)
        let title = try #require(Row.attributedTitle(name: "Ultra", usage: usage,
                                                     nameColumnWidth: 100))
        let found = attachments(title)
        #expect(found.count == 2)
        let bars = try #require(found.last)
        #expect(bars.image?.size.width == 200)
        #expect(bars.bounds.width == 200)
    }

    @Test func ageNoteFollowsBars() throws {
        let title = try #require(Row.attributedTitle(name: "Work",
                                                     usage: Fix.bars(ageNote: "10m ago"),
                                                     nameColumnWidth: 80))
        #expect(title.string.hasSuffix("10m ago"))
        let found = attachments(title)
        #expect(found.count == 2)
        #expect(found.last?.image?.size == UsageBarsMenuImage.size)

        let color = title.attribute(.foregroundColor, at: title.length - 1,
                                    effectiveRange: nil) as? NSColor
        #expect(color == NSColor.secondaryLabelColor)
    }

    @Test func noteReplacesBars() throws {
        let note = "usage unavailable — retrying · last data 3h ago"
        let title = try #require(Row.attributedTitle(name: "Spare", usage: .note(note),
                                                     nameColumnWidth: 80))
        #expect(title.string.hasPrefix("Spare"))
        #expect(title.string.hasSuffix(note))
        let found = attachments(title)
        #expect(found.count == 1)
        #expect(found.first?.image?.size != UsageBarsMenuImage.size)
    }

    @Test func noneHasNoAttributedTitle() {
        let name = "Personal"
        let title = Row.attributedTitle(name: name, usage: MenuUsage.none, nameColumnWidth: 80)
        #expect(title == nil)

        let item = NSMenuItem(title: "placeholder", action: nil, keyEquivalent: "")
        Row.apply(to: item, name: name, usage: MenuUsage.none, identity: nil, nameColumnWidth: 80)
        #expect(item.attributedTitle == nil)
        #expect(item.title == name)
        #expect(item.toolTip == nil)
    }

    @Test func applyKeepsPlainTitleAndSetsToolTip() throws {
        let session = Fix.session40()
        let weekly = Fix.weekly16()
        let sessionReset = try #require(session.resetPhrase)
        let weeklyReset = try #require(weekly.resetPhrase)

        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        Row.apply(to: item, name: "Work",
                  usage: .bars(session: session, weekly: weekly, ageNote: nil),
                  identity: nil,
                  nameColumnWidth: Row.nameWidth("Work"))
        #expect(item.title == "Work")
        #expect(item.attributedTitle != nil)
        #expect(item.toolTip == "5-hour: 40% used · \(sessionReset) — Weekly: 16% used · \(weeklyReset)")
    }

    @Test func toolTipNamesOnlyPresentBucketsAndOnlyForBars() throws {
        let weekly = Fix.weekly16()
        let weeklyReset = try #require(weekly.resetPhrase)
        let weeklyOnly = MenuUsage.bars(session: nil, weekly: weekly, ageNote: nil)
        #expect(Row.toolTip(for: weeklyOnly, identity: nil) == "Weekly: 16% used · \(weeklyReset)")
        #expect(Row.toolTip(for: .note("needs re-login"), identity: nil) == nil)
        #expect(Row.toolTip(for: MenuUsage.none, identity: nil) == nil)
    }

    /// The login email leads, on a line of its own above the reset times.
    @Test func toolTipLeadsWithTheIdentityAboveTheResetTimes() throws {
        let session = Fix.session40()
        let weekly = Fix.weekly16()
        let sessionReset = try #require(session.resetPhrase)
        let weeklyReset = try #require(weekly.resetPhrase)
        let usage = MenuUsage.bars(session: session, weekly: weekly, ageNote: nil)

        let resetTimes = "5-hour: 40% used · \(sessionReset) — Weekly: 16% used · \(weeklyReset)"
        let toolTip = Row.toolTip(for: usage, identity: "dev@acme.example")
        #expect(toolTip == "dev@acme.example\n\(resetTimes)")
    }

    /// With no bars there are no reset times, so the email stands alone.
    @Test func toolTipIsTheIdentityAloneWithoutBars() {
        let identity = "dev@acme.example"
        #expect(Row.toolTip(for: MenuUsage.none, identity: identity) == identity)
        #expect(Row.toolTip(for: .note("needs re-login"), identity: identity) == identity)
    }

    /// An empty identity counts as none.
    @Test func toolTipIgnoresAnEmptyIdentity() {
        #expect(Row.toolTip(for: MenuUsage.none, identity: "") == nil)
    }

    @Test func applySetsTheIdentityOnTheToolTip() throws {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        Row.apply(to: item, name: "Work", usage: Fix.bars(), identity: "dev@acme.example",
                  nameColumnWidth: Row.nameWidth("Work"))
        #expect(item.title == "Work")
        let toolTip = try #require(item.toolTip)
        let lines = toolTip.components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines.first == "dev@acme.example")
        #expect(lines.last?.hasPrefix("5-hour: 40% used") == true)

        // A row with no usage still carries the email.
        let bare = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        Row.apply(to: bare, name: "Personal", usage: MenuUsage.none, identity: "me@acme.example",
                  nameColumnWidth: 0)
        #expect(bare.attributedTitle == nil)
        #expect(bare.toolTip == "me@acme.example")
    }
}
