//// The default console reporter. Prints a line per result as events arrive,
//// buffers failures and todos, and renders details plus a summary at RunEnd.

import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
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

pub fn reporter(filter: Option(String)) -> Reporter(State) {
  Reporter(init: State(failures: [], todos: [], discovered: 0), handle: fn(
    state,
    e,
  ) {
    handle(filter, state, e)
  })
}

fn handle(filter: Option(String), state: State, e: Event) -> State {
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
      io.println(result_line(name, out, duration))
      case out {
        outcome.Failed(detail) ->
          State(..state, failures: [#(name, detail), ..state.failures])
        outcome.Todo(p) -> State(..state, todos: [#(name, p), ..state.todos])
        _ -> state
      }
    }
    event.RunEnd(tally, duration) -> {
      print_failures(list.reverse(state.failures))
      print_todos(list.reverse(state.todos))
      print_summary(filter, state.discovered, tally, duration)
      state
    }
  }
}

fn result_line(name: String, out: TestOutcome, duration: Int) -> String {
  case out {
    outcome.Pass -> "  ok    " <> name <> time(duration)
    outcome.Skipped(p) -> "  skip  " <> name <> " — " <> p.message
    outcome.Todo(p) -> "  todo  " <> name <> " — blocked on todo at " <> site(p)
    outcome.Failed(_) -> "  FAIL  " <> name <> time(duration)
  }
}

fn print_failures(failures: List(#(String, outcome.FailureDetail))) -> Nil {
  case failures {
    [] -> Nil
    _ -> {
      io.println("")
      io.println("Failures:")
      list.each(failures, print_failure)
    }
  }
}

fn print_failure(failure: #(String, outcome.FailureDetail)) -> Nil {
  let #(name, detail) = failure
  io.println("")
  io.println("  " <> name)
  case detail {
    outcome.PanicDetail(p) -> {
      io.println(
        "    "
        <> p.message
        <> " ("
        <> p.file
        <> ":"
        <> int.to_string(p.line)
        <> ")",
      )
      print_panic_detail(p)
    }
    outcome.UnknownDetail(raw) -> io.println("    " <> string.inspect(raw))
    outcome.TimeoutDetail(ms) ->
      io.println("    timed out after " <> int.to_string(ms) <> "ms")
    outcome.ExitDetail(raw) ->
      io.println("    test process died: " <> string.inspect(raw))
  }
}

fn print_panic_detail(p: GleamPanic) -> Nil {
  case p.kind {
    gleam_panic.Assert(
      kind: gleam_panic.BinaryOperator(operator: op, left: l, right: r),
      ..,
    ) -> {
      io.println("      left:  " <> expression_value(l))
      io.println("      right: " <> expression_value(r))
      io.println("      op:    " <> op)
    }
    gleam_panic.Assert(kind: gleam_panic.FunctionCall(arguments: args), ..) ->
      list.each(args, fn(a) {
        io.println("      arg:   " <> expression_value(a))
      })
    gleam_panic.LetAssert(value: v, ..) ->
      io.println("      value: " <> string.inspect(v))
    _ -> Nil
  }
}

fn expression_value(e: gleam_panic.AssertedExpression) -> String {
  gleam_panic.describe_expression(e)
}

fn print_todos(todos: List(#(String, GleamPanic))) -> Nil {
  case todos {
    [] -> Nil
    _ -> {
      io.println("")
      io.println("Blocked on unimplemented code:")
      todos
      |> list.group(fn(t) { site(t.1) })
      |> dict.to_list
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      |> list.each(fn(group) {
        let #(site_name, tests) = group
        io.println(
          "  "
          <> int.to_string(list.length(tests))
          <> " test(s) blocked on todo at "
          <> site_name,
        )
      })
    }
  }
}

fn print_summary(
  filter: Option(String),
  discovered: Int,
  tally: Tally,
  duration: Int,
) -> Nil {
  io.println("")
  case tally.passed + tally.failed + tally.todos + tally.skipped {
    0 ->
      case discovered, filter {
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
    _ ->
      io.println(
        int.to_string(tally.passed)
        <> " passed, "
        <> int.to_string(tally.failed)
        <> " failed, "
        <> int.to_string(tally.todos)
        <> " todo, "
        <> int.to_string(tally.skipped)
        <> " skipped ("
        <> format_duration(duration)
        <> ")",
      )
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
      int.to_string(tenths_s / 10)
      <> "."
      <> int.to_string(tenths_s % 10)
      <> "s"
    }
  }
}
