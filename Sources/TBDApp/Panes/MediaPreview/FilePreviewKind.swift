import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Which view the file viewer shows for a file.
enum FilePreviewKind: Equatable, Sendable {
    case renderedMarkdown, image, text, audio, video, unpreviewable
}

/// Decides whether a byte sample is text. Text is a UTF-8 sample with no NUL
/// byte (the test Git uses to call a file binary).
enum TextSniff {
    static let sampleLength = 8192

    /// `sampleIsFull` is true when the sample is a full `sampleLength` bytes,
    /// meaning a multi-byte character may be cut off at its end; up to three
    /// trailing bytes are then ignored.
    nonisolated static func readsAsText(_ sample: Data, sampleIsFull: Bool) -> Bool {
        if sample.contains(0) { return false }
        if String(data: sample, encoding: .utf8) != nil { return true }
        guard sampleIsFull else { return false }
        for drop in 1...3 where sample.count > drop {
            if String(data: sample.dropLast(drop), encoding: .utf8) != nil { return true }
        }
        return false
    }

    /// Whether the file at `path` reads as text. Only a regular file is read
    /// (`stat` follows symlinks, so a link to one counts): opening a FIFO
    /// blocks until a writer appears, so a FIFO, a directory, a socket or a
    /// missing path is not text. A read error is not text either.
    nonisolated static func fileReadsAsText(atPath path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        // `read(upToCount:)` throws on a read error, where
        // `readData(ofLength:)` raises an Objective-C exception Swift cannot
        // catch. It returns nil at end of file, so an empty file is text.
        let sample: Data
        do {
            sample = try handle.read(upToCount: sampleLength) ?? Data()
        } catch {
            return false
        }
        return readsAsText(sample, sampleIsFull: sample.count == sampleLength)
    }
}

/// Classifies a file for the viewer, outside any SwiftUI `body`.
/// Order: rendered markdown, image, text, media, unpreviewable.
@MainActor
final class FilePreviewClassifier {
    static let shared = FilePreviewClassifier()

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "ico", "svg"]

    private let playableTypeIdentifiers: Set<String>
    private let sniffsAsText: @MainActor (String) -> Bool
    private var mediaKindCache: [String: FilePreviewKind?] = [:]

    init(
        playableTypeIdentifiers: Set<String> = Set(AVURLAsset.audiovisualTypes().map(\.rawValue)),
        sniffsAsText: @escaping @MainActor (String) -> Bool = { TextSniff.fileReadsAsText(atPath: $0) }
    ) {
        self.playableTypeIdentifiers = playableTypeIdentifiers
        self.sniffsAsText = sniffsAsText
    }

    func kind(forPath path: String, rendersMarkdown: Bool) -> FilePreviewKind {
        let ext = (path as NSString).pathExtension.lowercased()
        if rendersMarkdown && MarkdownWebViewConfiguration.renderableExtensions.contains(ext) {
            return .renderedMarkdown
        }
        if Self.imageExtensions.contains(ext) { return .image }
        if sniffsAsText(path) { return .text }
        return mediaKind(forExtension: ext) ?? .unpreviewable
    }

    /// `.audio`, `.video` or nil. Cached per lower-cased extension.
    func mediaKind(forExtension ext: String) -> FilePreviewKind? {
        let key = ext.lowercased()
        if let cached = mediaKindCache[key] { return cached }
        let result = computeMediaKind(forExtension: key)
        mediaKindCache[key] = .some(result)
        return result
    }

    private func computeMediaKind(forExtension ext: String) -> FilePreviewKind? {
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext),
              playableTypeIdentifiers.contains(type.identifier) else { return nil }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return nil
    }
}
