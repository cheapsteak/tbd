import Foundation
import Testing
import TestSupport
import UniformTypeIdentifiers
@testable import TBDApp

private let playableForTests: Set<String> = Set(
    ["m4a", "mp3", "wav", "flac", "mov", "mp4", "m3u", "vtt", "ts", "mts", "mod"]
        .compactMap { UTType(filenameExtension: $0)?.identifier }
)

@MainActor
@Suite("FilePreviewKind")
struct FilePreviewKindTests {
    private func classifier(sniff: Bool) -> FilePreviewClassifier {
        FilePreviewClassifier(playableTypeIdentifiers: playableForTests, sniffsAsText: { _ in sniff })
    }

    @Test("audio extensions classify as audio")
    func audioExtensionsClassifyAsAudio() async {
        let c = classifier(sniff: false)
        for name in ["a.m4a", "a.mp3", "a.wav", "a.flac"] {
            let k = await c.kind(forPath: "/x/\(name)", rendersMarkdown: false)
            #expect(k == .audio, "\(name)")
        }
    }

    @Test("video extensions classify as video")
    func videoExtensionsClassifyAsVideo() async {
        let c = classifier(sniff: false)
        let mov = await c.kind(forPath: "/x/a.mov", rendersMarkdown: false)
        #expect(mov == .video)
        let mp4 = await c.kind(forPath: "/x/a.mp4", rendersMarkdown: false)
        #expect(mp4 == .video)
    }

    @Test("mkv outside the playable set is unpreviewable")
    func mkvNotInTheSetIsUnpreviewable() async {
        let c = classifier(sniff: false)
        let k = await c.kind(forPath: "/x/a.mkv", rendersMarkdown: false)
        #expect(k == .unpreviewable)
    }

    @Test("playlists and captions are text")
    func playlistsAndCaptionsAreText() async {
        let c = classifier(sniff: true)
        let m3u = await c.kind(forPath: "/x/a.m3u", rendersMarkdown: false)
        #expect(m3u == .text)
        let vtt = await c.kind(forPath: "/x/a.vtt", rendersMarkdown: false)
        #expect(vtt == .text)
    }

    @Test("source files with media extensions are text")
    func sourceFilesWithMediaExtensionsAreText() async {
        let c = classifier(sniff: true)
        for name in ["index.ts", "mod.mts", "go.mod"] {
            let k = await c.kind(forPath: "/x/\(name)", rendersMarkdown: false)
            #expect(k == .text, "\(name)")
        }
    }

    @Test("png is an image")
    func pngIsImage() async {
        let c = classifier(sniff: true)
        let k = await c.kind(forPath: "/x/a.png", rendersMarkdown: false)
        #expect(k == .image)
    }

    @Test("markdown renders only when asked")
    func markdownRendersOnlyWhenAsked() async {
        let c = classifier(sniff: true)
        let rendered = await c.kind(forPath: "/x/a.md", rendersMarkdown: true)
        #expect(rendered == .renderedMarkdown)
        let source = await c.kind(forPath: "/x/a.md", rendersMarkdown: false)
        #expect(source == .text)
    }

    @Test("upper-case extensions match")
    func upperCaseExtensionsMatch() async {
        let c = classifier(sniff: false)
        let song = await c.kind(forPath: "/x/SONG.MP3", rendersMarkdown: false)
        #expect(song == .audio)
        let clip = await c.kind(forPath: "/x/CLIP.MOV", rendersMarkdown: false)
        #expect(clip == .video)
    }

    @Test("the real system list plays common media")
    func realSystemListPlaysCommonMedia() async {
        let c = FilePreviewClassifier(sniffsAsText: { _ in false })
        let m4a = await c.kind(forPath: "/x/a.m4a", rendersMarkdown: false)
        #expect(m4a == .audio)
        let wav = await c.kind(forPath: "/x/a.wav", rendersMarkdown: false)
        #expect(wav == .audio)
        let mov = await c.kind(forPath: "/x/a.mov", rendersMarkdown: false)
        #expect(mov == .video)
    }
}

@Suite("TextSniff")
struct TextSniffTests {
    /// A fresh directory under the temporary directory; the caller removes it.
    private static func makeScratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("ASCII is text")
    func ascii() {
        #expect(TextSniff.readsAsText(Data("hello\n".utf8), sampleIsFull: false))
    }

    @Test("multi-byte UTF-8 is text")
    func multiByte() {
        #expect(TextSniff.readsAsText(Data("héllo ✓ 日本".utf8), sampleIsFull: false))
    }

