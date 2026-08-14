//// JSONL reporter: one JSON event per line, streamed as the run progresses.
//// The schema is explicitly unstable in v1.

import gleam/io
import gleam/list
import gleam/string
import vouch/internal/event.{type Event}
import vouch/internal/gleam_panic.{type GleamPanic}
import vouch/internal/json.{Num, Obj, Str}
import vouch/internal/outcome.{type TestOutcome}
import vouch/internal/reporter.{type Reporter, Reporter}

pub fn reporter() -> Reporter(Nil) {
  Reporter(init: Nil, handle: fn(_, e) {
    io.println(event_to_json(e))
    Nil
  })
}

pub fn event_to_json(e: Event) -> String {
  json.render(Obj(fields(e)))
}

fn fields(e: Event) -> List(#(String, json.Value)) {
  case e {
    event.RunStart(total) -> [
      #("event", Str("run_start")),
      #("total", Num(total)),
    ]
    event.TestStart(module, function) -> [
      #("event", Str("test_start")),
      #("module", Str(module)),
      #("function", Str(function)),
    ]
    event.TestResult(module, function, out, duration) ->
      [
        #("event", Str("test_result")),
        #("module", Str(module)),
        #("function", Str(function)),
        #("outcome", Str(outcome_name(out))),
        #("duration_us", Num(duration)),
      ]
      |> list.append(outcome_fields(out))
    event.RunEnd(tally, duration) -> [
      #("event", Str("run_end")),
      #("passed", Num(tally.passed)),
      #("failed", Num(tally.failed)),
      #("todo", Num(tally.todos)),
      #("skipped", Num(tally.skipped)),
      #("duration_us", Num(duration)),
    ]
  }
}

fn outcome_name(out: TestOutcome) -> String {
  case out {
    outcome.Pass -> "pass"
    outcome.Skipped(_) -> "skip"
    outcome.Todo(_) -> "todo"
    outcome.Failed(_) -> "fail"
  }
}

fn outcome_fields(out: TestOutcome) -> List(#(String, json.Value)) {
  case out {
    outcome.Pass -> []
    outcome.Skipped(p) -> [#("message", Str(p.message))]
    outcome.Todo(p) -> [
      #("message", Str(p.message)),
      #("site_module", Str(p.module)),
      #("site_function", Str(p.function)),
      #("site_line", Num(p.line)),
    ]
    outcome.Failed(outcome.PanicDetail(p)) ->
      [
        #("message", Str(p.message)),
        #("file", Str(p.file)),
        #("line", Num(p.line)),
      ]
      |> list.append(kind_fields(p))
    outcome.Failed(outcome.UnknownDetail(raw)) -> [
      #("kind", Str("unknown")),
      #("message", Str(string.inspect(raw))),
    ]
  }
}

fn kind_fields(p: GleamPanic) -> List(#(String, json.Value)) {
  case p.kind {
    gleam_panic.Panic -> [#("kind", Str("panic"))]
    gleam_panic.Todo -> [#("kind", Str("todo"))]
    gleam_panic.LetAssert(value: v, ..) -> [
      #("kind", Str("let_assert")),
      #("value", Str(string.inspect(v))),
    ]
    gleam_panic.Assert(
      kind: gleam_panic.BinaryOperator(operator: op, left: l, right: r),
      ..,
    ) -> [
      #("kind", Str("assert")),
      #("operator", Str(op)),
      #("left", Str(gleam_panic.describe_expression(l))),
      #("right", Str(gleam_panic.describe_expression(r))),
    ]
    gleam_panic.Assert(..) -> [#("kind", Str("assert"))]
  }
}
