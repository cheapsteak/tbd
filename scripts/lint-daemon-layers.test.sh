#!/usr/bin/env bash
# Tests for scripts/lint-daemon-layers.py — run: bash scripts/lint-daemon-layers.test.sh [test_name...]
#
# ZERO BUILDS, NO GIT, AND IT NEVER READS THE REAL Sources/TBDDaemon. Every case
# writes a small sample tree under one scratch directory — a few Swift files
# under `Sources/TBDDaemon/<unit>/` and a `scripts/daemon-layers.txt` — and runs
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
# IT RUNS UNDER PYTHON 3.9 AND BASH 3.2 AND UP. CI runs it on Linux under bash
# 5 and that runner's python3. The pre-push hook runs the check itself, not
# this harness, under whatever `python3` the developer has, which on a Mac
# without Homebrew is the system 3.9; CI's `lint` job holds the check to that
# 3.9. The harness is kept bash 3.2-clean so a Mac can run it under /bin/bash
# too, though no CI job enforces that. `PYTHON` picks the interpreter:
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

# A fresh sample tree: Base/Widget.swift holding BASE_SWIFT, and a layer file
# whose one layer is `Base, Top`, so a reference either way between the two
# fails. Echoes the fixture root. Top is a unit only once a case writes a
# Swift file into it, and until then the layer file names no unit: a case
# that never does writes its own layers.
mkfix() {
  local d; d="$(mktemp -d "$WORK/fixture.XXXXXX")"
  mkdir -p "$d/$DAEMON_REL/Base" "$d/scripts"
  printf '%s\n' "$BASE_SWIFT" > "$d/$DAEMON_REL/Base/Widget.swift"
  printf '%s\n' "# fixture" "Base, Top" > "$d/scripts/daemon-layers.txt"
  echo "$d"
}

# mkfix's tree with its declaring unit named Core, for a case that lists that
# unit above another: the check holds a unit named Base to the bottom line.
mkfix_core() {
  local d; d="$(mkfix)"
  mv "$d/$DAEMON_REL/Base" "$d/$DAEMON_REL/Core"
  printf '%s\n' "# fixture" "Core, Top" > "$d/scripts/daemon-layers.txt"
  echo "$d"
}

# Write a file under the fixture's Sources/TBDDaemon. `put <root> <path> <content>`
put() {
  mkdir -p "$(dirname "$1/$DAEMON_REL/$2")"
  printf '%s\n' "$3" > "$1/$DAEMON_REL/$2"
}

# Rewrite the fixture's layer file as the comment line plus the given lines,
# bottom layer first. `layers <root> [<line>...]`
layers() {
  local d="$1"; shift
  printf '%s\n' "# fixture" ${@+"$@"} > "$d/scripts/daemon-layers.txt"
}

