#!/usr/bin/env bash
# Tests for scripts/lint-daemon-layers.py — run: bash scripts/lint-daemon-layers.test.sh [test_name...]
#
# ZERO BUILDS, NO GIT, AND IT NEVER READS THE REAL Sources/TBDDaemon. Every case
# writes a small sample tree under one scratch directory — a few Swift files
# under `Sources/TBDDaemon/<unit>/` and a `scripts/daemon-links.txt` — and runs
# the check against it with `--repo-root`. The Swift in these fixtures is
# scanner input and is never compiled, so it only has to look like Swift to a
# lexer, not type-check.
#
# EVERY REFERENCE CASE RUNS BOTH WAYS. `both_ways` writes a file that makes the
# reference and expects the check to fail and name it, then rewrites the same
# file without the reference and expects a pass. A case that only proved the
# failure could pass against a check that reddens on everything; the pass half
# is what makes it discriminate.
#
# IT RUNS UNDER TWO INTERPRETERS. CI runs it on Linux under bash 5 and that
# runner's python3; the pre-push hook runs the check itself under whatever
# `python3` the developer has, which on a Mac without Homebrew is the system
# 3.9. So the harness stays bash 3.2-clean, and `PYTHON` picks the interpreter:
#   PYTHON=/usr/bin/python3 /bin/bash scripts/lint-daemon-layers.test.sh
#
# Name cases as arguments to run only those; with none, every `test_*` runs.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F` below
# shellcheck disable=SC2001 # indenting a captured multi-line report is what sed is for
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/lint-daemon-layers.py"
PYTHON="${PYTHON:-python3}"
DAEMON_REL="Sources/TBDDaemon"

