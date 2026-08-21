//// Natural-language rendering of a failure.
////
//// A failed assertion is a sentence: what the test expected, and what it
//// got instead. The compiler's assert payload carries the operands and the
//// operator, so vouch can say that in words rather than dumping the raw
//// fields — `Expected: 5 / But was: 4` in the shape NUnit, xUnit and Jest
//// have trained everyone to read.
////
//// Where the payload alone is too abstract to read — a pattern that did
//// not match, a predicate that returned False — the byte offsets it
//// carries are used to quote the source back (see `source`), so the report
//// names the code rather than describing it. Every such lookup can fail,
//// and every one has wording that works without it.
////
//// Shared by every reporter, so the console, TeamCity details and JUnit
//// failure bodies all say the same thing.

import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import vouch/internal/gleam_panic.{type AssertedExpression, type GleamPanic}
import vouch/internal/outcome.{type CrashSite, type FailureDetail}
import vouch/internal/source

/// The body of a failure report: one entry per line, unindented.
pub fn failure(detail: FailureDetail) -> List(String) {
  case detail {
    outcome.PanicDetail(p) ->
      case panic_detail(p) {
        // A bare `panic` has no operands to take apart; its message is the
        // whole story.
        [] -> [p.message]
        lines -> lines
      }
    outcome.TimeoutDetail(ms) -> [
      "Timed out after " <> int.to_string(ms) <> "ms",
    ]
    outcome.UnknownDetail(raw, site) -> [
      "Crashed: " <> crash(raw, site),
      ..at_line(site)
    ]
    outcome.ExitDetail(raw, site) -> [
      "Test process died: " <> crash(raw, site),
      ..at_line(site)
    ]
  }
}

/// The reason with its call site: `Undef calling filepath:split/1`. The
/// shared summary every reporter embeds after its own prefix; without a
/// site — every JavaScript crash — it is the reason alone.
pub fn crash(raw: Dynamic, site: Option(CrashSite)) -> String {
  let reason = string.inspect(raw)
  case site {
    option.None -> reason
    option.Some(s) ->
      reason
      <> " calling "
      <> s.module
      <> ":"
      <> s.function
      <> "/"
      <> int.to_string(s.arity)
  }
}