# The line the check prints for a reference from Top into Base when both are
# in layer 1, as in every fixture that keeps mkfix's layers.
# `same_layer <path:line> <name>`
same_layer() {
  echo "Sources/TBDDaemon/$1: Top (layer 1) uses Base (layer 1), its own layer: $2 is declared in Base"
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
  assert_contains "$label: and is named" "$RUN_OUT" "$(same_layer "Top/User.swift:$line" "$name")"
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

# A raw string that opens with three quotes and closes on its own line is
# single-line: `#"""#` holds one quote. Read as multi-line, it never closes.
# One whose opening line holds no closer is multi-line, and a `"#` inside it
# does not close it.
test_raw_string_opening_with_three_quotes() {
  both_ways "a raw string holding one quote" 2 Widget $'let quote = #"""#\nlet w = Widget()' \
    $'let quote = #"""#\nlet w = 1'
  both_ways "a raw string holding two quotes" 2 Widget $'let quote = ##""""##\nlet w = Widget()' \
    $'let quote = ##""""##\nlet w = 1'
  both_ways "a multi-line raw string" 4 Widget $'let s = #"""\nWidget "# x\n"""#\nlet w = Widget()' \
    $'let s = #"""\nWidget "# x\n"""#\nlet w = 1'
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
  # Spaced, the bound still counts, and a `.` before it still makes a member.
  both_ways "a spaced range's member" 1 widgetLimit 'let r = 0 ... widgetLimit' 'let r = 0 ... .widgetLimit'
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

# A statement's label, and the name `break` or `continue` gives it; a trailing
# closure's label; a function type's parameter name; an uppercase argument
# label. None of them is a reference.
test_labels_ignored() {
  both_ways "a statement label and continue" 2 widgetLimit \
    $'func f(xs: [Int]) {\n    for x in xs { _ = widgetLimit }\n}' \
    $'func f(xs: [Int]) {\n    widgetLimit: for x in xs { continue widgetLimit }\n}'
  both_ways "a statement label and break" 2 widgetLimit \
    $'func f() {\n    while true { _ = widgetLimit }\n}' \
    $'func f() {\n    widgetLimit: while true { break widgetLimit }\n}'
  both_ways "a statement label after a brace" 1 widgetLimit 'func f() { while true { _ = widgetLimit } }' \
    'func f() { widgetLimit: while true { break widgetLimit } }'
  both_ways "a statement label after a semicolon" 1 widgetLimit 'func f() { _ = 1; while true { _ = widgetLimit } }' \
    'func f() { _ = 1; widgetLimit: while true { break widgetLimit } }'
  # A label starts a statement. After `case` it is a pattern, and in brackets
  # a dictionary key, even before an `if`.
  both_ways "a case pattern before an if" 1 widgetLimit 'switch n { case widgetLimit: if c {}; default: break }' \
    'switch n { case limit: if c {}; default: break }'
  both_ways "a dictionary key before an if" 2 widgetLimit $'let d = [\n    widgetLimit: if c { 1 } else { 2 },\n]' \
    $'let d = [\n    limit: if c { 1 } else { 2 },\n]'
  both_ways "a trailing closure's label" 1 widgetLimit 'func g() { run { } then: { widgetLimit } }' \
    'func g() { run { } widgetLimit: { } }'
  both_ways "a function type's parameter name" 1 widgetLimit \
    'typealias Handler = (_ limit: Int) -> Int; let n = widgetLimit' \
    'typealias Handler = (_ widgetLimit: Int) -> Int; let n = 0'
  both_ways "an uppercase argument label" 1 Widget 'let x = f(Widget)' 'let x = f(Widget: 1)'
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
  both_ways "an external label's internal name" 1 widgetLimit 'func f(with limit: Int) { _ = widgetLimit }' \
    'func f(with widgetLimit: Int) { _ = widgetLimit }'
  # Only a `:` directly in the parameter list follows a parameter's name; one
  # inside brackets is a dictionary's.
  both_ways "a dictionary default argument" 1 widgetLimit 'func f(a: [Int: Int] = [widgetLimit: 1]) {}' \
    'func f(a: [Int: Int] = [limit: 1]) {}'
  # `.init(...)` is a call, whose labels are no parameters.
  both_ways "a call to .init" 1 widgetLimit 'let w = Box.init(widgetLimit: 1); let n = widgetLimit' \
    'let w = Box.init(widgetLimit: 1); let n = 0'
}

test_closure_parameter_shadows() {
  both_ways "closure parameter" 1 widgetLimit 'let g = { (limit: Int) in widgetLimit }' \
    'let g = { (widgetLimit: Int) in widgetLimit }'
  both_ways "a variadic closure parameter" 1 widgetLimit 'let g = { (limits: Int...) in widgetLimit }' \
    'let g = { (widgetLimit: Int...) in widgetLimit }'
  # An `in:` argument label is not a closure's `in`: no parameters precede it.
  both_ways "an in: label" 1 widgetCount 'let g = { widgetCount(in: 1) }' 'let g = { count(in: 1) }'
}

test_for_in_shadows() {
  both_ways "for-in" 1 widgetLimit 'for x in xs { _ = widgetLimit }' 'for widgetLimit in xs { _ = widgetLimit }'
  both_ways "for-in over tuples" 1 widgetLimit 'for (i, limit) in pairs { _ = widgetLimit }' \
    'for (i, widgetLimit) in pairs { _ = widgetLimit }'
  both_ways "for try await" 1 widgetLimit 'func f(s: S) async throws { for try await x in s { _ = widgetLimit } }' \
    'func f(s: S) async throws { for try await widgetLimit in s { _ = widgetLimit } }'
}

# `let` or `var` before a pattern binds each lowercase name in it. A type that
# qualifies a case, a name after a `.` and a label inside the pattern bind
# nothing, and without a `let` or `var` a bare name in a case pattern matches
# a value: all of those are still references.
test_pattern_bindings_shadow() {
  both_ways "if case let" 1 widgetLimit 'func f(x: Int?) { if case let .some(n) = x { _ = widgetLimit } }' \
    'func f(x: Int?) { if case let .some(widgetLimit) = x { _ = widgetLimit } }'
  both_ways "guard case let, qualified" 1 widgetLimit \
    'func f(r: R) { guard case let Result.success(n) = r else { return }; _ = widgetLimit }' \
    'func f(r: R) { guard case let Result.success(widgetLimit) = r else { return }; _ = widgetLimit }'
  both_ways "for case let" 1 widgetLimit 'func f(xs: [Int?]) { for case let .some(n) in xs { _ = widgetLimit } }' \
    'func f(xs: [Int?]) { for case let .some(widgetLimit) in xs { _ = widgetLimit } }'
  both_ways "case let in a switch" 1 widgetLimit \
    'func f(e: E) { switch e { case let .pair(n, other): _ = widgetLimit; default: break } }' \
    'func f(e: E) { switch e { case let .pair(widgetLimit, other): _ = widgetLimit; default: break } }'
  both_ways "the type qualifying a case" 1 Widget 'func f(r: R) { guard case let Widget.success(n) = r else { return } }' \
    'func f(r: R) { guard case let Result.success(n) = r else { return } }'
  both_ways "a qualified case in a tuple pattern" 1 Widget \
    'func f(p: P) { switch p { case let (Widget.zero, n): _ = n; default: break } }' \
    'func f(p: P) { switch p { case let (Gadget.zero, n): _ = n; default: break } }'
  both_ways "a cast in a pattern" 1 Widget 'func f(e: E) { if case let .a(x as Widget) = e {} }' \
    'func f(e: E) { if case let .a(x as Gadget) = e {} }'
  both_ways "a label in a case pattern" 1 widgetLimit \
    'func f(e: E) { switch e { case let .pair(widgetLimit: n): _ = widgetLimit; default: break } }' \
    'func f(e: E) { switch e { case let .pair(limit: widgetLimit): _ = widgetLimit; default: break } }'
  both_ways "a value in a for case pattern" 1 widgetLimit 'func f(xs: [Int?]) { for case .some(widgetLimit) in xs {} }' \
    'func f(xs: [Int?]) { for case .some(limit) in xs {} }'
  both_ways "a case name in a pattern" 1 widgetLimit 'func f(e: E) { if case let .widgetLimit(n) = e {}; _ = widgetLimit }' \
    'func f(e: E) { if case let .widgetLimit(n) = e {}; _ = 0 }'
  both_ways "a value with a member in a pattern" 1 widgetLimit \
    'func f(p: P) { switch p { case let (widgetLimit.zero, n): _ = n; default: break } }' \
    'func f(p: P) { switch p { case let (limit.zero, n): _ = n; default: break } }'
  # A `let` inside a tuple pattern binds up to the parenthesis that closes
  # the tuple, not past it into the case's body.
  both_ways "a let inside a tuple pattern" 1 widgetLimit \
    'func f(p: P) { switch p { case (_, let .some(n)): _ = widgetLimit; default: break } }' \
    'func f(p: P) { switch p { case (_, let .some(widgetLimit)): _ = widgetLimit; default: break } }'
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
  # A `->` inside the list does not close it, so a parameter after it counts.
  both_ways "a function type in a constraint" 1 Widget \
    'struct Box<F: Handler<(Int) -> Void>, T> { let w: Widget }' \
    'struct Box<F: Handler<(Int) -> Void>, Widget> { let w: Widget }'
  # An operator's name is punctuation: the `<` in `<<` opens no list, so the
  # names after it are not parameters. `==<T>` has one.
  both_ways "an operator function" 1 Widget \
    'struct Buf { static func << (lhs: inout Buf, rhs: Int) {}; let w = (1, Widget()) }' \
    'struct Buf { static func << (lhs: inout Buf, rhs: Int) {}; let w = (1, Gadget()) }'
  both_ways "a generic operator function" 1 Widget \
    'struct Box { static func ==<T>(a: T, b: Widget) -> Bool { false } }' \
    'struct Box { static func ==<Widget>(a: Widget, b: Widget) -> Bool { false } }'
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
  layers "$d" 'Base, Mid, Top'
  run_check "$d"
  assert_rc "a declaration of the module's name is indexed" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "and the import names it" "$RUN_OUT" \
    "Sources/TBDDaemon/Top/User.swift:1: Top (layer 1) uses Mid (layer 1), its own layer: TBDShared is declared in Mid"
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
  assert_contains "and is named" "$RUN_OUT" "$(same_layer Top/User.swift:1 Gizmo)"
  put "$d" Base/More.swift $'let seed = 1\nprivate\nstruct Gizmo {}'
  run_check "$d"
  assert_rc "a private on the line above its keyword is not" 0 "$RUN_RC" "$RUN_OUT"
}

# `.private` is a member, as in a log call's `privacy: .private`, not a
# modifier: the declaration after it stays indexed.
test_private_member_is_no_modifier() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'let g = Gizmo()'
  put "$d" Base/More.swift $'let level: Privacy = .private\nstruct Gizmo {}'
  run_check "$d"
  assert_rc "a declaration after .private is indexed" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "and is named" "$RUN_OUT" "$(same_layer Top/User.swift:1 Gizmo)"
  put "$d" Base/More.swift $'let level: Privacy = .private\nprivate struct Gizmo {}'
  run_check "$d"
  assert_rc "a private one is not" 0 "$RUN_RC" "$RUN_OUT"
}

# `actor` used as a value, as in `actor as Int`, declares no type named `as`.
# Read as one, every file with a cast would link to its unit.
test_actor_as_a_value_declares_nothing() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'let y = 1 as Gizmo'
  put "$d" Base/More.swift 'actor Gizmo {}'
  run_check "$d"
  assert_rc "an actor is indexed" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "and is named" "$RUN_OUT" "$(same_layer Top/User.swift:1 Gizmo)"
  put "$d" Top/User.swift 'let y = 1 as Int'
  put "$d" Base/More.swift 'let x = actor as Int'
  run_check "$d"
  assert_rc "a cast is no reference to an actor used as a value" 0 "$RUN_RC" "$RUN_OUT"
}