FAIL=0
assert_rc()       { if [[ "$3" == "$2" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected exit $2, got $3"; echo "$4" | sed 's/^/       /'; FAIL=1; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: output lacks [$3]"; echo "$2" | sed 's/^/       /'; FAIL=1; fi; }
assert_lacks()    { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: output contains [$3]"; echo "$2" | sed 's/^/       /'; FAIL=1; fi; }

# One scratch directory holds every fixture and goes on exit. Fixtures are
# made inside `$(...)`, a subshell, so an array of their paths appended to
# there would never reach the trap; a single parent directory needs no list.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lint-daemon-layers-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# The one declaring unit every case references. Fixture Swift is never compiled.
BASE_SWIFT='struct Widget {
    static func make() -> Widget { Widget() }
}
protocol Widgeting {}
func widgetCount() -> Int { 0 }
let widgetLimit = 3
private func baseSecret() {}
extension String {
    func gadgetName() -> String { self }
}'

# A fresh sample tree: Base/Widget.swift holding BASE_SWIFT, and a list that
# holds only a comment, so no link is listed. Echoes the fixture root.
mkfix() {
  local d; d="$(mktemp -d "$WORK/fixture.XXXXXX")"
  mkdir -p "$d/$DAEMON_REL/Base" "$d/scripts"
  printf '%s\n' "$BASE_SWIFT" > "$d/$DAEMON_REL/Base/Widget.swift"
  printf '%s\n' "# fixture" > "$d/scripts/daemon-links.txt"
  echo "$d"
}

# Write a file under the fixture's Sources/TBDDaemon. `put <root> <path> <content>`
put() {
  mkdir -p "$(dirname "$1/$DAEMON_REL/$2")"
  printf '%s\n' "$3" > "$1/$DAEMON_REL/$2"
}

# Rewrite the fixture's list as the comment line plus the given links, in the
# order given. `list <root> [<line>...]`
list() {
  local d="$1"; shift
  printf '%s\n' "# fixture" ${@+"$@"} > "$d/scripts/daemon-links.txt"
}

# Run the check against a fixture. Sets RUN_OUT (stdout and stderr) and RUN_RC.
run_check() {
  RUN_OUT="$("$PYTHON" "$SCRIPT" --repo-root "$1" 2>&1)"
  RUN_RC=$?
}

# `both_ways <label> <line> <name> <with> <without>`: Top/User.swift holding
# <with> fails and names the reference at <line>; holding <without>, it passes.
both_ways() {
  local label="$1" line="$2" name="$3" with="$4" without="$5" d
  d="$(mkfix)"
  put "$d" Top/User.swift "$with"
  run_check "$d"
  assert_rc "$label: the reference fails the check" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "$label: and is named" "$RUN_OUT" \
    "Sources/TBDDaemon/Top/User.swift:$line: Top -> Base is a new link: $name is declared in Base"
  put "$d" Top/User.swift "$without"
  run_check "$d"
  assert_rc "$label: without it, the check passes" 0 "$RUN_RC" "$RUN_OUT"
}

# `passes <label> <content>`: Top/User.swift holding <content> passes.
passes() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift "$2"
  run_check "$d"
  assert_rc "$1" 0 "$RUN_RC" "$RUN_OUT"
}

# `cannot_scan <label> <content> <message> <fixed>`: Top/User.swift holding
# <content> stops the check with exit 2 and <message>; holding <fixed>, it passes.
cannot_scan() {
  local label="$1" content="$2" message="$3" fixed="$4" d
  d="$(mkfix)"
  put "$d" Top/User.swift "$content"
  run_check "$d"
  assert_rc "$label: cannot scan" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "$label: and says where" "$RUN_OUT" "lint-daemon-layers: cannot scan Sources/TBDDaemon/Top/User.swift:$message"
  put "$d" Top/User.swift "$fixed"
  run_check "$d"
  assert_rc "$label: fixed, the check passes" 0 "$RUN_RC" "$RUN_OUT"
}

# ---------------------------------------------------------------------------
# What counts as a reference
# ---------------------------------------------------------------------------

test_type_in_signature() {
  both_ways "signature" 1 Widget 'func use(_ w: Widget) {}' 'func use(_ w: Int) {}'
}

test_construction() {
  both_ways "construction" 1 Widget 'let w = Widget()' 'let w = Int()'
}

test_static_call() {
  both_ways "static call" 1 Widget 'let w = Widget.make()' 'let w = Int.max'
}

test_extension_on_other_units_type() {
  both_ways "extension" 1 Widget 'extension Widget {}' 'extension Int {}'
}

test_conformance() {
  both_ways "conformance" 1 Widgeting 'struct Gadget: Widgeting {}' 'struct Gadget {}'
}

test_top_level_function() {
  both_ways "top-level function" 1 widgetCount 'let n = widgetCount()' 'let n = 0'
}

test_global() {
  both_ways "global" 1 widgetLimit 'let n = widgetLimit' 'let n = 0'
}

# `Widgeté` is one identifier, not `Widget` followed by something else.
test_unicode_identifier_is_not_a_prefix_match() {
  both_ways "unicode" 1 Widget 'let x = Widget()' "$(printf 'let x = Widget\303\251()')"
}

# Code inside a literal still counts: an interpolation is code, and so is a
# name in backticks.
test_string_interpolation_counts() {
  both_ways "interpolation" 1 Widget 'let s = "\(Widget.make())"' 'let s = "\(1)"'
}

# In a raw string only `\#(` interpolates; a bare `\(` is two characters of text.
test_raw_string_interpolation_counts() {
  both_ways "raw interpolation" 1 widgetLimit 'let s = #"\#(widgetLimit)"#' 'let s = #"\(widgetLimit)"#'
}

# A parenthesis inside an interpolation does not close it.
test_parentheses_inside_an_interpolation() {
  both_ways "parentheses in an interpolation" 1 Widget 'let s = "\(max(1, 2) + Widget.count)"' \
    'let s = "\(max(1, 2) + other.count)"'
}

test_multiline_interpolation_counts() {
  both_ways "multi-line interpolation" 2 widgetLimit $'let s = """\n\\(widgetLimit)\n"""' $'let s = """\nwidgetLimit\n"""'
}

test_backtick_name_counts() {
  # shellcheck disable=SC2016 # the backticks are Swift, not command substitution
  both_ways "backticks" 1 Widget 'let w = `Widget`()' 'let w = `Int`()'
}

# Anything in backticks but a single name is one raw identifier, and the words
# in it are not code: a test named for Widget does not use it.
test_raw_identifier_names_nothing() {
  # shellcheck disable=SC2016 # the backticks are Swift, not command substitution
  both_ways "raw identifier" 1 Widget 'func `checks that Widget parses`() { _ = Widget() }' \
    'func `checks that Widget parses`() {}'
  # shellcheck disable=SC2016
  passes "a raw identifier holding a quote" 'func `reads a "quoted" Widget`() {}'
}

# A `/` between two operands is division; reading it as a regex would hide
# the name between the slashes.
test_division_is_not_a_regex() {
  both_ways "division" 1 Widget 'let x = total/Widget.scale/2' 'let x = total/other.scale/2'
  # At the start of a line a `/` may open a regex, but not one that starts or
  # ends on a space: each of these is two divisions.
  both_ways "a regex cannot start with a space" 2 Widget $'let x = total\n    / Widget.scale/2' \
    $'let x = total\n    / other.scale/2'
  both_ways "a regex cannot end on a space" 2 Widget $'let x = total\n    /Widget.scale / 2' \
    $'let x = total\n    /other.scale / 2'
}

# ---------------------------------------------------------------------------
# Comments and literals are not references
# ---------------------------------------------------------------------------

test_line_comment_ignored() {
  both_ways "line comment" 1 Widget 'let w = Widget()' 'let w = 0 // Widget()'
}

test_doc_comment_ignored() {
  both_ways "doc comment" 1 Widget '_ = Widget.make()' '/// Widget.make()'
}

test_nested_block_comment_ignored() {
  both_ways "nested block comment" 1 Widget 'let w = Widget() /* a /* b */ c */' 'let w = 0 /* a /* b */ Widget() */'
}

test_string_ignored() {
  both_ways "string" 1 Widget 'let s = Widget.make()' 'let s = "Widget.make()"'
}

# `\"` is an escaped quote, which does not close the string.
test_escaped_quote_ignored() {
  both_ways "escaped quote" 1 Widget 'let s = "a"; _ = Widget()' 'let s = "a \" Widget \" b"'
}

test_raw_string_ignored() {
  both_ways "raw string" 1 Widget 'let s = Widget.make()' 'let s = #"say "Widget" \(Widget)"#'
}

test_multiline_string_ignored() {
  both_ways "multi-line string" 2 Widget $'let s = """\n\\(Widget.make())\n"""' $'let s = """\nWidget "quoted" {\n"""'
}

# A lexer that misses the regex reads the quote as a string's start, or the
# brace as unbalanced, and fails a file that is fine.
test_bare_regex_ignored() {
  both_ways "bare regex" 1 Widget 'let r = Widget.make()' 'let r = /Widget+/'
  passes "a bare regex holding a quote and a brace" 'let r = /\{"Widget"/'
  both_ways "a bare regex at the start of a line" 2 Widget $'let patterns = [\n    Widget.pattern,\n]' \
    $'let patterns = [\n    /Widget/,\n]'
}

test_extended_regex_ignored() {
  both_ways "extended regex" 1 Widget 'let r = Widget.make()' 'let r = #/Widget "x" {/#'
}

# A bare regex can follow a keyword that an expression follows. Read as
# division there, a name in its body would count, and a quote in it would open
# a string that never closes.
test_bare_regex_after_a_keyword() {
  local keyword
  for keyword in return throw try await in case where if guard while switch; do
    both_ways "regex after $keyword" 1 Widget "_ = { $keyword Widget.pattern }" "_ = { $keyword /Widget/ }"
  done
  passes "a quote in a regex after try" '_ = try /"x/.firstMatch(in: s)'
  passes "a quote in a regex after case" 'switch s { case /"a/: break; default: break }'
}

# ---------------------------------------------------------------------------
# Names that are not references
# ---------------------------------------------------------------------------

# After a `.` a name is a member of whatever precedes it, never a top-level one.
test_name_after_dot_ignored() {
  both_ways "after a dot" 1 widgetCount 'let n = widgetCount()' 'let n = gadget.widgetCount()'
  both_ways "after a dot, uppercase" 1 Widget 'let k = Widget.self' 'let k = Outer.Widget.self'
}

# `...` is an operator, not a member access: the name after it is a range's
# bound. `..<` needs no exception, and keeps working.
test_name_after_a_range_counts() {
  both_ways "closed range" 1 widgetLimit 'for i in 0...widgetLimit {}' 'for i in 0...limit {}'
  both_ways "closed range, uppercase" 1 Widget 'for i in 1...Widget.maxAttempts {}' 'for i in 1...Int.max {}'
  both_ways "half-open range" 1 widgetLimit 'for i in 0..<widgetLimit {}' 'for i in 0..<limit {}'
}

test_argument_label_ignored() {
  both_ways "argument label" 1 widgetLimit 'takes(widgetLimit)' 'takes(widgetLimit: 1)'
  both_ways "argument label after a comma" 1 widgetLimit 'takes(a, widgetLimit)' 'takes(a, widgetLimit: 1)'
}

# A name before a `:` is a label only directly in parentheses. In brackets it
# is a dictionary key, and after a `case` item's comma a pattern: both code.
test_label_rule_is_for_parentheses() {
  both_ways "dictionary key" 1 widgetLimit 'let d = [a: 1, widgetLimit: 2]' 'let d = [a: 1, limit: 2]'
  both_ways "case item" 1 widgetLimit 'switch n { case 1, widgetLimit: break; default: break }' \
    'switch n { case 1, 2: break; default: break }'
}

# A label is skipped where it stands; it does not make the name the file's own.
test_label_does_not_hide_a_later_use() {
  both_ways "a use after a same-named label" 2 widgetLimit $'takes(widgetLimit: 1)\nlet n = widgetLimit' \
    $'takes(widgetLimit: 1)\nlet n = 0'
}

# The blind spot the guide names: a local of the same name shadows the global
# for the whole file.
test_local_let_shadows_lowercase_global() {
  both_ways "local let" 1 widgetLimit 'func f() { let limit = 2; _ = widgetLimit }' \
    'func f() { let widgetLimit = 2; _ = widgetLimit }'
}

test_parameter_shadows() {
  both_ways "parameter" 1 widgetLimit 'func f(limit: Int) { _ = widgetLimit }' \
    'func f(widgetLimit: Int) { _ = widgetLimit }'
  passes "an external label's internal name shadows too" 'func f(with widgetLimit: Int) { _ = widgetLimit }'
  # Only a `:` directly in the parameter list follows a parameter's name; one
  # inside brackets is a dictionary's.
  both_ways "a dictionary default argument" 1 widgetLimit 'func f(a: [Int: Int] = [widgetLimit: 1]) {}' \
    'func f(a: [Int: Int] = [limit: 1]) {}'
}

test_closure_parameter_shadows() {
  both_ways "closure parameter" 1 widgetLimit 'let g = { (limit: Int) in widgetLimit }' \
    'let g = { (widgetLimit: Int) in widgetLimit }'
}

test_for_in_shadows() {
  both_ways "for-in" 1 widgetLimit 'for x in xs { _ = widgetLimit }' 'for widgetLimit in xs { _ = widgetLimit }'
  both_ways "for-in over tuples" 1 widgetLimit 'for (i, limit) in pairs { _ = widgetLimit }' \
    'for (i, widgetLimit) in pairs { _ = widgetLimit }'
}

# An enum's case names are its own, the second of a list as much as the first.
test_enum_case_shadows() {
  both_ways "enum case" 1 widgetLimit 'enum Mode { case a, b; static let all: [Mode] = [a, widgetLimit] }' \
    'enum Mode { case a, widgetLimit; static let all: [Mode] = [a, widgetLimit] }'
}

test_private_top_level_shadows() {
  both_ways "private type" 2 Widget $'struct Gadget {}\nlet w = Widget()' $'private struct Widget {}\nlet w = Widget()'
}

test_nested_type_shadows() {
  both_ways "nested type" 1 Widget 'struct Box { struct Gizmo {}; let w = Widget() }' \
    'struct Box { struct Widget {}; let w = Widget() }'
}

# A generic parameter, and a protocol's primary associated type, is the file's
# own name. A constraint on one is still a reference.
test_generic_parameter_shadows() {
  both_ways "generic function" 1 Widget 'func f<T>(_ x: T) -> Widget? { nil }' 'func f<Widget>(_ x: Widget) -> Widget? { nil }'
  both_ways "generic type" 1 Widget 'struct Box<T, U> { let w: Widget }' 'struct Box<T, Widget> { let w: Widget }'
  both_ways "generic initializer" 1 Widget 'struct Box { init?<T>(_ w: Widget) {} }' 'struct Box { init?<Widget>(_ w: Widget) {} }'
  both_ways "parameter pack" 1 Widget 'func f<each T>(_ w: Widget) {}' 'func f<each Widget>(_ w: Widget) {}'
  both_ways "primary associated type" 1 Widget 'protocol Holder<T> { var w: Widget { get } }' \
    'protocol Holder<Widget> { var w: Widget { get } }'
  both_ways "a constraint" 1 Widgeting 'struct Box<T: Widgeting> {}' 'struct Box<T: Equatable> {}'
}

test_associated_type_shadows() {
  both_ways "associated type" 1 Widget 'protocol Holder { associatedtype Gadget; var w: Widget { get } }' \
    'protocol Holder { associatedtype Widget; var w: Widget { get } }'
}

# A type or function declared inside a function's body is the file's own.
test_local_declaration_shadows() {
  both_ways "local type" 1 Widget 'func f() { struct Gizmo {}; _ = Widget() }' 'func f() { struct Widget {}; _ = Widget() }'
  both_ways "local function" 1 widgetCount 'func f() { func helper() -> Int { 1 }; _ = widgetCount() }' \
    'func f() { func widgetCount() -> Int { 1 }; _ = widgetCount() }'
  # `actor` names a local only before a name on its line; here it is a value.
  both_ways "actor as a value" 3 widgetCount $'func f(actor: Int) {\n    let a = actor\n    widgetCount()\n}' \
    $'func f(actor: Int) {\n    let a = actor\n    count()\n}'
  # `case let Kind.code(x)` binds x, and names Kind.
  both_ways "a qualified let pattern" 1 Widget 'func f(e: Error) { if case let Widget.failed(x) = e {} }' \
    'func f(e: Error) { if case let Gadget.failed(x) = e {} }'
}

# An enum's case list continues past a line break after a comma.
test_enum_case_continuation_shadows() {
  both_ways "case on a continuation line" 4 widgetLimit \
    $'enum Mode {\n    case a,\n        b\n    static let all: [Mode] = [a, widgetLimit]\n}' \
    $'enum Mode {\n    case a,\n        widgetLimit\n    static let all: [Mode] = [a, widgetLimit]\n}'
}

# A private extension declares nothing of its own; it still extends Widget.
test_private_extension_still_counts() {
  both_ways "private extension" 1 Widget 'private extension Widget {}' 'private extension Int {}'
}

# `import struct M.Name` imports one declaration from another module; it
# declares nothing here. Read as a declaration of `M`, it would turn every
# other unit's `import M` into a link.
test_scoped_import_is_not_a_declaration() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift $'import TBDShared\nlet r = 1'
  put "$d" Mid/Reader.swift 'struct TBDShared {}'
  run_check "$d"
  assert_rc "a declaration of the module's name is indexed" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "and the import names it" "$RUN_OUT" \
    "Sources/TBDDaemon/Top/User.swift:1: Top -> Mid is a new link: TBDShared is declared in Mid"
  put "$d" Mid/Reader.swift $'import struct TBDShared.Gizmo\nimport func TBDShared.gizmoCount\nstruct Reader {}'
  run_check "$d"
  assert_rc "a scoped import declares nothing" 0 "$RUN_RC" "$RUN_OUT"
}