/// Where the crashing frame lives, when the BEAM recorded it — an undef
/// frame never does, the called function not existing anywhere.
fn at_line(site: Option(CrashSite)) -> List(String) {
  case site {
    option.Some(outcome.CrashSite(location: option.Some(#(file, line)), ..)) ->
      ["  at " <> file <> ":" <> int.to_string(line)]
    _ -> []
  }
}

/// Where the failure happened, as a clickable `file:line`. Paths are
/// normalised to forward slashes so terminals and editors link them on
/// Windows too.
pub fn location(p: GleamPanic) -> String {
  string.replace(p.file, "\\", "/") <> ":" <> int.to_string(p.line)
}

/// The expected/actual lines for a panic that carries operands. Empty for
/// `panic` and `todo`, which carry only a message.
pub fn panic_detail(p: GleamPanic) -> List(String) {
  case p.kind {
    // Operands say everything a comparison has to say, so this case is
    // matched ahead of the one below that reads the source back.
    gleam_panic.Assert(
      kind: gleam_panic.BinaryOperator(operator: op, left: l, right: r),
      ..,
    ) -> binary_detail(op, l, r)
    gleam_panic.Assert(start:, end:, expression_start:, kind:) ->
      assert_detail(
        quoting(p.file, start, end, "assert"),
        expression_start,
        end,
        kind,
      )
    gleam_panic.LetAssert(start:, end:, pattern_start:, pattern_end:, value:) -> {
      let src = quoting(p.file, start, end, "let assert")
      let want = case quote(src, pattern_start, pattern_end) {
        Ok(pattern) -> "a value matching " <> pattern
        Error(Nil) -> "the pattern to match"
      }
      [expected(want), but_was(string.inspect(value))]
    }
    _ -> []
  }
}

fn assert_detail(
  src: Source,
  expression_start: Int,
  end: Int,
  kind: gleam_panic.AssertKind,
) -> List(String) {
  case kind {
    // Handled by the caller, which matches it before reading any source.
    gleam_panic.BinaryOperator(operator: op, left: l, right: r) ->
      binary_detail(op, l, r)
    // A predicate call panics only by returning False, so "it was False" is
    // no news. What the call *was*, and the values behind its arguments,
    // are.
    gleam_panic.FunctionCall(arguments: args) -> [
      expected(to_be_true(src, expression_start, end)),
      but_was("False"),
      ..arguments(src, args)
    ]
    gleam_panic.OtherExpression(expression: e) -> [
      expected(to_be_true(src, e.start, e.end)),
      but_was("False"),
    ]
  }
}

/// `is_even(n) to be True` when the expression can be quoted, plain `True`
/// when it cannot.
fn to_be_true(src: Source, start: Int, end: Int) -> String {
  case quote(src, start, end) {
    Ok(expression) -> expression <> " to be True"
    Error(Nil) -> "True"
  }
}

fn binary_detail(
  op: String,
  l: AssertedExpression,
  r: AssertedExpression,
) -> List(String) {
  let left = gleam_panic.describe_expression(l)
  let right = gleam_panic.describe_expression(r)
  case op {
    "==" -> {
      let #(actual, want) = orient(l, r)
      [expected(want), but_was(actual)]
    }
    "!=" -> {
      let #(actual, want) = orient(l, r)
      [expected("anything except " <> want), but_was(actual)]
    }
    "<" | "<." -> [expected("less than " <> right), but_was(left)]
    "<=" | "<=." -> [
      expected("less than or equal to " <> right),
      but_was(left),
    ]
    ">" | ">." -> [expected("greater than " <> right), but_was(left)]
    ">=" | ">=." -> [
      expected("greater than or equal to " <> right),
      but_was(left),
    ]
    // Both sides are shown for the boolean operators: which one was False
    // is the answer, and `(not evaluated)` shows where it short-circuited.
    "&&" -> [expected("both sides True"), but_was(left <> " && " <> right)]
    "||" -> [
      expected("at least one side True"),
      but_was(left <> " || " <> right),
    ]
    _ -> [
      expected(left <> " " <> op <> " " <> right <> " to hold"),
      but_was("False"),
    ]
  }
}

/// Which operand is the expectation, for the symmetric operators, as
/// `#(actual, expected)`. Tests are written `assert actual == expected` far
/// more often than the reverse, so the left operand is the actual value —
/// unless the left is a literal and the right is not, which can only be the
/// reverse shape: a literal is what a test expects, never what it computed.
/// Public so reporters with their own expected/actual fields (TeamCity's
/// comparisonFailure) orient identically to the console.
pub fn orient(
  l: AssertedExpression,
  r: AssertedExpression,
) -> #(String, String) {
  let left = gleam_panic.describe_expression(l)
  let right = gleam_panic.describe_expression(r)
  case l.kind, r.kind {
    gleam_panic.Literal(_), gleam_panic.Expression(_) -> #(right, left)
    _, _ -> #(left, right)
  }
}

/// One line per argument, naming it the way the call site did: `n = 3`.
/// An argument written out literally is dropped — `3 = 3` says nothing that
/// the quoted call above it did not already say.
fn arguments(src: Source, args: List(AssertedExpression)) -> List(String) {
  args
  |> list.index_map(fn(a, i) {
    let value = gleam_panic.describe_expression(a)
    let label =
      quote(src, a.start, a.end)
      |> result.unwrap("argument " <> int.to_string(i + 1))
    case label == value {
      True -> ""
      False -> "  " <> label <> " = " <> value
    }
  })
  |> list.filter(fn(line) { line != "" })
}

/// The failing statement's own text, read back once and then sliced for
/// each span quoted out of it, alongside the offset it starts at so the
/// payload's file-wide offsets can be rebased onto it.
type Source {
  Quotable(text: String, offset: Int)
  Unavailable
}

fn quoting(file: String, start: Int, end: Int, keyword: String) -> Source {
  case source.statement(file, start, end, keyword) {
    Ok(text) -> Quotable(text, start)
    Error(Nil) -> Unavailable
  }
}

/// A span of the failing statement, as a single line short enough to sit
/// inside a sentence. Source spans can be wrapped across lines or arbitrarily
/// long; a report that inherits either stops being scannable.
fn quote(src: Source, start: Int, end: Int) -> Result(String, Nil) {
  case src {
    Unavailable -> Error(Nil)
    Quotable(text, offset) ->
      source.byte_slice(text, start - offset, end - offset)
      |> result.map(one_line)
      |> result.map(ellipsise(_, 64))
  }
}

fn one_line(text: String) -> String {
  text
  |> string.replace("\r\n", " ")
  |> string.replace("\n", " ")
  |> string.replace("\t", " ")
  |> string.split(" ")
  |> list.filter(fn(word) { word != "" })
  |> string.join(" ")
}

fn ellipsise(text: String, limit: Int) -> String {
  case string.length(text) > limit {
    True -> string.slice(text, 0, limit - 1) <> "…"
    False -> text
  }
}

fn expected(what: String) -> String {
  "Expected: " <> what
}

fn but_was(what: String) -> String {
  "But was:  " <> what
}