# `private(set)` restricts only the setter, so the name stays indexed.
test_private_set_is_indexed() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'let n = gizmoCount'
  put "$d" Base/More.swift 'private(set) var gizmoCount = 0'
  run_check "$d"
  assert_rc "a private(set) global is indexed" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "and is named" "$RUN_OUT" "$(same_layer Top/User.swift:1 gizmoCount)"
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
  assert_contains "and is named" "$RUN_OUT" "$(same_layer Top/User.swift:1 gizmoHeight)"
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
  assert_contains "and is named" "$RUN_OUT" "$(same_layer Top/User.swift:1 baseSecret)"
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
  assert_contains "and is named" "$RUN_OUT" "$(same_layer Top/User.swift:1 gadgetName)"
}

# ---------------------------------------------------------------------------
# The layer order
# ---------------------------------------------------------------------------

# A unit may use a unit in a lower layer, and not one in a higher layer.
test_lower_layer_passes_higher_fails() {
  local d; d="$(mkfix_core)"
  put "$d" Top/User.swift 'let w = Widget()'
  layers "$d" 'Core' 'Top'
  run_check "$d"
  assert_rc "a reference into a lower layer passes" 0 "$RUN_RC" "$RUN_OUT"
  assert_contains "and says so" "$RUN_OUT" "lint-daemon-layers: OK, 2 units in 2 layers, 1 link, each into a lower layer."
  layers "$d" 'Top' 'Core'
  run_check "$d"
  assert_rc "a reference into a higher layer fails" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "and is named with both layers" "$RUN_OUT" \
    "Sources/TBDDaemon/Top/User.swift:1: Top (layer 1) uses Core (layer 2), a higher layer: Widget is declared in Core"
}

# Units in one layer may not use each other, whichever is listed first. Every
# reference case above is the other direction: Top using Base in mkfix's layer.
test_same_layer_fails() {
  local d; d="$(mkfix_core)"
  put "$d" Top/User.swift 'struct Gadget {}'
  put "$d" Core/Back.swift 'let g = Gadget()'
  run_check "$d"
  assert_rc "Core using Top in their one layer fails" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "and is named" "$RUN_OUT" \
    "Sources/TBDDaemon/Core/Back.swift:1: Core (layer 1) uses Top (layer 1), its own layer: Gadget is declared in Top"
  layers "$d" 'Top' 'Core'
  run_check "$d"
  assert_rc "with Top a layer below, it passes" 0 "$RUN_RC" "$RUN_OUT"
}

# Any lower layer will do, not only the one just below.
test_skipping_layers_passes() {
  local d; d="$(mkfix_core)"
  put "$d" Top/User.swift 'let w = Widget()'
  put "$d" Mid/Middle.swift 'struct Middle {}'
  layers "$d" 'Core' 'Mid' 'Top'
  run_check "$d"
  assert_rc "a reference two layers down passes" 0 "$RUN_RC" "$RUN_OUT"
  layers "$d" 'Top' 'Mid' 'Core'
  run_check "$d"
  assert_rc "two layers up, it fails" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "and is named" "$RUN_OUT" "Top (layer 1) uses Core (layer 3), a higher layer: Widget"
}

