//// JUnit XML reporter, targeting the de-facto Ant/Surefire schema that CI
//// systems consume. Buffers results and writes the file at RunEnd. Runs
//// alongside the console or JSONL reporter, so it prints nothing on
//// success; write failures go to stderr.
////
//// Outcome mapping: Todo maps to <failure type="todo"> (consistent with the
//// non-zero exit code — CI must not render green while the build fails);
//// Skipped maps to <skipped>.

import gleam/int
import gleam/io
import gleam/list
import gleam/string
import vouch/internal/describe
import vouch/internal/event.{type Event}
import vouch/internal/gleam_panic.{type GleamPanic}
import vouch/internal/outcome.{type TestOutcome}
import vouch/internal/reporter.{type Reporter, Reporter}

type Case =
  #(String, String, TestOutcome, Int)

pub fn reporter(path: String) -> Reporter(List(Case)) {
  Reporter(init: [], handle: fn(state, e) { handle(path, state, e) })
}

fn handle(path: String, state: List(Case), e: Event) -> List(Case) {
  case e {
    event.TestResult(module, function, out, duration) -> [
      #(module, function, out, duration),
      ..state
    ]
    event.RunEnd(_, duration) -> {
      case write_file(path, render(list.reverse(state), duration)) {
        Ok(Nil) -> Nil
        Error(reason) ->
          io.println_error(
            "vouch: could not write JUnit report to " <> path <> ": " <> reason,
          )
      }
      state
    }
    _ -> state
  }
}

pub fn render(results: List(Case), duration_us: Int) -> String {
  let modules = list.unique(list.map(results, fn(r) { r.0 }))
  let suites =
    list.map(modules, fn(module) {
      suite(module, list.filter(results, fn(r) { r.0 == module }))
    })
  let #(failures, skips) = counts(results)
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
  <> "<testsuites tests=\""
  <> int.to_string(list.length(results))
  <> "\" failures=\""
  <> int.to_string(failures)
  <> "\" skipped=\""
  <> int.to_string(skips)
  <> "\" time=\""
  <> seconds(duration_us)
  <> "\">\n"
  <> string.concat(suites)
  <> "</testsuites>\n"
}

fn suite(module: String, results: List(Case)) -> String {
  let #(failures, skips) = counts(results)
  let total_us = list.fold(results, 0, fn(acc, r) { acc + r.3 })
  "  <testsuite name=\""
  <> escape(module)
  <> "\" tests=\""
  <> int.to_string(list.length(results))
  <> "\" failures=\""
  <> int.to_string(failures)
  <> "\" skipped=\""
  <> int.to_string(skips)
  <> "\" time=\""
  <> seconds(total_us)
  <> "\">\n"
  <> string.concat(list.map(results, test_case))
  <> "  </testsuite>\n"
}

fn test_case(r: Case) -> String {
  let #(module, function, out, duration) = r
  let open =
    "    <testcase name=\""
    <> escape(function)
    <> "\" classname=\""
    <> escape(module)
    <> "\" time=\""
    <> seconds(duration)
    <> "\""
  case out {
    outcome.Pass -> open <> "/>\n"
    outcome.Skipped(p) ->
      open
      <> ">\n      <skipped message=\""
      <> escape(p.message)
      <> "\"/>\n    </testcase>\n"
    outcome.Todo(p) ->
      open
      <> ">\n      <failure type=\"todo\" message=\""
      <> escape("todo at " <> site(p))
      <> "\">"
      <> escape(p.message)
      <> "</failure>\n    </testcase>\n"
    outcome.Failed(outcome.PanicDetail(p)) ->
      open
      <> ">\n      <failure type=\""
      <> kind_name(p)
      <> "\" message=\""
      <> escape(p.message)
      <> "\">"
      <> escape(string.join(
        [describe.location(p), ..describe.panic_detail(p)],
        "\n",
      ))
      <> "</failure>\n    </testcase>\n"
    outcome.Failed(outcome.UnknownDetail(raw)) ->
      open
      <> ">\n      <failure type=\"unknown\" message=\""
      <> escape(string.inspect(raw))
      <> "\"/>\n    </testcase>\n"
    outcome.Failed(outcome.TimeoutDetail(ms)) ->
      open
      <> ">\n      <failure type=\"timeout\" message=\"timed out after "
      <> int.to_string(ms)
      <> "ms\"/>\n    </testcase>\n"
    outcome.Failed(outcome.ExitDetail(raw)) ->
      open
      <> ">\n      <failure type=\"died\" message=\""
      <> escape(string.inspect(raw))
      <> "\"/>\n    </testcase>\n"
  }
}

fn kind_name(p: GleamPanic) -> String {
  case p.kind {
    gleam_panic.Panic -> "panic"
    gleam_panic.Todo -> "todo"
    gleam_panic.LetAssert(..) -> "let_assert"
    gleam_panic.Assert(..) -> "assert"
  }
}

fn counts(results: List(Case)) -> #(Int, Int) {
  #(
    list.count(results, fn(r) {
      case r.2 {
        outcome.Failed(_) -> True
        outcome.Todo(_) -> True
        _ -> False
      }
    }),
    list.count(results, fn(r) {
      case r.2 {
        outcome.Skipped(_) -> True
        _ -> False
      }
    }),
  )
}

fn site(p: GleamPanic) -> String {
  p.module <> "." <> p.function <> ":" <> int.to_string(p.line)
}

fn seconds(us: Int) -> String {
  let ms = us / 1000
  int.to_string(ms / 1000)
  <> "."
  <> string.pad_start(int.to_string(ms % 1000), 3, "0")
}

/// The five XML entities, plus the C0 control characters, which XML 1.0
/// forbids outright — even as character references. A panic message can
/// carry them (string.inspect of binary data, an ANSI escape in a caught
/// error), and one such byte passed through would make CI reject the whole
/// report file. They become U+FFFD instead; tab, newline and carriage
/// return are the three controls XML allows.
fn escape(s: String) -> String {
  s
  |> string.to_utf_codepoints
  |> list.map(escape_codepoint)
  |> string.concat
}

fn escape_codepoint(cp: UtfCodepoint) -> String {
  case string.utf_codepoint_to_int(cp) {
    0x26 -> "&amp;"
    0x3c -> "&lt;"
    0x3e -> "&gt;"
    0x22 -> "&quot;"
    0x27 -> "&apos;"
    0x09 | 0x0a | 0x0d -> string.from_utf_codepoints([cp])
    code if code < 0x20 -> "\u{fffd}"
    _ -> string.from_utf_codepoints([cp])
  }
}

@external(erlang, "vouch_ffi", "write_file")
@external(javascript, "../../../vouch_ffi.mjs", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)
