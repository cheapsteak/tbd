import AppKit
import Markdown

/// Converts a message's Markdown into an `NSAttributedString` for the TextKit 2
/// transcript. Pure: same input → same output, no view/layout state. (#129)
enum MarkdownAttributedRenderer {
    static func render(_ markdown: String) -> NSAttributedString {
        let document = Document(parsing: markdown)
        var visitor = AttributedStringVisitor()
        return visitor.visit(document)
    }
}

/// Walks the swift-markdown AST and appends styled runs. (#129)
private struct AttributedStringVisitor: MarkupVisitor {
    typealias Result = NSAttributedString

    mutating func defaultVisit(_ markup: Markup) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for child in markup.children {
            out.append(visit(child))
        }
        return out
    }

    mutating func visitText(_ text: Markdown.Text) -> NSAttributedString {
        NSAttributedString(string: text.string)
    }
}