# Layer numbers count layer lines: a comment or a blank line is no layer.
test_layer_numbers_count_layer_lines() {
  local d; d="$(mkfix_core)"
  put "$d" Top/User.swift 'let w = Widget()'
  layers "$d" 'Top' '' '# between' 'Core'
  run_check "$d"
  assert_rc "a reference up past a comment fails" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "and names the layers by count" "$RUN_OUT" "Top (layer 1) uses Core (layer 2), a higher layer"
  layers "$d" 'Core' '' '# between' 'Top'
  run_check "$d"
  assert_rc "down past it, it passes" 0 "$RUN_RC" "$RUN_OUT"
  assert_contains "with two layers" "$RUN_OUT" "2 units in 2 layers"
}

# A file's layer is its folder's. A folder emptied of Swift is no unit any
# more, so its name leaves the layer file in the change that empties it.
test_moved_file_takes_its_folders_layer() {
  local d; d="$(mkfix_core)"
  put "$d" Top/User.swift 'let w = Widget()'
  put "$d" Low/Lowly.swift 'struct Lowly {}'
  layers "$d" 'Low' 'Core' 'Top'
  run_check "$d"
  assert_rc "before the move, it passes" 0 "$RUN_RC" "$RUN_OUT"

  mv "$d/$DAEMON_REL/Top/User.swift" "$d/$DAEMON_REL/Low/User.swift"
  run_check "$d"
  assert_rc "the emptied folder is no unit" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "and its line is named" "$RUN_OUT" \
    "lint-daemon-layers: cannot read scripts/daemon-layers.txt:4: Top is not a unit under Sources/TBDDaemon"
  layers "$d" 'Low' 'Core'
  run_check "$d"
  assert_rc "listed without it, the moved file's reference fails" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "from its new folder" "$RUN_OUT" \
    "Sources/TBDDaemon/Low/User.swift:1: Low (layer 1) uses Core (layer 2), a higher layer: Widget is declared in Core"
}

# Base stays on the bottom line, where it may use no other unit. Anywhere
# else, or on no line, the check says so and judges nothing more: every place
# it would name assumes Base at the bottom. Only a unit named Base is held.
test_base_stays_on_the_bottom_line() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'let w = Widget()'
  layers "$d" 'Base' 'Top'
  run_check "$d"
  assert_rc "Base on the bottom line passes" 0 "$RUN_RC" "$RUN_OUT"
  layers "$d" 'Top' 'Base'
  run_check "$d"
  assert_rc "Base above it fails" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "and says where Base is" "$RUN_OUT" \
    "scripts/daemon-layers.txt: Base is in layer 2; Base stays on the bottom line"
  assert_contains "and counts it" "$RUN_OUT" "lint-daemon-layers: Base is not on the bottom line."
  assert_contains "and says what to do" "$RUN_OUT" "Put Base on the first line of scripts/daemon-layers.txt"
  assert_contains "and points to the guide's Base rule" "$RUN_OUT" 'Sources/TBDDaemon/CLAUDE.md, "Base".'
  assert_lacks "and judges nothing else" "$RUN_OUT" "a higher layer"
  layers "$d" 'Top'
  run_check "$d"
  assert_rc "Base on no line fails" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "the same way" "$RUN_OUT" "scripts/daemon-layers.txt: Base has no layer; Base stays on the bottom line"
  assert_lacks "with no place suggested" "$RUN_OUT" "it fits in"

  d="$(mkfix_core)"
  put "$d" Top/User.swift 'struct Gadget {}'
  put "$d" Core/Back.swift 'let g = Gadget()'
  layers "$d" 'Top' 'Core'
  run_check "$d"
  assert_rc "a unit with another name may sit above another" 0 "$RUN_RC" "$RUN_OUT"
}

# Every unit has a layer, even one that uses nothing and that nothing uses:
# a new folder fails until a line lists it. The root files too.
test_unlisted_unit_fails() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'let n = 1'
  layers "$d" 'Base'
  run_check "$d"
  assert_rc "a unit no line lists fails" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "and is named" "$RUN_OUT" "scripts/daemon-layers.txt: Top has no layer; it fits in layer 1"
  assert_contains "and counted" "$RUN_OUT" "lint-daemon-layers: 1 unit with no layer."
  layers "$d" 'Base, Top'
  run_check "$d"
  assert_rc "listed, it passes" 0 "$RUN_RC" "$RUN_OUT"

  put "$d" Daemon.swift 'let n = 1'
  run_check "$d"
  assert_rc "root files no line lists fail" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "as (root)" "$RUN_OUT" "scripts/daemon-layers.txt: (root) has no layer"
  layers "$d" 'Base, Top, (root)'
  run_check "$d"
  assert_rc "listed, they pass" 0 "$RUN_RC" "$RUN_OUT"
}