    @Test("a NUL byte is binary")
    func nulIsBinary() {
        #expect(!TextSniff.readsAsText(Data([0x61, 0x00, 0x62]), sampleIsFull: false))
    }

    @Test("invalid UTF-8 is binary")
    func invalidUTF8() {
        #expect(!TextSniff.readsAsText(Data([0xC3, 0x28]), sampleIsFull: false))
    }

    @Test("a cut-off character is ignored only on a full sample")
    func truncatedTail() {
        let sample = Data("ab".utf8) + Data([0xE2, 0x9C])
        #expect(TextSniff.readsAsText(sample, sampleIsFull: true))
        #expect(!TextSniff.readsAsText(sample, sampleIsFull: false))
    }

    @Test("a file whose 8 KB sample ends inside a character is text")
    func fileEndingInsideCharacter() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("long.txt")
        let data = Data(repeating: 0x61, count: 8191) + Data("✓".utf8)
        try data.write(to: file)
        #expect(TextSniff.fileReadsAsText(atPath: file.path))
    }

    /// Opening a directory for reading succeeds, and reading it fails with
    /// `EISDIR`, which `readData(ofLength:)` raised as an uncatchable
    /// exception.
    @Test("a directory is not text")
    func directoryIsNotText() throws {
        let dir = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!TextSniff.fileReadsAsText(atPath: dir.path))
    }

    @Test("a symlink to a text file is text")
    func symlinkToTextIsText() throws {
        let dir = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("target.ts")
        try Data("export const x = 1\n".utf8).write(to: file)
        let link = dir.appendingPathComponent("link.ts")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(TextSniff.fileReadsAsText(atPath: link.path))
    }

    // MARK: - FIFO

    /// What the probe thread reported, read from the test's poll.
    private final class SniffProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var _started = false
        private var _result: Bool?

        var started: Bool { lock.withLock { _started } }
        var result: Bool? { lock.withLock { _result } }

        func markStarted() { lock.withLock { _started = true } }
        func finish(_ value: Bool) { lock.withLock { _result = value } }
    }

    /// Runs the sniff on a dedicated thread, so a sniff that blocks in
    /// `open(2)` parks that thread rather than the cooperative pool.
    private static func startSniffThread(path: String, into probe: SniffProbe) -> Thread {
        let worker = Thread {
            probe.markStarted()
            probe.finish(TextSniff.fileReadsAsText(atPath: path))
        }
        worker.name = "fifo-sniff-probe"
        worker.start()
        return worker
    }

    /// What the bounded wait observed when it expired. Thrown so the
    /// diagnostic lands on the CI summary's primary failure line.
    private struct SniffDidNotReturn: Error, CustomStringConvertible {
        let started: Bool
        let elapsed: Duration
        var description: String {
            started
                ? "the sniff started but had not returned after \(elapsed) — it blocked " +
                  "opening a FIFO, so the regular-file check is gone"
                : "the sniff thread never got to run within \(elapsed) — a scheduling " +
                  "starvation, not a blocked open"
        }
    }

    /// `open(2)` on a FIFO with no writer never returns, so a sniff that opened
    /// one would wedge the viewer's classification forever. The sniff runs on
    /// a dedicated thread behind a bounded wait, so a regression fails this
    /// test instead of hanging the suite; if it does block, the test opens the
    /// write end to release the stuck opener. The bound is a hang guard, not
    /// the assertion: a blocked `open(2)` never returns, so any finite
    /// deadline tells the two outcomes apart.
    @Test("a FIFO is not text, and sniffing it does not block")
    func fifoIsNotTextWithoutBlocking() async throws {
        let dir = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("pipe.ts").path
        try #require(mkfifo(path, 0o600) == 0,
                     Comment(rawValue: "mkfifo failed: \(String(cString: strerror(errno)))"))

        let probe = SniffProbe()
        let started = ContinuousClock.now
        _ = Self.startSniffThread(path: path, into: probe)

        let outcome = await pollUntilTrue(
            timeout: TestDeadlines.saturatedPass, pollInterval: .milliseconds(20)
        ) { @Sendable in
            probe.result != nil
        }
        if outcome == .timedOut {
            let didStart = probe.started
            // Release a stuck `open(2)` so the worker thread is not leaked in a
            // permanently blocking syscall, then report what was observed.
            let writeEnd = open(path, O_WRONLY | O_NONBLOCK)
            if writeEnd >= 0 { close(writeEnd) }
            Issue.record(SniffDidNotReturn(started: didStart, elapsed: ContinuousClock.now - started))
            return
        }
        guard outcome == .satisfied else { return }
        let result = probe.result
        #expect(result == false)
    }
}
