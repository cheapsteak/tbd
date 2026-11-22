# CSV and TSV table preview in the file viewer

## Summary

The file viewer pane shows a `.csv` or `.tsv` file as a table. The first row
gives the column titles, which stay at the top while the rows scroll. The
pane's source button (`</>`), which today switches a markdown file between its
rendered view and its source, switches a CSV or TSV file between the table and
its highlighted text.

The table is a native AppKit `NSTableView`. It reads the file off the main
thread and shows up to 100,000 rows. When the file has more, a line under the
table says so.

## Behavior

### Which files get the table

A file gets the table when all of these hold:

- its extension is `csv` or `tsv`, in any case
- it is the only file the pane shows
- the pane is not in source mode
- its first 8 KB reads as text, by the test the viewer already uses: valid
  UTF-8 with no NUL byte (`TextSniff`)

A `.csv` that fails the text test is not a table. It goes on to the media
check and the "Cannot preview" screen, as any other binary file does.

When several files are selected, each one stacks in the pane's scroll view,
and a CSV or TSV file there shows its highlighted text. A rendered markdown
file does the same, for the same reason: a view that scrolls itself has no
height inside the pane's scroll view.

The viewer decides a file's view in this order: rendered markdown, **table**,
image, text, media, then the "Cannot preview" screen.

The source button appears whenever the pane's single file is a CSV or TSV
file, as it does for markdown. A file opens on the table.

### Reading the file

The delimiter comes from the extension: a comma for `csv`, a tab for `tsv`.