# A unit with no layer is told where it fits: the lowest layer above every
# unit it uses and below every unit that uses it, or a new line. Listing it
# there passes. References to and from it wait until it has a layer. No new
# line goes below Base, which stays on the bottom line.
test_unlisted_unit_says_where_it_fits() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'struct Gadget {}'
  layers "$d" 'Base' 'Top'

  put "$d" Mid/Middle.swift 'let w = Widget()'
  run_check "$d"
  assert_contains "a unit using layer 1 fits in layer 2" "$RUN_OUT" "Mid has no layer; it fits in layer 2"
  assert_lacks "and its reference waits for its layer" "$RUN_OUT" "uses Base"
  layers "$d" 'Base' 'Top, Mid'
  run_check "$d"
  assert_rc "listed there, it passes" 0 "$RUN_RC" "$RUN_OUT"

  layers "$d" 'Base' 'Top'
  put "$d" Top/User.swift $'struct Gadget {}\nlet m = Middle()'
  put "$d" Mid/Middle.swift $'struct Middle {}\nlet w = Widget()'
  run_check "$d"
  assert_contains "one between two layers needs a new line" "$RUN_OUT" \
    "Mid has no layer; it needs a new line between layers 1 and 2"
  layers "$d" 'Base' 'Mid' 'Top'
  run_check "$d"
  assert_rc "listed there, it passes" 0 "$RUN_RC" "$RUN_OUT"

  layers "$d" 'Base' 'Top'
  put "$d" Top/User.swift 'struct Gadget {}'
  put "$d" Mid/Middle.swift 'let g = Gadget()'
  run_check "$d"
  assert_contains "one using the top layer needs a new line at the top" "$RUN_OUT" \
    "Mid has no layer; it needs a new line at the top"
  layers "$d" 'Base' 'Top' 'Mid'
  run_check "$d"
  assert_rc "listed there, it passes" 0 "$RUN_RC" "$RUN_OUT"

  layers "$d" 'Base, Top'
  put "$d" Mid/Middle.swift 'struct Middle {}'
  put "$d" Top/User.swift $'struct Gadget {}\nlet m = Middle()'
  run_check "$d"
  assert_contains "one the bottom layer uses fits nowhere, since no line goes below Base" "$RUN_OUT" \
    "Mid has no layer; no layer fits it: layer 1 uses it, and Base stays on the bottom line"
  layers "$d" 'Base, Mid' 'Top'
  run_check "$d"
  assert_rc "with its user moved up, it passes beside Base" 0 "$RUN_RC" "$RUN_OUT"

  layers "$d" 'Base' 'Top'
  put "$d" Mid/Middle.swift $'struct Middle {}\nlet g = Gadget()'
  run_check "$d"
  assert_rc "one that a layer uses and that uses it" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "fits nowhere" "$RUN_OUT" "Mid has no layer; no layer fits it: it uses layer 2, and layer 2 uses it"
  assert_lacks "and names no unit the use runs through" "$RUN_OUT" "uses it through"

  d="$(mkfix_core)"
  put "$d" Top/User.swift 'struct Gadget {}'
  put "$d" Mid/Middle.swift 'struct Middle {}'
  put "$d" Core/Back.swift 'let m = Middle()'
  layers "$d" 'Core' 'Top'
  run_check "$d"
  assert_contains "with no Base, one the bottom layer uses needs a new line at the bottom" "$RUN_OUT" \
    "Mid has no layer; it needs a new line at the bottom"
  layers "$d" 'Mid' 'Core' 'Top'
  run_check "$d"
  assert_rc "listed there, it passes" 0 "$RUN_RC" "$RUN_OUT"
}

# Units with no layer are placed together, each above every unit it uses and
# below every unit that uses it, listed or not. Placed apart, two where one
# uses the other would each fit in layer 1, where that use fails.
test_new_units_are_placed_together() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'struct Gadget {}'
  put "$d" Low/Lowly.swift 'struct Lowly {}'
  put "$d" Mid/Middle.swift 'struct Middle {}'
  layers "$d" 'Base' 'Top'
  run_check "$d"
  assert_contains "apart, one fits in layer 1" "$RUN_OUT" "Low has no layer; it fits in layer 1"
  assert_contains "and so does the other" "$RUN_OUT" "Mid has no layer; it fits in layer 1"

  put "$d" Mid/Middle.swift $'struct Middle {}\nlet l = Lowly()'
  run_check "$d"
  assert_rc "one using the other" 1 "$RUN_RC" "$RUN_OUT"
  assert_lacks "never stops on a traceback" "$RUN_OUT" "Traceback"
  assert_contains "the one used fits in layer 1" "$RUN_OUT" "Low has no layer; it fits in layer 1"
  assert_contains "and the one using it in layer 2" "$RUN_OUT" "Mid has no layer; it fits in layer 2"
  layers "$d" 'Base, Low' 'Top, Mid'
  run_check "$d"
  assert_rc "listed there, they pass" 0 "$RUN_RC" "$RUN_OUT"
  layers "$d" 'Base, Low, Mid' 'Top'
  run_check "$d"
  assert_rc "listed both in layer 1, they fail" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "on that use" "$RUN_OUT" "Mid (layer 1) uses Low (layer 1), its own layer: Lowly is declared in Low"

  # Between two layers, each takes a new line, and the user's goes above the
  # lines of the units it uses.
  layers "$d" 'Base' 'Top'
  put "$d" Top/User.swift $'struct Gadget {}\nlet m = Middle()'
  put "$d" Low/Lowly.swift $'struct Lowly {}\nlet w = Widget()'
  put "$d" Lone/Lonely.swift $'struct Lonely {}\nlet w = Widget()'
  put "$d" Mid/Middle.swift $'struct Middle {}\nlet l = Lowly()\nlet o = Lonely()'
  run_check "$d"
  assert_lacks "never stops on a traceback" "$RUN_OUT" "Traceback"
  assert_contains "one used needs a new line between the two layers" "$RUN_OUT" \
    "Low has no layer; it needs a new line between layers 1 and 2"
  assert_contains "and so does the other" "$RUN_OUT" "Lone has no layer; it needs a new line between layers 1 and 2"
  assert_contains "and the user one above theirs" "$RUN_OUT" \
    "Mid has no layer; it needs a new line between layers 1 and 2, above the lines for Lone and Low"
  layers "$d" 'Base' 'Lone, Low' 'Mid' 'Top'
  run_check "$d"
  assert_rc "listed there, they pass" 0 "$RUN_RC" "$RUN_OUT"
  put "$d" Mid/Middle.swift $'struct Middle {}\nlet l = Lowly()'
  layers "$d" 'Base' 'Top'
  run_check "$d"
  assert_contains "using one, the user goes above its line" "$RUN_OUT" \
    "Mid has no layer; it needs a new line between layers 1 and 2, above the line for Low"
  assert_contains "and the other, used by none, fits in layer 2" "$RUN_OUT" "Lone has no layer; it fits in layer 2"
  layers "$d" 'Base' 'Low' 'Mid' 'Top, Lone'
  run_check "$d"
  assert_rc "listed there, they pass" 0 "$RUN_RC" "$RUN_OUT"
}

