import Foundation
import TBDShared

enum PromptRailFixtures {
    /// `prompts` user prompts "p-i" ("Prompt i"), each followed by an assistant
    /// reply "a-i" of `replySentences(i)` wrapping sentences.
    static func conversation(prompts: Int, replySentences: (Int) -> Int) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        for index in 0..<prompts {
            items.append(.userPrompt(id: "p-\(index)", text: "Prompt \(index)", timestamp: nil))
            items.append(.assistantText(
                id: "a-\(index)",
                text: String(
                    repeating: "A reply sentence whose prose wraps across the column. ",
                    count: replySentences(index)),
                timestamp: nil,
                usage: nil))
        }
        return items
    }
}
