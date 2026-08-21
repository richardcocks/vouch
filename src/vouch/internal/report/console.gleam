//// The default console reporter. Prints a line per result as events arrive,
//// buffers failures and todos, and renders todos, then failure details,
//// then a summary at RunEnd.

import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import vouch/internal/describe
import vouch/internal/event.{type Event, type Tally}
import vouch/internal/gleam_panic.{type GleamPanic}
import vouch/internal/outcome.{type TestOutcome}
import vouch/internal/reporter.{type Reporter, Reporter}

pub type State {
  State(
    failures: List(#(String, outcome.FailureDetail)),
    todos: List(#(String, GleamPanic)),
    discovered: Int,
  )
}

pub fn reporter(filter: Option(String), color: Bool) -> Reporter(State) {
  Reporter(
    init: State(failures: [], todos: [], discovered: 0),
    handle: fn(state, e) { handle(Style(filter, color), state, e) },
  )
}

type Style {
  Style(filter: Option(String), color: Bool)
}

fn handle(style: Style, state: State, e: Event) -> State {
  case e {
    event.RunStart(total, discovered) -> {
      case total == discovered {
        True -> io.println("Running " <> int.to_string(total) <> " tests")
        False ->
          io.println(
            "Running "
            <> int.to_string(total)
            <> " of "
            <> int.to_string(discovered)
            <> " tests",
          )
      }
      State(..state, discovered: discovered)
    }
    event.TestStart(_, _) -> state
    event.TestResult(module, function, out, duration) -> {
      let name = module <> "." <> function
      io.println(result_line(style, name, out, duration))
      case out {
        outcome.Failed(detail) ->
          State(..state, failures: [#(name, detail), ..state.failures])
        outcome.Todo(p) -> State(..state, todos: [#(name, p), ..state.todos])
        _ -> state
      }
    }
    event.RunEnd(tally, duration) -> {
      print_todos(style, list.reverse(state.todos))
      print_failures(style, list.reverse(state.failures))
      print_summary(style, state.discovered, tally, duration)
      state
    }
  }
}

fn result_line(
  style: Style,
  name: String,
  out: TestOutcome,
  duration: Int,
) -> String {
  case out {
    outcome.Pass ->
      "  " <> paint(style, green, "ok") <> "    " <> name <> time(duration)
    outcome.Skipped(p) ->
      "  " <> paint(style, dim, "skip") <> "  " <> name <> " — " <> p.message
    outcome.Todo(p) ->
      "  "
      <> paint(style, yellow, "todo")
      <> "  "
      <> name
      <> " — todo at "
      <> site(p)
    outcome.Failed(_) ->
      "  " <> paint(style, red, "FAIL") <> "  " <> name <> time(duration)
  }
}

fn print_failures(
  style: Style,
  failures: List(#(String, outcome.FailureDetail)),
) -> Nil {
  case failures {
    [] -> Nil
    _ -> {
      io.println("")
      io.println(paint(style, red, "Failures:"))
      list.each(failures, print_failure(style, _))
    }
  }
}

fn print_failure(
  style: Style,
  failure: #(String, outcome.FailureDetail),
) -> Nil {
  let #(name, detail) = failure
  io.println("")
  io.println("  " <> name <> where(style, detail))
  list.each(describe.failure(detail), fn(line) { io.println("    " <> line) })
}

/// The failure site, dimmed, on the same line as the test name so the whole
/// report is name, place, expectation.
fn where(style: Style, detail: outcome.FailureDetail) -> String {
  case detail {
    outcome.PanicDetail(p) ->
      paint(style, dim, "  (" <> describe.location(p) <> ")")
    _ -> ""
  }
}

fn print_todos(style: Style, todos: List(#(String, GleamPanic))) -> Nil {
  case todos {
    [] -> Nil
    _ -> {
      io.println("")
      io.println(paint(style, yellow, "Unimplemented code:"))
      todos
      |> list.group(fn(t) { site(t.1) })
      |> dict.to_list
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      |> list.each(fn(group) {
        let #(site_name, tests) = group
        let count = case list.length(tests) {
          1 -> "1 test"
          n -> int.to_string(n) <> " tests"
        }
        let message = case tests {
          [#(_, p), ..] -> " — \"" <> p.message <> "\""
          [] -> ""
        }
        io.println("  todo at " <> site_name <> message <> " (" <> count <> ")")
      })
    }
  }
}

fn print_summary(
  style: Style,
  discovered: Int,
  tally: Tally,
  duration: Int,
) -> Nil {
  io.println("")
  case tally.passed + tally.failed + tally.todos + tally.skipped {
    0 ->
      case discovered, style.filter {
        0, _ ->
          io.println(
            "No tests found! Expected *_test functions in *_test modules under test/.",
          )
        _, Some(pattern) ->
          io.println(
            "No tests matched the filter \""
            <> pattern
            <> "\" — "
            <> int.to_string(discovered)
            <> " tests were discovered.",
          )
        _, None ->
          io.println(
            "No tests ran, but "
            <> int.to_string(discovered)
            <> " were discovered.",
          )
      }
    _ -> {
      let segment = fn(count, label, color) {
        let text = int.to_string(count) <> " " <> label
        case count {
          0 -> text
          _ -> paint(style, color, text)
        }
      }
      io.println(
        segment(tally.passed, "passed", green)
        <> ", "
        <> segment(tally.failed, "failed", red)
        <> ", "
        <> segment(tally.todos, "todo", yellow)
        <> ", "
        <> segment(tally.skipped, "skipped", dim)
        <> " ("
        <> format_duration(duration)
        <> ")",
      )
    }
  }
}

const green = "32"

const red = "31"

const yellow = "33"

const dim = "2"

fn paint(style: Style, code: String, text: String) -> String {
  case style.color {
    True -> "\u{001B}[" <> code <> "m" <> text <> "\u{001B}[0m"
    False -> text
  }
}

fn site(p: GleamPanic) -> String {
  p.module <> "." <> p.function <> ":" <> int.to_string(p.line)
}

fn time(duration: Int) -> String {
  " (" <> format_duration(duration) <> ")"
}

pub fn format_duration(microseconds: Int) -> String {
  // Tenths of a millisecond, then tenths of a second past one second.
  let tenths_ms = microseconds / 100
  case tenths_ms < 10_000 {
    True ->
      int.to_string(tenths_ms / 10)
      <> "."
      <> int.to_string(tenths_ms % 10)
      <> "ms"
    False -> {
      let tenths_s = tenths_ms / 1000
      int.to_string(tenths_s / 10) <> "." <> int.to_string(tenths_s % 10) <> "s"
    }
  }
}