# A `private` belongs to the one declaration it modifies: it does not hide the
# next declaration on its line, and it still applies from the line above.
test_privacy_is_per_declaration() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'let g = Gizmo()'
  put "$d" Base/More.swift 'private let seed = 1; struct Gizmo {}'
  run_check "$d"
  assert_rc "a declaration after a private one on its line is indexed" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "and is named" "$RUN_OUT" "Top -> Base is a new link: Gizmo"
  put "$d" Base/More.swift $'let seed = 1\nprivate\nstruct Gizmo {}'
  run_check "$d"
  assert_rc "a private on the line above its keyword is not" 0 "$RUN_RC" "$RUN_OUT"
}

# `private(set)` restricts only the setter, so the name stays indexed.
test_private_set_is_indexed() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'let n = gizmoCount'
  put "$d" Base/More.swift 'private(set) var gizmoCount = 0'
  run_check "$d"
  assert_rc "a private(set) global is indexed" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "and is named" "$RUN_OUT" "Top -> Base is a new link: gizmoCount"
  put "$d" Base/More.swift 'private var gizmoCount = 0'
  run_check "$d"
  assert_rc "a private one is not" 0 "$RUN_RC" "$RUN_OUT"
}

# `let (a, b) = ...` at file scope declares both names.
test_tuple_global_is_indexed() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'let h = gizmoHeight'
  put "$d" Base/More.swift 'let (gizmoWidth, gizmoHeight) = (1, 2)'
  run_check "$d"
  assert_rc "a tuple global is indexed" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "and is named" "$RUN_OUT" "Top -> Base is a new link: gizmoHeight"
  put "$d" Base/More.swift 'let (gizmoWidth, gizmoDepth) = (1, 2)'
  run_check "$d"
  assert_rc "without the name, the check passes" 0 "$RUN_RC" "$RUN_OUT"
}

