import Foundation
import Testing
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
    func audioExtensionsClassifyAsAudio() {
        let c = classifier(sniff: false)
        for name in ["a.m4a", "a.mp3", "a.wav", "a.flac"] {
            #expect(c.kind(forPath: "/x/\(name)", rendersMarkdown: false) == .audio)
        }
    }

    @Test("video extensions classify as video")
    func videoExtensionsClassifyAsVideo() {
        let c = classifier(sniff: false)
        #expect(c.kind(forPath: "/x/a.mov", rendersMarkdown: false) == .video)
        #expect(c.kind(forPath: "/x/a.mp4", rendersMarkdown: false) == .video)
    }

    @Test("mkv outside the playable set is unpreviewable")
    func mkvNotInTheSetIsUnpreviewable() {
        let c = classifier(sniff: false)
        #expect(c.kind(forPath: "/x/a.mkv", rendersMarkdown: false) == .unpreviewable)
    }

    @Test("playlists and captions are text")
    func playlistsAndCaptionsAreText() {
        let c = classifier(sniff: true)
        #expect(c.kind(forPath: "/x/a.m3u", rendersMarkdown: false) == .text)
        #expect(c.kind(forPath: "/x/a.vtt", rendersMarkdown: false) == .text)
    }

    @Test("source files with media extensions are text")
    func sourceFilesWithMediaExtensionsAreText() {
        let c = classifier(sniff: true)
        for name in ["index.ts", "mod.mts", "go.mod"] {
            #expect(c.kind(forPath: "/x/\(name)", rendersMarkdown: false) == .text)
        }
    }

    @Test("png is an image")
    func pngIsImage() {
        let c = classifier(sniff: true)
        #expect(c.kind(forPath: "/x/a.png", rendersMarkdown: false) == .image)
    }

    @Test("markdown renders only when asked")
    func markdownRendersOnlyWhenAsked() {
        let c = classifier(sniff: true)
        #expect(c.kind(forPath: "/x/a.md", rendersMarkdown: true) == .renderedMarkdown)
        #expect(c.kind(forPath: "/x/a.md", rendersMarkdown: false) == .text)
    }

    @Test("upper-case extensions match")
    func upperCaseExtensionsMatch() {
        let c = classifier(sniff: false)
        #expect(c.kind(forPath: "/x/SONG.MP3", rendersMarkdown: false) == .audio)
        #expect(c.kind(forPath: "/x/CLIP.MOV", rendersMarkdown: false) == .video)
    }

    @Test("the real system list plays common media")
    func realSystemListPlaysCommonMedia() {
        let c = FilePreviewClassifier(sniffsAsText: { _ in false })
        #expect(c.kind(forPath: "/x/a.m4a", rendersMarkdown: false) == .audio)
        #expect(c.kind(forPath: "/x/a.wav", rendersMarkdown: false) == .audio)
        #expect(c.kind(forPath: "/x/a.mov", rendersMarkdown: false) == .video)
    }
}

@Suite("TextSniff")
struct TextSniffTests {
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
}
