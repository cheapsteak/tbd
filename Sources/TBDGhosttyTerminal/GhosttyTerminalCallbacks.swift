// What a libghostty terminal tells its owner, and the two queries it asks its owner to answer.
//
// There are two kinds of callback here, and they run at different times:
//
// - **Effects** (`writePty`, `bell`, `clipboardWrite`, `desktopNotification`, `programStatus`) are
//   collected while the terminal parses and delivered after its lock drops, but before the
//   `feed`, `resize`, `reset` or appearance change that produced them returns. They are delivered
//   in the order the terminal produced them, and never two at once, even when several threads
//   call into the terminal: a delivery may run on whichever of those threads is delivering at
//   that moment. They may call back into the terminal; what such a nested call produces is
//   delivered after the callback returns, not inside it. They must not wait on another thread
//   that may itself be calling into the terminal, because that thread may be waiting for this
//   delivery to finish.
// - **Queries** (`deviceAttributes`, `xtversion`) are asked *during* the parse, with the terminal's
//   lock held, because the answer has to go into the reply the parser is writing. They must return
//   at once and must not call into the terminal: that would deadlock.
//
// Every callback is optional. A nil effect is dropped. A nil query lets libghostty answer with
// its own default. A nil `programStatus` also means an OSC 7501 support query gets no reply,
// because libghostty only answers it while that callback is set.

/// The callbacks one `GhosttyTerminal` uses. Set once, at `GhosttyTerminal.init`.
public struct GhosttyTerminalCallbacks: Sendable {
    /// Bytes the terminal writes back to the program: query replies and mode reports, such as a DA
    /// answer or a mode 2048 size report. Dropped while the terminal is muted.
    ///
    /// May be called on any thread that calls `feed`, `resize`, `reset` or the appearance setter,
    /// but never concurrently with itself, and always in the order the terminal produced the
    /// replies. A size report from a resize on the main thread and a DA reply from a feed on the
    /// IO thread arrive one after the other, in the terminal's order, whichever thread runs them.
    public var writePty: (@Sendable ([UInt8]) -> Void)?
    /// BEL (0x07). Dropped while muted.
    public var bell: (@Sendable () -> Void)?
    /// An OSC 52 (or OSC 1337, OSC 5522) write to the standard clipboard, as text. An empty
    /// string asks for the clipboard to be cleared. The program is told the write succeeded only
    /// when this is set. Dropped while muted.
    public var clipboardWrite: (@Sendable (String) -> Void)?
    /// An OSC 9 or OSC 777 notification: title (empty when the protocol has none) and body.
    /// Dropped while muted.
    public var desktopNotification: (@Sendable (_ title: String, _ body: String) -> Void)?
    /// An OSC 7501 program status report. Dropped while muted.
    public var programStatus: (@Sendable (ProgramStatus) -> Void)?
    /// The answer to DA1, DA2 and DA3. A query: runs inside the parse, under the lock.
    public var deviceAttributes: (@Sendable () -> DeviceAttributes)?
    /// The answer to XTVERSION (`CSI > q`), such as `"myterm 1.0"`. A query: runs inside the
    /// parse, under the lock. An empty string means libghostty's default.
    public var xtversion: (@Sendable () -> String)?

    public init(
        writePty: (@Sendable ([UInt8]) -> Void)? = nil,
        bell: (@Sendable () -> Void)? = nil,
        clipboardWrite: (@Sendable (String) -> Void)? = nil,
        desktopNotification: (@Sendable (_ title: String, _ body: String) -> Void)? = nil,
        programStatus: (@Sendable (ProgramStatus) -> Void)? = nil,
        deviceAttributes: (@Sendable () -> DeviceAttributes)? = nil,
        xtversion: (@Sendable () -> String)? = nil
    ) {
        self.writePty = writePty
        self.bell = bell
        self.clipboardWrite = clipboardWrite
        self.desktopNotification = desktopNotification
        self.programStatus = programStatus
        self.deviceAttributes = deviceAttributes
        self.xtversion = xtversion
    }
}

extension GhosttyTerminalCallbacks {
    /// One OSC 7501 report, copied out of the parser. The strings are untrusted text from the
    /// program.
    public struct ProgramStatus: Sendable, Equatable {
        public enum State: Sendable, Equatable {
            case idle, working, done, blocked, error
            /// Not a state: remove the record with this id and every record beneath it. An empty
            /// id removes every record.
            case clear
        }

        public enum Kind: Sendable, Equatable {
            case none, permission, question, auth
        }

        public var state: State
        /// What a blocked program needs. `.none` for every other state.
        public var kind: Kind
        /// 0 through 100, or nil when the program sent no percentage.
        public var progress: Int?
        /// Which record the report is about. Empty for the program itself.
        public var id: String
        public var app: String
        public var title: String
        public var message: String

        public init(
            state: State, kind: Kind = .none, progress: Int? = nil,
            id: String = "", app: String = "", title: String = "", message: String = ""
        ) {
            self.state = state
            self.kind = kind
            self.progress = progress
            self.id = id
            self.app = app
            self.title = title
            self.message = message
        }
    }

    /// A device attributes answer. Each field goes into the reply to the matching query:
    /// `conformanceLevel` and `features` to DA1 (`CSI c`), the next three to DA2 (`CSI > c`), and
    /// `unitID` to DA3 (`CSI = c`).
    public struct DeviceAttributes: Sendable, Equatable {
        /// DA1 Pp, for example 62 for a VT220.
        public var conformanceLevel: UInt16
        /// DA1 feature codes, at most 64. Extra entries are dropped.
        public var features: [UInt16]
        /// DA2 Pp, for example 1 for a VT220.
        public var deviceType: UInt16
        /// DA2 Pv.
        public var firmwareVersion: UInt16
        /// DA2 Pc.
        public var romCartridge: UInt16
        /// DA3, written as 8 hex digits.
        public var unitID: UInt32

        public init(
            conformanceLevel: UInt16, features: [UInt16],
            deviceType: UInt16, firmwareVersion: UInt16 = 0, romCartridge: UInt16 = 0,
            unitID: UInt32 = 0
        ) {
            self.conformanceLevel = conformanceLevel
            self.features = features
            self.deviceType = deviceType
            self.firmwareVersion = firmwareVersion
            self.romCartridge = romCartridge
            self.unitID = unitID
        }
    }
}
