import Testing
@testable import TBDApp

@Suite("Code viewer file entry sorting")
struct CodeViewerFileEntrySortTests {
    private func entry(_ name: String, isDirectory: Bool = false) -> FileEntry {
        FileEntry(path: "/tmp/root/" + name, name: name, isDirectory: isDirectory, depth: 0)
    }

    @Test("directories sort before files")
    func directoriesFirst() {
        let sorted = FileEntry.sortedForListing([
            entry("zebra.txt"),
            entry("alpha", isDirectory: true),
            entry("beta.md"),
            entry("gamma", isDirectory: true),
        ])
        #expect(sorted.map(\.name) == ["alpha", "gamma", "beta.md", "zebra.txt"])
        #expect(sorted.prefix(2).allSatisfy { $0.isDirectory })
    }

    @Test("names sort case-insensitively within each group")
    func caseInsensitiveWithinGroup() {
        let sorted = FileEntry.sortedForListing([
            entry("README.md"),
            entry("apple.swift"),
            entry("Banana.swift"),
            entry("Sources", isDirectory: true),
            entry("docs", isDirectory: true),
        ])
        #expect(sorted.map(\.name) == ["docs", "Sources", "apple.swift", "Banana.swift", "README.md"])
    }

    @Test("empty input yields empty output")
    func emptyInput() {
        #expect(FileEntry.sortedForListing([]).isEmpty)
    }

    @Test("sorting preserves entry fields")
    func preservesFields() {
        let input = [entry("b.txt"), entry("a", isDirectory: true)]
        let sorted = FileEntry.sortedForListing(input)
        #expect(sorted.first?.path == "/tmp/root/a")
        #expect(sorted.first?.depth == 0)
        #expect(sorted.last?.name == "b.txt")
        #expect(sorted.last?.isDirectory == false)
    }
}
