//// Orchestration: discovery, execution, event emission, exit codes. The
//// per-target loops live here with the narrow FFI contract at the bottom.

import gleam/dynamic.{type Dynamic}
import gleam/io
import gleam/list
import gleam/option.{type Option}
import gleam/order
import gleam/string
import vouch/internal/config
import vouch/internal/event.{type Tally, Tally}
import vouch/internal/outcome.{type TestOutcome}
import vouch/internal/reporter.{type Reporter}

pub fn tally(outcomes: List(TestOutcome)) -> Tally {
  Tally(
    passed: list.count(outcomes, fn(o) { o == outcome.Pass }),
    failed: list.count(outcomes, fn(o) {
      case o {
        outcome.Failed(_) -> True
        _ -> False
      }
    }),
    todos: list.count(outcomes, fn(o) {
      case o {
        outcome.Todo(_) -> True
        _ -> False
      }
    }),
    skipped: list.count(outcomes, fn(o) {
      case o {
        outcome.Skipped(_) -> True
        _ -> False
      }
    }),
  )
}

/// Todos fail the run (unimplemented code is still not done), and so does a
/// run that found no tests at all: silence is worse than a false alarm.
pub fn exit_code(t: Tally) -> Int {
  case t.passed + t.failed + t.todos + t.skipped {
    0 -> 1
    _ ->
      case t.failed + t.todos {
        0 -> 0
        _ -> 1
      }
  }
}

fn matches(filter: Option(String), module: String, function: String) -> Bool {
  case filter {
    option.None -> True
    option.Some(pattern) ->
      string.contains(module <> "." <> function, pattern)
  }
}

fn finish(
  rep: Reporter(s),
  state: s,
  outcomes: List(TestOutcome),
  duration: Int,
) -> Nil {
  let t = tally(outcomes)
  let _ = rep.handle(state, event.RunEnd(t, duration))
  halt(exit_code(t))
}

/// Call a function, capturing any panic as the raw target-specific value.
/// On JavaScript the call is synchronous; async functions are not awaited
/// here (the JavaScript run loop awaits discovered tests itself).
@external(erlang, "vouch_ffi", "catch_panic")
@external(javascript, "../../vouch_ffi.mjs", "catch_panic")
pub fn catch_panic(f: fn() -> a) -> Result(Nil, Dynamic)

@external(erlang, "vouch_ffi", "halt")
@external(javascript, "../../vouch_ffi.mjs", "halt")
pub fn halt(code: Int) -> Nil

@external(erlang, "vouch_ffi", "now_microseconds")
@external(javascript, "../../vouch_ffi.mjs", "now_microseconds")
fn now_microseconds() -> Int

// On the Erlang target enumeration and invocation are synchronous, so the
// whole loop is Gleam.

@target(erlang)
pub fn run(rep: Reporter(s), filter: Option(String), timeout_ms: Int) -> Nil {
  redirect_diagnostics_to_stderr()
  let started = now_microseconds()
  let candidates =
    find_test_files()
    |> list.map(path_to_module)
    |> list.filter(string.ends_with(_, "_test"))
    |> list.flat_map(fn(module) {
      exported_zero_arity(module)
      |> list.filter(string.ends_with(_, "_test"))
      |> list.map(fn(function) { #(module, function) })
    })
  let tests =
    candidates
    |> list.filter(fn(t) { matches(filter, t.0, t.1) })
    |> list.sort(fn(a, b) {
      case string.compare(a.0, b.0) {
        order.Eq -> string.compare(a.1, b.1)
        other -> other
      }
    })

  let state =
    rep.handle(
      rep.init,
      event.RunStart(list.length(tests), list.length(candidates)),
    )
  let #(state, outcomes) =
    list.fold(tests, #(state, []), fn(acc, test_case) {
      let #(state, outcomes) = acc
      let #(module, function) = test_case
      let state = rep.handle(state, event.TestStart(module, function))
      let test_started = now_microseconds()
      let invocation = run_in_process(module, function, timeout_ms)
      let duration = now_microseconds() - test_started
      let out = outcome.classify(module, function, invocation)
      let state =
        rep.handle(state, event.TestResult(module, function, out, duration))
      #(state, [out, ..outcomes])
    })
  finish(rep, state, list.reverse(outcomes), now_microseconds() - started)
}

@target(erlang)
@external(erlang, "vouch_ffi", "redirect_diagnostics_to_stderr")
fn redirect_diagnostics_to_stderr() -> Nil

@target(erlang)
fn path_to_module(path: String) -> String {
  path
  |> string.replace("\\", "/")
  |> string.replace(".gleam", "")
}

@target(erlang)
@external(erlang, "vouch_ffi", "find_test_files")
fn find_test_files() -> List(String)

@target(erlang)
@external(erlang, "vouch_ffi", "exported_zero_arity")
fn exported_zero_arity(module: String) -> List(String)

/// Run one exported zero-arity function in its own monitored process with a
/// timeout. Public so vouch's own suite can exercise isolation directly.
@target(erlang)
@external(erlang, "vouch_ffi", "run_test")
pub fn run_in_process(
  module: String,
  function: String,
  timeout_ms: Int,
) -> outcome.Invocation

// On the JavaScript target dynamic import and test invocation are async, so
// sequencing lives in the FFI, which threads reporter state through Gleam
// callbacks. The state tuple is (reporter state, outcomes so far, start time
// of the test in flight).

// JavaScript has no cheap process primitive: tests run in-process and the
// timeout does not apply. A documented target difference — but asking for a
// non-default timeout here deserves a loud note rather than silence.
@target(javascript)
pub fn run(rep: Reporter(s), filter: Option(String), timeout_ms: Int) -> Nil {
  case timeout_ms == config.default_timeout_ms {
    True -> Nil
    False ->
      io.println_error(
        "vouch: --timeout has no effect on the JavaScript target — tests run in-process and cannot be interrupted",
      )
  }
  let started = now_microseconds()
  js_run_tests(
    #(rep.init, [], 0),
    fn(module, function) { matches(filter, module, function) },
    fn(state, total, discovered) {
      let #(st, outs, _) = state
      #(rep.handle(st, event.RunStart(total, discovered)), outs, 0)
    },
    fn(state, module, function) {
      let #(st, outs, _) = state
      let st = rep.handle(st, event.TestStart(module, function))
      #(st, outs, now_microseconds())
    },
    fn(state, module, function, raw) {
      let #(st, outs, test_started) = state
      let duration = now_microseconds() - test_started
      let out = outcome.classify(module, function, outcome.from_caught(raw))
      let st =
        rep.handle(st, event.TestResult(module, function, out, duration))
      #(st, [out, ..outs], 0)
    },
    fn(state) {
      let #(st, outs, _) = state
      finish(rep, st, list.reverse(outs), now_microseconds() - started)
    },
  )
}

@target(javascript)
@external(javascript, "../../vouch_ffi.mjs", "run_tests")
fn js_run_tests(
  state: #(s, List(TestOutcome), Int),
  should_run: fn(String, String) -> Bool,
  on_begin: fn(#(s, List(TestOutcome), Int), Int, Int) ->
    #(s, List(TestOutcome), Int),
  on_test_start: fn(#(s, List(TestOutcome), Int), String, String) ->
    #(s, List(TestOutcome), Int),
  on_test_result: fn(#(s, List(TestOutcome), Int), String, String, Result(Nil, Dynamic)) ->
    #(s, List(TestOutcome), Int),
  on_done: fn(#(s, List(TestOutcome), Int)) -> Nil,
) -> Nil
