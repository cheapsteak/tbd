import Testing
import Foundation
@testable import TBDShared

/// Runs `body` against a fresh temporary directory, removed afterwards. Nothing
/// here touches `~/tbd`: the store is constructed with an explicit file URL,
/// and the `environment:` seam is exercised with a dictionary.
private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-supervision-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

@Suite struct SupervisionFileStoreTests {
    private let repoA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
    private let repoB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!

    @Test func anAbsentFileLoadsAsTheEmptyValue() throws {
        try withTemporaryDirectory { directory in
            let store = SupervisionFileStore(
                fileURL: directory.appendingPathComponent("supervision.json"))
            let loaded = try store.load()
            #expect(loaded == SupervisionFile())
        }
    }

    @Test func untouchedAndTurnedOffAreIndistinguishable() throws {
        try withTemporaryDirectory { directory in
            let store = SupervisionFileStore(
                fileURL: directory.appendingPathComponent("supervision.json"))
            let untouched = try store.load()

            try store.save(untouched.settingMark("acme-checkout", on: true))
            let on = try store.load()
            #expect(on.isMarked("acme-checkout"))

            try store.save(on.settingMark("acme-checkout", on: false))
            let reloaded = try store.load()
            #expect(reloaded == untouched)
        }
    }

    @Test func theEnvironmentSeamResolvesThroughTBDConstants() {
        let store = SupervisionFileStore(environment: ["TBD_HOME": "/tmp/tbd-store-seam"])
        #expect(store.fileURL.path == "/tmp/tbd-store-seam/supervision/supervision.json")
    }

    @Test func saveCreatesTheDirectory() throws {
        try withTemporaryDirectory { directory in
            let nested = directory.appendingPathComponent("supervision", isDirectory: true)
            let store = SupervisionFileStore(
                fileURL: nested.appendingPathComponent("supervision.json"))
            try store.save(SupervisionFile().settingMark("acme-checkout", on: true))
            let loaded = try store.load()
            #expect(loaded.isMarked("acme-checkout"))
        }
    }

    @Test func savedFileRoundTripsThroughLoad() throws {
        try withTemporaryDirectory { directory in
            let store = SupervisionFileStore(
                fileURL: directory.appendingPathComponent("supervision.json"))
            let file = SupervisionFile(
                projects: ["acme-checkout": .init(
                    repos: [repoA, repoB], policy: .repo(repoA),
                    sweep: .init(fields: ["script": .string("/tmp/sweep.py")]))],
                supervised: ["acme-checkout"],
                modes: ["acme-checkout": .bare("autonomous")],
                supervisors: ["acme-checkout": .init(terminal: "t42")])
            try store.save(file)
            let loaded = try store.load()
            #expect(loaded == file)
        }
    }

    @Test func loaderRefusesARepoInTwoProjectsOnDisk() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("supervision.json")
            let json = """
                {"version": 1,
                 "projects": {
                   "acme-checkout": {"repos": ["\(repoA.uuidString)"], "policy": {"operator": true}},
                   "acme-hooks": {"repos": ["\(repoA.uuidString)"], "policy": {"operator": true}}}}
                """
            try Data(json.utf8).write(to: url)
            let thrown = #expect(throws: SupervisionFileError.self) {
                try SupervisionFileStore(fileURL: url).load()
            }
            #expect(thrown?.description.contains(repoA.uuidString) == true)
        }
    }

    @Test func malformedJSONNamesTheFile() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("supervision.json")
            try Data("{ not json".utf8).write(to: url)
            let thrown = #expect(throws: SupervisionFileError.self) {
                try SupervisionFileStore(fileURL: url).load()
            }
            #expect(thrown?.description.contains(url.path) == true)
        }
    }

    // MARK: Atomicity

    @Test func theWriteTempSitsInTheTargetsOwnDirectory() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("supervision.json")
            let store = SupervisionFileStore(fileURL: url)
            // rename(2) is atomic only within one filesystem: a temp under
            // NSTemporaryDirectory() can land on another volume, where the
            // rename degrades into a tearable copy.
            #expect(store.temporaryURL().deletingLastPathComponent().path == directory.path)
        }
    }

    @Test func aSaveReplacesTheFileRatherThanTruncatingItInPlace() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("supervision.json")
            let store = SupervisionFileStore(fileURL: url)
            try store.save(SupervisionFile().settingMark("acme-checkout", on: true))
            let before = try Data(contentsOf: url)

            // An open handle keeps reading the bytes it opened as long as the
            // writer renames a new file over the name. A writer that truncated
            // and rewrote in place would show this handle the new content — and
            // would leave a torn file behind on a crash.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            try store.save(SupervisionFile().settingMark("acme-hooks", on: true))
            let seenThroughTheOldHandle = try handle.readToEnd() ?? Data()
            #expect(seenThroughTheOldHandle == before)
            let after = try Data(contentsOf: url)
            #expect(after != before)
        }
    }

    @Test func aSuccessfulSaveLeavesNoTemporaryBehind() throws {
        try withTemporaryDirectory { directory in
            let store = SupervisionFileStore(
                fileURL: directory.appendingPathComponent("supervision.json"))
            try store.save(SupervisionFile().settingMark("acme-checkout", on: true))
            try store.save(SupervisionFile().settingMark("acme-hooks", on: true))
            let entries = try FileManager.default
                .contentsOfDirectory(atPath: directory.path).sorted()
            #expect(entries == ["supervision.json"])
        }
    }

    @Test func aRefusedSaveLeavesThePreviousBytesByteIdentical() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("supervision.json")
            let store = SupervisionFileStore(fileURL: url)
            try store.save(SupervisionFile().settingMark("acme-checkout", on: true))
            let before = try Data(contentsOf: url)

            // A file the loader would reject never reaches the disk at all.
            let unloadable = SupervisionFile(projects: [
                "acme-checkout": .init(repos: [repoA], policy: .repo(repoB)),
            ])
            #expect(throws: SupervisionFileError.self) { try store.save(unloadable) }

            let after = try Data(contentsOf: url)
            #expect(after == before)
            let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(entries == ["supervision.json"])
            let reloaded = try store.load()
            #expect(reloaded.isMarked("acme-checkout"))
        }
    }
}