test_private_declarations_not_indexed() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'let x = baseSecret()'
  run_check "$d"
  assert_rc "another unit's private function is not a reference" 0 "$RUN_RC" "$RUN_OUT"
  put "$d" Base/Widget.swift "${BASE_SWIFT/private func baseSecret/func baseSecret}"
  run_check "$d"
  assert_rc "made internal, it is" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "and is named" "$RUN_OUT" "Top -> Base is a new link: baseSecret"
}

# The blind spot the guide names: a member another unit's extension adds is
# not indexed, so calling it makes no link.
test_extension_members_not_indexed() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'extension Int { func f() -> String { gadgetName() } }'
  run_check "$d"
  assert_rc "a member from another unit's extension is not a reference" 0 "$RUN_RC" "$RUN_OUT"
  put "$d" Base/Widget.swift "$BASE_SWIFT"$'\nfunc gadgetName() -> String { "" }'
  run_check "$d"
  assert_rc "a top-level function of the same name is" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "and is named" "$RUN_OUT" "Top -> Base is a new link: gadgetName"
}

# ---------------------------------------------------------------------------
# The list
# ---------------------------------------------------------------------------

test_listed_link_passes_and_unused_is_stale() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'let w = Widget()'
  list "$d" 'Top -> Base'
  run_check "$d"
  assert_rc "a listed link passes" 0 "$RUN_RC" "$RUN_OUT"
  assert_contains "and says so" "$RUN_OUT" "lint-daemon-layers: OK"

  put "$d" Top/User.swift ''
  run_check "$d"
  assert_rc "a listed link no code makes fails" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "as stale, at its line in the list" "$RUN_OUT" \
    "scripts/daemon-links.txt:2: Top -> Base is stale: no file in Top names a declaration from Base"
}

