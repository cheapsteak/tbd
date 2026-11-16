import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared
import TestSupport

/// The bytes an image part is delivered as.
///
/// Claude Code turns a paste into an image attachment only when the WHOLE paste
/// is one quoted path, so an image part delivered together with its surrounding
/// words silently becomes literal text. How the holder transport frames a
/// single image part, and refuses a multi-part message, is
/// `HolderCompositeSendRefusalTests`' subject.
@Suite("terminal.send image part")
struct TerminalSendPartsDeliveryTests {
    @Test func anImagePartIsPastedAsABareQuotedPath() {
        #expect(RPCRouter.quotedImagePath("/tmp/a b.png") == "'/tmp/a b.png'")
        #expect(RPCRouter.quotedImagePath("/tmp/it's.png") == #"'/tmp/it'\''s.png'"#)
    }
}
