import Testing
@testable import TBDShared

/// `HTMLEscaping` escapes by Unicode scalar. Each case feeds a syntax
/// character together with a scalar that joins it into one `Character`, which
/// `replacingOccurrences(of:with:)` and `Character` comparison both skip. An
/// HTML parser reads code points, so the escape must catch every one.
@Suite("HTMLEscaping")
struct HTMLEscapingTests {

    /// Each scalar joins the character before it into one `Character`: a
    /// combining acute accent, an emoji variation selector and a combining
    /// enclosing keycap.
    static let joiningMarks = ["\u{301}", "\u{FE0F}", "\u{20E3}"]

    /// A prepended concatenation mark joins the character after it.
    static let prependedMark = "\u{600}"

    /// Each character escaped by default, with its entity.
    static let entities = [("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;")]

    static func scalars(_ text: String) -> [Unicode.Scalar] {
        Array(text.unicodeScalars)
    }

    static func label(_ text: String) -> String {
        text.unicodeScalars
            .map { "U+" + String($0.value, radix: 16, uppercase: true) }
            .joined(separator: " ")
    }

    @Test func eachCharacterIsEscapedWhateverMarkFollowsIt() {
        for (character, entity) in Self.entities {
            for mark in Self.joiningMarks {
                let escaped = HTMLEscaping.escaped("a" + character + mark + "b")
                #expect(
                    Self.scalars(escaped) == Self.scalars("a" + entity + mark + "b"),
                    "\(Self.label(character)) then \(Self.label(mark))")
            }
        }
    }

    @Test func eachCharacterIsEscapedAfterAPrependedMark() {
        for (character, entity) in Self.entities {
            let escaped = HTMLEscaping.escaped("a" + Self.prependedMark + character + "b")
            #expect(
                Self.scalars(escaped) == Self.scalars("a" + Self.prependedMark + entity + "b"),
                "U+600 then \(Self.label(character))")
        }
    }

    /// No raw `<`, `>` or `"` scalar survives, whatever joins it.
    @Test func noMarkupScalarSurvives() {
        let text = Self.joiningMarks.map { "<" + $0 + ">" + $0 + "\"" + $0 }.joined()
            + Self.prependedMark + "\""
        let escaped = HTMLEscaping.escaped(text)
        #expect(!escaped.unicodeScalars.contains { $0 == "<" || $0 == ">" || $0 == "\"" })
    }

    /// Plain ASCII comes out exactly as the `replacingOccurrences` chain this
    /// replaced wrote it.
    @Test func plainASCIIOutputIsPinned() {
        #expect(HTMLEscaping.escaped(#"<a href="x">Tom & Jerry's</a>"#)
            == #"&lt;a href=&quot;x&quot;&gt;Tom &amp; Jerry's&lt;/a&gt;"#)
        #expect(HTMLEscaping.escaped(#"<a href="x">Tom & Jerry's</a>"#, includingApostrophe: true)
            == #"&lt;a href=&quot;x&quot;&gt;Tom &amp; Jerry&#39;s&lt;/a&gt;"#)
    }

    /// One pass: the `&` of an entity in the input is escaped once, and an
    /// entity this writes is never escaped again.
    @Test func anAmpersandIsEscapedOnce() {
        #expect(HTMLEscaping.escaped("&amp; <") == "&amp;amp; &lt;")
    }

    /// Text with nothing to escape comes back scalar for scalar, marks and all.
    @Test func otherTextIsCopiedScalarForScalar() {
        let text = "cafe\u{301} \u{1F600}\u{FE0F} 1\u{20E3} \u{600}x"
        #expect(Self.scalars(HTMLEscaping.escaped(text)) == Self.scalars(text))
    }

    // MARK: - The apostrophe branch

    @Test func anApostropheIsLeftAloneByDefault() {
        #expect(HTMLEscaping.escaped("it's") == "it's")
        for mark in Self.joiningMarks {
            #expect(
                Self.scalars(HTMLEscaping.escaped("'" + mark)) == Self.scalars("'" + mark),
                "\(Self.label(mark))")
        }
    }

    @Test func anApostropheIsEscapedWhenAsked() {
        #expect(HTMLEscaping.escaped("it's", includingApostrophe: true) == "it&#39;s")
        for mark in Self.joiningMarks {
            #expect(
                Self.scalars(HTMLEscaping.escaped("'" + mark, includingApostrophe: true))
                    == Self.scalars("&#39;" + mark),
                "\(Self.label(mark))")
        }
        #expect(
            Self.scalars(HTMLEscaping.escaped(Self.prependedMark + "'", includingApostrophe: true))
                == Self.scalars(Self.prependedMark + "&#39;"))
    }
}