test_failure_footer() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'let w = Widget()'
  run_check "$d"
  assert_rc "an unlisted link fails" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "the footer prints the line to add" "$RUN_OUT" $'\n    Top -> Base\n'
  assert_contains "and points to the guide" "$RUN_OUT" 'Sources/TBDDaemon/CLAUDE.md, "Links between folders"'
}

test_misspelled_unit_is_stale() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'let w = Widget()'
  list "$d" 'Tpo -> Base'
  run_check "$d"
  assert_rc "a misspelled unit fails" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "the real link is new" "$RUN_OUT" "Top -> Base is a new link"
  assert_contains "the misspelled one is stale" "$RUN_OUT" "Tpo -> Base is stale"
  assert_contains "and named as no unit" "$RUN_OUT" "(Tpo is not a unit under Sources/TBDDaemon)"
}

test_moved_file_flips_links() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'let w = Widget()'
  list "$d" 'Top -> Base'
  run_check "$d"
  assert_rc "before the move, the list matches" 0 "$RUN_RC" "$RUN_OUT"

  mkdir -p "$d/$DAEMON_REL/Mid"
  mv "$d/$DAEMON_REL/Top/User.swift" "$d/$DAEMON_REL/Mid/User.swift"
  run_check "$d"
  assert_rc "after the move, the check fails" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "the old link is stale" "$RUN_OUT" "Top -> Base is stale"
  assert_contains "the new link is new" "$RUN_OUT" "Sources/TBDDaemon/Mid/User.swift:1: Mid -> Base is a new link"
}

