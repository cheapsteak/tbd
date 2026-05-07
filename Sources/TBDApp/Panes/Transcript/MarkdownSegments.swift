import Foundation

/// Splits a chat-bubble text into ordered prose / fenced-code segments.
///
/// Block code fences must start at the beginning of a line — keeps the
/// implementation simple and avoids false positives from inline backticks.
/// An unterminated fence consumes the rest of the input as a single code
/// segment.
enum MarkdownSegments {
    enum Segment: Equatable {
        case prose(String)
        case code(language: String?, content: String)
    }

    static func split(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        let lines = text.components(separatedBy: "\n")

        var proseBuffer: [String] = []
        var inCode = false
        var codeLang: String? = nil
        var codeBuffer: [String] = []

        func flushProse() {
            if proseBuffer.isEmpty { return }
            // Trim trailing empty lines introduced by the join, but preserve internal blanks.
            while proseBuffer.last?.isEmpty == true { proseBuffer.removeLast() }
            if !proseBuffer.isEmpty {
                segments.append(.prose(proseBuffer.joined(separator: "\n")))
            }
            proseBuffer.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            while codeBuffer.last?.isEmpty == true { codeBuffer.removeLast() }
            segments.append(.code(language: codeLang, content: codeBuffer.joined(separator: "\n")))
            codeBuffer.removeAll(keepingCapacity: true)
            codeLang = nil
        }

        for line in lines {
            if line.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushProse()
                    inCode = true
                    let langRaw = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLang = langRaw.isEmpty ? nil : langRaw
                }
                continue
            }
            if inCode {
                codeBuffer.append(line)
            } else {
                proseBuffer.append(line)
            }
        }

        if inCode {
            flushCode()
        } else {
            flushProse()
        }

        return segments
    }
}

extension MarkdownSegments.Segment: Identifiable {
    /// Content-derived id so SwiftUI's `ForEach` preserves identity for
    /// unchanged segments across mid-stream re-splits (e.g. a fenced block
    /// opening inside what was previously one prose segment).
    var id: String {
        switch self {
        case .prose(let text):
            return "p:\(text.hashValue)"
        case .code(let language, let content):
            return "c:\(language ?? ""):\(content.hashValue)"
        }
    }
}