# When no layer fits a unit with no layer, the message says why: a use that
# runs through another unit with no layer, or a circle of them. A unit that
# uses one no layer fits, or is near a circle, waits for it.
test_new_units_no_layer_fits() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift $'struct Gadget {}\nlet m = Middle()'
  put "$d" Mid/Middle.swift $'struct Middle {}\nlet l = Lowly()'
  put "$d" Low/Lowly.swift $'struct Lowly {}\nlet g = Gadget()'
  put "$d" Hub/Hub.swift 'let m = Middle()'
  layers "$d" 'Base' 'Top'
  run_check "$d"
  assert_rc "a use up through a unit with no layer" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named with the unit it runs through" "$RUN_OUT" \
    "Low has no layer; no layer fits it: it uses layer 2, and layer 2 uses it through Mid"
  assert_contains "and the unit using it waits" "$RUN_OUT" "Mid has no layer; no layer fits it until one fits Low"
  assert_contains "as does one further up, for the same unit" "$RUN_OUT" "Hub has no layer; no layer fits it until one fits Low"
  put "$d" Low/Lowly.swift 'struct Lowly {}'
  run_check "$d"
  assert_contains "without that use, one fits in layer 1" "$RUN_OUT" "Low has no layer; it fits in layer 1"
  assert_contains "the next between it and its user" "$RUN_OUT" \
    "Mid has no layer; it needs a new line between layers 1 and 2"
  assert_lacks "above no new line, since the unit it uses sits in layer 1" "$RUN_OUT" "above the line for Low"
  assert_contains "and the last above both" "$RUN_OUT" "Hub has no layer; it fits in layer 2"
  layers "$d" 'Base, Low' 'Mid' 'Top, Hub'
  run_check "$d"
  assert_rc "listed there, they pass" 0 "$RUN_RC" "$RUN_OUT"

  put "$d" Top/User.swift 'struct Gadget {}'
  put "$d" Low/Lowly.swift $'struct Lowly {}\nlet m = Middle()'
  put "$d" Mid/Middle.swift $'struct Middle {}\nlet l = Lowly()\nlet f = Leaf()'
  put "$d" Leaf/Leaf.swift 'struct Leaf {}'
  put "$d" Hub/Hub.swift 'let m = Middle()'
  layers "$d" 'Base' 'Top'
  run_check "$d"
  assert_rc "units with no layer that use each other" 1 "$RUN_RC" "$RUN_OUT"
  assert_lacks "never stop on a traceback" "$RUN_OUT" "Traceback"
  assert_contains "run in a circle" "$RUN_OUT" "Low has no layer; no layer fits it: its links run in a circle, Low -> Mid -> Low"
  assert_contains "named from each" "$RUN_OUT" "Mid has no layer; no layer fits it: its links run in a circle, Mid -> Low -> Mid"
  assert_contains "a unit using the circle waits" "$RUN_OUT" "Hub has no layer; no layer fits it until one fits Low"
  assert_contains "and so does one it uses" "$RUN_OUT" "Leaf has no layer; no layer fits it until one fits Low"
  put "$d" Low/Lowly.swift 'struct Lowly {}'
  run_check "$d"
  assert_lacks "with the circle broken, all fit" "$RUN_OUT" "no layer fits it"
  assert_contains "and the unit that uses the rest goes above them" "$RUN_OUT" \
    "Hub has no layer; it needs a new line at the top"
  layers "$d" 'Base, Leaf, Low' 'Top, Mid' 'Hub'
  run_check "$d"
  assert_rc "listed where they fit, they pass" 0 "$RUN_RC" "$RUN_OUT"
}

# A name that is no unit is a typo, or a folder renamed or emptied: the check
# cannot tell which layer was meant, so it stops at the line.
test_unknown_unit_cannot_check() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'let n = 1'
  layers "$d" 'Base' 'Tpo'
  run_check "$d"
  assert_rc "a misspelled unit" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named at its line" "$RUN_OUT" \
    "lint-daemon-layers: cannot read scripts/daemon-layers.txt:3: Tpo is not a unit under Sources/TBDDaemon"
  layers "$d" 'Base' 'Top'
  run_check "$d"
  assert_rc "spelled right, it passes" 0 "$RUN_RC" "$RUN_OUT"
}

# A unit listed twice has two layers. The message names both lines.
test_duplicate_unit_cannot_check() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'let w = Widget()'
  layers "$d" 'Base' 'Top' 'Base'
  run_check "$d"
  assert_rc "a unit on two lines" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named at the second" "$RUN_OUT" \
    "lint-daemon-layers: cannot read scripts/daemon-layers.txt:4: Base is listed twice: line 2 lists it too"
  layers "$d" 'Base, Base' 'Top'
  run_check "$d"
  assert_rc "a unit twice on one line" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named" "$RUN_OUT" "scripts/daemon-layers.txt:2: Base is listed twice: line 2 lists it too"
  layers "$d" 'Base' 'Top'
  run_check "$d"
  assert_rc "listed once, it passes" 0 "$RUN_RC" "$RUN_OUT"
}

# Units on a line are separated by commas. An empty name is a stray comma, and
# a name with a space in it a missing one.
test_layer_line_format() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'let w = Widget()'
  put "$d" Mid/Middle.swift 'struct Middle {}'
  layers "$d" 'Base,' 'Top, Mid'
  run_check "$d"
  assert_rc "a stray comma" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named" "$RUN_OUT" \
    'lint-daemon-layers: cannot read scripts/daemon-layers.txt:2: "Base," has an empty name: a comma with no unit beside it'
  printf '# fixture\r\n  Base, \r\nTop, Mid\r\n' > "$d/scripts/daemon-layers.txt"
  run_check "$d"
  assert_rc "a stray comma before spaces and a CRLF ending" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named with the line trimmed" "$RUN_OUT" \
    'lint-daemon-layers: cannot read scripts/daemon-layers.txt:2: "Base," has an empty name: a comma with no unit beside it'
  layers "$d" 'Base' 'Top Mid'
  run_check "$d"
  assert_rc "a missing comma" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named" "$RUN_OUT" \
    'lint-daemon-layers: cannot read scripts/daemon-layers.txt:3: "Top Mid": a unit name has no spaces in it; separate units with commas'
  layers "$d" 'Base' 'Top,Mid'
  run_check "$d"
  assert_rc "commas with no spaces pass" 0 "$RUN_RC" "$RUN_OUT"
  assert_contains "and read as one layer" "$RUN_OUT" "3 units in 2 layers"
}