test_list_whitespace_is_tolerated() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'let w = Widget()'
  printf '# fixture\r\n\r\nTop -> Base  \r\n' > "$d/scripts/daemon-links.txt"
  run_check "$d"
  assert_rc "CRLF endings and trailing spaces are tolerated" 0 "$RUN_RC" "$RUN_OUT"
  printf '# fixture\r\n\r\nTop -> Base  ' > "$d/scripts/daemon-links.txt"
  run_check "$d"
  assert_rc "so is a missing final newline" 0 "$RUN_RC" "$RUN_OUT"
}

test_malformed_list_cannot_check() {
  local d empty; d="$(mkfix)"
  put "$d" Top/User.swift 'let w = Widget()'

  list "$d" 'Top->Base'
  run_check "$d"
  assert_rc "a line without the arrow's spaces" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named" "$RUN_OUT" 'lint-daemon-layers: cannot read scripts/daemon-links.txt:2: expected "A -> B", got "Top->Base"'

  list "$d" 'Top -> Base' 'Top -> Base'
  run_check "$d"
  assert_rc "a duplicate" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named" "$RUN_OUT" 'scripts/daemon-links.txt:3: "Top -> Base" is listed twice'

  list "$d" 'Top -> Base' 'Mid -> Base'
  run_check "$d"
  assert_rc "an unsorted list" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named" "$RUN_OUT" 'scripts/daemon-links.txt:3: out of order; keep the list sorted (LC_ALL=C sort)'

  list "$d" 'Top -> Top'
  run_check "$d"
  assert_rc "a self-link" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named" "$RUN_OUT" 'scripts/daemon-links.txt:2: "Top -> Top" links a unit to itself'

  rm "$d/scripts/daemon-links.txt"
  run_check "$d"
  assert_rc "a missing list" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named" "$RUN_OUT" "lint-daemon-layers: cannot read scripts/daemon-links.txt: not found"

  empty="$(mktemp -d "$WORK/empty.XXXXXX")"
  run_check "$empty"
  assert_rc "a root with no Sources/TBDDaemon" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named" "$RUN_OUT" "lint-daemon-layers: cannot scan Sources/TBDDaemon: not found"
}

# A unit name is one word. A space in one is a format error at its line, and
# a folder with a space in its name stops the scan, since its links could not
# be listed.
test_unit_name_with_a_space_cannot_check() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'let w = Widget()'
  list "$d" 'Top Level -> Base'
  run_check "$d"
  assert_rc "a listed unit with a space" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named" "$RUN_OUT" \
    'lint-daemon-layers: cannot read scripts/daemon-links.txt:2: "Top Level -> Base": a unit name has no spaces in it'
  list "$d" 'Top -> Base'
  run_check "$d"
  assert_rc "without the space, the check passes" 0 "$RUN_RC" "$RUN_OUT"

  mkdir -p "$d/$DAEMON_REL/Top Level"
  mv "$d/$DAEMON_REL/Top/User.swift" "$d/$DAEMON_REL/Top Level/User.swift"
  run_check "$d"
  assert_rc "a folder with a space in its name" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named" "$RUN_OUT" \
    'lint-daemon-layers: cannot scan Sources/TBDDaemon/Top Level/User.swift: the folder "Top Level" has a space in its name'
}

# The list is UTF-8 like the Swift: a byte that is not stops the check at its
# line. A byte order mark is not text, in the list or in a Swift file.
test_list_encoding() {
  local d bom; d="$(mkfix)"; bom="$(printf '\357\273\277')"
  put "$d" Top/User.swift 'let w = Widget()'
  printf '# fixture\nTop -> Base\n\351\n' > "$d/scripts/daemon-links.txt"
  run_check "$d"
  assert_rc "a list byte that is not UTF-8" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named" "$RUN_OUT" "lint-daemon-layers: cannot read scripts/daemon-links.txt:3: not valid UTF-8"
  printf '\357\273\277# fixture\nTop -> Base\n' > "$d/scripts/daemon-links.txt"
  run_check "$d"
  assert_rc "a list that starts with a byte order mark passes" 0 "$RUN_RC" "$RUN_OUT"
  both_ways "a Swift file that starts with a byte order mark" 1 Widget \
    "${bom}Widget.pattern.firstMatch(in: s)" "${bom}/Widget/.firstMatch(in: s)"
}

