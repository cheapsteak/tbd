import Testing
import TestSupport

/// `handoverCompare` itself, on snaps built by hand. Neither engine leaves a compared mode
/// unanswered in the corpus, so only these reach the branches that count a missing answer, and
/// they hold that two snaps that both lack one do not pass as two that agree.
@Suite(.fastPassBounded)
struct HandoverCompareTests {
    /// A snap that answered every compared mode, each reset, with libghostty's mouse bits and no
    /// mouse mode in effect.
    private static func answered() -> HandoverSnap {
        var snap = HandoverSnap()
        for name in handoverAnsweredModeNames { snap.modes[name] = false }
        snap.mouseModeBits = Dictionary(uniqueKeysWithValues: handoverMouseModeNames.map { ($0, false) })
        snap.mouseTracking = 0
        snap.mouseEncoding = 0
        return snap
    }

    @Test func snapsThatAnswerAlikeMatch() {
        let tally = handoverCompare(Self.answered(), Self.answered())
        #expect(tally.isEmpty, "\(tally.summary)")
    }

    @Test func aModeOneSideDidNotAnswerDiffers() {
        var missing = Self.answered()
        missing.modes["DECAWM"] = nil
        let expectedFirst = handoverCompare(Self.answered(), missing)
        #expect(expectedFirst.categories == ["mode.DECAWM"], "\(expectedFirst.summary)")
        let actualFirst = handoverCompare(missing, Self.answered())
        #expect(actualFirst.categories == ["mode.DECAWM"], "\(actualFirst.summary)")
    }

    @Test func aModeNeitherSideAnsweredDiffers() {
        var missing = Self.answered()
        missing.modes["DECOM"] = nil
        let tally = handoverCompare(missing, missing)
        #expect(tally.categories == ["mode.DECOM"], "\(tally.summary)")
    }

    @Test func aMouseBitNeitherSideHasDiffers() {
        var missing = Self.answered()
        missing.mouseModeBits?["mouse1002"] = nil
        let tally = handoverCompare(missing, missing)
        #expect(tally.categories == ["mode.mouse1002"], "\(tally.summary)")
    }

    @Test func aMouseModeInEffectNeitherSideReadDiffers() {
        var unread = Self.answered()
        unread.mouseTracking = nil
        unread.mouseEncoding = nil
        let tally = handoverCompare(unread, unread)
        #expect(tally.categories == ["mouseTracking", "mouseEncoding"], "\(tally.summary)")
    }
}