# Whitespace around a line or a name, CRLF endings and a missing final newline
# read the same as a clean file. A comment may be indented.
test_layer_file_whitespace_is_tolerated() {
  local d; d="$(mkfix_core)"
  put "$d" Top/User.swift 'let w = Widget()'
  put "$d" Mid/Middle.swift 'struct Middle {}'
  printf '# fixture\r\n\r\n  Core \r\n\tTop ,  Mid  \r\n' > "$d/scripts/daemon-layers.txt"
  run_check "$d"
  assert_rc "CRLF endings and stray spaces are tolerated" 0 "$RUN_RC" "$RUN_OUT"
  printf '# fixture\r\n\r\nCore\r\n Top , Mid ' > "$d/scripts/daemon-layers.txt"
  run_check "$d"
  assert_rc "so is a missing final newline" 0 "$RUN_RC" "$RUN_OUT"
  printf '# fixture\n  # Top, Mid\n\t# a comment after a tab\nCore\nTop, Mid\n' > "$d/scripts/daemon-layers.txt"
  run_check "$d"
  assert_rc "an indented comment is no layer" 0 "$RUN_RC" "$RUN_OUT"
  assert_contains "and is not counted" "$RUN_OUT" "3 units in 2 layers"
  printf '# fixture\r\n\r\n\tTop ,  Mid  \r\n  Core \r\n' > "$d/scripts/daemon-layers.txt"
  run_check "$d"
  assert_rc "and such lines still order the layers" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "as written" "$RUN_OUT" "Top (layer 1) uses Core (layer 2), a higher layer"
}

# The layer file is UTF-8 like the Swift: a byte that is not stops the check at
# its line. A byte order mark is not text, in the layer file or a Swift file.
test_layer_file_encoding() {
  local d bom; d="$(mkfix)"; bom="$(printf '\357\273\277')"
  put "$d" Top/User.swift 'let n = 1'
  printf '# fixture\nBase, Top\n\351\n' > "$d/scripts/daemon-layers.txt"
  run_check "$d"
  assert_rc "a byte that is not UTF-8" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named" "$RUN_OUT" "lint-daemon-layers: cannot read scripts/daemon-layers.txt:3: not valid UTF-8"
  printf '\357\273\277Base, Top\n' > "$d/scripts/daemon-layers.txt"
  run_check "$d"
  assert_rc "a byte order mark before the first unit passes" 0 "$RUN_RC" "$RUN_OUT"
  both_ways "a Swift file that starts with a byte order mark" 1 Widget \
    "${bom}Widget.pattern.firstMatch(in: s)" "${bom}/Widget/.firstMatch(in: s)"
}

test_missing_layer_file_cannot_check() {
  local d empty; d="$(mkfix)"
  put "$d" Top/User.swift 'let n = 1'
  mv "$d/scripts/daemon-layers.txt" "$d/scripts/kept.txt"
  run_check "$d"
  assert_rc "a missing layer file" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named" "$RUN_OUT" "lint-daemon-layers: cannot read scripts/daemon-layers.txt: not found"
  mv "$d/scripts/kept.txt" "$d/scripts/daemon-layers.txt"
  run_check "$d"
  assert_rc "back in place, it passes" 0 "$RUN_RC" "$RUN_OUT"

  empty="$(mktemp -d "$WORK/empty.XXXXXX")"
  run_check "$empty"
  assert_rc "a root with no Sources/TBDDaemon" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named" "$RUN_OUT" "lint-daemon-layers: cannot scan Sources/TBDDaemon: not found"
}

# A folder the layer file could not name stops the scan: a line separates its
# names with commas and trims the spaces around them, and a line that starts
# with `#` is a comment.
test_folder_the_layer_file_cannot_name() {
  local d folder reason; d="$(mkfix)"
  put "$d" Top/User.swift 'let w = Widget()'
  layers "$d" 'Base' 'Top'
  run_check "$d"
  assert_rc "a folder the layer file can name passes" 0 "$RUN_RC" "$RUN_OUT"
  while IFS='|' read -r folder reason; do
    mv "$d/$DAEMON_REL/Top" "$d/$DAEMON_REL/$folder"
    run_check "$d"
    mv "$d/$DAEMON_REL/$folder" "$d/$DAEMON_REL/Top"
    assert_rc "a folder that $reason" 2 "$RUN_RC" "$RUN_OUT"
    assert_contains "is named" "$RUN_OUT" \
      "lint-daemon-layers: cannot scan Sources/TBDDaemon/$folder/User.swift: the folder \"$folder\" $reason, so the layer file cannot name it"
  done <<'EOF'
Top Level|has a space in its name
Top,Level|has a comma in its name
#Top|starts with "#"
EOF
  run_check "$d"
  assert_rc "renamed back, it passes" 0 "$RUN_RC" "$RUN_OUT"
}

# A file or folder the check cannot open stops it with exit 2 and the path,
# never a traceback: skipping it would drop its references.
test_unreadable_cannot_check() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift 'let w = Widget()'
  layers "$d" 'Base' 'Top'
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

  chmod 000 "$d/scripts/daemon-layers.txt"
  run_check "$d"
  chmod 644 "$d/scripts/daemon-layers.txt"
  assert_rc "an unreadable layer file" 2 "$RUN_RC" "$RUN_OUT"
  assert_contains "is named" "$RUN_OUT" "lint-daemon-layers: cannot read scripts/daemon-layers.txt: Permission denied"

  run_check "$d"
  assert_rc "readable again, the check passes" 0 "$RUN_RC" "$RUN_OUT"
}