# A file or folder the check cannot open stops it with exit 2 and the path,
# never a traceback: skipping it would drop its links.
test_unreadable_cannot_check() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'let w = Widget()'
  list "$d" 'Top -> Base'
  chmod 000 "$d/$DAEMON_REL/Top/User.swift"
  if [ -r "$d/$DAEMON_REL/Top/User.swift" ]; then
    chmod 644 "$d/$DAEMON_REL/Top/User.swift"
    echo "ok   - unreadable files: skipped, this user reads a mode 000 file"
    return
  fi
  run_check "$d"
  chmod 644 "$d/$DAEMON_REL/Top/User.swift"
  assert_rc "an unreadable Swift file" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named" "$RUN_OUT" "lint-daemon-layers: cannot read Sources/TBDDaemon/Top/User.swift: Permission denied"

  chmod 000 "$d/$DAEMON_REL/Top"
  run_check "$d"
  chmod 755 "$d/$DAEMON_REL/Top"
  assert_rc "an unreadable folder" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named" "$RUN_OUT" "lint-daemon-layers: cannot read Sources/TBDDaemon/Top: Permission denied"

  chmod 000 "$d/scripts/daemon-links.txt"
  run_check "$d"
  chmod 644 "$d/scripts/daemon-links.txt"
  assert_rc "an unreadable list" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named" "$RUN_OUT" "lint-daemon-layers: cannot read scripts/daemon-links.txt: Permission denied"

  run_check "$d"
  assert_rc "readable again, the check passes" 0 "$RUN_RC" "$RUN_OUT"
}

# ---------------------------------------------------------------------------
# The cycle report
# ---------------------------------------------------------------------------

test_two_unit_cycle_reported() {
  local d; d="$(mkfix)"
  put "$d" Base/Back.swift 'let g = Gadget()'
  put "$d" Top/User.swift $'struct Gadget {}\nlet w = Widget()'
  list "$d" 'Base -> Top' 'Top -> Base'
  run_check "$d"
  assert_rc "a listed cycle passes" 0 "$RUN_RC" "$RUN_OUT"
  assert_contains "and is counted" "$RUN_OUT" "cycles among the listed links: 1 group"
  assert_contains "and named" "$RUN_OUT" "    2 units, 2 links: Base, Top"
}

test_no_cycle_reported_as_none() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift $'struct Gadget {}\nlet w = Widget()'
  list "$d" 'Top -> Base'
  run_check "$d"
  assert_rc "a list with no cycle passes" 0 "$RUN_RC" "$RUN_OUT"
  assert_contains "and says so" "$RUN_OUT" "cycles among the listed links: none"
}

# Leaf hangs off the cycle without being in it.
test_three_unit_cycle_excludes_tail() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift $'struct Topper {}\nlet m = Middle()'
  put "$d" Mid/User.swift $'struct Middle {}\nlet w = Widget()'
  put "$d" Base/Back.swift $'let t = Topper()\nlet l = Leafy()'
  put "$d" Leaf/Leafy.swift 'struct Leafy {}'
  list "$d" 'Base -> Leaf' 'Base -> Top' 'Mid -> Base' 'Top -> Mid'
  run_check "$d"
  assert_rc "a listed three-unit cycle passes" 0 "$RUN_RC" "$RUN_OUT"
  assert_contains "and is named" "$RUN_OUT" $'\n    3 units, 3 links: Base, Mid, Top'
  assert_lacks "without its tail" "$RUN_OUT" "Leaf"
}

test_cycles_not_printed_on_failure() {
  local d; d="$(mkfix)"
  list "$d" 'Top -> Base'
  run_check "$d"
  assert_rc "a stale link fails" 1 "$RUN_RC" "$RUN_OUT"
  assert_lacks "and the cycle report waits for a pass" "$RUN_OUT" "cycles among"
}

# ---------------------------------------------------------------------------
# Units
# ---------------------------------------------------------------------------

test_root_files_are_one_unit() {
  local d; d="$(mkfix)"
  put "$d" Daemon.swift 'let p = PIDFile()'
  put "$d" PIDFile.swift 'struct PIDFile {}'
  run_check "$d"
  assert_rc "root files referencing each other make no link" 0 "$RUN_RC" "$RUN_OUT"

  put "$d" Daemon.swift 'let w = Widget()'
  run_check "$d"
  assert_rc "a root file referencing Base" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "is a link from (root)" "$RUN_OUT" "Sources/TBDDaemon/Daemon.swift:1: (root) -> Base is a new link: Widget"

  put "$d" Daemon.swift 'let p = PIDFile()'
  put "$d" Base/Uses.swift 'let p = PIDFile()'
  run_check "$d"
  assert_rc "Base referencing a root file" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "is a link to (root)" "$RUN_OUT" "Base -> (root) is a new link: PIDFile"
}