Both use the same quoting rules, those of RFC 4180, which most tools that
write TSV also follow (Python's `excel-tab` dialect, pandas):

- A field that starts with a double quote runs to the matching closing quote.
  Inside it, the delimiter and line breaks are part of the value, and two
  double quotes stand for one.
- A double quote anywhere else in a field is an ordinary character.
- A row ends at `\n`, `\r\n` or `\r` outside quotes.
- A line break at the end of the file does not start another row.
- An empty line in the middle of the file is a row with one empty field.
- A UTF-8 byte order mark at the start of the file is removed, so the first
  column title does not carry it. Excel's "CSV UTF-8" export writes one.
- Bytes that are not valid UTF-8, after the first 8 KB the text test checked,
  show as the replacement character (`�`). The rest of the file still shows.

### Header and columns

- The first row gives the column titles. A file with no header row shows its
  first data row as titles.
- The table has as many columns as its widest row. A shorter row leaves its
  last cells empty. A column past the end of the header row has an empty
  title.
- Each column starts at a width measured from its title and the values in the
  first 200 rows, between 48 and 320 points. The user can drag a column wider
  or narrower. When the columns need less width than the pane has, the last
  column takes the rest. When they need more, the table scrolls sideways.

### Cells

- Values use the system font at 12 points with fixed-width digits, so numbers
  in a column line up.
- Each row is one line high. A line break inside a value shows as `↵`, so the
  row keeps one line and no part of the value is lost.
- A value too wide for its column ends in an ellipsis. Pointing at it shows
  the whole value in an expansion tooltip, the way Finder's list view does
  (`allowsExpansionToolTips`).
- Rows alternate their background colour, and thin lines separate the
  columns.
- The user can click a row to highlight it. Nothing else happens on a click.

### Appearance

The table follows the system's light or dark appearance, as a rendered
markdown file does. It is not inside the dark theme the pane forces on
highlighted text.

### Large files

The table holds at most 100,000 data rows, not counting the header row.

Reading also stops after 50 MB of the file, so a file with very long rows
cannot fill memory before it reaches the row limit. When reading stops at
50 MB, the last row, which may be cut off, is dropped.

When either limit stops the reading, a line under the table says:
"Showing the first N rows. The rest of the file is not shown." N is the
number of rows the table holds.

The table draws only the rows in view, so scrolling does not slow down as the
row count grows.

### States

- **Loading:** a spinner in the middle of the pane until the first read
  finishes.
- **The file changes on disk:** the viewer reads it again. The old table
  stays on screen until the new one is ready, so the pane does not flash.
- **An empty file:** the pane says "This file is empty."
- **A header row and no other rows:** the table shows its titles and no rows.
- **A quote that never closes:** the pane says "Cannot show this file as a
  table: the quote that opens on line N never closes. The source button shows
  the file as text." N is the line, counting from 1, where the quoted field
  starts. Without this check, the rest of the file would fall into one cell.
- **A file that cannot be read** (removed, no permission): the pane says
  "Could not read file", as the text view does.

## Design

### Units

New files live in `Sources/TBDApp/Panes/TablePreview/`, so
`CodeViewerPaneView.swift` does not grow.

- **`DelimitedTextParser`**
  - **What it does:** turns bytes into rows under the rules in "Reading the
    file".
  - **Inputs:** the bytes, the delimiter, the row limit, and whether the bytes
    were cut short by the byte limit.
  - **Output:** a `DelimitedTable` (the titles, the rows, the column count,
    and whether the reading stopped at a limit), or an error that names the
    line of a quote that never closes.
  - **Pure:** no file access and no actor isolation, so tests feed it strings.
- **`DelimitedTableLoader`**
  - **What it does:** reads a file off the main actor and hands the bytes to
    the parser.
  - **Reading:** it opens only a regular file, for the reason `TextSniff`
    gives: opening a FIFO blocks. It reads at most 50 MB with
    `read(upToCount:)`, which throws on a read error where `readData` raises
    an exception Swift cannot catch.
- **`TablePreviewView`**
  - **What it is:** an `NSViewRepresentable` around an `NSScrollView` that
    holds one `NSTableView`, with the table's data source and delegate on its
    coordinator.
  - **Cells:** view-based, with plain `NSTextField` cells the table reuses.
    No SwiftUI view is hosted in a cell (the root `CLAUDE.md`, "SwiftUI or
    AppKit").
  - **A new table:** rebuilds the columns and their widths only when the
    column count or the titles change, then reloads the rows. A rewrite that
    keeps the columns keeps the user's column widths and the scroll position.
- **`DelimitedTablePreview`**
  - **What it is:** the SwiftUI view that `FilePreviewView` shows for a table.
    It runs the loader in a `.task` keyed on the path and the revision, and
    shows the spinner, the messages, the table and the line about the limit.

### Changes to existing code

- **`FilePreviewKind`** gains `.table`. `FilePreviewClassifier` returns it
  for a CSV or TSV file that passes the text test, when the pane asks for its
  rendered view. Its `rendersMarkdown` parameter becomes `rendersRichView`,
  since it now covers both views.
- **`MarkdownPaneLayout`** becomes `RichViewPaneLayout`. It gives a single CSV
  or TSV file the whole pane, as it does a single markdown file, outside the
  pane's scroll view and its forced dark theme.
- **`isRenderableFile`** in `CodeViewerPaneView.swift`, which decides whether
  the source button appears, reads a new set of table extensions as well as
  the markdown one.
- **`MarkdownWebViewConfiguration.renderableExtensions`** stays markdown only.
  It also decides which links in a rendered markdown file open in the pane,
  and this change does not touch that.
- **`FilePreviewView`** routes `.table` to `DelimitedTablePreview`.

### What this change does not need

- **No feature flag.** The table is a new view for one kind of file. It
  starts nothing by itself, deletes nothing, and the file's text is one click
  away on the source button, the same arrangement markdown has.
- **No daemon, database or RPC change.** Drawing a file is app-only.
- **No reconciler.** The change creates no durable resource: no file,
  process, git ref or tmux object outlives the view.

## Testing

Unit tests use Swift Testing and run through `scripts/test.sh`.

- **`DelimitedTextParser`:**
  - plain comma rows, and tab rows
  - a quoted field holding the delimiter, a line break, and a doubled quote
  - `\n`, `\r\n` and `\r` row ends, and a mix of them
  - a line break at the end of the file adds no row
  - an empty line in the middle is a row with one empty field
  - a byte order mark is removed from the first title
  - a quote in the middle of an unquoted field is kept as a character
  - rows shorter and longer than the header give the widest row's column count
  - a quote that never closes is an error naming the line where it opens
  - the row limit stops at N rows and marks the table as stopped
  - input cut short by the byte limit drops its last row and marks the table
    as stopped
  - an empty input, and a header with no rows
  - invalid UTF-8 shows as `�`
- **`DelimitedTableLoader`:** a directory and a FIFO are refused, and the FIFO
  check returns without blocking.
- **`FilePreviewClassifier`:**
  - `csv`, `CSV` and `tsv` that read as text are `.table` when the rendered
    view is asked for, and `.text` when it is not
  - a `.csv` with a NUL byte is not `.table`
  - markdown is still `.renderedMarkdown`
- **`RichViewPaneLayout`:** a single CSV or TSV file takes the whole pane; in
  source mode or in a multi-file selection it does not.
- **`TablePreviewView`**, in an offscreen window:
  - the column titles are the header row and the row count is the data rows
  - a cell shows its value, and a value with a line break shows `↵`
  - a rewrite with the same columns keeps a column width the test changed
- **`FilePreviewView`:** a CSV file shows the table, and with `showSourceCode`
  shows the text view.

Live verification after `scripts/restart.sh`, with cua-driver window captures:

1. A CSV and a TSV file open as tables, with the header row pinned while the
   rows scroll.
2. The source button switches to highlighted text and back.
3. A file of more than 100,000 rows opens without a hang and shows the line
   about the limit.
4. A wide file scrolls sideways, and a dragged column keeps its width when an
   agent rewrites the file.
5. The table follows a switch between light and dark appearance.

## Out of scope

- Sorting, a row-number column, copying rows, and right-aligned number
  columns. Each can come later on this table.
- Other delimiters, such as semicolons or pipes, and a delimiter guessed from
  the content.
- Encodings other than UTF-8, such as the UTF-16 that Excel's "Unicode Text"
  export writes. Those fail the text test and reach the "Cannot preview"
  screen.
- Tables in a multi-file selection, and in the transcript overlay's file
  frame.
- Opening a CSV linked from a rendered markdown file in the pane.

## Rejected alternatives

### An HTML table in the markdown webview

The pane already renders markdown in a `WKWebView`, so a CSV could become an
HTML table there, with a sticky header in CSS. But a webview builds every row
into its document: 100,000 rows would be 100,000 DOM rows, built and laid out
before the first paint. An `NSTableView` asks only for the rows in view.

### SwiftUI's `Table`

On macOS, SwiftUI's `Table` sits on an `NSTableView`. But it wants its columns
known at compile time, and a CSV's columns are known only when the file is
read. `TableColumnForEach` builds columns at run time, but adds a SwiftUI
layer over each cell. The root `CLAUDE.md` asks for AppKit all the way down to
the cells for large scrolling collections, after the transcript and the
sidebar both outgrew their SwiftUI versions.

### A delimiter guessed from the content

Python's `csv.Sniffer` and similar tools guess the delimiter from a sample.
The guess can be wrong, and a wrong guess shows a table of one column, or
splits a column in two. The extension states the delimiter, and every file
this change handles has one.