# The footer counts the failures and says how to fix each kind present, and
# only those.
test_failure_footer() {
  local d; d="$(mkfix)"
  put "$d" Top/User.swift $'let w = Widget()\nlet n = widgetCount()'
  run_check "$d"
  assert_rc "two references against the order" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "are counted, with their one link" "$RUN_OUT" \
    "lint-daemon-layers: 2 references against the layer order, in 1 link."
  assert_contains "the footer says to move the declaration" "$RUN_OUT" \
    "Move the declaration into the unit that uses it, or into a lower unit both can use."
  assert_contains "or pass a closure or a protocol in" "$RUN_OUT" \
    "Pass a closure or a protocol in from the unit above, so the lower unit stops naming the higher one."
  assert_contains "or move the using unit up" "$RUN_OUT" \
    "move the using unit up, to a line above the unit it uses, in scripts/daemon-layers.txt in this change"
  assert_contains "and how to repair main when the reference is not this change's" "$RUN_OUT" \
    "If this change makes none of these references, main already fails"
  assert_lacks "it says nothing of units with no layer" "$RUN_OUT" "Every unit has a layer"
  assert_contains "and points to the guide" "$RUN_OUT" 'Sources/TBDDaemon/CLAUDE.md, "Folder layers"'

  put "$d" Mid/Middle.swift 'struct Middle {}'
  run_check "$d"
  assert_contains "both kinds are counted" "$RUN_OUT" \
    "lint-daemon-layers: 2 references against the layer order, in 1 link; 1 unit with no layer."

  layers "$d" 'Base' 'Top'
  run_check "$d"
  assert_rc "a unit with no layer alone" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "is counted" "$RUN_OUT" "lint-daemon-layers: 1 unit with no layer."
  assert_contains "the footer says to add it where it fits" "$RUN_OUT" \
    "Every unit has a layer. Add each unit above to scripts/daemon-layers.txt in this change: in the layer it fits in, or on the new line it needs."
  assert_contains "and what to do where none fits" "$RUN_OUT" \
    "Where no layer fits a unit, change a reference, or move the units involved to other lines so that every use points down."
  assert_lacks "it says nothing of references" "$RUN_OUT" "Move the declaration"
  assert_contains "and points to the guide" "$RUN_OUT" 'Sources/TBDDaemon/CLAUDE.md, "Folder layers"'
}

# ---------------------------------------------------------------------------
# Units
# ---------------------------------------------------------------------------

test_root_files_are_one_unit() {
  local d; d="$(mkfix)"
  put "$d" Daemon.swift 'let p = PIDFile()'
  put "$d" PIDFile.swift 'struct PIDFile {}'
  layers "$d" 'Base, (root)'
  run_check "$d"
  assert_rc "root files referencing each other make no link" 0 "$RUN_RC" "$RUN_OUT"

  put "$d" Daemon.swift 'let w = Widget()'
  run_check "$d"
  assert_rc "a root file referencing Base" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "is a reference from (root)" "$RUN_OUT" \
    "Sources/TBDDaemon/Daemon.swift:1: (root) (layer 1) uses Base (layer 1), its own layer: Widget is declared in Base"

  put "$d" Daemon.swift 'let p = PIDFile()'
  put "$d" Base/Uses.swift 'let p = PIDFile()'
  run_check "$d"
  assert_rc "Base referencing a root file" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "is a reference to (root)" "$RUN_OUT" \
    "Base (layer 1) uses (root) (layer 1), its own layer: PIDFile is declared in (root)"
}

test_main_swift_is_skipped() {
  local d; d="$(mkfix)"
  put "$d" main.swift 'let w = Widget()'
  layers "$d" 'Base'
  run_check "$d"
  assert_rc "main.swift's references are not read" 0 "$RUN_RC" "$RUN_OUT"
  rm "$d/$DAEMON_REL/main.swift"
  put "$d" Launch.swift 'let w = Widget()'
  layers "$d" 'Base, (root)'
  run_check "$d"
  assert_rc "the same line in another root file" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "is a reference from (root)" "$RUN_OUT" "(root) (layer 1) uses Base (layer 1), its own layer: Widget"

  d="$(mkfix)"
  put "$d" main.swift 'struct Entry {}'
  put "$d" Top/User.swift 'let e = Entry()'
  run_check "$d"
  assert_rc "main.swift's declarations are not indexed" 0 "$RUN_RC" "$RUN_OUT"
  rm "$d/$DAEMON_REL/main.swift"
  put "$d" Launch.swift 'struct Entry {}'
  layers "$d" 'Base, Top, (root)'
  run_check "$d"
  assert_rc "the same declaration in another root file" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "is a reference to (root)" "$RUN_OUT" "Top (layer 1) uses (root) (layer 1), its own layer: Entry"
}

test_nested_folders_fold_into_top_folder() {
  local d; d="$(mkfix)"
  put "$d" Top/Deep/Nested.swift 'let w = Widget()'
  run_check "$d"
  assert_rc "a subfolder's reference" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "belongs to its top folder" "$RUN_OUT" "$(same_layer Top/Deep/Nested.swift:1 Widget)"

  d="$(mkfix)"
  put "$d" Base/Inner/More.swift 'let w = Widget()'
  layers "$d" 'Base'
  run_check "$d"
  assert_rc "a subfolder referencing its own top folder makes no link" 0 "$RUN_RC" "$RUN_OUT"
}

# A folder that holds no Swift is no unit, so it needs no layer.
test_non_swift_files_are_ignored() {
  local d; d="$(mkfix)"
  put "$d" Top/Migrations/20260101000000_x.sql 'Widget()'
  put "$d" Top/CLAUDE.md 'Widget'
  layers "$d" 'Base'
  run_check "$d"
  assert_rc "SQL and Markdown files are not read" 0 "$RUN_RC" "$RUN_OUT"
  put "$d" Top/Migrations/X.swift 'Widget()'
  layers "$d" 'Base, Top'
  run_check "$d"
  assert_rc "the same content in a Swift file" 1 "$RUN_RC" "$RUN_OUT"
  assert_contains "is a reference" "$RUN_OUT" "$(same_layer Top/Migrations/X.swift:1 Widget)"
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