test_main_swift_is_skipped() {
  local d; d="$(mkfix)"
  put "$d" main.swift 'let w = Widget()'
  run_check "$d"
  assert_rc "main.swift's references are not read" 0 "$RUN_RC" "$RUN_OUT"
  rm "$d/$DAEMON_REL/main.swift"
  put "$d" Launch.swift 'let w = Widget()'
  run_check "$d"
  assert_rc "the same line in another root file" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "is a link from (root)" "$RUN_OUT" "(root) -> Base is a new link: Widget"

  d="$(mkfix)"
  put "$d" main.swift 'struct Entry {}'
  put "$d" Top/User.swift 'let e = Entry()'
  run_check "$d"
  assert_rc "main.swift's declarations are not indexed" 0 "$RUN_RC" "$RUN_OUT"
  rm "$d/$DAEMON_REL/main.swift"
  put "$d" Launch.swift 'struct Entry {}'
  run_check "$d"
  assert_rc "the same declaration in another root file" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "is a link to (root)" "$RUN_OUT" "Top -> (root) is a new link: Entry"
}

test_nested_folders_fold_into_top_folder() {
  local d; d="$(mkfix)"
  put "$d" Top/Deep/Nested.swift 'let w = Widget()'
  run_check "$d"
  assert_rc "a subfolder's reference" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "belongs to its top folder" "$RUN_OUT" "Sources/TBDDaemon/Top/Deep/Nested.swift:1: Top -> Base is a new link"

  d="$(mkfix)"
  put "$d" Base/Inner/More.swift 'let w = Widget()'
  run_check "$d"
  assert_rc "a subfolder referencing its own top folder makes no link" 0 "$RUN_RC" "$RUN_OUT"
}

test_non_swift_files_are_ignored() {
  local d; d="$(mkfix)"
  put "$d" Top/Migrations/20260101000000_x.sql 'Widget()'
  put "$d" Top/CLAUDE.md 'Widget'
  run_check "$d"
  assert_rc "SQL and Markdown files are not read" 0 "$RUN_RC" "$RUN_OUT"
  put "$d" Top/Migrations/X.swift 'Widget()'
  run_check "$d"
  assert_rc "the same content in a Swift file" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "is a link" "$RUN_OUT" "Top -> Base is a new link"
}

# ---------------------------------------------------------------------------
# Code the lexer cannot read
# ---------------------------------------------------------------------------

test_unbalanced_braces_cannot_scan() {
  cannot_scan "unclosed brace" 'struct A {' '1: unclosed "{"' 'struct A {}'
  cannot_scan "stray brace" '}' '1: "}" with no matching "{"' 'struct A {}'
}

test_unterminated_block_comment_cannot_scan() {
  cannot_scan "block comment" '/* Widget' '1: unterminated block comment' '/* Widget */'
}

test_unterminated_string_cannot_scan() {
  cannot_scan "string" 'let s = "Widget' '1: unterminated string literal' 'let s = "Widget"'
}

test_unterminated_multiline_string_cannot_scan() {
  cannot_scan "multi-line string" $'let s = """\nWidget' '1: unterminated multi-line string literal' \
    $'let s = """\nWidget\n"""'
}

test_unterminated_extended_regex_cannot_scan() {
  cannot_scan "extended regex" 'let r = #/Widget' '1: unterminated regex literal' 'let r = #/Widget/#'
}

# A traceback would name the script, not the file; exit 2 names the file and line.
test_non_utf8_cannot_scan() {
  local d; d="$(mkfix)"
  mkdir -p "$d/$DAEMON_REL/Top"
  printf 'let a = 1\nlet s = "\351"\n' > "$d/$DAEMON_REL/Top/User.swift"
  run_check "$d"
  assert_rc "bytes that are not UTF-8 cannot be scanned" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "and the line is named" "$RUN_OUT" \
    "lint-daemon-layers: cannot scan Sources/TBDDaemon/Top/User.swift:2: not valid UTF-8"
  printf 'let a = 1\nlet s = "e"\n' > "$d/$DAEMON_REL/Top/User.swift"
  run_check "$d"
  assert_rc "fixed, the check passes" 0 "$RUN_RC" "$RUN_OUT"
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

if [ $# -gt 0 ]; then
  CASES="$*"
else
  CASES=$(declare -F | awk '{print $3}' | grep '^test_' | sort)
fi
for case_name in $CASES; do
  if ! declare -F "$case_name" >/dev/null; then
    echo "FAIL - no such case: $case_name"
    FAIL=1
    continue
  fi
  echo "--- $case_name"
  "$case_name"
done

if [ "$FAIL" -ne 0 ]; then
  echo "lint-daemon-layers.test.sh: FAILURES"
  exit 1
fi
echo "lint-daemon-layers.test.sh: all green"
