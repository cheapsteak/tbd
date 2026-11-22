import SwiftUI

/// The file viewer's view of a CSV or TSV file: the table, or a sentence
/// saying why there is none.
///
/// The file is read by `DelimitedTableLoader` on a detached task, in a
/// `.task` keyed on the path and the revision, so neither the read nor the
/// parse runs in `body` or on the main actor. A task cancelled while the read
/// runs drops its result.
///
/// The result is kept with the path it was read for, and `body` shows it only
/// while that path is still the one shown: a switch to another file shows the
/// spinner rather than the previous file's table. It deliberately does not
/// compare the revision. When the file changes on disk, the table on screen
/// stays until the new read finishes, so the pane does not flash, and the
/// same `TablePreviewView` takes the new rows in place.
struct DelimitedTablePreview: View {
    let filePath: String
    let revision: Int

    @State private var loaded: Loaded?

    /// One finished read and the path it was made for. `loadID` changes with
    /// every read, which is how `TablePreviewView` tells a new table from an
    /// unrelated SwiftUI update without comparing the tables.
    private struct Loaded {
        let path: String
        let result: DelimitedTableLoad
        let loadID: Int
    }

    var body: some View {
        Group {
            if let loaded, loaded.path == filePath {
                content(loaded)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(filePath)#\(revision)") {
            await load()
        }
    }

    @ViewBuilder
    private func content(_ loaded: Loaded) -> some View {
        switch loaded.result {
        case .unreadable:
            message("Could not read file")
        case .loaded(.empty):
            message("This file is empty.")
        case .loaded(.unterminatedQuote(let line)):
            message(
                "Cannot show this file as a table: the quote that opens on line \(line) "
                    + "never closes. The source button shows the file as text."
            )
        case .loaded(.table(let table)):
            VStack(spacing: 0) {
                TablePreviewView(table: table, loadID: loaded.loadID)
                if table.stoppedAtLimit || table.stoppedAtColumnLimit {
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        if table.stoppedAtLimit {
                            Text(rowLimitNote(rowCount: table.rows.count))
                        }
                        if table.stoppedAtColumnLimit {
                            Text(columnLimitNote(columnCount: table.columnCount))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rowLimitNote(rowCount: Int) -> String {
        "Showing the first \(rowCount.formatted()) rows. The rest of the file is not shown."
    }

    private func columnLimitNote(columnCount: Int) -> String {
        "Showing the first \(columnCount.formatted()) columns. The other columns are not shown."
    }

    private func load() async {
        let path = filePath
        let result = await Task.detached(priority: .userInitiated) {
            DelimitedTableLoader.load(path: path)
        }.value
        // Cancelled while the read ran: a newer task owns `loaded`.
        guard !Task.isCancelled else { return }
        let nextID = (loaded?.loadID ?? 0) &+ 1
        loaded = Loaded(path: path, result: result, loadID: nextID)
    }
}
