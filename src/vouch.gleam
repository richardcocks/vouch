//// vouch — a test runner for Gleam.

import argv
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import vouch/internal/outcome.{type TestOutcome}
import vouch/internal/runner.{type RawResult}

pub fn main() -> Nil {
  case argv.load().arguments {
    [] -> Nil
    args -> io.println("forwarded args: " <> string.inspect(args))
  }
  runner.run_tests(report)
}

fn report(results: List(RawResult)) -> Nil {
  let outcomes =
    list.map(results, fn(raw) {
      let #(module, function, result) = raw
      let out = outcome.classify(module, function, result)
      print_outcome(module <> "." <> function, out)
      out
    })

  let passed = list.count(outcomes, fn(o) { o == outcome.Pass })
  let skipped = list.count(outcomes, is_skipped)
  let todo_count = list.count(outcomes, is_todo)
  let failed = list.count(outcomes, is_failed)

  io.println("")
  io.println(
    int.to_string(passed)
    <> " passed, "
    <> int.to_string(failed)
    <> " failed, "
    <> int.to_string(todo_count)
    <> " todo, "
    <> int.to_string(skipped)
    <> " skipped",
  )

  case failed + todo_count {
    0 -> runner.halt(0)
    _ -> runner.halt(1)
  }
}

fn print_outcome(name: String, out: TestOutcome) -> Nil {
  case out {
    outcome.Pass -> io.println("  ok    " <> name)
    outcome.Skipped(p) -> io.println("  skip  " <> name <> " — " <> p.message)
    outcome.Todo(p) ->
      io.println(
        "  todo  "
        <> name
        <> " — blocked on todo at "
        <> p.module
        <> "."
        <> p.function
        <> ":"
        <> int.to_string(p.line)
        <> ": "
        <> p.message,
      )
    outcome.Failed(outcome.PanicDetail(p)) ->
      io.println(
        "  FAIL  "
        <> name
        <> " — "
        <> p.message
        <> " ("
        <> p.file
        <> ":"
        <> int.to_string(p.line)
        <> ")",
      )
    outcome.Failed(outcome.UnknownDetail(raw)) ->
      io.println("  FAIL  " <> name <> " — " <> string.inspect(raw))
  }
}

fn is_skipped(o: TestOutcome) -> Bool {
  case o {
    outcome.Skipped(_) -> True
    _ -> False
  }
}

fn is_todo(o: TestOutcome) -> Bool {
  case o {
    outcome.Todo(_) -> True
    _ -> False
  }
}

fn is_failed(o: TestOutcome) -> Bool {
  case o {
    outcome.Failed(_) -> True
    _ -> False
  }
}
